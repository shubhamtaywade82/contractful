# frozen_string_literal: true

module RestClient
  VERSION_INFO = [2, 2, 0].freeze
  VERSION = VERSION_INFO.map(&:to_s).join('.').freeze

  def self.version
    VERSION
  end
end
