# Request Tracker

include_recipe 'osl-rt'

# Set up the hostname as the website
hostname "#{node['hostname'][0..48]}.osuosl.intnet" do
  aliases %w(request.osuosl.intnet)
end

# Download mailx for testing the email queue later
package 'mailx'

# Database
osl_mysql_test 'rt' do
  username 'rt-user'
  password 'rt-password'
end

rt_lifecycle = {
  'default' => {
    'initial' => [ 'new' ],
    'active' => [ 'open' ],
    'inactive' => %w(stalled resolved rejected deleted),

    'defaults' => {
      'on_create' => 'new',
      'on_merge' => 'resolved',
      'approved' => 'open',
      'denied' => 'rejected',
    },

    'transitions' => {
      '' => %w(new open resolved),
      'new' => %w(open stalled resolved rejected deleted),
      'open' => %w(new stalled resolved rejected deleted),
      'stalled' => %w(new open rejected resolved deleted),
      'resolved' => %w(new open stalled rejected deleted),
      'rejected' => %w(new open stalled resolved deleted),
      'deleted' => %w(new open stalled rejected resolved),
    },

    'rights' => {
      '* -> deleted' => 'DeleteTicket',
      '* -> *' => 'ModifyTicket',
    },
    'actions' => {
      'new -> open' => {
        'label' => 'Open It',
        'update' => 'Respond',
      },
    },
  },
  'new-wave' => {
    'initial' => [ 'order in' ],
    'active' => [ 'order work' ],
    'inactive' => [ 'order up' ],

    'transitions' => {
      '' => [ 'order in' ],
      'order in' => [ 'order work' ],
      'order work' => [ 'order up' ],
    },

    'rights' => {
      '* -> order in' => 'ResetOrder',
    },
  },
}

# Request tracker service
osl_request_tracker 'request.osuosl.intnet' do
  domain_root 'request.osuosl.intnet'
  db_name 'rt'
  db_username 'rt-user'
  db_password 'rt-password'
  root_password 'my-epic-rt'
  error_redirect 'sysadmin@osuosl.intnet'
  lifecycles rt_lifecycle
  queues({
    'Frontend Team' => 'frontend',
    'Backend Team' => 'backend',
    'Dev Ops Team' => 'devops',
    'Marketing Team' => 'advertising',
    'The Board Of Directors' => 'board',
    'Support' => 'support'
  })
  config_options({ '$WebPort' => '80' })
end

# Post-RT install
include_recipe 'osl-rt::post'

# Send test ticket
execute 'Create test ticket via Email' do
  command <<~EOL
    echo "Hello, I need help creating a Request Tracker instance" | mailx -r root@localhost -s "support-test" support@request.osuosl.intnet
  EOL
    not_if "/opt/rt/bin/rt ls -q General -s | grep -q 'support-test'"
    not_if { ::File.exist?('/root/first_run_done') }
end

file '/root/first_run_done'
