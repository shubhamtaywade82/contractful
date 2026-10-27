# frozen_string_literal: true

module Contractful
  # The ParamsArray class is used to represent an ordered list of [key, value]
  # pairs. Use this when you need to include a key multiple times or want
  # explicit control over parameter ordering.
  #
  # Most of the request payload & parameter functions normally accept a Hash of
  # keys => values, which does not allow for duplicated keys.
  #
  # @see Contractful::Utils.encode_query_string
  # @see Contractful::Utils.flatten_params
  #
  class ParamsArray
    include Enumerable

    # @param array [Array<Array>] An array of parameter key,value pairs. These
    #   pairs may be 2 element arrays [key, value] or single element hashes
    #   {key => value}. They may also be single element arrays to represent a
    #   key with no value.
    #
    # @example
    #   >> ParamsArray.new([[:foo, 123], [:foo, 456], [:bar, 789]])
    #   This will be encoded as "foo=123&foo=456&bar=789"
    #
    # @example
    #   >> ParamsArray.new({foo: 123, bar: 456})
    #   This is valid, but there's no reason not to just use the Hash directly
    #   instead of a ParamsArray.
    #
    #
    def initialize(array)
      @array = process_input(array)
    end

    def each(...)
      @array.each(...)
    end

    def empty?
      @array.empty?
    end

    private

    def process_input(array)
      array.map { |v| process_pair(v) }
    end

    # A pair may be:
    # - A single element hash, e.g. {foo: 'bar'}
    # - A two element array, e.g. ['foo', 'bar']
    # - A one element array, e.g. ['foo']
    #
    # The recursive `pair.to_a` branch previously could infinite-loop on
    # an object whose `to_a` returns itself (or another non-Hash/Array),
    # and crashed on `nil.to_a` (which returns []) because the recursive
    # call would then raise IndexError on `pair.fetch(0)`. Reject those
    # inputs up front with a clear error message.
    def process_pair(pair)
      case pair
      when Hash
        raise ArgumentError.new("Bad # of fields for pair: #{pair.inspect}") if pair.length != 1

        pair.to_a.fetch(0)
      when Array
        raise ArgumentError.new("Bad # of fields for pair: #{pair.inspect}") if pair.length > 2

        [pair.fetch(0), pair[1]]
      else
        # recurse, converting any non-array to an array — but only if
        # to_a actually returns an Array (to_a on a custom Object can
        # legitimately return something else, e.g. an Enumerator).
        coerced = pair.to_a
        unless coerced.is_a?(Array)
          raise ArgumentError,
                'ParamsArray pair must be a Hash, Array, or respond to ' \
                "to_a with an Array, got #{pair.class}: #{pair.inspect}"
        end

        process_pair(coerced)
      end
    end
  end
end
