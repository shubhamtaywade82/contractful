# frozen_string_literal: true

require 'json'
require_relative 'openapi_import'
require_relative 'postman_import/scope'
require_relative 'postman_import/url'
require_relative 'postman_import/body'
require_relative 'postman_import/auth'
require_relative 'postman_import/operation'

module Contractful
  module Contract
    # Imports a Postman Collection (a v2.0 or v2.1 JSON export) as contract
    # declarations, the way {OpenAPIImport} imports OpenAPI documents. It is
    # opt-in and development-time:
    #
    #   require 'contractful/contract/postman_import'
    #
    # A collection carries example values rather than schemas, so its params are
    # untyped and none is required, except a GraphQL query. Everything that is not
    # mapped is reported on {Import#notes}.
    module PostmanImport
      FORMAT = 'Postman Collection v2.1'
      IDENTIFIER = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

      # The import result, shared with {OpenAPIImport}.
      Import = OpenAPIImport::Import

      module_function

      # @param source a collection Hash, a path, or JSON text
      # @param variables [Hash] values for {{variables}} the collection does not
      #   define, such as an environment's baseUrl; they override the collection's
      # @param only [Array<Symbol>] keep only these operation names
      # @param except [Array<Symbol>] drop these operation names
      # @return [OpenAPIImport::Import]
      def import(source, variables: {}, only: nil, except: nil)
        collection = load(source)
        scope = Scope.new(collection_variables(collection).merge(string_hash(variables)))
        results = requests(collection['item']).filter_map { |item| Operation.build(item, scope) }
        base = base_origin(results, scope)
        definitions = definitions_for(results, base, only, except)
        summarize(scope, definitions)
        assemble(collection, results, base, definitions, scope)
      end

      def assemble(collection, results, base, definitions, scope)
        Import.new(document: document(collection), base_url: base, auth_hints: auth_hints(collection, results),
                   definitions: definitions, notes: scope.notes)
      end

      def definitions(source, variables: {}, only: nil, except: nil)
        import(source, variables: variables, only: only, except: except).definitions
      end

      def to_ruby(source, class_name: 'GeneratedClient', variables: {}, only: nil, except: nil)
        import(source, variables: variables, only: only, except: except).to_ruby(class_name: class_name)
      end

      def load(source)
        collection = source.is_a?(Hash) ? source : parse(source)
        unless collection.is_a?(Hash) && collection['item'].is_a?(Array)
          raise OpenAPIImport::Error, 'not a Postman collection: expected an "item" array'
        end

        collection
      end

      def parse(source)
        JSON.parse(text_of(source))
      rescue JSON::ParserError => e
        raise OpenAPIImport::Error, "invalid JSON for a Postman collection: #{e.message}"
      end

      def text_of(source)
        return source if source.is_a?(String) && source.lstrip.start_with?('{', '[')
        raise OpenAPIImport::Error, "no such file: #{source}" unless File.file?(source.to_s)

        File.read(source.to_s)
      end

      # Request items in document order, with folders flattened away.
      def requests(items)
        list(items).flat_map do |item|
          next [] unless item.is_a?(Hash)
          next [item] if item['request'].is_a?(Hash)

          requests(item['item'])
        end
      end

      # The origin most requests call. Requests on another origin cannot share
      # one client's base URL, so they are skipped and noted.
      def base_origin(results, scope)
        base = results.map(&:origin).tally.max_by(&:last)&.first
        results.each do |result|
          next if result.origin == base

          scope.note("#{result.definition.name}: calls #{result.origin}, not #{base} — one client has " \
                     'one base URL, so it is skipped')
        end
        base
      end

      def definitions_for(results, base, only, except)
        results.each_with_object({}) do |result, out|
          name = result.definition.name
          out[name] = result.definition if result.origin == base && !OpenAPIImport.skip_name?(name, only, except)
        end
      end

      def summarize(scope, definitions)
        return if definitions.empty?

        scope.note('a Postman collection carries example values, not schemas: params are untyped and ' \
                   'none is required, except a GraphQL query')
        return unless scope.inferred_body?

        scope.note('body fields come from example bodies: their types are unknown, and strict_params is ' \
                   'off on those operations, because an example may omit fields')
      end

      def document(collection)
        { 'info' => { 'title' => info_name(collection) }, 'x-contractful-source' => FORMAT }
      end

      def auth_hints(collection, results)
        prefix = env_prefix(collection)
        auths = ([collection['auth']] + results.map(&:auth)).compact.uniq
        auths.flat_map { |auth| Auth.hints(auth, prefix) }.uniq
      end

      def info_name(collection)
        info = collection['info']
        info.is_a?(Hash) ? info['name'].to_s : ''
      end

      def env_prefix(collection)
        name = info_name(collection).upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        name.empty? ? 'POSTMAN' : name
      end

      def collection_variables(collection)
        list(collection['variable']).each_with_object({}) do |entry, out|
          out[entry['key'].to_s] = entry['value'].to_s if entry.is_a?(Hash) && entry['key']
        end
      end

      def string_hash(hash)
        hash.to_h { |key, value| [key.to_s, value.to_s] }
      end

      # The items of an array field, or none when the field is missing or malformed.
      def list(value)
        value.is_a?(Array) ? value : []
      end

      # The entries of a key/value list that are not disabled.
      def enabled(entries)
        list(entries).select { |entry| entry.is_a?(Hash) && !entry['disabled'] }
      end
    end
  end
end
