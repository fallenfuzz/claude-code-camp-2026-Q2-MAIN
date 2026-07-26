require_relative "helper"
require "json"

# The `chat` span widened to the whole exchange — injected context, prompt,
# request, plan and response all fall inside its brackets and carry its
# operation_id, so the transcript's duration and MUD/db rollup for that
# exchange come off the span, not off `dt_ms`.
class TestChatSpan < Minitest::Test
  # Stands in for PromptBuilder + Client together, exactly as
  # TestHooksSeam::FakePipe does — the agent only ever asks the builder for a
  # payload and the client for a response.
  class FakePipe
    FakeBackend = Struct.new(:model)

    def initialize(context, *responses)
      @context   = context
      @responses = responses
    end

    def backend = FakeBackend.new("fake-model")
    def to_api_payload(**_) = {}
    def parse_response(r) = { stop_reason: r["stop_reason"], content: r["content"] }
    def call(**_) = @responses.shift
  end

  def tool_use_response(name)
    { "stop_reason" => "tool_use", "usage" => { "input_tokens" => 10, "output_tokens" => 5 },
      "content" => [ { "type" => "text", "text" => "Let me check that." },
                     { "type" => "tool_use", "id" => "u1", "name" => name, "input" => {} } ] }
  end

  def text_response(text)
    { "stop_reason" => "end_turn", "usage" => { "input_tokens" => 20, "output_tokens" => 8 },
      "content" => [ { "type" => "text", "text" => text } ] }
  end

  def build(responses:, turn: 1)
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    reg.tool("probe", description: "d") { |**_| "RAW MUD TEXT" }
    pipe = FakePipe.new(ctx, *responses)
    path = File.join(Dir.mktmpdir, "s.jsonl")
    logger = Boukensha::Logger.new(log: path)
    agent = Boukensha::Agent.new(context: ctx, registry: reg, builder: pipe, client: pipe,
                                 logger: logger, turn: turn)
    [ agent, logger ]
  end

  def read_events(logger)
    logger.close
    File.readlines(logger.path).map { |l| JSON.parse(l) }
  end

  # The window a reader would open on the one span they most want to read: it
  # used to bracket only `@client.call`, which is adjacent to nothing.
  def test_the_chat_span_owns_its_injected_context_prompt_request_plan_and_response
    agent, logger = build(responses: [ tool_use_response("probe"), text_response("done") ])
    agent.run
    events = read_events(logger)

    chat_start = events.find { |e| e["phase"] == "operation_start" && e["operation"].to_s.start_with?("chat ") }
    chat_end   = events.find { |e| e["phase"] == "operation_end" && e["operation_id"] == chat_start["operation_id"] }
    refute_nil chat_start
    refute_nil chat_end

    start_i = events.index(chat_start)
    end_i   = events.index(chat_end)
    inside  = events[(start_i + 1)...end_i]

    assert_includes inside.map { |e| e["phase"] }, "prompt"
    assert_includes inside.map { |e| e["phase"] }, "request"
    assert_includes inside.map { |e| e["phase"] }, "plan"
    assert_includes inside.map { |e| e["phase"] }, "response"

    # And every one of them is stamped with the span's own id — not merely
    # positioned between its brackets, but recorded as belonging to it.
    inside.each do |event|
      next unless %w[prompt request plan response].include?(event["phase"])

      assert_equal chat_start["operation_id"], event["operation_id"],
                   "#{event["phase"]} should carry the chat span's operation_id"
    end
  end

  # work_attribution.md §2 must not regress: widening the span to the whole
  # exchange must not quietly re-include our own request/response
  # serialization in what "model time" means. `boukensha.wire_ms` is the
  # narrow number; the span's own duration is the wide one, and the wide
  # number can never be smaller than the narrow one it contains.
  def test_wire_ms_is_published_and_no_larger_than_the_span_duration
    agent, logger = build(responses: [ text_response("done") ])
    agent.run
    events = read_events(logger)

    chat_end = events.find { |e| e["phase"] == "operation_end" && e["operation"].to_s.start_with?("chat ") }
    refute_nil chat_end["boukensha.wire_ms"]
    refute_nil chat_end["gen_ai.client.operation.duration"]
    assert_operator chat_end["boukensha.wire_ms"], :<=, chat_end["duration_ms"]
  end

  # Every content phase this exchange produces carries operation_id — the
  # regression the plan names outright (injected_context/prompt/request/plan
  # /response used to be written with none at all).
  def test_every_content_phase_of_the_turn_carries_an_operation_id
    hooks = Class.new(Boukensha::Hooks) do
      def before_model(context:) = context.state_block = "[here] Market Square"
    end.new
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    pipe = FakePipe.new(ctx, text_response("done"))
    path = File.join(Dir.mktmpdir, "s.jsonl")
    logger = Boukensha::Logger.new(log: path)
    agent = Boukensha::Agent.new(context: ctx, registry: reg, builder: pipe, client: pipe,
                                 logger: logger, hooks: hooks)
    agent.run
    events = read_events(logger)

    content_phases = %w[injected_context prompt request plan response iteration]
    events.select { |e| content_phases.include?(e["phase"]) }.each do |event|
      refute_nil event["operation_id"], "#{event["phase"]} should carry an operation_id"
    end
  end
end
