module OslRT
  module Cookbook
    module Helpers
      # Merged into RT 5 core (EL10+); loading them as plugins breaks startup, so
      # they are dropped from the plugin list on RT 5.
      RT5_CORE_PLUGINS = %w(
        RT::Authen::Token
        RT::Extension::REST2
      ).freeze

      # True when the platform ships RT 5 (AlmaLinux 10 and newer).
      def osl_rt_rt5?
        node['platform_version'].to_i >= 10
      end

      # True when the configured database engine is PostgreSQL. RT expects the
      # literal 'Pg' for $DatabaseType; anything else (default 'mysql') is MySQL.
      def osl_rt_pg?(rt_config)
        rt_config['db']['type'] == 'Pg'
      end

      # Initalize the default configurations
      def osl_rt_load_config_defaults
        {
          'db' => {
            'type' => 'mysql',
            'host' => 'localhost',
            'name' => 'rt',
          },
          'fqdn' => 'example.org',
          'user' => 'support',
          'internal-domain' => 'rtlocal',
          'plugins' => [],
        }
      end

      # Initalize the configuration options given the attributes
      def osl_rt_init_config(rt_config)
        # The public email domain may differ from the host/web domain (fqdn).
        # When 'mail-domain' is unset it falls back to the fqdn (single-domain).
        mail_domain = osl_rt_mail_domain(rt_config)
        domains = osl_rt_domains(rt_config)

        config_options = {}
        config_options['$rtname'] = rt_config['fqdn']
        config_options['$WebDomain'] = rt_config['fqdn']
        # When TLS terminates upstream (HAProxy) and RT serves plain HTTP, RT
        # otherwise assumes http://<fqdn>:80 and rejects HTTPS form posts with a
        # "possible cross-site request forgery" error (the browser Referer is :443).
        # 'web-port' (e.g. 443) makes RT treat itself as HTTPS; 'web-base-url'
        # overrides the full base URL when the public URL isn't derivable from the
        # fqdn + port (different host, a WebPath prefix, etc.).
        config_options['$WebPort'] = rt_config['web-port'] if rt_config['web-port']
        config_options['$WebBaseURL'] = rt_config['web-base-url'] if rt_config['web-base-url']
        config_options['$Organization'] = mail_domain
        config_options['$CorrespondAddress'] = "#{rt_config['user']}@#{mail_domain}"
        config_options['$CommentAddress'] = "#{rt_config['user']}-comment@#{mail_domain}"
        config_options['$DatabaseType'] = rt_config['db']['type']
        config_options['$DatabaseHost'] = rt_config['db']['host']
        config_options['$DatabaseRTHost'] = rt_config['db']['host']
        config_options['$DatabaseName'] = rt_config['db']['name']
        config_options['$DatabaseUser'] = rt_config['db-username']
        config_options['$DatabasePassword'] = rt_config['db-password']
        config_options['_Plugins'] = osl_rt_plugins(rt_config['plugins']) if rt_config['plugins']
        config_options['_Lifecycles'] = rt_config['lifecycles'] if rt_config['lifecycles']

        # Optional branding. The recipe fetches the logo image; the link/alt are
        # plain strings. Overridable via 'extra-config' (merged below).
        if rt_config['logo']
          logo = rt_config['logo']
          config_options['$LogoURL'] = "/static/images/#{::File.basename(logo['url'])}" if logo['url']
          config_options['$LogoLinkURL'] = logo['link'] if logo['link']
          config_options['$LogoAltText'] = logo['alt'] if logo['alt']
        end

        # Queue emails (sorted, non-nil) drive $RTAddressRegexp below. The postfix
        # aliases/transports that actually route this mail are built separately by
        # osl_rt_postfix_aliases / osl_rt_postfix_transports and handed to the
        # osl_postfix_server resource in osl_request_tracker.
        rt_emails = osl_rt_emails(rt_config)

        # Match "<email>" and "<email>-comment" at any of our delivery domains.
        # The joined emails MUST be wrapped in their own group, otherwise the
        # trailing "(-comment)?@(domains)" only binds to the last alternative.
        domain_re = domains.map { |d| d.gsub('.', '\\.') }.join('|')
        config_options['$RTAddressRegexp'] = "^((#{rt_emails.join('|')})(-comment)?@(#{domain_re}))$"

        # RT runs under apache, so by default outgoing mail's envelope sender is
        # apache@<fqdn> and bounces dead-end at the local apache/root mailbox. Use
        # each queue's correspond address as the envelope sender instead so bounces
        # return to a real RT address. Overridable via 'extra-config' (merged below).
        config_options['$SetOutgoingMailFrom'] = 1

        # Merge any raw RT options provided in the data bag (e.g. '$Timezone',
        # '$DefaultQueue', '%FullTextSearch'). These are emitted verbatim by
        # parse_config, so the keys must be valid RT config names.
        config_options.merge!(rt_config['extra-config']) if rt_config['extra-config']

        # Since this is recipe-driven, go straight to parsing the config options,
        # then append the drop-in loader and return the final config file.
        parse_config(config_options) + osl_rt_siteconfig_loader
      end

      # Trailing stanza appended to RT_SiteConfig.pm: load any *.pm dropped into
      # RT_SiteConfig.d (in sorted order) AFTER the options above, so a wrapping
      # cookbook can supply config that parse_config can't express -- notably
      # nested hashrefs like $ExternalSettings (RT::Authen::ExternalAuth) or
      # $ServiceAgreements (RT::Extension::SLA). The closing `1;` keeps the
      # require truthy even when the glob matches nothing.
      def osl_rt_siteconfig_loader
        <<~PERL

          # Drop-in site configuration (managed by wrapping cookbooks). Loaded last
          # so these files can override anything set above.
          do $_ for sort glob('/opt/rt/etc/RT_SiteConfig.d/*.pm');
          1;
        PERL
      end

      # The public email domain, defaulting to the host fqdn when unset
      def osl_rt_mail_domain(rt_config)
        rt_config['mail-domain'] || rt_config['fqdn']
      end

      # All domains mail may be delivered to locally (host fqdn + public domain)
      def osl_rt_domains(rt_config)
        [rt_config['fqdn'], osl_rt_mail_domain(rt_config)].uniq
      end

      # Mail users that receive RT mail: the RT user, plus the optional forward
      # user (the two-user split, where a dedicated user forwards a copy off-box).
      def osl_rt_mail_users(rt_config)
        [rt_config['user'], rt_config['forward-user']].compact
      end

      # The queue emails (sorted, non-nil) used to build $RTAddressRegexp.
      def osl_rt_emails(rt_config)
        rt_config['queues'].values.compact.sort
      end

      # Postfix aliases handed to osl_postfix_server. Self-alias each mail user so
      # its mailbox (and ~/.procmailrc) gets RT mail, overriding any system default
      # like "support: postmaster"; then map every queue email (and its -comment
      # variant) to the mail user(s). A queue email that is also a mail user is
      # overridden by the queue mapping (which fans out to the forward user too).
      # osl_postfix_server seeds the OSL system aliases underneath these.
      def osl_rt_postfix_aliases(rt_config)
        mail_users = osl_rt_mail_users(rt_config)
        target = mail_users.join(', ')
        aliases = {}
        mail_users.each { |u| aliases[u] = u }
        rt_config['queues'].each_value do |email|
          next if email.nil?
          aliases[email] = target
          aliases["#{email}-comment"] = target
        end
        aliases
      end

      # Postfix transports handed to osl_postfix_server: route every queue email
      # (and its -comment variant) at each delivery domain to local delivery, so
      # rt-mailgate/procmail handle it.
      def osl_rt_postfix_transports(rt_config, domains)
        transports = {}
        rt_config['queues'].each_value do |email|
          next if email.nil?
          domains.each do |domain|
            transports["#{email}@#{domain}"] = 'local:$myhostname'
            transports["#{email}-comment@#{domain}"] = 'local:$myhostname'
          end
        end
        transports
      end

      # Postfix map db type for transport_maps. EL10 dropped Berkeley DB ('hash')
      # from postfix in favor of 'lmdb'; older platforms keep 'hash'.
      def osl_rt_postfix_db_type
        node['platform_version'].to_i >= 10 ? 'lmdb' : 'hash'
      end

      # Shell guard (for not_if/only_if) that succeeds when the SQL SELECT returns
      # a row, so one-time DB/queue steps key off real DB state and skip an
      # imported DB. Dispatches to the client for the configured engine.
      def osl_rt_db_guard(rt_config, query)
        if osl_rt_pg?(rt_config)
          "PGPASSWORD='#{rt_config['db-password']}' psql -h #{rt_config['db']['host']} " \
            "-U #{rt_config['db-username']} -tAc \"#{query}\" #{rt_config['db']['name']} 2>/dev/null | grep -q ."
        else
          "mysql -u #{rt_config['db-username']} -p#{rt_config['db-password']} " \
            "-N -B -e \"#{query}\" #{rt_config['db']['name']} 2>/dev/null | grep -q ."
        end
      end

      # Query that yields a row only once RT's schema has been loaded, used to
      # skip DB init (and the root-password set) against an already-populated
      # database. MySQL uses SHOW TABLES; Postgres folds the unquoted table name
      # to lowercase, so to_regclass('users') is non-null once the table exists.
      def osl_rt_schema_present_query(rt_config)
        osl_rt_pg?(rt_config) ? "SELECT to_regclass('users')" : "SHOW TABLES LIKE 'Users'"
      end

      # Command to set RT's root password directly in the DB, fired only on a
      # fresh init (never on import). RT accepts a bare MD5 hash, which both
      # engines' md5() function produces over the cleartext password.
      def osl_rt_set_root_password_command(rt_config)
        if osl_rt_pg?(rt_config)
          <<~EOC
            PGPASSWORD='#{rt_config['db-password']}' psql -h #{rt_config['db']['host']} \
              -U #{rt_config['db-username']} \
              -c "UPDATE Users SET Password=md5('#{rt_config['root-password']}') WHERE Name='root';" \
              #{rt_config['db']['name']}
          EOC
        else
          <<~EOC
            mysql -u #{rt_config['db-username']} \
              -p#{rt_config['db-password']} \
              -e 'UPDATE Users \
                SET Password=md5("#{rt_config['root-password']}") \
                WHERE Name="root";' \
              #{rt_config['db']['name']}
          EOC
        end
      end

      # The plugin list to load, dropping any that ship in core on RT 5 (EL10+).
      def osl_rt_plugins(plugins)
        return plugins unless osl_rt_rt5?

        dropped = plugins & RT5_CORE_PLUGINS
        unless dropped.empty?
          Chef::Log.warn(
            "osl-rt: not loading #{dropped.join(', ')} as plugin(s); merged into RT 5 core on this platform"
          )
        end
        plugins - RT5_CORE_PLUGINS
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
          if key.start_with?('%')
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
          # RT expects 'actions' as an ordered arrayref of 'from -> to' => {...}
          # pairs, but it is most naturally expressed as a hash in a data bag.
          # Convert it so ordering is preserved and RT parses it correctly.
          if key == 'actions' && value.is_a?(Hash)
            strConfig += "#{ind}'actions' => [\n"
            value.each do |transition, opts|
              strConfig += "#{ind}\t'#{transition}' => {\n#{parse_lifecycle_ht(opts, nIndent + 2)}#{ind}\t},\n"
            end
            strConfig += "#{ind}],\n"
            next
          end
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
    end
  end
end

Chef::DSL::Recipe.include ::OslRT::Cookbook::Helpers
Chef::Resource.include ::OslRT::Cookbook::Helpers
