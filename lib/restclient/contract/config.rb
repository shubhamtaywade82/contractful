# frozen_string_literal: true

module RestClient
  module Contract
    # Class-level configuration for contract-first clients.
    #
    # An instance lives on each class that includes {RestClient::Contract}
    # (as <tt>@__contract_config</tt>) and is read by walking the superclass
    # chain: scalar settings use nearest-definition-wins, while callbacks and
    # contracts accumulate down the chain (see {DSL::ClassMethods}).
    class Config
      # Contract name (Symbol) => Definition
      attr_reader :contracts

      # { before_request: [...], after_response: [...] }
      attr_reader :callbacks

      # Scalars are nil until explicitly set, so that "unset" can be
      # distinguished from every meaningful value (including false/{}).
      attr_reader :base_url, :default_headers, :strict_params, :payload_style, :auth

      def initialize
        @contracts = {}
        @callbacks = { before_request: [], after_response: [] }
        @base_url = nil
        @default_headers = nil
        @strict_params = nil
        @payload_style = nil
        @auth = nil
      end

      def base_url=(url)
        @base_url = url
      end

      def default_headers=(headers)
        unless headers.is_a?(Hash)
          raise InvalidDefinition,
                "default_headers must be a Hash, got #{headers.inspect}"
        end
        @default_headers = headers
      end

      def strict_params=(flag)
        @strict_params = flag ? true : false
      end

      def payload_style=(style)
        unless %i[json form query].include?(style.to_sym)
          raise InvalidDefinition,
                "invalid payload_style #{style.inspect} " \
                '(expected :json, :form or :query)'
        end
        @payload_style = style.to_sym
      end

      def auth=(value)
        unless value.nil? || value.is_a?(Auth) || value.equal?(false)
          raise InvalidDefinition,
                'auth must be a RestClient::Contract::Auth or false, ' \
                "got #{value.inspect}"
        end
        @auth = value
      end

      def add_callback(kind, block)
        unless @callbacks.key?(kind)
          raise InvalidDefinition, "unknown callback kind #{kind.inspect}"
        end
        unless block.is_a?(Proc)
          raise InvalidDefinition, "callback #{kind} requires a block"
        end
        @callbacks[kind] << block
      end
    end
  end
end
