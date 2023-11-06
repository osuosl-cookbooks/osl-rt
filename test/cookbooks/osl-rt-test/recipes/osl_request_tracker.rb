# Download mailx for testing the email queue later
package %w(mailx jq)

# Database
osl_mysql_test 'rt' do
  username 'rt-user'
  password 'rt-password'
end

# Request Tracker
include_recipe 'osl-rt'

# Restart Apache
service 'httpd' do
  action :restart
  not_if { ::File.exist?('/root/first_run_done') }
end

# Send test ticket
execute 'Create test ticket via Email' do
  command <<~EOL
    echo "Hello, I need help creating a Request Tracker instance" | mailx -r root@localhost -s "support-test" support@example.org
  EOL
  not_if "/opt/rt/bin/rt ls -q General -s | grep -q 'support-test'"
  not_if { ::File.exist?('/root/first_run_done') }
end

file '/root/first_run_done'
