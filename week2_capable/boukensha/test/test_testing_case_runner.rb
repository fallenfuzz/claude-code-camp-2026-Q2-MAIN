require_relative "helper"
require "json"
require "boukensha/testing/case_runner"
require_relative "../lib/boukensha_loader"

# The child half of a run, tested for ONE property: the map a case ends with is
# kept under the id of the session that built it.
#
# Everything the child does between those two points — seeding, the MUD, the
# model — is stubbed, because none of it is what retention can get wrong. What
# retention can get wrong is ORDER: the archive this replaces ran before a case
# started, so it filed the previous case's map under the timestamp at which the
# next case began, and nothing joined a map to the run that produced it.
class TestTestingCaseRunner < Minitest::Test
  SESSION = "20260729T183933Z-4caca6d5".freeze

  def setup
    @root = Dir.mktmpdir
    @profile_dir = File.join(@root, "profiles", "Derrano")
    FileUtils.mkdir_p(@profile_dir)
    @previous_session = Boukensha::Operation.session_id
  end

  def teardown
    Boukensha::Operation.session_id = @previous_session
    Boukensha.stage = nil
    FileUtils.remove_entry(@root)
  end

  def test_the_map_a_case_ends_with_is_retained_under_the_session_id
    result = run_case { seed_map(5) }

    assert_equal retained_path, result["map_memory_retained"]
    assert_equal 5, count_rooms(retained_path), "the map at the END of the case, not the start"
    assert result["ok"]
  end

  # A case that died halfway still built a map, and that map is usually the
  # evidence for why it died.
  def test_a_case_that_fails_mid_run_still_retains_what_it_had_built
    result = run_case do
      seed_map(2)
      raise "the MUD went away"
    end

    refute result["ok"]
    assert_equal retained_path, result["map_memory_retained"]
    assert_equal 2, count_rooms(retained_path)
  end

  # Retention is a harness convenience; the agent's result is the finding. A
  # case whose map could not be copied is still a case that ran.
  def test_a_retention_failure_never_fails_a_case_that_passed
    # A plain file where the retained directory belongs: mkdir_p cannot proceed,
    # which is as good a stand-in as any for the disk saying no.
    FileUtils.mkdir_p(File.dirname(sessions_dir))
    File.write(sessions_dir, "not a directory")

    result = run_case { seed_map(1) }

    assert result["ok"], "the agent's turn succeeded, so the case did"
    assert_nil result["map_memory_retained"]
  end

  def test_older_maps_are_pruned_as_each_case_retains_its_own
    stale = (1..30).map do |i|
      path = File.join(sessions_dir, format("20260729T%06dZ-4caca6d5.sqlite3", i))
      FileUtils.mkdir_p(sessions_dir)
      File.write(path, "an older run")
      path
    end

    run_case { seed_map(1) }

    kept = Dir.glob(File.join(sessions_dir, "*.sqlite3"))
    assert_equal 30, kept.size, "the limit holds across runs, not just within one"
    assert_includes kept, retained_path
    refute File.file?(stale.first), "the oldest went, and it went by name"
  end

  # ---------- per-run settings overrides (settings_sweep.md §10 step 1) -------

  # The child half of the injection seam. The parent resolves the override and
  # ships it in the payload; this is where it has to be INSTALLED, in the one
  # window between Config existing and the first read of it.
  def test_the_payloads_settings_override_is_installed_before_anything_reads_config
    result = run_case(settings: { "tools" => { "navigation" => { "limits" => { "max_decisions" => 10 } } } },
                      arm: "max_decisions=10") { seed_map(1) }

    assert result["ok"]
    assert_equal [{ "tools" => { "navigation" => { "limits" => { "max_decisions" => 10 } } } }],
                 @installed
  end

  # Which arm a case ran under, in the run log. §3.3's complaint about a sweep is
  # that the arm is otherwise invisible: a scenario name tells a reader nothing
  # about which of six configurations produced the row.
  def test_the_arm_and_its_overrides_are_named_in_the_run_log
    log = File.join(@root, "run.log")
    run_case(settings: { "tasks" => { "navigator" => { "model" => "claude-sonnet-4-6" } } },
             arm: "model=claude-sonnet-4-6", run_log: log) { seed_map(1) }

    line = File.read(log).lines.find { |l| l.include?("settings") }

    refute_nil line, "the arm has to appear in the log the run is watched through"
    assert_match(/model=claude-sonnet-4-6/, line)
    assert_match(/tasks\.navigator\.model=claude-sonnet-4-6/, line)
  end

  def test_a_case_with_no_override_installs_nothing
    run_case { seed_map(1) }

    assert_empty @installed, "an absent override is a no-op, not an empty install"
  end

  # ---------- staging (mocking_messages.md §3, §6, §7) -----------------------

  # The child half of the staging seam, and the same shape as the settings one:
  # the parent validates and ships it, the child INSTALLS it, and it has to be
  # installed before the agent's first model call or a staged task reaches the
  # network on iteration one.
  def test_the_payloads_stage_is_installed_before_the_agent_runs
    seen = nil
    result = run_case(stage: { "because" => "run A", "navigator" => [{ "direction" => "north" }] }) do
      seen = Boukensha.stage
      seed_map(1)
    end

    assert result["ok"]
    refute_nil seen, "the stage has to be in place before the turn, not after it"
    assert seen.staged?("navigator")
    refute seen.staged?("cartographer")
  end

  # §7: a staged run is not a real run and the record has to say so. The result
  # file is what the parent reads to build the report row.
  def test_the_result_says_which_tasks_were_staged_and_which_were_live
    result = run_case(stage: { "because" => "run A", "navigator" => [{ "direction" => "north" }] }) { seed_map(1) }

    assert_equal({ "navigator" => 1 }, result["stage"]["staged"])
    assert_equal %w[player cartographer judge], result["stage"]["live"]
  end

  # Which task was LIVE is the only line in a staged run that says what the run
  # measured, so a reader watching the log should not have to open the scenario.
  def test_the_stage_is_named_in_the_run_log
    log = File.join(@root, "run.log")
    run_case(stage: { "because" => "run A", "navigator" => [{ "direction" => "north" }] },
             run_log: log) { seed_map(1) }

    line = File.read(log).lines.find { |l| l.include?("stage") }

    refute_nil line
    assert_match(/navigator ×1/, line)
    assert_match(/live player, cartographer, judge/, line)
  end

  def test_an_unstaged_case_installs_nothing_and_says_nothing
    result = run_case { seed_map(1) }

    assert_nil Boukensha.stage
    refute result.key?("stage"), "an ordinary case has the shape it had before staging existed"
  end

  private

  # Runs one case with the agent's turn replaced by `agent_work`, which stands
  # in for everything a real turn does to the knowledge database.
  def run_case(settings: nil, arm: nil, run_log: nil, stage: nil, &agent_work)
    result_path = File.join(@root, "result.json")
    payload = {
      "player_profile" => "Derrano", "goal" => "find the bakery", "map_memory" => "none",
      "skip_seed" => true, "result_path" => result_path, "session_name" => "find_bakery",
      "settings" => settings, "arm" => arm, "run_log" => run_log, "stage" => stage
    }.compact

    fake_config = config
    stubbing(
      [BoukenshaLoader, :apply_profile!, ->(_name) { "Derrano" }],
      [Boukensha, :config, -> { fake_config }],
      [Boukensha::Launch, :test, ->(**) { nil }],
      # The agent's turn: it sets the session id and it writes to the knowledge
      # database, which is the whole of what retention cares about.
      [BoukenshaLoader, :run_case, lambda { |**|
        Boukensha::Operation.session_id = SESSION
        agent_work.call
      }]
    ) { Boukensha::Testing::CaseRunner.run(payload) }

    JSON.parse(File.read(result_path))
  end

  # Minitest 6 no longer ships `Object#stub`, and the four seams here are all
  # singleton methods, so this is the whole of what a mocking library would
  # have provided.
  def stubbing(*replacements)
    originals = replacements.map { |receiver, name, impl| [receiver, name, receiver.method(name), impl] }
    originals.each { |receiver, name, _original, impl| receiver.define_singleton_method(name, &impl) }
    yield
  ensure
    originals&.each { |receiver, name, original, _impl| receiver.define_singleton_method(name, original) }
  end

  # Only the paths CaseRunner reads, plus the override seam. A real Config would
  # drag settings.yaml and a provider in with it, neither of which retention has
  # an opinion about; what IS asserted about the seam is that the child calls it,
  # with what, and before anything else — Config's own test owns the merge and
  # the too-late guard.
  def config
    installed = (@installed ||= [])
    Struct.new(:root_dir, :profile_dir, :tests_dir, keyword_init: true) do
      define_method(:install_settings_overrides!) { |overrides| installed << overrides }
    end.new(root_dir: @root, profile_dir: @profile_dir, tests_dir: File.join(@root, "tests"))
  end

  def sessions_dir  = File.join(@root, "tests", "knowledge", "sessions", "Derrano")
  def retained_path = File.join(sessions_dir, "#{SESSION}.sqlite3")

  def seed_map(rooms)
    store = Boukensha::Mud::Memory::Store.for_dir(@profile_dir)
    rooms.times { |i| store.create_room(name: "Room #{i}", description: "d#{i}", weak_fingerprint: "wf#{i}") }
    store.close
  end

  def count_rooms(path)
    require "sqlite3"
    db = SQLite3::Database.new(path)
    begin
      db.execute("SELECT COUNT(*) FROM rooms").first.first.to_i
    ensure
      db.close
    end
  end
end
