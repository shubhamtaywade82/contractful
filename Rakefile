# load `rake build/install/release tasks'
require 'bundler/setup'
require_relative 'lib/contractful/version'

namespace :ruby do
  Bundler::GemHelper.install_tasks(name: 'contractful')
end

require 'rspec/core/rake_task'

desc 'Run all specs'
RSpec::Core::RakeTask.new('spec')

desc 'Run unit specs'
RSpec::Core::RakeTask.new('spec:unit') do |t|
  # ** so the nested spec/unit/contract/ suite runs too
  t.pattern = 'spec/unit/**/*_spec.rb'
end

desc 'Run integration specs'
RSpec::Core::RakeTask.new('spec:integration') do |t|
  t.pattern = 'spec/integration/*_spec.rb'
end

desc 'Run RuboCop static analysis (see .rubocop.yml for the baseline strategy)'
require 'rubocop/rake_task'
RuboCop::RakeTask.new('rubocop')

desc 'Print specdocs'
RSpec::Core::RakeTask.new(:doc) do |t|
  t.rspec_opts = ['--format', 'specdoc', '--dry-run']
  t.pattern = 'spec/**/*_spec.rb'
end

task default: :spec

desc 'Regenerate authors file'
task :authors do
  Dir.chdir(File.dirname(__FILE__)) do
    File.write('AUTHORS', <<~EOM)
      The Ruby REST Client would not be what it is today without the help of
      the following kind souls:
      
    EOM

    sh 'git shortlog -s | cut -f 2 >> AUTHORS'
  end
end

############################

WINDOWS_PLATFORMS = %w[x86-mingw32 x64-mingw32 x64-mingw-ucrt]

namespace :all do
  desc "Build contractful #{Contractful::VERSION} for all platforms"
  task build: ['ruby:build'] + 
              WINDOWS_PLATFORMS.map { |p| "windows:#{p}:build" }

  desc "Create tag v#{Contractful::VERSION} and for all platforms build and " \
       "push contractful #{Contractful::VERSION} to Rubygems"
  task release: ['build', 'ruby:release'] + 
                WINDOWS_PLATFORMS.map { |p| "windows:#{p}:push" }
end

namespace :windows do
  spec_path = File.join(File.dirname(__FILE__), 'contractful.windows.gemspec')

  WINDOWS_PLATFORMS.each do |platform|
    namespace platform do
      gem_filename = "contractful-#{Contractful::VERSION}-#{platform}.gem"
      base = File.dirname(__FILE__)
      pkg_dir = File.join(base, 'pkg')
      gem_file_path = File.join(pkg_dir, gem_filename)

      desc "Build #{gem_filename} into the pkg directory"
      task 'build' do
        orig_platform = ENV.fetch('BUILD_PLATFORM', nil)
        begin
          ENV['BUILD_PLATFORM'] = platform

          sh("gem build -V #{spec_path}") do |ok, res|
            if ok
              FileUtils.mkdir_p(pkg_dir)
              FileUtils.mv(File.join(base, gem_filename), pkg_dir)
              Bundler.ui.confirm("contractful #{Contractful::VERSION} " \
                                 "built to pkg/#{gem_filename}")
            else
              abort "Command `gem build` failed: #{res}"
            end
          end
        ensure
          ENV['BUILD_PLATFORM'] = orig_platform
        end
      end

      desc "Push #{gem_filename} to Rubygems"
      task 'push' do
        sh("gem push #{gem_file_path}")
      end
    end
  end
end

############################

require 'rdoc/task'

Rake::RDocTask.new do |t|
  t.rdoc_dir = 'rdoc'
  t.title    = 'contractful, fetch RESTful resources effortlessly'
  t.options << '--line-numbers' << '--inline-source' << '-A cattr_accessor=object'
  t.options << '--charset' << 'utf-8'
  t.rdoc_files.include('README.md')
  t.rdoc_files.include('lib/*.rb')
end
