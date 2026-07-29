require_relative "helper"
require "yaml"

# move_to.md §8 "Surface": the claim that `move_to` is the ONLY movement tool the
# player can call, checked against the deployment's REAL settings.yaml rather
# than against a fixture — because the whole point of §3 is a change to that
# file, and a test that wrote its own YAML would pass happily while the shipped
# config said something else.
#
# It reads the file rather than building a `Config`, for two reasons.
# `Config.new` loads the deployment's `.env` into this process's ENV, which a
# test has no business doing; and `Config` resolves its directory from
# BOUKENSHA_DIR, which the test process does not set — so every assertion here
# would skip, and a surface test that always skips guards nothing.
class TestMoveToSurface < Minitest::Test
  SLICE = Boukensha::Mud::Navigation::MoveTo::NAVIGATION_SLICE

  # The repo's own config directory, two levels up from the gem: weeks 2 and 3
  # share a folder and the deployment settings sit beside them.
  SETTINGS = File.expand_path("../../../.boukensha/settings.yaml", __dir__)

  def setup
    skip "no deployment settings.yaml at #{SETTINGS}" unless File.exist?(SETTINGS)

    @settings = YAML.safe_load(File.read(SETTINGS)) || {}
    @allow    = dig("tasks", "player", "allow")
    skip "no tasks.player.allow configured" if @allow.nil? || @allow.empty?
  end

  def dig(*keys) = keys.reduce(@settings) { |node, k| node.is_a?(Hash) ? node[k] : nil }

  def task(name) = dig("tasks", name) || {}

  def rules(list) = Array(list).map { |r| r.to_s.split("(").first.strip }

  def test_move_to_is_on_the_players_surface
    assert_includes rules(@allow), "move_to"
  end

  # The three tools it replaced. `plan_route` is still registered natively and
  # `tbamud__move` still arrives over MCP; neither is on this list, so
  # `Registry#tool` never puts them on the model's surface.
  def test_the_three_tools_it_replaced_are_not
    %w[plan_route execute_route tbamud__move].each do |name|
      refute_includes rules(@allow), name,
                      "#{name} on the player's surface reintroduces the fork move_to exists to remove"
    end
  end

  # §3. `tbamud__move` could not simply be deleted: the walker used to dispatch
  # through the PLAYER's registry, so dropping the rule would make
  # `Registry#tool` never register `move` and the walk would raise
  # UnknownToolError on step 1. It has to live somewhere, and this is where.
  def test_the_navigation_slice_grants_move_and_poll
    allow = rules(dig("tools", SLICE, "allow"))

    assert_includes allow, "tbamud__move"
    assert_includes allow, "tbamud__poll", "the walk polls between steps"
  end

  # The precedent this follows: `tbamud__look` is granted to the room survey and
  # appears nowhere on the player's surface.
  def test_the_slice_follows_the_room_survey_precedent
    survey = rules(dig("tools", Boukensha::Mud::RoomSurvey::NAME, "allow"))

    assert_includes survey, "tbamud__look"
    refute_includes rules(@allow), "tbamud__look"
  end

  # §4.2. The four knobs exist as configuration, not as constants in Ruby,
  # because "how far is too far" is a question the batch harness answers and it
  # can only sweep them if they are settings.
  def test_every_limit_is_configuration_and_reaches_the_subsystem
    limits = dig("tools", SLICE, "limits")
    refute_nil limits, "tools.#{SLICE}.limits is missing"

    subject = Boukensha::Mud::Navigation::MoveTo.new(
      store: nil, call_tool: nil, hooks: nil, limits: limits
    )
    Boukensha::Mud::Navigation::MoveTo::DEFAULT_LIMITS.each_key do |key|
      assert_equal Integer(limits[key]), subject.limit(key),
                   "tools.#{SLICE}.limits.#{key} is not reaching the subsystem"
    end
  end

  # §4.2 / §8. `tasks.navigator.max_iterations` is read from settings, not
  # hardcoded — and it is 1, which is what keeps the navigator a judgement rather
  # than a second agent: it has no tools and nothing to iterate on.
  def test_the_navigator_task_is_configured_and_reads_its_ceiling_from_settings
    settings = task("navigator")
    refute_empty settings, "tasks.navigator is missing"

    assert_equal 1, Boukensha::Tasks::Navigator.max_iterations(settings)
    refute_equal Boukensha::Tasks::Base::DEFAULT_MAX_ITERATIONS,
                 Boukensha::Tasks::Navigator.max_iterations(settings),
                 "a ceiling that happens to equal the default proves nothing about where it was read from"
  end

  # Neither reasoner has tools, and neither wants an `allow:` block. They answer
  # with fields — §5.2 — and `Reasoners` runs both with `tools: false` so
  # registering the MUD server for them never opens a second telnet login.
  def test_neither_reasoner_is_granted_any_tools
    %w[navigator cartographer].each do |name|
      settings = task(name)
      next if settings.empty?

      assert_nil settings["allow"], "tasks.#{name}.allow would give a judgement a tool surface"
    end
  end

  def test_the_configured_reasoner_models_are_ones_the_backend_knows
    %w[navigator cartographer].each do |name|
      settings = task(name)
      next if settings.empty?
      next unless settings["provider"].to_s == "anthropic"

      assert_includes Boukensha::Backends::Anthropic::MODELS.keys, settings["model"],
                      "tasks.#{name}.model is not one Backends::Anthropic prices"
    end
  end

  # Both bundled prompts have to resolve, and neither may fall back to the
  # player's. `Base.read_default_prompt` reads `<prompts>/<name>.md` — the
  # player's file — which is how the judge silently ran with no prompt of its own
  # until it was scoped by task name.
  def test_both_reasoner_prompts_resolve_and_are_scoped_by_task_name
    prompts = Boukensha::Config::PROMPTS_DIR
    player  = Boukensha::Tasks::Player.system_prompt({}, default_prompts_dir: prompts)

    nav = Boukensha::Tasks::Navigator.system_prompt({}, default_prompts_dir: prompts)
    refute_nil nav, "the navigator has no bundled default system prompt"
    refute_equal player, nav
    assert_match(/direction/i, nav)
    assert_match(/JSON/, nav)
    # §5.3's guard rail has to be IN the prompt: a field that demands an answer
    # every leg will manufacture confident bad labels at one per leg.
    assert_match(/null/, nav)

    cart = Boukensha::Tasks::Cartographer.system_prompt({}, default_prompts_dir: prompts)
    refute_nil cart, "the cartographer has no bundled default system prompt"
    refute_equal player, cart
    refute_equal nav, cart
    # §5.5: without a legal decline, the first uneasy leg manufactures a
    # permanent boundary.
    assert_match(/declin/i, cart)
  end
end
