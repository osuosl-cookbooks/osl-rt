default['osl-rt']['queues'].tap do |q|
  q['Support Example'] = nil
end
default['osl-rt']['db'].tap do |db|
  db['host'] = 'localhost'
  db['name'] = 'rt'
end
default['osl-rt']['fqdn'] = 'example.org'
default['osl-rt']['user'] = 'support'
default['osl-rt']['db']['type'] = 'mysql'
default['osl-rt']['internal-domain'] = 'rtlocal'
default['osl-rt']['data-bag'] = 'default'

default['osl-rt']['plugins'] = []
default['osl-rt']['lifecycles'] = {
  'example' => {
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
}
