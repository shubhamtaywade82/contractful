# frozen_string_literal: true

module Contractful
  module Contract
    module Swagger2
      # Swagger 2.0 keeps definitions, parameters and responses in top-level
      # sections; OpenAPI 3.0 keeps them under components. Local $refs follow.
      module References
        SECTIONS = { 'definitions' => 'schemas', 'parameters' => 'parameters', 'responses' => 'responses' }.freeze

        module_function

        # Copy a document with its local $refs translated. Memoized by identity,
        # so YAML aliases and cycles copy once and terminate.
        def translate(node, memo = {}.compare_by_identity)
          case node
          when Hash then translate_hash(node, memo)
          when Array then translate_array(node, memo)
          else node
          end
        end

        def translate_hash(node, memo)
          return memo[node] if memo.key?(node)

          out = memo[node] = {}
          node.each do |key, value|
            out[key] = key == '$ref' && value.is_a?(String) ? translate_ref(value) : translate(value, memo)
          end
          out
        end

        def translate_array(node, memo)
          return memo[node] if memo.key?(node)

          out = memo[node] = []
          node.each { |value| out << translate(value, memo) }
          out
        end

        def translate_ref(ref)
          ref.start_with?('#') ? "##{translate_pointer(ref[1..])}" : ref
        end

        def translate_pointer(fragment)
          return nil if fragment.nil?

          fragment.sub(%r{\A/(definitions|parameters|responses)(?=/|\z)}) do
            "/components/#{SECTIONS.fetch(Regexp.last_match(1))}"
          end
        end
      end
    end
  end
end
