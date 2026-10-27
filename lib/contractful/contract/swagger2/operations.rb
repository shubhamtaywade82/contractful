# frozen_string_literal: true

module Contractful
  module Contract
    module Swagger2
      # Paths, operations and responses. Each Swagger 2.0 operation becomes an
      # OpenAPI 3.0 operation with the same identity fields.
      module Operations
        HTTP_METHODS = %w[get put post patch delete head options].freeze
        # Swagger 2.0 fields that have no operation-level OpenAPI 3.0 form.
        DROPPED = %w[parameters consumes produces responses schemes].freeze

        module_function

        def convert_paths(root)
          paths = root['paths'].is_a?(Hash) ? root['paths'] : {}
          paths.each_with_object({}) do |(path, item), out|
            out[path] = convert_item(root, item) if item.is_a?(Hash)
          end
        end

        def convert_item(root, item)
          shared = Swagger2.list(item['parameters'])
          item.each_with_object({}) do |(key, value), ops|
            if HTTP_METHODS.include?(key.to_s)
              ops[key] = convert_operation(root, value, shared)
            elsif key.to_s.start_with?('x-')
              ops[key] = value
            end
          end
        end

        def convert_operation(root, operation, shared)
          return {} unless operation.is_a?(Hash)

          consumes = media_types(root, operation, 'consumes')
          produces = media_types(root, operation, 'produces')
          params = Parameters.merge(root, shared + Swagger2.list(operation['parameters']))
          out = operation.except(*DROPPED).merge('parameters' => Parameters.locational(params))
          body = Parameters.request_body(params, consumes)
          out['requestBody'] = body if body
          out.merge('responses' => convert_responses(operation['responses'], produces))
        end

        # The operation's own media types, or the document-level ones.
        def media_types(root, operation, key)
          own = Swagger2.list(operation[key])
          own.empty? ? Swagger2.list(root[key]) : own
        end

        def convert_responses(responses, produces)
          return {} unless responses.is_a?(Hash)

          responses.each_with_object({}) do |(code, response), out|
            next unless response.is_a?(Hash)

            out[code.to_s] = response['$ref'] ? { '$ref' => response['$ref'] } : convert_response(response, produces)
          end
        end

        def convert_response(response, produces)
          out = { 'description' => response['description'].to_s }
          if response['schema'].is_a?(Hash)
            media = produces.first || 'application/json'
            out['content'] = { media => { 'schema' => response_schema(response['schema']) } }
          end
          out['headers'] = convert_headers(response['headers']) if response['headers'].is_a?(Hash)
          out
        end

        def convert_headers(headers)
          headers.transform_values { |header| { 'schema' => Parameters.simple_schema(header) } }
        end

        def response_schema(schema)
          schema['type'] == 'file' ? { 'type' => 'string', 'format' => 'binary' } : schema
        end
      end
    end
  end
end
