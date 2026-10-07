# Two-domain + branding suite (mail-domain != fqdn, logo), plus TLS on the host,
# worker sizing and full-text indexing. Sets its own self-contained data bag.
node.default['osl-rt-test']['site'] = 'support.example.org'
node.default['osl-rt-test']['data-bag'] = 'two-domain'

# Stage the logo locally so osl-rt's remote_file fetch needs no network (the data
# bag points at this file:// path); declared before osl-rt converges below.
file '/tmp/osl-rt-test-logo.png' do
  content 'fake-logo-for-testing'
end

include_recipe 'osl-rt-test::osl_request_tracker'

# RT checks for the index table only at startup, so restart httpd once it exists.
service 'httpd for the full-text index' do
  service_name 'httpd'
  action :nothing
end

# The bag sets fulltext-index; build the index once, as production does by hand.
execute 'rt-setup-fulltext-index' do
  notifies :restart, 'service[httpd for the full-text index]', :immediately
  command '/opt/rt/sbin/rt-setup-fulltext-index --dba rt-user --dba-password rt-password'
  not_if osl_rt_db_guard(
    { 'db' => { 'type' => 'mysql', 'name' => 'rt' }, 'db-username' => 'rt-user', 'db-password' => 'rt-password' },
    "SHOW TABLES LIKE 'AttachmentsIndex'"
  )
end
