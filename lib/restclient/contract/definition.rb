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

      # Symbol aliases for response body types. +:json+ means "must parse as
      # JSON" without constraining the shape; +Array+/+Hash+ also parse and
      # additionally check the parsed shape.
      RESPONSE_TYPES = {
        array: Array,
        hash: Hash,
        string: String,
        json: :json,
      }.freeze

      attr_reader :name, :verb, :path_template, :params, :description
      attr_reader :response_statuses, :response_type, :response_verifier

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

      # Declare the expected responses: one or more status codes (Integers or
      # Ranges) and an optional body +type+ (Array, Hash, String, any class or
      # the symbols :array/:hash/:string/:json).
      #
      # When the declared statuses include error codes (4xx/5xx), the default
      # rest-client exception behavior is suppressed for this contract and
      # every response is judged by the contract instead; a status outside
      # the declared set raises {UnexpectedResponse}.
      def responds(*statuses, type: nil)
        if statuses.empty?
          raise InvalidDefinition,
                "responds requires at least one status for :#{@name}"
        end
        statuses.each do |status|
          unless valid_status?(status)
            raise InvalidDefinition,
                  "invalid status #{status.inspect} for :#{@name} " \
                  '(expected an Integer or an Integer Range)'
          end
        end
        @response_statuses = statuses.freeze
        @response_type = normalize_response_type(type) if type
      end

      # Register a custom assertion block. It receives the response (and the
      # JSON-parsed body when declared with two parameters); a falsey return
      # value raises {UnexpectedResponse}. Raising inside the block
      # propagates untouched.
      def verify_response(&block)
        unless block
          raise InvalidDefinition,
                "verify_response requires a block for :#{@name}"
        end
        @response_verifier = block
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

      # One-line description, e.g. <tt>"POST /repos/:owner/:repo/issues (params: :owner, :repo, :title) responds 200, 404 => Hash"</tt>.
      def describe
        parts = ["#{verb.to_s.upcase} #{path_template}"]
        if @params.any?
          parts << "(params: #{@params.keys.map { |k| ":#{k}" }.join(', ')})"
        end
        if @response_statuses
          rendered = @response_statuses.map { |s| s.is_a?(Range) ? s.inspect : s.to_s }
          response_part = "responds #{rendered.join(', ')}"
          if @response_type
            response_part << " => #{response_type_name}"
          end
          parts << response_part
        end
        parts.join(' ')
      end

      def inspect
        "#<RestClient::Contract::Definition #{describe}>"
      end

      # Human-readable name of the declared response body type (also used by
      # the Executor when building violation messages).
      def response_type_name
        case @response_type
        when :json then 'JSON'
        when String then 'String'
        else @response_type.name || 'anonymous class'
        end
      end

      private

      def validate_verb!
        unless VALID_VERBS.include?(@verb)
          raise InvalidDefinition,
                "unsupported HTTP verb #{verb.to_s.inspect} for :#{@name} " \
                "(supported: #{VALID_VERBS.join(', ')})"
        end
      end

      def valid_status?(status)
        status.is_a?(Integer) ||
          (status.is_a?(Range) && status.min.is_a?(Integer) && status.max.is_a?(Integer))
      end

      def normalize_response_type(type)
        return RESPONSE_TYPES[type] if type.is_a?(Symbol) && RESPONSE_TYPES.key?(type)

        return type if type.is_a?(Class)

        raise InvalidDefinition,
              "unsupported response type #{type.inspect} for :#{@name} " \
              '(expected a Class or :array/:hash/:string/:json)'
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
