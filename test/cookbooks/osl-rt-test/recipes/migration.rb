# Migration suite: import an older-RT dump before osl-rt converges, then upgrade.
# Exercises the DB-state guards (init/existing queue/root preserved), creation of
# the missing "Migrated Queue", and db-upgrade. The seed fixture
# (files/rt-seed.sql.gz, RT 4.4.4) and regeneration steps are in docs/migration.md.
node.default['osl-rt']['data-bag'] = 'migration'

if node['platform_version'].to_i <= 8
  package %w(mailx jq)
else
  package %w(s-nail jq)
end

# Empty DB + user (same as the standard suite)
osl_mysql_test 'rt' do
  username 'rt-user'
  password 'rt-password'
end

# Stage the older-RT seed dump and import it into the empty DB BEFORE osl-rt runs.
# Guarded on the schema being absent so it loads exactly once.
cookbook_file '/tmp/rt-seed.sql.gz' do
  source 'rt-seed.sql.gz'
end

execute 'import-rt-seed' do
  command 'gunzip -c /tmp/rt-seed.sql.gz | mysql -u rt-user -prt-password rt'
  not_if "mysql -u rt-user -prt-password -N -B -e \"SHOW TABLES LIKE 'Users'\" rt 2>/dev/null | grep -q ."
  sensitive true
end

# osl-rt sees a populated DB: skips init/root, upgrades, creates the missing queue.
include_recipe 'osl-rt'

# Restart Apache to clear the first-run race (same as the standard suite).
service 'httpd' do
  action :restart
  not_if { ::File.exist?('/root/first_run_done') }
end

file '/root/first_run_done'
