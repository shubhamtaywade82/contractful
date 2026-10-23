# frozen_string_literal: true

require_relative 'swagger2/references'
require_relative 'swagger2/parameters'
require_relative 'swagger2/operations'
require_relative 'swagger2/components'

module Contractful
  module Contract
    # Converts a Swagger 2.0 document into the OpenAPI 3.0 shape that
    # {OpenAPIImport} reads. The conversion is structural and covers the
    # constructs the importer maps: paths and operations, parameters (path,
    # query, header, body and formData), responses, definitions and security.
    # Everything else is copied through unchanged.
    #
    # Opt-in, like {OpenAPIImport}: it is loaded by
    # <tt>require 'contractful/contract/openapi_import'</tt>.
    module Swagger2
      module_function

      # @return [Boolean] true for a Hash that declares a Swagger 2.x version
      def swagger?(doc)
        doc.is_a?(Hash) && doc['swagger'].to_s.start_with?('2.')
      end

      # Convert a Swagger 2.0 document (a Hash) into an OpenAPI 3.0.3 Hash. The
      # input is not modified.
      def convert(doc)
        root = References.translate(doc)
        { 'openapi' => '3.0.3', 'x-contractful-source' => 'Swagger 2.0' }
          .merge(document_fields(root))
          .merge(root.select { |key, _| key.to_s.start_with?('x-') })
      end

      def document_fields(root)
        fields = { 'servers' => Components.servers(root), 'paths' => Operations.convert_paths(root) }
        fields['info'] = root['info'] if root['info']
        fields['security'] = root['security'] if root['security']
        components = Components.components(root)
        fields['components'] = components unless components.empty?
        fields
      end

      # Map a Swagger 2.0 $ref fragment to its OpenAPI 3.0 location, for refs
      # from other files into a converted document.
      def translate_pointer(fragment)
        References.translate_pointer(fragment)
      end

      def list(value)
        value.is_a?(Array) ? value : []
      end
    end
  end
end
