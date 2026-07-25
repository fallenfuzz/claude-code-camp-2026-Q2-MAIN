require "opentelemetry-api"
require "opentelemetry-sdk"
require "opentelemetry/exporter/otlp"
require "json"

module Boukensha
  module Telemetry
    class OpenTelemetry
      KIND = {
        internal: ::OpenTelemetry::Trace::SpanKind::INTERNAL,
        client: ::OpenTelemetry::Trace::SpanKind::CLIENT,
        server: ::OpenTelemetry::Trace::SpanKind::SERVER,
        producer: ::OpenTelemetry::Trace::SpanKind::PRODUCER,
        consumer: ::OpenTelemetry::Trace::SpanKind::CONSUMER
      }.freeze

      class Span
        def initialize(span)
          @span = span
        end

        def trace_id
          @span.context.hex_trace_id if @span.context.valid?
        end

        def span_id
          @span.context.hex_span_id if @span.context.valid?
        end

        def set_attributes(attributes)
          attributes.each { |key, value| @span.set_attribute(key.to_s, value) unless value.nil? }
        end

        def add_event(name, attributes: {})
          @span.add_event(name.to_s, attributes: attributes.compact.transform_keys(&:to_s))
        end

        def record_exception(exception)
          @span.record_exception(exception)
        end

        def error!(exception = nil)
          @span.set_attribute("error.type", exception.class.name) if exception
          @span.status = ::OpenTelemetry::Trace::Status.error(exception&.message)
        end
      end

      def initialize(capture_content: false, content_max_bytes: 4096, warning_io: $stderr)
        @capture_content = capture_content
        @content_max_bytes = content_max_bytes
        @warning_io = warning_io
        configure_once
        @tracer = ::OpenTelemetry.tracer_provider.tracer("boukensha", Boukensha::VERSION)
      end

      def in_span(name, kind: :internal, attributes: {}, root: false)
        parent = root ? ::OpenTelemetry::Context.empty : ::OpenTelemetry::Context.current
        span = @tracer.start_span(name.to_s, with_parent: parent, kind: KIND.fetch(kind),
                                  attributes: clean(attributes))
        context = ::OpenTelemetry::Trace.context_with_span(span, parent_context: parent)
        ::OpenTelemetry::Context.with_current(context) { yield Span.new(span) }
      ensure
        span&.finish
      end

      def current_ids
        context = ::OpenTelemetry::Trace.current_span.context
        return {} unless context.valid?

        { trace_id: context.hex_trace_id, span_id: context.hex_span_id }
      end

      def propagation_carrier
        carrier = {}
        ::OpenTelemetry.propagation.inject(carrier)
        carrier
      end

      def capture_event(event)
        phase = (event[:phase] || event["phase"]).to_s
        span = ::OpenTelemetry::Trace.current_span
        return unless span.context.valid?

        if phase == "reasoning"
          span.add_event("boukensha.reasoning", attributes: { "boukensha.reasoning.present" => true })
          return
        end
        return unless @capture_content
        return unless %w[prompt request response tool_call tool_result injected_context context_transform].include?(phase)

        json = JSON.generate(redact(event))
        truncated = json.bytesize > @content_max_bytes
        json = json.byteslice(0, @content_max_bytes).scrub if truncated
        span.add_event("boukensha.#{phase}", attributes: {
          "boukensha.content" => json,
          "boukensha.content.truncated" => truncated
        })
      rescue StandardError => e
        warn_once(e)
      end

      def force_flush(timeout: nil)
        ::OpenTelemetry.tracer_provider.force_flush(timeout: timeout)
      rescue StandardError => e
        warn_once(e)
        false
      end

      def shutdown(timeout: nil)
        ::OpenTelemetry.tracer_provider.shutdown(timeout: timeout)
      rescue StandardError => e
        warn_once(e)
        false
      end

      private

      def configure_once
        return if self.class.instance_variable_get(:@configured)

        ::OpenTelemetry::SDK.configure do |config|
          config.service_name = ENV.fetch("OTEL_SERVICE_NAME", "boukensha")
        end
        self.class.instance_variable_set(:@configured, true)
      end

      def clean(attributes)
        attributes.compact.transform_keys(&:to_s).select do |_key, value|
          value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false ||
            (value.is_a?(Array) && value.all? { |item| item.is_a?(String) || item.is_a?(Numeric) })
        end
      end

      SECRET_KEY = /(authorization|api[_-]?key|token|password|secret|credential)/i
      SECRET_VALUE = /(Bearer\s+)[^\s]+|\bsk-[A-Za-z0-9_-]{8,}/i

      def redact(value, key = nil)
        return "[REDACTED]" if key&.match?(SECRET_KEY)

        case value
        when Hash
          value.each_with_object({}) { |(child_key, child), out| out[child_key] = redact(child, child_key.to_s) }
        when Array
          value.map { |child| redact(child) }
        when String
          value.gsub(SECRET_VALUE) { |match| match.start_with?("Bearer ") ? "Bearer [REDACTED]" : "[REDACTED]" }
        else
          value
        end
      end

      def warn_once(error)
        return if @warned

        @warned = true
        @warning_io.puts("boukensha: OpenTelemetry export failed: #{error.class}: #{error.message}")
      end
    end
  end
end
