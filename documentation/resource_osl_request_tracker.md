osl\_request\_tracker
=====================

Configures and initializes a Request Tracker website

### Notice of features missing from the resource

As of right now, some details need to be modified through the use of attributes in order properly deploy the RT website. These include the ticket queues needed in RT and the FQDN of where the site will be. These can be configured as such:

```rb
default['osl-rt']['queues'].tap |q| do
  q['Pretty Text Name'] = 'email-address'
  q['General Support'] = 'support'
  q['Frontend Team'] = 'frontend'
  q['Backend Team'] = 'backend'
end

default['osl-rt']['fqdn'] = 'support.osuosl.intnet'
```

## Actions

- create - (default) Installs and configures RT

## Properties

Name             | Types  | Description                                                  | Default   | Required?
-----------------|--------|--------------------------------------------------------------|-----------|----------
`domain_name`    | String | The FQDN of the site and email                               |           | yes
`root_password`  | String | The password used for the root account                       |           | yes
`default_email`  | String | The default email queues are associated with                 | support   | no
`db_type`        | String | The database type, MySQL or Postgres                         | localhost | no
`db_host`        | String | The hostname of the DB server                                |           | yes
`db_name`        | String | The DB name on the DB server                                 |           | yes
`db_username`    | String | The username of the DB user                                  |           | yes
`db_password`    | String | The password of the DB user                                  |           | yes
`error_redirect` | String | If an email cant end up anywhere, it will go to this account | error     | no
`queues`         | Hash   | **[NOT USABLE]** The queues and emails available for RT      |           | no
`plugins`        | Array  | A list of [plugins](https://rt-wiki.bestpractical.com/wiki/Extensions) to add to the RT site | | no
`lifecycles`     | Hash   | Any [custom lifecycles](https://docs.bestpractical.com/rt/4.4.1/customizing/lifecycles.html) to make available in RT | | no
`config_options` | Hash   | Any extra keyval configs to add to the RT site               |           | no

### Examples

```rb
# Create a regular RT site, attributes are added into the recipe for greater detail

node.default['osl-rt']['queues'].tap |q| do
  q['General'] = 'support'
  q['Frontend'] = 'frontend'
  q['Backend'] = 'backend'
end
node.default['osl-rt']['fqdn'] = 'support.osuosl.intnet'

osl_request_tracker 'request.osuosl.intnet' do
  db_name 'rt'
  db_username 'rt-user'
  db_password 'rt-password'
  root_password 'my own rt website'
end

# Example of a custom lifecycle
rt_lifecycle = {
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

# Example of additional config options
rt_configs = {
  '$WebPort' => '443',
  '$SetOutgoingMailFrom' => 'support@osuosl.org'
  '$LogoURL' -> 'https://osuosl.org/logos/osl.jpg'
}
```
