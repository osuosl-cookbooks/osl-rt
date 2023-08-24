# Download mailx for testing the email queue later
package %w(mailx jq)

# Database
osl_mysql_test 'rt' do
  username node['osl-rt']['db']['username']
  password node['osl-rt']['db']['password']
end

# Request Tracker
include_recipe 'osl-rt'

# Wait a bit so the RT instance could start back up
chef_sleep 'Wait a bit' do
  seconds 5
  not_if { ::File.exist?('/root/first_run_done') }
end

# Send test ticket
execute 'Create test ticket via Email' do
  command <<~EOL
    echo "Hello, I need help creating a Request Tracker instance" | mailx -r root@localhost -s "support-test" support@request.osuosl.intnet
  EOL
  not_if "/opt/rt/bin/rt ls -q General -s | grep -q 'support-test'"
  not_if { ::File.exist?('/root/first_run_done') }
end

file '/root/first_run_done'
