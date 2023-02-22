require 'logger'

class Jail
  def initialize
    @logger = Logger.new('/var/log/podagent/jail.log', 'weekly')

    # Create array of usable incoming ports
    @master_ports = (30_000..59_999).to_a

    # Store in use ports and IP's
    @jail_ports_inuse = []
    @jail_ip_inuse = []

    # Regex to extract fields from /etc/jail.conf
    @jail_fields_regex = /(?<jail_name>\w+) \{ \$address = (?<jail_ip>\d+.\d+.\d+.\d+); \$port = (?<jail_port>\d+); \$quota = (?<quota>\w+); \$reserve = (?<reserve>\w+); \$snaplim = (?<snaplim>\w+); \$filelim = (?<filelim>\d+);/
    @jail_configs = []

    # Perform an initial data gather on startup
    update_inuse
  end

  def next_port
    available_port = (@master_ports - @jail_ports_inuse).sample
    @jail_ports_inuse.push(available_port)
    available_port.to_s
  end

  def next_ip
    count = 0
    until defined?(new_ip) || count > 10
      possible_ip = IPAddr.new(10 * 2**24 + rand(2**24), Socket::AF_INET)
      unless @jail_ip_inuse.include?(possible_ip)
        new_ip = possible_ip
        @jail_ip_inuse.push(new_ip)
        return new_ip.to_s
      end
      count += 1
    end
    @logger.warn('jail.next_ip') { "Couldn't find a suitable IP after #{count} tries. Check for errors with interface or subnet" }
    nil
  end

  def update_inuse
    # Update in memory details for jails existing on this POD
    @jail_configs.clear
    @jail_ports_inuse.clear
    @jail_ip_inuse.clear

    # Parse /etc/jail.conf to gather currently defined jails
    File.open('/etc/jail.conf').each do |line|
      @jail_fields_regex.match(line)
      @jail_configs.push($~) unless $~.nil?
    end

    @jail_configs.each do |jail_item|
      @jail_ip_inuse.push(jail_item[:jail_ip])
      @jail_ports_inuse.push(jail_item[:jail_port].to_i)
    end
  end

  # Create Queue methods
  def create(jail_id:, ssh_key:, **jail_params)
    # Verify jail is unique on system
    return nil if @jail_configs.one? { |jail_item| jail_item[:jail_name].eql?(jail_id) }

    # Captures updated fields
    quota   = jail_params["quota"]
    reserve = jail_params["reserve"]
    snaplim = jail_params["snaplim"]
    filelim = jail_params["filelim"]
    port    = next_port

    # Generate jail config fragment with unique customer ID name to avoid duplicates
    file = File.open('/etc/jail.conf', 'a+')
    new_jail_config = "#{jail_id} { $address = #{next_ip}; $port = #{port}; $quota = #{quota}; $reserve = #{reserve}; $snaplim = #{snaplim}; $filelim = #{filelim}; }"
    @logger.debug('jail.create') { "Writing: #{new_jail_config}" }
    file.puts new_jail_config
    file.close

    @logger.info('jail.create') { "Starting: #{jail_id}" }
    jail_start = system("/usr/sbin/jail -c #{jail_id}")
    auth_keys_file = File.open("/remotepool/#{jail_id}/home/.ssh/authorized_keys", 'w')
    auth_keys_file.puts ssh_key
    auth_keys_file.close

    update_inuse
    jail_start ? (return port) : (return false)
  end

  # Cleanup Queue
  def purge(cust_id:)
    # Remove all jails owned by a specific customer
    pending = []

    # Capture the jails with the matching customer ID
    @jail_configs.each do |jail_item|
      pending.push(jail_item[:jail_name]) if jail_item[:jail_name].start_with?(cust_id)
    end
    @logger.debug('jail.purge') { "Purge list: #{pending.inspect}" }

    # Create a local array of jails to delete to avoid clobbering
    unless pending.empty?
      removed_jails = pending.map { |jail_item| remove(jail_id: jail_item) }
      @logger.debug('jail.purge') { "Removed: #{removed_jails}" }
      return removed_jails.length
    end
    nil
  end

  # Direct Queue Methods
  def remove(jail_id:)
    # Remove running jail, remove from /etc/jail.conf and update usages

    # Verify jail exists before trying to remove
    return nil unless @jail_configs.one? { |jail_item| jail_item[:jail_name].eql?(jail_id) }

    @logger.info('jail.remove') { "Stopping Jail: #{jail_id}" }
    jail_remove = system("/usr/sbin/jail -r #{jail_id}")

    @logger.info('jail.remove') { "Deleting #{jail_id} from '/etc/jails.conf'" }
    jail_file_remove = system("/usr/bin/sed -i .delbak /#{jail_id}/d /etc/jail.conf")
    @logger.debug('jail.remove') { "File diff:\n" + `/usr/bin/diff /etc/jail.conf /etc/jail.conf.delbak` }

    @logger.info('jail.remove') { "Destroying datasets: #{jail_id}" }
    zfs_destroy = system("/sbin/zfs destroy -r remotepool/#{jail_id}")

    @logger.debug('jail.remove') { "Return status: #{jail_remove}:#{zfs_destroy}:#{jail_file_remove}" }
    return false unless jail_remove && zfs_destroy && jail_file_remove

    update_inuse
    jail_remove
  end

  def migrate(jail_id:)
    # TODO: add functionality to migrate jail to new host
  end

  def modify(jail_id:, ssh_key: '', **jail_params)
    # Modifies an existing jail on the POD
    jail_mod, zfs_mod, modifycmd = true

    # Regex to extract single jail's configs
    @jail_name_regex = /(?<jail_name>#{jail_id}) \{ \$address = (?<jail_ip>\d+.\d+.\d+.\d+); \$port = (?<jail_port>\d+); \$quota = (?<quota>\w+); \$reserve = (?<reserve>\w+); \$snaplim = (?<snaplim>\w+); \$filelim = (?<filelim>\d+);/

    # Verify jail exists on POD before going further
    return nil unless @jail_configs.one? { |jail_item| jail_item[:jail_name].eql?(jail_id) }

    current_params = @jail_name_regex.match(IO.read('/etc/jail.conf'))

    # Skip if we are just updating ssh keys
    unless current_params == jail_params
      quota   = jail_params["quota"]
      reserve = jail_params["reserve"]
      snaplim = jail_params["snaplim"]
      filelim = jail_params["filelim"]

      jail_config = "#{jail_id} { $address = #{current_params[:jail_ip]}; $port = #{current_params[:jail_port]}; $quota = #{quota}; $reserve = #{reserve}; $snaplim = #{snaplim}; $filelim = #{filelim}; }"
      @logger.info('jail.modify') { "Updating params: #{jail_params} to #{jail_config}" }
      modifycmd = system("/usr/bin/sed -i .modbak 's/^#{jail_id}.*$/#{jail_config}/' /etc/jail.conf")
      @logger.debug('jail.modify') { "Modify diff:\n" + `/usr/bin/diff /etc/jail.conf /etc/jail.conf.delbak` }

      zfs_mod = system("/sbin/zfs set quota=#{quota} reserve=#{reserve} snapshot_limit=#{snaplim} filesystem_limit=#{filelim} remotepool/#{jail_id}")

      @logger.info('jail.modify') { "Restarting #{jail_id} to pick up changes (if necessary)" }
      jail_mod = system("/usr/sbin/jail -mr #{jail_id}")
      @logger.debug('jail.modify') { "Jail mod: #{jail_mod} ZFS mod: #{zfs_mod} CMD mod: #{modifycmd}" }
    end

    # If we receive a new SSH, put it in the jail, overwriting the original
    unless ssh_key.empty?
      @logger.debug('jail.modify') { "Modify: #{ssh_key}" }
      auth_keys_file = File.open("/remotepool/#{jail_id}/home/.ssh/authorized_keys", 'w')
      auth_keys_file.puts ssh_key
      auth_keys_file.close
    end

    update_inuse

    jail_mod && zfs_mod && modifycmd ? (return true) : (return false)
  end
end
