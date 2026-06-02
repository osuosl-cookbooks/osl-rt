# Verifies importing an older-RT dump: import intact, schema upgraded, missing
# queue added. Seed contract (docs/migration.md): a "Imported Queue" queue, a
# "seeded-ticket" ticket, and root's password "my-epic-rt".

describe service('httpd') do
  it { should be_enabled }
  it { should be_running }
end

describe package('request-tracker') do
  it { should be_installed }
end

# The opt-in schema upgrade ran.
describe file('/opt/rt/chef/upgrade-db-rt') do
  it { should exist }
end

# Imported data survived (init was skipped, not re-initialized).
describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t queue -f Name' do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Imported Queue/) } # from the dump, untouched
  its('stdout') { should match(/Migrated Queue/) } # newly created from the data bag
end

describe command 'HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject' do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/seeded-ticket/) }
end

# RT is functional post-upgrade and root auth (imported password) works.
describe command "HOSTALIASES=/root/.rthost curl -sk -u 'root:my-epic-rt' http://rtlocal/REST/2.0/rt" do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Version/) }
end

# Mail round-trip into the new queue. Delivery is async (and slow on the first
# mailgate hit post-upgrade), so poll for the ticket rather than checking at once.
describe command(<<~CMD) do
  echo "Migrated instance still takes mail" | mailx -r root@localhost -s "post-migration-test" migrated@example.org
  for _ in $(seq 1 30); do
    HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject 2>/dev/null | grep -q post-migration-test && break
    sleep 2
  done
  HOSTALIASES=/root/.rthost /opt/rt/bin/rt ls -t ticket -f Subject,Queue
CMD
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/post-migration-test/) }
  its('stdout') { should match(/Migrated Queue/) }
end
