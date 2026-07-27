require_relative "helper"
require "json"

# Navigation::ExecuteRouteTool — batched movement over a `plan_route`-known
# path, reconciling per step through Mud::Hooks#reconcile_move! and stopping
# early on a failed move or an interrupting poll event.
class TestExecuteRoute < Minitest::Test
  H  = Boukensha::Mud::Hooks
  M  = Boukensha::Mud::Memory
  ER = Boukensha::Mud::Navigation::ExecuteRouteTool

  TRANSCRIPTS = JSON.parse(
    File.read(File.expand_path("fixtures/mud_transcripts.json", __dir__))
  ).freeze

  MARKET_SQUARE_MOVE = "\e[0;33mMarket Square\e[0m\r\n   You are standing on the market square, the famous " \
                       "Square of Midgaard.\r\nRoads lead in every direction.\r\n\e[0;36m[ Exits: n e s w ]" \
                       "\e[0m\r\n\e[0;33mA cityguard stands here.\r\n\e[0m\r\n20H 100M 81V (news) (motd) > ".freeze

  MARKET_SQUARE = {
    "look" => MARKET_SQUARE_MOVE,
    "check:exits" => "Obvious exits:\r\nnorth - The Temple Square\r\neast  - Main Street\r\n" \
                     "south - The Common Square\r\nwest  - Main Street\r\n\r\n20H 100M 81V > ",
    "consider:cityguard" => "You could take him.\r\n\r\n20H 100M 81V > ",
    "examine:cityguard" => TRANSCRIPTS.fetch("examine_cityguard"),
    "check:score" => "This ranks you as Dummy the Man (level 1).\r\n20H 100M 81V > ",
    "poll" => ""
  }.freeze

  COMMON_SQUARE = {
    "look" => TRANSCRIPTS.fetch("look_common_square"),
    "check:exits" => TRANSCRIPTS.fetch("exits_common_square"),
    "check:score" => "This ranks you as Dummy the Man (level 1).\r\n20H 100M 84V > ",
    "consider:fido" => TRANSCRIPTS.fetch("consider_fido"),
    "examine:fido" => TRANSCRIPTS.fetch("examine_fido"),
    "poll" => ""
  }.freeze

  # Two independent scripted dispatchers sharing one mutable "current room"
  # response set — `player_call_tool` (move/poll, under the player's own
  # permissions) and `hook_call_tool` (look/check/consider/examine, under the
  # room-survey slice, exactly as Mud::Hooks itself is wired in production).
  #
  # `moves:` is consumed one entry per tbamud__move call: `text` is the raw
  # move result, and `fixtures` — if given — becomes the new shared response
  # set the MOMENT that move is dispatched, so a survey reconcile_move!
  # triggers immediately afterward already sees the DESTINATION room's
  # responses. This mirrors test_mud_hooks.rb's `walk` helper, which swaps
  # FakeMud#responses at the identical point for the identical reason: a
  # static hash cannot answer "look" for two different rooms at once.
  class ScriptedMud
    attr_reader :move_calls, :poll_calls

    def initialize(start_fixtures:, moves: [], polls: [])
      @current = start_fixtures.dup
      @moves   = moves.dup
      @polls   = polls.dup
      @move_calls = []
      @poll_calls = []
    end

    def player_call_tool
      lambda do |name, args|
        case name
        when "tbamud__move"
          @move_calls << args["direction"]
          step = @moves.shift || {}
          @current = step[:fixtures] if step[:fixtures]
          step[:text].to_s
        when "tbamud__poll"
          @poll_calls << true
          @polls.shift.to_s
        else
          ""
        end
      end
    end

    def hook_call_tool
      lambda do |name, args|
        key = name.sub("tbamud__", "")
        key = "#{key}:#{args[:target] || args[:kind]}" if args[:target] || args[:kind]
        @current.fetch(key) { @current.fetch(name.sub("tbamud__", ""), "") }
      end
    end
  end

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
    Boukensha::Operation.reset!
  end

  # Establishes Market Square (room 1) as the current position before the
  # scripted move/poll sequence begins.
  def hooks_at_market_square(mud)
    hooks = H.new(store: @store, call_tool: mud.hook_call_tool, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: "t"))
    hooks
  end

  def test_full_route_completes_with_no_interrupting_polls
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE }],
      polls: [""]
    )
    hooks = hooks_at_market_square(mud)

    result = ER.call(steps: ["south"], call_tool: mud.player_call_tool, hooks: hooks)

    assert_match(/\[route\] executed 1\/1/, result)
    assert_match(/step 1: south → The Common Square \(ok\)/, result)
    assert_match(/arrived: The Common Square/, result)
    assert_equal ["south"], mud.move_calls
  end

  def test_multi_step_route_polls_between_steps_but_not_after_the_last
    # Market Square (1) --south--> Common Square (2) --north--> Market
    # Square: the second step is a revisit, so no survey round trip either.
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [
        { text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE },
        { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }
      ],
      polls: [""]
    )
    hooks = hooks_at_market_square(mud)

    result = ER.call(steps: %w[south north], call_tool: mud.player_call_tool, hooks: hooks)

    assert_match(/\[route\] executed 2\/2/, result)
    assert_equal %w[south north], mud.move_calls
    assert_equal 1, mud.poll_calls.size, "one poll between the two steps, none after the last"
  end

  def test_stops_early_on_an_interrupting_poll_and_lists_remaining_steps
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [
        { text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE },
        { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }
      ],
      polls: ["The creepy crawler misses a wild punch at you.\r\n"]
    )
    hooks = hooks_at_market_square(mud)

    result = ER.call(steps: %w[south north], call_tool: mud.player_call_tool, hooks: hooks)

    assert_match(/\[route\] executed 1\/2 — stopped/, result)
    assert_match(/step 1: south → The Common Square \(ok\)/, result)
    assert_match(/stopped: The creepy crawler misses a wild punch at you\./, result)
    assert_match(/remaining: north/, result)
    assert_equal ["south"], mud.move_calls, "the second move must never be issued after the stop"
  end

  def test_stops_early_on_a_rejected_move
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > " }],
      polls: []
    )
    hooks = hooks_at_market_square(mud)

    result = ER.call(steps: %w[up east], call_tool: mud.player_call_tool, hooks: hooks)

    assert_match(/\[route\] executed 0\/2 — stopped/, result)
    assert_match(/stopped: move failed \(up\)/, result)
    assert_match(/remaining: east/, result)
    assert_equal 1, @store.frontier_attempt_counts[[1, "up"]]
  end

  def test_no_steps_is_a_clean_no_op
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)

    result = ER.call(steps: [], call_tool: mud.player_call_tool, hooks: hooks)
    assert_match(/no steps given/, result)
    assert_empty mud.move_calls
  end
end
