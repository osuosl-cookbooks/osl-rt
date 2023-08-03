default['osl-rt']['queues'].tap do |q|
  q['Support'] = 'support'
  q['Frontend Team'] = 'frontend'
  q['Backend Team'] = 'backend'
  q['DevOps Team'] = 'devops'
  q['Marketing Team'] = 'advertising'
  q['The Board Of Directors'] = 'board'
end
default['osl-rt']['db'].tap do |db|
  db['type'] = 'mysql'
  db['host'] = 'localhost'
  db['name'] = 'rt'
  db['username'] = 'rt-user'
  db['password'] = 'rt-password'
end

default['osl-rt']['fqdn'] = 'request.osuosl.intnet'
default['osl-rt']['default'] = 'support'
default['osl-rt']['root-password'] = 'my-epic-rt'
default['osl-rt']['plugins'] = %w(RT::Extension::REST2 RT::Authen::Token)
default['osl-rt']['lifecycles'] = {
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
