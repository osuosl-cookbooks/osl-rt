OSUOSL Recipe-based Request Tracker
===================================

Configures and initializes a Request Tracker website

## Attributes

Name             | Types  | Description                                                  | Required?
-----------------|--------|--------------------------------------------------------------|----------
`fqdn`           | String | The FQDN of the site and email                               | yes
`data-bag`       | Array [String, String]  | A two string array containing the `bag name` and `item name` of a data bag | yes
`user`           | String | The user account that is responsible for being the default email | no
`db.type`        | String | The database type, MySQL or Postgres                         | no
`db.host`        | String | The hostname of the DB server                                | yes
`db.name`        | String | The DB name on the DB server                                 | yes
`queues`         | Hash   | The queues and emails available for RT. The key is the pretty print, and the value is a email-valid name. | no
`plugins`        | Array  | A list of [plugins](https://rt-wiki.bestpractical.com/wiki/Extensions) to add to the RT site | no
`lifecycles`     | Hash   | Any [custom lifecycles](https://docs.bestpractical.com/rt/4.4.1/customizing/lifecycles.html) to make available in RT | no

### Required Data Bag Attributes

Some information required for hosting an RT instance require special handling in order to ensure that the instance is secure. As such, these variables should be set in a data bag, with the data bag then referenced in the attributes.

Name            | Types  | Description
----------------|--------|------------
`db-username`   | String | The username of the DB user
`db-password`   | String | The password of the DB user
`root-password` | String | The password used for the root account on RT

### Example Attributes

```rb
# Create three different Queues. The keys are the "pretty print" name, while the values are the email name.
default['osl-rt']['queues'].tap do |q|
  q['Support'] = 'support'
  q['Frontend Team'] = 'frontend'
  q['Backend Team'] = 'backend'
end

# Set up the Database connection
default['osl-rt']['db'].tap do |db|
  db['type'] = 'mysql'
  db['host'] = 'localhost'
  db['name'] = 'rt'
end

# Configure the domain name that the website and email reciever/sender will be from
default['osl-rt']['fqdn'] = 'subdomain.example.com'

# Set the name of the user who will be managing the RT emails recieved
default['osl-rt']['user'] = 'support'

# Add on any extra plugins to the RT site, as an array
default['osl-rt']['plugins'] = %w(RT::Extension::REST2 RT::Authen::Token)

# Create a custom lifecycle to use, leaving this blank will only supply the stock lifecycle
default['osl-rt']['lifecycles'] = {
  'new-wave' => {
    'initial' => [ 'order in' ],
    'active' => [ 'order work', 'order delayed' ],
    'inactive' => [ 'order up' ],

    'transitions' => {
      '' => [ 'order in' ],
      'order in' => [ 'order work' ],
      'order work' => [ 'order delayed', 'order up' ],
      'order delayed' => [ 'order work' ],
    },

    'rights' => {
      '* => order in' => 'ResetOrder',
    }
  }
}
```
