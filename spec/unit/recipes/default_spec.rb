#
# Cookbook:: osl-rt
# Spec:: default
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
        # Simulate a fresh database so the one-time DB/queue setup runs.
        stub_command(/SHOW TABLES LIKE 'Users'/).and_return(false)
        stub_command(/SELECT 1 FROM Queues WHERE Name=/).and_return(false)
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
        osl-apache osl-apache::mod_remoteip osl-apache::mod_perl
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

      # Drop-in config dir + the loader that sources it from RT_SiteConfig.pm
      it do
        is_expected.to create_directory('/opt/rt/etc/RT_SiteConfig.d').with(
          group: 'apache',
          mode: '0750'
        )
      end

      it do
        is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm')
          .with_content("do $_ for sort glob('/opt/rt/etc/RT_SiteConfig.d/*.pm');")
      end

      # RT Site Config generated content
      it do
        is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content(
          "Set($CorrespondAddress, 'support@example.org');"
        )
      end

      it do
        is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content(
          "Set($CommentAddress, 'support-comment@example.org');"
        )
      end

      it do
        is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content(
          "Set($RTAddressRegexp, '^((advertising|backend|board|devops|frontend|support)(-comment)?@(example\\.org))$');"
        )
      end

      # RT runs under apache; use the queue address as the envelope sender so
      # bounces don't dead-end at the local apache/root mailbox.
      it { is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content('Set($SetOutgoingMailFrom, 1);') }

      # REST2/Authen::Token are plugins on RT 4.4 (EL8/9) but core on RT 5 (EL10+).
      if p[:version].to_i >= 10
        it { is_expected.to_not render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content("Plugin('RT::Extension::REST2');") }
        it { is_expected.to_not render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content("Plugin('RT::Authen::Token');") }
      else
        it { is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content("Plugin('RT::Extension::REST2');") }
        it { is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content("Plugin('RT::Authen::Token');") }
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

      # RT Database Initalization (guarded by DB state, not a marker file)
      it do
        is_expected.to run_execute('init-db-rt').with(
          sensitive: true,
          command: <<~EOC
        /opt/rt/sbin/rt-setup-database \
          --action init \
          --dba rt-user \
          --dba-password rt-password \
          --skip-create
          EOC
        )
      end

      # init-db-rt sets the root password only on a fresh init (never on import)
      it do
        expect(chef_run.execute('init-db-rt')).to notify('execute[Set root password]').to(:run).immediately
      end

      # Root password: action :nothing (fired only by init-db-rt), sensitive, no marker.
      it do
        resource = chef_run.execute('Set root password')
        expect(resource.action).to eq([:nothing])
        expect(resource.sensitive).to be true
        expect(resource.command).to eq(<<~EOC)
        mysql -u rt-user \
          -prt-password \
          -e 'UPDATE Users \
            SET Password=md5("my-epic-rt") \
            WHERE Name="root";' \
          rt
        EOC
      end

      # The upgrade step is opt-in and absent unless 'db-upgrade' is set
      it { is_expected.to_not run_execute('upgrade-db-rt') }

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
            sensitive: true,
            command: <<~EOC
        HOSTALIASES=/root/.rthost \
        /opt/rt/bin/rt create -t queue set \
          name="#{pt}" correspondaddress="#{email}@example.org" \
          commentaddress="#{email}-comment@example.org"
            EOC
          )
        end
      end

      # Support mail account
      it do
        is_expected.to create_user('support').with(
          manage_home: true
        )
      end

      # procmail's MAILDIR ($HOME/Mail) must exist or local delivery logs errors.
      it do
        is_expected.to create_directory('/home/support/Mail').with(
          owner: 'support',
          group: 'support',
          mode: '0700'
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
            domain_match: '(example\.org)',
            internal_domain: 'rtlocal',
            mail_domain: 'example.org',
            error_email: 'root',
            forward_email: nil,
          }
        )
      end

      # No forwarding user or logo configured by default
      it { is_expected.to_not create_template('/home/support-gmail/.procmailrc') }
      it { is_expected.to_not create_user('support-gmail') }
      it { expect(chef_run.template('/home/support/.procmailrc').variables[:forward_email]).to be_nil }

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

  # Optional mail forwarding + branding (two-user split, off-box forward, logo)
  context 'with forwarding and branding' do
    cached(:chef_run) do
      ChefSpec::SoloRunner.new(ALMA_9) do |node|
        node.default['osl-rt']['data-bag'] = 'default'
      end.converge(described_recipe)
    end

    before do
      stub_command('/usr/bin/test /etc/alternatives/mta -ef /usr/sbin/sendmail.postfix').and_return(true)
      stub_command(/SHOW TABLES LIKE 'Users'/).and_return(false)
      stub_command(/SELECT 1 FROM Queues WHERE Name=/).and_return(false)
      stub_data_bag_item('request-tracker', 'default').and_return({
                                                                    'db-username': 'rt-user',
                                                                    'db-password': 'rt-password',
                                                                    'root-password': 'my-epic-rt',
                                                                    'user': 'support',
                                                                    'forward-email': 'archive@gapps.example.org',
                                                                    'forward-user': 'support-gmail',
                                                                    'logo': {
                                                                      'url': 'https://example.org/img/logo.png',
                                                                      'link': 'https://support.example.org/',
                                                                      'alt': 'Example Support',
                                                                    },
                                                                    'queues': {
                                                                      'Support': 'support',
                                                                    },
                                                                  })
    end

    # Dedicated forward user is created and its procmailrc forwards off-box
    it { is_expected.to create_user('support-gmail').with(manage_home: true) }
    it do
      is_expected.to create_template('/home/support-gmail/.procmailrc').with(
        source: 'forward.procmailrc.erb',
        cookbook: 'osl-rt',
        owner: 'support-gmail',
        group: 'support-gmail',
        variables: {
          mail_domain: 'example.org',
          forward_email: 'archive@gapps.example.org',
        }
      )
    end
    it { is_expected.to render_file('/home/support-gmail/.procmailrc').with_content('! archive@gapps.example.org') }

    # In split mode the RT user does NOT also CC the copy
    it { expect(chef_run.template('/home/support/.procmailrc').variables[:forward_email]).to be_nil }

    # Queue alias delivers to both the RT user and the forward user
    it { is_expected.to render_file('/etc/aliases').with_content('support: support, support-gmail') }

    # Logo is fetched and wired into the RT config
    it { is_expected.to create_directory('/opt/rt/share/static/images').with(recursive: true) }
    it do
      is_expected.to create_remote_file('/opt/rt/share/static/images/logo.png').with(
        source: 'https://example.org/img/logo.png'
      )
    end
    it do
      is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm')
        .with_content("Set($LogoURL, '/static/images/logo.png');")
        .with_content("Set($LogoLinkURL, 'https://support.example.org/');")
        .with_content("Set($LogoAltText, 'Example Support');")
    end
  end

  # Single-user CC-forward (forward-email without forward-user)
  context 'with single-user forwarding' do
    cached(:chef_run) do
      ChefSpec::SoloRunner.new(ALMA_9) do |node|
        node.default['osl-rt']['data-bag'] = 'default'
      end.converge(described_recipe)
    end

    before do
      stub_command('/usr/bin/test /etc/alternatives/mta -ef /usr/sbin/sendmail.postfix').and_return(true)
      stub_command(/SHOW TABLES LIKE 'Users'/).and_return(false)
      stub_command(/SELECT 1 FROM Queues WHERE Name=/).and_return(false)
      stub_data_bag_item('request-tracker', 'default').and_return({
                                                                    'db-username': 'rt-user',
                                                                    'db-password': 'rt-password',
                                                                    'root-password': 'my-epic-rt',
                                                                    'user': 'support',
                                                                    'forward-email': 'archive@gapps.example.org',
                                                                    'queues': {
                                                                      'Support': 'support',
                                                                    },
                                                                  })
    end

    # The RT user CCs a copy off-box; no separate forward user exists
    it { is_expected.to_not create_user('support-gmail') }
    it { expect(chef_run.template('/home/support/.procmailrc').variables[:forward_email]).to eq('archive@gapps.example.org') }
    it { is_expected.to render_file('/home/support/.procmailrc').with_content('! archive@gapps.example.org') }
  end

  # Opt-in upgrade: 'db-upgrade' = the DB's RT version, passed as --upgrade-from.
  context 'with db-upgrade set to a version' do
    cached(:chef_run) do
      ChefSpec::SoloRunner.new(ALMA_9) do |node|
        node.default['osl-rt']['data-bag'] = 'default'
      end.converge(described_recipe)
    end

    before do
      stub_command('/usr/bin/test /etc/alternatives/mta -ef /usr/sbin/sendmail.postfix').and_return(true)
      stub_command(/SHOW TABLES LIKE 'Users'/).and_return(false)
      stub_command(/SELECT 1 FROM Queues WHERE Name=/).and_return(false)
      stub_data_bag_item('request-tracker', 'default').and_return({
                                                                    'db-username': 'rt-user',
                                                                    'db-password': 'rt-password',
                                                                    'root-password': 'my-epic-rt',
                                                                    'user': 'support',
                                                                    'db-upgrade': '4.4.4',
                                                                    'queues': {
                                                                      'Support': 'support',
                                                                    },
                                                                  })
    end

    it do
      is_expected.to run_execute('upgrade-db-rt').with(
        creates: '/opt/rt/chef/upgrade-db-rt',
        cwd: '/opt/rt',
        sensitive: true,
        command: <<~EOC
        printf '\\ny\\n' | /opt/rt/sbin/rt-setup-database \
          --action upgrade \
          --upgrade-from 4.4.4 \
          --dba rt-user \
          --dba-password rt-password \
          > /opt/rt/chef/upgrade-db-rt.log 2>&1 && \
        touch /opt/rt/chef/upgrade-db-rt
        EOC
      )
    end
  end

  # RT user not among queue emails: still self-aliased so its mailbox gets mail
  # (overrides the system "support: postmaster" default).
  context 'with the RT user not among the queue emails' do
    cached(:chef_run) do
      ChefSpec::SoloRunner.new(ALMA_9) do |node|
        node.default['osl-rt']['data-bag'] = 'default'
      end.converge(described_recipe)
    end

    before do
      stub_command('/usr/bin/test /etc/alternatives/mta -ef /usr/sbin/sendmail.postfix').and_return(true)
      stub_command(/SHOW TABLES LIKE 'Users'/).and_return(false)
      stub_command(/SELECT 1 FROM Queues WHERE Name=/).and_return(false)
      stub_data_bag_item('request-tracker', 'default').and_return({
                                                                    'db-username': 'rt-user',
                                                                    'db-password': 'rt-password',
                                                                    'root-password': 'my-epic-rt',
                                                                    'user': 'support',
                                                                    'queues': {
                                                                      'Imported Queue': 'imported',
                                                                    },
                                                                  })
    end

    it { is_expected.to render_file('/etc/aliases').with_content('support: support') }
    it { is_expected.to render_file('/etc/aliases').with_content('imported: support') }
  end

  # PostgreSQL backend (db.type = Pg): DBD::Pg + psql client instead of the
  # mariadb client, and the DB guards/commands use psql.
  context 'with a postgresql backend' do
    cached(:chef_run) do
      ChefSpec::SoloRunner.new(ALMA_9) do |node|
        node.default['osl-rt']['data-bag'] = 'default'
      end.converge(described_recipe)
    end

    before do
      stub_command('/usr/bin/test /etc/alternatives/mta -ef /usr/sbin/sendmail.postfix').and_return(true)
      # Fresh DB so the one-time DB/queue setup runs (Postgres guards use psql).
      stub_command(/to_regclass/).and_return(false)
      stub_command(/SELECT 1 FROM Queues WHERE Name=/).and_return(false)
      stub_data_bag_item('request-tracker', 'default').and_return({
                                                                    'db': {
                                                                      'type': 'Pg',
                                                                      'host': 'localhost',
                                                                      'name': 'rt',
                                                                    },
                                                                    'db-username': 'rt-user',
                                                                    'db-password': 'rt-password',
                                                                    'root-password': 'my-epic-rt',
                                                                    'user': 'support',
                                                                    'queues': {
                                                                      'Support': 'support',
                                                                    },
                                                                  })
    end

    # Postgres pulls in the Perl driver + psql client, not the mariadb client.
    it { is_expected.to install_package(%w(perl-DBD-Pg postgresql)) }
    it { is_expected.to_not include_recipe('osl-mysql::client') }

    # RT is pointed at the Postgres backend.
    it { is_expected.to render_file('/opt/rt/etc/RT_SiteConfig.pm').with_content("Set($DatabaseType, 'Pg');") }

    # Root password is set via psql on a fresh init.
    it do
      resource = chef_run.execute('Set root password')
      expect(resource.action).to eq([:nothing])
      expect(resource.sensitive).to be true
      expect(resource.command).to eq(<<~EOC)
        PGPASSWORD='rt-password' psql -h localhost \
          -U rt-user \
          -c "UPDATE Users SET Password=md5('my-epic-rt') WHERE Name='root';" \
          rt
      EOC
    end
  end
end
