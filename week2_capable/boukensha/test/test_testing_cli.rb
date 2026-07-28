require_relative "helper"
require "json"
require "boukensha/testing"

# The seam where a finished case becomes a report row: tier 1 is evaluated, the
# judge may downgrade it, and a broken harness is never labelled a failing
# agent.
class TestTestingCli < Minitest::Test
  CLI = Boukensha::Testing::CLI
  Case = Boukensha::Testing::Fixtures::Case
  Outcome = Boukensha::Testing::Runner::Outcome

  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "profiles", "Derrano", "sessions"))
  end

  def teardown = FileUtils.remove_entry(@root)

  def test_a_clean_run_meeting_every_expectation_passes
    row = assess(outcome_for(write_session))

    assert_equal "pass", row[:status]
    assert_equal 3, row[:facts][:model_tool_calls]
    assert row[:expectations].all? { |e| e[:ok] }
    assert_equal "20260728T120000Z-fef86633", row[:session_id]
  end

  def test_a_violated_expectation_fails_and_names_the_evidence
    kase = kase_with(expect: { "tool_not_called" => ["plan_route"] })
    row  = assess(outcome_for(write_session), kase: kase)

    assert_equal "fail", row[:status]
    failed = row[:expectations].reject { |e| e[:ok] }
    assert_equal 1, failed.size
    assert_match(/call_1/, failed.first[:detail])
  end

  # A broken harness and a failing agent are different findings. Conflating them
  # is how you spend an afternoon debugging a model that was never called.
  def test_a_child_that_errored_is_error_even_though_a_log_exists
    outcome = outcome_for(write_session, status: "error", error: "seeding failed", error_kind: "seed_failed")

    row = assess(outcome)

    assert_equal "error", row[:status]
    assert_equal "seed_failed", row[:error_kind]
    refute row.key?(:expectations), "an errored case is not graded"
  end

  def test_a_case_with_no_session_log_is_an_error_that_says_so
    row = assess(Outcome.new(index: 1, case: kase_with, result: nil, status: "ran"))

    assert_equal "error", row[:status]
    assert_match(/no session log/, row[:error])
  end

  # The state a case ran against is embedded, not referenced: a report naming
  # `cleric` is worthless once the file changes.
  def test_the_row_embeds_the_resolved_state_and_map_mode
    row = assess(outcome_for(write_session))

    assert_equal 0, row[:resolved_state].dig("money", "gold")
    assert_equal "cleric", row[:base_initial_state]
    assert_equal "none", row[:map_memory]["mode"]
    assert_equal 0, row[:map_memory]["rooms_at_start"]
  end

  def test_a_scenario_with_no_rubric_is_not_sent_to_the_judge
    cli = CLI.new({ mode: :scenario, name: "find_bakery" }, root_dir: @root, out: StringIO.new)
    row = cli.assess(outcome_for(write_session), run_id: "run1")

    refute row.key?(:judge), "there is nothing to judge and nothing to pay for"
  end

  private

  def assess(outcome, kase: nil, no_judge: true)
    outcome = Outcome.new(**outcome.to_h.merge(case: kase)) if kase
    cli = CLI.new({ mode: :scenario, name: "find_bakery", no_judge: no_judge },
                  root_dir: @root, out: StringIO.new)
    cli.assess(outcome, run_id: "run1")
  end

  def outcome_for(session_id, status: "ran", error: nil, error_kind: nil)
    Outcome.new(
      index: 1, case: kase_with, status: status, error: error, error_kind: error_kind,
      result: { "ok" => status == "ran", "session_id" => session_id,
                "map_memory" => { "mode" => "none", "rooms_at_start" => 0 } }
    )
  end

  def kase_with(expect: { "tool_called" => ["plan_route", "shop(action: list)"], "max_model_tool_calls" => 6 })
    Case.new(scenario: "find_bakery", session_name: "find_bakery", player_profile: "Derrano",
             goal: "Find the bakery.", state: { "money" => { "gold" => 0 } },
             base_initial_state: "cleric", map_memory: "none", limits: {},
             expect: expect, evaluation: {})
  end

  def write_session(id = "20260728T120000Z-fef86633")
    path = File.join(@root, "profiles", "Derrano", "sessions", "#{id}.jsonl")
    events = [
      { phase: "session_start", session_name: "find_bakery",
        launch: { "mode" => "test", "scenario" => "find_bakery" } },
      { phase: "turn", n: 1 },
      { phase: "iteration", n: 1, max: 15 },
      { phase: "tool_call", call_id: "h1", name: "tbamud__look", args: {}, initiator: "hook" },
      { phase: "tool_result", call_id: "h1", name: "tbamud__look", result: "The Temple", ok: true, duration_ms: 40 },
      { phase: "tool_call", call_id: "call_1", name: "plan_route", args: { destination: "bakery" }, initiator: "model" },
      { phase: "tool_result", call_id: "call_1", name: "plan_route", result: "known", ok: true },
      { phase: "tool_call", call_id: "call_2", name: "execute_route", args: { steps: %w[south] }, initiator: "model" },
      { phase: "tool_result", call_id: "call_2", name: "execute_route", result: "arrived", ok: true },
      { phase: "tool_call", call_id: "call_3", name: "tbamud__shop", args: { action: "list" }, initiator: "model" },
      { phase: "tool_result", call_id: "call_3", name: "tbamud__shop", result: "bread", ok: true },
      { phase: "response", text: "Found it.", input_tokens: 900, output_tokens: 40, cost_usd: 0.0016 },
      { phase: "turn_end", reason: "completed", iterations: 1 }
    ]
    File.write(path, events.map { |e| JSON.generate(e.merge(session_id: id)) }.join("\n"))
    id
  end
end
