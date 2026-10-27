# frozen_string_literal: true

module Contractful
  module Contract
    module PostmanImport
      # Postman auth objects as commented-out auth hints, the way the OpenAPI import
      # writes securitySchemes. Credentials are never invented: each hint reads its
      # value from an environment variable named after the collection.
      module Auth
        module_function

        def hints(auth, prefix)
          return [] unless auth.is_a?(Hash)

          case auth['type']
          when 'bearer' then ["auth bearer: -> { ENV['#{prefix}_TOKEN'] } # Postman auth: bearer"]
          when 'basic' then [basic_hint(prefix)]
          when 'apikey' then apikey_hint(auth, prefix)
          else []
          end
        end

        def basic_hint(prefix)
          "auth basic: -> { [ENV['#{prefix}_USER'], ENV['#{prefix}_PASSWORD']] } # Postman auth: basic"
        end

        def apikey_hint(auth, prefix)
          settings = PostmanImport.list(auth['apikey']).grep(Hash)
                                  .to_h { |entry| [entry['key'].to_s, entry['value'].to_s] }
          return [] if settings['key'].to_s.empty?

          location = settings['in'] == 'query' ? ', in: :query' : ''
          ["auth api_key: { name: #{settings['key'].inspect}, value: -> { ENV['#{prefix}_API_KEY'] }#{location} } " \
           '# Postman auth: apikey']
        end
      end
    end
  end
end
