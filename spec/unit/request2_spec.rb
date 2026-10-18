# frozen_string_literal: true

require_relative '_lib'

describe RestClient::Request, :include_helpers do
  context 'params for GET requests' do
    it 'manage params for get requests' do
      stub_request(:get, 'http://some/resource?a=b&c=d').with(headers: { 'Accept' => '*/*', 'Foo' => 'bar' }).to_return(body: 'foo', status: 200)
      expect(RestClient::Request.execute(url: 'http://some/resource', method: :get, headers: { foo: :bar, params: { :a => :b, 'c' => 'd' } }).body).to eq 'foo'

      stub_request(:get, 'http://some/resource').with(headers: { 'Accept' => '*/*', 'Foo' => 'bar' }).to_return(body: 'foo', status: 200)
      expect(RestClient::Request.execute(url: 'http://some/resource', method: :get, headers: { foo: :bar, params: :a }).body).to eq 'foo'
    end

    it 'adds GET params when params are present in URL' do
      stub_request(:get, 'http://some/resource?a=b&c=d').with(headers: { 'Accept' => '*/*', 'Foo' => 'bar' }).to_return(body: 'foo', status: 200)
      expect(RestClient::Request.execute(url: 'http://some/resource?a=b', method: :get, headers: { foo: :bar, params: { c: 'd' } }).body).to eq 'foo'
    end

    it 'encodes nested GET params' do
      stub_request(:get, 'http://some/resource?a[foo][]=1&a[foo][]=2&a[bar]&b=foo+bar&math=2+%2B+2+%3D%3D+4').with(headers: { 'Accept' => '*/*' }).to_return(body: 'foo', status: 200)
      expect(RestClient::Request.execute(url: 'http://some/resource', method: :get, headers: {
                                           params: {
                                             a: {
                                               foo: [1, 2],
                                               bar: nil
                                             },
                                             b: 'foo bar',
                                             math: '2 + 2 == 4'
                                           }
                                         }).body).to eq 'foo'
    end
  end

  it 'can use a block to process response' do
    response_value = nil
    block = proc do |http_response|
      response_value = http_response.body
    end
    stub_request(:get, 'http://some/resource?a=b&c=d').with(headers: { 'Accept' => '*/*', 'Foo' => 'bar' }).to_return(body: 'foo', status: 200)
    RestClient::Request.execute(url: 'http://some/resource', method: :get, headers: { foo: :bar, params: { :a => :b, 'c' => 'd' } }, block_response: block)
    expect(response_value).to eq 'foo'
  end

  it 'closes payload if not nil' do
    test_file = File.new(test_image_path)

    stub_request(:post, 'http://some/resource').with(headers: { 'Accept' => '*/*' }).to_return(body: 'foo', status: 200)
    RestClient::Request.execute(url: 'http://some/resource', method: :post, payload: { file: test_file })

    expect(test_file.closed?).to be true
  end

  describe 'retries' do
    it 'does not retry transient network failures by default' do
      stub_request(:get, 'http://some/resource').to_timeout.then.to_return(body: 'ok')
      expect do
        RestClient::Request.execute(url: 'http://some/resource', method: :get)
      end.to raise_error(RestClient::Exceptions::OpenTimeout)
      expect(a_request(:get, 'http://some/resource')).to have_been_made.once
    end

    it 'retries transient network failures and succeeds' do
      stub_request(:get, 'http://some/resource').to_timeout.then.to_return(body: 'ok')
      expect(
        RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                    max_retries: 2, retry_interval: 0)
      ).to eq 'ok'
      expect(a_request(:get, 'http://some/resource')).to have_been_made.twice
    end

    it 'raises the network error when retries are exhausted' do
      stub_request(:get, 'http://some/resource')
        .to_timeout.then.to_timeout.then.to_return(body: 'ok')
      expect do
        RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                    max_retries: 1, retry_interval: 0)
      end.to raise_error(RestClient::Exceptions::OpenTimeout)
      expect(a_request(:get, 'http://some/resource')).to have_been_made.twice
    end

    it 'retries when the server breaks the connection (EOFError)' do
      stub_request(:get, 'http://some/resource')
        .to_raise(EOFError).then.to_return(body: 'ok')
      expect(
        RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                    max_retries: 1, retry_interval: 0)
      ).to eq 'ok'
    end

    it 'retries on connection reset errors' do
      stub_request(:get, 'http://some/resource')
        .to_raise(Errno::ECONNRESET).then.to_return(body: 'ok')
      expect(
        RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                    max_retries: 1, retry_interval: 0)
      ).to eq 'ok'
    end

    it 'does not retry HTTP error responses' do
      stub = stub_request(:get, 'http://some/resource')
             .to_return(status: 404).then.to_return(body: 'should not happen')
      expect do
        RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                    max_retries: 3, retry_interval: 0)
      end.to raise_error(RestClient::ResourceNotFound)
      expect(stub).to have_been_made.once
    end

    it 'sleeps with exponential backoff between retries' do
      stub_request(:get, 'http://some/resource')
        .to_timeout.then.to_timeout.then.to_return(body: 'ok')

      delays = []
      allow_any_instance_of(RestClient::Request).to receive(:sleep_for_retry) do |_, secs|
        delays << secs
      end

      RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                  max_retries: 2, retry_interval: 0.5)

      expect(delays).to eq([0.5, 1.0])
    end

    it 'rewinds string payloads so retried requests resend the same body' do
      stub_request(:post, 'http://some/resource').with(body: 'payload-data')
                                                 .to_raise(Errno::ECONNRESET).then.to_return(body: 'ok')
      expect(
        RestClient::Request.execute(url: 'http://some/resource', method: :post,
                                    payload: 'payload-data',
                                    max_retries: 1, retry_interval: 0)
      ).to eq 'ok'
      expect(a_request(:post, 'http://some/resource').with(body: 'payload-data'))
        .to have_been_made.twice
    end

    it 'does not retry when the payload cannot be rewound' do
      stream = Object.new
      def stream.read(*_args)
        'payload-data'
      end

      def stream.close; end

      def stream.closed?
        false
      end

      stub = stub_request(:post, 'http://some/resource').to_raise(Errno::ECONNRESET)
      expect do
        RestClient::Request.execute(url: 'http://some/resource', method: :post,
                                    payload: stream,
                                    max_retries: 3, retry_interval: 0)
      end.to raise_error(Errno::ECONNRESET)
      expect(stub).to have_been_made.once
    end

    it 'rejects invalid :max_retries values' do
      expect do
        RestClient::Request.new(url: 'http://some/resource', method: :get,
                                max_retries: -1)
      end.to raise_error(ArgumentError, /:max_retries/)

      expect do
        RestClient::Request.new(url: 'http://some/resource', method: :get,
                                max_retries: 'three')
      end.to raise_error(ArgumentError, /:max_retries/)
    end

    it 'rejects invalid :retry_interval values' do
      expect do
        RestClient::Request.new(url: 'http://some/resource', method: :get,
                                retry_interval: -1)
      end.to raise_error(ArgumentError, /:retry_interval/)

      expect do
        RestClient::Request.new(url: 'http://some/resource', method: :get,
                                retry_interval: 'forever')
      end.to raise_error(ArgumentError, /:retry_interval/)
    end

    it 'rejects invalid :max_retry_after values' do
      expect do
        RestClient::Request.new(url: 'http://some/resource', method: :get,
                                max_retry_after: -5)
      end.to raise_error(ArgumentError, /:max_retry_after/)
    end
  end

  describe 'retryable-status retries with Retry-After' do
    before do
      allow_any_instance_of(RestClient::Request).to receive(:sleep_for_retry) { |_, secs|
        @slept << secs
      }
    end

    before { @slept = [] }

    it 'retries a 503 and succeeds' do
      stub_request(:get, 'http://some/resource')
        .to_return(status: 503, headers: { 'Retry-After' => '1' })
        .then.to_return(body: 'ok')

      expect(
        RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                    max_retries: 2, retry_interval: 0.5)
      ).to eq 'ok'
      expect(a_request(:get, 'http://some/resource')).to have_been_made.twice
    end

    it 'honors Retry-After delta-seconds over the exponential backoff' do
      stub_request(:get, 'http://some/resource')
        .to_return(status: 429, headers: { 'Retry-After' => '7' })
        .then.to_return(body: 'ok')

      RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                  max_retries: 1, retry_interval: 0.5)
      expect(@slept).to eq([7.0])
    end

    it 'falls back to exponential backoff when Retry-After exceeds :max_retry_after' do
      stub_request(:get, 'http://some/resource')
        .to_return(status: 503, headers: { 'Retry-After' => '3600' })
        .then.to_return(body: 'ok')

      RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                  max_retries: 1, retry_interval: 0.25)
      expect(@slept).to eq([0.25])
    end

    it 'parses HTTP-date Retry-After values' do
      stub_request(:get, 'http://some/resource')
        .to_return(status: 503,
                   headers: { 'Retry-After' => Time.at(Time.now.to_i + 3).httpdate })
        .then.to_return(body: 'ok')

      RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                  max_retries: 1, retry_interval: 0.25)
      expect(@slept.first).to be_between(0.5, 3.0)
    end

    it 'retries 429 inside the block path (error-status suppression)' do
      stub_request(:get, 'http://some/resource')
        .to_return(status: 429, headers: { 'Retry-After' => '0' })
        .then.to_return(status: 200, body: 'ok')

      result = RestClient::Request.execute(url: 'http://some/resource',
                                           method: :get,
                                           max_retries: 1,
                                           retry_interval: 0) do |response|
        response
      end
      expect(result.code).to eq 200
      expect(a_request(:get, 'http://some/resource')).to have_been_made.twice
    end

    it 'does not retry terminal statuses like 404' do
      stub = stub_request(:get, 'http://some/resource')
             .to_return(status: 404).then.to_return(body: 'should not happen')
      expect do
        RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                    max_retries: 3, retry_interval: 0)
      end.to raise_error(RestClient::NotFound)
      expect(stub).to have_been_made.once
    end

    it 'does not retry retryable statuses when :retry_after is disabled' do
      stub = stub_request(:get, 'http://some/resource')
             .to_return(status: 503).then.to_return(body: 'should not happen')
      expect do
        RestClient::Request.execute(url: 'http://some/resource', method: :get,
                                    max_retries: 3, retry_interval: 0,
                                    retry_after: false)
      end.to raise_error(RestClient::ServiceUnavailable)
      expect(stub).to have_been_made.once
    end
  end

  describe 'persistent connections' do
    before do
      RestClient.connection_pool = RestClient::ConnectionPool.new(max_idle: 4)
    end

    after do
      RestClient.connection_pool.clear!
      RestClient.connection_pool = nil
    end

    it 'reuses the pooled connection for sequential requests' do
      stub_request(:get, 'http://some/resource')
        .to_return(body: 'first').then.to_return(body: 'second')

      expect(
        RestClient::Request.execute(url: 'http://some/resource',
                                    method: :get, persistent: true)
      ).to eq 'first'
      expect(
        RestClient::Request.execute(url: 'http://some/resource',
                                    method: :get, persistent: true)
      ).to eq 'second'

      # A single connection was retained and reused for both requests.
      expect(RestClient.connection_pool.stats).to eq(idle: 1, checked_out: 0)
    end

    it 'does not pool connections unless :persistent is requested' do
      stub_request(:get, 'http://some/resource')
        .to_return(body: 'ok').then.to_return(body: 'ok')

      RestClient::Request.execute(url: 'http://some/resource', method: :get)
      RestClient::Request.execute(url: 'http://some/resource', method: :get)

      expect(RestClient.connection_pool.stats).to eq(idle: 0, checked_out: 0)
    end

    it 'discards the connection after a network failure' do
      stub_request(:get, 'http://some/resource').to_timeout

      expect do
        RestClient::Request.execute(url: 'http://some/resource',
                                    method: :get, persistent: true)
      end.to raise_error(RestClient::Exceptions::OpenTimeout)

      expect(RestClient.connection_pool.stats).to eq(idle: 0, checked_out: 0)
    end

    it 'keeps the connection pooled when the response is an HTTP error' do
      stub_request(:get, 'http://some/resource').to_return(status: 404)

      expect do
        RestClient::Request.execute(url: 'http://some/resource',
                                    method: :get, persistent: true)
      end.to raise_error(RestClient::ResourceNotFound)

      expect(RestClient.connection_pool.stats).to eq(idle: 1, checked_out: 0)
    end
  end
end
