# Verifies the two-domain (mail-domain != fqdn) + logo setup.

describe service('httpd') do
  it { should be_enabled }
  it { should be_running }
end

describe service('postfix') do
  it { should be_enabled }
  it { should be_running }
end

# SSL terminated upstream; backend is HTTP-only with mod_remoteip.
describe port 443 do
  it { should_not be_listening }
end

describe apache_conf('/etc/httpd/mods-available/remoteip.conf') do
  its('RemoteIPHeader') { should cmp 'X-Forwarded-For' }
end

# RT config: web/host identity uses the fqdn, mail identity uses mail-domain.
describe file('/opt/rt/etc/RT_SiteConfig.pm') do
  [
    "Set($rtname, 'support.example.org');",
    "Set($WebDomain, 'support.example.org');",
    "Set($Organization, 'example.org');",
    "Set($CorrespondAddress, 'support@example.org');",
    "Set($CommentAddress, 'support-comment@example.org');",
    # RTAddressRegexp must accept BOTH delivery domains
    "Set($RTAddressRegexp, '^((abuse|support|systems)(-comment)?@(support\\.example\\.org|example\\.org))$');",
    # Branding wired from the 'logo' data-bag key
    "Set($LogoURL, '/static/images/osl-rt-test-logo.png');",
    "Set($LogoLinkURL, 'https://support.example.org/');",
    "Set($LogoAltText, 'Example Support');",
  ].each do |line|
    its('content') { should include line }
  end
end

# Logo fetched into RT's static images dir
describe file('/opt/rt/share/static/images/osl-rt-test-logo.png') do
  it { should be_file }
end

describe user('support') do
  it { should exist }
end

# The folders procmail files into must be full maildirs: an undeliverable one
# falls through to the next recipe.
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

# RT user feeds rt-mailgate for both domains
describe file('/home/support/.procmailrc') do
  # domain_match group accepts both delivery domains (dots escaped for procmail)
  its('content') { should include 'X-Original-To: support@(support\.example\.org|example\.org)' }
  its('content') { should include '/opt/rt/bin/rt-mailgate --queue "Support" --action correspond --url http://rtlocal' }
  # abuse@ is exempt from the spam diversion: reports quote what they report
  its('content') do
    should match(
      /^\* ! \^X-Original-To: \(abuse\)\(-comment\)\?@\(support\\\.example\\\.org\|example\\\.org\)\n\* \^X-Spam-Status: Yes$/
    )
  end
  # RFC 3834 loop guards; auto-generated and Precedence bulk excluded on purpose
  its('content') { should match /^\* \^Auto-Submitted:\[ \t\]\*auto-\(replied\|notified\)$/ }
  its('content') { should match /^\* \^Precedence:\[ \t\]\*\(list\|junk\)$/ }
  its('content') { should match /^\* \^List-Id:$/ }
end

describe file('/etc/aliases') do
  its('content') { should match(/^support: support$/) }
  its('content') { should match(/^abuse: support$/) }
end

# Transports exist for every delivery domain
describe file('/etc/postfix/transport') do
  [
    'support@support.example.org local:$myhostname',
    'support@example.org local:$myhostname',
    'support-comment@support.example.org local:$myhostname',
    'support-comment@example.org local:$myhostname',
    'systems@support.example.org local:$myhostname',
    'systems@example.org local:$myhostname',
    'abuse@support.example.org local:$myhostname',
    'abuse@example.org local:$myhostname',
  ].each do |line|
    its('content') { should match Regexp.escape(line) }
  end
end

# Only the fqdn is local; queue mail at example.org reaches RT by transport
describe postfix_conf('/etc/postfix/main.cf') do
  its('mydestination') do
    should eq '$myhostname, localhost.$mydomain, localhost, support.example.org'
  end
end

# Anyone else at example.org goes to the relay rather than bouncing locally:
# probe a non-queue address and wait for postfix to log where it routed it
describe command(%q(sh -c 'sendmail -bv not-a-queue@example.org; for i in $(seq 30); do journalctl -u postfix --no-pager | grep -q "to=<not-a-queue@example.org>" && break; sleep 1; done; journalctl -u postfix --no-pager | grep "to=<not-a-queue@example.org>"')) do
  its('stdout') { should match /to=<not-a-queue@example\.org>/ }
  its('stdout') { should_not match /relay=local/ }
end

# Mail round-trip: a ticket to the mail-domain reaches RT.
describe command 'echo "Need help with the two-domain setup" | mailx -r root@localhost -s "two-domain-test" support@example.org' do
  its('exit_status') { should eq 0 }
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t queue -f Name' do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Support/) }
  its('stdout') { should match(/Systems Team/) }
  its('stdout') { should match(/Abuse/) }
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject,Queue' do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/two-domain-test/) }
end

# Mail-injection checks run through the osl-rt-test-mail script (one root
# command; a multi-line command here would run its tail as the unprivileged ssh
# user). The script polls until the message arrives, then the one-line rt ls
# describe below asserts what must NOT have happened.

# Spam to a normal queue files into .Spam/ and never tickets
describe command "/usr/local/bin/osl-rt-test-mail support@example.org two-domain-spam-test /home/support/Mail/.Spam/new 'X-Spam-Status: Yes, score=10.0 required=5.0'" do
  its('exit_status') { should eq 0 }
end

# Spam-tagged mail to abuse@ must still ticket: reports quote the spam they report
describe command "/usr/local/bin/osl-rt-test-mail abuse@example.org abuse-exemption-test ticket 'X-Spam-Status: Yes, score=10.0 required=5.0'" do
  its('exit_status') { should eq 0 }
end

# A sender-supplied X-Original-To must not defeat the abuse exemption (or pick
# the queue): cleanup strips it before local delivery stamps the real one.
describe command "/usr/local/bin/osl-rt-test-mail support@example.org forged-xoriginalto-test /home/support/Mail/.Spam/new 'X-Original-To: abuse@example.org' 'X-Spam-Status: Yes, score=10.0 required=5.0'" do
  its('exit_status') { should eq 0 }
end

# An incoming autoresponse files into .AutoReply/ and never reaches rt-mailgate
describe command "/usr/local/bin/osl-rt-test-mail support@example.org two-domain-autoreply-test /home/support/Mail/.AutoReply/new 'Auto-Submitted: auto-replied'" do
  its('exit_status') { should eq 0 }
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject,Queue' do
  its('stdout') { should_not match(/two-domain-spam-test/) }
  its('stdout') { should_not match(/two-domain-autoreply-test/) }
  its('stdout') { should_not match(/forged-xoriginalto-test/) }
end
