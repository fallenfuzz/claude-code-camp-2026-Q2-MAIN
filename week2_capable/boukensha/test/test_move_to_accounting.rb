require_relative "helper"
require "json"

# move_to.md §8 "Accounting": player-turn input tokens for `find_bakery_cold`
# asserted against a committed baseline, so a regression shows up as a diff.
#
# The baseline is a file rather than a number in this test, because the numbers
# are EVIDENCE — they name the run they came from, and a reader who distrusts one
# can reopen that session. This asserts the two things a committed measurement is
# for: that the recorded win is real arithmetic rather than a hopeful round
# number, and that the newest run on disk has not quietly given it back.
#
# It cannot run the case itself. That needs a live MUD, a key and real spend, so
# the freshness half skips when no report is present — which is the honest shape:
# the baseline is still checked for internal consistency on every commit.
class TestMoveToAccounting < Minitest::Test
  ROOT     = File.expand_path("../../../.boukensha", __dir__)
  BASELINE = File.join(ROOT, "tests", "baselines", "find_bakery_cold.json")
  REPORTS  = File.join(ROOT, "tests", "reports", "find_bakery_cold")

  # Room for run-to-run variance in a sampled model without room for a
  # regression: the win being measured is 81%, so 25% of slack cannot hide it.
  TOLERANCE = 1.25

  def setup
    skip "no committed baseline at #{BASELINE}" unless File.exist?(BASELINE)

    @baseline = JSON.parse(File.read(BASELINE))
    @before   = @baseline.fetch("before")
    @after    = @baseline.fetch("after")
  end

  def test_the_baseline_records_a_real_reduction_in_the_players_own_budget
    assert_operator @after["player_input_tokens"], :<, @before["player_input_tokens"]

    # The claim §1 makes is that the turn budget is the scarce resource and that
    # nearly all of it was context re-send. A win worth the surface change is a
    # large one, not a marginal one.
    ratio = @after["player_input_tokens"].to_f / @before["player_input_tokens"]
    assert_operator ratio, :<, 0.5, "the player's budget should be at least halved"
  end

  # §1's actual complaint: five of ten cases in the boundaries_gate run ended on
  # `max_tokens` rather than on the agent finishing. Ending on `completed` is the
  # outcome, and the token count is only how it was bought.
  def test_the_turn_now_ends_because_the_agent_finished
    assert_equal "max_tokens", @before["end_reason"]
    assert_equal "completed", @after["end_reason"]
    assert_equal "pass", @after["verdict"]
    assert_equal "The Bakery", @after["final_room"]
  end

  # §2's whole mechanism: N model round trips collapse into one tool call.
  def test_the_model_makes_far_fewer_tool_calls
    assert_operator @after["model_tool_calls"], :<=, 4
    assert_operator @after["model_tool_calls"], :<, @before["model_tool_calls"] / 3
  end

  # The honest total. §2.1's argument is that the navigator's spend lands off the
  # player's turn budget — not that it is free — so the baseline has to carry it
  # and the comparison has to be made against the sum.
  def test_the_baseline_accounts_for_the_navigators_spend_and_still_wins
    refute_nil @after["navigator_input_tokens"], "a baseline that hid the subagent would be dishonest"

    total = @after["player_cost_usd"] + @after["navigator_cost_usd"]
    assert_in_delta @after["cost_usd"], total, 0.002,
                    "the recorded total should be the two halves added up"
    assert_operator @after["cost_usd"], :<, @before["cost_usd"]
  end

  # The freshness half. Skips with no report on disk, because the case needs a
  # live MUD and real spend to produce one.
  def test_the_most_recent_run_has_not_given_the_win_back
    reports = Dir.glob(File.join(REPORTS, "*.json")).sort
    skip "no find_bakery_cold report on disk — run `boukensha -ts find_bakery_cold`" if reports.empty?

    facts = JSON.parse(File.read(reports.last)).dig("cases", 0, "facts")
    skip "the newest report has no facts block" unless facts

    ceiling = @before["player_input_tokens"]
    assert_operator facts["input_tokens"], :<, ceiling,
                    "run #{File.basename(reports.last)} is back at the pre-move_to budget"
    assert_operator facts["model_tool_calls"], :<=, (@after["model_tool_calls"] * TOLERANCE).ceil,
                    "run #{File.basename(reports.last)} made #{facts['model_tool_calls']} model tool " \
                    "calls against a baseline of #{@after['model_tool_calls']}"
  end
end
