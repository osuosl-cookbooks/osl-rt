#
# Cookbook:: osl-rt
# Recipe:: default
#
# Copyright:: 2023, Oregon State University
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
include_recipe 'osl-apache'
include_recipe 'osl-apache::mod_ssl'
include_recipe 'osl-apache::mod_perl'
include_recipe 'osl-mysql::client'
include_recipe 'yum-osuosl'
include_recipe 'perl'

package %w(request-tracker mutt procmail)
