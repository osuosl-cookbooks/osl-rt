describe service 'httpd' do
  it { should be_enabled }
  it { should be_running }
end

describe service('postfix') do
  it { should be_enabled }
  it { should be_running }
end

%w(
  mutt
  procmail
  request-tracker
  perl-DBD-Pg
).each do |p|
  describe package p do
    it { should be_installed }
  end
end

# RT talks to PostgreSQL, listening on 5432 alongside the web/mail ports.
%w(
  25
  80
  5432
).each do |p|
  describe port p do
    it { should be_listening }
  end
end

# RT major version via the package (the login page no longer carries it on RT 5).
describe package('request-tracker') do
  if os[:release].to_i >= 10
    its('version') { should match(/^5\./) }
  else
    its('version') { should match(/^4\.4/) }
  end
end

# The site config points RT at the Postgres backend.
describe file '/opt/rt/etc/RT_SiteConfig.pm' do
  its('owner') { should eq 'root' }
  its('group') { should eq 'apache' }
  its('mode') { should cmp '0640' }
  [
    "Set($DatabaseType, 'Pg');",
    "Set($DatabaseHost, 'localhost');",
    "Set($DatabaseRTHost, 'localhost');",
    "Set($DatabaseName, 'rt');",
    "Set($DatabaseUser, 'rt-user');",
    "Set($DatabasePassword, 'rt-password');",
    'Set($SetOutgoingMailFrom, 1);',
  ].each do |line|
    its('content') { should match Regexp.escape line }
  end
end

# RT's schema was loaded into Postgres, so the Users table exists.
describe command "PGPASSWORD=rt-password psql -h localhost -U rt-user -tAc \"SELECT to_regclass('users')\" rt" do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/users/) }
end

describe command '/usr/local/sbin/rt help' do
  its('exit_status') { should eq 0 }
end

# Send a test ticket
describe command 'echo "Hello, I need help creating a Request Tracker instance" | mailx -r root@localhost -s "support-test" support@example.org' do
  its('exit_status') { should eq 0 }
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t queue -f Name' do
  its('exit_status') { should eq 0 }
  [
    'Frontend Team',
    'Backend Team',
    'DevOps Team',
    'Marketing Team',
    'The Board Of Directors',
    'Support',
  ].each do |line|
    its('stdout') { should match line }
  end
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject,Requestors,Queue' do
  its('exit_status') { should eq 0 }
  its('stdout') { should match /^1\s+Support\s+support-test\s+root@localhost$/ }
end

# REST login with the root password set during init proves the md5() password
# update ran against Postgres and RT authenticates against the Pg backend.
describe command "HOSTALIASES=/root/.rthost curl -sk -u 'root:my-epic-rt' http://rtlocal/REST/2.0/ticket/1 | jq .Subject" do
  its('exit_status') { should eq 0 }
  its('stdout') { should match /^"support-test"$/ }
end

# RT_SiteConfig.d drop-in is loaded by RT's own config loader.
describe command %q{perl -I/opt/rt/lib -e 'use RT; RT::LoadConfig(); print RT->Config->Get("Timezone")'} do
  its('exit_status') { should eq 0 }
  its('stdout') { should cmp 'US/Pacific' }
end
