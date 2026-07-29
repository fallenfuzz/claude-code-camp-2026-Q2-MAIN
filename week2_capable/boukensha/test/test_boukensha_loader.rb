require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../lib/boukensha_loader"

class BoukenshaLoaderTest < Minitest::Test
  def setup
    @original_home = ENV["HOME"]
    @original_path = ENV["BOUKENSHA_PATH"]
    @original_dir = ENV["BOUKENSHA_DIR"]
    @home = Dir.mktmpdir
    ENV["HOME"] = @home
    ENV.delete("BOUKENSHA_PATH")
    ENV.delete("BOUKENSHA_DIR")
  end

  def teardown
    ENV["HOME"] = @original_home
    restore_env("BOUKENSHA_PATH", @original_path)
    restore_env("BOUKENSHA_DIR", @original_dir)
    FileUtils.remove_entry(@home)
  end

  def test_yaml_configures_implementation_and_runtime_directory
    step = make_step("configured-step")
    write_rc(<<~YAML)
      boukensha_path: #{step}
      boukensha_dir: config
    YAML

    assert_equal File.join(step, "lib", "boukensha.rb"), BoukenshaLoader.resolve
    assert_equal File.join(@home, "config"), ENV["BOUKENSHA_DIR"]
  end

  def test_environment_variables_override_rc_values
    rc_step = make_step("rc-step")
    env_step = make_step("env-step")
    write_rc("boukensha_path: #{rc_step}\nboukensha_dir: rc-config\n")
    ENV["BOUKENSHA_PATH"] = env_step
    ENV["BOUKENSHA_DIR"] = "/explicit/config"

    assert_equal File.join(env_step, "lib", "boukensha.rb"), BoukenshaLoader.resolve
    assert_equal "/explicit/config", ENV["BOUKENSHA_DIR"]
  end

  def test_legacy_single_path_format_is_supported
    step = make_step("legacy-step")
    write_rc("#{step}\n")

    assert_equal File.join(step, "lib", "boukensha.rb"), BoukenshaLoader.resolve
  end

  def test_empty_config_uses_bundled_implementation
    write_rc("")

    assert_equal BoukenshaLoader::BUNDLED_LIB, BoukenshaLoader.resolve
  end

  # The test flags are extracted from ARGV before anything is required, so the
  # branch is decided without loading the framework — which also makes it the
  # one place a flag can go missing without anything failing.
  def test_snapshot_map_carries_profile_and_from_session
    args = with_argv(%w[--snapshot-map midgaard --profile Derrano --from-session 20260729T183933Z-4caca6d5]) do
      BoukenshaLoader.extract_test_arguments
    end

    assert_equal :snapshot_map, args[:mode]
    assert_equal "midgaard", args[:name]
    assert_equal "Derrano", args[:profile]
    assert_equal "20260729T183933Z-4caca6d5", args[:from_session]
  end

  def test_snapshot_map_without_from_session_still_pins_the_live_map
    args = with_argv(%w[--snapshot-map bakery_known --profile Dummy]) { BoukenshaLoader.extract_test_arguments }

    assert_nil args[:from_session]
  end

  def test_map_memory_accepts_a_session_mode
    args = with_argv(%w[-ts find_bakery --map-memory session:20260729T183933Z-4caca6d5]) do
      BoukenshaLoader.extract_test_arguments
    end

    assert_equal "session:20260729T183933Z-4caca6d5", args[:map_memory]
  end

  # ---------- scenario limits reach the agent (move_to.md §4.5) -------------
  #
  # These four are the guard on a gap that was invisible for as long as it
  # existed: a scenario's `limits:` block was logged by the case runner and
  # asserted against by the expectations, and never passed to the agent — so
  # `find_bakery.yml`'s `max_iterations: 15` produced runs of 16, 17 and 19
  # under the settings.yaml default of 25.

  def test_run_case_passes_scenario_limits_through_to_the_agent
    captured = capture_run_kwargs do
      BoukenshaLoader.run_case(goal: "Find the bakery.",
                               limits: { "max_iterations" => 15, "max_turn_tokens" => 40_000,
                                         "wall_timeout_s" => 240 })
    end

    assert_equal 15, captured[:max_iterations]
    assert_equal 40_000, captured[:max_turn_tokens]
  end

  # `wall_timeout_s` is the PARENT's limit (Testing::Runner kills the child
  # process on it) and must never be mistaken for an agent ceiling.
  def test_run_case_ignores_the_parent_owned_wall_timeout
    captured = capture_run_kwargs do
      BoukenshaLoader.run_case(goal: "g", limits: { "wall_timeout_s" => 240 })
    end

    assert_nil captured[:max_iterations]
    assert_nil captured[:max_turn_tokens]
  end

  # nil, not 0. `Agent` reads 0 as "no ceiling", so passing a missing limit on
  # as a zero would REMOVE the ceiling a caller meant to leave alone.
  def test_run_case_with_no_limits_leaves_the_configured_defaults_alone
    captured = capture_run_kwargs { BoukenshaLoader.run_case(goal: "g") }

    assert_nil captured[:max_iterations]
    assert_nil captured[:max_turn_tokens]
  end

  # Same reasoning as above, one step further: a typo'd budget must fall back to
  # the default rather than disable the ceiling it was trying to tighten.
  def test_a_non_integer_limit_falls_back_to_the_default
    captured = nil
    _out, err = capture_io do
      captured = capture_run_kwargs do
        BoukenshaLoader.run_case(goal: "g", limits: { "max_iterations" => "fifteen" })
      end
    end

    assert_nil captured[:max_iterations]
    assert_match(/limits\.max_iterations/, err)
  end

  private

  # Stub `Boukensha.run` and hand back the keywords it was called with. The MUD
  # setup block is never evaluated, so this needs no MUD, no MCP and no store.
  def capture_run_kwargs
    require_relative "../lib/boukensha"
    captured = {}
    Boukensha.singleton_class.alias_method(:__run_without_capture, :run)
    Boukensha.define_singleton_method(:run) do |**kwargs, &_block|
      captured = kwargs
      nil
    end
    yield
    captured
  ensure
    Boukensha.singleton_class.alias_method(:run, :__run_without_capture)
    Boukensha.singleton_class.remove_method(:__run_without_capture)
  end

  def with_argv(argv)
    original = ARGV.dup
    ARGV.replace(argv)
    yield
  ensure
    ARGV.replace(original)
  end

  def make_step(name)
    step = File.join(@home, name)
    FileUtils.mkdir_p(File.join(step, "lib"))
    FileUtils.touch(File.join(step, "lib", "boukensha.rb"))
    step
  end

  def write_rc(contents)
    File.write(File.join(@home, ".boukensharc"), contents)
  end

  def restore_env(name, value)
    value ? ENV[name] = value : ENV.delete(name)
  end
end
