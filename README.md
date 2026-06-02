# osl-rt

## Requirements

### Platforms

- AlmaLinux 8, 9 (Request Tracker 4.4)
- AlmaLinux 10 (Request Tracker 5)

The RT major version follows the platform: EL8/9 install RT 4.4, EL10 installs
RT 5. The cookbook adjusts automatically — notably, extensions that RT 5 merged
into core (`RT::Extension::REST2`, `RT::Authen::Token`) are skipped from the
`plugins` list on EL10 (loading them as plugins makes RT 5 fail to start).

### Cookbooks

### TLS / reverse proxy

This cookbook serves RT over **plain HTTP only**. TLS is expected to be
terminated by an upstream HAProxy (or similar) reverse proxy that forwards to
this backend over HTTP. Apache is configured with `osl-apache::mod_remoteip`
so the real client IP is recovered from the `X-Forwarded-For` header.

The list of trusted proxies defaults to OSUOSL's load balancers. For other
deployments, override it on the node:

```ruby
node.default['osl-apache']['mod_remoteip']['trusted_proxy'] = %w(10.0.0.1)
```

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
`fqdn`           | String | The FQDN of the site (web/host domain)                       | `example.org`
`mail-domain`    | String | The public email domain for queue addresses, when it differs from the host `fqdn` (e.g. `example.org` while the site is `support.example.org`). Mail to either domain is accepted. | `fqdn`
`user`           | String | The user account that is responsible for being the default email | `support`
`failed-email`   | String | Address that mail RT fails to process is forwarded to        | `root`
`forward-email`  | String | If set, a copy of incoming queue mail is forwarded off-box to this address (e.g. a Google Workspace archive mailbox). | nil
`forward-user`   | String | Optional dedicated local user for the forward (two-user split). When set, queue mail is delivered to both the RT `user` (feeds rt-mailgate) and this user (forwards a copy to `forward-email`), so RT processing and the off-box copy don't interfere. Requires `forward-email`. | nil
`logo`           | Hash   | Optional custom branding. `url` is fetched into RT's static images dir and `$LogoURL` is set to the served path; `link`/`alt` set `$LogoLinkURL`/`$LogoAltText`. Assumes the default (empty) `WebPath`; override `$LogoURL` via `extra-config` otherwise. | nil
`internal-domain`| String | A workaround required needs a non-sublevel domain name to access the site internally | `rtlocal`
`db.type`        | String | The database type, MySQL or Postgres                         | `mysql`
`db.host`        | String | The hostname of the DB server                                | `localhost`
`db.name`        | String | The DB name on the DB server                                 | `rt`
`db-upgrade`     | String | Opt-in: the RT version the database is currently at (e.g. `"4.4.7"`), passed as `--upgrade-from` to apply pending schema upgrades (after importing a DB or an RT package upgrade). The "proceed?" prompt is auto-confirmed, so **back up first**. See [docs/migration.md](docs/migration.md). | unset |
`queues`         | Hash   | The queues and emails available for RT. The key is the pretty print, and the value is a email-valid name. | `{'Support Example': nil}` Any nil-valued key will be ignored.
`plugins`        | Array  | A list of [plugins](https://rt-wiki.bestpractical.com/wiki/Extensions) to add to the RT site. On EL10/RT 5, extensions merged into core (`RT::Extension::REST2`, `RT::Authen::Token`) are automatically skipped. | `[]`
`lifecycles`     | Hash   | Any [custom lifecycles](https://docs.bestpractical.com/rt/4.4.1/customizing/lifecycles.html) to make available in RT. Arbitrary lifecycles (including an `approvals` lifecycle) are emitted verbatim, so add them here rather than in code. | `{}` Provides default lifecycle.
`extra-config`   | Hash   | Raw RT config options emitted verbatim into `RT_SiteConfig.pm`. Keys must be valid RT names (e.g. `$Timezone`, `$DefaultQueue`, `$ParseNewMessageForTicketCcs`). String values are quoted; numbers/literals are emitted as-is; keys beginning with `%` are treated as Perl literals (e.g. `%FullTextSearch`). Do **not** set `_Plugins`/`_Lifecycles` here — use `plugins`/`lifecycles`. | `{}`

### Example Data Bag Attributes

```json
{
  "db": {
    "type": "mysql",
    "host": "localhost",
    "name": "rt"
  },
  "fqdn": "support.example.org",
  "mail-domain": "example.org",
  "user": "support",
  "failed-email": "systems@example.org",
  "forward-email": "archive@gapps.example.org",
  "forward-user": "support-gmail",
  "logo": {
    "url": "https://example.org/img/logo.png",
    "link": "https://support.example.org/",
    "alt": "Example Support"
  },
  "queues": {
    "Support": "support",
    "Frontend Team": "frontend",
    "Backend Team": "backend",
    "DevOps Team": "devops",
    "Marketing Team": "advertising",
    "The Board Of Directors": "board"
  },
  "plugins": ["RT::Extension::REST2", "RT::Authen::Token"],
  "extra-config": {
    "$Timezone": "US/Pacific",
    "$DefaultQueue": "Support",
    "$ParseNewMessageForTicketCcs": 1,
    "%FullTextSearch": "Enable => 1, Indexed => 1"
  },
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

## Migration / importing an existing instance

The recipe is safe to converge against an **already-populated** database: schema
init, the root password, and existing queues are all guarded by the actual
database state, so an imported instance is never re-initialized or clobbered. The
opt-in `db-upgrade` key applies pending schema upgrades after an import or package
upgrade. See [docs/migration.md](docs/migration.md) for the full details, the
`migration` Test Kitchen suite, and how to generate the seed dump.

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
