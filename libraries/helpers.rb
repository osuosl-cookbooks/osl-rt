module OslRT
  module Cookbook
    module Helpers
      # Take all of the config settings set in the databag, and overwrite the default attributes.
      def osl_rt_set_attributes
        rt_secrets = data_bag_item('request-tracker', node['osl-rt']['data-bag'])

        # Iterate over all keys which will be replaced
        %w(fqdn user internal-comain db queues plugins lifecycles).each do |key|
          node.override['osl-rt'][key] = rt_secrets[key] if rt_secrets[key]
        end
      end

      # Initalize the configuration options given the attributes
      def osl_rt_init_config
        rt_secrets = data_bag_item('request-tracker', node['osl-rt']['data-bag'])

        config_options = {}
        config_options['$rtname'] = node['osl-rt']['fqdn']
        config_options['$WebDomain'] = node['osl-rt']['fqdn']
        config_options['$Organization'] = node['osl-rt']['fqdn'][/([\w\-_]+\.+\w+$)/]
        config_options['$CorrespondAddress'] = "#{node['osl-rt']['user']}@#{config_options['$Organization']}"
        config_options['$CommentAddress'] = "#{node['osl-rt']['default']}-comment@#{config_options['$Organization']}"
        config_options['$DatabaseType'] = node['osl-rt']['db']['type']
        config_options['$DatabaseHost'] = node['osl-rt']['db']['host']
        config_options['$DatabaseRTHost'] = node['osl-rt']['db']['host']
        config_options['$DatabaseName'] = node['osl-rt']['db']['name']
        config_options['$DatabaseUser'] = rt_secrets['db-username']
        config_options['$DatabasePassword'] = rt_secrets['db-password']
        config_options['_Plugins'] = node['osl-rt']['plugins'] if node['osl-rt']['plugins']
        config_options['_Lifecycles'] = node['osl-rt']['lifecycles'] if node['osl-rt']['lifecycles']

        # Set up the queue emails
        rt_emails = init_emails(node['osl-rt']['queues'], node['osl-rt']['fqdn'], node['osl-rt']['user'])

        config_options['$RTAddressRegexp'] = "^(#{rt_emails.join('|')}(-comment)?\@(#{node['osl-rt']['fqdn']}))"

        # Since this is recipe-driven, go straight to parsing the config options, then return the final config file.
        parse_config(config_options)
      end

      private

      # Take in a hashmap containing the properties we'd like to set
      # for the RT instance, and convert to the perl config standard
      # Returns a string
      def parse_config(hOptions)
        strConfig = ''
        hOptions.each do |key, value|
          case key
          when '_Plugins'
            # _Plugins contains an array of all plugins requested
            strConfig += parse_plugin(value)
            next
          when '_Lifecycles'
            # _Lifecycles contains a recursive key-val/array pair for defining
            # the progress of a ticket
            strConfig += parse_lifecycle(value)
            next
          end
          strConfig += "Set(#{key}, "
          # Check to see if the key's first character is asking for a literal.
          if key[0] == '%'
            strConfig += "#{value});\n"
            next
          end
          # Normal config option, check to see if it should be incapsulated with quotation marks.
          strConfig += if !value.is_a?(String)
                         # Interprete as a literal
                         "#{value});\n"
                       else
                         # Add quotation marks
                         "'#{value}');\n"
                       end
        end
        strConfig
      end

      # Take in an array of plugins to add
      # and return a string to append to the config file
      def parse_plugin(arrPlugins)
        strConfig = ''
        arrPlugins.sort.each do |plugin|
          strConfig += "Plugin('#{plugin}');\n"
        end
        strConfig
      end

      # Take in a hash of a lifecycle
      # and convert it to be used in the config file
      # Returns a string
      def parse_lifecycle(hLifecycle)
        # Check to see if there is any configuration given
        if hLifecycle.empty?
          return '# The given lifecycle variable was empty!\n'
        end
        # Add the Lifecycles option
        strConfig = "Set(%Lifecycles,\n"
        # The top-most hashtable pair contains different lifecycle options.
        hLifecycle.each do |lifecycle, options|
          strConfig += "\t'#{lifecycle}' => {\n"
          strConfig += parse_lifecycle_ht(options)
          strConfig += "\t},\n"
        end
        strConfig += ");\n"
        strConfig
      end

      # Recursive function for going into a keyval pair
      # nIndent gives the amount of tabs to place to pretty print for the file
      # Returns a string
      def parse_lifecycle_ht(hPair, nIndent = 2)
        strConfig = ''
        ind = "\t" * nIndent
        # Loop over all key-value pairs, either setting to the value,
        # or going into another recursive function.
        hPair.each do |key, value|
          strConfig += "#{ind}'#{key}' => "
          strConfig += if value.is_a?(Hash)
                         "{\n#{parse_lifecycle_ht(value, nIndent + 1)}#{ind}},\n"
                       elsif value.is_a?(Array)
                         "[\n#{parse_lifecycle_array(value, nIndent + 1)}#{ind}],\n"
                       else
                         "'#{value}',\n"
                       end
        end
        strConfig
      end

      # Recursive function for going into an array
      # nIndent gives the amount of tabs to place to pretty print for the file
      # Returns a string
      def parse_lifecycle_array(arrItems, nIndent = 2)
        strConfig = ''
        indChld = "\t" * (nIndent + 1)
        # Loop over all items, either appending a value,
        # or going into another recursive function.
        arrItems.each do |item|
          strConfig += if item.is_a?(Hash)
                         "{\n#{indChld}#{parse_lifecycle_ht(item, nIndent + 1)}#{"\t" * nIndent}},\n"
                       elsif item.is_a?(Array)
                         "[\n#{indChld}#{parse_lifecycle_array(item, nIndent + 1)}#{"\t" * nIndent}],\n"
                       else
                         "#{indChld}'#{item}',\n"
                       end
        end
        strConfig
      end

      # Sets up the email queues for postfix. And returns the emails for RT configuration.
      def init_emails(queues, strdomain, strdefault)
        rt_emails = []
        queues.each do |_, email|
          next if email.nil?
          node.force_override['postfix']['aliases'][email] = strdefault
          node.force_override['postfix']['aliases']["#{email}-comment"] = strdefault
          node.force_override['postfix']['transports']["#{email}@#{strdomain}"] = 'local:$myhostname'
          node.force_override['postfix']['transports']["#{email}-comment@#{strdomain}"] = 'local:$myhostname'
          rt_emails.push(email)
        end
        rt_emails.sort
      end
    end
  end
end

Chef::DSL::Recipe.include ::OslRT::Cookbook::Helpers
Chef::Resource.include ::OslRT::Cookbook::Helpers
