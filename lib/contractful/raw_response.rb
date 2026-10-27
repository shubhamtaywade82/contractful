# frozen_string_literal: true

module Contractful
  # The response from Contractful on a raw request looks like a string, but is
  # actually one of these.  99% of the time you're making a rest call all you
  # care about is the body, but on the occasion you want to fetch the
  # headers you can:
  #
  #   Contractful.get('http://example.com').headers[:content_type]
  #
  # In addition, if you do not use the response as a string, you can access
  # a Tempfile object at res.file, which contains the path to the raw
  # downloaded request body.
  class RawResponse
    include AbstractResponse

    attr_reader :file, :request, :start_time, :end_time

    def inspect
      "<Contractful::RawResponse @code=#{code.inspect}, @file=#{file.inspect}, @request=#{request.inspect}>"
    end

    # @param [Tempfile] tempfile The temporary file containing the body
    # @param [Net::HTTPResponse] net_http_res
    # @param [Contractful::Request] request
    # @param [Time] start_time
    def initialize(tempfile, net_http_res, request, start_time = nil)
      @file = tempfile

      # reopen the tempfile so we can read it. Tempfile#open does NOT
      # preserve the binmode flag that fetch_body_to_tempfile set
      # (https://github.com/ruby/tempfile/blob/v0.3.0/lib/tempfile.rb).
      # On Windows the reopened file is text mode, which corrupts binary
      # bodies (image, gzip) via CRLF translation. Re-apply binmode
      # unconditionally; on Linux it is a no-op.
      @file.open
      @file.binmode

      response_set_vars(net_http_res, request, start_time)
    end

    def to_s
      body
    end

    def body
      @file.rewind
      @file.read
    end

    def size
      file.size
    end

    # Close and unlink the underlying tempfile. Long-lived processes
    # that issue many raw_response: true requests leak a file
    # descriptor per RawResponse until GC finalizes the Tempfile — call
    # this method when the body is no longer needed to release the FD
    # and the on-disk file immediately. After this call, #body and
    # #size raise (the file is gone); callers that want to keep the
    # body around should read it into a String before closing.
    def close
      return if @file.nil?

      @file.close(true) if @file.respond_to?(:close)
      @file = nil
    end
    alias close! close
  end
end
