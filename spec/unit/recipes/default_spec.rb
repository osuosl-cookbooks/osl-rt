#
# Cookbook:: osl-rt
# Spec:: default
#
# Copyright:: 2023-2025, Oregon State University
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

require_relative '../../spec_helper'

describe 'osl-rt::default' do
  ALL_PLATFORMS.each do |p|
    context "#{p[:platform]} #{p[:version]}" do
      cached(:chef_run) do
        ChefSpec::SoloRunner.new(p) do |node|
          node.default['osl-rt']['data-bag'] = 'default'
        end.converge(described_recipe)
      end

      # Stubbed commands
      before do
        stub_command('/usr/bin/test /etc/alternatives/mta -ef /usr/sbin/sendmail.postfix').and_return(true)
        stub_data_bag_item('request-tracker', 'default').and_return({
          'db-username': 'rt-user',
          'db-password': 'rt-password',
          'root-password': 'my-epic-rt',
          'user': 'support',
          'queues': {
            'Support': 'support',
            'Frontend Team': 'frontend',
            'Backend Team': 'backend',
            'DevOps Team': 'devops',
            'Marketing Team': 'advertising',
            'The Board Of Directors': 'board',
          },
          'plugins': ['RT::Extension::REST2', 'RT::Authen::Token'],
          'lifecycles': {
            'default': {
              'initial': [ 'new' ],
              'active': [ 'open' ],
              'inactive': %w(stalled resolved rejected deleted),

              'defaults': {
                'on_create': 'new',
                'on_merge': 'resolved',
                'approved': 'open',
                'denied': 'rejected',
              },

              'transitions': {
                '': %w(new open resolved),
                'new': %w(open stalled resolved rejected deleted),
                'open': %w(new stalled resolved rejected deleted),
                'stalled': %w(new open rejected resolved deleted),
                'resolved': %w(new open stalled rejected deleted),
                'rejected': %w(new open stalled resolved deleted),
                'deleted': %w(new open stalled rejected resolved),
              },

              'rights': {
                '* -> deleted': 'DeleteTicket',
                '* -> *': 'ModifyTicket',
              },

              'actions': {
                'new -> open': {
                  'label': 'Open It',
                  'update': 'Respond',
                },
              },
            },
          },
        })
      end

      # Recipes dependencies
      %w(
        osl-apache osl-apache::mod_ssl osl-apache::mod_perl
        osl-mysql::client yum-osuosl perl
        osl-postfix::server postfix::aliases
        postfix::access postfix::transports
      ).each do |r|
        it { is_expected.to include_recipe(r) }
      end

      # RT Site Config
      it do
        is_expected.to create_file('/opt/rt/etc/RT_SiteConfig.pm').with(
          group: 'apache',
          mode: '0640',
          sensitive: true
        )
      end

      # Root Account Config
      it do
        is_expected.to create_template('/root/.rtrc').with(
          source: 'rtrc.erb',
          mode: '0600',
          variables: { root_pass: 'my-epic-rt', domain: 'rtlocal' },
          sensitive: true
        )
      end

      # Add RT to sbin PATH
      it do
        is_expected.to create_link('/usr/local/sbin/rt').with(
          to: '/opt/rt/bin/rt'
        )
      end

      # RT Database Initalization
      it do
        is_expected.to run_execute('init-db-rt').with(
          creates: '/opt/rt/chef/init-db-rt',
          sensitive: true,
          command: <<~EOC
        /opt/rt/sbin/rt-setup-database \
          --action init \
          --dba rt-user \
          --dba-password rt-password \
          --skip-create && \
        touch /opt/rt/chef/init-db-rt
          EOC
        )
      end

      # Set a new password for root
      it do
        is_expected.to run_execute('Set root password').with(
        creates: '/opt/rt/chef/init-root-passwd',
        sensitive: true,
        command: <<~EOC
        mysql -u rt-user \
          -prt-password \
          -e 'UPDATE Users \
            SET Password=md5("my-epic-rt") \
            WHERE Name="root";\' \
          rt && \
        touch /opt/rt/chef/init-root-passwd
        EOC
      )
      end

      # Apache Configuration Website
      it do
        is_expected.to create_apache_app('example.org').with(
          directory: '/opt/rt/share/html',
          include_config: true,
          include_template: true,
          include_name: 'rt',
          include_params: { 'domain': 'example.org' },
          server_aliases: ['rtlocal']
        )
      end

      # RT queue setup
      it do
        {
          'Support': 'support',
          'Frontend Team': 'frontend',
          'Backend Team': 'backend',
          'DevOps Team': 'devops',
          'Marketing Team': 'advertising',
          'The Board Of Directors': 'board',
        }.each do |pt, email|
          is_expected.to run_execute("Creating RT queue for #{pt}").with(
            command: <<~EOC,
        HOSTALIASES=/root/.rthost \
        /opt/rt/bin/rt create -t queue set \
          name="#{pt}" correspondaddress="#{email}@example.org" \
          commentaddress="#{email}-comment@example.org" \
          && touch /tmp/#{email}done
            EOC
            creates: "/tmp/#{email}done"
          )
        end
      end

      # Support mail account
      it do
        is_expected.to create_user('support').with(
          manage_home: true
        )
      end

      # Support Procmail setup
      it do
        is_expected.to create_template('/home/support/.procmailrc').with(
          source: 'support.procmailrc.erb',
          cookbook: 'osl-rt',
          owner: 'support',
          group: 'support',
          variables: {
            rt_queues: {
              'Support' => 'support',
              'Frontend Team' => 'frontend',
              'Backend Team' => 'backend',
              'DevOps Team' => 'devops',
              'Marketing Team' => 'advertising',
              'The Board Of Directors' => 'board',
            },
            domain_name: 'rtlocal',
            'fqdn': 'example.org',
            error_email: 'almalinux',
          }
        )
      end

      # Default Procmail setup
      it do
        is_expected.to create_file('/etc/procmailrc').with(
          content: "DEFAULT=$HOME/Mail/\nPATH=/usr/local/bin:/usr/bin:/bin\nMAILDIR=$HOME/Mail/\nLOGFILE=$MAILDIR/from"
        )
      end

      # Global Mutt Configuration
      it do
        is_expected.to create_cookbook_file('/etc/Muttrc.local').with(
          source: 'rt/Muttrc.local',
          cookbook: 'osl-rt'
        )
      end
    end
  end
end
