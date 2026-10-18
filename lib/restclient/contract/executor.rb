# frozen_string_literal: true

require 'json'

module RestClient
  module Contract
    # Turns a {Definition} plus user-supplied params into a real HTTP request,
    # executes it through the normal rest-client machinery and returns the
    # {RestClient::Response}.
    #
    # The pipeline is:
    #
    #   1. symbolize keys, split per-call meta options (+_headers+, ...)
    #   2. validate & coerce params against the contract
    #   3. expand the path template, route remaining params to query/payload
    #   4. run before_request callbacks with a mutable context
    #   5. execute via RestClient::Request
    #   6. run after_response callbacks
    module Executor
      # Per-call meta options (underscore prefix keeps them out of the
      # contract's param namespace).
      META_OPTIONS = %i[
        _headers _timeout _open_timeout _read_timeout _write_timeout
        _persistent _max_retries _retry_interval
      ].freeze

      META_MAP = {
        _timeout: :timeout,
        _open_timeout: :open_timeout,
        _read_timeout: :read_timeout,
        _write_timeout: :write_timeout,
        _persistent: :persistent,
        _max_retries: :max_retries,
        _retry_interval: :retry_interval,
      }.freeze

      # Verbs whose params are sent as a query string by default.
      QUERY_VERBS = %i[get head delete options].freeze

      module_function

      # Execute a contract.
      #
      # @param instance a client instance (includes RestClient::Contract)
      # @param definition [Definition]
      # @param params [Hash] user-supplied params (String or Symbol keys)
      # @return [RestClient::Response]
      def call(instance, definition, params)
        params = symbolize_keys(params)
        meta, params = split_meta(params)
        coerced = validate_params(instance, definition, params)
        path, remaining = definition.expand_path(coerced)
        url = build_full_url(instance.__contract_base, path)

        verb = definition.verb
        headers = instance.__contract_effective_headers(meta[:_headers])
        payload, query, headers =
          build_body_and_query(instance, definition, verb, remaining, headers)

        ctx = {
          definition: definition,
          method: verb,
          url: url,
          headers: headers,
          payload: payload,
          query: query,
        }

        instance.__run_before_callbacks(ctx)

        request_args = {
          method: ctx[:method],
          url: ctx[:url],
          headers: ctx[:headers],
          payload: ctx[:payload],
        }
        if ctx[:query] && !ctx[:query].empty?
          request_args[:headers] = request_args[:headers].merge(params: ctx[:query])
        end
        merge_meta_options!(request_args, meta)

        response = RestClient::Request.execute(request_args)
        instance.__run_after_callbacks(response)
        response
      end

      # Build the full URL for a contract (used by the generated
      # <tt>#{name}_url</tt> methods). Only path params are required; other
      # declared params are accepted but not appended.
      def build_url(instance, definition, params)
        params = symbolize_keys(params || {})
        coerced = {}
        definition.path_param_names.each do |key|
          param = definition.params[key]
          value = params.key?(key) && !params[key].nil? ? params[key] : nil
          if value.nil? && param&.has_default?
            value = param.default_value
          end
          if value.nil?
            raise MissingParam,
                  "path param :#{key} is required by " \
                  "#{definition.path_template.inspect} but was not provided"
          end
          coerced[key] = param ? param.process!(value) : value
        end
        path, = definition.expand_path(coerced)
        build_full_url(instance.__contract_base, path)
      end

      # --- internals ---------------------------------------------------------

      def symbolize_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end

      def split_meta(params)
        meta = {}
        regular = {}
        params.each do |key, value|
          if key.to_s.start_with?('_')
            unless META_OPTIONS.include?(key)
              raise UnknownParam,
                    "unknown meta option #{key.inspect} " \
                    "(supported: #{META_OPTIONS.map(&:inspect).join(', ')})"
            end
            if key == :_headers && !value.is_a?(Hash)
              raise ParamError, "_headers must be a Hash, got #{value.inspect}"
            end
            meta[key] = value
          else
            regular[key] = value
          end
        end
        [meta, regular]
      end

      def validate_params(instance, definition, params)
        coerced = {}
        definition.params.each do |name, param|
          value = params[name]
          if !value.nil?
            coerced[name] = param.process!(value)
          elsif param.has_default?
            coerced[name] = param.process!(param.default_value)
          elsif param.required?
            raise MissingParam,
                  "param :#{name} is required by #{definition.describe}"
          end
        end

        unknown = params.keys - definition.params.keys
        if unknown.any?
          if strict_params?(instance)
            raise UnknownParam,
                  "unknown param #{unknown.map { |k| ":#{k}" }.join(', ')} " \
                  "for #{definition.describe} " \
                  '(disable with strict_params false)'
          end
          unknown.each { |key| coerced[key] = params[key] }
        end
        coerced
      end

      def strict_params?(instance)
        value = instance.class.__merged_scalar(:strict_params)
        value.nil? ? true : value
      end

      def effective_payload_style(instance, definition, verb)
        definition.payload_style ||
          instance.class.__merged_scalar(:payload_style) ||
          (QUERY_VERBS.include?(verb) ? :query : :json)
      end

      def build_body_and_query(instance, definition, verb, remaining, headers)
        return [nil, nil, headers] if remaining.empty?

        style = effective_payload_style(instance, definition, verb)
        if QUERY_VERBS.include?(verb) || style == :query
          [nil, remaining, headers]
        elsif style == :form
          [remaining, nil, headers]
        else # :json
          unless headers.keys.any? { |k| k.to_s.casecmp('content-type').zero? }
            headers = headers.merge('Content-Type' => 'application/json')
          end
          [JSON.generate(remaining), nil, headers]
        end
      end

      def build_full_url(base, path)
        base = base.sub(%r{/+\z}, '')
        path = path.start_with?('/') ? path : "/#{path}"
        "#{base}#{path}"
      end

      def merge_meta_options!(request_args, meta)
        META_MAP.each do |meta_key, option_key|
          request_args[option_key] = meta[meta_key] if meta.key?(meta_key)
        end
      end
    end
  end
end
