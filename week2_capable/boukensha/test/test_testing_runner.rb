require_relative "helper"
require "json"
require "boukensha/testing/runner"
require "boukensha/testing/fixtures"

# The parent half of a run. The one property that matters is containment: a
# case that hangs, raises, or takes the MUD down with it costs ONE case, not
# the remaining nineteen.
#
# The child is stubbed with a tiny Ruby script rather than the real binary —
# what is under test is the parent's supervision, not the agent.
class TestTestingRunner < Minitest::Test
  R = Boukensha::Testing::Runner
  C = Boukensha::Testing::Fixtures::Case

  def setup
    @root = Dir.mktmpdir
    @work = File.join(@root, "work")
  end

  def teardown = FileUtils.remove_entry(@root)

  def test_collects_a_result_written_by_the_child
    outcomes = runner(child_that(:succeeds)).run([kase], run_id: "run1")

    assert_equal 1, outcomes.size
    assert_equal "ran", outcomes.first.status
    assert_equal "20260728T120000Z-aaaaaaaa", outcomes.first.result["session_id"]
    assert_nil outcomes.first.error
  end

  def test_a_child_reporting_failure_is_an_error_carrying_its_kind
    outcome = runner(child_that(:fails)).run([kase], run_id: "run1").first

    assert_equal "error", outcome.status
    assert_equal "seed_failed", outcome.error_kind
    assert_match(/could not delete/, outcome.error)
  end

  # The property the whole one-process-per-case design exists for.
  def test_a_case_exceeding_its_wall_timeout_is_recorded_and_the_batch_continues
    slow = kase(wall_timeout_s: 1)
    outcomes = runner(child_that(:hangs)).run([slow, slow], run_id: "run1")

    assert_equal 2, outcomes.size, "the second case still ran"
    outcomes.each do |outcome|
      assert_equal "error", outcome.status
      assert_match(/wall_timeout_s of 1s exceeded/, outcome.error)
      assert_equal "timeout_or_crash", outcome.error_kind
    end
  end

  def test_a_child_that_dies_without_writing_a_result_is_an_error_not_a_pass
    outcome = runner(child_that(:crashes)).run([kase], run_id: "run1").first

    assert_equal "error", outcome.status
    assert_match(/no result file/, outcome.error)
  end

  def test_the_payload_carries_the_resolved_state_so_the_child_reads_no_files
    payload = runner(child_that(:succeeds)).payloads([kase], run_id: "run1", plan: "banking").first

    assert_equal "find_bakery", payload["scenario"]
    assert_equal "banking", payload["plan"]
    assert_equal 1, payload["case_index"]
    assert_equal({ "money" => { "gold" => 0 } }, payload["state"])
    assert_equal "cleric", payload["base_initial_state"]
  end

  def test_each_case_gets_its_own_result_and_seed_log_paths
    runner = runner(child_that(:succeeds))
    runner.run([kase, kase], run_id: "run1")

    assert_equal 2, Dir.glob(File.join(@work, "case-*-input.json")).size
  end

  private

  def runner(script)
    R.new(root_dir: @root, work_dir: @work, executable: [RbConfig.ruby, script])
  end

  def kase(wall_timeout_s: 30)
    C.new(scenario: "find_bakery", session_name: "find_bakery", player_profile: "Derrano",
          goal: "Find the bakery.", state: { "money" => { "gold" => 0 } },
          base_initial_state: "cleric", map_memory: "none",
          limits: { "wall_timeout_s" => wall_timeout_s }, expect: {}, evaluation: {})
  end

  # A stand-in child. It speaks the same contract the real one does: read the
  # payload named by `--test-case`, write JSON to `result_path`.
  def child_that(behaviour)
    body = case behaviour
           when :succeeds
             'File.write(payload["result_path"], JSON.generate({"ok" => true, "session_id" => "20260728T120000Z-aaaaaaaa", "map_memory" => {"mode" => "none", "rooms_at_start" => 0}}))'
           when :fails
             'File.write(payload["result_path"], JSON.generate({"ok" => false, "error" => "could not delete the character", "error_kind" => "seed_failed"}))'
           when :hangs
             "sleep 30"
           when :crashes
             'abort "boom"'
           end

    path = File.join(@root, "child-#{behaviour}.rb")
    File.write(path, <<~RUBY)
      require "json"
      payload = JSON.parse(File.read(ARGV[ARGV.index("--test-case") + 1]))
      #{body}
    RUBY
    path
  end
end
