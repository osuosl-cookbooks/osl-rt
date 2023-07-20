default['osl-apache']['listen'] = %w(80 443)
default['osl-apache']['worker_mem'] = 215

default['osl-postfix']['main']['home_mailbox'] = 'Mail/'
default['osl-postfix']['main']['mailbox_command'] = '/usr/bin/procmail'
default['osl-postfix']['main']['mailbox_size_limit'] = '0'
default['osl-postfix']['main']['message_size_limit'] = '102400000'
default['osl-postfix']['main']['transport_maps'] = 'hash:/etc/postfix/transport'

default['postfix']['access']['140.211.166.133'] = 'OK' # smtp2.osuosl.org
default['postfix']['access']['140.211.166.136'] = 'OK' # smtp3.osuosl.org
default['postfix']['access']['140.211.166.137'] = 'OK' # smtp4.osuosl.org
default['postfix']['access']['140.211.166.138'] = 'OK' # smtp1.osuosl.org
