require_relative "helper"

class TestOtelConfig < Minitest::Test
  include McpTestHelper

  OTEL_KEYS = %w[
    OTEL_SERVICE_NAME
    OTEL_EXPORTER_OTLP_ENDPOINT
    OTEL_EXPORTER_OTLP_PROTOCOL
    OTEL_TRACES_EXPORTER
  ].freeze

  def teardown
    @original_env&.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def test_applies_otel_env_from_settings
    preserve_otel_env
    OTEL_KEYS.each { |key| ENV.delete(key) }

    config_from(<<~YAML) do |config|
      observability:
        otel:
          enabled: true
          env:
            OTEL_SERVICE_NAME: boukensha
            OTEL_EXPORTER_OTLP_ENDPOINT: http://localhost:4318
            OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
            OTEL_TRACES_EXPORTER: otlp
    YAML
      assert config.otel_enabled?
      config.apply_otel_environment!
      assert_equal "boukensha", ENV["OTEL_SERVICE_NAME"]
      assert_equal "http://localhost:4318", ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]
      assert_equal "http/protobuf", ENV["OTEL_EXPORTER_OTLP_PROTOCOL"]
      assert_equal "otlp", ENV["OTEL_TRACES_EXPORTER"]
    end
  end

  def test_process_environment_overrides_yaml
    preserve_otel_env
    ENV["OTEL_SERVICE_NAME"] = "deployment-name"

    config_from(<<~YAML) do |config|
      observability:
        otel:
          enabled: true
          env:
            OTEL_SERVICE_NAME: yaml-name
    YAML
      config.apply_otel_environment!
      assert_equal "deployment-name", ENV["OTEL_SERVICE_NAME"]
    end
  end

  def test_rejects_non_otel_environment_keys
    config_from(<<~YAML) do |config|
      observability:
        otel:
          enabled: true
          env:
            PATH: /tmp/not-allowed
    YAML
      error = assert_raises(ArgumentError) { config.apply_otel_environment! }
      assert_match(/must start with OTEL_/, error.message)
    end
  end

  private

  def preserve_otel_env
    @original_env = OTEL_KEYS.to_h { |key| [key, ENV[key]] }
  end
end
