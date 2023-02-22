#! /usr/local/bin/ruby
require 'bundler/setup'
require 'logger'
require_relative 'lib/podconsumer.rb'

STDOUT.sync = true

MINPLAN_BYTES = 10_737_418_240
consumer = PodConsumer.new
consumer.create_subscriber
consumer.cleanup_subscriber
consumer.direct_subscriber

@logger = Logger.new('/var/log/podagent/podagent.log', 'weekly')

# Test for ZFS basejail that is needed before we consume any creates
abort('Remotepool is missing the basejail snapshot!') unless `/sbin/zfs list remotepool/basejail@prod`

begin
  loop do
    # Get the current free space in the pool and ensure we have at least the smallest plan available
    poolspace = `/sbin/zfs list -Hpo available remotepool`.to_i

    if poolspace <= MINPLAN_BYTES
      @logger.info('podagent.main') { "#{poolspace / 1024 / 1024 / 1024}GB is below usable cap! Add space!" }
    elsif poolspace > MINPLAN_BYTES && consumer.create_queue.consumer_count > 0
      @logger.debug('podagent.main') { 'All good - keep on keeping on' }
    end
    sleep 600
  end
rescue SignalException
  @logger.info('podagent.interrupt') { "\nShutting down consumers: " }
  consumer.stop
  @logger.close
end
