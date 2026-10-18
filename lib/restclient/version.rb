# frozen_string_literal: true

module RestClient
  VERSION_INFO = [2, 4, 0].freeze
  VERSION = VERSION_INFO.map(&:to_s).join('.').freeze

  def self.version
    VERSION
  end
end
