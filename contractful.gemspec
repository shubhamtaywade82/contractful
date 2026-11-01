# frozen_string_literal: true

require_relative 'lib/contractful/version'

Gem::Specification.new do |s|
  s.name = 'contractful'
  s.version = Contractful::VERSION
  s.authors = ['Shubham Taywade']
  s.email = ['shubhamtaywade82@gmail.com']
  s.description = 'A contract-first HTTP client for Ruby: closed request schemas that reject bad input before the network is touched, open response schemas that treat unknown fields as data, and contract-level auth, idempotency, pagination, rate limits and error classification. Clients are generated from contract definitions, with an OpenAPI import helper and a recorded-sequence test helper.'
  s.license = 'MIT'
  s.executables = ['contractful']
  s.extra_rdoc_files = ['README.md', 'history.md']

  shipped_directories = %w[lib bin].freeze
  shipped_root_files = %w[
    README.md history.md LICENSE AUTHORS SECURITY.md CODE_OF_CONDUCT.md API.md ARCHITECTURE.md
  ].freeze

  tracked = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true)
  end || []

  s.files = if tracked.empty?
              Dir['lib/**/*', 'bin/*', *shipped_root_files].select { |f| File.file?(f) }
            else
              tracked.select do |path|
                shipped_root_files.include?(path) ||
                  shipped_directories.any? { |dir| path.start_with?("#{dir}/") }
              end
            end

  s.homepage = 'https://github.com/shubhamtaywade82/contractful'
  s.summary = 'Contract-first HTTP client for Ruby with metaprogrammed clients, OpenAPI import and recorded-sequence test helpers.'
  s.metadata = {
    'allowed_push_host' => 'https://rubygems.org',
    'bug_tracker_uri' => 'https://github.com/shubhamtaywade82/contractful/issues',
    'changelog_uri' => 'https://github.com/shubhamtaywade82/contractful/blob/master/history.md',
    'documentation_uri' => 'https://rubydoc.info/gems/contractful/frames',
    'source_code_uri' => 'https://github.com/shubhamtaywade82/contractful',
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

  # Ruby 3.0 and 3.1 are end-of-life and the ubuntu-26.04 GitHub Actions
  # runner image no longer ships a build for them, so the CI matrix cannot
  # exercise those releases. The gem runtime still works on 3.0/3.1 in
  # principle, but the supported and tested floor is 3.2.
  s.required_ruby_version = '>= 3.2'
end
