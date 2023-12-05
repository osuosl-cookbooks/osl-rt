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
).each do |p|
  describe package p do
    it { should be_installed }
  end
end

%w(
  25
  80
  443
).each do |p|
  describe port p do
    it { should be_listening }
  end
end

describe http('http://127.0.0.1', headers: { Host: 'example.org' }, ssl_verify: false) do
  its('status') { should cmp 200 }
  its('headers.Set-Cookie') { should match /RT_SID_example.org.80/ }
  its('body') { should match /RT for example.org/ }
  its('body') { should match /RT 4.4/ }
end

describe file '/root/.rtrc' do
  its('owner') { should eq 'root' }
  its('group') { should eq 'root' }
  its('mode') { should cmp '0600' }
  its('content') { should match %r{^server http://rtlocal$} }
  its('content') { should match /^user root$/ }
  its('content') { should match /^passwd my-epic-rt$/ }
end

describe file '/opt/rt/etc/RT_SiteConfig.pm' do
  its('owner') { should eq 'root' }
  its('group') { should eq 'apache' }
  its('mode') { should cmp '0640' }
  [
    "Set($DatabaseHost, 'localhost');",
    "Set($DatabaseRTHost, 'localhost');",
    "Set($DatabaseUser, 'rt-user');",
    "Set($DatabasePassword, 'rt-password');",
  ].each do |line|
    its('content') { should match Regexp.escape line }
  end

  its('content') do
    should match /advertising\|backend\|board\|devops\|frontend\|support/
  end
end

describe command '/usr/local/sbin/rt help' do
  its('exit_status') { should eq 0 }
end

describe file '/usr/local/sbin/rt' do
  it { should be_symlink }
  its('link_path') { should eq '/opt/rt/bin/rt' }
end

describe postfix_conf('/etc/postfix/main.cf') do
  its('home_mailbox') { should eq 'Mail/' }
  its('mydestination') { should eq '$myhostname, localhost.$mydomain, localhost, example.org' }
  its('mailbox_command') { should eq '/usr/bin/procmail' }
  its('mailbox_size_limit') { should eq '0' }
  its('message_size_limit') { should eq '102400000' }
  its('transport_maps') { should eq 'hash:/etc/postfix/transport' }
end

describe file('/etc/aliases') do
  it { should exist }
  [
    'frontend: "support"',
    'backend: "support"',
    'devops: "support"',
    'advertising: "support"',
    'board: "support"',
    'support: "support"',
  ].each do |line|
    its('content') { should match Regexp.escape line }
  end
end

describe file('/etc/postfix/access') do
  it { should exist }
  [
    '140.211.166.133 OK',
    '140.211.166.136 OK',
    '140.211.166.137 OK',
    '140.211.166.138 OK',
  ].each do |line|
    its('content') { should match Regexp.escape line }
  end
end

describe file('/etc/postfix/transport') do
  it { should exist }
  [
    'advertising@example.org local:$myhostname',
    'advertising-comment@example.org local:$myhostname',
    'backend@example.org local:$myhostname',
    'backend-comment@example.org local:$myhostname',
    'board@example.org local:$myhostname',
    'board-comment@example.org local:$myhostname',
    'devops@example.org local:$myhostname',
    'devops-comment@example.org local:$myhostname',
    'frontend@example.org local:$myhostname',
    'frontend-comment@example.org local:$myhostname',
    'support@example.org local:$myhostname',
    'support-comment@example.org local:$myhostname',
  ].each do |line|
    its('content') { should match Regexp.escape line }
  end
end

describe command 'postfix check' do
  its('stderr') { should_not match /warning/ }
end

describe apache_conf('/etc/httpd/sites-enabled/example.org.conf') do
  its('ServerName') { should include 'example.org' }
  its('DocumentRoot') { should include '/opt/rt/share/html' }
  its('Include') { should include '/etc/httpd/sites-available/rt_include.conf' }
end

describe apache_conf('/etc/httpd/sites-available/rt_include.conf') do
  its('RewriteEngine') { should cmp 'On' }
  its('RewriteRule') { should cmp '^/([0-9]+)$ https://example.org/Ticket/Display.html?id=$1 [QSA,L]' }
  its('AddDefaultCharset') { should cmp 'UTF-8' }
end

describe user 'support' do
  it { should exist }
  its('group') { should cmp 'support' }
  its('home') { should cmp '/home/support' }
end

describe directory '/home/support' do
  it { should exist }
  its('owner') { should cmp 'support' }
  its('group') { should cmp 'support' }
end

describe file '/etc/Muttrc.local' do
  its('content') { should match /This file was generated by Chef/ }
  its('content') { should match %r{^set folder="~/Mail"$} }
end

describe file '/home/support/.procmailrc' do
  it { should exist }
  its('owner') { should cmp 'support' }
  its('group') { should cmp 'support' }
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

describe command "HOSTALIASES=/root/.rthost curl -sk -u 'root:my-epic-rt' http://rtlocal/REST/2.0/ticket/1 | jq .Subject" do
  its('exit_status') { should eq 0 }
  its('stdout') { should match /^"support-test"$/ }
end
