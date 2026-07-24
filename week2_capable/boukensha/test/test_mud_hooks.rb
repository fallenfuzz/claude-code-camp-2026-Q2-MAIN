require_relative "helper"
require "json"

# Mud::Hooks — the three bodies that replace the inspect_room tool.
#
# What is being tested is mostly the ABSENCE of round trips: a revisit that
# spends nothing, a familiar mob that costs nothing, a room dump the model never
# sees. Each test therefore asserts on the fake MUD's call list as much as on
# the state block.
class TestMudHooks < Minitest::Test
  H = Boukensha::Mud::Hooks
  M = Boukensha::Mud::Memory

  TRANSCRIPTS = JSON.parse(
    File.read(File.expand_path("fixtures/mud_transcripts.json", __dir__))
  ).freeze

  def t(key) = TRANSCRIPTS.fetch(key)

  # The MUD, scripted. `calls` is the assertion surface for every cost claim in
  # the plan's §10 table.
  class FakeMud
    attr_reader :calls
    attr_accessor :responses

    def initialize(responses = {})
      @responses = responses
      @calls = []
    end

    def to_proc
      lambda do |name, args = {}|
        @calls << [name.sub("tbamud__", ""), args]
        key = name.sub("tbamud__", "")
        key = "#{key}:#{args[:target] || args[:kind]}" if args[:target] || args[:kind]
        @responses.fetch(key) { @responses.fetch(name.sub("tbamud__", ""), "") }
      end
    end

    def tools_called = @calls.map(&:first)
  end

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  COMMON_SQUARE = {
    "look" => TRANSCRIPTS.fetch("look_common_square"),
    "check:exits" => TRANSCRIPTS.fetch("exits_common_square"),
    "check:score" => "This ranks you as Dummy the Man (level 1).\r\n20H 100M 84V > ",
    "consider:fido" => TRANSCRIPTS.fetch("consider_fido"),
    "examine:fido" => TRANSCRIPTS.fetch("examine_fido"),
    "poll" => ""
  }.freeze

  # A real movement result, lifted verbatim from .boukensha/manager: it looks
  # exactly like a full `look`, which is precisely why §5.5 refuses to build a
  # room record out of one.
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

  def hooks_for(responses, **kwargs)
    fake = FakeMud.new(responses.dup)
    [H.new(store: @store, call_tool: fake.to_proc, warn_to: nil, **kwargs), fake]
  end

  def ctx = Boukensha::Context.new(system: "t")

  # Walk one room. The MUD is re-scripted by swapping the FAKE's responses, not
  # by swapping the hook's call_tool: the survey holds its own reference to that
  # lambda, so replacing it would leave the survey talking to the old room while
  # the poll talked to the new one — and the test would pass for a reason that
  # has nothing to do with the code.
  def walk(hooks, fake, context, direction, responses)
    fake.responses = responses
    fake.calls.clear
    hooks.before_tools(calls: [], context: context)
    hooks.after_tool(name: "tbamud__move", args: { "direction" => direction },
                     result: responses.fetch("look"), context: context)
    hooks.before_model(context: context)
  end

  # --- before_tools: the poll, in the one position where it works ------------

  # 79% of polls came back empty in the logs, and that rate is a PLACEMENT bug,
  # not an argument against polling: poll used to run as step 1 of the survey,
  # immediately after a command whose own pre-send drain had emptied the buffer.
  def test_before_tools_always_polls_exactly_once_per_batch
    h, fake = hooks_for({ "poll" => t("poll_event") })
    h.before_tools(calls: [{ "name" => "tbamud__move" }, { "name" => "tbamud__say" }], context: ctx)

    assert_equal %w[poll], fake.tools_called, "once per BATCH, not once per call"
  end

  # The thinking-gap output the pre-send drain would otherwise destroy. Without
  # this the agent would have died with no record of why.
  def test_a_fight_that_happened_during_inference_reaches_the_model
    fight = "You're stunned, but will probably regain consciousness again.\r\n0H 100M 84V > \r\n" \
            "The newbie monster pierces you.\r\n" \
            "You are mortally wounded, and will die soon, if not aided.\r\n-6H 100M 84V > "
    h, = hooks_for({ "poll" => fight })
    c = ctx

    h.before_tools(calls: [], context: c)
    h.before_model(context: c)

    assert_includes c.state_block, "mortally wounded"
    assert_equal(-6, @store.player[:hp], "HP tracking is free — the prompt rides on every response")
  end

  def test_the_prompt_line_is_never_shipped_as_an_event
    h, = hooks_for({ "poll" => t("poll_event") })
    c = ctx
    h.before_tools(calls: [], context: c)
    h.before_model(context: c)

    assert_includes c.state_block, "The cityguard has arrived."
    refute_match(/just now:.*100M/, c.state_block)
  end

  # --- after_tool: §6.2's substitution ---------------------------------------

  # 46 movement results over six sessions were 19,352 chars ≈ 4,838 tokens —
  # the single largest thing in the model's context, ahead of the survey tool
  # itself, and every byte a room description the hook has already read.
  def test_a_successful_move_is_replaced_by_a_one_line_stub
    h, = hooks_for(MARKET_SQUARE)

    stub = h.after_tool(name: "tbamud__move", args: { "direction" => "south" },
                        result: MARKET_SQUARE_MOVE, context: ctx)

    assert_equal "moved south → Market Square", stub
    assert_operator stub.length, :<, MARKET_SQUARE_MOVE.length / 4
  end

  def test_flee_says_fled_and_names_where_it_landed
    h, = hooks_for(MARKET_SQUARE)
    assert_equal "fled → Market Square",
                 h.after_tool(name: "tbamud__flee", args: {}, result: MARKET_SQUARE_MOVE, context: ctx)
  end

  # The one place this design can make the agent STUPIDER. A missed
  # substitution costs ~100 tokens; a wrongly swallowed failure costs an agent
  # that retries a wall until its iteration limit trips.
  def test_every_known_movement_failure_reaches_the_model_verbatim
    h, = hooks_for(MARKET_SQUARE)

    [
      "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > ",
      "The door is closed.\r\n\r\n20H 100M 81V > ",
      "You are too exhausted.\r\n\r\n20H 100M 81V > ",
      "You are too tired.\r\n\r\n20H 100M 81V > ",
      # The rule is a WHITELIST on success, so text no parser has ever seen is
      # passed through by construction rather than by having been listed here.
      "Some refusal from a future patch nobody anticipated.\r\n\r\n20H 100M 81V > "
    ].each do |failure|
      assert_nil h.after_tool(name: "tbamud__move", args: { "direction" => "north" },
                              result: failure, context: ctx),
                 "#{failure.inspect} must reach the model untouched"
    end
  end

  # Only the movement family. `shop`, `check`, `say` and the rest are read by
  # the model and must stay verbatim.
  def test_non_movement_tools_are_never_substituted
    h, = hooks_for(MARKET_SQUARE)
    assert_nil h.after_tool(name: "tbamud__shop", args: {}, result: MARKET_SQUARE_MOVE, context: ctx)
    assert_nil h.after_tool(name: "tbamud__say", args: {}, result: "You say, 'hi'\r\n20H 100M 81V > ", context: ctx)
  end

  # The model may call check(score) itself, and when it does we get the level
  # reading — which is what `threat_level` is measured against — for free.
  def test_a_score_check_by_the_model_updates_the_level
    h, = hooks_for(MARKET_SQUARE)
    h.after_tool(name: "tbamud__check", args: { "kind" => "score" },
                 result: "You have scored 1250 exp, and have 43 gold coins.\r\n" \
                         "This ranks you as Dummy the Man (level 3).\r\n20H 100M 81V > ",
                 context: ctx)

    assert_equal 3, @store.player[:level]
    assert_equal 43, @store.player[:gold]
  end

  # --- before_model: the reconciliation --------------------------------------

  # A fresh login, a new session, a /clear, a reconnect: nothing has told us
  # where we are, player_state.current_room_id is a hint from a previous
  # process, and the only correct action is a real look.
  # ONE look, not two. A cold look is a real look we issued a moment ago with
  # nothing in between, so the survey reuses it. The refusal in §5.5 is about
  # MOVEMENT text — which has the async window drained out of it — and applying
  # it here too would just buy a redundant round trip on every session start.
  def test_a_cold_start_spends_one_look_and_surveys_the_room
    h, fake = hooks_for(COMMON_SQUARE)
    c = ctx
    h.before_model(context: c)

    assert_equal %w[look check consider examine], fake.tools_called
    assert_includes c.state_block, "[here] The Common Square"
    assert_equal 1, @store.stats[:rooms]
    assert_equal "The Eastern End Of Poor Alley", @store.exit_at(1, "west")[:target_name]
  end

  # …but arriving somewhere new via a MOVE does pay for its own look, because
  # the movement text has a hole in it: run_command drains the buffer before
  # sending, so anything that happened during the last inference is gone from
  # it, and a room record built from that is a room record with a lie in it.
  def test_a_new_room_reached_by_moving_still_pays_for_its_own_look
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)               # cold start in Market Square
    walk(h, fake, c, "south", COMMON_SQUARE)

    assert_equal %w[poll look check consider examine], fake.tools_called
    assert_equal 2, @store.stats[:rooms]
  end

  # The §10 row the world-level entities table exists to produce: a new room
  # whose mobs are all familiar costs the survey minus the appraisal.
  def test_a_new_room_full_of_familiar_mobs_skips_the_appraisal
    main_street = MARKET_SQUARE.merge(
      "look" => "\e[0;33mMain Street\e[0m\r\n   The main street.\r\n\e[0;36m[ Exits: e w ]\e[0m\r\n" \
                "\e[0;33mA cityguard stands here.\r\n\e[0m\r\n20H 100M 81V > ",
      "check:exits" => "Obvious exits:\r\neast  - Market Square\r\nwest  - The Grocer\r\n\r\n20H 100M 81V > "
    )
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_turn(context: c)                # level 1, so the appraisal is fresh
    h.before_model(context: c)               # meets and appraises the cityguard here
    walk(h, fake, c, "east", main_street)

    assert_equal %w[poll look check], fake.tools_called,
                 "a cityguard met in a brand-new room is already appraised"
    assert_equal 2, @store.stats[:rooms]
    assert_equal 1, @store.stats[:entities], "one type, two rooms"
    assert_includes c.state_block, "You could take him."
  end

  # `check(exits)` said one thing; walking it proved another. A room cannot
  # move, so the room wins — otherwise the state block puts a `✓` next to a
  # place the agent has never been, which is worse than the `?` it replaced.
  def test_walking_an_exit_corrects_a_destination_name_that_was_wrong
    wrong = MARKET_SQUARE.merge(
      "check:exits" => "Obvious exits:\r\nsouth - Somewhere Else Entirely\r\n\r\n20H 100M 81V > "
    )
    h, fake = hooks_for(wrong)
    c = ctx
    h.before_model(context: c)
    assert_equal "Somewhere Else Entirely", @store.exit_at(1, "south")[:target_name]

    walk(h, fake, c, "south", COMMON_SQUARE)

    assert_equal "The Common Square", @store.exit_at(1, "south")[:target_name]
    assert_equal 2, @store.exit_at(1, "south")[:target_room_id]
  end

  # THE point of the whole plan. In the sampled session Market Square and Main
  # Street were each fully re-surveyed on the second visit — 27% of arrivals
  # buying information the transcript already contained.
  def test_returning_to_a_known_room_spends_nothing
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)                                  # discover it
    h.after_tool(name: "tbamud__move", args: { "direction" => "north" }, result: "", context: c)
    fake.calls.clear

    # Walk away and come back.
    h.after_tool(name: "tbamud__move", args: { "direction" => "south" },
                 result: MARKET_SQUARE_MOVE, context: c)
    h.before_model(context: c)

    assert_empty fake.tools_called, "a room's name, prose and exits cannot change between visits"
    assert_equal 1, @store.stats[:rooms]
    assert_equal 2, @store.room(1)[:visit_count]
    assert_includes c.state_block, "(visit 2)"
  end

  # The prose is the largest field in the record and the agent has already read
  # it. Re-sending it every five seconds is exactly the accumulation this
  # design exists to stop.
  def test_the_description_is_sent_once_and_the_name_thereafter
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)
    assert_includes c.state_block, "famous Square of Midgaard"

    h.before_model(context: c)
    assert_includes c.state_block, "[here] Market Square"
    refute_includes c.state_block, "famous Square of Midgaard"
  end

  # `✓` is a destination the agent has stood in; `?` is the frontier. It cannot
  # tell those apart today at all.
  def test_the_exits_line_marks_the_frontier
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)

    assert_includes c.state_block, "n→The Temple Square ?"
    assert_includes c.state_block, "s→The Common Square ?"
  end

  def test_walking_an_exit_turns_a_frontier_into_a_link
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)                                   # in Market Square
    walk(h, fake, c, "south", COMMON_SQUARE)                     # arrived somewhere new

    edge = @store.exit_at(1, "south")
    assert_equal 2, edge[:target_room_id], "the edge we walked is now real"
    assert_equal 1, edge[:traversals]
  end

  # A wandering mob is not a property of the room. Presence is rendered from the
  # live parse plus the latest poll, never from stored sightings — reporting the
  # cityguard that "The cityguard leaves east" just removed is the single worst
  # failure mode this design can have.
  def test_a_departure_removes_the_mob_from_the_here_line
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)
    assert_includes c.state_block, "A cityguard stands here."

    h.before_tools(calls: [], context: c)  # an empty poll leaves it standing there
    # A departure can ride on ANY response, not just a poll — which is why it is
    # noticed in absorb_mud_text rather than in the poll handler.
    h.after_tool(name: "tbamud__say", args: {},
                 result: "The cityguard leaves east.\r\n20H 100M 81V > ", context: c)
    h.before_model(context: c)

    refute_includes c.state_block, "A cityguard stands here."
  end

  def test_the_remembered_threat_rides_along_with_the_mob
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)

    assert_includes c.state_block, "You could take him."
  end

  # A parse that could not tell mobs from objects is wrong in EVERY room at once
  # now that entities are world-level. Degrade to a room with no entity record
  # rather than a room with a wrong one.
  def test_uncoloured_output_is_not_written_to_the_entities_table
    plain = MARKET_SQUARE.merge("look" => MARKET_SQUARE_MOVE.gsub(/\e\[[0-9;]*m/, ""))
    h, = hooks_for(plain)
    h.before_model(context: ctx)

    assert_equal 1, @store.stats[:rooms], "the ROOM is still recorded"
    assert_equal 0, @store.stats[:entities], "the mis-kinded entity is not"
  end

  # --- encounters ------------------------------------------------------------

  # "if it fights the minotaur at level 3 and loses, it should record that and
  # then refer to it along with its current level when deciding if it can win."
  def test_losing_a_fight_is_recorded_against_the_thing_that_won_it
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_turn(context: c)                        # level 1
    h.before_model(context: c)                       # meets and appraises the cityguard

    h.after_tool(name: "tbamud__attack", args: { "target" => "cityguard" },
                 result: "You hit the cityguard.\r\n12H 100M 81V > ", context: c)
    h.after_tool(name: "tbamud__attack", args: { "target" => "cityguard" },
                 result: "You are mortally wounded, and will die soon, if not aided.\r\n-6H 100M 81V > ",
                 context: c)

    guard = @store.entity_for("A cityguard stands here.")
    row   = @store.encounters_for(guard[:id]).first
    assert_equal "died", row[:outcome]
    assert_equal 1, row[:player_level], "the level is what makes the outcome usable later"
    assert_equal(-6, row[:hp_after])
  end

  # And the whole point of recording it: the next time the agent stands next to
  # one, it is told.
  def test_a_remembered_defeat_is_surfaced_next_time_you_meet_the_thing
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_turn(context: c)
    h.before_model(context: c)
    h.after_tool(name: "tbamud__attack", args: { "target" => "cityguard" },
                 result: "You are dead! Sorry...\r\n1H 100M 81V > ", context: c)

    # Back on our feet, and back in the room.
    h2, = hooks_for(MARKET_SQUARE)
    c2 = ctx
    h2.before_model(context: c2)

    assert_includes c2.state_block, "you died against this at level 1"
  end

  def test_walking_away_from_an_open_fight_is_abandoned_not_won
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)
    h.after_tool(name: "tbamud__attack", args: { "target" => "cityguard" },
                 result: "You hit the cityguard.\r\n12H 100M 81V > ", context: c)
    h.after_tool(name: "tbamud__move", args: { "direction" => "north" },
                 result: MARKET_SQUARE_MOVE, context: c)

    guard = @store.entity_for("A cityguard stands here.")
    assert_equal "abandoned", @store.encounters_for(guard[:id]).first[:outcome]
  end

  def test_a_win_is_recorded_too
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)
    h.after_tool(name: "tbamud__attack", args: { "target" => "cityguard" },
                 result: "The cityguard is dead! R.I.P.\r\n18H 100M 81V > ", context: c)

    guard = @store.entity_for("A cityguard stands here.")
    assert_equal "won", @store.encounters_for(guard[:id]).first[:outcome]
    # …and a win is not something the state block nags about.
    h.before_model(context: c)
    refute_includes c.state_block.to_s, "you won against"
  end

  # --- resilience ------------------------------------------------------------

  # An agent with broken memory must degrade to the behaviour it had before any
  # of this existed, never to a dead REPL.
  def test_a_broken_store_does_not_kill_the_turn
    h, = hooks_for(MARKET_SQUARE)
    @store.close
    c = ctx

    h.before_turn(context: c)
    h.before_tools(calls: [], context: c)
    assert_nil h.after_tool(name: "tbamud__move", args: {}, result: MARKET_SQUARE_MOVE, context: c)
    h.before_model(context: c)
  ensure
    @store = nil
  end

  # --- the turn policy -------------------------------------------------------

  def test_the_turn_policy_is_off_unless_asked_for
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)

    assert_nil c.turn_policy
  end

  # It may only ever narrow, so it restates every tool the task already granted
  # and constrains exactly one of them.
  def test_the_turn_policy_pins_move_to_the_exits_the_mud_printed
    h, = hooks_for(MARKET_SQUARE, turn_policy: true)
    c = ctx
    c.register_tool(Boukensha::Tool.new("tbamud__move", "d", {}, proc {}))
    c.register_tool(Boukensha::Tool.new("tbamud__say", "d", {}, proc {}))
    h.before_model(context: c)

    assert c.turn_policy.call_permitted?("tbamud__move", { direction: "north" })
    refute c.turn_policy.call_permitted?("tbamud__move", { direction: "up" })
    assert c.turn_policy.call_permitted?("tbamud__say", { message: "hi" }),
           "a policy that denied everything it did not name would not be narrowing"
  end
end
