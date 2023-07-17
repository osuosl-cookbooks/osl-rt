# Resource: osl_request_tracker
# Easily deploy a custom RT instance for a customer

provides :osl_request_tracker
resource_name :osl_request_tracker
unified_mode true

# Properties
property :domain_name, String, name_property: true
property :domain_root, String, required: true
property :root_password, String, required: true
property :default_email, String, default: 'support'
property :db_type, String, default: 'mysql'
property :db_host, String, default: 'localhost'
property :db_name, String, required: true
property :db_username, String, required: true
property :db_password, String, required: true
property :error_redirect, String, required: true
property :queues, Hash, default: {}
property :plugins, Array, default: []
property :lifecycles, Hash, default: {}
property :config_options, Hash, default: {}

default_action :create

action :create do

  # Get the config options, and overwrite the options given with other properties
  config_options = new_resource.config_options

  # Organization will be the Main domain name only, no sub-level domains.

  config_options['$rtname'] = new_resource.domain_name
  config_options['$WebDomain'] = new_resource.domain_name
  config_options['$Organization'] = new_resource.domain_name[/([\w\-_]+\.+\w+$)/]
  config_options['$CorrespondAddress'] = "#{new_resource.default_email}@#{config_options["$Organization"]}"
  config_options['$CommentAddress'] = "#{new_resource.default_email}-comment@#{config_options["$Organization"]}"
  config_options['$DatabaseType'] = new_resource.db_type
  config_options['$DatabaseHost'] = new_resource.db_host
  config_options['$DatabaseRTHost'] = new_resource.db_host
  config_options['$DatabaseName'] = new_resource.db_name
  config_options['$DatabaseUser'] = new_resource.db_username
  config_options['$DatabasePassword'] = new_resource.db_password
  config_options['_Plugins'] = new_resource.plugins
  config_options['_Lifecycles'] = new_resource.lifecycles

  ruby_block 'Set up the emails' do
    block do
      # Set up the queue emails
      rt_emails = init_emails(new_resource.queues, config_options['$Organization'], new_resource.default_email)

      config_options['$RTAddressRegexp'] = "^(#{rt_emails.join('|')}(-comment)?\@(#{config_options['WebDomain']}))"

      # Remove the default email from the array
      rt_emails.pop()
    end
    action :nothing
  end

  file '/root/emails' do
    content "#{new_resource.queues}"
    mode '0400'
    notifies :run, 'ruby_block[Set up the emails]', :immediately
  end


  # Parse the config hash to a string we can use as
  # the RT_SiteConfig.pm file.
  strConfigFile = parse_config(new_resource.config_options)

  # RT Initial Configuration.
  file '/opt/rt/etc/RT_SiteConfig.pm' do
    content strConfigFile
    user 'root'
    group 'apache'
    mode '0640'
    sensitive true
    notifies :reload, 'apache2_service[osuosl]'
  end

  # Root Account
  template '/root/.rtrc' do
    source 'rt/rtrc.erb'
    user 'root'
    group 'root'
    mode '0600'
    sensitive true
    variables(root_pass: new_resource.root_password, domain: new_resource.domain_name)
    notifies :reload, 'apache2_service[osuosl]'
  end

  # Add the RT command to the root user's PATH
  link '/usr/local/sbin/rt' do
    to '/opt/rt/bin/rt'
  end

  # Initalize the DB
  execute 'init-db-rt' do
    command <<-EOH
      /opt/rt/sbin/rt-setup-database \
        --action init \
        --dba #{new_resource.db_username} \
        --dba-password #{new_resource.db_password} \
        --skip-create && \
      touch /opt/rt/chef/init-db-rt
    EOH
    creates '/opt/rt/chef/init-db-rt'
    sensitive true
  end

  # Set a new password for root
  execute 'Set root password' do
    command <<-EOH
      mysql -u #{new_resource.db_username} -p#{new_resource.db_password} -e 'UPDATE Users SET Password=md5("#{new_resource.root_password}") WHERE Name="root";' #{new_resource.db_name} \
      && touch /opt/rt/chef/init-root-passwd
    EOH
    creates '/opt/rt/chef/init-root-passwd'
    sensitive true
  end

  acme_selfsigned new_resource.domain_name do
    crt "/etc/pki/tls/certs/#{new_resource.domain_name}.crt"
    chain "/etc/pki/tls/certs/#{new_resource.domain_name}-chain.crt"
    key "/etc/pki/tls/certs/#{new_resource.domain_name}.key"
  end

  # Set up web app
  apache_app new_resource.domain_name do
    directory '/opt/rt/share/html'
    directive_http ["Redirect permanent / https://#{new_resource.domain_name}"]
    include_config true
    include_directory 'rt'
    include_name 'rt'
    ssl_enable true
    cert_file "/etc/pki/tls/certs/#{new_resource.domain_name}.crt"
    cert_key "/etc/pki/tls/certs/#{new_resource.domain_name}.key"
    cert_chain "/etc/pki/tls/certs/#{new_resource.domain_name}-chain.crt"
  end

  # Make the new self-signed certificate trusted
  execute 'Trust self-signed cert' do
    command "cat /etc/pki/tls/certs/#{new_resource.domain_name}.crt >> /etc/ssl/certs/ca-bundle.crt"
    creates '/tmp/cacrt'
  end

  # Verify that the certificate is valid
  execute 'Validate self-signed cert' do
    command "openssl verify /etc/pki/tls/certs/#{new_resource.domain_name}.crt && touch /tmp/cacrt"
    retries 5
    retry_delay 10
    creates '/tmp/cacrt'
  end

  # Set up the queues in RT
  new_resource.queues.each do |pt, email|
    execute "Creating RT queue for #{pt}" do
      command <<~EOL
      /opt/rt/bin/rt create -t queue set \
        name="#{pt}" correspondaddress="#{email}@#{new_resource.domain_name}" \
        commentaddress="#{email}-comment@#{new_resource.domain_name}" \
        && touch /tmp/#{email}done
      EOL
      creates "/tmp/#{email}done"
    end
  end

  # Install Mutt and Procmail
  package %w(mutt procmail)

  # Set up user for mail
  user new_resource.default_email do
    manage_home true
  end

  # Nobody mail directory
  file '/var/spool/mail/nobody' do
    owner 'nobody'
    group 'mail'
    mode '0660'
  end

  # Set up the procmail
  template "/home/#{new_resource.default_email}/.procmailrc" do
    source 'rt/support.procmailrc.erb'
    cookbook 'osl-rt'
    owner new_resource.default_email
    group new_resource.default_email
    variables(
      rt_queues: new_resource.queues,
      domain_name: new_resource.domain_name,
      error_email: new_resource.error_redirect
    )
  end

  # Mutt Configuration
  cookbook_file '/etc/Muttrc.local' do
    source 'rt/Muttrc.local'
    cookbook 'osl-rt'
  end

end
