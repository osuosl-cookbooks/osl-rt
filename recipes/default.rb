#
# Cookbook:: osl-rt
# Recipe:: default
#
# Copyright:: 2023-2026, Oregon State University
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

# TLS terminates upstream at HAProxy; serve HTTP only, recover client IP via mod_remoteip.
node.default['osl-apache']['listen'] = %w(80)
node.default['osl-apache']['worker_mem'] = 215

node.default['osl-postfix']['main']['home_mailbox'] = 'Mail/'
node.default['osl-postfix']['main']['mailbox_command'] = '/usr/bin/procmail'
node.default['osl-postfix']['main']['mailbox_size_limit'] = '0'
node.default['osl-postfix']['main']['message_size_limit'] = '102400000'
node.default['osl-postfix']['main']['transport_maps'] = "#{node['postfix']['db_type']}:/etc/postfix/transport"

node.default['postfix']['access']['140.211.166.133'] = 'OK' # smtp2.osuosl.org
node.default['postfix']['access']['140.211.166.136'] = 'OK' # smtp3.osuosl.org
node.default['postfix']['access']['140.211.166.137'] = 'OK' # smtp4.osuosl.org
node.default['postfix']['access']['140.211.166.138'] = 'OK' # smtp1.osuosl.org

include_recipe 'osl-apache'
include_recipe 'osl-apache::mod_remoteip'
include_recipe 'osl-apache::mod_perl'
include_recipe 'osl-mysql::client'
include_recipe 'yum-osuosl'
include_recipe 'perl'

package %w(request-tracker mutt procmail)

# Initalize the attributes, and overwrite the defaults
rt_config = osl_rt_load_config_defaults

rt_config = rt_config.merge(data_bag_item('request-tracker', node['osl-rt']['data-bag'])) { |_key, _old_value, new_value| new_value }

# Public email domain (defaults to the host fqdn). Mail may be delivered to
# either the fqdn or the public domain, so build a list of both for matching.
mail_domain = osl_rt_mail_domain(rt_config)
domains = osl_rt_domains(rt_config)

# Optional off-box forwarding. 'forward-email' alone: the RT user CCs a copy.
# Plus 'forward-user': a dedicated user gets the copy and forwards it (two-user split).
forward_email = rt_config['forward-email']
forward_user = rt_config['forward-user']

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

# RT user always exists; the forward user only with the optional two-user split.
[rt_config['user'], forward_user].compact.each do |mail_user|
  user mail_user do
    manage_home true
  end
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

# Optional custom logo, fetched into RT's static images dir; $LogoURL is set in
# osl_rt_init_config.
if rt_config['logo'] && rt_config['logo']['url']
  directory '/opt/rt/share/static/images' do
    recursive true
  end

  remote_file "/opt/rt/share/static/images/#{::File.basename(rt_config['logo']['url'])}" do
    source rt_config['logo']['url']
    mode '0644'
  end
end

# Initialize the DB only if RT's schema is absent (safe to import an existing DB);
# the root password is set on a fresh init via the notify below.
execute 'init-db-rt' do
  command <<~EOC
    /opt/rt/sbin/rt-setup-database \
      --action init \
      --dba #{rt_config['db-username']} \
      --dba-password #{rt_config['db-password']} \
      --skip-create
  EOC
  not_if osl_rt_mysql_guard(rt_config, "SHOW TABLES LIKE 'Users'")
  sensitive true
  notifies :run, 'execute[Set root password]', :immediately
end

# Set the root password only on a fresh init (notified above), never on import.
execute 'Set root password' do
  command <<~EOC
    mysql -u #{rt_config['db-username']} \
      -p#{rt_config['db-password']} \
      -e 'UPDATE Users \
        SET Password=md5("#{rt_config['root-password']}") \
        WHERE Name="root";' \
      #{rt_config['db']['name']}
  EOC
  action :nothing
  sensitive true
end

# Opt-in schema upgrade (imported DB or after a package upgrade). 'db-upgrade' is
# the DB's current RT version, passed as --upgrade-from. The upgrade is interactive
# (stop-at version + "proceed"), so feed a blank line + "y"; output is logged. Runs
# once (remove the marker to re-run). Back up before enabling.
if rt_config['db-upgrade']
  execute 'upgrade-db-rt' do
    command <<~EOC
      printf '\\ny\\n' | /opt/rt/sbin/rt-setup-database \
        --action upgrade \
        --upgrade-from #{rt_config['db-upgrade']} \
        --dba #{rt_config['db-username']} \
        --dba-password #{rt_config['db-password']} \
        > /opt/rt/chef/upgrade-db-rt.log 2>&1 && \
      touch /opt/rt/chef/upgrade-db-rt
    EOC
    # upgrade reads the cwd-relative ./etc/upgrade, so run from the RT base dir.
    cwd '/opt/rt'
    creates '/opt/rt/chef/upgrade-db-rt'
    sensitive true
  end
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

# Create only queues missing from the DB; existing queues (and tickets) are untouched.
rt_config['queues'].each do |pt, email|
  next unless email
  execute "Creating RT queue for #{pt}" do
    command <<~EOC
    HOSTALIASES=/root/.rthost \
    /opt/rt/bin/rt create -t queue set \
      name="#{pt}" correspondaddress="#{email}@#{mail_domain}" \
      commentaddress="#{email}-comment@#{mail_domain}"
    EOC
    not_if osl_rt_mysql_guard(rt_config, "SELECT 1 FROM Queues WHERE Name='#{pt}'")
    sensitive true
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
    # Regex group matching any delivery domain, with literal dots escaped
    domain_match: "(#{domains.map { |d| d.gsub('.', '\\.') }.join('|')})",
    internal_domain: rt_config['internal-domain'],
    mail_domain: mail_domain,
    # Where RT-unprocessable mail is forwarded (default local root).
    error_email: rt_config['failed-email'] || 'root',
    # CC off-box only in single-user mode; the forward user handles it otherwise.
    forward_email: forward_user ? nil : forward_email
  )
end

# Optional forward user (two-user split): gets a copy of queue mail and forwards it.
if forward_user
  user_home = forward_user == 'root' ? '/root' : "/home/#{forward_user}"
  template "#{user_home}/.procmailrc" do
    source 'forward.procmailrc.erb'
    cookbook 'osl-rt'
    owner forward_user
    group forward_user
    variables(
      mail_domain: mail_domain,
      forward_email: forward_email
    )
  end
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

node.default['osl-postfix']['main']['mydestination'] = "$myhostname, localhost.$mydomain, localhost, #{domains.join(', ')}"
node.default['osl-postfix']['main']['mydomain'] = rt_config['fqdn']

include_recipe 'osl-postfix::server'
include_recipe 'postfix::aliases'
include_recipe 'postfix::access'
include_recipe 'postfix::transports'
