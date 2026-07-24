ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

# Existing controller fixtures exercise the migration-era unprofiled runtime.
# Profile-specific tests may delete this cookie to assert the required 409.
class ActionDispatch::IntegrationTest
  setup do
    cookies["mud_monitor_profile"] = "legacy"
  end
end
