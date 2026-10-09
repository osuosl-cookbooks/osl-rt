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

# SSL is terminated upstream by HAProxy; the backend listens on plain HTTP only.
%w(
  25
  80
).each do |p|
  describe port p do
    it { should be_listening }
  end
end

describe port 443 do
  it { should_not be_listening }
end

# mod_remoteip restores the real client IP from the HAProxy X-Forwarded-For header.
describe apache_conf('/etc/httpd/mods-available/remoteip.conf') do
  its('RemoteIPHeader') { should cmp 'X-Forwarded-For' }
end

# Session cleanup is on by default; full-text indexing is opt-in.
describe file('/etc/cron.d/rt-clean-sessions') do
  its('content') { should match %r{^15 3 \* \* \* apache /opt/rt/sbin/rt-clean-sessions --older 30D --skip-user$} }
end

describe file('/etc/cron.d/rt-fulltext-indexer') do
  it { should_not exist }
end

describe file('/opt/rt/etc/RT_SiteConfig.pm') do
  its('content') { should_not match /FullTextSearch/ }
end

# rt-clean-sessions runs as apache, which must be able to read RT's config.
describe command 'runuser -u apache -- env -C / /opt/rt/sbin/rt-clean-sessions --older 30D --skip-user' do
  its('exit_status') { should eq 0 }
end

describe http('http://127.0.0.1', headers: { Host: 'example.org' }, ssl_verify: false) do
  its('status') { should cmp 200 }
  # RT_SID cookie encodes the rtname, confirming RT serves this host.
  its('headers.Set-Cookie') { should match /RT_SID_example.org.80/ }
  # RT 5's redesigned login page drops the "RT for <rtname>" banner; assert on 4.4 only.
  its('body') { should match(/RT for example.org/) } if os[:release].to_i < 10
end

# RT major version via the package (the login page no longer carries it on RT 5).
describe package('request-tracker') do
  if os[:release].to_i >= 10
    its('version') { should match(/^5\./) }
  else
    its('version') { should match(/^4\.4/) }
  end
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
    # RT runs under apache; envelope sender is the queue address, not apache@<fqdn>.
    'Set($SetOutgoingMailFrom, 1);',
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
  its('header_checks') { should eq 'regexp:/etc/postfix/header_checks' }
  its('home_mailbox') { should eq 'Mail/' }
  its('mydestination') { should eq '$myhostname, localhost.$mydomain, localhost, example.org' }
  its('mailbox_command') { should eq '/usr/bin/procmail' }
  its('mailbox_size_limit') { should eq '0' }
  its('message_size_limit') { should eq '102400000' }
  if os[:release].to_i < 10
    its('transport_maps') { should eq 'hash:/etc/postfix/transport' }
  else
    its('transport_maps') { should eq 'lmdb:/etc/postfix/transport' }
  end
end

