# osl-rt

## Requirements

### Platforms

- Almalinux 8+

### Cookbooks

## Attributes

Do **NOT** set the configuration in the attributes, instead use data bags.

Name       | Type   | Description                                                            | Default
-----------|--------|------------------------------------------------------------------------|---------
`data-bag` | String | The name of the databag item. The data bag is always `request-tracker` | nil

## Data Bag Attributes

Name             | Type   | Description                                                  | Default
-----------------|--------|--------------------------------------------------------------|----------
`db-username`    | String | The username of the DB user                                  | nil
`db-password`    | String | The password of the DB user                                  | nil
`root-password`  | String | The password used for the root account on RT                 | nil
`fqdn`           | String | The FQDN of the site and email                               | `example.org`
`user`           | String | The user account that is responsible for being the default email | `support`
`internal-domain`| String | A workaround required needs a non-sublevel domain name to access the site internally | `rtlocal`
`db.type`        | String | The database type, MySQL or Postgres                         | `mysql`
`db.host`        | String | The hostname of the DB server                                | `localhost`
`db.name`        | String | The DB name on the DB server                                 | `rt`
`queues`         | Hash   | The queues and emails available for RT. The key is the pretty print, and the value is a email-valid name. | `{'Support Example': nil}` Any nil-valued key will be ignored.
`plugins`        | Array  | A list of [plugins](https://rt-wiki.bestpractical.com/wiki/Extensions) to add to the RT site | `[]`
`lifecycles`     | Hash   | `WARNING: Default set to a custom lifecycle, explicitly set this to nil for actual default.` Any [custom lifecycles](https://docs.bestpractical.com/rt/4.4.1/customizing/lifecycles.html) to make available in RT | A custom example of a default lifecycle.

### Example Data Bag Attributes

```json
{
  "db": {
    "type": "mysql",
    "host": "localhost",
    "name": "rt"
  },
  "fqdn": "support.example.org",
  "user": "support",
  "queues": {
    "Support": "support",
    "Frontend Team": "frontend",
    "Backend Team": "backend",
    "DevOps Team": "devops",
    "Marketing Team": "advertising",
    "The Board Of Directors": "board"
  },
  "plugins": ["RT::Extension::REST2", "RT::Authen::Token"]
  "lifecycles": {
    "new-wave": {
      "initial": ["order in"],
      "active": ["order work", "order delayed"],
      "inactive": ["order up"]

      "transitions": {
        "": ["order in"],
        "order in": ["order work"],
        "order work": ["order delayed", "order up"],
        "order delayed": ["order work"]
      },
      
      "rights": {
        "* => order in": "ResetOrder"
      }
    }
  }
}
```

## Resources

## Recipes

### osl-rt::default
Deploys an RT web service on the given system, using the provided attributes

## Contributing

1. Fork the repository on Github
1. Create a named feature branch (like `username/add_component_x`)
1. Write tests for your change
1. Write your change
1. Run the tests, ensuring they all pass
1. Submit a Pull Request using Github

## License and Authors

- Author:: Oregon State University <chef@osuosl.org>

```text
Copyright:: 2023, Oregon State University

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
