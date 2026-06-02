# Verifies the two-domain (mail-domain != fqdn) + forward-user split + logo setup.

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
    "Set($RTAddressRegexp, '^((support|systems)(-comment)?@(support\\.example\\.org|example\\.org))$');",
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

# Both mail users exist (two-user split)
%w(support support-gmail).each do |u|
  describe user(u) do
    it { should exist }
  end
end

# RT user feeds rt-mailgate for both domains and does NOT forward (the split user does).
describe file('/home/support/.procmailrc') do
  # domain_match group accepts both delivery domains (dots escaped for procmail)
  its('content') { should include 'X-Original-To: support@(support\.example\.org|example\.org)' }
  its('content') { should include '/opt/rt/bin/rt-mailgate --queue "Support" --action correspond --url http://rtlocal' }
  # In split mode the RT user does NOT forward off-box (that is the forward user)
  its('content') { should_not match(/^! root@example\.org$/) }
end

# Forward user forwards a copy off-box
describe file('/home/support-gmail/.procmailrc') do
  it { should exist }
  its('content') { should match(/^! root@example\.org$/) }
end

# Queue mail is delivered to BOTH the RT user and the forward user
describe file('/etc/aliases') do
  its('content') { should match(/^support: support, support-gmail$/) }
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
  ].each do |line|
    its('content') { should match Regexp.escape(line) }
  end
end

describe postfix_conf('/etc/postfix/main.cf') do
  its('mydestination') do
    should eq '$myhostname, localhost.$mydomain, localhost, support.example.org, example.org'
  end
end

# Mail round-trip: a ticket to the mail-domain reaches RT through the split.
describe command 'echo "Need help with the two-domain setup" | mailx -r root@localhost -s "two-domain-test" support@example.org' do
  its('exit_status') { should eq 0 }
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t queue -f Name' do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Support/) }
  its('stdout') { should match(/Systems Team/) }
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject,Queue' do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/two-domain-test/) }
end
