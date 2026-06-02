# Migrating / importing an existing RT instance

`osl-rt` is safe to converge against an **already-populated** database (e.g. one
restored from another host). The one-time setup steps are guarded by the actual
database state rather than marker files:

- **Schema init** (`rt-setup-database --action init`) runs only when RT's tables
  are absent, so an imported schema is never re-initialized.
- **Root password** is set only as part of a fresh init, so an imported instance's
  root password is left untouched. (On a greenfield install it is set to
  `root-password`.)
- **Queues** are created only if missing; existing queues and their tickets are
  never touched. Adding a new queue to `queues` later creates just that one.

Point `db.*` at the imported database and converge. If the imported schema is
older than the installed RT package (or you upgraded the package), set
`db-upgrade` to the RT version the database is currently at (e.g. `"4.4.7"`) for
that converge to apply pending schema upgrades; it is passed as `--upgrade-from`
(RT does not persist its schema version). `rt-setup-database --action upgrade` is
interactive — it asks for an optional stop-at version and a final "proceed?" — so
the recipe feeds a blank line + `y` on stdin. **That auto-confirms the upgrade, so
take a database backup before enabling `db-upgrade`.** The upgrade runs from
`/opt/rt` (it reads the cwd-relative `./etc/upgrade`), runs once (tracked by
`/opt/rt/chef/upgrade-db-rt` — remove it to run again after a future upgrade), and
logs its output to `/opt/rt/chef/upgrade-db-rt.log` (the resource is `sensitive`,
so that log is where you read what happened). Review RT's upgrade notes first.

## The `migration` Test Kitchen suite

The `migration` suite imports a pre-seeded RT database that was dumped from an
**older RT version**, then lets `osl-rt` upgrade it. That dump,
`test/cookbooks/osl-rt-test/files/rt-seed.sql.gz`, is committed as a fixture (an
RT **4.4.4** schema with the seed data below). Regenerate it with the steps in
this doc if you need a different starting version, and update `migration.json`'s
`db-upgrade` to match.

### Seed contract

The suite's verifier (`test/integration/migration/migration_test.rb`) expects the
dump to contain:

- a queue named **`Imported Queue`** (so we can confirm it survives untouched),
- at least one ticket whose subject contains **`seeded-ticket`**,
- the **root** user's password set to **`my-epic-rt`** (the value the data bag and
  verifier use; root is *not* reset on import, so it must already match).

The `db-upgrade` value in `test/integration/data_bags/request-tracker/migration.json`
must equal the **RT version of the dump** (it is passed as `--upgrade-from`). Pick a
version older than the platform you test on:

- EL8/EL9 (RT 4.4.x): use a 4.4 dump older than the installed patch -> in-series upgrade.
- EL10 (RT 5.x): a 4.4 dump exercises the 4.4 -> 5 major upgrade.

### Generating the dump (older RT 4.4, apache-free)

On a throwaway EL9 box/container with the OSUOSL yum repo available:

```bash
# 1. MariaDB + an OLDER request-tracker than your target platform.
dnf install -y mariadb-server
systemctl enable --now mariadb
dnf install -y request-tracker-4.4.4        # pick an available older NVR; note it for db-upgrade

# 2. RT database + user.
mysql -u root <<'SQL'
CREATE DATABASE rt;
CREATE USER 'rt-user'@'localhost' IDENTIFIED BY 'rt-password';
GRANT ALL ON rt.* TO 'rt-user'@'localhost';
FLUSH PRIVILEGES;
SQL

# 3. Minimal site config so RT can talk to the DB, then init the schema.
cat > /opt/rt/etc/RT_SiteConfig.pm <<'PM'
Set($rtname, 'seed');
Set($DatabaseType, 'mysql');
Set($DatabaseHost, 'localhost');
Set($DatabaseName, 'rt');
Set($DatabaseUser, 'rt-user');
Set($DatabasePassword, 'rt-password');
1;
PM
/opt/rt/sbin/rt-setup-database --action init --dba rt-user --dba-password rt-password --skip-create

# 4. Set root's password to the value the tests use.
mysql -u rt-user -prt-password -e 'UPDATE Users SET Password=md5("my-epic-rt") WHERE Name="root";' rt

# 5. Seed a queue + ticket via the standalone server (no apache needed).
/opt/rt/sbin/rt-server --port 8080 &
RT_SERVER=$!
sleep 5
cat > ~/.rtrc <<'RC'
server http://localhost:8080
user root
passwd my-epic-rt
RC
/opt/rt/bin/rt create -t queue  set name="Imported Queue" correspondaddress="imported@example.org"
/opt/rt/bin/rt create -t ticket set subject="seeded-ticket" queue="Imported Queue"
kill "$RT_SERVER"

# 6. Dump schema+data only (no CREATE DATABASE, so it loads into the test 'rt' DB).
mysqldump --no-tablespaces --skip-add-locks -u rt-user -prt-password rt | gzip > rt-seed.sql.gz
```

Copy `rt-seed.sql.gz` into `test/cookbooks/osl-rt-test/files/` and set
`migration.json`'s `db-upgrade` to the version you installed in step 1 (e.g.
`4.4.4`). Then:

```bash
KITCHEN_LOCAL_YAML=kitchen.dokken.yml cinc exec kitchen verify migration-almalinux-10
```

> Tip: a sanitized `mysqldump` of an existing production RT works too, as long as it
> satisfies the seed contract above (queue/ticket names and the root password).
