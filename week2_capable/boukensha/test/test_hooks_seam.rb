require_relative "helper"

# The framework half: Boukensha::Hooks and its five call sites in Agent.
#
# This is the entire framework change the memory work required. Everything else
# is a Hooks subclass living under mud/, which is what keeps boukensha's claim
# to be a MUD-agnostic MCP host honest.
class TestHooksSeam < Minitest::Test
  # Records the order the seam fires in, and can replace a tool result.
  class RecordingHooks < Boukensha::Hooks
    attr_reader :events

    def initialize(replacement: nil)
      @events = []
      @replacement = replacement
    end

    def before_turn(context:)  = @events << :before_turn
    def before_model(context:) = @events << :before_model

    def before_tools(calls:, context:)
      @events << [:before_tools, calls.map { |c| c["name"] }]
    end

    def after_tool(name:, args:, result:, context:)
      @events << [:after_tool, name]
      @replacement
    end

    def after_turn(context:, text:) = @events << :after_turn
  end

  # Stands in for PromptBuilder + Client together: the agent only ever asks the
  # builder for a payload and the client for a response.
  class FakePipe
    attr_reader :requests

    def initialize(context, *responses)
      @context   = context
      @responses = responses
      @requests  = []
    end

    # The logger asks the backend for `model` when it stamps a response event.
    FakeBackend = Struct.new(:model)

    def backend = FakeBackend.new("fake-model")

    def to_api_payload(**_)
      # Captured so a test can assert on what actually went on the wire —
      # request_messages, which is where the state block rides.
      @requests << { messages: @context.request_messages.map(&:content),
                     tools: @context.advertised_tools.keys }
      {}
    end

    # The normalized shape every real backend returns (Backends::Base).
    def parse_response(r) = { stop_reason: r["stop_reason"], content: r["content"] }
    def call(**_) = @responses.shift
  end

  def tool_use_response(name)
    { "stop_reason" => "tool_use", "usage" => { "input_tokens" => 1, "output_tokens" => 1 },
      "content" => [{ "type" => "tool_use", "id" => "u1", "name" => name, "input" => {} }] }
  end

  def text_response(text)
    { "stop_reason" => "end_turn", "usage" => { "input_tokens" => 1, "output_tokens" => 1 },
      "content" => [{ "type" => "text", "text" => text }] }
  end

  def build(hooks: nil, responses: [])
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    reg.tool("probe", description: "d") { |**_| "RAW MUD TEXT" }
    pipe = FakePipe.new(ctx, *responses)
    logger = Boukensha::Logger.new(log: File.join(Dir.mktmpdir, "s.jsonl"))
    agent = Boukensha::Agent.new(context: ctx, registry: reg, builder: pipe, client: pipe,
                                 logger: logger, hooks: hooks)
    [agent, ctx, pipe, logger]
  end

  def read_events(logger)
    File.readlines(logger.path).map { |l| JSON.parse(l) }
  end

  # --- the null object -------------------------------------------------------

  # Every existing caller, test and entrypoint that never passes `hooks:` must
  # behave exactly as it did.
  def test_an_agent_with_no_hooks_runs_unchanged
    agent, ctx, = build(responses: [tool_use_response("probe"), text_response("done")])

    assert_equal "done", agent.run
    assert_includes ctx.messages.map { |m| m.content.to_s }, "RAW MUD TEXT"
  end

  def test_the_default_hooks_object_answers_every_call_with_nil
    h = Boukensha::Hooks.new
    ctx = Boukensha::Context.new(system: "t")

    assert_nil h.before_turn(context: ctx)
    assert_nil h.before_model(context: ctx)
    assert_nil h.before_tools(calls: [], context: ctx)
    assert_nil h.after_tool(name: "x", args: {}, result: "r", context: ctx)
    assert_nil h.after_turn(context: ctx, text: "t")
  end

  # --- ordering --------------------------------------------------------------

  # before_model fires per ITERATION, not per turn. The agent moves inside its
  # own loop — 56 `move` calls against 28 turns in the sampled sessions — so a
  # room refresh at turn start alone means the model reasons about the room it
  # just left.
  def test_the_seam_fires_in_the_documented_order
    hooks = RecordingHooks.new
    agent, = build(hooks: hooks, responses: [tool_use_response("probe"), text_response("done")])
    agent.run

    assert_equal [
      :before_turn,
      :before_model,
      [:before_tools, ["probe"]],
      [:after_tool, "probe"],
      :before_model,
      :after_turn
    ], hooks.events
  end

  # The only moment the output that arrived during inference is still alive is
  # between the model's response and the first dispatch.
  def test_before_tools_fires_once_per_batch_before_any_dispatch
    hooks = RecordingHooks.new
    agent, = build(hooks: hooks, responses: [
      { "stop_reason" => "tool_use", "usage" => {},
        "content" => [{ "type" => "tool_use", "id" => "a", "name" => "probe", "input" => {} },
                      { "type" => "tool_use", "id" => "b", "name" => "probe", "input" => {} }] },
      text_response("done")
    ])
    agent.run

    batches = hooks.events.select { |e| e.is_a?(Array) && e.first == :before_tools }
    assert_equal 1, batches.size
    assert_equal [:before_tools, %w[probe probe]], batches.first
    # …and it came before both after_tools.
    assert_operator hooks.events.index(batches.first), :<,
                    hooks.events.index { |e| e.is_a?(Array) && e.first == :after_tool }
  end

  # --- the substitution seam -------------------------------------------------

  # The session log keeps the MUD's exact words — mud_monitor stops being a
  # faithful record otherwise — and only the model's copy is replaced.
  def test_after_tool_replaces_what_the_model_sees_but_not_what_is_logged
    hooks = RecordingHooks.new(replacement: "moved north → Market Square")
    agent, ctx, _pipe, logger = build(hooks: hooks,
                                      responses: [tool_use_response("probe"), text_response("done")])
    agent.run
    logger.close

    contents = ctx.messages.map { |m| m.content.to_s }
    assert_includes contents, "moved north → Market Square"
    refute_includes contents, "RAW MUD TEXT"

    logged = File.read(logger.path)
    assert_includes logged, "RAW MUD TEXT", "the log must keep exactly what the MUD said"
  end

  def test_returning_nil_leaves_the_tool_result_alone
    hooks = RecordingHooks.new(replacement: nil)
    agent, ctx, = build(hooks: hooks, responses: [tool_use_response("probe"), text_response("done")])
    agent.run

    assert_includes ctx.messages.map { |m| m.content.to_s }, "RAW MUD TEXT"
  end

  # A hook never gets to rewrite a failure, because it never sees one: the model
  # has to know why a tool blew up or it will retry forever.
  def test_a_failed_tool_is_never_handed_to_after_tool
    hooks = RecordingHooks.new(replacement: "swallowed!")
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    reg.tool("probe", description: "d") { |**_| raise "boom" }
    pipe = FakePipe.new(ctx, tool_use_response("probe"), text_response("done"))
    agent = Boukensha::Agent.new(context: ctx, registry: reg, builder: pipe, client: pipe,
                                 logger: Boukensha::Logger.new(log: File.join(Dir.mktmpdir, "s.jsonl")),
                                 hooks: hooks)
    agent.run

    refute_includes hooks.events, [:after_tool, "probe"]
    assert(ctx.messages.any? { |m| m.content.to_s.include?("boom") })
  end

  # --- what the log says the model did and saw (observ_improvements.md §1-2) --

  # The counterpart to the hook dispatcher's `initiator: "hook"`. Without the
  # pair, a session cannot report model and automatic tool counts separately,
  # and a hook's bootstrap `score` makes the model look tool-hungry.
  def test_model_selected_calls_are_logged_as_such_and_correlated_by_call_id
    agent, _ctx, _pipe, logger = build(responses: [tool_use_response("probe"), text_response("done")])
    agent.run
    logger.close
    events = read_events(logger)

    call   = events.find { |e| e["phase"] == "tool_call" }
    result = events.find { |e| e["phase"] == "tool_result" }

    assert_equal "model", call["initiator"]
    assert_equal "model", result["initiator"]
    assert_equal call["call_id"], result["call_id"]
    assert_kind_of Integer, result["duration_ms"]
  end

  # The raw result AND the replacement, on one record, joined by call_id. The
  # monitor could previously only show the two by making the reader diff the
  # transcript against the request drawer.
  def test_a_replacement_is_recorded_against_the_call_it_replaced
    hooks = RecordingHooks.new(replacement: "moved north → Market Square")
    agent, _ctx, _pipe, logger = build(hooks: hooks,
                                       responses: [tool_use_response("probe"), text_response("done")])
    agent.run
    logger.close
    events = read_events(logger)

    call      = events.find { |e| e["phase"] == "tool_call" }
    transform = events.find { |e| e["phase"] == "context_transform" }

    refute_nil transform
    assert_equal call["call_id"], transform["call_id"]
    assert_equal "tool_result_replacement", transform["kind"]
    assert_equal "moved north → Market Square", transform["content"]
    assert_equal "RAW MUD TEXT".length, transform["raw_chars"]
  end

  def test_no_transform_is_logged_when_the_hook_leaves_the_result_alone
    agent, _ctx, _pipe, logger = build(hooks: RecordingHooks.new(replacement: nil),
                                       responses: [tool_use_response("probe"), text_response("done")])
    agent.run
    logger.close

    assert_empty read_events(logger).select { |e| e["phase"] == "context_transform" }
  end

  # "Thank you for the context" — which context? The transcript could not say;
  # only the request payload carried the block. Now every model call is preceded
  # by the state it was handed.
  def test_the_injected_state_block_is_logged_before_the_request_that_carried_it
    hooks = Class.new(Boukensha::Hooks) do
      def before_model(context:) = context.state_block = "[here] The Temple Of Midgaard"
    end.new
    agent, _ctx, _pipe, logger = build(hooks: hooks, responses: [text_response("done")])
    agent.run
    logger.close
    events = read_events(logger)

    injected = events.find { |e| e["phase"] == "injected_context" }
    refute_nil injected
    assert_equal "state_block", injected["kind"]
    assert_equal "[here] The Temple Of Midgaard", injected["content"]
    assert_equal true, injected["changed"]
    assert_operator events.index(injected), :<, events.index { |e| e["phase"] == "request" }
  end

  # The block is re-rendered every iteration and is usually identical to the
  # last one. Saying so is what lets the monitor collapse the repeats instead of
  # printing the same four lines between every pair of tool calls.
  def test_an_unchanged_block_is_still_logged_but_marked_unchanged
    hooks = Class.new(Boukensha::Hooks) do
      def before_model(context:) = context.state_block = "[here] Market Square"
    end.new
    agent, _ctx, _pipe, logger = build(hooks: hooks,
                                       responses: [tool_use_response("probe"), text_response("done")])
    agent.run
    logger.close

    injected = read_events(logger).select { |e| e["phase"] == "injected_context" }
    assert_equal [true, false], injected.map { |e| e["changed"] }
  end

  # --- the state block -------------------------------------------------------

  # It is not a message. It lives on the Context, is re-rendered before each
  # model call, and exists in exactly one copy that is always current.
  def test_the_state_block_rides_at_the_tail_and_is_never_duplicated
    ctx = Boukensha::Context.new(system: "t")
    ctx.add_message(:user, "go north")

    assert_equal ["go north"], ctx.request_messages.map(&:content)

    ctx.state_block = "[here] Market Square"
    assert_equal ["go north", "[here] Market Square"], ctx.request_messages.map(&:content)
    assert_equal 1, ctx.messages.size, "the transcript itself is untouched"

    # Rewriting it leaves no trail of stale copies behind.
    ctx.state_block = "[here] The Dark Alley"
    assert_equal ["go north", "[here] The Dark Alley"], ctx.request_messages.map(&:content)

    ctx.state_block = nil
    assert_equal ["go north"], ctx.request_messages.map(&:content)
  end

  # Compaction throws away the OLDEST messages, which is precisely where the
  # rooms nearest the start of an exploration used to live. The state block is
  # not in @messages, so it cannot be compacted away.
  def test_compaction_cannot_drop_the_state_block
    ctx = Boukensha::Context.new(system: "t")
    6.times { |i| ctx.add_message(:user, "m#{i}") }
    ctx.state_block = "[here] Market Square"
    ctx.compact_messages!

    assert_equal "[here] Market Square", ctx.request_messages.last.content
  end
end
