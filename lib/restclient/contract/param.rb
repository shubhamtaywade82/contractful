# frozen_string_literal: true

module RestClient
  module Contract
    # A single typed parameter declared inside a contract definition.
    #
    # Params carry the contract-first metadata: expected type, whether the
    # value is required, a default value and an allowed set/range of values.
    # When a contract is executed, every provided value flows through
    # {Param#process!}, which coerces and validates it or raises
    # {InvalidParam} with a precise message.
    #
    # Supported types:
    #
    #   * +String+ (+:string+)   — accepts String and Symbol
    #   * +Integer+ (+:integer+) — accepts Integer, integral Float, numeric String
    #   * +Float+ (+:float+)     — accepts Integer, Float, numeric String
    #   * +:boolean+             — accepts true/false, "true"/"false" spellings, 1/0
    #   * +Array+ (+:array+)     — accepts Array; other values are wrapped
    #   * +Hash+ (+:hash+)       — accepts Hash only
    #   * any +Class+            — +is_a?+ check first, then +Class#restclient_coerce+,
    #                              then a Kernel cast attempt (e.g. +Float+)
    #   * any +Proc+             — custom coercion; its return value is used
    #
    # With <tt>coerce: false</tt> the value must already match the declared
    # type exactly (no conversion is attempted).
    class Param
      # Types that may be referenced with a symbol instead of a class.
      SYMBOL_TYPES = {
        string: String,
        integer: Integer,
        float: Float,
        boolean: :boolean,
        array: Array,
        hash: Hash,
      }.freeze

      BOOLEAN_TRUTHY = %w[true 1 on yes].freeze
      BOOLEAN_FALSY = %w[false 0 off no].freeze

      attr_reader :name, :type, :inclusion, :description

      def initialize(name, type = nil, required: false, default: NO_DEFAULT,
                     inclusion: nil, coerce: true, description: nil)
        @name = name.to_sym
        @type = normalize_type(type)
        @required = required ? true : false
        @default = default
        @inclusion = inclusion
        @coerce = coerce ? true : false
        @description = description
        validate_definition!
      end

      def required?
        @required
      end

      def coerce?
        @coerce
      end

      def has_default?
        !@default.equal?(NO_DEFAULT)
      end

      # The declared default value. Procs are called so defaults can be
      # computed lazily (for example <tt>default: -> { Time.now.to_i }</tt>).
      def default_value
        @default.is_a?(Proc) ? @default.call : @default
      end

      # Coerce and validate a value, returning the coerced result.
      #
      # @raise [InvalidParam] when the value cannot be accepted
      def process!(value)
        coerced = @coerce ? coerce_value(value) : strict_check(value)
        validate_inclusion!(coerced)
        coerced
      rescue InvalidParam => e
        raise InvalidParam, "param :#{@name}: #{e.message}"
      end

      # Human-readable summary used in error messages and introspection.
      def to_s
        parts = [type_name]
        parts << 'required' if @required
        parts << "default=#{@default.inspect}" if has_default? && !@default.is_a?(Proc)
        parts << "in #{inclusion.inspect}" if @inclusion
        parts.join(', ')
      end

      private

      def normalize_type(type)
        return nil if type.nil?

        if type.is_a?(Symbol)
          unless SYMBOL_TYPES.key?(type)
            raise InvalidDefinition,
                  "unsupported param type #{type.inspect} for :#{@name} " \
                  "(supported symbols: #{SYMBOL_TYPES.keys.join(', ')})"
          end
          return SYMBOL_TYPES[type]
        end

        if type.equal?(TrueClass) || type.equal?(FalseClass)
          return :boolean
        end

        unless type.is_a?(Class) || type.is_a?(Proc)
          raise InvalidDefinition,
                "unsupported param type #{type.inspect} for :#{@name} " \
                '(expected a Class, Proc or supported symbol)'
        end

        type
      end

      def validate_definition!
        if @inclusion && !@inclusion.respond_to?(:include?)
          raise InvalidDefinition,
                "param :#{@name}: inclusion must respond to #include? " \
                "(got #{@inclusion.inspect})"
        end
      end

      def type_name
        case @type
        when nil then 'untyped'
        when :boolean then 'boolean'
        when Proc then 'custom coercion'
        when Class then @type.name || 'anonymous class'
        else @type.to_s
        end
      end

      def describe_value(value)
        return 'nil' if value.nil?

        inspected = value.inspect
        inspected = inspected[0, 57] + '...' if inspected.length > 60
        "#{value.class} (#{inspected})"
      end

      def validate_inclusion!(value)
        return unless @inclusion

        unless @inclusion.include?(value)
          raise InvalidParam,
                "value #{value.inspect} is not in #{@inclusion.inspect}"
        end
      end

      # Coercion path: convert the value into the declared type where the
      # conversion is unambiguous, otherwise reject it. Contract-first means
      # we never silently mangle data: "abc" is not an Integer, and we say so.
      #
      # NOTE: comparisons use #equal? (identity) rather than case/===, because
      # the type IS a class — `case @type when String` would match with
      # String#=== semantics, which is not what we want here.
      def coerce_value(value)
        if @type.nil?
          value
        elsif @type.equal?(:boolean)
          coerce_boolean(value)
        elsif @type.equal?(String)
          coerce_string(value)
        elsif @type.equal?(Integer)
          coerce_integer(value)
        elsif @type.equal?(Float)
          coerce_float(value)
        elsif @type.equal?(Array)
          value.is_a?(Array) ? value : [value]
        elsif @type.equal?(Hash)
          unless value.is_a?(Hash)
            raise InvalidParam, "expected Hash, got #{describe_value(value)}"
          end
          value
        elsif @type.is_a?(Proc)
          coerce_custom(value)
        elsif @type.is_a?(Class)
          coerce_class(value)
        else
          raise InvalidParam, "unsupported type #{type_name}"
        end
      end

      def coerce_string(value)
        case value
        when String then value
        when Symbol then value.to_s
        else raise InvalidParam, "expected String, got #{describe_value(value)}"
        end
      end

      def coerce_integer(value)
        case value
        when Integer then value
        when Float
          if value == value.to_i
            value.to_i
          else
            raise InvalidParam, "expected Integer, got #{describe_value(value)}"
          end
        when String
          if /\A[+-]?\d+\z/.match?(value)
            Integer(value)
          else
            raise InvalidParam, "expected Integer, got #{describe_value(value)}"
          end
        else
          raise InvalidParam, "expected Integer, got #{describe_value(value)}"
        end
      end

      def coerce_float(value)
        case value
        when Integer, Float then Float(value)
        when String
          begin
            Float(value)
          rescue ArgumentError
            raise InvalidParam, "expected Float, got #{describe_value(value)}"
          end
        else
          raise InvalidParam, "expected Float, got #{describe_value(value)}"
        end
      end

      def coerce_boolean(value)
        return value if value.equal?(true) || value.equal?(false)

        if value.is_a?(String)
          downcased = value.downcase
          return true if BOOLEAN_TRUTHY.include?(downcased)
          return false if BOOLEAN_FALSY.include?(downcased)
        elsif value.is_a?(Integer) && (value == 1 || value == 0)
          return value == 1
        end

        raise InvalidParam, "expected boolean, got #{describe_value(value)}"
      end

      def coerce_custom(value)
        begin
          return @type.call(value)
        rescue InvalidParam
          raise
        rescue StandardError => e
          raise InvalidParam, "custom coercion failed: #{e.class}: #{e.message}"
        end
      end

      def coerce_class(value)
        return value if value.is_a?(@type)

        if @type.respond_to?(:restclient_coerce)
          begin
            return @type.restclient_coerce(value)
          rescue InvalidParam
            raise
          rescue StandardError => e
            raise InvalidParam, "custom coercion failed: #{e.class}: #{e.message}"
          end
        end

        begin
          cast = send(@type.name.to_sym, value) # Kernel cast, e.g. Float("1.5")
          return cast if cast.is_a?(@type)
        rescue StandardError
          nil
        end

        raise InvalidParam, "expected #{type_name}, got #{describe_value(value)}"
      end

      # Strict path (coerce: false): the value must already match exactly.
      def strict_check(value)
        if @type.nil?
          value
        elsif @type.equal?(:boolean)
          if value.equal?(true) || value.equal?(false)
            value
          else
            raise InvalidParam, "expected boolean, got #{describe_value(value)}"
          end
        elsif @type.is_a?(Proc)
          coerce_custom(value)
        elsif @type.is_a?(Class)
          if value.is_a?(@type)
            value
          else
            raise InvalidParam, "expected #{type_name}, got #{describe_value(value)}"
          end
        else
          raise InvalidParam, "unsupported strict type #{type_name}"
        end
      end
    end
  end
end
