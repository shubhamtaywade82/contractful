# frozen_string_literal: true

module RestClient
  module Contract
    # The definition of a single API operation — one "contract".
    #
    # A Definition is built from a request line (<tt>'POST /repos/:owner/:repo/issues'</tt>)
    # plus an optional DSL block that is +instance_eval+'d against the
    # definition object itself, so every statement in the block is a method
    # call on the definition:
    #
    #   contract :create_issue, 'POST /repos/:owner/:repo/issues' do
    #     param :owner, String, required: true
    #     param :title, String, required: true
    #     param :labels, Array, default: []
    #   end
    #
    # Path placeholders (+:owner+, +:repo+) are automatically synthesized as
    # required params unless they were explicitly declared.
    class Definition
      PATH_PLACEHOLDER = /:([a-zA-Z_][a-zA-Z0-9_]*)/.freeze

      VALID_VERBS = %i[get head post put patch delete options].freeze

      attr_reader :name, :verb, :path_template, :params, :description

      def initialize(name, verb, path_template, description: nil, &block)
        @name = name.to_sym
        @verb = verb.to_s.downcase.to_sym
        @path_template = path_template.dup
        @description = description
        @params = {}
        @payload_style = nil

        validate_verb!
        validate_path_template!
        synthesize_path_params!

        # The DSL block is instance_eval'd against the definition, so every
        # statement inside it is a method call on this object. It runs after
        # path-param synthesis so explicit declarations win.
        instance_eval(&block) if block
      end

      # --- DSL surface (evaluated inside the contract block) -----------------

      # Declare a parameter. See {Param} for the supported options.
      def param(name, type = nil, **options)
        key = name.to_sym
        @params[key] = Param.new(key, type, **options)
      end

      # Declare the payload style for non-query params:
      # +:json+ (default for POST/PUT/PATCH), +:form+ or +:query+.
      def payload_style(style = nil)
        return @payload_style if style.nil?

        unless %i[json form query].include?(style.to_sym)
          raise InvalidDefinition,
                "invalid payload_style #{style.inspect} for :#{@name} " \
                '(expected :json, :form or :query)'
        end
        @payload_style = style.to_sym
      end

      # --- path handling -----------------------------------------------------

      # Symbols referenced as +:placeholders+ in the path template.
      def path_param_names
        @path_param_names ||=
          @path_template.scan(PATH_PLACEHOLDER).map { |m| m[0].to_sym }
      end

      # Expand the path template with (already coerced) +params+.
      #
      # @return [Array(String, Hash)] the expanded path and the remaining
      #   params that were not consumed by placeholders
      def expand_path(params)
        remaining = params.dup
        expanded = @path_template.gsub(PATH_PLACEHOLDER) do
          key = Regexp.last_match(1).to_sym
          unless remaining.key?(key)
            raise MissingParam,
                  "path param :#{key} is required by #{@path_template.inspect} " \
                  'but was not provided'
          end
          escape_path_segment(remaining.delete(key))
        end
        [expanded, remaining]
      end

      def escape_path_segment(value)
        URI.encode_www_form_component(value.to_s).gsub('+', '%20')
      end

      # --- introspection -----------------------------------------------------

      # One-line description, e.g. <tt>"POST /repos/:owner/:repo/issues (params: :owner, :repo, :title)"</tt>.
      def describe
        parts = ["#{verb.to_s.upcase} #{path_template}"]
        if @params.any?
          parts << "(params: #{@params.keys.map { |k| ":#{k}" }.join(', ')})"
        end
        parts.join(' ')
      end

      def inspect
        "#<RestClient::Contract::Definition #{describe}>"
      end

      private

      def validate_verb!
        unless VALID_VERBS.include?(@verb)
          raise InvalidDefinition,
                "unsupported HTTP verb #{verb.to_s.inspect} for :#{@name} " \
                "(supported: #{VALID_VERBS.join(', ')})"
        end
      end

      def validate_path_template!
        unless @path_template.start_with?('/')
          raise InvalidDefinition,
                "path template #{@path_template.inspect} for :#{@name} must " \
                'start with "/" (it is resolved against the base URL)'
        end
      end

      # Every +:placeholder+ in the path template is implicitly a required
      # String param unless the user declared it explicitly.
      def synthesize_path_params!
        path_param_names.each do |key|
          next if @params.key?(key)

          @params[key] = Param.new(key, nil, required: true,
                                             description: 'path parameter (auto-synthesized)')
        end
      end
    end
  end
end
