# frozen_string_literal: true

# Gem version constants for rest-client.
module RestClient
  VERSION_INFO = [2, 6, 0].freeze
  VERSION = VERSION_INFO.map(&:to_s).join('.').freeze

  def self.version
    VERSION
  end
end
