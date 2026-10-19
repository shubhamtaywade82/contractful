# frozen_string_literal: true

require 'webmock/rspec'
require 'contractful'

require_relative 'helpers'

# See http://rubydoc.info/gems/rspec-core/RSpec/Core/Configuration
RSpec.configure do |config|
  config.raise_errors_for_deprecations!

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = 'random'

  # always run with ruby warnings enabled
  # TODO: figure out why this is so obscenely noisy (rspec bug?)
  # config.warnings = true

  # add helpers
  config.include Helpers, :include_helpers

  config.mock_with :rspec do |mocks|
    mocks.yield_receiver_to_any_instance_implementation_blocks = true
  end

  # Contractful.log is process-global state, and several logging specs assign
  # it directly (`log = Contractful.log = []`). Under RSpec's random ordering
  # such an assignment would leak into unrelated examples that never enabled
  # logging: unit CI observed request2_spec's "does not retry when the
  # payload cannot be rewound" dying with NoMethodError on a leaked logger,
  # and resource specs receiving a leaked log array as their expected
  # `:log => nil` option. Reset it after every example so examples stay
  # order-independent regardless of which logging specs ran before them.
  config.after do
    Contractful.log = nil
  end
end

# always run with ruby warnings enabled (see above)
$VERBOSE = true
