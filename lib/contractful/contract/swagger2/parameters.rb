# frozen_string_literal: true

module Contractful
  module Contract
    module Swagger2
      # Path, query and header parameters keep a schema, which Swagger 2.0 keeps
      # inline. Body and formData parameters become one requestBody.
      module Parameters
        LOCATIONS = %w[path query header].freeze
        SCHEMA_KEYS = %w[type format items enum default minimum maximum exclusiveMinimum exclusiveMaximum
                         minLength maxLength pattern minItems maxItems uniqueItems multipleOf].freeze

        module_function

        # Path-level and operation-level parameters. The operation wins on the
        # same name and location, and parameter references resolve to their
        # definition.
        def merge(root, raw)
          raw.each_with_object({}) do |node, merged|
            param = resolve(root, node)
            merged[[param['in'], param['name']]] = param if param.is_a?(Hash)
          end.values
        end

        def resolve(root, node)
          match = %r{\A#/components/parameters/(.+)\z}.match(node.is_a?(Hash) ? node['$ref'].to_s : '')
          return node unless match

          global = root['parameters']
          global.is_a?(Hash) ? global[match[1]] : nil
        end

        def locational(params)
          params.select { |param| LOCATIONS.include?(param['in']) }.map { |param| convert(param) }
        end

        def convert(param)
          out = { 'name' => param['name'], 'in' => param['in'] }
          out['required'] = true if param['required'] == true || param['in'] == 'path'
          out['description'] = param['description'] if param['description']
          out['schema'] = simple_schema(param)
          out
        end

        # A Swagger 2.0 non-body parameter carries its schema inline.
        def simple_schema(node)
          schema = node.slice(*SCHEMA_KEYS)
          if schema['type'] == 'file'
            schema['type'] = 'string'
            schema['format'] = 'binary'
          end
          schema['items'] = simple_schema(schema['items']) if schema['items'].is_a?(Hash)
          schema
        end

        def request_body(params, consumes)
          body = params.find { |param| param['in'] == 'body' }
          return body_content(body, consumes) if body

          form = params.select { |param| param['in'] == 'formData' }
          form_content(form, consumes) unless form.empty?
        end

        def body_content(body, consumes)
          media = consumes.first || 'application/json'
          { 'required' => body['required'] == true,
            'content' => { media => { 'schema' => body['schema'] || {} } } }
        end

        def form_content(form, consumes)
          media = multipart?(form, consumes) ? 'multipart/form-data' : 'application/x-www-form-urlencoded'
          { 'content' => { media => { 'schema' => form_schema(form) } } }
        end

        # A file field selects multipart; otherwise the body is urlencoded.
        def multipart?(form, consumes)
          consumes.include?('multipart/form-data') || form.any? { |param| param['type'] == 'file' }
        end

        def form_schema(form)
          schema = { 'type' => 'object', 'properties' => form.to_h { |param| [param['name'], form_property(param)] } }
          required = form.select { |param| param['required'] == true }.map { |param| param['name'] }
          required.empty? ? schema : schema.merge('required' => required)
        end

        def form_property(param)
          schema = simple_schema(param)
          param['description'] ? schema.merge('description' => param['description']) : schema
        end
      end
    end
  end
end
