# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe 'RestClient::Exceptions error classification' do
  describe 'RETRIABLE_STATUSES' do
    it 'classifies transient statuses as retryable' do
      expect(RestClient::Exceptions::RETRIABLE_STATUSES).to include(408, 425, 429, 500, 502, 503, 504)
    end

    it 'excludes terminal statuses' do
      [400, 401, 403, 404, 409, 422, 501].each do |status|
        expect(RestClient::Exceptions::RETRIABLE_STATUSES).not_to include(status)
      end
    end
  end

  describe 'Exception#retryable?' do
    it 'defaults to terminal (false) for exceptions without a response' do
      expect(RestClient::Exception.new.retryable?).to be false
      expect(RestClient::SSLCertificateNotVerified.new.retryable?).to be false
    end

    it 'classifies response-bearing exceptions by HTTP status' do
      response = double('response', code: 429)
      expect(RestClient::TooManyRequests.new(response).retryable?).to be true

      response = double('response', code: 404)
      expect(RestClient::NotFound.new(response).retryable?).to be false

      response = double('response', code: 503)
      expect(RestClient::ServiceUnavailable.new(response).retryable?).to be true
    end

    it 'marks network timeouts retryable' do
      expect(RestClient::Exceptions::OpenTimeout.new.retryable?).to be true
      expect(RestClient::Exceptions::ReadTimeout.new.retryable?).to be true
      expect(RestClient::ServerBrokeConnection.new.retryable?).to be true
    end
  end

  describe '.retryable?' do
    it 'classifies Integer statuses' do
      expect(RestClient::Exceptions.retryable?(429)).to be true
      expect(RestClient::Exceptions.retryable?(503)).to be true
      expect(RestClient::Exceptions.retryable?(404)).to be false
      expect(RestClient::Exceptions.retryable?(401)).to be false
    end

    it 'classifies RestClient exceptions' do
      expect(RestClient::Exceptions.retryable?(RestClient::Exceptions::OpenTimeout.new)).to be true
      expect(RestClient::Exceptions.retryable?(RestClient::NotFound.new)).to be false
      expect(RestClient::Exceptions.retryable?(RestClient::ServerBrokeConnection.new)).to be true
    end

    it 'classifies plain network errors' do
      expect(RestClient::Exceptions.retryable?(SocketError.new('boom'))).to be true
      expect(RestClient::Exceptions.retryable?(EOFError.new)).to be true
      expect(RestClient::Exceptions.retryable?(Errno::ECONNRESET.new)).to be true
      expect(RestClient::Exceptions.retryable?(Net::OpenTimeout.new)).to be true
    end

    it 'classifies anything else as terminal' do
      expect(RestClient::Exceptions.retryable?(ArgumentError.new('bad arg'))).to be false
      expect(RestClient::Exceptions.retryable?('weird')).to be false
      expect(RestClient::Exceptions.retryable?(nil)).to be false
    end
  end
end
