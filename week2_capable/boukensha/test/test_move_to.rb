require_relative "helper"
require "json"

# Navigation::MoveTo — move_to.md §8.
#
# The one movement tool on the player's surface: plan, walk, and when the
# destination is not on the map, ask `Tasks::Navigator` which frontier and walk
# that instead. Everything below runs against a scripted MUD and a scripted
# navigator, so the loop, its four limits, its region writes and its journalling
# are all testable with no model, no network and no key — the same trade
# `RoomSurvey` makes with its injected `call_tool`.
class TestMoveTo < Minitest::Test
  H  = Boukensha::Mud::Hooks
  M  = Boukensha::Mud::Memory
  MT = Boukensha::Mud::Navigation::MoveTo
  T  = Boukensha::Mud::Navigation::RegionTools
  R  = Boukensha::Mud::Navigation::Reasoners

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

  # Two scripted dispatchers over one mutable "current room" response set, as in
  # test_execute_route.rb: `nav_call_tool` is the NAVIGATION slice (move, poll)
  # and `hook_call_tool` is the room-survey slice (look, check, consider,
  # examine), exactly as production wires them.
  class ScriptedMud
    attr_reader :move_calls, :poll_calls

    def initialize(start_fixtures:, moves: [], polls: [])
      @current    = start_fixtures.dup
      @moves      = moves.dup
      @polls      = polls.dup
      @move_calls = []
      @poll_calls = []
    end

    def nav_call_tool
      lambda do |name, args = {}|
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

  # A navigator that answers from a script. `calls` is the record of every
  # payload it was handed, which is how the gate tests assert what was NOT asked
  # rather than only what was answered.
  class ScriptedReasoner
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls   = []
    end

    def to_proc
      lambda do |payload|
        @calls << payload
        answer = @answers.shift
        raise answer if answer.is_a?(StandardError)

        answer
      end
    end
  end

  # Collects journal lines without a file. `Journal#event` is the only method
  # MoveTo uses.
  class FakeJournal
    attr_reader :events

    def initialize = @events = []
    def event(stream:, op:, **fields) = @events << { stream: stream, op: op }.merge(fields)
    def find(op) = @events.find { |e| e[:op] == op }
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

  def hooks_at_market_square(mud)
    hooks = H.new(store: @store, call_tool: mud.hook_call_tool, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: "t"))
    hooks
  end

  def move_to(mud, hooks, **kwargs)
    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks, **kwargs)
  end

  # Market Square (1) --south--> Common Square (2), then back.
  def south_then_north
    ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [
        { text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE },
        { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }
      ],
      polls: [""] * 8
    )
  end

  # ---------- behaviour: the known branch (§8) ---------------------------

  def test_a_known_destination_walks_without_asking_the_navigator
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    # One walk south makes The Common Square a room the agent has stood in, so
    # the second call has a `known` path to it.
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "exploring" })
    move_to(mud, hooks, navigator: navigator.to_proc).call(destination: "Common Square")

    known = ScriptedReasoner.new
    result = move_to(mud, hooks, navigator: known.to_proc).call(destination: "Common Square")

    assert_match(/\[move_to\] Common Square — arrived/, result)
    assert_empty known.calls, "a known path is not a judgement — nothing to decide, nothing to ask"
  end

  def test_already_being_there_returns_immediately_and_moves_nothing
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)

    result = move_to(mud, hooks).call(destination: "Market Square")

    assert_match(/\[move_to\] Market Square — arrived/, result)
    assert_match(/here: Market Square \(#1\)/, result)
    assert_empty mud.move_calls
  end

  def test_an_empty_destination_is_refused_before_anything_moves
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)

    assert_match(/destination is required/, move_to(mud, hooks).call(destination: "   "))
    assert_empty mud.move_calls
  end

  # ---------- scope: the one navigation judgement left with the player ----
  #
  # `plan_route` answers `region_exhausted` when every remaining lead leaves the
  # region, and boundaries_revised §2 calls that "a question rather than a wall"
  # — so the answer prints the widening call. With plan_route off the player's
  # surface that remedy has to name a tool the player actually has.

  # Two rooms, hand-built: a town with its single exit walked off, and a field
  # beyond it in its own region holding the only unexplored exit left. That IS
  # region_exhausted — every remaining lead leaves the region — and it needs no
  # MUD, because nothing here walks.
  def town_with_every_lead_outside_it
    @store.create_room(name: "Market Square", description: "The famous square.",
                       weak_fingerprint: "a")
    @store.record_exits!(1, targets: { "north" => "The Great Field" })
    @store.update_player!(current_room_id: 1)
    T.name_region(store: @store, region: "Midgaard")

    field = @store.create_room(name: "The Great Field", description: "Grass, and more grass.",
                               weak_fingerprint: "b", arrived_from: 1, arrived_direction: "north")
    @store.link_exit!(1, "north", field)
    @store.record_exits!(field, dirs: %w[north], targets: { "south" => "Market Square" })
    @store.link_exit!(field, "south", 1)
    @store.update_player!(current_room_id: field)
    T.split_region(store: @store, region: "The Great Field")
    @store.update_player!(current_room_id: 1)
  end

  def test_the_region_exhausted_remedy_names_move_to_and_not_plan_route
    town_with_every_lead_outside_it

    result = MT.new(store: @store, call_tool: nil, hooks: nil).call(destination: "hermit")

    assert_match(/region_exhausted/, result)
    assert_match(/move_to\(destination: "hermit", scope: "world"\)/, result,
                 "a remedy naming a tool the player does not have is a remedy for nobody")
    refute_match(/plan_route\(/, result)
  end

  def test_scope_world_lifts_the_region_confinement
    town_with_every_lead_outside_it

    result = MT.new(store: @store, call_tool: nil, hooks: nil).call(destination: "hermit", scope: "world")

    refute_match(/region_exhausted/, result)
    assert_match(/unexplored, anywhere you have walked/, result)
  end

  # An unrecognised scope falls back to the default rather than raising inside a
  # tool call, for the same reason a bad limit does.
  def test_an_unknown_scope_falls_back_to_region
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)

    result = move_to(mud, hooks).call(destination: "bakery", scope: "galaxy")

    assert_match(/unexplored, in /, result, "the region label heads the listing, so scoping held")
  end

  # ---------- behaviour: the unknown branch ------------------------------

  def test_with_no_navigator_the_frontier_listing_is_the_answer
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)

    result = move_to(mud, hooks).call(destination: "bakery")

    assert_match(/\[route\] bakery — unknown/, result, "plan_route's own words, not a second copy of them")
    assert_match(/unexplored/, result)
    assert_empty mud.move_calls, "nothing to decide with means nothing to walk"
  end

  def test_the_navigator_is_asked_once_per_leg_and_its_reason_reaches_the_output
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new(
      { "direction" => "south", "reason" => "a bakery is a shop and shops are on streets" },
      { "direction" => "north", "reason" => "back towards the square" },
      { "direction" => "south", "reason" => "still looking" }
    )

    result = move_to(mud, hooks, navigator: navigator.to_proc,
                                 limits: { "max_rooms" => 2 }).call(destination: "bakery")

    assert_equal 2, navigator.calls.size, "one decision per leg, and max_rooms 2 allows two legs"
    assert_match(/a bakery is a shop and shops are on streets/, result)
    assert_match(/chose south/, result)
    assert_equal %w[south north], mud.move_calls
  end

  def test_the_navigator_payload_carries_the_candidate_names_and_the_region_shape
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "r" })

    move_to(mud, hooks, navigator: navigator.to_proc,
                        limits: { "max_rooms" => 1 }).call(destination: "bakery")

    payload = navigator.calls.first
    assert_equal "bakery", payload["destination"]
    assert_match(/Market Square/, payload["here"])
    assert_match(/unconfirmed/, payload["region"])
    names = payload["candidates"].map { |c| c["leads_to"] }
    assert_includes names, "The Common Square"
    assert_includes names, "The Temple Square"
  end

  # ---------- limits (§4.3, §8) ------------------------------------------

  def test_max_rooms_returns_a_structured_stop_naming_budget_not_failure
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new(*Array.new(6) { { "direction" => "south", "reason" => "r" } })

    result = move_to(mud, hooks, navigator: navigator.to_proc,
                                 limits: { "max_rooms" => 1 }).call(destination: "bakery")

    assert_match(/stopped on budget/, result)
    assert_match(/max_rooms \(1\) reached/, result)
    assert_match(/here: The Common Square/, result, "a budget stop still says where it got to")
    assert_equal 1, mud.move_calls.size
  end

  def test_max_decisions_bounds_spend_independently_of_distance
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new(*Array.new(6) { { "direction" => "south", "reason" => "r" } })

    result = move_to(mud, hooks, navigator: navigator.to_proc,
                                 limits: { "max_rooms" => 99, "max_decisions" => 1 }).call(destination: "bakery")

    assert_equal 1, navigator.calls.size
    assert_match(/max_decisions \(1\) reached/, result)
  end

  def test_max_steps_per_leg_caps_one_decisions_walk
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "r" })

    move_to(mud, hooks, navigator: navigator.to_proc,
                        limits: { "max_steps_per_leg" => 1, "max_decisions" => 1 }).call(destination: "bakery")

    assert_equal 1, mud.move_calls.size
  end

  def test_limits_come_from_configuration_and_a_bad_value_falls_back_to_the_default
    subject = MT.new(store: @store, call_tool: ->(*) { "" }, hooks: nil,
                     limits: { "max_rooms" => 3, "max_decisions" => "twelve" })

    assert_equal 3, subject.limit("max_rooms")
    assert_equal MT::DEFAULT_LIMITS["max_decisions"], subject.limit("max_decisions")
    assert_equal MT::DEFAULT_LIMITS["max_steps_per_leg"], subject.limit("max_steps_per_leg")
  end

  # ---------- interruption and death -------------------------------------

  # A multi-step leg, which is the only shape an interruption can land inside:
  # `walk` polls BETWEEN steps and not after the last, because the next
  # before_model call polls for that one.
  #
  # Getting there needs two rooms linked both ways, so the first call walks
  # south and back north; after that, The Common Square's own unexplored exits
  # are one move from Market Square and a decision to take one of them is a
  # two-step leg — walk to the room, then out through the exit.
  def test_an_interrupting_event_mid_leg_returns_where_it_got_to
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [
        { text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE },
        { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE },
        { text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE }
      ],
      polls: ["The creepy crawler misses a wild punch at you.\r\n"]
    )
    hooks = hooks_at_market_square(mud)
    there_and_back = ScriptedReasoner.new({ "direction" => "south", "reason" => "r" },
                                          { "direction" => "north", "reason" => "r" })
    move_to(mud, hooks, navigator: there_and_back.to_proc,
                        limits: { "max_rooms" => 2, "max_steps_per_leg" => 1 }).call(destination: "bakery")
    assert_equal 2, mud.move_calls.size, "precondition: both rooms are linked in both directions"

    # `south` is now unique to The Common Square: Market Square's own south is
    # the linked edge we just walked, so it is no longer a frontier at all.
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "the nasty smell is worth a look" })
    result = move_to(mud, hooks, navigator: navigator.to_proc,
                                 limits: { "max_steps_per_leg" => 4 }).call(destination: "bakery")

    chosen = navigator.calls.first["candidates"].find { |c| c["direction"] == "south" }
    assert_equal ["south"], Array(chosen["walk"]),
                 "the chosen frontier is one move away, so the leg is walk-then-exit"
    assert_match(/— interrupted/, result)
    assert_match(/creepy crawler/, result)
    assert_match(/here: The Common Square/, result)
    assert_equal 3, mud.move_calls.size, "the second step of the leg is never issued after the stop"
  end

  # The Void fingerprints like any other room, so `note_death` drops position
  # rather than re-deriving it — and a batched walk has no pause in which to
  # notice, so the walk has to stop on the same text it noticed on.
  #
  # The invariant is that the Void never becomes a room: a walk that carried on
  # would resolve position off the death text, record wherever the corpse landed
  # as an explored location, and then dead-reckon from it.
  def test_a_death_mid_walk_stops_the_walk_and_records_no_room
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: "You are dead! Sorry...\r\n\r\n1H 100M 81V > " },
              { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }]
    )
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "r" },
                                     { "direction" => "north", "reason" => "r" })
    rooms_before = @store.rooms.size

    result = move_to(mud, hooks, navigator: navigator.to_proc).call(destination: "bakery")

    assert_match(/you died/, result)
    assert_equal rooms_before, @store.rooms.size, "the Void must never be recorded as explored"
    assert_equal 1, mud.move_calls.size, "no further move is issued after a death"
  end

  # ---------- regions: naming (§5.3) -------------------------------------

  def test_a_place_against_an_unconfirmed_region_names_it
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    journal = FakeJournal.new
    navigator = ScriptedReasoner.new(
      { "direction" => "south", "reason" => "towards the streets", "place" => "Midgaard" }
    )

    move_to(mud, hooks, navigator: navigator.to_proc, journal: journal,
                        limits: { "max_rooms" => 1 }).call(destination: "bakery")

    assert_equal "Midgaard", @store.region_for_room(1)[:label]
    assert_equal 1, @store.region_for_room(1)[:confirmed]
    named = journal.find("region_named")
    refute_nil named, "a declaration with no recorded justification is indistinguishable from a bug"
    assert_equal "Midgaard", named[:place]
    assert_equal "towards the streets", named[:reason]
  end

  def test_a_place_against_an_already_confirmed_region_changes_nothing
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    T.name_region(store: @store, region: "Midgaard")
    navigator = ScriptedReasoner.new(
      { "direction" => "south", "reason" => "r", "place" => "Somewhere Else" }
    )

    move_to(mud, hooks, navigator: navigator.to_proc,
                        limits: { "max_rooms" => 1 }).call(destination: "bakery")

    assert_equal "Midgaard", @store.region_for_room(1)[:label],
                 "a confirmed label is a declaration somebody earned; a per-leg field does not overwrite it"
  end

  def test_a_null_or_unchanged_place_never_renames_anything
    MT::UNCHANGED.each do |value|
      store = M::Store.open(":memory:")
      mud   = south_then_north
      hooks = H.new(store: store, call_tool: mud.hook_call_tool, warn_to: nil)
      hooks.before_model(context: Boukensha::Context.new(system: "t"))
      before = store.region_for_room(1)[:label]

      MT.new(store: store, call_tool: mud.nav_call_tool, hooks: hooks,
             navigator: ScriptedReasoner.new({ "direction" => "south", "reason" => "r",
                                               "place" => value }).to_proc,
             limits: { "max_rooms" => 1 }).call(destination: "bakery")

      assert_equal before, store.region_for_room(1)[:label], "place #{value.inspect} must be a no-op"
      store.close
    end
  end

  def test_act_on_place_false_keeps_the_field_in_the_schema_and_out_of_the_store
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    before = @store.region_for_room(1)[:label]

    move_to(mud, hooks, act_on_place: false, limits: { "max_rooms" => 1 },
                        navigator: ScriptedReasoner.new({ "direction" => "south", "reason" => "r",
                                                          "place" => "Midgaard" }).to_proc)
      .call(destination: "bakery")

    assert_equal before, @store.region_for_room(1)[:label]
  end

  # ---------- regions: the scope gate (§5.7) -----------------------------

  def test_the_scope_question_is_not_asked_below_the_gate
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "r" })

    move_to(mud, hooks, navigator: navigator.to_proc,
                        limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 3 })
      .call(destination: "bakery")

    refute navigator.calls.first.key?("scope_question"),
           "one room and a median of zero is not a scope problem — the fields stay off the payload"
  end

  def test_the_scope_question_is_asked_once_the_region_is_large_enough
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "r" })

    move_to(mud, hooks, navigator: navigator.to_proc,
                        limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 1 })
      .call(destination: "bakery")

    assert navigator.calls.first.key?("scope_question")
    assert_match(/distances, not the count/, navigator.calls.first["scope_question"])
  end

  def test_scope_suspect_below_the_gate_never_reaches_the_cartographer
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    cartographer = ScriptedReasoner.new({ "split_at_room_id" => 1, "label" => "Nope" })

    move_to(mud, hooks, cartographer: cartographer.to_proc,
                        navigator: ScriptedReasoner.new({ "direction" => "south", "reason" => "r",
                                                          "scope_suspect" => true }).to_proc,
                        limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 99 })
      .call(destination: "bakery")

    assert_empty cartographer.calls
  end

  # ---------- regions: splitting (§5.5, §5.6) ---------------------------

  # Walk south first so The Common Square (room 2) has a stored arrival edge —
  # `1 --south--> 2` — which is the edge a split at room 2 must land on.
  def walked_south
    mud   = south_then_north
    hooks = hooks_at_market_square(mud)
    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks,
           navigator: ScriptedReasoner.new({ "direction" => "south", "reason" => "r" }).to_proc,
           limits: { "max_rooms" => 1 }).call(destination: "bakery")
    [mud, hooks]
  end

  def test_a_cartographer_declining_leaves_the_region_untouched
    mud, hooks = walked_south
    journal = FakeJournal.new
    before  = @store.region_for_room(2)[:id]
    cartographer = ScriptedReasoner.new({ "split" => false, "reason" => "large but coherent" })

    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks, journal: journal,
           cartographer: cartographer.to_proc,
           navigator: ScriptedReasoner.new({ "direction" => "north", "reason" => "r",
                                             "scope_suspect" => true,
                                             "scope_reason" => "median is six" }).to_proc,
           limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 1 }).call(destination: "bakery")

    assert_equal 1, cartographer.calls.size
    assert_equal before, @store.region_for_room(2)[:id], "a decline must create no boundary"
    declined = journal.find("region_split_declined")
    refute_nil declined
    assert_equal "large but coherent", declined[:reason]
  end

  # §5.6. The signal arrives after the boundary was crossed, and that is
  # recoverable because the edge is persisted per room rather than held
  # transiently.
  def test_a_split_lands_on_the_arrival_edge_of_the_room_the_cartographer_named
    mud, hooks = walked_south
    journal = FakeJournal.new
    cartographer = ScriptedReasoner.new(
      { "split_at_room_id" => 2, "label" => "The Common Quarter", "within" => "Midgaard",
        "reason" => "everything past room 1's south door is residential" }
    )

    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks, journal: journal,
           cartographer: cartographer.to_proc,
           navigator: ScriptedReasoner.new({ "direction" => "north", "reason" => "r",
                                             "scope_suspect" => true,
                                             "scope_reason" => "median is six" }).to_proc,
           limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 1 }).call(destination: "bakery")

    assert_equal "The Common Quarter", @store.region_for_room(2)[:label]
    refute_equal "The Common Quarter", @store.region_for_room(1)[:label],
                 "the room behind the boundary keeps its region"

    split = journal.find("region_split")
    refute_nil split
    assert_equal 2, split[:at_room_id]
    assert_match(/residential/, split[:reason])
    assert_match(/median is six/, split[:detected_by])
  end

  def test_a_split_naming_a_room_outside_the_region_is_rejected_rather_than_applied
    mud, hooks = walked_south
    journal = FakeJournal.new
    cartographer = ScriptedReasoner.new({ "split_at_room_id" => 9999, "label" => "Nowhere", "reason" => "r" })

    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks, journal: journal,
           cartographer: cartographer.to_proc,
           navigator: ScriptedReasoner.new({ "direction" => "north", "reason" => "r",
                                             "scope_suspect" => true }).to_proc,
           limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 1 }).call(destination: "bakery")

    assert_nil @store.region_by_label("Nowhere")
    refute_nil journal.find("region_split_rejected")
  end

  def test_the_cartographer_payload_carries_the_graph_placement_needs
    mud, hooks = walked_south
    cartographer = ScriptedReasoner.new({ "split" => false, "reason" => "r" })

    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks,
           cartographer: cartographer.to_proc,
           navigator: ScriptedReasoner.new({ "direction" => "north", "reason" => "r",
                                             "scope_suspect" => true }).to_proc,
           limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 1 }).call(destination: "bakery")

    payload = cartographer.calls.first
    common  = payload["rooms"].find { |r| r["id"] == 2 }
    refute_nil common, "every room in the region is in the payload"
    assert_equal 1, common["first_entered_from"]
    assert_equal "south", common["first_entered_by"]
    assert(payload["edges"].any? { |e| e["from"] == 1 && e["direction"] == "south" && e["to"] == 2 })
  end

  # ---------- attribution (§6) ------------------------------------------

  def test_every_navigator_decision_is_journalled_with_its_reason
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    journal = FakeJournal.new

    move_to(mud, hooks, journal: journal, limits: { "max_rooms" => 1 },
                        navigator: ScriptedReasoner.new({ "direction" => "south",
                                                          "reason" => "shops are on streets" }).to_proc)
      .call(destination: "bakery")

    decision = journal.find("decision")
    refute_nil decision, "one opaque \"walked 9 rooms, found nothing\" is undebuggable"
    assert_equal MT::NAME, decision[:stream]
    assert_equal "south", decision[:direction]
    assert_equal "shops are on streets", decision[:reason]
    assert_equal "bakery", decision[:destination]
  end

  def test_a_direction_this_code_chose_is_recorded_as_a_fallback_not_as_judgement
    mud = south_then_north
    hooks = hooks_at_market_square(mud)

    result = move_to(mud, hooks, limits: { "max_rooms" => 1 },
                                 navigator: ScriptedReasoner.new({ "direction" => "sideways",
                                                                   "reason" => "r" }).to_proc)
      .call(destination: "bakery")

    assert_match(/fallback: navigator answered "sideways"/, result)
    assert_equal 1, mud.move_calls.size, "a defined fallback still moves; it just says it was not the model's pick"
  end

  def test_a_navigator_that_raises_stops_the_call_rather_than_the_session
    mud = south_then_north
    hooks = hooks_at_market_square(mud)

    result = move_to(mud, hooks,
                     navigator: ScriptedReasoner.new(RuntimeError.new("api down")).to_proc)
      .call(destination: "bakery")

    assert_match(/the navigator did not answer/, result)
    assert_match(/api down/, result)
    assert_empty mud.move_calls
  end

  # ---------- the answer parser -----------------------------------------

  def test_the_reasoner_parser_tolerates_a_fence_and_a_preface
    assert_equal({ "direction" => "south" }, R.parse(%({"direction": "south"})))
    assert_equal({ "direction" => "south" }, R.parse(%(```json\n{"direction": "south"}\n```)))
    assert_equal({ "direction" => "south" }, R.parse(%(Here you go: {"direction": "south"} — hope that helps)))
    assert_nil R.parse("I would go south, I think."),
               "unparseable is nil, so MoveTo stops with a reason rather than aborting a walk mid-character"
    assert_nil R.parse(nil)
  end
end
