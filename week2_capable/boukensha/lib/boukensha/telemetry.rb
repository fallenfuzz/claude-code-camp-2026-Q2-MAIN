require_relative "telemetry/noop"

module Boukensha
  module Telemetry
    SEMANTIC_CONVENTIONS = "OpenTelemetry GenAI semantic conventions 1.37.0".freeze

    class << self
      def build(config:, warning_io: $stderr)
        return Noop.new unless config.otel_enabled?

        config.apply_otel_environment!
        capture_content = config.otel_capture_content?
        content_max_bytes = config.otel_content_max_bytes
        begin
          require_relative "telemetry/open_telemetry"
          OpenTelemetry.new(
            capture_content: capture_content,
            content_max_bytes: content_max_bytes,
            warning_io: warning_io
          )
        rescue LoadError, StandardError => e
          Boukensha.error_log.record(e, component: "otel", boundary: "build")
          warning_io.puts("boukensha: OpenTelemetry disabled: #{e.class}: #{e.message}")
          Noop.new
        end
      end
    end
  end
end
