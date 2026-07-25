module Boukensha
  module Telemetry
    class NoopSpan
      def trace_id = nil
      def span_id = nil
      def propagation_carrier = {}
      def set_attributes(_attributes) = nil
      def add_event(_name, attributes: {}) = nil
      def record_exception(_exception) = nil
      def error!(_exception = nil) = nil
    end

    class Noop
      def in_span(_name, kind: :internal, attributes: {}, root: false)
        yield NoopSpan.new
      end

      def current_ids = {}
      def propagation_carrier = {}
      def capture_event(_event) = nil
      def force_flush(timeout: nil) = true
      def shutdown(timeout: nil) = true
    end
  end
end
