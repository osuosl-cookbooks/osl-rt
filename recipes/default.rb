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

include_recipe 'osl-apache'
include_recipe 'osl-apache::mod_ssl'
include_recipe 'osl-apache::mod_perl'
include_recipe 'osl-mysql::client'
include_recipe 'yum-osuosl'
include_recipe 'perl'

package %w(request-tracker mutt procmail)

# Initalize the attributes, and overwrite the defaults
rt_config = osl_rt_load_config_defaults

rt_config = rt_config.merge(data_bag_item('request-tracker', node['osl-rt']['data-bag'])) { |_key, _old_value, new_value| new_value }

# Root Account
template '/root/.rtrc' do
  source 'rtrc.erb'
  mode '0600'
  sensitive true
  variables(
    root_pass: rt_config['root-password'],
    domain: rt_config['internal-domain']
  )
end

# Set up user for mail
user rt_config['user'] do
  manage_home true
end

# User defined Hostalias file in order to patch into the RT site with the RT CLI/procmail
[
  'root',
  "/home/#{rt_config['user']}",
].each do |file_path|
  file "/#{file_path}/.rthost" do
    content <<~EOF
      #{rt_config['internal-domain']} localhost
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
  content osl_rt_init_config(rt_config)
  group 'apache'
  mode '0640'
  sensitive true
  notifies :reload, 'apache2_service[osuosl]'
end

# Initalize the DB
execute 'init-db-rt' do
  command <<~EOC
    /opt/rt/sbin/rt-setup-database \
      --action init \
      --dba #{rt_config['db-username']} \
      --dba-password #{rt_config['db-password']} \
      --skip-create && \
    touch /opt/rt/chef/init-db-rt
  EOC
  creates '/opt/rt/chef/init-db-rt'
  sensitive true
end

# Set a new password for root
execute 'Set root password' do
  command <<~EOC
    mysql -u #{rt_config['db-username']} \
      -p#{rt_config['db-password']} \
      -e 'UPDATE Users \
        SET Password=md5(\"#{rt_config['root-password']}\") \
        WHERE Name=\"root\";' \
      #{rt_config['db']['name']} && \
    touch /opt/rt/chef/init-root-passwd
  EOC
  creates '/opt/rt/chef/init-root-passwd'
  sensitive true
end

# Set up web app
apache_app rt_config['fqdn'] do
  directory '/opt/rt/share/html'
  include_config true
  include_template true
  include_name 'rt'
  include_params('domain': rt_config['fqdn'])
  server_aliases [rt_config['internal-domain']]
end

# Forcefully reload Apache during the initial run, in order to allow for setting up the queues properly.
# apache_app does not reload httpd after being ran, meaning the website is unavailable until after the converge has finished.
service 'httpd' do
  action :reload
  not_if { ::File.exist?('/etc/procmailrc') }
end

# Set up the queues in RT
rt_config['queues'].each do |pt, email|
  next unless email
  execute "Creating RT queue for #{pt}" do
    command <<~EOC
    HOSTALIASES=/root/.rthost \
    /opt/rt/bin/rt create -t queue set \
      name="#{pt}" correspondaddress="#{email}@#{rt_config['fqdn']}" \
      commentaddress="#{email}-comment@#{rt_config['fqdn']}" \
      && touch /tmp/#{email}done
    EOC
    creates "/tmp/#{email}done"
  end
end

# Set up the procmail
template "/home/#{rt_config['user']}/.procmailrc" do
  source 'support.procmailrc.erb'
  cookbook 'osl-rt'
  owner rt_config['user']
  group rt_config['user']
  variables(
    rt_queues: rt_config['queues'],
    fqdn: rt_config['fqdn'],
    domain_name: rt_config['internal-domain'],
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

node.default['osl-postfix']['main']['mydestination'] = "$myhostname, localhost.$mydomain, localhost, #{rt_config['fqdn']}"
node.default['osl-postfix']['main']['mydomain'] = rt_config['fqdn']

include_recipe 'osl-postfix::server'
include_recipe 'postfix::aliases'
include_recipe 'postfix::access'
include_recipe 'postfix::transports'
