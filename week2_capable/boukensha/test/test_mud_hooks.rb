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
    attr_reader :calls, :metas
    attr_accessor :responses

    def initialize(responses = {})
      @responses = responses
      @calls = []
      @metas = []
    end

    def to_proc
      # Provenance is no longer an argument the dispatcher is handed — the
      # logger reads it off the ambient `Boukensha::Operation` stack. So the
      # thing a test must observe is which span was OPEN at the moment the call
      # was made, sampled here for exactly that reason.
      lambda do |name, args = {}|
        @calls << [name.sub("tbamud__", ""), args]
        frame  = Boukensha::Operation.current
        @metas << [name.sub("tbamud__", ""),
                   frame ? { operation: frame.name, trigger: frame.trigger,
                             operation_id: frame.id, parent_operation_id: frame.parent_id } : {}]
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
    # A span left open by a raise that escaped an `ensure` would silently
    # mislabel every call the NEXT test makes.
    Boukensha::Operation.reset!
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

  # The provenance the hook stamped on its FIRST call to `tool`.
  def meta_for(fake, tool)
    fake.metas.find { |name, _| name == tool }&.last || {}
  end

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

  # plan_route.md §6.3's missing memory: a rejected move is recorded so the
  # frontier ranker can fan outward instead of retrying the same blocked door.
  #
  # The row is written by `before_model` rather than by `after_tool`, and the
  # deferral is the point rather than an accident of layering: whether an
  # unreadable reply refused us or moved us is exactly what is unknown at
  # `after_tool` time, and `after_tool` may not spend the `look` that settles
  # it. Writing the guess there is what put twenty-two false failures in session
  # 20260730T201603Z-ff25f010's ledger.
  def test_a_rejected_move_records_a_failed_frontier_attempt
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c) # establishes current_room_id = 1 (Market Square)

    h.after_tool(name: "tbamud__move", args: { "direction" => "north" },
                 result: "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > ", context: c)
    assert_nil @store.frontier_attempt_counts[[1, "north"]],
               "which outcome to record is not yet known, and after_tool may not find out"

    h.before_model(context: c)

    assert_equal 1, @store.frontier_attempt_counts[[1, "north"]]
    assert_equal 1, @store.player[:current_room_id], "and the look confirmed we never left"
  end

  def test_a_successful_move_records_a_succeeded_frontier_attempt
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)
    walk(h, fake, c, "south", COMMON_SQUARE)

    assert_nil @store.frontier_attempt_counts[[1, "south"]], "a success is not a failure count"
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

  # --- reconcile_move! (execute_route's per-step reconciliation) -----------
  #
  # execute_route performs several moves inside ONE tool call, so it cannot
  # wait for the next before_model to learn where each step landed. These
  # tests cover the same three outcomes ordinary movement handles — a brand
  # new room, a familiar one, and a rejected move — but reconciled
  # immediately, synchronously, mid-batch.

  def test_reconcile_move_resolves_a_new_room_immediately_not_deferred
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c) # establishes Market Square as room 1

    fake.responses = COMMON_SQUARE
    outcome = h.reconcile_move!(direction: "south", text: COMMON_SQUARE.fetch("look"))

    assert outcome[:ok]
    assert_equal "The Common Square", outcome[:room_name]
    edge = @store.exit_at(1, "south")
    assert_equal outcome[:room_id], edge[:target_room_id], "the edge is linked immediately, not deferred"
    assert_equal 1, edge[:traversals]

    # The next before_model must find nothing left to redo: no pending
    # arrival, and @current_room_id already set, so it only re-renders state.
    fake.calls.clear
    h.before_model(context: c)
    assert_empty fake.tools_called, "before_model must spend nothing after reconcile_move! already settled it"
    assert_includes c.state_block, "The Common Square"
  end

  def test_reconcile_move_on_a_revisit_spends_nothing_extra
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)
    fake.responses = COMMON_SQUARE
    h.reconcile_move!(direction: "south", text: COMMON_SQUARE.fetch("look"))

    fake.responses = MARKET_SQUARE
    fake.calls.clear
    outcome = h.reconcile_move!(direction: "north", text: MARKET_SQUARE_MOVE)

    assert outcome[:ok]
    assert_equal 1, outcome[:room_id]
    assert_empty fake.tools_called, "a revisit needs no survey round trip, immediate or deferred"
    assert_equal 2, @store.room(1)[:visit_count]
  end

  def test_reconcile_move_on_a_rejected_move_records_failure_and_does_not_move
    h, = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)

    outcome = h.reconcile_move!(direction: "up", text: "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > ")

    refute outcome[:ok]
    assert_equal :refused, outcome[:kind]
    assert_equal 1, @store.frontier_attempt_counts[[1, "up"]]
    assert_equal 1, @store.player[:current_room_id], "a rejected move must not change position"
  end

  # --- unreadable movement output (dark_rooms_and_stuck_walks.md) ------------
  #
  # The class of failure that stranded session 20260730T201603Z-ff25f010: a move
  # whose reply is not a room USED to be read as "the move was refused", which
  # is only one of the two things it can mean. The other is that we moved and
  # cannot see where to, and concluding the first when the second is true leaves
  # memory asserting a room the character has left — permanently, because
  # nothing afterwards re-checks a position it believes it knows.
  #
  # None of these tests hands the parser a sentence to recognise. What settles
  # the ambiguity is a `look` and what it comes back with, which is why the same
  # code covers darkness, blindness, and output nobody has seen yet.

  # tbaMUD's reply on walking into an unlit room. It is here as a fixture rather
  # than as a constant in the parser precisely because no production code may
  # test for it.
  PITCH_BLACK = "It is pitch black...\r\n\r\n27H 132M 94V (news) (motd) > ".freeze

  def test_an_unreadable_move_that_a_look_proves_was_a_real_move_updates_position
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c) # Market Square is room 1

    # The move says nothing readable, but a look from where we now stand shows
    # a different room: we moved.
    fake.responses = COMMON_SQUARE
    outcome = h.reconcile_move!(direction: "south", text: PITCH_BLACK)

    assert outcome[:ok], "a move the look proves happened is an arrival, not a refusal"
    assert_equal :look, outcome[:resolved_by]
    assert_equal "The Common Square", outcome[:room_name]
    assert_equal outcome[:room_id], @store.player[:current_room_id]
    assert_equal outcome[:room_id], @store.exit_at(1, "south")[:target_room_id],
                 "the step is still a step, and the map gains it"
    assert_nil @store.frontier_attempt_counts[[1, "south"]],
               "an exit that moved us must never be recorded as a failed attempt"
  end

  def test_an_unreadable_move_and_an_unreadable_look_drops_position_and_marks_the_exit
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)

    # Wherever we are, we cannot read it either — the sewer under The Dump.
    fake.responses = { "look" => PITCH_BLACK, "poll" => "" }
    outcome = h.reconcile_move!(direction: "down", text: PITCH_BLACK)

    refute outcome[:ok]
    assert_equal :position_lost, outcome[:kind]
    assert_nil @store.player[:current_room_id],
               "asserting the old room is the defect; unknown is the honest answer"
    assert_equal 1, @store.exit_at(1, "down")[:opaque],
                 "an exit walked for no information must stop being offered as a frontier"
    assert_nil @store.frontier_attempt_counts[[1, "down"]],
               "we moved, so the attempt succeeded — it simply told us nothing"
  end

  # The other half, and the one that keeps the fix from being a licence to
  # wander: when the look says we are exactly where we thought, the move really
  # was refused and nothing about the map changes.
  def test_an_unreadable_move_a_look_shows_we_never_left_is_still_a_refusal
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)
    before = @store.exit_at(1, "north")

    fake.responses = MARKET_SQUARE
    outcome = h.reconcile_move!(direction: "north", text: "Some output nobody has ever seen.\r\n20H 100M 81V > ")

    refute outcome[:ok]
    assert_equal :refused, outcome[:kind]
    assert_equal 1, @store.player[:current_room_id]
    assert_equal 1, @store.frontier_attempt_counts[[1, "north"]]
    assert_equal before.to_h, @store.exit_at(1, "north").to_h,
                 "one refusal is a closed door as often as a wrong edge, and must not demote one"
  end

  # The single-move path reaches the same three answers, but `after_tool` is
  # documented as spending no MUD I/O, so the doubt is carried to `before_model`
  # rather than resolved on the spot.
  def test_a_single_unreadable_move_defers_its_look_to_before_model
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)

    fake.responses = COMMON_SQUARE
    fake.calls.clear
    h.after_tool(name: "tbamud__move", args: { "direction" => "south" }, result: PITCH_BLACK, context: c)

    assert_empty fake.tools_called, "after_tool may not spend a round trip"
    assert_equal 1, @store.player[:current_room_id], "and so cannot have resolved it yet"

    h.before_model(context: c)

    assert_includes fake.tools_called, "look"
    assert_equal "The Common Square", @store.room(@store.player[:current_room_id])[:name]
  end

  def test_a_single_unreadable_move_into_an_unreadable_room_leaves_position_unknown
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)

    fake.responses = { "look" => PITCH_BLACK, "poll" => "" }
    h.after_tool(name: "tbamud__move", args: { "direction" => "down" }, result: PITCH_BLACK, context: c)
    h.before_model(context: c)

    assert_nil @store.player[:current_room_id]
    assert_equal 1, @store.exit_at(1, "down")[:opaque]
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

    assert_includes c.state_block, "north→The Temple Square ?"
    assert_includes c.state_block, "south→The Common Square ?"
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

  # --- the score refresh policy (observ_improvements.md §5) -------------------
  #
  # The player's allowlist no longer offers `check(kind: score)` — the hook
  # maintains the sheet. That is only safe with an invalidation policy: gold,
  # experience and level do NOT appear on the prompt line, so anything that
  # moves them without printing the new totals has to mark the sheet dirty or
  # the state block serves a stale figure for the rest of the session.

  def test_score_is_read_once_and_not_again_while_it_is_believed_current
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    3.times { h.before_turn(context: c) }

    assert_equal 1, fake.tools_called.count("check")
  end

  # A kill pays experience and usually gold, and the death message prints
  # neither.
  def test_a_won_fight_marks_the_sheet_stale
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_turn(context: c)
    h.after_tool(name: "tbamud__attack", args: { "target" => "cityguard" },
                 result: "You hit the cityguard.\r\n20H 100M 81V > ", context: c)
    h.after_tool(name: "tbamud__attack", args: { "target" => "cityguard" },
                 result: "The cityguard is dead! R.I.P.\r\n18H 100M 81V > ", context: c)
    fake.calls.clear
    h.before_turn(context: c)

    assert_equal 1, fake.tools_called.count("check"), "the next turn re-reads the sheet"
  end

  def test_shopping_marks_the_sheet_stale
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_turn(context: c)
    h.after_tool(name: "tbamud__shop", args: { "action" => "buy" },
                 result: "You buy a loaf of bread for 5 coins.\r\n20H 100M 81V > ", context: c)
    fake.calls.clear
    h.before_turn(context: c)

    assert_equal 1, fake.tools_called.count("check")
  end

  # Dying costs experience and moves the character to the Void.
  def test_death_marks_the_sheet_stale
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_turn(context: c)
    h.after_tool(name: "tbamud__attack", args: {},
                 result: "You are mortally wounded, and will die soon, if not aided.\r\n-6H 100M 81V > ",
                 context: c)
    fake.calls.clear
    h.before_turn(context: c)

    assert_equal 1, fake.tools_called.count("check")
  end

  # …but an ordinary move must NOT. A refresh on every action is exactly the
  # per-iteration cost this design exists to avoid.
  def test_ordinary_actions_leave_the_sheet_alone
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_turn(context: c)
    h.after_tool(name: "tbamud__move", args: { "direction" => "north" },
                 result: MARKET_SQUARE_MOVE, context: c)
    h.after_tool(name: "tbamud__say", args: {}, result: "You say, 'hi'\r\n20H 100M 81V > ", context: c)
    fake.calls.clear
    h.before_turn(context: c)

    assert_equal 0, fake.tools_called.count("check")
  end

  # --- provenance (observ_improvements.md §1) ---------------------------------
  #
  # None of these calls were chosen by the model, and the session log used to
  # have no way to say so. `operation` is the semantic reason, `trigger` the
  # lifecycle seam it fired from; the monitor groups on the pair.

  def test_every_hook_call_is_labelled_with_its_operation_and_trigger
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx

    h.before_turn(context: c)                  # score
    h.before_tools(calls: [], context: c)      # poll
    h.before_model(context: c)                 # cold look, then the survey

    assert_equal ["player_bootstrap", "before_turn"], meta_for(fake, "check").values_at(:operation, :trigger)
    assert_equal ["async_poll", "before_tools"],      meta_for(fake, "poll").values_at(:operation, :trigger)
    assert_equal ["position_refresh", "before_model"], meta_for(fake, "look").values_at(:operation, :trigger)
  end

  # `look`, `check(exits)`, `consider` and `examine` are ONE unit of automatic
  # work. Four separately-labelled commands scattered through the model's
  # narrative is the presentation bug this grouping exists to prevent.
  def test_the_survey_labels_its_whole_group_as_one_operation
    h, fake = hooks_for(MARKET_SQUARE)
    h.before_model(context: ctx)               # first visit ⇒ a full survey

    surveyed = fake.metas.select { |name, _| %w[check consider examine].include?(name) }
    refute_empty surveyed
    assert_equal [ "room_survey" ], surveyed.map { |_, meta| meta[:operation] }.uniq
  end

  # The shape the whole plan exists for: `room_survey` is not a SIBLING of
  # `position_refresh`, it runs INSIDE it (before_model → resolve_position →
  # discover → survey). Adjacency cannot express that and got it wrong; a
  # parent id can only ever be right.
  def test_the_survey_span_is_nested_inside_the_position_refresh_that_ran_it
    h, fake = hooks_for(MARKET_SQUARE)
    h.before_model(context: ctx)

    outer = meta_for(fake, "look")           # the cold look, under position_refresh
    inner = meta_for(fake, "examine")        # deep inside the survey

    assert_equal "position_refresh", outer[:operation]
    assert_equal "room_survey", inner[:operation]
    assert_equal outer[:operation_id], inner[:parent_operation_id]
  end

  # The survey names no lifecycle seam of its own — it cannot know one — so it
  # inherits the seam of the span it opened inside.
  def test_a_nested_span_inherits_its_parents_trigger
    h, fake = hooks_for(MARKET_SQUARE)
    h.before_model(context: ctx)

    assert_equal "before_model", meta_for(fake, "examine")[:trigger]
  end

  # A span must RESTORE its predecessor, not clear it. The survey opens an
  # inner span inside before_model's; if the exit path wiped the label instead
  # of putting the outer one back, the next automatic call would come out
  # unattributed and land in the model's narrative as a player action.
  def test_a_span_survives_an_inner_one_opening_and_closing_inside_it
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.before_model(context: c)                 # first visit: cold look, then the survey
    # Death drops position — the Void must never be recorded as a room — so the
    # next before_model is cold again and spends a `look` under the OUTER span.
    h.after_tool(name: "tbamud__attack", args: {},
                 result: "You are mortally wounded, and will die soon, if not aided.\r\n-6H 100M 84V > ",
                 context: c)
    fake.metas.clear
    h.before_model(context: c)

    assert_equal ["position_refresh", "before_model"],
                 meta_for(fake, "look").values_at(:operation, :trigger)
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

  # --- the player sheet ------------------------------------------------------
  #
  # Collection rides readings the agent already pays for, so every test below
  # asserts the SAME cost claim from a different angle: `fake.tools_called` must
  # not grow. The fixtures are the bytes this build really emitted
  # (bin/seed_player --emit-fixtures).

  def player_fixture(name) = File.read(File.expand_path("fixtures/player/#{name}.txt", __dir__))

  # `before_turn` already spends one `check(score)` per process for the level
  # reading. Widening the parser means the other two thirds of that sheet —
  # which used to be thrown away — now land for free.
  def test_the_score_before_turn_already_pays_for_lands_whole
    h, fake = hooks_for({ "check:score" => player_fixture("score"), "poll" => "" })
    h.before_turn(context: ctx)

    assert_equal %w[check], fake.tools_called, "no round trip beyond the one already spent"
    p = @store.player
    assert_equal [10, 450_000, 225_000, 5_000], [p[:level], p[:exp], p[:exp_to_next], p[:gold]]
    assert_equal [162, 94], [p[:max_mana], p[:max_move]], "the denominators the prompt line has no room for"
    assert_equal ["94/10", 0, "Derrano the Minister", "standing"],
                 [p[:armor_class], p[:alignment], p[:title], p[:position]]
  end

  # …and the same catch when the MODEL calls score itself, which is the reading
  # we get for nothing at all.
  def test_a_models_own_score_check_is_caught_for_free
    h, fake = hooks_for(MARKET_SQUARE)
    h.after_tool(name: "tbamud__check", args: { "kind" => "score" },
                 result: player_fixture("score"), context: ctx)

    assert_empty fake.tools_called
    assert_equal "Derrano the Minister", @store.player[:title]
  end

  def test_the_pack_and_the_gear_are_captured_off_the_models_own_checks
    h, fake = hooks_for(MARKET_SQUARE)
    c = ctx
    h.after_tool(name: "tbamud__check", args: { "kind" => "inventory" },
                 result: player_fixture("inventory"), context: c)
    h.after_tool(name: "tbamud__check", args: { "kind" => "equipment" },
                 result: player_fixture("equipment"), context: c)

    assert_empty fake.tools_called, "no new round trips — we ride the model's own reads"
    assert_equal [["a bottle", 2]], @store.items(location: "inventory").map { |i| [i[:descr], i[:quantity]] }
    assert_equal [["worn on body", "a leather jacket"], ["wielded", "a wooden club"]],
                 @store.items(location: "equipped").map { |i| [i[:worn_on], i[:descr]] }
  end

  # The rule the snapshot exists to enforce: an item the agent no longer carries
  # must not still be in its knowledge the moment it looks again.
  def test_a_dropped_item_is_gone_from_the_next_snapshot
    h, = hooks_for(MARKET_SQUARE)
    c  = ctx
    h.after_tool(name: "tbamud__check", args: { "kind" => "inventory" },
                 result: player_fixture("inventory"), context: c)
    h.after_tool(name: "tbamud__drop_item", args: { "item" => "bottle" },
                 result: "You drop a bottle.\r\n19H 100M 83V > ", context: c)
    h.after_tool(name: "tbamud__check", args: { "kind" => "inventory" },
                 result: player_fixture("inventory_empty"), context: c)

    assert_empty @store.items(location: "inventory")
  end

  # Honest staleness. A mutation the agent did not follow with a read leaves the
  # snapshot ALONE and leaves `items_updated_at` where it was — the monitor then
  # says "as of T" rather than showing a bag nobody ever read.
  def test_a_mutation_without_a_following_read_does_not_fabricate_a_delta
    h, = hooks_for(MARKET_SQUARE)
    c  = ctx
    h.after_tool(name: "tbamud__check", args: { "kind" => "inventory" },
                 result: player_fixture("inventory"), context: c)
    stamped = @store.player[:items_updated_at]
    h.after_tool(name: "tbamud__drop_item", args: { "item" => "bottle" },
                 result: "You drop a bottle.\r\n19H 100M 83V > ", context: c)

    assert_equal 1, @store.items(location: "inventory").length, "the delta is not guessed"
    assert_equal stamped, @store.player[:items_updated_at], "and freshness is not claimed"
  end

  # A refusal parses to the same `[]` an empty pack does, so replacing on it
  # would delete everything the agent owns. The header is what separates them.
  def test_a_refusal_never_wipes_the_bag
    h, = hooks_for(MARKET_SQUARE)
    c  = ctx
    h.after_tool(name: "tbamud__check", args: { "kind" => "inventory" },
                 result: player_fixture("inventory"), context: c)
    h.after_tool(name: "tbamud__check", args: { "kind" => "inventory" },
                 result: "Huh?!?\r\n19H 100M 83V > ", context: c)

    assert_equal ["a bottle"], @store.items(location: "inventory").map { |i| i[:descr] }
  end

  # Skills are EARNED: the listing the model asked for is captured in place, and
  # the sessions counter rides along in the same response.
  def test_practice_lands_the_skill_list_and_the_sessions_counter
    h, fake = hooks_for(MARKET_SQUARE)
    h.after_tool(name: "tbamud__practice", args: {}, result: player_fixture("practice_guild"), context: ctx)

    assert_empty fake.tools_called
    assert_equal 30, @store.player[:practices_left]
    armor = @store.skills.find { |s| s[:name] == "armor" }
    assert_equal ["good", 1, "spell"], [armor[:proficiency], armor[:learned], armor[:kind]]
    assert_equal 17, @store.stats[:skills]
  end

  # …and never deletes. A listing that omits a skill is not evidence the
  # character forgot it — that is the whole difference between EARNED and the
  # replace-on-read bag above.
  def test_a_later_listing_upserts_rather_than_replacing
    h, = hooks_for(MARKET_SQUARE)
    c  = ctx
    h.after_tool(name: "tbamud__practice", args: {}, result: player_fixture("practice_guild"), context: c)
    h.after_tool(name: "tbamud__practice", args: {}, result: player_fixture("practice_refuse"), context: c)

    assert_equal 17, @store.stats[:skills], "the shorter listing did not erase the longer one"
    # The grade itself is CURRENT ability, so the freshest reading wins — the
    # two-row listing here is the level-1 capture, and it says armor is back to
    # "not learned". What survives is the row and the level it was first known
    # at; what moves is the grade.
    armor = @store.skills.find { |s| s[:name] == "armor" }
    assert_equal ["not learned", 0], [armor[:proficiency], armor[:learned]]
    assert_equal "not learned", @store.skills.find { |s| s[:name] == "bless" }[:proficiency]
  end

  # Every new path is inside `guard`, same as room capture: a player-capture
  # failure degrades to "no player detail", never to a dead turn.
  def test_broken_player_capture_leaves_the_turn_alive
    h, = hooks_for(MARKET_SQUARE)
    @store.close
    c = ctx

    assert_nil h.after_tool(name: "tbamud__check", args: { "kind" => "inventory" },
                            result: player_fixture("inventory"), context: c)
    assert_nil h.after_tool(name: "tbamud__practice", args: {},
                            result: player_fixture("practice_guild"), context: c)
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

  # --- change_capture.md P1: the progression journal shares the capture seam ---

  # A hook wired with a journal, plus a reader that returns its jsonl lines.
  # The journal is wired into the STORE too, since generic CDC now lives there.
  def hooks_with_journal(responses, **kwargs)
    dir     = Dir.mktmpdir
    journal = Boukensha::Journal.new(session_id: "test", dir: dir)
    @store.journal = journal
    fake    = FakeMud.new(responses.dup)
    hooks   = H.new(store: @store, call_tool: fake.to_proc, warn_to: nil, journal: journal, **kwargs)
    [ hooks, fake, journal, dir ]
  end

  def journal_lines(journal, dir)
    journal.close
    path = File.join(dir, "#{Time.now.strftime('%Y%m%d')}.jsonl")
    File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  # before_turn reads score and writes it to the store, whose generic CDC emits
  # the player-stat deltas — no extra round trip.
  def test_before_turn_journals_player_stats_through_the_store
    responses = COMMON_SQUARE.merge(
      "check:score" => "You have 1500 gold coins.\r\nThis ranks you as Dummy the Man (level 4).\r\n20H 100M 84V > "
    )
    h, _fake, journal, dir = hooks_with_journal(responses)
    h.before_turn(context: ctx)

    changes = journal_lines(journal, dir).select { |l| l["kind"] == "change" && l["stream"] == "stat" }
    by_key  = changes.each_with_object({}) { |c, h2| h2[c["key"]] = c["to"] }
    assert_equal 4, by_key["level"]
    assert_equal 1500, by_key["gold"]
  end

  # Generic capture records hp changes now (we want ALL deltas), but the journal
  # still swallows an unchanged reading — that dedup is what keeps volume from
  # exploding on the every-tool-call prompt scrape.
  def test_generic_capture_records_hp_on_change_and_swallows_no_ops
    h, _fake, journal, dir = hooks_with_journal(COMMON_SQUARE)
    h.after_tool(name: "tbamud__look", args: {}, result: "20H 100M 84V > ", context: ctx) # hp 20
    h.after_tool(name: "tbamud__look", args: {}, result: "20H 100M 84V > ", context: ctx) # unchanged ⇒ swallowed
    h.after_tool(name: "tbamud__look", args: {}, result: "5H 100M 84V > ", context: ctx)  # hp 5

    hp = journal_lines(journal, dir).select { |l| l["kind"] == "change" && l["key"] == "hp" }.map { |l| l["to"] }
    assert_equal [ 20, 5 ], hp
  end

  # An item the agent moved on its own initiative lands in the item ledger.
  def test_an_item_op_is_journalled_as_an_event
    h, _fake, journal, dir = hooks_with_journal(COMMON_SQUARE)
    h.after_tool(name: "tbamud__get_item", args: { "item" => "sword" },
                 result: "You get a long sword.\r\n20H 100M 84V > ", context: ctx)

    item = journal_lines(journal, dir).find { |l| l["kind"] == "event" && l["stream"] == "item" }
    refute_nil item
    assert_equal "acquire", item["op"]
    assert_equal "sword", item["keyword"]
  end

  # Death is a milestone on the timeline, filed against the level it happened at.
  def test_death_is_journalled_as_a_milestone
    @store.update_player!(level: 3)
    h, _fake, journal, dir = hooks_with_journal(COMMON_SQUARE)
    h.after_tool(name: "tbamud__attack", args: { "target" => "minotaur" },
                 result: "You are dead! Sorry...\r\n", context: ctx)

    death = journal_lines(journal, dir).find { |l| l["kind"] == "event" && l["op"] == "death" }
    refute_nil death
    assert_equal 3, death["level"]
  end

  # A session with no journal behaves exactly as before — no path here may
  # require one.
  def test_capture_seam_is_inert_without_a_journal
    h, = hooks_for(COMMON_SQUARE)
    h.before_turn(context: ctx)
    h.after_tool(name: "tbamud__get_item", args: { "item" => "sword" },
                 result: "You get a long sword.\r\n20H 100M 84V > ", context: ctx)
    # no raise ⇒ pass; the store still got its snapshot
    refute_nil @store.player[:level]
  end
end
