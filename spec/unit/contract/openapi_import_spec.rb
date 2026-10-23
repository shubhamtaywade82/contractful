# frozen_string_literal: true

require_relative '../../spec_helper'
require 'contractful/contract/openapi_import'
require 'fileutils'
require 'tmpdir'
require 'pathname'

RSpec.describe Contractful::Contract::OpenAPIImport do
  subject(:mod) { described_class }

  let(:user_schema) do
    {
      'type' => 'object',
      'required' => %w[id email],
      'properties' => {
        'id' => { 'type' => 'integer' },
        'email' => { 'type' => 'string' },
        'role' => { 'type' => 'string', 'enum' => %w[admin member] }
      }
    }
  end

  let(:doc) do
    {
      'openapi' => '3.0.3',
      'info' => { 'title' => 'Acme API', 'version' => '1.0.0' },
      'servers' => [{ 'url' => 'https://api.acme.test/v1' }],
      'components' => {
        'securitySchemes' => { 'bearerAuth' => { 'type' => 'http', 'scheme' => 'bearer' } },
        'schemas' => { 'User' => user_schema }
      },
      'paths' => {
        '/users' => {
          'get' => {
            'operationId' => 'listUsers',
            'parameters' => [
              { 'name' => 'page', 'in' => 'query',
                'schema' => { 'type' => 'integer', 'minimum' => 1, 'default' => 1 } },
              { 'name' => 'role', 'in' => 'query',
                'schema' => { 'type' => 'string', 'enum' => %w[admin member] } }
            ],
            'responses' => {
              '200' => { 'content' => { 'application/json' => { 'schema' => {
                'type' => 'array', 'items' => { '$ref' => '#/components/schemas/User' }
              } } } },
              '401' => { 'description' => 'unauthorized' }
            }
          },
          'post' => {
            'operationId' => 'createUser',
            'requestBody' => { 'content' => { 'application/json' => { 'schema' => {
              'type' => 'object', 'required' => ['email'],
              'properties' => {
                'email' => { 'type' => 'string' },
                'age' => { 'type' => 'integer', 'minimum' => 18 },
                'name' => { 'type' => 'string', 'minLength' => 2, 'maxLength' => 40 },
                'patterned' => { 'type' => 'string', 'pattern' => '\A[a-z]+\z' }
              }
            } } } },
            'responses' => {
              '201' => { 'content' => { 'application/json' => { 'schema' => {
                '$ref' => '#/components/schemas/User'
              } } } },
              '422' => { 'content' => { 'application/json' => { 'schema' => { 'type' => 'object' } } } }
            }
          }
        },
        '/users/{id}' => {
          'get' => {
            'summary' => 'Fetch one user',
            'parameters' => [
              { 'name' => 'id', 'in' => 'path', 'required' => true,
                'schema' => { 'type' => 'integer' } }
            ],
            'responses' => {
              '200' => { 'content' => { 'application/json' => { 'schema' => {
                '$ref' => '#/components/schemas/User'
              } } } },
              'default' => { 'description' => 'anything' }
            }
          }
        }
      }
    }
  end

  def definitions(source = doc, **opts)
    mod.definitions(source, **opts)
  end

  describe '.load' do
    it 'passes a Hash through' do
      expect(mod.load(doc)).to eq doc
    end

    it 'parses YAML text' do
      text = "openapi: 3.0.3\ninfo:\n  title: T\n  version: '1'\npaths: {}"
      expect(mod.load(text)).to include('openapi' => '3.0.3')
    end

    it 'parses JSON text' do
      expect(mod.load('{"openapi": "3.1.0"}')).to include('openapi' => '3.1.0')
    end

    it 'loads YAML and JSON files from a path string or Pathname' do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, 'api.yaml')
        json_path = File.join(dir, 'api.json')
        File.write(yaml_path, YAML.dump(doc))
        File.write(json_path, JSON.generate(doc))

        expect(mod.load(yaml_path)['info']).to eq doc['info']
        expect(mod.load(Pathname.new(json_path))['info']).to eq doc['info']
      end
    end

    it 'raises on a missing file' do
      expect { mod.load('/nonexistent/spec/openapi.yaml') }
        .to raise_error(mod::Error, /no such file/)
    end

    it 'raises on invalid YAML' do
      expect { mod.load("openapi: 3.0.3\n  bad:\n  - : : :") }
        .to raise_error(mod::Error, /invalid YAML/)
    end

    it 'rejects an openapi field with a 2.x value, which is not a version (Swagger 2.0 uses swagger:)' do
      expect { definitions({ 'openapi' => '2.0', 'paths' => {} }) }
        .to raise_error(mod::Error, /'openapi' version field "2\.0" \(expected 3\.x\)/)
    end

    it 'raises on a missing or non-3.x version' do
      expect { definitions({ 'paths' => {} }) }
        .to raise_error(mod::Error, /missing or unsupported 'openapi' version/)
      expect { definitions({ 'openapi' => '4.0.0', 'paths' => {} }) }
        .to raise_error(mod::Error, /missing or unsupported/)
    end

    it 'raises when the document declares no paths' do
      expect { definitions({ 'openapi' => '3.0.3', 'paths' => {} }) }
        .to raise_error(mod::Error, /declares no paths/)
    end
  end

  describe '.definitions — naming' do
    it 'snake-cases operationIds' do
      expect(definitions.keys).to include(:list_users, :create_user)
    end

    it 'derives names from verb + path segments when operationId is absent' do
      expect(definitions.keys).to include(:get_users_id)
    end

    it 'collapses placeholder braces in derived names without double underscores' do
      expect(definitions[:get_users_id].path_template).to eq '/users/:id'
    end

    it 'deduplicates name collisions with a numeric suffix' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/a' => { 'get' => { 'operationId' => 'doThing', 'responses' => {} } },
        '/b' => { 'get' => { 'operationId' => 'do-thing', 'responses' => {} } }
      } }
      expect(definitions(d).keys).to eq %i[do_thing do_thing_2]
    end

    it 'never produces reserved names' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/x' => { 'get' => { 'operationId' => 'send', 'responses' => {} } }
      } }
      expect(definitions(d).keys).not_to include(:send)
    end

    it 'sanitizes characters that cannot appear in Ruby method names' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/v2/orders history' => { 'get' => { 'operationId' => 'list.orders history!',
                                             'responses' => {} } }
      } }
      expect(definitions(d).keys).to include(:list_orders_history)
    end

    it 'raises on invalid path placeholders' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/files/{file name}' => { 'get' => { 'responses' => {} } }
      } }
      expect { definitions(d) }.to raise_error(mod::Error, /not a valid Ruby identifier/)
    end

    it 'filters with only:/except: by final operation name' do
      expect(definitions(doc, only: [:list_users]).keys).to eq %i[list_users]
      expect(definitions(doc, except: %i[list_users create_user]).keys).to eq %i[get_users_id]
    end
  end

  describe '.definitions — params' do
    it 'maps query params with types, defaults, enums and constraints' do
      page = definitions[:list_users].params[:page]
      expect(page.type).to eq Integer
      expect(page.has_default?).to be true
      expect(page.default_value).to eq 1
      expect(page.min).to eq 1

      role = definitions[:list_users].params[:role]
      expect(role.type).to eq String
      expect(role.inclusion).to eq %w[admin member]
    end

    it 'declares path params explicitly (replacing the synthesized String param)' do
      param = definitions[:get_users_id].params[:id]
      expect(param.type).to eq Integer
      expect(param.required?).to be true
    end

    it 'shifts an exclusive integer bound by one' do
      d = { 'openapi' => '3.0.3',
            'paths' => {
              '/counts' => { 'get' => {
                'operationId' => 'getCounts',
                'parameters' => [{ 'name' => 'count', 'in' => 'query',
                                   'schema' => { 'type' => 'integer', 'exclusiveMinimum' => 5 } }],
                'responses' => {}
              } }
            } }

      import = mod.import(d)

      expect(import.definitions[:get_counts].params[:count].min).to eq 6
      expect(import.notes.join).not_to match(/exclusiveMinimum approximated/)
    end

    it 'does not shift an exclusive numeric bound for a number schema' do
      d = { 'openapi' => '3.0.3',
            'paths' => {
              '/ratios' => { 'get' => {
                'operationId' => 'getRatios',
                'parameters' => [{ 'name' => 'ratio', 'in' => 'query',
                                   'schema' => { 'type' => 'number', 'exclusiveMinimum' => 5 } }],
                'responses' => {}
              } }
            } }

      import = mod.import(d)
      param = import.definitions[:get_ratios].params[:ratio]

      expect(param.min).to eq 5
      expect(import.notes.join).to match(/exclusiveMinimum approximated as an inclusive bound/)
      expect { param.process!(5.5) }.not_to raise_error
    end

    it 'maps request body properties with required from the schema required array' do
      params = definitions[:create_user].params
      expect(params[:email].required?).to be true
      expect(params[:age].required?).to be false
      expect(params[:age].type).to eq Integer
      expect(params[:age].min).to eq 18
    end

    it 'maps minLength/maxLength to a length range and pattern to a Regexp' do
      name = definitions[:create_user].params[:name]
      expect(name.length).to eq(2..40)
      patterned = definitions[:create_user].params[:patterned]
      expect(patterned.pattern).to eq(/\A[a-z]+\z/)
    end

    it 'maps form-urlencoded request bodies to payload_style :form' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/token' => { 'post' => {
          'requestBody' => { 'content' => {
            'application/x-www-form-urlencoded' => { 'schema' => {
              'type' => 'object',
              'properties' => { 'grant_type' => { 'type' => 'string' } }
            } }
          } },
          'responses' => {}
        } }
      } }
      expect(definitions(d)[:post_token].payload_style).to eq :form
    end

    it 'maps form-urlencoded request body properties to params like JSON body properties' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/customers' => { 'post' => {
          'requestBody' => { 'content' => {
            'application/x-www-form-urlencoded' => { 'schema' => {
              'type' => 'object',
              'required' => ['email'],
              'properties' => {
                'email' => { 'type' => 'string' },
                'name' => { 'type' => 'string' },
                'balance' => { 'type' => 'integer' }
              }
            } }
          } },
          'responses' => {}
        } }
      } }
      import = mod.import(d)
      definition = import.definitions[:post_customers]

      expect(definition.payload_style).to eq :form
      expect(definition.params.keys).to eq %i[email name balance]
      expect(definition.params[:email].required?).to be true
      expect(definition.params[:balance].type).to eq Integer
      expect(import.notes).to be_empty
    end

    it 'prefers the JSON body when a request offers both JSON and form media types' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/orders' => { 'post' => {
          'requestBody' => { 'content' => {
            'application/json' => { 'schema' => {
              'type' => 'object', 'properties' => { 'sku' => { 'type' => 'string' } }
            } },
            'application/x-www-form-urlencoded' => { 'schema' => {
              'type' => 'object', 'properties' => { 'coupon' => { 'type' => 'string' } }
            } }
          } },
          'responses' => {}
        } }
      } }
      definition = mod.import(d).definitions[:post_orders]

      expect(definition.params.keys).to eq [:sku]
      expect(definition.payload_style).to be_nil
    end

    it 'keeps a custom-verb suffix that follows a path placeholder' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/things/{id}:archive' => { 'post' => {
          'operationId' => 'archiveThing',
          'parameters' => [{ 'name' => 'id', 'in' => 'path', 'required' => true,
                             'schema' => { 'type' => 'integer' } }],
          'responses' => {}
        } }
      } }
      definition = definitions(d)[:archive_thing]

      expect(definition.path_template).to eq '/things/:id:archive'
      expect(definition.path_param_names).to eq %i[id]
      expect(definition.params[:id].type).to eq Integer
      expect(definition.expand_path(id: 5).first).to eq '/things/5:archive'
    end

    it 'uses payload_style :query for body-less POST/PUT/PATCH with query params' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/search' => { 'post' => {
          'parameters' => [{ 'name' => 'q', 'in' => 'query',
                             'schema' => { 'type' => 'string' } }],
          'responses' => {}
        } }
      } }
      expect(definitions(d)[:post_search].payload_style).to eq :query
    end

    it 'merges path-level and operation-level parameters (operation wins)' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/items/{id}' => {
          'parameters' => [
            { 'name' => 'id', 'in' => 'path', 'schema' => { 'type' => 'string' } },
            { 'name' => 'verbose', 'in' => 'query', 'schema' => { 'type' => 'boolean' } }
          ],
          'get' => {
            'parameters' => [
              { 'name' => 'id', 'in' => 'path', 'schema' => { 'type' => 'integer' } }
            ],
            'responses' => {}
          }
        }
      } }
      params = definitions(d)[:get_items_id].params
      expect(params[:id].type).to eq Integer
      expect(params[:verbose].type).to eq :boolean
    end

    it 'resolves $ref parameters' do
      d = { 'openapi' => '3.0.3',
            'components' => { 'parameters' => {
              'PageParam' => { 'name' => 'page', 'in' => 'query',
                               'schema' => { 'type' => 'integer' } }
            } },
            'paths' => {
              '/logs' => { 'get' => {
                'parameters' => [{ '$ref' => '#/components/parameters/PageParam' }],
                'responses' => {}
              } }
            } }
      expect(definitions(d)[:get_logs].params[:page].type).to eq Integer
    end

    it 'resolves nested $ref schemas in params' do
      d = { 'openapi' => '3.0.3',
            'components' => { 'schemas' => {
              'Limit' => { 'type' => 'integer', 'maximum' => 100 }
            } },
            'paths' => {
              '/things' => { 'get' => {
                'parameters' => [{ 'name' => 'limit', 'in' => 'query',
                                   'schema' => { '$ref' => '#/components/schemas/Limit' } }],
                'responses' => {}
              } }
            } }
      expect(definitions(d)[:get_things].params[:limit].max).to eq 100
    end
  end

  describe 'Swagger 2.0 documents' do
    let(:swagger) do
      {
        'swagger' => '2.0',
        'info' => { 'title' => 'Legacy', 'version' => '1' },
        'host' => 'api.legacy.test',
        'basePath' => '/v2',
        'schemes' => ['https'],
        'securityDefinitions' => { 'basic' => { 'type' => 'basic' } },
        'definitions' => {
          'Pet' => { 'type' => 'object', 'required' => ['name'],
                     'properties' => { 'name' => { 'type' => 'string' }, 'tag' => { 'type' => 'string' } } }
        },
        'paths' => { '/pets' => { 'post' => {
          'operationId' => 'createPet',
          'parameters' => [{ 'name' => 'pet', 'in' => 'body', 'required' => true,
                             'schema' => { '$ref' => '#/definitions/Pet' } }],
          'responses' => { '200' => { 'description' => 'ok', 'schema' => { '$ref' => '#/definitions/Pet' } } }
        } } }
      }
    end

    it 'imports the body, response fields, base URL and security as an OpenAPI 3 document would' do
      import = mod.import(swagger)
      definition = import.definitions[:create_pet]

      expect(import.base_url).to eq 'https://api.legacy.test/v2'
      expect(import.auth_hints.join).to match(/auth basic/)
      expect(definition.params.keys).to eq %i[name tag]
      expect(definition.params[:name].required?).to be true
      expect(definition.response_fields.keys).to eq %i[name tag]
    end

    it 'renders a client whose contracts describe identically to the import' do
      import = mod.import(swagger)
      generated = Module.new
      generated.module_eval(mod.to_ruby(swagger, class_name: 'LegacyPets'))
      contract = generated.const_get(:LegacyPets).contract_for(:create_pet)

      expect(contract.describe).to eq import.definitions[:create_pet].describe
      expect(mod.to_ruby(swagger, class_name: 'LegacyPets')).to include('# Source: Legacy (Swagger 2.0, version 1)')
    end

    it 'bundles an external Swagger 2.0 file and resolves its own definitions' do
      Dir.mktmpdir do |dir|
        defs = {
          'swagger' => '2.0', 'info' => { 'title' => 'defs', 'version' => '1' }, 'paths' => {},
          'definitions' => {
            'User' => { 'type' => 'object',
                        'properties' => { 'id' => { 'type' => 'integer' },
                                          'address' => { '$ref' => '#/definitions/Address' } } },
            'Address' => { 'type' => 'object', 'properties' => { 'city' => { 'type' => 'string' } } }
          }
        }
        File.write(File.join(dir, 'defs.yaml'), YAML.dump(defs))
        ok = { 'description' => 'ok', 'schema' => { '$ref' => 'defs.yaml#/definitions/User' } }
        root_doc = swagger.merge('paths' => { '/users' => { 'get' => { 'operationId' => 'listUsers',
                                                                       'responses' => { '200' => ok } } } })
        root_path = File.join(dir, 'api.yaml')
        File.write(root_path, YAML.dump(root_doc))

        definition = mod.import(root_path).definitions[:list_users]

        expect(definition.response_fields[:id].type).to eq Integer
        expect(definition.response_fields[:address].type).to eq Hash
      end
    end
  end

  describe 'external file $refs' do
    let(:dir) { Dir.mktmpdir }
    let(:user_schema) do
      { 'User' => { 'type' => 'object', 'required' => ['id'],
                    'properties' => { 'id' => { 'type' => 'integer' } } } }
    end

    after { FileUtils.remove_entry(dir) }

    def write_yaml(name, data)
      path = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(data))
      path
    end

    def root_document(ref, extra = {})
      {
        'openapi' => '3.0.3',
        'paths' => { '/users' => { 'get' => {
          'operationId' => 'listUsers',
          'responses' => { '200' => { 'description' => 'ok', 'content' => { 'application/json' => {
            'schema' => { '$ref' => ref }
          } } } }
        } } }
      }.merge(extra)
    end

    it 'bundles a schema from a sibling file and types its fields' do
      write_yaml('schemas/user.yaml', user_schema)
      root = write_yaml('api.yaml', root_document('schemas/user.yaml#/User'))

      definition = mod.import(root).definitions[:list_users]

      expect(definition.response_fields.keys).to eq %i[id]
      expect(definition.response_fields[:id].required?).to be true
      expect(definition.response_type).to eq Hash
    end

    it 'resolves local refs inside an external file against that file' do
      write_yaml('schemas/user.yaml', {
                   'User' => { 'type' => 'object', 'properties' => { 'address' => { '$ref' => '#/Address' } } },
                   'Address' => { 'type' => 'object', 'properties' => { 'city' => { 'type' => 'string' } } }
                 })
      root = write_yaml('api.yaml', root_document('schemas/user.yaml#/User'))

      definition = mod.import(root).definitions[:list_users]

      expect(definition.response_fields[:address].type).to eq Hash
    end

    it 'resolves refs inside an external file relative to that file' do
      write_yaml('schemas/common/ids.yaml', { 'Id' => { 'type' => 'integer' } })
      write_yaml('schemas/user.yaml', {
                   'User' => { 'type' => 'object', 'properties' => { 'id' => { '$ref' => 'common/ids.yaml#/Id' } } }
                 })
      root = write_yaml('api.yaml', root_document('schemas/user.yaml#/User'))

      import = mod.import(root)

      expect(import.definitions[:list_users].response_fields[:id].type).to eq Integer
      expect(import.notes.grep(/unresolvable/)).to be_empty
    end

    it 'terminates on circular references between external files' do
      write_yaml('a.yaml', { 'A' => { 'type' => 'object', 'properties' => { 'b' => { '$ref' => 'b.yaml#/B' } } } })
      write_yaml('b.yaml', { 'B' => { 'type' => 'object', 'properties' => { 'a' => { '$ref' => 'a.yaml#/A' } } } })
      root = write_yaml('api.yaml', root_document('a.yaml#/A'))

      definition = mod.import(root).definitions[:list_users]

      expect(definition.response_fields.keys).to eq %i[b]
    end

    it 'resolves a ref back into the root document without copying the root' do
      components = { 'components' => { 'schemas' => {
        'User' => { 'type' => 'object', 'properties' => { 'id' => { 'type' => 'integer' } } }
      } } }
      root = write_yaml('api.yaml', root_document('other.yaml#/Wrapper', components))
      write_yaml('other.yaml', {
                   'Wrapper' => { 'type' => 'object',
                                  'properties' => { 'user' => { '$ref' => 'api.yaml#/components/schemas/User' } } }
                 })

      import = mod.import(root)
      definition = import.definitions[:list_users]

      expect(definition.response_fields.keys).to eq %i[user]
      expect(definition.response_fields[:user].type).to eq Hash
      expect(import.document['x-contractful-external'].size).to eq 1
    end

    it 'raises when a referenced file cannot be read' do
      root = write_yaml('api.yaml', root_document('schemas/missing.yaml#/User'))

      expect { mod.import(root) }.to raise_error(mod::Error, /no such file/)
    end

    it 'never fetches remote refs and reports them as unresolved' do
      root = write_yaml('api.yaml', root_document('https://example.test/schemas.yaml#/User'))

      import = mod.import(root)

      expect(import.notes.join).to match(%r{unresolvable \$ref "https://example\.test})
      expect(a_request(:any, //)).not_to have_been_made
    end
  end

  describe 'header and cookie parameters' do
    let(:parameters) do
      [
        { 'name' => 'X-Request-Id', 'in' => 'header', 'required' => true, 'schema' => { 'type' => 'string' } },
        { 'name' => 'X-Trace', 'in' => 'header', 'schema' => { 'type' => 'integer', 'default' => 1 } },
        { 'name' => 'session_id', 'in' => 'cookie', 'schema' => { 'type' => 'string' } },
        { 'name' => 'X-List', 'in' => 'header', 'schema' => { 'type' => 'array', 'items' => { 'type' => 'string' } } },
        { 'name' => 'bad name', 'in' => 'header', 'schema' => { 'type' => 'string' } }
      ]
    end
    let(:doc) do
      {
        'openapi' => '3.0.3',
        'paths' => { '/items' => { 'get' => {
          'operationId' => 'listItems', 'parameters' => parameters, 'responses' => {}
        } } }
      }
    end

    it 'maps header params to header: declarations with snake_cased names' do
      definition = mod.import(doc).definitions[:list_items]

      expect(definition.params[:x_request_id].header).to eq 'X-Request-Id'
      expect(definition.params[:x_request_id].required?).to be true
      expect(definition.params[:x_trace].header).to eq 'X-Trace'
      expect(definition.params[:x_trace].default_value).to eq 1
    end

    it 'maps cookie params to cookie: declarations' do
      expect(mod.import(doc).definitions[:list_items].params[:session_id].cookie).to eq 'session_id'
    end

    it 'notes header params that cannot be sent as a scalar header or a header name' do
      notes = mod.import(doc).notes.join("\n")

      expect(notes).to match(/X-List.*not representable as a scalar header value/)
      expect(notes).to match(/bad name.*not a valid HTTP header name/)
    end

    it 'renders header and cookie options that re-evaluate to the same contract' do
      source = mod.to_ruby(doc, class_name: 'HeaderRoundTrip')
      generated = Module.new
      generated.module_eval(source)
      contract = generated.const_get(:HeaderRoundTrip).contract_for(:list_items)

      expect(contract.params[:x_request_id].header).to eq 'X-Request-Id'
      expect(contract.params[:session_id].cookie).to eq 'session_id'
    end
  end

  describe 'allOf composition' do
    let(:components) do
      {
        'Base' => { 'type' => 'object', 'required' => ['id'],
                    'properties' => { 'id' => { 'type' => 'integer' } } },
        'Role' => { 'type' => 'string', 'enum' => %w[admin member] }
      }
    end

    def doc_with(operation)
      {
        'openapi' => '3.0.3',
        'components' => { 'schemas' => components },
        'paths' => { '/items' => { 'post' => { 'responses' => {} }.merge(operation) } }
      }
    end

    it 'flattens an allOf of object schemas into one body with merged required fields' do
      d = doc_with(
        'operationId' => 'createItem',
        'requestBody' => { 'content' => { 'application/json' => { 'schema' => {
          'allOf' => [
            { '$ref' => '#/components/schemas/Base' },
            { 'type' => 'object', 'required' => ['name'],
              'properties' => { 'name' => { 'type' => 'string', 'minLength' => 1, 'maxLength' => 40 } } }
          ]
        } } } }
      )
      import = mod.import(d)
      params = import.definitions[:create_item].params

      expect(params.keys).to eq %i[id name]
      expect(params[:id].required?).to be true
      expect(params[:name].required?).to be true
      expect(params[:name].length).to eq(1..40)
      expect(import.notes.grep(/allOf/)).to be_empty
    end

    it 'flattens an allOf response schema so its members become response fields' do
      d = doc_with(
        'operationId' => 'getItem',
        'responses' => { '200' => { 'description' => 'ok', 'content' => { 'application/json' => { 'schema' => {
          'allOf' => [
            { '$ref' => '#/components/schemas/Base' },
            { 'type' => 'object', 'properties' => { 'label' => { 'type' => 'string' } } }
          ]
        } } } } }
      )
      definition = mod.import(d).definitions[:get_item]

      expect(definition.response_type).to eq Hash
      expect(definition.response_fields.keys).to eq %i[id label]
      expect(definition.response_fields[:id].required?).to be true
    end

    it 'unwraps a single allOf reference that only adds annotations' do
      d = doc_with(
        'operationId' => 'setRole',
        'parameters' => [{ 'name' => 'role', 'in' => 'query', 'schema' => {
          'allOf' => [{ '$ref' => '#/components/schemas/Role' }],
          'description' => 'Access level'
        } }]
      )
      import = mod.import(d)
      param = import.definitions[:set_role].params[:role]

      expect(param.type).to eq String
      expect(param.inclusion).to eq %w[admin member]
      expect(import.notes.grep(/allOf/)).to be_empty
    end

    it 'keeps an allOf that mixes object and scalar members as a note' do
      d = doc_with(
        'operationId' => 'mixed',
        'parameters' => [{ 'name' => 'filter', 'in' => 'query', 'schema' => {
          'allOf' => [{ 'type' => 'object' }, { 'type' => 'string' }]
        } }]
      )
      import = mod.import(d)

      expect(import.definitions[:mixed].params[:filter].type).to be_nil
      expect(import.notes.join).to match(/allOf schemas are not representable/)
    end
  end

  describe '.definitions — responses' do
    it 'collects statuses sorted and derives the body type from the first 2xx JSON schema' do
      d = definitions[:list_users]
      expect(d.response_statuses).to eq [200, 401]
      expect(d.response_type).to eq Array
    end

    it 'maps object responses to Hash with open-schema response fields from $refs' do
      d = definitions[:create_user]
      expect(d.response_type).to eq Hash
      expect(d.response_fields.keys).to eq %i[id email role]
      expect(d.response_fields[:id].required?).to be true
      expect(d.response_fields[:id].type).to eq Integer
      expect(d.response_fields[:role].required?).to be false
      expect(d.response_fields[:role].inclusion).to eq %w[admin member]
      expect(d.response_fields[:role]).not_to be_strict
    end

    it 'maps 2XX wildcards to a Range' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/anything' => { 'get' => {
          'responses' => { '2XX' => { 'content' => { 'application/json' => {
            'schema' => { 'type' => 'object' }
          } } } }
        } }
      } }
      definition = definitions(d)[:get_anything]
      expect(definition.response_statuses).to eq [(200..299)]
      expect(definition.response_type).to eq Hash
    end

    it 'notes and skips the default response' do
      import = mod.import(doc)
      expect(import.notes).to include(/response "default": the 'default' response is not representable/)
      expect(definitions[:get_users_id].response_statuses).to eq [200]
    end

    it 'derives type :json for JSON bodies without a resolvable shape' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/blob' => { 'get' => {
          'responses' => { '200' => { 'content' => { 'application/json' => {} } } }
        } }
      } }
      expect(definitions(d)[:get_blob].response_type).to eq :json
    end

    it 'keeps string responses as String with no response fields' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/health' => { 'get' => {
          'responses' => { '200' => { 'content' => { 'application/json' => {
            'schema' => { 'type' => 'string' }
          } } } }
        } }
      } }
      definition = definitions(d)[:get_health]
      expect(definition.response_type).to eq String
      expect(definition.response_fields).to be_empty
    end
  end

  describe 'the notes channel' do
    it 'reports header and cookie params that cannot be carried as a scalar on the wire' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/w' => { 'get' => {
          'parameters' => [
            { 'name' => 'X-List', 'in' => 'header',
              'schema' => { 'type' => 'array', 'items' => { 'type' => 'string' } } },
            { 'name' => 'bad sid', 'in' => 'cookie', 'schema' => { 'type' => 'string' } }
          ],
          'responses' => {}
        } }
      } }
      notes = mod.import(d).notes
      expect(notes).to include(/header param "X-List": not representable as a scalar header value/)
      expect(notes).to include(/cookie param "bad sid": name "bad sid" is not a valid cookie name/)
    end

    it 'reports multipart and non-JSON bodies' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/upload' => { 'post' => {
          'requestBody' => { 'content' => { 'multipart/form-data' => {
            'schema' => { 'type' => 'object',
                          'properties' => { 'file' => { 'type' => 'string', 'format' => 'binary' } } }
          } } },
          'responses' => {}
        } }
      } }
      expect(mod.import(d).notes).to include(%r{multipart/form-data.*not representable as contract params})
    end

    it 'reports oneOf unions instead of guessing' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/pay' => { 'post' => {
          'requestBody' => { 'content' => { 'application/json' => {
            'schema' => { 'oneOf' => [{ 'type' => 'object' }, { 'type' => 'array' }] }
          } } },
          'responses' => {}
        } }
      } }
      expect(mod.import(d).notes).to include(%r{schema combination \(oneOf/anyOf/allOf\)})
      expect(definitions(d)[:post_pay].params).to be_empty
    end

    it 'reports mixed query params on body verbs' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/orders' => { 'post' => {
          'parameters' => [{ 'name' => 'dry_run', 'in' => 'query',
                             'schema' => { 'type' => 'boolean' } }],
          'requestBody' => { 'content' => { 'application/json' => {
            'schema' => { 'type' => 'object', 'properties' => { 'qty' => { 'type' => 'integer' } } }
          } } },
          'responses' => {}
        } }
      } }
      notes = mod.import(d).notes
      expect(notes).to include(/mixes a request body and query parameters/)
      expect(definitions(d)[:post_orders].params[:dry_run]).not_to be_nil
    end

    it 'reports deprecated operations and unsupported status spellings' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/old' => { 'get' => {
          'deprecated' => true,
          'responses' => { 'OK' => { 'description' => 'fine' } }
        } }
      } }
      notes = mod.import(d).notes
      expect(notes).to include(%r{GET /old: deprecated operation})
      expect(notes).to include(/response code "OK" is not a numeric status/)
    end

    it 'does not invent base URLs for relative servers' do
      d = { 'openapi' => '3.0.3',
            'servers' => [{ 'url' => '/api/v1' }],
            'paths' => { '/x' => { 'get' => { 'responses' => {} } } } }
      import = mod.import(d)
      expect(import.base_url).to be_nil
      expect(import.notes).to include(/not an absolute http\(s\) URL/)
    end

    it 'reports unresolvable refs and keeps the param untyped' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/x' => { 'get' => {
          'parameters' => [{ 'name' => 'q', 'in' => 'query',
                             'schema' => { '$ref' => '#/components/schemas/Missing' } }],
          'responses' => {}
        } }
      } }
      import = mod.import(d)
      expect(import.notes.join).to match(/unresolvable \$ref/)
      expect(import.definitions[:get_x].params[:q].type).to be_nil
    end

    it 'deduplicates repeated notes' do
      d = { 'openapi' => '3.0.3', 'paths' => {
        '/a' => { 'get' => { 'parameters' => [
          { 'name' => 'bad sid', 'in' => 'cookie', 'schema' => { 'type' => 'string' } }
        ], 'responses' => {} } },
        '/b' => { 'get' => { 'parameters' => [
          { 'name' => 'bad sid', 'in' => 'cookie', 'schema' => { 'type' => 'string' } }
        ], 'responses' => {} } }
      } }
      cookie_notes = mod.import(d).notes.grep(/cookie param "bad sid"/)
      expect(cookie_notes.size).to eq 2 # distinct labels stay distinct
    end
  end

  describe 'base URL and auth hints' do
    it 'takes the first server URL' do
      expect(mod.import(doc).base_url).to eq 'https://api.acme.test/v1'
    end

    it 'substitutes server variables with their defaults' do
      d = { 'openapi' => '3.0.3', 'servers' => [{
        'url' => 'https://{region}.acme.test/v1',
        'variables' => { 'region' => { 'default' => 'us' } }
      }], 'paths' => { '/x' => { 'get' => { 'responses' => {} } } } }
      expect(mod.import(d).base_url).to eq 'https://us.acme.test/v1'
    end

    it 'emits auth hints for bearer, basic and apiKey schemes' do
      d = { 'openapi' => '3.0.3',
            'components' => { 'securitySchemes' => {
              'b' => { 'type' => 'http', 'scheme' => 'bearer' },
              'ba' => { 'type' => 'http', 'scheme' => 'basic' },
              'key' => { 'type' => 'apiKey', 'in' => 'header', 'name' => 'X-Api-Key' },
              'qkey' => { 'type' => 'apiKey', 'in' => 'query', 'name' => 'api_token' }
            } },
            'paths' => { '/x' => { 'get' => { 'responses' => {} } } } }
      hints = mod.import(d).auth_hints
      expect(hints.grep(/auth bearer:/).first).to include("ENV['B_TOKEN']")
      expect(hints.grep(/auth basic:/).first).to include("ENV['BA_USER']")
      expect(hints.grep(/auth api_key:/).first).to include('"X-Api-Key"')
      expect(hints.grep(/in: :query/).first).to include('"api_token"')
    end

    it 'notes OAuth schemes instead of faking them' do
      d = { 'openapi' => '3.0.3',
            'components' => { 'securitySchemes' => {
              'oa' => { 'type' => 'oauth2', 'flows' => {} }
            } },
            'paths' => { '/x' => { 'get' => { 'responses' => {} } } } }
      expect(mod.import(d).notes.join).to match(/OAuth flows are not auto-generated/)
    end
  end

  describe '.to_ruby — generated source round-trips' do
    let(:class_token) { "G#{object_id.abs}" }
    let(:source) { mod.to_ruby(doc, class_name: "Acme::#{class_token}") }
    let(:generated) do
      Object.send(:remove_const, :Acme) if Object.const_defined?(:Acme, false)
      Object.const_set(:Acme, Module.new)
      TOPLEVEL_BINDING.eval(source)
      Acme.const_get(class_token)
    end

    it 'renders valid Ruby for every imported definition' do
      expect(source).to include('base "https://api.acme.test/v1"')
      expect(source).to include('contract :list_users, "GET /users" do')
      expect(source).to include('param :page, Integer, default: 1, min: 1')
      expect(source).to include('responds 200, 401, type: :array')
      expect(source).to include('response_field :id, :integer, required: true')
      expect(source).to include('# auth bearer: -> {')
    end

    it 'evaluates to a client class whose contracts describe identically (round-trip)' do
      imported = definitions
      expect(imported.keys).to eq generated.contract_names
      imported.each do |name, definition|
        expect(generated.contract_for(name).describe).to eq definition.describe
      end
    end

    it 'emits import notes as comments' do
      expect(source).to include('# Import notes (review these):')
      expect(source).to include('#   - GET /users/{id} response "default":')
    end

    it 'rejects invalid class names' do
      expect { mod.to_ruby(doc, class_name: 'not-a-constant') }
        .to raise_error(mod::Error, /class_name must be a Ruby constant/)
    end
  end

  describe 'generated clients execute end-to-end' do
    let(:class_name) { "ImportSmoke#{object_id.abs}" }
    let(:source) do
      <<~RUBY
        class #{class_name}
          include Contractful::Contract
          base 'https://smoke.test'
          contract :list_users, 'GET /users' do
            param :page, Integer, default: 1, min: 1
            responds 200, 401, type: :array
          end
        end
      RUBY
    end

    before { TOPLEVEL_BINDING.eval(source) }

    it 'executes a mapped contract through WebMock' do
      stub_request(:get, 'https://smoke.test/users')
        .with(query: hash_including('page' => '1'))
        .to_return(body: '[{"id":1,"email":"a@b.c"}]',
                   headers: { 'Content-Type' => 'application/json' })

      response = Object.const_get(class_name).new.list_users
      expect(response.json).to eq([{ 'id' => 1, 'email' => 'a@b.c' }])
    end

    it 'rejects invalid params before any network traffic' do
      expect { Object.const_get(class_name).new.list_users(page: 0) }
        .to raise_error(Contractful::Contract::InvalidParam, /below minimum 1/)
      expect(a_request(:any, //)).not_to have_been_made
    end
  end

  describe 'generated form-body clients execute end-to-end' do
    let(:class_name) { "ImportFormSmoke#{object_id.abs}" }
    let(:doc) do
      {
        'openapi' => '3.0.3',
        'servers' => [{ 'url' => 'https://form.test' }],
        'paths' => {
          '/customers' => {
            'post' => {
              'operationId' => 'createCustomer',
              'requestBody' => { 'content' => { 'application/x-www-form-urlencoded' => { 'schema' => {
                'type' => 'object',
                'required' => ['email'],
                'properties' => {
                  'email' => { 'type' => 'string' },
                  'balance' => { 'type' => 'integer' }
                }
              } } } },
              'responses' => { '200' => { 'description' => 'ok' } }
            }
          }
        }
      }
    end

    before { TOPLEVEL_BINDING.eval(mod.to_ruby(doc, class_name: class_name)) }

    it 'sends the declared body fields as form parameters' do
      stub = stub_request(:post, 'https://form.test/customers')
             .with { |req| URI.decode_www_form(req.body).to_h == { 'email' => 'a@b.test', 'balance' => '5' } }

      Object.const_get(class_name).new.create_customer(email: 'a@b.test', balance: 5)
      expect(stub).to have_been_made
    end

    it 'rejects a missing required body field before any network traffic' do
      expect { Object.const_get(class_name).new.create_customer(balance: 5) }
        .to raise_error(Contractful::Contract::MissingParam, /email/)
      expect(a_request(:any, //)).not_to have_been_made
    end
  end
end
