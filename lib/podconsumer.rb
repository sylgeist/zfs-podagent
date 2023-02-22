require 'bundler/setup'
require 'bunny'
require 'logger'
require 'json'
require 'bytes_converter'
require_relative 'jail'

class PodConsumer
  attr_accessor :channel, :consumer, :direct, :cleanup, :create_queue, :cleanup_queue, :direct_queue

  def initialize
    @logger = Logger.new('/var/log/podagent/podsumer.log', 'weekly')
    # @region = `cloud-init query availability_zone`
    # @podname = `cloud-init query local_hostname`
    @region = 'sfo3'
    @podname = `hostname -s`.chomp

    # Get the Jail instance
    @warden = Jail.new

    # RabbitMQ Cluster connection (uses RABBITMQ_URL env variable to set connection)
    @logger.debug('consumer.startup') { 'Initializing queues...' }
    @connection = Bunny.new("#{ENV['RABBITMQ_URL']}", connection_name: "#{@podname}")
    @connection.start
    @logger.debug('consumer.startup') { "Connection to RabbitMQ: #{@connection.status}" }

    # MQ Definitions
    @channel = @connection.create_channel
    @channel.prefetch(1)
    @jail_create_exch  = @channel.topic('jail-create', durable: true)
    @jail_cleanup_exch = @channel.fanout('jail-cleanup', durable: true)
    @jail_direct_exch  = @channel.direct('jail-direct', durable: true)
    @jail_dlx_exch     = @channel.fanout('jail-failsafe', durable: true)
    @reply_exch        = @channel.default_exchange

    # Queues and bindings
    @create_queue  = @channel.queue(
      'create',
      durable: true,
      arguments: {
        'x-dead-letter-exchange': @jail_dlx_exch.name,
        'x-message-ttl': 10000 })
      .bind(@jail_create_exch, routing_key: 'us.west.#.create'
    )
    @cleanup_queue = @channel.queue('', exclusive: true).bind(@jail_cleanup_exch)
    @direct_queue  = @channel.queue('', exclusive: true).bind(@jail_direct_exch, routing_key: @podname)
  end

  def create_subscriber
    @create_subscriber = @create_queue.subscribe(manual_ack: true) do |delivery_info, properties, payload|
      @logger.debug('consumer.create') { "Create Request: #{properties.inspect}" }

      jail_id = properties.headers['jail_params']['jail_id']
      jail_params = properties.headers['jail_params']
      correlation_id = properties.correlation_id
      response = {}
      storage_needed = 0

      # If there's not enough room in the pool for the plan, built it without the ususal reservation and backfill ASAP
      planspace = BytesConverter::convert(jail_params.fetch('quota')).to_i
      poolspace = `/sbin/zfs list -Hpo available remotepool`.to_i
      if planspace > poolspace
        @logger.info('consumer.create') { "Pod does not have enough space for: #{jail_id} Plan: #{planspace} > Pool: #{poolspace}" }
        @logger.info('consumer.create') { 'Building jail without reservation and requesting storage expansing' }
        jail_params['reserve'] = '0GB'
        storage_needed = planspace - poolspace
      end

      case properties.type
      when 'create'
        if jail_id.nil?
          @channel.reject(delivery_info.delivery_tag)
          @logger.info('consumer.create') { "Received empty jail_id create - discarding" }
          break
        end

        @logger.info('consumer.create') { "Create: #{jail_id}" }
        @logger.debug('consumer.create') { "#{jail_id} - #{jail_params}" }
        result = @warden.create(jail_id: jail_id, ssh_key: payload, **jail_params)
        
        # Returned port should always be above 9999 from PODs
        if result && result.to_i.between?(30_000,59_999)
          # If successful reponse, awknowledge the message to the broker
          @channel.acknowledge(delivery_info.delivery_tag)
          response = { message: 'Success', jail_id: "#{jail_id}", port: result, pod: @podname, storage_needed: storage_needed }

          # Return jail port information to the reply-queue
          @logger.debug('consumer.create') { "Acknowledge: #{delivery_info.delivery_tag} from: #{properties.app_id} at: #{properties.timestamp}" }
          reply(message: response, routing_key: properties.reply_to, request_id: correlation_id)
        elsif result.nil?
          @channel.acknowledge(delivery_info.delivery_tag)
          response = { message: 'Failed', jail_id: "#{jail_id}", detail: 'Jail already exists on this system!' }
          reply(message: response, routing_key: properties.reply_to, request_id: correlation_id)
        else
          # Create failed for some other reason, reject the request and re-queue for another pod to pick up
          @channel.reject(delivery_info.delivery_tag, true)
          @logger.warn('consumer.create') { "Rejecting: #{jail_id}" }
          @logger.debug('consumer.create') { "Rejecting: #{delivery_info}" }
        end
      else
        # Catchall for future message types
        @channel.reject(delivery_info.delivery_tag)
        @logger.warn('consumer.create') { 'Not a create message? Is it in the right queue?' }
      end
    end
  end

  def create_subscriber_stop
    @logger.info('consumer') { 'Shut down create subscriber' }
    @create_subscriber.cancel
  end

  def cleanup_subscriber
    # Cleanup Queue for cancelled customers - purges or preserves all jails owned by a customer ID
    @cleanup_subscriber = @cleanup_queue.subscribe do |_delivery_info, properties, _payload|
      @logger.debug('consumer.cleanup') { "Cleanup Request: #{properties.inspect}" }

      cust_id = properties.headers['jail_params']['cust_id']

      case properties.type
      when 'purge'
        @logger.info('consumer.purge') { "Removing all jails from: #{cust_id}" }
        @warden.purge(cust_id: cust_id)
      when 'preserve'
        @logger.info('consumer.preserve') { "Hold/preserve jails from: #{cust_id}" }
        @warden.preserve(cust_id: cust_id)
      else
        # Catchall for future message types
        @logger.warn('consumer.cleanup') { 'Not a valid cleanup message type' }
      end
    end
  end

  def cleanup_subscriber_stop
    @logger.info('consumer.cleanup') { 'Shut down cleanup subscriber' }
    @cleanup_subscriber.cancel
  end

  def direct_subscriber
    # Direct Queue for POD specific actions: modify plan, migrate to new pod, remove individual jails
    @direct_subscriber = @direct_queue.subscribe(manual_ack: true) do |delivery_info, properties, payload|
      @logger.debug('consumer.direct') { "Direct Request: #{properties.inspect}" }

      jail_id = properties.headers['jail_params']['jail_id']
      jail_params = properties.headers['jail_params']
      correlation_id = properties.correlation_id
      response = {}

      case properties.type
      when 'modify'
        @logger.info('consumer.modify') { "Modify: #{jail_params.inspect}" }
        result = @warden.modify(jail_id: jail_id, ssh_key: payload, **jail_params)
        response = if result
                     { message: 'Success', jail_id: "#{jail_id}", detail: "#(**jail_params}" }
                   elsif result.nil?
                     { message: 'Failed', jail_id: "#{jail_id}", detail: "Jail not found on #{@podname}" }
                   else
                     { message: 'Failed', jail_id: "#{jail_id}", detail: 'Modification failed, check pod logs' }
                   end
      when 'migrate'
        @logger.info('consumer.migrate') { "Initiate migrate for: #{jail_id}" }
        result = @warden.migrate(jail_id: jail_id, pod_id: pod_id)
        response = if result
                     { message: 'Success', jail_id: "#{jail_id}", detail: "Moved to #{pod_id}" }
                   elsif result.nil?
                     { message: 'Failed', jail_id: "#{jail_id}", detail:  "Jail not found on #{@podname}" }
                   else
                     { message: 'Failed', jail_id: "#{jail_id}", detail: 'Migration failed, check pod logs' }
                   end
      when 'remove'
        @logger.info('consumer.remove') { "Removing: #{jail_id}" }
        result = @warden.remove(jail_id: jail_id)
        response = if result
                     { message: 'Success', jail_id: "#{jail_id}", detail: "Jail removed" }
                   elsif result.nil?
                     { message: 'Failed', jail_id: "#{jail_id}", detail: "Jail not found on #{@podname}" }
                   else
                     { message: 'Failed', jail_id: "#{jail_id}", detail: 'Removal failed, check pod logs' }
                   end
      else
        # Catchall for future message types
        @logger.warn('consumer.direct') { 'Undefined request' }
      end

      @channel.acknowledge(delivery_info.delivery_tag)

      # Send back results
      reply(message: response, routing_key: properties.reply_to, request_id: correlation_id)
    end
  end

  def direct_subscriber_stop
    @direct_subscriber.cancel
  end

  def reply(message:, routing_key:, request_id:)
    @reply_exch.publish(JSON.generate(message),
                      routing_key: routing_key,
                      correlation_id: request_id)
  end

  def stop
    create_subscriber_stop
    cleanup_subscriber_stop
    direct_subscriber_stop
    @channel.close
    @connection.close
    @logger.close
  end
end
