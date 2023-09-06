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

node.default['osl-apache']['listen'] = %w(80 443)
node.default['osl-apache']['worker_mem'] = 215

node.default['osl-postfix']['main']['home_mailbox'] = 'Mail/'
node.default['osl-postfix']['main']['mailbox_command'] = '/usr/bin/procmail'
node.default['osl-postfix']['main']['mailbox_size_limit'] = '0'
node.default['osl-postfix']['main']['message_size_limit'] = '102400000'
node.default['osl-postfix']['main']['transport_maps'] = 'hash:/etc/postfix/transport'

node.default['postfix']['access']['140.211.166.133'] = 'OK' # smtp2.osuosl.org
node.default['postfix']['access']['140.211.166.136'] = 'OK' # smtp3.osuosl.org
node.default['postfix']['access']['140.211.166.137'] = 'OK' # smtp4.osuosl.org
node.default['postfix']['access']['140.211.166.138'] = 'OK' # smtp1.osuosl.org

node.default['osl-rt']['lifecycles'] = {}
node.default['osl-rt']['plugins'] = {}

include_recipe 'osl-apache'
include_recipe 'osl-apache::mod_ssl'
include_recipe 'osl-apache::mod_perl'
include_recipe 'osl-mysql::client'
include_recipe 'yum-osuosl'
include_recipe 'perl'

package %w(request-tracker mutt procmail)

# Root Account
template '/root/.rtrc' do
  source 'rt/rtrc.erb'
  cookbook 'osl-rt'
  mode '0600'
  sensitive true
  variables(root_pass: node['osl-rt']['root-password'])
end

# Set up user for mail
user node['osl-rt']['default'] do
  manage_home true
end

# User defined Hostalias file in order to patch into the RT site with the RT CLI/procmail
['root', "/home/#{node['osl-rt']['default']}"].each do |file_path|
  file "/#{file_path}/.rthost" do
    content <<~EOF
      rtlocal localhost
    EOF
  end
end

# Add the RT command to the root user's PATH
link '/usr/local/sbin/rt' do
  to '/opt/rt/bin/rt'
end

# RT Initial Configuration.
file '/opt/rt/etc/RT_SiteConfig.pm' do
  # Use the init function in order to generate the perl config file
  content osl_rt_init_config
  group 'apache'
  mode '0640'
  sensitive true
  notifies :reload, 'apache2_service[osuosl]'
end

# Initalize the DB
execute 'init-db-rt' do
  command <<~EOH
    /opt/rt/sbin/rt-setup-database \
      --action init \
      --dba #{node['osl-rt']['db']['username']} \
      --dba-password #{node['osl-rt']['db']['password']} \
      --skip-create && \
    touch /opt/rt/chef/init-db-rt
  EOH
  creates '/opt/rt/chef/init-db-rt'
  sensitive false
end

# Set a new password for root
execute 'Set root password' do
  command <<~EOH
    mysql -u #{node['osl-rt']['db']['username']} \
      -p#{node['osl-rt']['db']['password']} \
      -e 'UPDATE Users \
        SET Password=md5(\"#{node['osl-rt']['root-password']}\") \
        WHERE Name=\"root\";' \
      #{node['osl-rt']['db']['name']} && \
    touch /opt/rt/chef/init-root-passwd
  EOH
  creates '/opt/rt/chef/init-root-passwd'
  sensitive true
end

# Set up web app
apache_app node['osl-rt']['fqdn'] do
  directory '/opt/rt/share/html'
  include_config true
  include_template true
  include_directory 'rt'
  include_name 'rt'
  include_params('domain': node['osl-rt']['fqdn'])
  server_aliases ['rtlocal']
end

# Forcefully reload Apache during the initial run, in order to allow for setting up the queues properly.
# apache_app does not reload httpd after being ran, meaning the website is unavailable until after the converge has finished.
service 'httpd' do
  action :reload
  not_if { ::File.exist?('/var/spool/mail/nobody') }
end

# Set up the queues in RT
node['osl-rt']['queues'].each do |pt, email|
  execute "Creating RT queue for #{pt}" do
    command <<~EOC
    HOSTALIASES=/root/.rthost \
    /opt/rt/bin/rt create -t queue set \
      name="#{pt}" correspondaddress="#{email}@#{node['osl-rt']['fqdn']}" \
      commentaddress="#{email}-comment@#{node['osl-rt']['fqdn']}" \
      && touch /tmp/#{email}done
    EOC
    creates "/tmp/#{email}done"
  end
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
    fqdn: node['osl-rt']['fqdn'],
    domain_name: 'rtlocal',
    error_email: node['platform']
  )
end

# Set up procmail in the default user's account
file '/etc/procmailrc' do
  content "DEFAULT=$HOME/Mail/\nPATH=/usr/local/bin:/usr/bin:/bin\nMAILDIR=$HOME/Mail/\nLOGFILE=$MAILDIR/from"
end

# Mutt Configuration
cookbook_file '/etc/Muttrc.local' do
  source 'rt/Muttrc.local'
  cookbook 'osl-rt'
end

node.default['osl-postfix']['main']['mydestination'] = "$myhostname, localhost.$mydomain, localhost, #{node['osl-rt']['fqdn']}"
node.default['osl-postfix']['main']['mydomain'] = node['osl-rt']['fqdn']

include_recipe 'osl-postfix::server'
include_recipe 'postfix::aliases'
include_recipe 'postfix::access'
include_recipe 'postfix::transports'
