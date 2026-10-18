# frozen_string_literal: true

require_relative 'lib/restclient/version'

Gem::Specification.new do |s|
  s.name = 'rest-client'
  s.version = RestClient::VERSION
  s.authors = ['REST Client Team']
  s.description = 'A simple HTTP and REST client for Ruby, inspired by the Sinatra microframework style of specifying actions: get, put, post, delete.'
  s.license = 'MIT'
  s.email = 'discuss@rest-client.groups.io'
  s.executables = ['restclient']
  s.extra_rdoc_files = ['README.md', 'history.md']
  s.files = `git ls-files -z`.split("\0")
  s.homepage = 'https://github.com/shubhamtaywade82/rest-client'
  s.summary = 'Simple HTTP and REST client for Ruby, inspired by microframework syntax for specifying actions.'
  s.metadata = {
    'bug_tracker_uri' => 'https://github.com/shubhamtaywade82/rest-client/issues',
    'changelog_uri' => 'https://github.com/shubhamtaywade82/rest-client/blob/master/history.md',
    'homepage_uri' => 'https://github.com/shubhamtaywade82/rest-client',
    'rubygems_mfa_required' => 'true'
  }

  s.add_development_dependency('webmock', '>= 3.19', '< 5')
  s.add_development_dependency('rspec', '~> 3.13')
  s.add_development_dependency('pry', '~> 0.14')
  s.add_development_dependency('rdoc', '>= 6.0')

  s.add_dependency('http-accept', '>= 1.7.0', '< 2.0')
  s.add_dependency('http-cookie', '>= 1.0.2', '< 2.0')
  s.add_dependency('mime-types', '>= 1.16', '< 4.0')
  s.add_dependency('netrc', '~> 0.8')

  s.required_ruby_version = '>= 3.0'
end
