# frozen_string_literal: true

# This spec mirrors lib/contractful/contract/postman_import.rb. RSpec/SpecFilePathFormat
# expects a contractful/ path prefix that this repository's spec layout does not use;
# the existing mirror specs are grandfathered in .rubocop_todo.yml, and this new one
# opts out here, with this explanation, rather than growing that baseline.
# rubocop:disable RSpec/SpecFilePathFormat

require_relative '../../spec_helper'
require 'contractful/contract/postman_import'
require 'tmpdir'

RSpec.describe Contractful::Contract::PostmanImport do
  subject(:mod) { described_class }

  let(:import_error) { Contractful::Contract::OpenAPIImport::Error }

  let(:collection) do
    {
      'info' => { 'name' => 'Acme Orders',
                  'schema' => 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json' },
      'variable' => [{ 'key' => 'baseUrl', 'value' => 'https://api.acme.test/v1' }],
      'auth' => { 'type' => 'bearer', 'bearer' => [{ 'key' => 'token', 'value' => '{{token}}' }] },
      'item' => [
        { 'name' => 'Orders', 'item' => [
          { 'name' => 'Get order', 'request' => {
            'method' => 'GET',
            'url' => { 'raw' => '{{baseUrl}}/orders/:id?expand=items', 'host' => ['{{baseUrl}}'],
                       'path' => ['orders', ':id'], 'query' => [{ 'key' => 'expand', 'value' => 'items' }] }
          } },
          { 'name' => 'Create order', 'request' => {
            'method' => 'POST', 'url' => '{{baseUrl}}/orders',
            'header' => [{ 'key' => 'Content-Type', 'value' => 'application/json' },
                         { 'key' => 'X-Client', 'value' => 'web' }],
            'body' => { 'mode' => 'raw', 'raw' => '{"sku": "A1", "qty": 2}',
                        'options' => { 'raw' => { 'language' => 'json' } } }
          } }
        ] }
      ]
    }
  end

  let(:apikey_auth) do
    { 'type' => 'apikey',
      'apikey' => [{ 'key' => 'key', 'value' => 'X-Key' }, { 'key' => 'in', 'value' => 'query' }] }
  end

  # A collection holding the given request objects, one top-level item each.
  def collection_with(*requests)
    items = requests.each_with_index.map { |request, i| { 'name' => "Request #{i}", 'request' => request } }
    collection.merge('item' => items)
  end

  def import_request(request, variables: {})
    mod.import(collection_with(request), variables: variables)
  end

  describe 'operations' do
    it 'flattens folders into named operations on the origin of the variables', :aggregate_failures do
      import = mod.import(collection)

      expect(import.definitions.keys).to eq %i[get_order create_order]
      expect(import.base_url).to eq 'https://api.acme.test'
    end

    it 'keeps the path template and maps placeholders, query keys and static headers to params', :aggregate_failures do
      definitions = mod.import(collection).definitions

      expect(definitions[:get_order].path_template).to eq '/v1/orders/:id'
      expect(definitions[:get_order].params.keys).to eq %i[id expand]
      expect(definitions[:get_order].params[:id]).to be_required
      expect(definitions[:create_order].params[:x_client].default_value).to eq 'web'
    end

    it 'declares JSON example body fields and turns strict params off for that operation', :aggregate_failures do
      create = mod.import(collection).definitions[:create_order]

      expect(create.params.keys).to include(:sku, :qty)
      expect(create.strict).to be false
    end

    it 'does not declare Content-Type, which the body decides' do
      expect(mod.import(collection).definitions[:create_order].params.keys).not_to include(:content_type)
    end
  end

  describe 'auth and notes' do
    it 'turns the collection bearer auth into a hint read from the environment' do
      expect(mod.import(collection).auth_hints.join).to include("auth bearer: -> { ENV['ACME_ORDERS_TOKEN'] }")
    end

    it 'says that example values are untyped and that example body fields are inferred' do
      expect(mod.import(collection).notes.join).to match(/example values, not schemas.*example bodies/m)
    end

    it 'does not map an Authorization header and says so' do
      request = { 'method' => 'GET', 'url' => 'https://api.acme.test/v1/me',
                  'header' => [{ 'key' => 'Authorization', 'value' => 'Bearer abc' }] }

      expect(import_request(request).notes.join).to include('Authorization is not mapped')
    end
  end

  describe 'variables' do
    it 'skips a request whose origin cannot be resolved, and says which variable is missing', :aggregate_failures do
      import = mod.import(collection.merge('variable' => []))

      expect(import.definitions).to be_empty
      expect(import.notes.join).to include('unresolved variable {{baseUrl}}')
    end

    it 'resolves variables the caller supplies when the collection does not define them' do
      import = mod.import(collection.merge('variable' => []), variables: { 'baseUrl' => 'https://api.acme.test/v1' })

      expect(import.definitions.keys).to eq %i[get_order create_order]
    end
  end

  describe 'bodies' do
    let(:urlencoded_request) do
      { 'method' => 'POST', 'url' => 'https://api.acme.test/v1/token',
        'body' => { 'mode' => 'urlencoded',
                    'urlencoded' => [{ 'key' => 'grant_type' }, { 'key' => 'scope', 'disabled' => true }] } }
    end

    it 'maps urlencoded bodies to form params', :aggregate_failures do
      definition = import_request(urlencoded_request).definitions.fetch(:request_0)

      expect(definition.payload_style).to eq :form
      expect(definition.params.keys).to eq [:grant_type]
    end

    it 'maps a GraphQL body to a required query and a variables hash', :aggregate_failures do
      request = { 'method' => 'POST', 'url' => 'https://api.acme.test/v1/graphql',
                  'body' => { 'mode' => 'graphql', 'graphql' => { 'query' => '{ me { id } }' } } }
      definition = import_request(request).definitions.fetch(:request_0)

      expect(definition.params[:query]).to be_required
      expect(definition.params[:variables].type).to eq Hash
    end

    it 'skips a multipart body with file fields and says so' do
      request = { 'method' => 'POST', 'url' => 'https://api.acme.test/v1/upload',
                  'body' => { 'mode' => 'formdata', 'formdata' => [{ 'key' => 'avatar', 'type' => 'file' }] } }

      expect(import_request(request).notes.join).to include('multipart body with file fields is not representable')
    end
  end

  describe 'requests it cannot represent' do
    it 'skips requests that call another origin' do
      other = { 'method' => 'GET', 'url' => 'https://other.test/v1/status' }
      import = mod.import(collection_with({ 'method' => 'GET', 'url' => 'https://api.acme.test/v1/ping' }, other))

      expect(import.definitions.keys).to eq [:request_0]
    end

    it 'skips unsupported methods and reports them' do
      expect(import_request({ 'method' => 'COPY', 'url' => 'https://api.acme.test/v1/x' }).notes.join)
        .to include('COPY is not a supported method')
    end

    it 'reports query keys that are not identifiers' do
      request = { 'method' => 'GET',
                  'url' => { 'raw' => 'https://api.acme.test/v1/items',
                             'query' => [{ 'key' => 'page[size]', 'value' => '10' }] } }

      expect(import_request(request).notes.join).to include('query parameter "page[size]" is not a valid identifier')
    end
  end

  describe 'input and edge cases' do
    it 'loads a collection from a JSON file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'acme.json')
        File.write(path, JSON.generate(collection))

        expect(mod.import(path).definitions.keys).to eq %i[get_order create_order]
      end
    end

    it 'reports a missing file and text that is not a collection', :aggregate_failures do
      expect { mod.import('/nonexistent/acme.json') }.to raise_error(import_error, /no such file/)
      expect { mod.import('{"info": {}}') }.to raise_error(import_error, /expected an "item" array/)
    end

    it 'reports malformed JSON' do
      expect { mod.import('{not json') }.to raise_error(import_error, /invalid JSON for a Postman collection/)
    end

    it 'turns basic and apikey auth into environment-backed hints', :aggregate_failures do
      basic = mod.import(collection.merge('auth' => { 'type' => 'basic' })).auth_hints.join
      apikey = mod.import(collection.merge('auth' => apikey_auth)).auth_hints.join

      expect(basic).to include("auth basic: -> { [ENV['ACME_ORDERS_USER'], ENV['ACME_ORDERS_PASSWORD']] }")
      expect(apikey).to include("name: \"X-Key\", value: -> { ENV['ACME_ORDERS_API_KEY'] }, in: :query")
    end

    it 'names a request without a usable name from its method and path' do
      item = { 'name' => '', 'request' => { 'method' => 'GET', 'url' => 'https://api.acme.test/v1/ping' } }

      expect(mod.import(collection.merge('item' => [item])).definitions.keys).to eq [:get_v1_ping]
    end

    it 'skips a request whose path has an unresolved variable and names it' do
      expect(import_request({ 'method' => 'GET', 'url' => 'https://api.acme.test/v1/orders/{{id}}' }).notes.join)
        .to include('unresolved variable {{id}}')
    end

    it 'reports a raw body that is not a JSON object' do
      request = { 'method' => 'POST', 'url' => 'https://api.acme.test/v1/notes',
                  'body' => { 'mode' => 'raw', 'raw' => 'plain text' } }

      expect(import_request(request).notes.join).to include('raw body is not a JSON object')
    end

    it 'reports a header whose value has control characters' do
      request = { 'method' => 'GET', 'url' => 'https://api.acme.test/v1/ping',
                  'header' => [{ 'key' => 'X-Bad', 'value' => "a\r\nb" }] }

      expect(import_request(request).notes.join)
        .to include('has control characters in its value')
    end

    it 'reports a body mode it cannot represent' do
      request = { 'method' => 'POST', 'url' => 'https://api.acme.test/v1/blob', 'body' => { 'mode' => 'file' } }

      expect(import_request(request).notes.join).to include('body mode "file" is not representable')
    end
  end

  describe 'generated clients' do
    let(:client) do
      generated = Module.new
      generated.module_eval(mod.to_ruby(collection, class_name: 'AcmeOrdersClient'))
      generated.const_get(:AcmeOrdersClient).new
    end

    it 'call the mapped path and query' do
      stub = stub_request(:get, 'https://api.acme.test/v1/orders/5?expand=items')

      client.get_order(id: 5, expand: 'items')
      expect(stub).to have_been_made
    end

    it 'send the mapped body, and allow fields the example omitted since strict params are off' do
      stub = stub_request(:post, 'https://api.acme.test/v1/orders')
             .with(headers: { 'X-Client' => 'web' }, body: hash_including('sku' => 'A1', 'qty' => 2, 'note' => 'gift'))

      client.create_order(sku: 'A1', qty: 2, note: 'gift')
      expect(stub).to have_been_made
    end
  end
end

# rubocop:enable RSpec/SpecFilePathFormat
