# PostgreSQL suite: same as the standard suite but backed by Postgres. Uses its
# own data bag (db.type = Pg) so it is self-contained alongside the MySQL suite.
node.default['osl-rt']['data-bag'] = 'postgresql'

# Download mailx/s-nail for testing the email queue later
if node['platform_version'].to_i <= 8
  package %w(mailx jq)
else
  package %w(s-nail jq)
end

# Database. osl_postgresql_test stands up Postgres locally and creates the rt
# database/role; the role is a superuser so rt-setup-database can load the schema.
osl_postgresql_test 'rt' do
  username 'rt-user'
  password 'rt-password'
end

# Request Tracker
include_recipe 'osl-rt'

# Exercise the RT_SiteConfig.d drop-in, same as the MySQL suite.
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
