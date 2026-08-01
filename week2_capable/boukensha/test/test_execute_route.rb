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

  # --- what kind of stop it was (dark_rooms_and_stuck_walks.md §Layer 3) -----
  #
  # `stopped` alone was never enough to drive a walk. A refusal is something to
  # re-plan around, an interruption belongs to the player, and a position that
  # cannot be established must not be planned from at all — three different
  # instructions that used to arrive as one string.

  PITCH_BLACK = "It is pitch black...\r\n\r\n27H 132M 94V (news) (motd) > ".freeze

  def test_a_rejected_move_reports_its_kind_so_a_caller_can_re_plan
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > " }]
    )
    hooks = hooks_at_market_square(mud)

    result = ER.walk(steps: %w[up east], call_tool: mud.player_call_tool, hooks: hooks)

    assert_equal :refused, result[:stopped_kind]
    assert_equal ["east"], result[:remaining]
  end

  # The recovery the recorded session never got to make. Walking into a room
  # that cannot be identified is not a dead end: the direction just walked is
  # still known, so its reverse is walked immediately — one MUD round trip, no
  # model call — and the walk ends somewhere the planner can work from.
  def test_a_step_into_an_unidentifiable_room_walks_itself_back_out
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      # `down` lands in the dark, and the look from there is dark too, so
      # position is lost; the reverse `up` lands back in Market Square.
      moves: [
        { text: PITCH_BLACK, fixtures: { "look" => PITCH_BLACK, "poll" => "" } },
        { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }
      ]
    )
    hooks = hooks_at_market_square(mud)

    result = ER.walk(steps: %w[down east], call_tool: mud.player_call_tool, hooks: hooks)

    assert_equal :unreadable, result[:stopped_kind]
    assert_equal %w[down up], mud.move_calls, "the reverse is walked inside the same call"
    assert_match(/stepped back up to Market Square/, result[:stopped])
    assert_equal 1, @store.player[:current_room_id], "and position is usable again"
    assert_equal 1, @store.exit_at(1, "down")[:opaque], "the exit is marked so it is not chosen again"
  end

  def test_a_one_way_step_into_the_dark_reports_the_position_as_lost
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [
        { text: PITCH_BLACK, fixtures: { "look" => PITCH_BLACK, "poll" => "" } },
        { text: "Alas, you cannot go that way.\r\n\r\n27H 132M 94V > " }
      ]
    )
    hooks = hooks_at_market_square(mud)

    result = ER.walk(steps: ["down"], call_tool: mud.player_call_tool, hooks: hooks)

    assert_equal :position_lost, result[:stopped_kind]
    assert_match(/did not lead back out/, result[:stopped])
    assert_nil @store.player[:current_room_id],
               "a walk that cannot say where it ended must not leave a room behind that it can"
  end

  # ---------- the bounded sweep (blind_step_recovery.md §5.5) --------------
  #
  # The drop that shut the way behind it is not a rare shape: room 3002's `down`
  # in the recorded world leads to a sewer junction with no `up` at all, and its
  # own exit description says climbing back is impossible. The reverse step cannot
  # work there, and the four outcomes below are what the walker does instead.

  REFUSED = "Alas, you cannot go that way.\r\n\r\n27H 132M 94V (news) (motd) > ".freeze

  # A move costs a movement point and a refusal costs none, so the numeric prompt
  # says which happened even when the room cannot be read. Nothing here reads a
  # word of the reply.
  MOVED_BUT_DARK = "It is pitch black...\r\n\r\n27H 132M 93V (news) (motd) > ".freeze

  def dark_then(*replies)
    ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: PITCH_BLACK, fixtures: { "look" => PITCH_BLACK, "poll" => "" } }] +
             replies.map { |r| r.is_a?(Hash) ? r : { text: r } }
    )
  end

  def test_the_sweep_recovers_when_a_direction_lands_somewhere_readable
    # `down` into the dark, `up` refused, then `north` is a room again.
    mud = dark_then(REFUSED, { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE })
    hooks = hooks_at_market_square(mud)

    result = ER.walk(steps: ["down"], call_tool: mud.player_call_tool, hooks: hooks, blind_steps: 6)

    assert_equal :recovered, result[:stopped_kind]
    assert_equal %w[down up north], mud.move_calls
    assert_match(/walked north into Market Square/, result[:stopped])
    assert_equal 1, @store.player[:current_room_id], "position is usable again"
  end

  # Every direction refused, none of them spending a movement point: the room is
  # sealed and that is a proof rather than a guess.
  def test_every_direction_refused_is_reported_as_stuck
    mud = dark_then(*Array.new(12) { REFUSED })
    hooks = hooks_at_market_square(mud)

    result = ER.walk(steps: ["down"], call_tool: mud.player_call_tool, hooks: hooks, blind_steps: 12)

    assert_equal :stuck, result[:stopped_kind]
    assert_match(/every direction from here was refused/, result[:stopped])
    assert_equal 11, mud.move_calls.size, "the reverse, then each of the ten canonical directions once"
  end

  # The budget running out proves nothing, and the status says so — which is the
  # difference that makes another attempt reasonable after one and pointless after
  # the other.
  def test_a_spent_budget_is_reported_as_recovery_exhausted_rather_than_stuck
    mud = dark_then(*Array.new(6) { REFUSED })
    hooks = hooks_at_market_square(mud)

    result = ER.walk(steps: ["down"], call_tool: mud.player_call_tool, hooks: hooks, blind_steps: 3)

    assert_equal :recovery_exhausted, result[:stopped_kind]
    assert_match(/untried/, result[:stopped])
    # The step itself, the reverse, then three of the sweep: the budget bounds the
    # sweep alone, which is what the setting says it does.
    assert_equal 5, mud.move_calls.size
  end

  # A step that MOVED without becoming readable puts the character somewhere new,
  # so the directions ruled out no longer describe where it is standing and `stuck`
  # must not be claimed on them.
  def test_a_move_that_stays_unreadable_resets_what_has_been_ruled_out
    dark_room = { text: MOVED_BUT_DARK, fixtures: { "look" => PITCH_BLACK, "poll" => "" } }
    mud = dark_then(REFUSED, dark_room, *Array.new(8) { REFUSED })
    hooks = hooks_at_market_square(mud)

    result = ER.walk(steps: ["down"], call_tool: mud.player_call_tool, hooks: hooks, blind_steps: 4)

    assert_equal :recovery_exhausted, result[:stopped_kind],
                 "the second room's exits were never all tested, so nothing is proved"
    assert_nil @store.player[:current_room_id]
  end

  # A caller with no recovery budget gets exactly what it got before the sweep
  # existed, which is what `position_lost` has always meant.
  def test_no_budget_leaves_the_old_behaviour_untouched
    mud = dark_then(REFUSED)
    hooks = hooks_at_market_square(mud)

    result = ER.walk(steps: ["down"], call_tool: mud.player_call_tool, hooks: hooks)

    assert_equal :position_lost, result[:stopped_kind]
    assert_equal %w[down up], mud.move_calls
  end

  # Nothing the sweep walks through is written down. It cannot identify the rooms,
  # so an arrival edge from an unknown origin is never recorded and no room row is
  # created for anywhere it passes.
  def test_the_sweep_writes_nothing_to_the_map
    mud = dark_then(REFUSED, { text: MOVED_BUT_DARK, fixtures: { "look" => PITCH_BLACK, "poll" => "" } },
                    *Array.new(8) { REFUSED })
    hooks = hooks_at_market_square(mud)
    before = @store.rooms.size

    ER.walk(steps: ["down"], call_tool: mud.player_call_tool, hooks: hooks, blind_steps: 4)

    assert_equal before, @store.rooms.size, "a room that cannot be identified is not a room to record"
    assert_nil @store.player[:current_room_id]
    # Market Square keeps the one edge the walk earned — the opaque `down` — and
    # gains nothing from anywhere the sweep wandered.
    assert_equal ["down"], @store.all_exits.select { |e| e[:opaque].to_i.positive? }.map { |e| e[:direction] }
  end

  def test_no_steps_is_a_clean_no_op
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)

    result = ER.call(steps: [], call_tool: mud.player_call_tool, hooks: hooks)
    assert_match(/no steps given/, result)
    assert_empty mud.move_calls
  end
end
