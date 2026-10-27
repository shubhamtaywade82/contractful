# frozen_string_literal: true

require 'json'

module Contractful
  module Contract
    module PostmanImport
      # A Postman request body as contract params. Example values carry no schema,
      # so body fields are untyped. A JSON example also turns off strict params for
      # its operation, because the example may omit fields the API accepts.
      module Body
        module_function

        def apply(definition, body, scope, label)
          return unless body.is_a?(Hash)

          case body['mode']
          when 'raw' then raw(definition, body['raw'].to_s, scope, label)
          when 'urlencoded' then form(definition, PostmanImport.enabled(body['urlencoded']), scope, label)
          when 'formdata' then formdata(definition, PostmanImport.enabled(body['formdata']), scope, label)
          when 'graphql' then graphql(definition, scope, label)
          when nil, '', 'none' then nil
          else scope.note("#{label}: body mode #{body['mode'].inspect} is not representable — skipped")
          end
        end

        def raw(definition, text, scope, label)
          return if text.strip.empty?

          json = object_of(text)
          return scope.note("#{label}: raw body is not a JSON object — declare params manually") unless json

          definition.strict_params(false)
          scope.inferred_body = true
          declare(definition, json.keys, scope, label)
        end

        def object_of(text)
          json = JSON.parse(text)
          json.is_a?(Hash) ? json : nil
        rescue JSON::ParserError
          nil
        end

        def form(definition, entries, scope, label)
          return if entries.empty?

          definition.payload_style(:form)
          declare(definition, entries.map { |entry| entry['key'] }, scope, label)
        end

        def formdata(definition, entries, scope, label)
          if entries.any? { |entry| entry['type'] == 'file' }
            return scope.note("#{label}: multipart body with file fields is not representable — skipped")
          end

          form(definition, entries, scope, label)
        end

        # The GraphQL body is a JSON object: {"query": ..., "variables": ...}.
        def graphql(definition, scope, label)
          if definition.params.key?(:query)
            return scope.note("#{label}: a param named query already exists — GraphQL body skipped")
          end

          definition.param(:query, String, required: true)
          definition.param(:variables, Hash)
        end

        def declare(definition, names, scope, label)
          names.each { |name| declare_field(definition, name.to_s, scope, label) }
        end

        def declare_field(definition, name, scope, label)
          unless name.match?(PostmanImport::IDENTIFIER)
            return scope.note("#{label}: body field #{name.inspect} is not a valid identifier — skipped")
          end
          if definition.params.key?(name.to_sym)
            return scope.note("#{label}: body field #{name.inspect} collides with another param — skipped")
          end

          definition.param(name.to_sym)
        end
      end
    end
  end
end