describe file('/etc/aliases') do
  it { should exist }
  [
    'frontend: support',
    'backend: support',
    'devops: support',
    'advertising: support',
    'board: support',
    'support: support',
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

# Sender-supplied X-Original-To could pick the dispatch queue or defeat the
# spam exemption; cleanup strips them all before local delivery stamps the real one.
describe file('/etc/postfix/header_checks') do
  its('content') { should match %r{^/\^X-Original-To:/ IGNORE$} }
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

# procmail's MAILDIR ($HOME/Mail) must exist, or local delivery can't write its
# LOGFILE ("Error while writing to ./from"). The folders procmail files into
# must be full maildirs owned at every level: an undeliverable (e.g. root-owned)
# one makes delivery fall through to the next recipe.
%w(
  Mail
  Mail/.Spam Mail/.Spam/cur Mail/.Spam/new Mail/.Spam/tmp
  Mail/.AutoReply Mail/.AutoReply/cur Mail/.AutoReply/new Mail/.AutoReply/tmp
).each do |dir|
  describe directory "/home/support/#{dir}" do
    it { should exist }
    its('owner') { should cmp 'support' }
    its('group') { should cmp 'support' }
    its('mode') { should cmp '0700' }
  end
end

# Mail/ itself must stay a plain directory: the rcfile ends in a catch-all,
# so a message landing in DEFAULT means a broken rcfile.
describe directory '/home/support/Mail/new' do
  it { should_not exist }
end

describe file '/etc/Muttrc.local' do
  its('content') { should match /This file was generated by Chef/ }
  its('content') { should match %r{^set folder="~/Mail"$} }
end

describe file '/home/support/.procmailrc' do
  it { should exist }
  its('owner') { should cmp 'support' }
  its('group') { should cmp 'support' }
  # RFC 3834 loop guards; auto-generated and Precedence bulk are excluded on
  # purpose (abuse feeds, cron jobs and vendor alerts must still ticket)
  its('content') { should match /^\* \^Auto-Submitted:\[ \t\]\*auto-\(replied\|notified\)$/ }
  its('content') { should match /^\* \^Precedence:\[ \t\]\*\(list\|junk\)$/ }
  its('content') { should match /^\* \^List-Id:$/ }
  # No abuse-type queue in this suite, so the spam rule carries no exemption
  its('content') { should_not include '* ! ^X-Original-To:' }
end

# Send a test ticket
describe command 'echo "Hello, I need help creating a Request Tracker instance" | mailx -r root@localhost -s "support-test" support@example.org' do
  its('exit_status') { should eq 0 }
end

# mailx returns once postfix queues the message; wait for rt-mailgate to ticket it
describe command "bash -c 'for i in $(seq 1 30); do HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject | grep -q support-test && exit 0; sleep 1; done; exit 1'" do
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

describe command "HOSTALIASES=/root/.rthost curl -sk -u 'root:my-epic-rt' http://rtlocal/REST/2.0/ticket/1 | jq .Subject" do
  its('exit_status') { should eq 0 }
  its('stdout') { should match /^"support-test"$/ }
end

# The test ticket above was delivered through procmail as the support user, so
# its logfile ($MAILDIR/from) was written there -- proving MAILDIR resolves.
# (Must come after the mail round-trip: no mail has flowed before it.)
describe file '/home/support/Mail/from' do
  it { should exist }
end

# Mail-injection checks run through the osl-rt-test-mail script (one root
# command; a multi-line command here would run its tail as the unprivileged ssh
# user). The script polls until the message arrives, then the one-line rt ls
# describes below assert what must NOT have happened.

# Spam is filed into .Spam/, never ticketed. If the maildir were undeliverable
# the rule would fall through and the spam would be ticketed instead.
describe command "/usr/local/bin/osl-rt-test-mail support@example.org spam-filing-test /home/support/Mail/.Spam/new 'X-Spam-Status: Yes, score=10.0 required=5.0'" do
  its('exit_status') { should eq 0 }
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject' do
  its('stdout') { should_not match /spam-filing-test/ }
end

# An incoming autoresponse must file into .AutoReply/, never reach rt-mailgate:
# RT auto-acks whatever gets that far and the two responders loop.
describe command "/usr/local/bin/osl-rt-test-mail support@example.org auto-replied-test /home/support/Mail/.AutoReply/new 'Auto-Submitted: auto-replied'" do
  its('exit_status') { should eq 0 }
end

# auto-generated is what abuse feeds and cron jobs set, and RFC 3834 5.2 bars
# it from a direct reply, so it cannot loop: it must still open a ticket.
describe command "/usr/local/bin/osl-rt-test-mail support@example.org auto-generated-test ticket 'Auto-Submitted: auto-generated'" do
  its('exit_status') { should eq 0 }
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject' do
  its('stdout') { should_not match /auto-replied-test/ }
end

# RT_SiteConfig.d drop-in: the snippet dropped by the test recipe is loaded by
# RT's own config loader, so $Timezone resolves to the value it set. This proves
# the do-glob appended to RT_SiteConfig.pm actually sources the directory.
describe file('/opt/rt/etc/RT_SiteConfig.d/99-dropin-test.pm') do
  it { should exist }
end

describe command %q{perl -I/opt/rt/lib -e 'use RT; RT::LoadConfig(); print RT->Config->Get("Timezone")'} do
  its('exit_status') { should eq 0 }
  its('stdout') { should cmp 'US/Pacific' }
end

# request-tracker-selinux: RT runs under its own policy, enforcing. Last in the
# file, so the mail and ticket checks above have exercised it.
describe selinux do
  it { should be_enforcing }
end

describe selinux.modules.where(name: 'request_tracker') do
  it { should be_installed }
  it { should be_enabled }
end

%w(httpd_can_sendmail httpd_can_network_connect_db).each do |b|
  describe selinux.booleans.where(name: b) do
    it { should be_on }
  end
end

describe file('/opt/rt/var/mason_data') do
  its('selinux_label') { should match /:httpd_sys_rw_content_t:/ }
end

# --input-logs: InSpec's stdin is a pipe, which ausearch would otherwise read
describe command("ausearch --input-logs -m avc,user_avc -ts boot -i 2>/dev/null | grep -E 'scontext=[^ ]*:(httpd_t|procmail_t):' | grep 'permissive=0'") do
  its('stdout') { should be_empty }
end
