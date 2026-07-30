require_relative "helper"
require "json"
require "boukensha/testing/report"

# The report is the artifact the whole harness exists to produce, so the things
# asserted here are the claims a reader will make from it.
class TestTestingReport < Minitest::Test
  R = Boukensha::Testing::Report

  def setup = @dir = Dir.mktmpdir
  def teardown = FileUtils.remove_entry(@dir)

  def test_counts_and_pass_rate_include_errors_in_the_denominator
    report = build(%w[pass pass fail error])

    summary = report.summary

    assert_equal 4, summary[:cases]
    assert_equal 2, summary[:passed]
    assert_equal 1, summary[:failed]
    assert_equal 1, summary[:errored]
    assert_in_delta 0.5, summary[:pass_rate], 1e-9,
                    "a run where a case crashed did not pass 3/3"
  end

  # The whole point of --batch 20 is that the agent is stochastic. A mean hides
  # exactly what you ran the batch to see.
  def test_reports_distributions_not_just_a_total
    report = R.new(kind: "scenario", name: "find_bakery")
    [4, 6, 6, 7, 20].each_with_index do |calls, i|
      report << { index: i + 1, status: "pass", facts: { model_tool_calls: calls, iterations: 2 } }
    end

    assert_equal 6, report.summary[:median][:model_tool_calls]
    assert_equal 20, report.summary[:p90][:model_tool_calls]
  end

  # Twenty logs into one sentence: which expectation actually broke, and how
  # often.
  def test_failure_modes_cluster_by_the_expectation_that_failed
    report = R.new(kind: "scenario", name: "find_bakery")
    2.times do |i|
      report << {
        index: i + 1, status: "fail", facts: {},
        expectations: [{ kind: "tool_not_called", rule: "tbamud__examine(target: menu)", ok: false },
                       { kind: "tool_called", rule: "plan_route", ok: true }]
      }
    end
    report << { index: 3, status: "error", error_kind: "timeout_or_crash", facts: {} }

    modes = report.summary[:failure_modes]

    assert_equal 2, modes["tool_not_called: tbamud__examine(target: menu)"]
    assert_equal 1, modes["timeout_or_crash"]
  end

  def test_a_judge_only_failure_gets_its_own_bucket
    report = R.new(kind: "scenario", name: "s")
    report << { index: 1, status: "fail", facts: {},
                expectations: [{ kind: "tool_called", rule: "plan_route", ok: true }] }

    assert_equal 1, report.summary[:failure_modes]["judge"]
  end

  def test_agent_and_judge_costs_are_attributed_separately
    report = R.new(kind: "scenario", name: "s")
    report << { index: 1, status: "pass", facts: { cost_usd: 0.01 }, judge: { cost_usd: 0.004 } }
    report << { index: 2, status: "pass", facts: { cost_usd: 0.02 }, judge: { cost_usd: 0.004 } }

    cost = report.summary[:cost_usd]

    assert_in_delta 0.03, cost[:agent], 1e-9
    assert_in_delta 0.008, cost[:judge], 1e-9
    assert_in_delta 0.038, cost[:total], 1e-9
  end

  # `run_id` has the same shape as a session id, so a directory listing sorts
  # chronologically by filename exactly as SessionLog::Store already relies on.
  def test_run_id_sorts_chronologically_by_filename
    assert_match(/\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/, R.new_run_id)
  end

  def test_writes_under_the_run_name_and_round_trips
    report = build(%w[pass])
    path   = report.write!(@dir)

    assert_equal File.join(@dir, "find_bakery", "#{report.run_id}.json"), path

    doc = JSON.parse(File.read(path))

    assert_equal 2, doc["schema"], "settings_sweep.md — arms, and a digest over the resolved settings"
    assert_equal "find_bakery", doc["name"]
    assert_equal 1, doc["cases"].length
  end

  def test_an_explicit_report_path_wins
    path = File.join(@dir, "somewhere", "else.json")

    assert_equal path, build(%w[pass]).write!(@dir, path: path)
    assert File.file?(path)
  end

  # A state file changes; a report that only NAMES one is worthless six weeks
  # later.
  def test_the_resolved_state_is_embedded_rather_than_referenced
    report = R.new(kind: "scenario", name: "s")
    report << { index: 1, status: "pass", facts: {}, base_initial_state: "cleric",
                resolved_state: { "level" => 10, "money" => { "gold" => 0 } } }

    doc = JSON.parse(JSON.generate(report.to_h))

    assert_equal 10, doc.dig("cases", 0, "resolved_state", "level")
  end

  # ---------- more than one configuration (settings_sweep.md §5) -------------

  def test_a_multi_arm_report_carries_one_entry_per_arm_with_its_own_statistics
    arms = sweep.summary[:arms]

    assert_equal 2, arms.size
    four = arms.find { |a| a[:arm] == "max_decisions=4" }
    ten  = arms.find { |a| a[:arm] == "max_decisions=10" }

    assert_equal 1, four[:passed]
    assert_equal 2, ten[:passed]
    assert_in_delta 0.5, four[:pass_rate], 1e-9
    assert_in_delta 1.0, ten[:pass_rate], 1e-9
    # Nearest-rank over that arm's cases ALONE — [6, 8] and [2, 3], never the
    # four of them together, which is the whole point.
    assert_equal 8, four[:median][:model_tool_calls]
    assert_equal 3, ten[:median][:model_tool_calls]
    refute_equal four[:settings_digest], ten[:settings_digest],
                 "an arm carries its own digest, or a reader cannot tell them apart"
    assert_equal 4, four.dig(:settings, "tools", "navigation", "limits", "max_decisions")
  end

  # A median across `max_decisions: 4` and `max_decisions: 10` is a number
  # describing nothing, and it is the number the run's final line would print.
  # Omitting it beats qualifying it in a comment nobody reads.
  def test_a_multi_arm_report_omits_the_run_level_numbers_that_do_not_aggregate
    summary = sweep.summary

    %i[pass_rate median p90].each do |key|
      refute summary.key?(key), "#{key} across two configurations describes neither"
    end
  end

  # Counts and cost DO aggregate honestly, and a run that hid what it spent would
  # be unusable for the one decision a sweep is run to make.
  def test_a_multi_arm_report_still_reports_counts_and_cost
    summary = sweep.summary

    assert_equal 4, summary[:cases]
    assert_equal 3, summary[:passed]
    assert_equal 1, summary[:failed]
    assert_in_delta 0.08, summary.dig(:cost_usd, :agent), 1e-9
  end

  def test_a_single_arm_run_keeps_exactly_the_shape_it_had
    summary = build(%w[pass fail]).summary

    assert_equal %i[cases passed failed errored pass_rate cost_usd median p90 failure_modes], summary.keys
    refute summary.key?(:arms), "one configuration is not a sweep"
  end

  # An arm label is present on every row the harness writes, but a report row
  # from before this existed has none and must still summarise.
  def test_rows_with_no_arm_at_all_are_one_arm
    assert_equal [nil], build(%w[pass pass]).arms
    refute build(%w[pass]).summary.key?(:arms)
  end

  private

  # Two arms of two cases: the shape §1's open question resolves to.
  def sweep
    R.new(kind: "plan", name: "navigation_limits").tap do |report|
      report << arm_row(1, "max_decisions=4", 4, "pass", calls: 6)
      report << arm_row(2, "max_decisions=4", 4, "fail", calls: 8)
      report << arm_row(3, "max_decisions=10", 10, "pass", calls: 2)
      report << arm_row(4, "max_decisions=10", 10, "pass", calls: 3)
    end
  end

  def arm_row(index, arm, decisions, status, calls:)
    {
      index: index, status: status, arm: arm,
      settings: { "tools" => { "navigation" => { "limits" => { "max_decisions" => decisions } } } },
      settings_digest: "sha256:#{decisions}",
      facts: { model_tool_calls: calls, cost_usd: 0.02 },
      expectations: [{ kind: "tool_called", rule: "move_to", ok: status == "pass" }]
    }
  end

  def build(statuses)
    R.new(kind: "scenario", name: "find_bakery").tap do |report|
      statuses.each_with_index do |status, i|
        report << { index: i + 1, status: status, facts: { model_tool_calls: 5, cost_usd: 0.01 } }
      end
    end
  end
end
