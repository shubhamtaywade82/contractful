# frozen_string_literal: true

module RestClient
  # Windows-specific support code (root certificate store loading).
  module Windows
  end
end

require_relative 'windows/root_certs' if RestClient::Platform.windows?
