default['osl-rt']['db'].tap do |db|
  db['host'] = 'localhost'
  db['name'] = 'rt'
end
default['osl-rt']['fqdn'] = 'example.org'
default['osl-rt']['user'] = 'support'
default['osl-rt']['db']['type'] = 'mysql'
default['osl-rt']['internal-domain'] = 'rtlocal'
default['osl-rt']['data-bag'] = 'default'
