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

  private

  # Runs one case with the agent's turn replaced by `agent_work`, which stands
  # in for everything a real turn does to the knowledge database.
  def run_case(&agent_work)
    result_path = File.join(@root, "result.json")
    payload = {
      "player_profile" => "Derrano", "goal" => "find the bakery", "map_memory" => "none",
      "skip_seed" => true, "result_path" => result_path, "session_name" => "find_bakery"
    }

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

  # Only the four paths CaseRunner reads. A real Config would drag settings.yaml
  # and a provider in with it, neither of which retention has an opinion about.
  def config
    Struct.new(:root_dir, :profile_dir, :tests_dir, keyword_init: true)
          .new(root_dir: @root, profile_dir: @profile_dir, tests_dir: File.join(@root, "tests"))
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
