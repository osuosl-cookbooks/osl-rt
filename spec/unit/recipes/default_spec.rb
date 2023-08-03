#
# Cookbook:: osl-rt
# Spec:: default
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

require_relative '../../spec_helper'

describe 'osl-rt::default' do
  cached(:subject) { chef_run }
  platform 'almalinux', '8'

  # Testing attributes
  default_attributes['osl-rt']['queues'].tap do |q|
    q['Support'] = 'support'
    q['Frontend Team'] = 'frontend'
    q['Backend Team'] = 'backend'
    q['DevOps Team'] = 'devops'
    q['Marketing Team'] = 'advertising'
    q['The Board Of Directors'] = 'board'
  end

  default_attributes['osl-rt']['db'].tap do |db|
    db['type'] = 'mysql'
    db['host'] = 'localhost'
    db['name'] = 'rt'
    db['username'] = 'rt-user'
    db['password'] = 'rt-password'
  end

  default_attributes['osl-rt']['fqdn'] = 'request.osuosl.intnet'
  default_attributes['osl-rt']['default'] = 'support'
  default_attributes['osl-rt']['root-password'] = 'my-epic-rt'

  # Postfix stubbing
  before do
    stub_command("/usr/bin/test /etc/alternatives/mta -ef /usr/sbin/sendmail.postfix").and_return(true)
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
  it {
    is_expected.to create_file('/opt/rt/etc/RT_SiteConfig.pm').with(
      group: 'apache',
      mode: '0640',
      sensitive: true
    )
  }

  # Root Account Config
  it {
    is_expected.to create_template('/root/.rtrc').with(
      source: 'rt/rtrc.erb',
      cookbook: 'osl-rt',
      mode: '0600',
      variables: { root_pass: 'my-epic-rt', domain: 'request.osuosl.intnet' },
      sensitive: true
    )
  }

  # Add RT to sbin PATH
  it {
    is_expected.to create_link('/usr/local/sbin/rt').with(
      to: '/opt/rt/bin/rt'
    )
  }

  # Set a new password for root
  it {
    is_expected.to run_execute('Set root password').with(
      command: 'mysql -u rt-user -prt-password -e \'UPDATE Users SET Password=md5("my-epic-rt") WHERE Name="root";\' rt && touch /opt/rt/chef/init-root-passwd',
    creates: '/opt/rt/chef/init-root-passwd',
    sensitive: true
    )
  }

  # Apache Configuration Website
  it {
    is_expected.to create_apache_app('request.osuosl.intnet').with(
      directory: '/opt/rt/share/html',
      include_config: true,
      include_directory: 'rt',
      include_name: 'rt',
    )
  }
  it {
    expect(chef_run.apache_app('request.osuosl.intnet')).to(
      notify('apache2_service[osuosl]').to(:restart).immediately
    )
  }

end
