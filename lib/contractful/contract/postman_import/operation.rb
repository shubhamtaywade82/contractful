# frozen_string_literal: true

module Contractful
  module Contract
    module PostmanImport
      # One Postman request as a contract {Definition}, or a note saying why it
      # cannot become one.
      module Operation
        VERBS = %w[get put post patch delete head options].freeze
        # A built operation: its definition, the origin it calls and its auth.
        Result = Struct.new(:definition, :origin, :auth, keyword_init: true)

        module_function

        def build(item, scope)
          request = item['request']
          verb = request['method'].to_s.downcase
          return unsupported(item, verb, scope) unless VERBS.include?(verb)

          build_request(item, request, verb, scope)
        rescue Url::Unresolved, Contract::InvalidDefinition => e
          scope.note("#{item['name'] || 'request'}: #{e.message} — skipped")
          nil
        end

        def build_request(item, request, verb, scope)
          parsed = Url.parse(request['url'], scope.variables)
          definition = new_definition(item, verb, parsed, request, scope)
          add_parts(definition, request, parsed, "#{verb.upcase} #{parsed.path}", scope)
          Result.new(definition: definition, origin: parsed.origin, auth: request['auth'])
        end

        def unsupported(item, verb, scope)
          scope.note("#{item['name'] || 'request'}: #{verb.upcase} is not a supported method — skipped")
          nil
        end

        def new_definition(item, verb, parsed, request, scope)
          Definition.new(scope.name_for(item, verb, parsed.path), verb.to_sym, parsed.path,
                         description: description(request))
        end

        def add_parts(definition, request, parsed, label, scope)
          add_query(definition, parsed.query, scope, label)
          add_headers(definition, request['header'], scope, label)
          Body.apply(definition, request['body'], scope, label)
        end

        def description(request)
          text = request['description']
          text = text['content'] if text.is_a?(Hash)
          text.is_a?(String) && !text.empty? ? text : nil
        end

        # Query keys become untyped, optional params; the example values are not kept.
        def add_query(definition, pairs, scope, label)
          pairs.map(&:first).each { |name| add_query_key(definition, name, scope, label) }
        end

        def add_query_key(definition, name, scope, label)
          unless name.match?(PostmanImport::IDENTIFIER)
            return scope.note("#{label}: query parameter #{name.inspect} is not a valid identifier — skipped")
          end
          if definition.params.key?(name.to_sym)
            return scope.note("#{label}: query parameter #{name.inspect} collides with another param — skipped")
          end

          definition.param(name.to_sym)
        end

        def add_headers(definition, headers, scope, label)
          PostmanImport.enabled(headers).each do |header|
            name = header['key'].to_s
            next if not_mapped_header?(name, scope, label)

            add_header(definition, name, header['value'].to_s, scope, label)
          end
        end

        def not_mapped_header?(name, scope, label)
          case name.downcase
          when 'content-type' then true # the body decides the content type
          when 'authorization'
            scope.note("#{label}: Authorization is not mapped; declare auth (see the auth hints)")
            true
          else false
          end
        end

        # A static value becomes the default, so the header is sent unless the caller
        # overrides it; a value with a variable is left for the caller to supply.
        def add_header(definition, name, value, scope, label)
          key = OpenAPIImport.header_param_key(name)
          unless name.match?(Param::HTTP_TOKEN) && key && !definition.params.key?(key)
            return scope.note("#{label}: header #{name.inspect} cannot be declared (name or duplicate) — skipped")
          end
          return definition.param(key, String, header: name) if value.empty? || value.include?('{{')
          unless Param::HEADER_VALUE.match?(value)
            return scope.note("#{label}: header #{name.inspect} has control characters in its value — skipped")
          end

          definition.param(key, String, header: name, default: value)
        end
      end
    end
  end
end
