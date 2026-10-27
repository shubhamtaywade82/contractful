# frozen_string_literal: true

require 'tempfile'
require 'securerandom'
require 'stringio'

begin
  # Use mime/types/columnar if available, for reduced memory usage
  require 'mime/types/columnar'
rescue LoadError
  require 'mime/types'
end

module Contractful
  # Payload generation: turns user-provided bodies (strings, hashes,
  # ParamsArray, IO-like objects) into the object contractful transmits,
  # deciding urlencoded vs multipart vs streamed representation.
  module Payload
    extend self

    def generate(params)
      # nil is a valid input — it means "no body for this request" (the
      # common case for GET/DELETE/HEAD). Return nil so the request
      # layer skips the body entirely. Only non-nil unknown types raise
      # so callers find out immediately instead of silently sending an
      # empty body (e.g. `Contractful.post(url, 123)`).
      return nil if params.nil?

      if params.is_a?(Contractful::Payload::Base)
        # pass through Payload objects unchanged
        params
      elsif params.is_a?(String)
        Base.new(params)
      elsif params.is_a?(Hash)
        if params[:multipart] == true
          Multipart.new(params.reject { |key, _value| key.equal?(:multipart) })
        elsif has_file?(params)
          Multipart.new(params)
        else
          UrlEncoded.new(params)
        end
      elsif params.is_a?(ParamsArray)
        if _has_file?(params)
          Multipart.new(params)
        else
          UrlEncoded.new(params)
        end
      elsif params.respond_to?(:read)
        Streamed.new(params)
      else
        # Previously this branch was silent: any value that did not match
        # one of the cases above returned nil from generate, and the
        # request went out with NO body — the user's payload was lost
        # without any signal. Raise so callers find out immediately
        # (e.g. `Contractful.post(url, 123)` or `Contractful.post(url, [1,2,3])`).
        raise ArgumentError,
              "unsupported payload type #{params.class} " \
              '(expected String, Hash, ParamsArray, or IO-like ' \
              'responding to #read)'
      end
    end

    def has_file?(params)
      raise ArgumentError.new("Must pass Hash, not #{params.inspect}") unless params.is_a?(Hash)

      _has_file?(params)
    end

    def _has_file?(obj)
      case obj
      when Hash, ParamsArray
        obj.any? { |_, v| _has_file?(v) }
      when Array
        obj.any? { |v| _has_file?(v) }
      else
        obj.respond_to?(:path) && obj.respond_to?(:read)
      end
    end

    # Base payload wrapping a readable stream; also the concrete payload
    # for plain String bodies.
    class Base
      def initialize(params)
        build_stream(params)
      end

      def build_stream(params)
        @stream = StringIO.new(params)
        @stream.seek(0)
      end

      def read(*args)
        @stream.read(*args)
      end

      def to_s
        result = read
        rewind_stream
        result
      end

      def headers
        { 'Content-Length' => size.to_s }
      end

      def size
        @stream.size
      end

      alias length size

      def close
        @stream.close unless @stream.closed?
      end

      def closed?
        @stream.closed?
      end

      # Rewind the payload stream to the beginning so that the payload can be
      # retransmitted (for example when retrying a request after a network
      # failure). Returns true if the payload was rewound, or false if the
      # underlying stream does not support rewinding (e.g. a socket).
      #
      # @return [Boolean]
      #
      def rewind
        if @stream.respond_to?(:rewind)
          @stream.rewind
          true
        else
          false
        end
      rescue IOError, SystemCallError
        false
      end

      # Best-effort, silent variant of #rewind used when a non-rewindable
      # stream is not an error (for example reading the payload for logging).
      # Streams that cannot be rewound (sockets, pipes, and other non-seekable
      # objects) are left positioned wherever reading left them.
      def rewind_stream
        @stream.seek(0) if @stream.respond_to?(:seek)
      rescue IOError, SystemCallError
        nil
      end

      def to_s_inspect
        to_s.inspect
      end

      def short_inspect
        return "#{size} byte(s) length" if size && size > 500
        return 'streaming body'.inspect unless seekable?

        to_s_inspect
      end

      private

      # A stream that responds to #seek may still reject it (pipes and
      # sockets raise Errno::ESPIPE). Probing the current position avoids
      # consuming the stream merely to render it in a log line.
      def seekable?
        return false unless @stream.respond_to?(:seek)

        @stream.seek(0, IO::SEEK_CUR)
        true
      rescue IOError, SystemCallError
        false
      end
    end

    # Payload for IO-like (streaming) bodies; the stream is consumed
    # directly and may be non-seekable.
    class Streamed < Base
      def build_stream(params = nil)
        @stream = params
      end

      def size
        if @stream.respond_to?(:size)
          @stream.size
        elsif @stream.is_a?(IO)
          @stream.stat.size
        end
      end

      # TODO: (breaks compatibility): ought to use mime_for() to autodetect the
      # Content-Type for stream objects that have a filename.

      alias length size
    end

    # Payload for urlencoded form bodies (Hash/ParamsArray without files).
    class UrlEncoded < Base
      def build_stream(params = nil)
        @stream = StringIO.new(Utils.encode_query_string(params))
        @stream.seek(0)
      end

      def headers
        super.merge({ 'Content-Type' => 'application/x-www-form-urlencoded' })
      end
    end

    # Payload for multipart/form-data bodies (Hash/ParamsArray with file
    # fields, or explicit multipart: true).
    class Multipart < Base
      EOL = "\r\n"

      def build_stream(params)
        b = '--' + boundary

        @stream = Tempfile.new('contractful.multipart.')
        @stream.binmode
        @stream.write(b + EOL)

        x = case params
            when Hash, ParamsArray
              Utils.flatten_params(params)
            else
              params
            end

        last_index = x.length - 1
        x.each_with_index do |a, index|
          key, value = * a
          if value.respond_to?(:read) && value.respond_to?(:path)
            create_file_field(@stream, key, value)
          else
            create_regular_field(@stream, key, value)
          end
          @stream.write(EOL + b)
          @stream.write(EOL) unless last_index == index
        end
        @stream.write('--')
        @stream.write(EOL)
        @stream.seek(0)
      end

      def create_regular_field(stream, key, value)
        # Multipart field names go into a quoted-string in the
        # Content-Disposition header. A user-controlled key that contains
        # `"` or CRLF can break out of the quoted-string and inject a
        # synthetic part header (or another Content-Disposition with an
        # attacker-chosen filename). Escape `"` as `\"` and strip CR/LF
        # so the field name cannot escape its quoted-string slot.
        safe_key = escape_form_field_name(key)
        stream.write("Content-Disposition: form-data; name=\"#{safe_key}\"")
        stream.write(EOL)
        stream.write(EOL)
        stream.write(value)
      end

      def create_file_field(stream, key, value)
        # Same header-injection guard as create_regular_field, plus a
        # filename escape — File.basename(value.path) is user-controlled
        # (the path on disk of an uploaded file), and a filename containing
        # `"`, `\r` or `\n` can inject a synthetic filename/content-type
        # header into the multipart stream.
        safe_key = escape_form_field_name(key)
        stream.write('Content-Disposition: form-data;')
        stream.write(" name=\"#{safe_key}\";") unless key.nil? || key == ''
        filename = value.respond_to?(:original_filename) ? value.original_filename : File.basename(value.path)
        stream.write(" filename=\"#{escape_form_field_name(filename)}\"#{EOL}")
        content_type = value.respond_to?(:content_type) ? value.content_type : mime_for(value.path)
        stream.write("Content-Type: #{content_type}#{EOL}")
        stream.write(EOL)
        while (data = value.read(8124))
          stream.write(data)
        end
      ensure
        value.close if value.respond_to?(:close)
      end

      # Escape a multipart form field name (the value of `name=` or
      # `filename=` in Content-Disposition) so the user input cannot
      # break out of the quoted-string slot in the header.
      #
      # - Replace `"` with `\"` (RFC 2047 quoted-string escape).
      # - Strip CR and LF entirely. RFC 7578 forbids them inside the
      #   token, and any CRLF ends the current header line — which is
      #   the injection vector.
      # - Return nil for nil so the caller's `unless key.nil? || key == ''`
      #   branch above keeps working unchanged.
      def escape_form_field_name(name)
        return nil if name.nil?

        name.to_s.tr("\r\n", '').gsub('"', '\"')
      end

      def mime_for(path)
        # value.path can legitimately return nil (e.g. a Tempfile that
        # has been unlinked, or a StringIO subclass). MIME::Types.type_for
        # calls #split on its argument, so passing nil raises
        # NoMethodError and crashes the whole multipart build.
        return 'text/plain' if path.nil? || path.to_s.empty?

        mime = MIME::Types.type_for(path)
        mime.empty? ? 'text/plain' : mime[0].content_type
      end

      def boundary
        return @boundary if defined?(@boundary) && @boundary

        # Use the same algorithm used by WebKit: generate 16 random
        # alphanumeric characters, replacing `+` `/` with `A` `B` (included in
        # the list twice) to round out the set of 64.
        s = SecureRandom.base64(12)
        # Do not mutate the generated string in place: the return value of
        # SecureRandom.base64 may be frozen, and boundary can then never be
        # built at all.
        s = s.tr('+/', 'AB')

        @boundary = '----RubyFormBoundary' + s
      end

      # for Multipart do not escape the keys
      #
      # Ostensibly multipart keys MAY be percent encoded per RFC 7578, but in
      # practice no major browser that I'm aware of uses percent encoding.
      #
      # Further discussion of multipart encoding:
      # https://github.com/rest-client/rest-client/pull/403#issuecomment-156976930
      #
      def handle_key key
        key
      end

      def headers
        super.merge({ 'Content-Type' => "multipart/form-data; boundary=#{boundary}" })
      end

      def close
        @stream.close!
      end
    end
  end
end
