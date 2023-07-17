# Resource: osl_rt_queue
# Configure a new queue for a Request Tracker instance

provides :osl_rt_queue
resource_name :osl_rt_queue
unified_mode true

# Properties
property :name, String, name_property: true
property :description, String
property :lifecycle, String, default: 'default'
property :subject_tag, String
property :sort_order, Integer
property :email_reply, String
property :email_comment, String

default_action :create
  
action :create do
  args = "name=#{new_resource.name} "
  args += new_resource.description ? "description=#{new_resource.description}" : ''
end
