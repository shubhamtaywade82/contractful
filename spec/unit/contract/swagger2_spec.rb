# frozen_string_literal: true

# This spec mirrors lib/contractful/contract/swagger2.rb. RSpec/SpecFilePathFormat
# expects a contractful/ path prefix that this repository's spec layout does not use;
# the existing mirror specs are grandfathered in .rubocop_todo.yml, and this new one
# opts out here, with this explanation, rather than growing that baseline.
# rubocop:disable RSpec/SpecFilePathFormat

require_relative '../../spec_helper'
require 'contractful/contract/swagger2'

RSpec.describe Contractful::Contract::Swagger2 do
  let(:document) do
    {
      'swagger' => '2.0',
      'info' => { 'title' => 'Legacy', 'version' => '1' },
      'host' => 'api.legacy.test',
      'basePath' => '/v2',
      'schemes' => %w[http https],
      'definitions' => { 'Pet' => { 'type' => 'object', 'required' => ['name'],
                                    'properties' => { 'name' => { 'type' => 'string' } } } },
      'paths' => {}
    }
  end
  let(:pet_ref) { { '$ref' => '#/definitions/Pet' } }

  # Converts the document with one POST /pets operation.
  def convert_operation(operation, extra = {})
    described_class.convert(document.merge(extra).merge('paths' => { '/pets' => { 'post' => operation } }))
  end

  def operation_at(converted, method = 'post')
    converted.dig('paths', '/pets', method)
  end

  def request_content(params, consumes)
    operation_at(convert_operation('consumes' => consumes, 'parameters' => params, 'responses' => {}))
      .dig('requestBody', 'content')
  end

  describe '.swagger?' do
    it 'recognizes a Swagger 2.x document by its swagger key' do
      expect(described_class.swagger?(document)).to be true
    end

    it 'does not claim OpenAPI 3 documents or non-hashes', :aggregate_failures do
      expect(described_class.swagger?({ 'openapi' => '3.0.3' })).to be false
      expect(described_class.swagger?('swagger: 2.0')).to be false
    end
  end

  describe 'document metadata' do
    it 'declares OpenAPI 3.0.3, keeps info and x- extensions', :aggregate_failures do
      converted = described_class.convert(document.merge('x-team' => 'payments'))

      expect(converted['openapi']).to eq '3.0.3'
      expect(converted['info']).to eq('title' => 'Legacy', 'version' => '1')
      expect(converted['x-team']).to eq 'payments'
    end

    it 'builds a server from host, basePath and the preferred scheme' do
      expect(described_class.convert(document)['servers']).to eq [{ 'url' => 'https://api.legacy.test/v2' }]
    end

    it 'keeps a relative server when the document has no host' do
      doc = document.merge('host' => nil, 'schemes' => nil)
      expect(described_class.convert(doc)['servers']).to eq [{ 'url' => '/v2' }]
    end

    it 'declares no servers when there is neither host nor basePath' do
      doc = document.except('host', 'basePath')
      expect(described_class.convert(doc)['servers']).to eq []
    end
  end

  describe 'definitions and references' do
    let(:ref_operation) do
      { 'parameters' => [{ 'name' => 'pet', 'in' => 'body', 'required' => true, 'schema' => pet_ref }],
        'responses' => { '200' => { 'description' => 'ok', 'schema' => pet_ref } } }
    end

    it 'moves definitions to components/schemas and rewrites references to them', :aggregate_failures do
      converted = convert_operation(ref_operation)

      expect(converted['components']['schemas']['Pet']['required']).to eq ['name']
      expect(operation_at(converted).dig('requestBody', 'content', 'application/json', 'schema'))
        .to eq('$ref' => '#/components/schemas/Pet')
    end
  end

  describe 'parameters' do
    # Fixtures are methods, not lets, so the group stays within the helper limit.
    def body_param
      { 'name' => 'pet', 'in' => 'body', 'required' => true, 'schema' => { 'type' => 'object' } }
    end

    def form_params
      [{ 'name' => 'email', 'in' => 'formData', 'type' => 'string', 'required' => true },
       { 'name' => 'balance', 'in' => 'formData', 'type' => 'integer', 'format' => 'int32' }]
    end

    def query_and_path
      [{ 'name' => 'limit', 'in' => 'query', 'type' => 'integer', 'minimum' => 1, 'maximum' => 100,
         'collectionFormat' => 'multi', 'default' => 20 },
       { 'name' => 'id', 'in' => 'path', 'required' => true, 'type' => 'string' }]
    end

    # A path item whose parameters are shared, and whose post overrides one of them.
    def shared_item
      { 'parameters' => [{ 'name' => 'trace', 'in' => 'header', 'type' => 'string' },
                         { 'name' => 'limit', 'in' => 'query', 'type' => 'integer' }],
        'post' => { 'parameters' => [{ 'name' => 'limit', 'in' => 'query', 'type' => 'string' }], 'responses' => {} } }
    end

    def expected_query_and_path
      [{ 'name' => 'limit', 'in' => 'query',
         'schema' => { 'type' => 'integer', 'minimum' => 1, 'maximum' => 100, 'default' => 20 } },
       { 'name' => 'id', 'in' => 'path', 'required' => true, 'schema' => { 'type' => 'string' } }]
    end

    it 'turns a body parameter into a requestBody using the first consumes media type', :aggregate_failures do
      operation = { 'consumes' => %w[application/xml application/json], 'parameters' => [body_param],
                    'responses' => {} }
      request = operation_at(convert_operation(operation))['requestBody']

      expect(request['required']).to be true
      expect(request['content'].keys).to eq ['application/xml']
    end

    it 'maps formData parameters to an urlencoded object body with required fields' do
      schema = request_content(form_params,
                               %w[application/x-www-form-urlencoded])['application/x-www-form-urlencoded']['schema']

      expect(schema).to eq('type' => 'object', 'required' => ['email'],
                           'properties' => { 'email' => { 'type' => 'string' },
                                             'balance' => { 'type' => 'integer', 'format' => 'int32' } })
    end

    it 'uses multipart when a formData parameter is a file', :aggregate_failures do
      content = request_content([{ 'name' => 'avatar', 'in' => 'formData', 'type' => 'file' }], %w[multipart/form-data])

      expect(content.keys).to eq ['multipart/form-data']
      expect(content['multipart/form-data']['schema']['properties']['avatar']).to eq('type' => 'string',
                                                                                     'format' => 'binary')
    end

    it 'converts query and path parameters into OpenAPI 3 parameter schemas' do
      converted = operation_at(convert_operation('parameters' => query_and_path, 'responses' => {}))['parameters']

      expect(converted).to eq expected_query_and_path
    end

    it 'merges path-level parameters into each operation, with the operation winning' do
      converted = described_class.convert(document.merge('paths' => { '/pets' => shared_item }))
      params = operation_at(converted)['parameters']

      expect(params.map { |param| [param['name'], param['schema']['type']] }).to eq [%w[trace string], %w[limit string]]
    end

    it 'resolves parameter references to the global parameters section' do
      global = { 'PageSize' => { 'name' => 'page_size', 'in' => 'query', 'type' => 'integer' } }
      item = { 'get' => { 'parameters' => [{ '$ref' => '#/parameters/PageSize' }], 'responses' => {} } }
      doc = document.merge('parameters' => global, 'paths' => { '/pets' => item })

      expect(described_class.convert(doc).dig('paths', '/pets', 'get', 'parameters'))
        .to eq [{ 'name' => 'page_size', 'in' => 'query', 'schema' => { 'type' => 'integer' } }]
    end
  end

  describe 'responses' do
    let(:reference_document) do
      item = { 'get' => { 'responses' => { '404' => { '$ref' => '#/responses/NotFound' } } } }
      document.merge('responses' => { 'NotFound' => { 'description' => 'missing' } }, 'paths' => { '/pets' => item })
    end

    let(:responses) do
      { '200' => { 'description' => 'ok', 'schema' => { 'type' => 'array' } },
        'default' => { 'description' => 'error' } }
    end

    it 'uses the first produces media type and keeps the default response', :aggregate_failures do
      converted = convert_operation('produces' => %w[application/json application/xml], 'responses' => responses)

      expect(operation_at(converted).dig('responses', '200', 'content').keys).to eq ['application/json']
      expect(operation_at(converted).dig('responses', 'default')).to eq('description' => 'error')
    end

    it 'keeps response references and moves the global responses to components/responses', :aggregate_failures do
      converted = described_class.convert(reference_document)

      expect(converted.dig('paths', '/pets', 'get', 'responses',
                           '404')).to eq('$ref' => '#/components/responses/NotFound')
      expect(converted.dig('components', 'responses', 'NotFound')).to eq('description' => 'missing')
    end

    it 'maps a file response schema to a binary string' do
      response = { '200' => { 'description' => 'file', 'schema' => { 'type' => 'file' } } }
      schema = operation_at(convert_operation('responses' => response)).dig('responses', '200', 'content',
                                                                            'application/json', 'schema')

      expect(schema).to eq('type' => 'string', 'format' => 'binary')
    end
  end

  describe 'security definitions' do
    let(:definitions) do
      { 'basic' => { 'type' => 'basic' },
        'key' => { 'type' => 'apiKey', 'name' => 'X-Key', 'in' => 'header' },
        'oauth' => { 'type' => 'oauth2', 'flow' => 'accessCode', 'authorizationUrl' => 'https://auth.test/authorize',
                     'tokenUrl' => 'https://auth.test/token', 'scopes' => { 'read' => 'read data' } } }
    end

    it 'maps basic, apiKey and oauth2 definitions to securitySchemes', :aggregate_failures do
      schemes = described_class.convert(document.merge('securityDefinitions' => definitions)).dig('components',
                                                                                                  'securitySchemes')

      expect(schemes['basic']).to eq('type' => 'http', 'scheme' => 'basic')
      expect(schemes['key']).to eq('type' => 'apiKey', 'name' => 'X-Key', 'in' => 'header')
      expect(schemes['oauth']['flows'].keys).to eq ['authorizationCode']
    end
  end
end

# rubocop:enable RSpec/SpecFilePathFormat
