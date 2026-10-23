# frozen_string_literal: true

require 'uri'

module Contractful
  module Contract
    module PostmanImport
      # Turns a Postman request URL into an origin, a path template and query
      # pairs. {{variables}} resolve from the collection and the caller. The
      # origin and the path must resolve, since a contract needs both.
      module Url
        VARIABLE = /\{\{\s*([^{}\s]+)\s*\}\}/
        ABSOLUTE = %r{\A([a-zA-Z][a-zA-Z0-9+.-]*://[^/]+)(/.*)?\z}

        # The origin and path of a request, and its enabled query pairs.
        Parsed = Struct.new(:origin, :path, :query, keyword_init: true)

        # Raised when the origin or the path cannot be resolved.
        class Unresolved < StandardError; end

        module_function

        def parse(request_url, variables)
          text = substitute(raw(request_url), variables)
          main, query_text = text.split('?', 2)
          main ||= ''
          variable = main.scan(VARIABLE).first
          raise Unresolved, "unresolved variable {{#{variable.first}}}" if variable

          match = ABSOLUTE.match(main)
          raise Unresolved, "no absolute URL for #{main.inspect}" unless match

          Parsed.new(origin: match[1], path: match[2] || '/', query: query(request_url, query_text))
        end

        # The URL as one string: Postman stores it as a string or as an object.
        def raw(request_url)
          return request_url if request_url.is_a?(String)
          return '' unless request_url.is_a?(Hash)
          return request_url['raw'].to_s if request_url['raw']

          "#{scheme_of(request_url)}#{authority(request_url)}#{path_of(request_url)}"
        end

        def scheme_of(request_url)
          request_url['protocol'] ? "#{request_url['protocol']}://" : ''
        end

        def authority(request_url)
          host = Array(request_url['host']).join('.')
          request_url['port'] ? "#{host}:#{request_url['port']}" : host
        end

        def path_of(request_url)
          path = Array(request_url['path']).join('/')
          path.empty? ? '' : "/#{path}"
        end

        def substitute(text, variables)
          text.gsub(VARIABLE) do
            name = Regexp.last_match(1)
            variables.fetch(name) { "{{#{name}}}" }
          end
        end

        # The object form's query list wins over the query text of the raw URL.
        def query(request_url, query_text)
          if request_url.is_a?(Hash) && request_url['query']
            return PostmanImport.enabled(request_url['query']).map { |entry| [entry['key'].to_s, entry['value'].to_s] }
          end
          return [] unless query_text

          URI.decode_www_form(query_text)
        rescue ArgumentError
          []
        end
      end
    end
  end
end
