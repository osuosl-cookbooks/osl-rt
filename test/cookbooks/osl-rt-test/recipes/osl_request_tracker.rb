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

# Request Tracker
include_recipe 'osl-rt'

# Restart Apache, removing race condition
# The website is already "deployed", but there is a race condition of the site being up in time
# and our test sending in a support ticket.
service 'httpd' do
  action :restart
  not_if { ::File.exist?('/root/first_run_done') }
end

file '/root/first_run_done'
