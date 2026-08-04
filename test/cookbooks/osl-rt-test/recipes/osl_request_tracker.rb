# Download mailx/s-nail for testing the email queue later
if node['platform_version'].to_i <= 8
  package %w(mailx jq)
else
  package %w(s-nail jq)
end

# Database
osl_mysql_test 'rt' do
  username 'rt-user'
  password 'rt-password'
end

# Request Tracker. The site fqdn and data-bag item are selected by osl-rt-test
# attributes (default 'example.org' / 'default'); the two-domain suite overrides
# them and reuses this recipe.
osl_request_tracker node['osl-rt-test']['site'] do
  data_bag node['osl-rt-test']['data-bag']
end

# Exercise the RT_SiteConfig.d drop-in: a snippet dropped here must be picked up
# by RT's own config loader (asserted in the inspec via RT::LoadConfig). $Timezone
# is otherwise unset by osl-rt, so it's a clean, observable value to check.
file '/opt/rt/etc/RT_SiteConfig.d/99-dropin-test.pm' do
  content "Set($Timezone, 'US/Pacific');\n1;\n"
  group 'apache'
  mode '0640'
end

# Restart Apache, removing race condition
# The website is already "deployed", but there is a race condition of the site being up in time
# and our test sending in a support ticket.
service 'httpd' do
  action :restart
  not_if { ::File.exist?('/root/first_run_done') }
end

file '/root/first_run_done'
