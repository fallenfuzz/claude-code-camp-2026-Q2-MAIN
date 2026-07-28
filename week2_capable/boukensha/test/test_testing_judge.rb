require_relative "helper"
require "json"
require "boukensha/testing/judge"
require "boukensha/testing/session_facts"
require "boukensha/testing/report"

# Tier 2. The two rules that matter are both about what the judge may NOT do:
# it cannot overturn tier 1, and it cannot pass by failing to answer.
class TestTestingJudge < Minitest::Test
  J  = Boukensha::Testing::Judge
  SF = Boukensha::Testing::SessionFacts

  def setup = @dir = Dir.mktmpdir
  def teardown = FileUtils.remove_entry(@dir)

  # ---------- the merge rule ------------------------------------------------

  def test_a_tier_one_failure_is_never_overturned_by_a_judge_pass
    verdict = J.new.parse('{"verdict":"pass","reasoning":"looked fine to me"}')

    assert_equal "fail", J.merge_status(false, verdict)
  end

  def test_the_judge_can_downgrade_a_mechanical_pass
    verdict = J.new.parse('{"verdict":"fail","reasoning":"arrived by luck"}')

    assert_equal "fail", J.merge_status(true, verdict)
  end

  def test_a_clean_run_with_no_judge_passes
    assert_equal "pass", J.merge_status(true, nil)
  end

  def test_a_judge_error_is_an_error_not_a_pass
    verdict = J.new.parse("I think it did well, honestly")

    assert_equal "error", J.merge_status(true, verdict)
  end

  # ---------- parsing -------------------------------------------------------

  def test_parses_a_well_formed_verdict
    verdict = J.new.parse(<<~JSON)
      {"verdict":"fail",
       "desired":[{"behaviour":"plan_route","met":true,"evidence":"call_1"}],
       "undesired":[{"behaviour":"examine(menu)","occurred":true,"evidence":"call_9"}],
       "reasoning":"Planned, then abandoned the route and examined the menu.",
       "confidence":0.9}
    JSON

    assert_equal "fail", verdict.verdict
    assert_equal 0.9, verdict.confidence
    assert_equal 1, verdict.desired.size
    refute verdict.errored?
  end

  # A fence is a formatting slip, not a refusal to answer. Throwing away a
  # verdict that is right there would cost a real model call for nothing.
  def test_tolerates_a_fenced_or_prefaced_response
    fenced = J.new.parse("Here you go:\n```json\n{\"verdict\":\"pass\",\"reasoning\":\"fine\"}\n```")

    assert_equal "pass", fenced.verdict
  end

  def test_malformed_json_is_an_error_carrying_what_came_back
    verdict = J.new.parse("{not json at all")

    assert verdict.errored?
    assert_match(/did not return JSON/, verdict.error)
  end

  def test_an_out_of_vocabulary_verdict_is_an_error
    verdict = J.new.parse('{"verdict":"maybe","reasoning":"unsure"}')

    assert verdict.errored?
    assert_match(/neither pass nor fail/, verdict.error)
  end

  # ---------- the digest ----------------------------------------------------

  def test_the_digest_carries_only_what_the_agent_chose
    digest = J.new.digest_for(facts, goal: "Find the bakery.",
                              evaluation: { "desired_behaviour" => "plan a route",
                                            "undesired_behaviour" => "examine the menu" })

    tools = digest[:trace].map { |c| c[:tool] }

    assert_equal %w[plan_route tbamud__shop], tools, "hook traffic must not reach the judge"
    assert_equal "Find the bakery.", digest[:goal]
    assert_equal ["I found it."], digest[:said]
  end

  def test_long_results_are_truncated_so_the_digest_stays_a_digest
    long = "a" * 2000
    digest = J.new.digest_for(facts(result: long), goal: "g", evaluation: {})

    assert_operator digest[:trace].first[:result].length, :<, 400
    assert_match(/2000 chars/, digest[:trace].first[:result])
  end

  # A judge call is itself a session log, openable in mud_monitor when you
  # distrust a verdict — which is the whole reason it goes through run_task.
  def test_the_verdict_names_the_judges_own_session
    judge = J.new(log_dir: @dir, runner: ->(_digest, _log) { '{"verdict":"pass","reasoning":"ok"}' })

    verdict = judge.call(facts: facts, goal: "g", evaluation: { "desired_behaviour" => "x" },
                         case_label: "20260728T120000Z-abcd1234")

    assert_equal "20260728T120000Z-abcd1234", verdict.session_id
  end

  def test_a_raising_runner_becomes_an_error_verdict_not_a_crashed_run
    judge = J.new(runner: ->(_d, _l) { raise "provider is down" })

    verdict = judge.call(facts: facts, goal: "g", evaluation: { "desired_behaviour" => "x" })

    assert verdict.errored?
    assert_match(/provider is down/, verdict.error)
  end

  private

  def facts(result: "bread 10 gold")
    path = File.join(@dir, "20260728T120000Z-fef86633.jsonl")
    events = [
      { phase: "session_start" },
      { phase: "tool_call", call_id: "h1", name: "tbamud__look", args: {}, initiator: "hook" },
      { phase: "tool_result", call_id: "h1", name: "tbamud__look", result: "The Temple", ok: true },
      { phase: "tool_call", call_id: "call_1", name: "plan_route", args: { destination: "bakery" }, initiator: "model" },
      { phase: "tool_result", call_id: "call_1", name: "plan_route", result: result, ok: true },
      { phase: "tool_call", call_id: "call_2", name: "tbamud__shop", args: { action: "list" }, initiator: "model" },
      { phase: "tool_result", call_id: "call_2", name: "tbamud__shop", result: "bread", ok: true },
      { phase: "response", text: "I found it.", input_tokens: 10, output_tokens: 2, cost_usd: 0.001 },
      { phase: "turn_end", reason: "completed", iterations: 1 }
    ]
    File.write(path, events.map { |e| JSON.generate(e) }.join("\n"))
    SF.load(path)
  end
end
