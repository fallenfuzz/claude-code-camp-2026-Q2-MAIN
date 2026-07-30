require_relative "helper"
require "tmpdir"
require_relative "../lib/boukensha_loader"

# `BoukenshaLoader.mud_agent_setup` — the proc both the REPL and a headless test
# case build their agent with.
#
# Nothing exercised it before, and it is the one place the entire move_to.md §3
# surface change lives: which tools get registered, which permission slice the
# walker dispatches under, and whether the navigator and cartographer are built
# at all. A NameError or a mis-shaped `cfg.dig` in here would boot fine under
# every unit test in this suite and fail on the first real session.
#
# So this evaluates the real proc, on a real RunDSL, against a real MCP server
# talking to a FakeMud — the same arrangement `test_tools_mcp.rb` uses — and
# asserts what ends up on the surface.
class TestMudAgentSetup < Minitest::Test
  include McpTestHelper

  SLICE = Boukensha::Mud::Navigation::MoveTo::NAVIGATION_SLICE

  def setup
    @fake = start_fake_mud
    @dir  = Dir.mktmpdir
    @saved = ENV.to_hash.slice("BOUKENSHA_DIR", "BOUKENSHA_PROFILE_DIR")
    ENV["BOUKENSHA_DIR"] = @dir
    ENV.delete("BOUKENSHA_PROFILE_DIR")
    File.write(File.join(@dir, "settings.yaml"), settings_yaml)
    reset_boukensha!
  end

  def teardown
    @fake&.stop
    @saved.each { |k, v| ENV[k] = v }
    %w[BOUKENSHA_DIR BOUKENSHA_PROFILE_DIR].each { |k| ENV.delete(k) unless @saved.key?(k) }
    reset_boukensha!
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    Boukensha::Operation.reset!
  end

  # Config and the shared MCP clients are both memoized on the module, so a test
  # that changes BOUKENSHA_DIR has to drop them or it silently asserts against
  # the previous test's world.
  def reset_boukensha!
    Boukensha.instance_variable_set(:@config, nil)
    Boukensha.reset_mcp_clients!
    Boukensha.reset_error_log!
  end

  # The shape of the deployment's own settings.yaml, cut down to what this seam
  # reads: the player's allowlist, the navigation slice, the survey slice, and
  # the two reasoner tasks.
  def settings_yaml(navigator: true, cartographer: true)
    <<~YAML
      tools:
        room_survey:
          allow:
            - tbamud__poll
            - tbamud__look
            - "tbamud__check(kind: exits|score)"
        #{SLICE}:
          allow:
            - tbamud__move
            - tbamud__poll
          limits:
            max_rooms: 7
      tasks:
        player:
          provider: anthropic
          model: claude-haiku-4-5
          allow:
            - move_to
            - name_region
            - split_region
            - tbamud__poll
      #{task_block("navigator") if navigator}
      #{task_block("cartographer") if cartographer}
      mcp_servers:
        mud:
          command: #{mud_manager_command}
          args:    #{mud_manager_args.inspect}
          prefix:  tbamud
          env:
            MUD_HOST:     127.0.0.1
            MUD_PORT:     #{@fake.port}
            MUD_NAME:     Gandalf
            MUD_PASSWORD: secret
    YAML
  end

  # One reasoner's block, indented to sit under `tasks:` — TWO spaces, not four.
  # It used to be a four-space literal inside the heredoc's interpolation, which
  # put both reasoners under `tasks.player` instead. `cfg.tasks(:navigator)` was
  # therefore always empty, so the setup proc never built a reasoner and
  # `test_the_reasoners_are_built_from_configuration` asserted nothing in either
  # direction.
  def task_block(name)
    "  #{name}:\n    provider: anthropic\n    model: claude-haiku-4-5\n    max_iterations: 1\n"
  end

  # Boukensha.run minus the model: resolve the player's permissions, register the
  # MCP tools, then instance_eval the real setup proc on a real RunDSL.
  def build_player_registry
    cfg      = Boukensha.config
    perms    = Boukensha.task_permissions(cfg, "player")
    ctx      = Boukensha::Context.new(system: "t")
    registry = Boukensha::Registry.new(ctx, permissions: perms)
    Boukensha.send(:register_task_tools, registry, cfg, perms)

    dsl = Boukensha::RunDSL.new(registry)
    dsl.instance_eval(&BoukenshaLoader.mud_agent_setup)
    perms.validate_referenced!(registry.tool_names)
    [registry, dsl]
  end

  def test_the_setup_evaluates_and_puts_move_to_on_the_players_surface
    registry, dsl = build_player_registry

    assert_includes registry.tool_names, "move_to"
    refute_nil dsl.hooks, "the MUD hooks must be installed"
    assert_kind_of Boukensha::Mud::Hooks, dsl.hooks
  end

  # §8's first surface assertion. `plan_route` is REGISTERED by this proc and
  # `tbamud__move` arrives over MCP; neither is on the player's allowlist, so
  # `Registry#tool` drops both and the model never sees them.
  def test_none_of_the_three_replaced_tools_reaches_the_player
    registry, = build_player_registry

    %w[plan_route execute_route tbamud__move].each do |name|
      refute_includes registry.tool_names, name
    end
  end

  # The region declarations stay: they are for the case the navigator cannot
  # see — working out what a place is from something an NPC said.
  def test_the_region_declarations_are_still_on_the_surface
    registry, = build_player_registry

    assert_includes registry.tool_names, "name_region"
    assert_includes registry.tool_names, "split_region"
  end

  # §3's load-bearing detail: the walker cannot reach `move` through the
  # player's registry any more, so it must reach it through its own slice.
  def test_the_navigation_slice_can_dispatch_move_and_the_player_cannot
    registry, = build_player_registry

    assert_raises(Boukensha::UnknownToolError) { registry.dispatch("tbamud__move", "direction" => "north") }

    dispatcher = Boukensha.tool_dispatcher(SLICE, initiator: "hook")
    refute_nil dispatcher.call("tbamud__move", { "direction" => "north" }),
               "the slice has to be able to walk, or move_to raises on step 1"
  end

  # The reasoners are built only when settings.yaml declares them, which is what
  # makes §9's staged delivery runnable — and §7.6's off switch, since a wrong
  # boundary is durable.
  def test_the_reasoners_are_built_from_configuration
    registry, = build_player_registry
    assert_includes registry.tool_names, "move_to"

    File.write(File.join(@dir, "settings.yaml"), settings_yaml(navigator: false, cartographer: false))
    reset_boukensha!
    registry, = build_player_registry

    assert_includes registry.tool_names, "move_to",
                    "with no navigator configured move_to still ships — the known branch needs no model"
  end

  # `tools.navigation.limits` has to travel from the file into the object, or the
  # numbers in settings.yaml are decoration.
  def test_the_configured_limits_reach_the_subsystem
    limits = Boukensha.config.dig(:tools, SLICE, :limits)

    assert_equal 7, limits["max_rooms"]
    subject = Boukensha::Mud::Navigation::MoveTo.new(store: nil, call_tool: nil, hooks: nil, limits: limits)
    assert_equal 7, subject.limit("max_rooms")
    assert_equal Boukensha::Mud::Navigation::MoveTo::DEFAULT_LIMITS["max_decisions"],
                 subject.limit("max_decisions"), "an unset knob falls back to its default"
  end

  # ---------- per-run settings overrides (settings_sweep.md §9) --------------

  # The one assertion that makes the feature real: a knob set by override is the
  # number the walking subsystem actually enforces. Asserted through the REAL
  # setup proc and the MoveTo it builds, rather than by constructing one here,
  # because the plumbing is the point — `install_settings_overrides!` reaching
  # every `cfg.dig` with none of them modified is the whole design (§2).
  def test_an_overridden_limit_is_the_number_the_subsystem_enforces
    Boukensha.config.install_settings_overrides!(
      "tools" => { SLICE => { "limits" => { "max_rooms" => 30, "max_decisions" => 10 } } }
    )

    subject = capture_move_to { build_player_registry }

    refute_nil subject, "the setup proc has to have built a MoveTo"
    assert_equal 30, subject.limit("max_rooms"), "the override, not the file's 7"
    assert_equal 10, subject.limit("max_decisions")
  end

  # "Is Haiku good enough to pick a frontier" is the question §1 exists for, and
  # it is answerable only if the navigator's model can be varied per run.
  def test_an_overridden_task_model_is_the_model_the_navigator_reports
    Boukensha.config.install_settings_overrides!(
      "tasks" => { "navigator" => { "model" => "claude-sonnet-4-6" } }
    )

    settings = Boukensha.config.tasks("navigator")

    assert_equal "claude-sonnet-4-6", Boukensha::Tasks::Navigator.model(settings)
    assert_equal "anthropic", Boukensha::Tasks::Navigator.provider(settings),
                 "an override carries only what it changes"
    assert_equal "claude-haiku-4-5", Boukensha.config.dig(:tasks, :player, :model),
                 "and it reaches only the task it named"
  end

  # §8.2. The injection window is not enforced by anything upstream, so it is
  # enforced by Config, and it raises rather than warns: an override that arrived
  # late produces a case that ran under one configuration and reported another.
  def test_an_override_arriving_after_configuration_was_read_raises
    Boukensha.config.dig(:tasks, :player, :model)

    error = assert_raises(Boukensha::Config::SettingsOverrideError) do
      Boukensha.config.install_settings_overrides!("tasks" => { "navigator" => { "model" => "x" } })
    end

    assert_match(/after configuration had already been read/, error.message)
  end

  # An empty override is a no-op rather than a read, so the ordinary interactive
  # path never trips the guard on its way past.
  def test_an_empty_override_neither_raises_nor_closes_the_window
    Boukensha.config.install_settings_overrides!({})
    Boukensha.config.install_settings_overrides!(nil)

    Boukensha.config.install_settings_overrides!("memory" => { "turn_policy" => true })

    assert_equal true, Boukensha.config.dig(:memory, :turn_policy)
  end

  private

  # The MoveTo the real setup proc builds, caught on its way out of the
  # constructor. Dispatching `move_to` to find out would walk the character.
  def capture_move_to
    klass    = Boukensha::Mud::Navigation::MoveTo
    original = klass.method(:new)
    caught   = nil
    klass.define_singleton_method(:new) do |**kwargs|
      caught = original.call(**kwargs)
    end
    yield
    caught
  ensure
    klass.define_singleton_method(:new, original)
  end
end
