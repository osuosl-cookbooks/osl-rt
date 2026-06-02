# Two-domain + forwarding + branding suite (mail-domain != fqdn, forward-user
# split, logo). Sets its own data bag so the suite is self-contained.
node.default['osl-rt']['data-bag'] = 'two-domain'

# Stage the logo locally so osl-rt's remote_file fetch needs no network (the data
# bag points at this file:// path); declared before osl-rt converges below.
file '/tmp/osl-rt-test-logo.png' do
  content 'fake-logo-for-testing'
end

include_recipe 'osl-rt-test::osl_request_tracker'
