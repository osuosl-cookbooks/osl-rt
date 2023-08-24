module OslRT
  module Cookbook
    module Helpers
      # Take in a hashmap containing the properties we'd like to set
      # for the RT instance, and convert to the perl config standard
      # Returns a string
      def parse_config(hOptions)
        strConfig = ''
        hOptions.each do |key, value|
          # If the key is _Plugins, this is a special case
          if key == '_Plugins'
            # _Plugins contains an array of all plugins requested
            strConfig += parse_plugin(value)
            next
          end
          # If the key is _Lifecycles, this is a special case
          if key == '_Lifecycles'
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
        arrPlugins.each do |plugin|
          strConfig += "Plugin('#{plugin}');\n"
        end
        strConfig
      end

      # Take in a hash of a lifecycle
      # and convert it to be used in the config file
      # Returns a string
      def parse_lifecycle(hLifecycle)
        # Check to see if there is any configuration given
        unless hLifecycle.empty?
          return '# The given variable was empty!'
        end
        # Add the Lifecycles option
        strConfig = 'Set(%Lifecycles,\n'
        # The top-most hashtable pair contains different lifecycle options.
        hLifecycle.each do |lifecycle, options|
          strConfig += "\t'#{lifecycle}' => {\n"
          strConfig += parse_lifecycle_ht(options)
          strConfig += "\t},\n"
        end
        strConfig += ');\n'
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
                         "{\n#{parse_lifecycle_ht(value, nIndent + 1)}},\n"
                       elsif value.is_a?(Array)
                         "[\n#{parse_lifecycle_array(value, nIndent + 1)}],\n"
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
                         "{\n#{indChld}#{parse_lifecycle_ht(item, nIndent + 1)}},\n"
                       elsif item.is_a?(Array)
                         "[\n#{indChld}#{parse_lifecycle_array(item, nIndent + 1)}],\n"
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
