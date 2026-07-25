require_relative "helper"
require "json"

class TestTelemetry < Minitest::Test
  class RecordingTelemetry
    Span = Struct.new(:name, :trace_id, :span_id, :parent_span_id, :attributes,
                      :events, :exception, :error, keyword_init: true) do
      def propagation_carrier
        { "traceparent" => "00-#{trace_id}-#{span_id}-01" }
      end

      def set_attributes(values) = attributes.merge!(values)
      def add_event(name, attributes: {}) = events << [name, attributes]
      def record_exception(value) = self.exception = value
      def error!(value = nil) = self.error = value
    end

    attr_reader :spans, :flushed

    def initialize
      @spans = []
      @stack_key = :"recording_telemetry_#{object_id}"
      @sequence = 0
    end

    def in_span(name, kind:, attributes:, root: false)
      parent = root ? nil : stack.last
      @sequence += 1
      trace_id = parent&.trace_id || format("%032x", @sequence)
      span = Span.new(name: name, trace_id: trace_id, span_id: format("%016x", @sequence),
                      parent_span_id: parent&.span_id, attributes: attributes.dup, events: [])
      @spans << span
      stack << span
      yield span
    ensure
      stack.pop
    end

    def current_ids
      span = stack.last
      span ? { trace_id: span.trace_id, span_id: span.span_id } : {}
    end

    def propagation_carrier = stack.last&.propagation_carrier || {}
    def capture_event(_event) = nil
    def force_flush(timeout: nil) = @flushed = timeout

    private

    def stack = (Thread.current[@stack_key] ||= [])
  end

  def test_nested_operations_correlate_jsonl_and_propagate_trace_context
    Dir.mktmpdir do |dir|
      telemetry = RecordingTelemetry.new
      path = File.join(dir, "session.jsonl")
      logger = Boukensha::Logger.new(session_id: "session-1", log: path, telemetry: telemetry)
      wire = nil

      logger.operation("outer", root: true) do
        logger.operation("inner") { wire = Boukensha::Operation.wire_meta }
      end
      logger.close

      outer, inner = telemetry.spans
      assert_equal outer.trace_id, inner.trace_id
      assert_equal outer.span_id, inner.parent_span_id
      assert_equal "session-1", inner.attributes["session.id"]
      assert_match(/\A00-[0-9a-f]{32}-[0-9a-f]{16}-01\z/, wire["traceparent"])

      events = File.readlines(path).map { |line| JSON.parse(line) }
      inner_events = events.select { |event| event["operation"] == "inner" }
      assert inner_events.all? { |event| event["trace_id"] == inner.trace_id }
      assert inner_events.all? { |event| event["span_id"] == inner.span_id }
      refute events.first.key?("trace_id"), "session-level records remain outside turn traces"
      assert_equal 5, telemetry.flushed
    end
  end

  def test_separate_root_turns_share_session_but_not_trace_ids
    Dir.mktmpdir do |dir|
      telemetry = RecordingTelemetry.new
      logger = Boukensha::Logger.new(session_id: "session-1",
                                     log: File.join(dir, "session.jsonl"), telemetry: telemetry)
      logger.operation("invoke_agent player", root: true) {}
      logger.operation("invoke_agent player", root: true) {}
      logger.close

      refute_equal telemetry.spans[0].trace_id, telemetry.spans[1].trace_id
      assert_equal ["session-1", "session-1"], telemetry.spans.map { |span| span.attributes["session.id"] }
      assert_nil telemetry.spans[1].parent_span_id
    end
  end

  def test_exception_is_recorded_and_reraised
    Dir.mktmpdir do |dir|
      telemetry = RecordingTelemetry.new
      logger = Boukensha::Logger.new(log: File.join(dir, "session.jsonl"), telemetry: telemetry)

      error = assert_raises(RuntimeError) { logger.operation("broken") { raise "boom" } }
      logger.close

      assert_same error, telemetry.spans.first.exception
      assert_same error, telemetry.spans.first.error
    end
  end
end
