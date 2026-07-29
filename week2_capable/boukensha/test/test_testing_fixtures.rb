require_relative "helper"
require "boukensha/testing/fixtures"

# Loading and validation. Every assertion here is a failure that would otherwise
# surface minutes into a batch, as a refusal deep inside a telnet exchange.
class TestTestingFixtures < Minitest::Test
  F = Boukensha::Testing::Fixtures

  def setup
    @root = Dir.mktmpdir
    write_profile("Derrano", "cleric")
    write_profile("Dummy", "warrior")
    write("states/cleric.yml", <<~YAML)
      requires_class: cleric
      location: 3001
      level: 10
      money: { gold: 5000, bank: 10000 }
      inventory:
        - { vnum: 3001, keyword: bottle, quantity: 2 }
    YAML
    write("scenarios/find_bakery.yml", <<~YAML)
      session_name: find_bakery
      player_profile: Derrano
      goal: "Find the bakery."
      base_initial_state: cleric
      initial_state_overrides:
        money: { gold: 0 }
    YAML
  end

  def teardown = FileUtils.remove_entry(@root)

  def fixtures = F.new(dir: File.join(@root, "tests"), profiles_dir: File.join(@root, "profiles"))

  # ---------- loading ----------------------------------------------------

  def test_lists_what_is_on_disk
    assert_equal %w[find_bakery], fixtures.scenario_names
    assert_equal %w[cleric], fixtures.state_names
  end

  def test_resolves_a_scenario_through_the_override_chain
    kase = fixtures.resolve_scenario("find_bakery").first

    assert_equal "find_bakery", kase.session_name
    assert_equal "Derrano", kase.player_profile
    assert_equal 0, kase.state.dig("money", "gold")
    assert_equal 10_000, kase.state.dig("money", "bank"), "the deep merge must not wipe siblings"
    assert_equal "none", kase.map_memory, "tests default to a cold map"
  end

  def test_a_batch_of_one_keeps_the_bare_name
    assert_equal "find_bakery", fixtures.resolve_scenario("find_bakery", batch: 1).first.session_name
  end

  def test_a_batch_suffixes_each_case
    names = fixtures.resolve_scenario("find_bakery", batch: 3).map(&:session_name)

    assert_equal ["find_bakery #1", "find_bakery #2", "find_bakery #3"], names
  end

  # ---------- validation ---------------------------------------------------

  def test_a_state_setting_class_or_gender_is_rejected
    write("states/bad.yml", "class: cleric\ngender: m\nlevel: 1\n")

    error = assert_raises(F::Error) { fixtures.state("bad") }

    assert_match(/profile.yaml/, error.message)
  end

  def test_requires_class_mismatch_names_the_profile
    error = assert_raises(F::Error) { fixtures.resolve_scenario("find_bakery", profile: "Dummy") }

    assert_match(/requires_class "cleric"/, error.message)
    assert_match(/"Dummy"/, error.message)
    assert_match(/"warrior"/, error.message)
  end

  def test_an_unknown_state_names_the_directory_it_searched
    write("scenarios/lost.yml", "goal: g\nplayer_profile: Derrano\nbase_initial_state: nowhere\n")

    error = assert_raises(F::Error) { fixtures.resolve_scenario("lost") }

    assert_match(%r{states}, error.message)
    assert_match(/available: cleric/, error.message)
  end

  def test_a_scenario_without_a_goal_is_rejected
    write("scenarios/empty.yml", "player_profile: Derrano\n")

    assert_raises(F::Error) { fixtures.scenario("empty") }
  end

  def test_a_bad_location_is_rejected_before_anything_is_seeded
    write("states/floor1.yml", "requires_class: cleric\nlocation: 1\nlevel: 1\n")
    write("scenarios/floor.yml", "goal: g\nplayer_profile: Derrano\nbase_initial_state: floor1\n")

    # A vnum of 1 is legal on its face, so this asserts the shape check rather
    # than a guess about the world: a string or a zero is what gets caught.
    write("states/floor2.yml", "requires_class: cleric\nlocation: 0\nlevel: 1\n")
    write("scenarios/floor2.yml", "goal: g\nplayer_profile: Derrano\nbase_initial_state: floor2\n")

    assert fixtures.resolve_scenario("floor").first
    assert_raises(F::Error) { fixtures.resolve_scenario("floor2") }
  end

  def test_an_unknown_map_memory_mode_is_rejected
    error = assert_raises(F::Error) { fixtures.resolve_scenario("find_bakery", map_memory: "warm") }

    assert_match(/copy:<profile>/, error.message)
  end

  def test_a_session_map_memory_carries_the_id_through
    kase = fixtures.resolve_scenario("find_bakery", map_memory: "session:20260729T183933Z-4caca6d5").first

    assert_equal "session:20260729T183933Z-4caca6d5", kase.map_memory
  end

  # Refused HERE, before anything is seeded, for the same reason a mistyped
  # scenario name is: finding out in case 19 costs eighteen real runs.
  def test_a_session_id_that_is_not_one_is_rejected_at_resolution
    error = assert_raises(F::Error) { fixtures.resolve_scenario("find_bakery", map_memory: "session:yesterday") }

    assert_match(/not a session id/, error.message)
  end

  # ---------- plans ---------------------------------------------------------

  def test_a_plan_referencing_a_missing_scenario_fails_before_anything_is_seeded
    write("plans/broken.yml", "name: broken\ncases:\n  - scenario: no_such_thing\n    batch: 5\n")

    error = assert_raises(F::Error) { fixtures.plan("broken") }

    assert_match(/no_such_thing/, error.message)
  end

  def test_plan_defaults_sit_under_each_cases_own_keys
    write("scenarios/other.yml", "goal: g\nplayer_profile: Derrano\nbase_initial_state: cleric\n")
    write("plans/suite.yml", <<~YAML)
      name: suite
      defaults:
        player_profile: Derrano
        map_memory: none
      cases:
        - { scenario: find_bakery, batch: 2 }
        - { scenario: other, batch: 1, map_memory: keep }
    YAML

    cases = fixtures.resolve_plan("suite")

    assert_equal 3, cases.size
    assert_equal %w[none none keep], cases.map(&:map_memory)
  end

  # `base_initial_state` is CHOSEN, not merged: a later layer discards the
  # earlier file wholesale, and only the overrides accumulate.
  def test_a_later_base_initial_state_discards_the_earlier_file
    write("states/wealthy.yml", "requires_class: cleric\nlocation: 3001\nlevel: 10\nmoney: { gold: 25000, bank: 0 }\n")
    write("plans/rich.yml", <<~YAML)
      name: rich
      cases:
        - scenario: find_bakery
          batch: 1
          base_initial_state: wealthy
    YAML

    kase = fixtures.resolve_plan("rich").first

    assert_equal "wealthy", kase.base_initial_state
    assert_equal 0, kase.state.dig("money", "bank"), "the wealthy file's bank, not the cleric file's"
    assert_equal 0, kase.state.dig("money", "gold"), "the scenario's override still applies on top"
  end

  private

  def write(relative, body)
    path = File.join(@root, "tests", relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def write_profile(name, klass)
    path = File.join(@root, "profiles", name, "profile.yaml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "player:\n  name: #{name}\n  gender: m\n  class: #{klass}\n")
  end
end
