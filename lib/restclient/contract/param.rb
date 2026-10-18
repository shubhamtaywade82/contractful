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
    #
    # Beyond type and inclusion, params can carry the closed-schema
    # constraints known from JSON Schema / OpenAPI (these are what make a
    # request schema "closed" — bad input is rejected before the network
    # call is ever attempted):
    #
    #   * +min:+ / +max:+      — inclusive numeric (or any Comparable) bounds,
    #                            the counterpart of JSON Schema's
    #                            +minimum+ / +maximum+
    #   * +length:+            — exact length (Integer) or a Range of valid
    #                            lengths for String/Array/Hash values
    #   * +pattern:+           — a Regexp the String value must match
    #
    # Constraints are enforced after coercion, so
    # <tt>param :quantity, Integer, min: 1</tt> rejects the string "0"
    # exactly like the integer 0.
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
      attr_reader :min, :max, :length, :pattern

      def initialize(name, type = nil, required: false, default: NO_DEFAULT,
                     inclusion: nil, coerce: true, description: nil,
                     min: nil, max: nil, length: nil, pattern: nil)
        @name = name.to_sym
        @type = normalize_type(type)
        @required = required ? true : false
        @default = default
        @inclusion = inclusion
        @coerce = coerce ? true : false
        @description = description
        @min = min
        @max = max
        @length = length
        @pattern = pattern
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
        validate_constraints!(coerced)
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
        parts << ">= #{@min.inspect}" if @min
        parts << "<= #{@max.inspect}" if @max
        parts << "length #{@length.inspect}" if @length
        parts << "matching #{@pattern.inspect}" if @pattern
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
        if @min && !@min.respond_to?(:<=)
          raise InvalidDefinition,
                "param :#{@name}: min must be comparable, got #{@min.inspect}"
        end
        if @max && !@max.respond_to?(:>=)
          raise InvalidDefinition,
                "param :#{@name}: max must be comparable, got #{@max.inspect}"
        end
        if @length && !valid_length_constraint?(@length)
          raise InvalidDefinition,
                "param :#{@name}: length must be an Integer or an Integer " \
                "Range, got #{@length.inspect}"
        end
        if @pattern && !@pattern.is_a?(Regexp)
          raise InvalidDefinition,
                "param :#{@name}: pattern must be a Regexp, got #{@pattern.inspect}"
        end
      end

      def valid_length_constraint?(constraint)
        constraint.is_a?(Integer) ||
          (constraint.is_a?(Range) && constraint.min.is_a?(Integer) &&
           constraint.max.is_a?(Integer))
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

      # Closed-schema constraints, enforced after coercion: the contract
      # rejects out-of-range, wrong-length and non-matching input before any
      # HTTP request is built.
      def validate_constraints!(value)
        validate_bounds!(value)
        validate_length!(value)
        validate_pattern!(value)
      end

      def validate_bounds!(value)
        if @min
          unless value.respond_to?(:<)
            raise InvalidParam,
                  "cannot enforce min #{@min.inspect} on #{value.class}"
          end
          begin
            below = value < @min
          rescue StandardError
            raise InvalidParam,
                  "cannot compare #{value.inspect} with min #{@min.inspect}"
          end
          if below
            raise InvalidParam,
                  "value #{value.inspect} is below minimum #{@min.inspect}"
          end
        end
        if @max
          unless value.respond_to?(:>)
            raise InvalidParam,
                  "cannot enforce max #{@max.inspect} on #{value.class}"
          end
          begin
            above = value > @max
          rescue StandardError
            raise InvalidParam,
                  "cannot compare #{value.inspect} with max #{@max.inspect}"
          end
          if above
            raise InvalidParam,
                  "value #{value.inspect} is above maximum #{@max.inspect}"
          end
        end
      end

      def validate_length!(value)
        return unless @length

        unless value.respond_to?(:length)
          raise InvalidParam,
                "cannot enforce length on #{value.class} " \
                "(does not respond to #length)"
        end
        actual = value.length
        ok = @length.is_a?(Integer) ? actual == @length : @length.cover?(actual)
        unless ok
          raise InvalidParam,
                "length #{actual} is outside #{@length.inspect}"
        end
      end

      def validate_pattern!(value)
        return unless @pattern

        unless value.is_a?(String)
          raise InvalidParam,
                "pattern requires a String, got #{describe_value(value)}"
        end
        unless @pattern.match?(value)
          raise InvalidParam,
                "value #{value.inspect} does not match #{@pattern.inspect}"
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
