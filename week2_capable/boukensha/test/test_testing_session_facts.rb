require_relative "helper"
require "json"
require "boukensha/testing/session_facts"
require "boukensha/testing/expectations"

# Tier 1: the projection of a session .jsonl that `expect:` is evaluated
# against. No model, no cost, no variance — which is exactly why it can be
# tested against a file on disk with nothing running.
class TestTestingSessionFacts < Minitest::Test
  SF = Boukensha::Testing::SessionFacts
  EX = Boukensha::Testing::Expectations

  def setup = @dir = Dir.mktmpdir
  def teardown = FileUtils.remove_entry(@dir)

  def test_splits_model_calls_from_hook_calls
    facts = load(session_log)

    assert_equal 3, facts.model_tool_calls
    assert_equal 2, facts.automatic_tool_calls
    assert facts.has_provenance?
  end

  # A file written before the provenance contract cannot say which calls were
  # the model's. Everything stays in `model_tool_calls` — which is what that
  # number meant before the split existed — and `has_provenance?` is how a
  # reader knows not to trust the split.
  def test_a_legacy_log_reports_no_bogus_split
    facts = load([
      { phase: "session_start" },
      { phase: "tool_call", call_id: "c1", name: "tbamud__move", args: { direction: "west" } },
      { phase: "tool_result", call_id: "c1", name: "tbamud__move", result: "ok", ok: true },
      { phase: "turn_end", reason: "completed", iterations: 1 }
    ])

    refute facts.has_provenance?
    assert_equal 1, facts.model_tool_calls
    assert_equal 0, facts.automatic_tool_calls
    assert_nil facts.launch, "a legacy log has no launch and must not invent one"
  end

  def test_reads_provenance_and_folds_renames_last_one_wins
    facts = load([
      { phase: "session_start", session_name: "first", launch: { "mode" => "test", "scenario" => "find_bakery" } },
      { phase: "session_rename", session_name: "second", source: "user" },
      { phase: "session_rename", session_name: "third", source: "user" }
    ])

    assert_equal "third", facts.session_name
    assert_equal "test", facts.launch["mode"]
  end

  def test_counts_iterations_turns_tokens_cost_and_end_reason
    facts = load(session_log)

    assert_equal 2, facts.iterations
    assert_equal 1, facts.turns
    assert_equal "completed", facts.end_reason
    assert_equal 9204, facts.input_tokens
    assert_equal 412, facts.output_tokens
    assert_in_delta 0.0161, facts.cost_usd, 1e-9
  end

  # A nested span's counters are already inside its parent's delta, so summing
  # every span would multiply the same work by its depth.
  def test_span_totals_sum_root_spans_only
    facts = load([
      { phase: "session_start" },
      { phase: "operation_start", operation_id: "op1", operation: "player_bootstrap" },
      { phase: "operation_start", operation_id: "op2", parent_operation_id: "op1", operation: "execute_tool look" },
      { phase: "operation_end", operation_id: "op2", mud_calls: 2, mud_ms: 100, db_writes: 3 },
      { phase: "operation_end", operation_id: "op1", mud_calls: 2, mud_ms: 100, db_writes: 3 }
    ])

    assert_equal 2, facts.span_totals[:mud_calls]
    assert_equal 3, facts.span_totals[:db_writes]
  end

  def test_an_incomplete_log_says_so_rather_than_claiming_completion
    facts = load([{ phase: "session_start" }, { phase: "turn", n: 1 }])

    assert_equal "incomplete", facts.end_reason
  end

  def test_errors_are_matched_to_this_session_only
    log  = write_log(session_log, id: "20260728T120000Z-aaaaaaaa")
    path = File.join(@dir, "error.log")
    File.write(path, [
      { id: "e1", session_id: "20260728T120000Z-aaaaaaaa", component: "repl", message: "boom" },
      { id: "e2", session_id: "someone-else", component: "repl", message: "not ours" }
    ].map { |e| JSON.generate(e) }.join("\n"))

    errors = SF.load(log).errors(path)

    assert_equal ["e1"], errors.map { |e| e[:id] }
  end

  # ---------- expectations over those facts --------------------------------

  def test_tool_called_matches_bare_and_prefixed_names_with_evidence
    facts = load(session_log)

    assert EX.called("plan_route", facts).ok
    assert EX.called("shop(action: list)", facts).ok, "a bare name matches through the MCP prefix"
    assert EX.called("tbamud__shop(action: list)", facts).ok

    miss = EX.called("tbamud__attack", facts)
    refute miss.ok
    assert_equal "never called", miss.detail
  end

  def test_a_pinned_argument_that_does_not_match_is_not_a_call
    facts = load(session_log)

    refute EX.called("shop(action: buy)", facts).ok
  end

  def test_tool_not_called_carries_the_call_id_as_evidence
    facts = load(session_log)
    result = EX.not_called("plan_route", facts)

    refute result.ok
    assert_match(/call_1/, result.detail)
  end

  # Hook traffic must not satisfy — or violate — a rule about what the AGENT
  # chose. The framework's bootstrap `look` is in this log for exactly that.
  def test_hook_calls_are_not_matchable
    facts = load(session_log)

    refute EX.called("tbamud__look", facts).ok
    assert EX.not_called("tbamud__look", facts).ok
  end

  def test_ceilings_compare_against_the_facts
    facts = load(session_log)

    assert EX.at_most("max_model_tool_calls", 6, facts.model_tool_calls).ok
    refute EX.at_most("max_model_tool_calls", 2, facts.model_tool_calls).ok
  end

  # "We did not measure it" must never read as "it was under budget".
  def test_an_unmeasurable_ceiling_fails_rather_than_passing_silently
    result = EX.at_most("max_cost_usd", 0.02, nil)

    refute result.ok
    assert_equal "not measured", result.detail
  end

  def test_an_unknown_expectation_key_is_a_load_error_not_a_silent_no_op
    error = assert_raises(EX::Error) { EX.evaluate({ "tool_calledd" => ["x"] }, load(session_log)) }

    assert_match(/tool_calledd/, error.message)
  end

  private

  # A realistic case: the hook's bootstrap `look` and `poll`, then the model
  # planning, executing and listing.
  def session_log
    [
      { phase: "session_start", session_name: "find_bakery #3",
        launch: { "mode" => "test", "runner" => "boukensha-test", "scenario" => "find_bakery" } },
      { phase: "turn", n: 1 },
      { phase: "iteration", n: 1, max: 15 },
      { phase: "tool_call", call_id: "h1", name: "tbamud__look", args: {}, initiator: "hook" },
      { phase: "tool_result", call_id: "h1", name: "tbamud__look", result: "The Temple", ok: true, duration_ms: 40 },
      { phase: "tool_call", call_id: "h2", name: "tbamud__poll", args: {}, initiator: "hook" },
      { phase: "tool_result", call_id: "h2", name: "tbamud__poll", result: "", ok: true, duration_ms: 5 },
      { phase: "tool_call", call_id: "call_1", name: "plan_route", args: { destination: "bakery" }, initiator: "model" },
      { phase: "tool_result", call_id: "call_1", name: "plan_route", result: "known: south, west", ok: true },
      { phase: "iteration", n: 2, max: 15 },
      { phase: "tool_call", call_id: "call_2", name: "execute_route", args: { steps: %w[south west] }, initiator: "model" },
      { phase: "tool_result", call_id: "call_2", name: "execute_route", result: "arrived", ok: true },
      { phase: "tool_call", call_id: "call_3", name: "tbamud__shop", args: { action: "list" }, initiator: "model" },
      { phase: "tool_result", call_id: "call_3", name: "tbamud__shop", result: "bread 10 gold", ok: true },
      { phase: "response", text: "I found the bakery.", input_tokens: 9204, output_tokens: 412, cost_usd: 0.0161 },
      { phase: "turn_end", reason: "completed", iterations: 2 }
    ]
  end

  def load(events) = SF.load(write_log(events))

  def write_log(events, id: "20260728T120000Z-fef86633")
    path = File.join(@dir, "#{id}.jsonl")
    File.write(path, events.map { |e| JSON.generate(e.merge(session_id: id, at: "2026-07-28T12:00:00.000Z")) }.join("\n"))
    path
  end
end
