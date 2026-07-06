#
# Cookbook:: osl-rt
# Resource:: default
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

resource_name :osl_request_tracker
provides :osl_request_tracker
unified_mode true

action_class do
  include OslRT::Cookbook::Helpers
end

# The site's fqdn. Authoritative -- overrides any 'fqdn' in the data bag -- and
# drives the Apache vhost, $rtname/$WebDomain, mydestination, the RT address
# regexp, and the queue correspond/comment addresses.
property :fqdn, String, name_property: true

# Name of the item in the fixed `request-tracker` data bag holding the rest of
# this instance's configuration: db creds, root password, queue map, mail-domain,
# plugins, lifecycles, etc.
property :data_bag, String, default: 'default'

action :create do
  # TLS terminates upstream at HAProxy; serve HTTP only, recover client IP via mod_remoteip.
  node.default['osl-apache']['listen'] = %w(80)
  node.default['osl-apache']['worker_mem'] = 215

  # Initalize the attributes, and overwrite the defaults. Loaded up front so the
  # DB-engine-specific setup below (client packages, DB guards) can branch on the
  # configured database type.
  rt_config = osl_rt_load_config_defaults
  rt_config = rt_config.merge(data_bag_item('request-tracker', new_resource.data_bag)) { |_key, _old_value, new_value| new_value }
  # The resource's fqdn is authoritative for the site identity, overriding the
  # data bag's (if any).
  rt_config['fqdn'] = new_resource.fqdn

  include_recipe 'osl-apache'
  include_recipe 'osl-apache::mod_remoteip'
  include_recipe 'osl-apache::mod_perl'
  include_recipe 'yum-osuosl'
  include_recipe 'perl'

  package %w(request-tracker mutt procmail)

  # Database client + Perl DBD driver for the configured engine. Postgres needs
  # DBD::Pg and the psql client (used by the DB guards below); MySQL pulls in the
  # mariadb client and DBD::MySQL via osl-mysql::client.
  if osl_rt_pg?(rt_config)
    package %w(perl-DBD-Pg postgresql)
  else
    include_recipe 'osl-mysql::client'
  end

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
    # Sources inside a resource action resolve against the CALLING cookbook, so
    # every template/cookbook_file here must name osl-rt explicitly.
    cookbook 'osl-rt'
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

    # procmail's MAILDIR/LOGFILE point at $HOME/Mail; create it so local delivery
    # doesn't fail to write its logfile ("Error while writing to ./from"). The
    # mailgate pipe runs either way, but without this every delivery logs an error.
    mail_home = mail_user == 'root' ? '/root' : "/home/#{mail_user}"
    directory "#{mail_home}/Mail" do
      owner mail_user
      group mail_user
      mode '0700'
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

  # Drop-in directory for additional site config, loaded by the do-glob appended to
  # RT_SiteConfig.pm above. A wrapping cookbook drops *.pm files here for config the
  # data-bag-driven generator can't express (e.g. external auth / SLA hashrefs).
  directory '/opt/rt/etc/RT_SiteConfig.d' do
    group 'apache'
    mode '0750'
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
    not_if osl_rt_db_guard(rt_config, osl_rt_schema_present_query(rt_config))
    sensitive true
    notifies :run, 'execute[Set root password]', :immediately
  end

  # Set the root password only on a fresh init (notified above), never on import.
  execute 'Set root password' do
    command osl_rt_set_root_password_command(rt_config)
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
    # rt.conf.erb lives in osl-rt; without this apache_app resolves the include
    # template against the cookbook that called osl_request_tracker.
    cookbook_include 'osl-rt'
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
      not_if osl_rt_db_guard(rt_config, "SELECT 1 FROM Queues WHERE Name='#{pt}'")
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

  # Mail server. All of RT's postfix configuration flows through a single
  # osl_postfix_server 'default' call (osl-postfix 3.x / postfix 7.x resource API):
  #   - main_settings: local delivery via procmail + the transport map. EL10 dropped
  #     the 'hash' (Berkeley DB) map type from postfix, so key the transport_maps db
  #     type off the platform (osl_rt_postfix_db_type).
  #   - access: allow-list the OSL smarthosts (use_access_maps renders /etc/postfix/access).
  #   - aliases: per-queue + self aliases (osl_postfix_server seeds the OSL system
  #     aliases underneath); use_alias_maps is forced on by osl_postfix_server.
  #   - transports: route every queue address (both delivery domains) to local
  #     delivery (use_transport_maps renders /etc/postfix/transport).
  postfix_aliases = osl_rt_postfix_aliases(rt_config)
  postfix_transports = osl_rt_postfix_transports(rt_config, domains)
  transport_maps = "#{osl_rt_postfix_db_type}:/etc/postfix/transport"

  osl_postfix_server 'default' do
    main_settings(
      'home_mailbox' => 'Mail/',
      'mailbox_command' => '/usr/bin/procmail',
      'mailbox_size_limit' => '0',
      'message_size_limit' => '102400000',
      'transport_maps' => transport_maps,
      'mydestination' => "$myhostname, localhost.$mydomain, localhost, #{domains.join(', ')}",
      'mydomain' => rt_config['fqdn']
    )
    access(
      '140.211.166.133' => 'OK', # smtp2.osuosl.org
      '140.211.166.136' => 'OK', # smtp3.osuosl.org
      '140.211.166.137' => 'OK', # smtp4.osuosl.org
      '140.211.166.138' => 'OK' # smtp1.osuosl.org
    )
    aliases postfix_aliases
    transports postfix_transports
    use_access_maps true
    use_transport_maps true
  end
end
