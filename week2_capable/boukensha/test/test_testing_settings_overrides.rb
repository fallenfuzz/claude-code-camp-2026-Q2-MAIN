require_relative "helper"
require "boukensha/testing/fixtures"

# Per-run settings overrides and the sweep built on them — settings_sweep.md §9.
#
# The failure this whole feature has to prevent is not a crash: it is an arm that
# quietly measured nothing. `--setting tools.navigation.limits.max_decision=10`,
# singular, merges cleanly into the settings hash, is read by nothing, and
# produces a report row that looks like a measurement of a changed configuration.
# So most of what is asserted here is a refusal, and every one of them happens
# before anything is seeded.
class TestTestingSettingsOverrides < Minitest::Test
  F = Boukensha::Testing::Fixtures
  O = Boukensha::Testing::Overrides

  def setup
    @root = Dir.mktmpdir
    write_profile("Derrano", "cleric")
    write_settings
    write("states/cleric.yml", "requires_class: cleric\nlocation: 3001\nlevel: 10\n")
    write("scenarios/find_bakery_cold.yml", <<~YAML)
      session_name: find_bakery_cold
      player_profile: Derrano
      goal: "Find the bakery."
      base_initial_state: cleric
    YAML
  end

  def teardown = FileUtils.remove_entry(@root)

  def fixtures
    F.new(dir: File.join(@root, "tests"),
          profiles_dir: File.join(@root, "profiles"),
          settings_file: File.join(@root, "settings.yaml"))
  end

  # ---------- merging (§2, §2.1) --------------------------------------------

  def test_an_override_deep_merges_and_leaves_sibling_keys_alone
    kase = resolve(cli_settings: setting("tools.navigation.limits.max_decisions=10"))

    limits = kase.settings.dig("tools", "navigation", "limits")
    assert_equal 10, limits["max_decisions"]
    assert_nil limits["max_rooms"], "an override carries only what it changes"

    merged = O.deep_merge(deployment_settings, kase.settings).dig("tools", "navigation", "limits")
    assert_equal 10, merged["max_decisions"]
    assert_equal 12, merged["max_rooms"], "the deep merge must not wipe siblings"
  end

  # settings.yaml < plan defaults < plan case < --setting. Later wins, and the
  # ordering mirrors the state merge so an author who knows one knows the other.
  def test_precedence_runs_from_the_file_up_to_the_flag
    write("plans/limits.yml", <<~YAML)
      name: limits
      defaults:
        settings:
          tools: { navigation: { limits: { max_rooms: 20, max_steps_per_leg: 2 } } }
      cases:
        - scenario: find_bakery_cold
          settings:
            tools: { navigation: { limits: { max_rooms: 30 } } }
    YAML

    kase = fixtures.resolve_plan("limits", cli_settings: setting("tools.navigation.limits.max_steps_per_leg=8")).first
    limits = kase.settings.dig("tools", "navigation", "limits")

    assert_equal 30, limits["max_rooms"], "the plan case beats the plan defaults"
    assert_equal 8, limits["max_steps_per_leg"], "--setting beats them both"
  end

  # `act_on_place` is read as `!= false`, so a string "false" would silently mean
  # true — which is the whole reason the flag coerces rather than passing text on.
  def test_the_flag_coerces_scalars
    kase = resolve(cli_settings: O.parse_sets(
      ["tools.navigation.limits.max_decisions=10", "tools.navigation.act_on_place=false"],
      flag: "--setting"
    ))

    assert_equal 10, kase.settings.dig("tools", "navigation", "limits", "max_decisions")
    assert_equal false, kase.settings.dig("tools", "navigation", "act_on_place")
  end

  def test_a_bad_assignment_names_the_flag_that_was_typed
    error = assert_raises(O::Error) { O.parse_sets(["max_decisions"], flag: "--setting") }

    assert_match(/--setting expects KEY=VALUE/, error.message)
  end

  # ---------- validation (§6, §6.1) -----------------------------------------

  def test_a_misspelt_key_path_is_an_error_that_names_it
    error = assert_raises(F::Error) do
      resolve(cli_settings: setting("tools.navigation.limits.max_decision=10"))
    end

    assert_match(/tools\.navigation\.limits\.max_decision /, error.message)
    assert_match(/max_decisions/, error.message, "the keys that DO exist are one glance away")
  end

  def test_a_key_path_absent_at_its_root_is_refused_too
    error = assert_raises(F::Error) { resolve(cli_settings: setting("toosl.navigation.act_on_place=false")) }

    assert_match(/toosl\.navigation\.act_on_place/, error.message)
  end

  # `mcp_servers` carries the MUD host, the port and the character being logged
  # in as. A case that could rewrite it could play as somebody else while the
  # report went on naming the profile it thought it was measuring.
  def test_touching_mcp_servers_is_refused_outright
    error = assert_raises(F::Error) { resolve(cli_settings: setting("mcp_servers.mud.env.MUD_HOST=elsewhere")) }

    assert_match(/mcp_servers/, error.message)
    assert_match(/logged in as/, error.message)
  end

  def test_the_axes_the_feature_exists_for_are_allowed
    %w[
      tools.navigation.limits.max_decisions=10
      tools.navigation.act_on_place=false
      tasks.navigator.model=claude-sonnet-4-6
      tasks.cartographer.model=claude-sonnet-4-6
      memory.turn_policy=true
    ].each do |assignment|
      kase = resolve(cli_settings: setting(assignment))
      refute_empty kase.settings, "#{assignment} names a key that exists and must resolve"
    end
  end

  # Legitimate, and it changes the agent under test in a way a reader skimming a
  # report would not expect from a scenario name.
  def test_overriding_memory_or_the_agent_block_is_allowed_with_a_warning
    subject = fixtures
    subject.resolve_scenario("find_bakery_cold", cli_settings: setting("memory.turn_policy=true"))

    assert_match(/memory/, subject.warnings.join(" "))
  end

  def test_a_scenario_may_not_change_the_configuration_it_is_measured_under
    write("scenarios/opinionated.yml", <<~YAML)
      player_profile: Derrano
      goal: "Find the bakery."
      settings:
        tools: { navigation: { limits: { max_decisions: 99 } } }
    YAML

    error = assert_raises(F::Error) { fixtures.scenario("opinionated") }

    assert_match(/only a plan or --setting/, error.message)
  end

  # `Config#dig` answers nil for an absent key and every reader has a default, so
  # the deployment's own file is the only thing there is to check a path against.
  def test_an_override_with_no_settings_file_to_check_against_says_so
    FileUtils.rm(File.join(@root, "settings.yaml"))

    error = assert_raises(F::Error) { resolve(cli_settings: setting("tasks.navigator.model=x")) }

    assert_match(/does not exist/, error.message)
  end

  # ---------- sweep expansion (§3.3) ----------------------------------------

  def test_two_axes_expand_to_the_cartesian_product_of_their_values
    write_sweep
    cases = fixtures.resolve_plan("navigation_limits")

    assert_equal 6, cases.map(&:arm).uniq.size, "three decisions × two models"
    assert_equal 12, cases.size, "every arm carries every case in the plan, batched"
  end

  def test_every_arm_is_labelled_by_its_axis_values
    write_sweep
    arms = fixtures.resolve_plan("navigation_limits").map(&:arm).uniq

    assert_includes arms, "max_decisions=4 model=claude-haiku-4-5"
    assert_includes arms, "max_decisions=10 model=claude-sonnet-4-6"
    assert_equal arms.uniq.size, arms.size, "a label that cannot tell two arms apart is no label"
  end

  def test_an_arms_label_reaches_its_session_names
    write_sweep
    names = fixtures.resolve_plan("navigation_limits").map(&:session_name)

    assert_includes names, "find_bakery_cold (max_decisions=4 model=claude-haiku-4-5) #1"
  end

  # `tasks.navigator.model` and `tasks.cartographer.model` share a last segment,
  # and an arm label that reads `model=x model=y` names neither of them.
  def test_axes_sharing_a_last_segment_fall_back_to_the_whole_path
    write("plans/models.yml", <<~YAML)
      name: models
      sweep:
        tasks.navigator.model:    [claude-haiku-4-5]
        tasks.cartographer.model: [claude-sonnet-4-6]
      cases:
        - scenario: find_bakery_cold
    YAML

    assert_equal ["tasks.navigator.model=claude-haiku-4-5 tasks.cartographer.model=claude-sonnet-4-6"],
                 fixtures.resolve_plan("models").map(&:arm)
  end

  def test_an_axis_value_reaches_the_arms_settings_as_a_nested_override
    write_sweep
    kase = fixtures.resolve_plan("navigation_limits").first

    assert_equal 4, kase.settings.dig("tools", "navigation", "limits", "max_decisions")
    assert_equal 12, kase.settings.dig("tools", "navigation", "limits", "max_rooms"),
                 "the plan's own defaults still apply underneath every arm"
  end

  # A sweep IS the arm, so an axis wins over a `settings:` the case wrote itself.
  def test_a_sweep_axis_beats_a_settings_block_on_the_same_case
    write("plans/both.yml", <<~YAML)
      name: both
      sweep:
        tools.navigation.limits.max_decisions: [10]
      cases:
        - scenario: find_bakery_cold
          settings:
            tools: { navigation: { limits: { max_decisions: 4, max_rooms: 20 } } }
    YAML

    settings = fixtures.resolve_plan("both").first.settings.dig("tools", "navigation", "limits")

    assert_equal 10, settings["max_decisions"]
    assert_equal 20, settings["max_rooms"], "the case's other keys survive"
  end

  def test_a_sweep_axis_that_is_not_a_list_of_values_is_refused
    write("plans/scalar.yml", "name: scalar\nsweep:\n  tools.navigation.limits.max_rooms: 12\ncases:\n  - scenario: find_bakery_cold\n")

    error = assert_raises(F::Error) { fixtures.plan("scalar") }

    assert_match(/non-empty list/, error.message)
  end

  def test_a_misspelt_axis_is_refused_like_any_other_override
    write("plans/typo.yml", <<~YAML)
      name: typo
      sweep:
        tools.navigation.limits.max_decision: [4, 10]
      cases:
        - scenario: find_bakery_cold
    YAML

    assert_raises(F::Error) { fixtures.resolve_plan("typo") }
  end

  # Region declarations are earned and never overwritten, so an arm running with
  # `keep` inherits whatever the arm before it wrote. §8.5.
  def test_a_sweep_that_accumulates_map_memory_is_warned_about
    write("plans/warm.yml", <<~YAML)
      name: warm
      defaults:
        map_memory: keep
      sweep:
        tools.navigation.limits.max_decisions: [4, 10]
      cases:
        - scenario: find_bakery_cold
    YAML

    subject = fixtures
    subject.resolve_plan("warm")

    assert_match(/map_memory: keep/, subject.warnings.join(" "))
  end

  def test_a_plan_with_no_sweep_resolves_to_one_unlabelled_arm
    write("plans/plain.yml", "name: plain\ncases:\n  - { scenario: find_bakery_cold, batch: 2 }\n")

    cases = fixtures.resolve_plan("plain")

    assert_equal ["default"], cases.map(&:arm).uniq
    assert_equal ["find_bakery_cold #1", "find_bakery_cold #2"], cases.map(&:session_name)
  end

  # A hand-written §3.2 plan has arms too, and the report has to be able to group
  # by them without a session name an author typed.
  def test_hand_written_arms_are_labelled_from_their_overrides
    write("plans/pair.yml", <<~YAML)
      name: pair
      cases:
        - scenario: find_bakery_cold
          session_name: "decisions 4"
          settings: { tools: { navigation: { limits: { max_decisions: 4 } } } }
        - scenario: find_bakery_cold
          session_name: "decisions 10"
          settings: { tools: { navigation: { limits: { max_decisions: 10 } } } }
    YAML

    cases = fixtures.resolve_plan("pair")

    assert_equal ["tools.navigation.limits.max_decisions=4",
                  "tools.navigation.limits.max_decisions=10"], cases.map(&:arm)
    assert_equal ["decisions 4", "decisions 10"], cases.map(&:session_name),
                 "an author who named their arms is left alone"
  end

  # ---------- the payload (§10 step 1) --------------------------------------

  def test_the_override_travels_in_the_case_payload_and_an_empty_one_does_not
    require "boukensha/testing/runner"
    runner = Boukensha::Testing::Runner.new(root_dir: @root)

    swept = resolve(cli_settings: setting("tools.navigation.limits.max_decisions=10"))
    plain = resolve

    payload = runner.payloads([swept], run_id: "r1").first
    assert_equal 10, payload.dig("settings", "tools", "navigation", "limits", "max_decisions")
    assert_equal swept.arm, payload["arm"]

    refute runner.payloads([plain], run_id: "r1").first.key?("settings"),
           "an empty override ships as absent rather than as {}"
  end

  private

  def resolve(cli_settings: {})
    fixtures.resolve_scenario("find_bakery_cold", cli_settings: cli_settings).first
  end

  def setting(assignment) = O.parse_sets([assignment], flag: "--setting")

  def deployment_settings = O.normalize(YAML.safe_load(File.read(File.join(@root, "settings.yaml"))))

  def write_sweep
    write("plans/navigation_limits.yml", <<~YAML)
      name: navigation_limits
      defaults:
        settings:
          tools: { navigation: { limits: { max_rooms: 12 } } }
      sweep:
        tools.navigation.limits.max_decisions: [4, 6, 10]
        tasks.navigator.model: [claude-haiku-4-5, claude-sonnet-4-6]
      cases:
        - scenario: find_bakery_cold
          batch: 2
    YAML
  end

  # The shape of the deployment's own settings.yaml, cut down to the keys these
  # assertions address. The key-path check is against THIS, which is the whole
  # of §6.1: settings are not a closed set, so the file is the schema.
  def write_settings
    File.write(File.join(@root, "settings.yaml"), <<~YAML)
      memory:
        turn_policy: false
      tools:
        navigation:
          allow:
            - tbamud__move
          limits:
            max_rooms: 12
            max_decisions: 6
            max_steps_per_leg: 4
            min_rooms_for_scope_check: 3
          act_on_place: true
      tasks:
        navigator:
          provider: anthropic
          model: claude-haiku-4-5
        cartographer:
          provider: anthropic
          model: claude-haiku-4-5
        player:
          provider: anthropic
          model: claude-haiku-4-5
          allow:
            - move_to
      mcp_servers:
        mud:
          command: mud-manager
          env:
            MUD_HOST: localhost
    YAML
  end

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
