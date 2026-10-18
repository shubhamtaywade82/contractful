require_relative '_lib'

describe RestClient::Request, :include_helpers do

  context 'params for GET requests' do
    it "manage params for get requests" do
      stub_request(:get, 'http://some/resource?a=b&c=d').with(:headers => {'Accept'=>'*/*', 'Foo'=>'bar'}).to_return(:body => 'foo', :status => 200)
      expect(RestClient::Request.execute(:url => 'http://some/resource', :method => :get, :headers => {:foo => :bar, :params => {:a => :b, 'c' => 'd'}}).body).to eq 'foo'

      stub_request(:get, 'http://some/resource').with(:headers => {'Accept'=>'*/*', 'Foo'=>'bar'}).to_return(:body => 'foo', :status => 200)
      expect(RestClient::Request.execute(:url => 'http://some/resource', :method => :get, :headers => {:foo => :bar, :params => :a}).body).to eq 'foo'
    end

    it 'adds GET params when params are present in URL' do
      stub_request(:get, 'http://some/resource?a=b&c=d').with(:headers => {'Accept'=>'*/*', 'Foo'=>'bar'}).to_return(:body => 'foo', :status => 200)
      expect(RestClient::Request.execute(:url => 'http://some/resource?a=b', :method => :get, :headers => {:foo => :bar, :params => {:c => 'd'}}).body).to eq 'foo'
    end

    it 'encodes nested GET params' do
      stub_request(:get, 'http://some/resource?a[foo][]=1&a[foo][]=2&a[bar]&b=foo+bar&math=2+%2B+2+%3D%3D+4').with(:headers => {'Accept'=>'*/*',}).to_return(:body => 'foo', :status => 200)
      expect(RestClient::Request.execute(url: 'http://some/resource', method: :get, headers: {
        params: {
          a: {
            foo: [1,2],
            bar: nil,
          },
          b: 'foo bar',
          math: '2 + 2 == 4',
        }
      }).body).to eq 'foo'
    end

  end

  it "can use a block to process response" do
    response_value = nil
    block = proc do |http_response|
      response_value = http_response.body
    end
    stub_request(:get, 'http://some/resource?a=b&c=d').with(:headers => {'Accept'=>'*/*', 'Foo'=>'bar'}).to_return(:body => 'foo', :status => 200)
    RestClient::Request.execute(:url => 'http://some/resource', :method => :get, :headers => {:foo => :bar, :params => {:a => :b, 'c' => 'd'}}, :block_response => block)
    expect(response_value).to eq "foo"
  end

  it 'closes payload if not nil' do
    test_file = File.new(test_image_path)

    stub_request(:post, 'http://some/resource').with(:headers => {'Accept'=>'*/*'}).to_return(:body => 'foo', :status => 200)
    RestClient::Request.execute(:url => 'http://some/resource', :method => :post, :payload => {:file => test_file})

    expect(test_file.closed?).to be true
  end

  describe 'retries' do
    it 'does not retry transient network failures by default' do
      stub_request(:get, 'http://some/resource').to_timeout.then.to_return(:body => 'ok')
      expect {
        RestClient::Request.execute(:url => 'http://some/resource', :method => :get)
      }.to raise_error(RestClient::Exceptions::OpenTimeout)
      expect(a_request(:get, 'http://some/resource')).to have_been_made.once
    end

    it 'retries transient network failures and succeeds' do
      stub_request(:get, 'http://some/resource').to_timeout.then.to_return(:body => 'ok')
      expect(
        RestClient::Request.execute(:url => 'http://some/resource', :method => :get,
                                    :max_retries => 2, :retry_interval => 0)
      ).to eq 'ok'
      expect(a_request(:get, 'http://some/resource')).to have_been_made.twice
    end

    it 'raises the network error when retries are exhausted' do
      stub_request(:get, 'http://some/resource')
        .to_timeout.then.to_timeout.then.to_return(:body => 'ok')
      expect {
        RestClient::Request.execute(:url => 'http://some/resource', :method => :get,
                                    :max_retries => 1, :retry_interval => 0)
      }.to raise_error(RestClient::Exceptions::OpenTimeout)
      expect(a_request(:get, 'http://some/resource')).to have_been_made.twice
    end

    it 'retries when the server breaks the connection (EOFError)' do
      stub_request(:get, 'http://some/resource')
        .to_raise(EOFError).then.to_return(:body => 'ok')
      expect(
        RestClient::Request.execute(:url => 'http://some/resource', :method => :get,
                                    :max_retries => 1, :retry_interval => 0)
      ).to eq 'ok'
    end

    it 'retries on connection reset errors' do
      stub_request(:get, 'http://some/resource')
        .to_raise(Errno::ECONNRESET).then.to_return(:body => 'ok')
      expect(
        RestClient::Request.execute(:url => 'http://some/resource', :method => :get,
                                    :max_retries => 1, :retry_interval => 0)
      ).to eq 'ok'
    end

    it 'does not retry HTTP error responses' do
      stub = stub_request(:get, 'http://some/resource')
        .to_return(:status => 404).then.to_return(:body => 'should not happen')
      expect {
        RestClient::Request.execute(:url => 'http://some/resource', :method => :get,
                                    :max_retries => 3, :retry_interval => 0)
      }.to raise_error(RestClient::ResourceNotFound)
      expect(stub).to have_been_made.once
    end

    it 'sleeps with exponential backoff between retries' do
      stub_request(:get, 'http://some/resource')
        .to_timeout.then.to_timeout.then.to_return(:body => 'ok')

      delays = []
      allow_any_instance_of(RestClient::Request).to receive(:sleep_for_retry) do |_, secs|
        delays << secs
      end

      RestClient::Request.execute(:url => 'http://some/resource', :method => :get,
                                  :max_retries => 2, :retry_interval => 0.5)

      expect(delays).to eq([0.5, 1.0])
    end

    it 'rewinds string payloads so retried requests resend the same body' do
      stub_request(:post, 'http://some/resource').with(:body => 'payload-data')
        .to_raise(Errno::ECONNRESET).then.to_return(:body => 'ok')
      expect(
        RestClient::Request.execute(:url => 'http://some/resource', :method => :post,
                                    :payload => 'payload-data',
                                    :max_retries => 1, :retry_interval => 0)
      ).to eq 'ok'
      expect(a_request(:post, 'http://some/resource').with(:body => 'payload-data'))
        .to have_been_made.twice
    end

    it 'does not retry when the payload cannot be rewound' do
      stream = Object.new
      def stream.read(*args)
        'payload-data'
      end
      def stream.close
      end
      def stream.closed?
        false
      end

      stub = stub_request(:post, 'http://some/resource').to_raise(Errno::ECONNRESET)
      expect {
        RestClient::Request.execute(:url => 'http://some/resource', :method => :post,
                                    :payload => stream,
                                    :max_retries => 3, :retry_interval => 0)
      }.to raise_error(Errno::ECONNRESET)
      expect(stub).to have_been_made.once
    end

    it 'rejects invalid :max_retries values' do
      expect {
        RestClient::Request.new(:url => 'http://some/resource', :method => :get,
                                :max_retries => -1)
      }.to raise_error(ArgumentError, /:max_retries/)

      expect {
        RestClient::Request.new(:url => 'http://some/resource', :method => :get,
                                :max_retries => 'three')
      }.to raise_error(ArgumentError, /:max_retries/)
    end

    it 'rejects invalid :retry_interval values' do
      expect {
        RestClient::Request.new(:url => 'http://some/resource', :method => :get,
                                :retry_interval => -1)
      }.to raise_error(ArgumentError, /:retry_interval/)

      expect {
        RestClient::Request.new(:url => 'http://some/resource', :method => :get,
                                :retry_interval => 'forever')
      }.to raise_error(ArgumentError, /:retry_interval/)
    end
  end

end
