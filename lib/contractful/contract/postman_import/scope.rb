# frozen_string_literal: true

module Contractful
  module Contract
    module PostmanImport
      # The notes and contract names of one import.
      class Scope
        attr_reader :variables, :notes
        attr_writer :inferred_body

        def initialize(variables)
          @variables = variables
          @notes = []
          @names = OpenAPIImport::Context.new({})
          @inferred_body = false
        end

        def note(message)
          @notes << message unless @notes.include?(message)
        end

        def inferred_body?
          @inferred_body
        end

        # A contract name from the request name, or from the method and path when
        # the request has no usable name.
        def name_for(item, verb, path)
          base = OpenAPIImport.snake_case(item['name'].to_s).gsub(/[^a-zA-Z0-9_]+/, '_').gsub(/\A_+|_+\z/, '')
          base = "#{verb} #{path}".gsub(/[^a-zA-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '') if base.empty?
          base = "_#{base}" if base.match?(/\A\d/)
          @names.unique_name(base)
        end
      end
    end
  end
end
