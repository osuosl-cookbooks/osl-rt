#
# Cookbook:: osl-rt
# Recipe:: default
#
# Copyright:: 2023, Oregon State University
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe 'osl-apache'
include_recipe 'osl-apache::mod_ssl'
include_recipe 'osl-apache::mod_perl'
include_recipe 'osl-mysql::client'
include_recipe 'yum-osuosl'
include_recipe 'perl'

package %w(request-tracker mutt procmail)

# Get the config options, and overwrite the options given with other properties
config_options = {}

# Organization will be the Main domain name only, no sub-level domains.

config_options['$rtname'] = node['osl-rt']['fqdn']
config_options['$WebDomain'] = node['osl-rt']['fqdn']
config_options['$Organization'] = node['osl-rt']['fqdn'][/([\w\-_]+\.+\w+$)/]
config_options['$CorrespondAddress'] = "#{node['osl-rt']['default']}@#{config_options['$Organization']}"
config_options['$CommentAddress'] = "#{node['osl-rt']['default']}-comment@#{config_options['$Organization']}"
config_options['$DatabaseType'] = node['osl-rt']['db']['type']
config_options['$DatabaseHost'] = node['osl-rt']['db']['host']
config_options['$DatabaseRTHost'] = node['osl-rt']['db']['host']
config_options['$DatabaseName'] = node['osl-rt']['db']['name']
config_options['$DatabaseUser'] = node['osl-rt']['db']['username']
config_options['$DatabasePassword'] = node['osl-rt']['db']['password']
config_options['_Plugins'] = node['osl-rt']['plugins']
config_options['_Lifecycles'] = node['osl-rt']['lifecycles']

# Set up the queue emails
rt_emails = init_emails(node['osl-rt']['queues'], node['osl-rt']['fqdn'], node['osl-rt']['default'])

config_options['$RTAddressRegexp'] = "^(#{rt_emails.join('|')}(-comment)?\@(#{node['osl-rt']['fqdn']}))"

# Set up the hostname as the website
hostname node['hostname'] do
  aliases ["#{node['osl-rt']['fqdn']}"]
end

# Parse the config hash to a string we can use as
# the RT_SiteConfig.pm file.
strConfigFile = parse_config(config_options)

# Root Account
template '/root/.rtrc' do
  source 'rt/rtrc.erb'
  cookbook 'osl-rt'
  user 'root'
  group 'root'
  mode '0600'
  sensitive true
  variables(root_pass: node['osl-rt']['root-password'], domain: node['osl-rt']['fqdn'])
end

# Add the RT command to the root user's PATH
link '/usr/local/sbin/rt' do
  to '/opt/rt/bin/rt'
end

# RT Initial Configuration.
file '/opt/rt/etc/RT_SiteConfig.pm' do
  content strConfigFile
  user 'root'
  group 'apache'
  mode '0640'
  sensitive true
  notifies :restart, 'apache2_service[osuosl]', :immediately
end

# Initalize the DB
execute 'init-db-rt' do
  command <<-EOH
    /opt/rt/sbin/rt-setup-database \
      --action init \
      --dba #{config_options['$DatabaseUser']} \
      --dba-password #{config_options['$DatabasePassword']} \
      --skip-create && \
    touch /opt/rt/chef/init-db-rt
  EOH
  creates '/opt/rt/chef/init-db-rt'
  sensitive true
end

# Set a new password for root
execute 'Set root password' do
  command "mysql -u #{config_options['$DatabaseUser']} -p#{config_options['$DatabasePassword']} -e 'UPDATE Users SET Password=md5(\"#{node['osl-rt']['root-password']}\") WHERE Name=\"root\";' #{config_options['$DatabaseName']} && touch /opt/rt/chef/init-root-passwd"
  creates '/opt/rt/chef/init-root-passwd'
  sensitive true
end

# Set up web app
apache_app node['osl-rt']['fqdn'] do
  directory '/opt/rt/share/html'
  include_config true
  include_directory 'rt'
  include_name 'rt'
end

service 'httpd' do
  action :restart
  not_if { ::File.exist?('/tmp/apache-reset') }
end

file '/tmp/apache-reset'

# Restart the web app, ONLY ONCE!
#execute 'Restart apache' do
#  command 'touch /tmp/apache-reset'
#  creates '/tmp/apache-reset'
#  notifies :restart, 'apache2_service[osuosl]', :immediately
#end

# Set up the queues in RT
node['osl-rt']['queues'].each do |pt, email|
  execute "Creating RT queue for #{pt}" do
    command <<~EOL
    /opt/rt/bin/rt create -t queue set \
      name="#{pt}" correspondaddress="#{email}@#{node['osl-rt']['fqdn']}" \
      commentaddress="#{email}-comment@#{node['osl-rt']['fqdn']}" \
      && touch /tmp/#{email}done
    EOL
    creates "/tmp/#{email}done"
  end
end

# Set up user for mail
user node['osl-rt']['default'] do
  manage_home true
end

# Nobody mail directory
file '/var/spool/mail/nobody' do
  owner 'nobody'
  group 'mail'
  mode '0660'
end

# Set up the procmail
template "/home/#{node['osl-rt']['default']}/.procmailrc" do
  source 'rt/support.procmailrc.erb'
  cookbook 'osl-rt'
  owner node['osl-rt']['default']
  group node['osl-rt']['default']
  variables(
    rt_queues: node['osl-rt']['queues'],
    domain_name: node['osl-rt']['fqdn'],
    error_email: "#{shell_out('id -nu 1001').stdout[0..-2]}@localhost"
  )
end

# Set up procmail in the default user's account
file '/home/almalinux/.procmailrc' do
  content "DEFAULT=$HOME/Mail/\nPATH=/usr/local/bin:/usr/bin:/bin\nMAILDIR=$HOME/Mail/\nLOGFILE=$MAILDIR/from"
  user 1001
  group 1001
end

# Mutt Configuration
cookbook_file '/etc/Muttrc.local' do
  source 'rt/Muttrc.local'
  cookbook 'osl-rt'
end

node['osl-rt']['queues'].each do |_, email|
  node.default['postfix']['aliases'][email] = node['osl-rt']['default']
  node.default['postfix']['aliases']["#{email}-comment"] = node['osl-rt']['default']
  node.default['postfix']['transports']["#{email}@#{node['osl-rt']['fqdn']}"] = 'local:$myhostname'
  node.default['postfix']['transports']["#{email}-comment@#{node['osl-rt']['fqdn']}"] = 'local:$myhostname'
end
node.force_override['postfix']['aliases'][node['osl-rt']['default']] = node['osl-rt']['default']

node.default['osl-postfix']['main']['mydestination'] = "$myhostname, localhost.$mydomain, localhost, #{node['osl-rt']['fqdn']}"
node.default['osl-postfix']['main']['mydomain'] = node['osl-rt']['fqdn']

include_recipe 'osl-postfix::server'
include_recipe 'postfix::aliases'
include_recipe 'postfix::access'
include_recipe 'postfix::transports'
