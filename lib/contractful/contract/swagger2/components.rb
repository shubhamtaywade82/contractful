# frozen_string_literal: true

module Contractful
  module Contract
    module Swagger2
      # Servers, definitions and security. Swagger 2.0 keeps these at the top
      # level; OpenAPI 3.0 keeps the reusable parts under components.
      module Components
        # Swagger 2.0 OAuth2 flow names, mapped to OpenAPI 3.0 flow names.
        FLOWS = {
          'implicit' => 'implicit', 'password' => 'password',
          'application' => 'clientCredentials', 'accessCode' => 'authorizationCode'
        }.freeze

        module_function

        def servers(root)
          url = root['host'] ? "#{scheme(root)}://#{root['host']}#{root['basePath']}" : root['basePath'].to_s
          url.empty? ? [] : [{ 'url' => url }]
        end

        # https when offered, otherwise the first listed scheme.
        def scheme(root)
          schemes = Swagger2.list(root['schemes'])
          schemes.include?('https') ? 'https' : (schemes.first || 'https')
        end

        def components(root)
          out = {}
          out['schemas'] = root['definitions'] if root['definitions'].is_a?(Hash)
          definitions = root['securityDefinitions']
          out['securitySchemes'] = security_schemes(definitions) if definitions.is_a?(Hash)
          out.merge(global_components(root))
        end

        def global_components(root)
          out = {}
          out['parameters'] = global_parameters(root['parameters']) if root['parameters'].is_a?(Hash)
          out['responses'] = global_responses(root) if root['responses'].is_a?(Hash)
          out
        end

        # Body parameters have no OpenAPI 3.0 parameter form; they are left out.
        def global_parameters(params)
          params.each_with_object({}) do |(name, param), out|
            out[name] = Parameters.convert(param) if param.is_a?(Hash) && param['in'] != 'body'
          end
        end

        def global_responses(root)
          produces = Swagger2.list(root['produces'])
          root['responses'].each_with_object({}) do |(name, response), out|
            out[name] = Operations.convert_response(response, produces) if response.is_a?(Hash)
          end
        end

        def security_schemes(definitions)
          definitions.each_with_object({}) do |(name, definition), out|
            scheme = definition.is_a?(Hash) ? security_scheme(definition) : nil
            out[name] = scheme if scheme
          end
        end

        def security_scheme(definition)
          case definition['type']
          when 'basic' then { 'type' => 'http', 'scheme' => 'basic' }
          when 'apiKey' then { 'type' => 'apiKey', 'name' => definition['name'], 'in' => definition['in'] }
          when 'oauth2' then oauth_scheme(definition)
          end
        end

        def oauth_scheme(definition)
          flow = FLOWS[definition['flow'].to_s]
          return nil unless flow

          settings = { 'scopes' => definition['scopes'].is_a?(Hash) ? definition['scopes'] : {} }
          settings['authorizationUrl'] = definition['authorizationUrl'] if definition['authorizationUrl']
          settings['tokenUrl'] = definition['tokenUrl'] if definition['tokenUrl']
          { 'type' => 'oauth2', 'flows' => { flow => settings } }
        end
      end
    end
  end
end
