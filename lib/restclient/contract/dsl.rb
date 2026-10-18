# frozen_string_literal: true

module RestClient
  module Contract
    # Metaprogramming machinery injected into classes that include
    # {RestClient::Contract}.
    #
    # {ClassMethods} provides the declaration macros (+base+, +contract+, ...)
    # and generates one real instance method per contract via +define_method+
    # (plus a <tt>#{name}_url</tt> path builder). {InstanceMethods} provides
    # the small runtime surface the {Executor} needs.
    module ClassMethods
      # Configure the base URL all contract paths are resolved against.
      # Trailing slashes are stripped.
      def base(url)
        unless url.is_a?(String) && url.match?(%r{\Ahttps?://}i)
          raise InvalidDefinition,
                "base must be an absolute http(s) URL, got #{url.inspect}"
        end
        __own_contract_config.base_url = url.sub(%r{/+\z}, '')
      end

      # Declare default headers merged into every request. Called with no
      # arguments it returns the headers accumulated down the ancestor chain.
      def default_headers(headers = nil)
        if headers.nil?
          merged = {}
          __contract_config_chain.reverse_each do |config|
            merged.update(config.default_headers) if config.default_headers
          end
          merged
        else
          __own_contract_config.default_headers = headers
        end
      end

      # Toggle strict param checking (default: strict). In strict mode,
      # providing params the contract does not declare raises {UnknownParam}.
      def strict_params(flag = true)
        __own_contract_config.strict_params = flag
      end

      # Default payload style for non-query params: +:json+ or +:form+.
      # Per-contract `payload_style` inside the block wins over this.
      def payload_style(style)
        __own_contract_config.payload_style = style
      end

      # Declare a contract. The request line is <tt>'VERB /path'</tt>; the
      # optional block is instance_eval'd against the new {Definition}.
      #
      # @return [Definition] the registered definition
      def contract(name, request_line, description: nil, &block)
        name = name.to_sym
        validate_contract_name!(name)

        verb, path = parse_request_line(request_line)
        definition = Definition.new(name, verb, path, description: description, &block)

        __own_contract_config.contracts[name] = definition
        __define_contract_methods(definition)
        definition
      end

      # --- machinery (used by Executor / introspection) -----------------------

      # The config object owned by *this* class (created on demand).
      def __own_contract_config
        @__contract_config ||= Config.new
      end

      # Config objects along the ancestor chain, self first.
      def __contract_config_chain
        chain = []
        klass = self
        while klass.is_a?(Class)
          if klass.instance_variable_defined?(:@__contract_config)
            chain << klass.instance_variable_get(:@__contract_config)
          end
          klass = klass.superclass
        end
        chain
      end

      # Nearest non-nil scalar setting down the chain (base_url,
      # strict_params, payload_style).
      def __merged_scalar(setting)
        __contract_config_chain.each do |config|
          value = config.public_send(setting)
          return value unless value.nil?
        end
        nil
      end

      # Callbacks of one kind, accumulated root-first.
      def __merged_callbacks(kind)
        __contract_config_chain.reverse_each.flat_map { |c| c.callbacks[kind] }
      end

      private

      def parse_request_line(line)
        match = line.to_s.match(
          /\A\s*(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS)\s+(\/\S*)\s*\z/i
        )
        unless match
          raise InvalidDefinition,
                "invalid request line #{line.inspect} — expected " \
                "'VERB /path', e.g. 'GET /users' or 'POST /repos/:owner/:repo/issues'"
        end
        [match[1].downcase.to_sym, match[2]]
      end

      def validate_contract_name!(name)
        unless name.to_s.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*[?!]?\z/)
          raise InvalidDefinition,
                "contract name #{name.inspect} is not a valid method name"
        end
        if RESERVED_NAMES.include?(name)
          raise InvalidDefinition,
                "contract name #{name.inspect} is reserved and cannot be used"
        end
      end

      # Generate the client methods for a contract:
      #
      #   name        -> execute the contract
      #   name_url    -> expand path params and return the full URL
      def __define_contract_methods(definition)
        name = definition.name

        define_method(name) do |**params|
          Contract::Executor.call(self, definition, params)
        end

        define_method(:"#{name}_url") do |**params|
          Contract::Executor.build_url(self, definition, params)
        end
      end
    end

    module InstanceMethods
      # Client-level overrides. They take precedence over the class-level
      # configuration; if the class defines its own #initialize it wins (call
      # <tt>super(base:, headers:)</tt> to keep both).
      def initialize(base: nil, headers: nil)
        @__base_override = base
        @__header_overrides = headers || {}
      end

      # Base URL for this instance (constructor override > class config).
      def __contract_base
        @__base_override || self.class.__merged_scalar(:base_url) ||
          raise(MissingBaseUrl,
                'no base URL configured — use `base "https://api.example.com"` ' \
                'or pass base: to the constructor')
      end

      # Merge class default headers (root-first), instance header overrides
      # and per-call _headers into one effective Hash.
      def __contract_effective_headers(call_headers)
        merged = self.class.default_headers
        merged.update(@__header_overrides)
        merged.update(call_headers) if call_headers
        merged
      end

      # Run the accumulated before_request callbacks with the mutable
      # execution context (root-most callbacks first).
      def __run_before_callbacks(ctx)
        self.class.__merged_callbacks(:before_request).each { |cb| cb.call(ctx) }
      end

      # Run the accumulated after_response callbacks with the response.
      def __run_after_callbacks(response)
        self.class.__merged_callbacks(:after_response).each { |cb| cb.call(response) }
      end
    end

    RESERVED_NAMES = %i[
      initialize inspect to_s class object_id method_missing respond_to_missing?
      == equal? hash freeze frozen? dup clone send public_send
    ].freeze

    class << self
      # Called when the DSL module is included in a client class: extend the
      # class with the declaration macros and include the runtime methods.
      def included(base)
        base.extend(ClassMethods)
        base.include(InstanceMethods)
      end
    end
  end
end
