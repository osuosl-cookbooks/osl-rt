  node.default['osl-postfix']['main']['home_mailbox'] = 'Mail/'
  node.default['osl-postfix']['main']['mailbox_command'] = '/usr/bin/procmail'
  node.default['osl-postfix']['main']['mailbox_size_limit'] = '0'
  node.default['osl-postfix']['main']['message_size_limit'] = '102400000'
  node.default['osl-postfix']['main']['transport_maps'] = 'hash:/etc/postfix/transport'

  node.default['postfix']['access']['140.211.166.133'] = 'OK' # smtp2.osuosl.org
  node.default['postfix']['access']['140.211.166.136'] = 'OK' # smtp3.osuosl.org
  node.default['postfix']['access']['140.211.166.137'] = 'OK' # smtp4.osuosl.org
  node.default['postfix']['access']['140.211.166.138'] = 'OK' # smtp1.osuosl.org

  include_recipe 'osl-postfix::server'
  include_recipe 'postfix::aliases'
  include_recipe 'postfix::access'
  include_recipe 'postfix::transports'
