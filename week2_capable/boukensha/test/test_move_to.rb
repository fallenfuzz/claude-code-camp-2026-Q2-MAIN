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

  # `move_to` now has two objective modes and both are optional parameters, so
  # the empty case has to name both — a call giving neither is not a travel
  # request missing its destination, it is a call with no objective at all.
  def test_a_call_with_no_objective_is_refused_before_anything_moves
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)

    assert_match(/destination to travel to or a survey question/,
                 move_to(mud, hooks).call(destination: "   "))
    assert_match(/destination to travel to or a survey question/, move_to(mud, hooks).call)
    assert_empty mud.move_calls
  end

  # Every call journals what it answered and how far it got, whether or not it
  # moved. Twelve `unreachable` answers in one session were invisible to every
  # projection over the log until this existed
  # (unreachable_destinations.md §1).
  def test_every_call_journals_its_answer_and_the_rooms_it_walked
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    journal = FakeJournal.new
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "exploring" })

    # "fido" is nowhere in memory at a cold start, so this goes through the
    # frontier branch, walks one room south, and finds him there.
    move_to(mud, hooks, navigator: navigator.to_proc, journal: journal).call(destination: "fido")

    answered = journal.find("answered")
    assert_equal "move_to", answered[:stream]
    assert_equal "fido", answered[:destination]
    assert_equal "arrived", answered[:status]
    assert_equal 1, answered[:rooms_walked]
  end

  def test_an_answer_that_moved_nothing_records_zero_rooms
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)
    journal = FakeJournal.new

    move_to(mud, hooks, journal: journal).call(destination: "Market Square")

    assert_equal 0, journal.find("answered")[:rooms_walked]
  end

  # ---------- the recorded failure, end to end (fix_surveying.md §3.5) ----
  #
  # Run 20260731T140528Z-34c846bf, in miniature. The agent stood on the concourse
  # with "The South Gate" printed on its own west exit, unwalked, and asked to go
  # there nine times; each answer identified Inside The West Gate Of Midgaard — a
  # different gate on the far side of the city, matched on the shared word "gate"
  # — and reported it unreachable. Nothing moved.

  SOUTH_GATE_MOVE = "\e[0;33mThe South Gate\e[0m\r\n   The city wall towers above you, and the road " \
                    "runs out through the arch.\r\n\e[0;36m[ Exits: n e ]\e[0m\r\n\r\n" \
                    "20H 100M 80V > ".freeze

  SOUTH_GATE = {
    "look" => SOUTH_GATE_MOVE,
    "check:exits" => "Obvious exits:\r\nnorth - On The Concourse\r\neast  - The Promenade\r\n\r\n20H 100M 80V > ",
    "check:score" => "This ranks you as Dummy the Man (level 1).\r\n20H 100M 80V > ",
    "poll" => ""
  }.freeze

  # Hand-built, because what matters is the shape of the memory and not how it
  # was earned: the destination named on an unwalked exit here, and a room
  # sharing one word with the query somewhere the agent cannot reach.
  def concourse_beside_the_south_gate
    @store.create_room(name: "On The Concourse", description: "A broad concourse runs north and south.",
                       weak_fingerprint: "concourse")
    @store.record_exits!(1, targets: { "west" => "The South Gate", "east" => "The Promenade" })
    @store.update_player!(current_room_id: 1)
    @store.create_room(name: "Inside The West Gate Of Midgaard", description: "The west gate of the city.",
                       weak_fingerprint: "westgate")
  end

  def test_a_place_named_on_an_unwalked_exit_is_walked_to_not_refused
    concourse_beside_the_south_gate
    mud = ScriptedMud.new(start_fixtures: SOUTH_GATE,
                          moves: [{ text: SOUTH_GATE_MOVE, fixtures: SOUTH_GATE }], polls: [""] * 4)
    hooks = H.new(store: @store, call_tool: mud.hook_call_tool, warn_to: nil)
    navigator = ScriptedReasoner.new({ "direction" => "west", "reason" => "the exit says so" })

    result = move_to(mud, hooks, navigator: navigator.to_proc).call(destination: "The South Gate")

    assert_equal ["west"], mud.move_calls
    refute_match(/unreachable/, result)
    refute_match(/Inside The West Gate Of Midgaard/, result)
    assert_match(/here: The South Gate/, result)
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

  # ---------- steps that did not land (dark_rooms_and_stuck_walks.md) ------
  #
  # The recorded failure this exists to make impossible: every kind of stop used
  # to end the call, so a refused first step returned "interrupted, walked 0
  # rooms" and the player spent a full model call to learn nothing. Session
  # 20260730T201603Z-ff25f010 did that twenty times from the same room.

  def test_a_refused_step_is_re_planned_inside_the_call_rather_than_ending_it
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > " },
              { text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE }],
      polls: [""] * 4
    )
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "north", "reason" => "trying north" },
                                     { "direction" => "south", "reason" => "north is shut" })

    result = move_to(mud, hooks, navigator: navigator.to_proc).call(destination: "bakery")

    assert_equal %w[north south], mud.move_calls,
                 "the refusal is a fact to plan around, and this call can do that for free"
    refute_match(/interrupted/, result)
    assert_match(/here: The Common Square/, result)
  end

  def test_the_setback_allowance_is_a_ceiling_and_the_stop_says_what_it_was
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: Array.new(6) { { text: "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > " } },
      polls: [""] * 6
    )
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new(*Array.new(6) { { "direction" => "north", "reason" => "r" } })

    result = move_to(mud, hooks, navigator: navigator.to_proc,
                                 limits: { "max_setbacks" => 2 }).call(destination: "bakery")

    assert_equal 2, mud.move_calls.size
    assert_match(/the way is blocked/, result)
    refute_match(/interrupted/, result, "\"interrupted\" reads as transient, and invites the retry")
  end

  # A walk that ends with no idea where it is standing must say so, and must not
  # print a room. The old rendering asserted `here: The Dump (#5)` on twenty
  # consecutive calls while the character stood two rooms away in the sewer.
  #
  # The remedy has to name a call the PLAYER can make. It used to advise `look`
  # and a light source, neither of which is on the player's allowlist, which is
  # what left session 20260731T151434Z-737a23cb with seventeen refused calls and
  # nothing to try (blind_step_recovery.md §5.6).
  def test_a_lost_position_is_reported_as_lost_and_names_a_call_the_player_can_make
    dark = "It is pitch black...\r\n\r\n27H 132M 94V > "
    refused = "Alas, you cannot go that way.\r\n\r\n27H 132M 94V > "
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: dark, fixtures: { "look" => dark, "poll" => "" } }] +
             Array.new(9) { { text: refused } }
    )
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "north", "reason" => "r" })

    result = move_to(mud, hooks, navigator: navigator.to_proc).call(destination: "bakery")

    assert_match(/here: position unknown/, result)
    assert_match(/walked north out of Market Square \(#1\)/, result,
                 "the room walked out of survives the position being cleared, and is worth saying")
    assert_match(/move_to\(destination: "north"\)/, result,
                 "a remedy naming a tool the player does not have is a remedy for nobody")
    refute_match(/light source/, result)
    refute_match(/`look`/, result)
  end

  # The budget is a ceiling on MUD moves, not on rooms, because a refused
  # direction costs a round trip and no movement.
  def test_the_blind_sweep_stops_on_its_budget_and_says_nothing_is_proved
    dark = "It is pitch black...\r\n\r\n27H 132M 94V > "
    refused = "Alas, you cannot go that way.\r\n\r\n27H 132M 94V > "
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: dark, fixtures: { "look" => dark, "poll" => "" } }] +
             Array.new(9) { { text: refused } }
    )
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "north", "reason" => "r" })

    result = move_to(mud, hooks, navigator: navigator.to_proc,
                                 limits: { "max_blind_steps" => 3 }).call(destination: "bakery")

    # One step north, the reverse south, then three of the sweep: five moves.
    assert_equal 5, mud.move_calls.size
    assert_match(/where you are is not known yet/, result)
    assert_match(/untried/, result, "an exhausted recovery has proved nothing and should not claim to")
    refute_match(/no way out of here/, result)
  end

  # And when every direction has been refused it says THAT, which is a different
  # instruction: no further walking will help, so the session can end on a
  # conclusion rather than on max_tokens.
  def test_a_sealed_room_is_reported_as_stuck_with_no_remedy_offered
    dark = "It is pitch black...\r\n\r\n27H 132M 94V > "
    refused = "Alas, you cannot go that way.\r\n\r\n27H 132M 94V > "
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: dark, fixtures: { "look" => dark, "poll" => "" } }] +
             Array.new(12) { { text: refused } }
    )
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "north", "reason" => "r" })

    result = move_to(mud, hooks, navigator: navigator.to_proc,
                                 limits: { "max_blind_steps" => 12 }).call(destination: "bakery")

    assert_match(/no way out of here/, result)
    assert_match(/every direction from here was refused/, result)
    refute_match(/move_to\(destination: "north"\)/, result,
                 "inviting another step after proving none work is the dishonesty this exists to remove")
  end

  # ---------- a lost position is walkable (§5.4) --------------------------

  def test_a_bare_direction_walks_one_step_when_the_position_is_unknown
    @store.clear_player_room!
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE,
                          moves: [{ text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }], polls: [""] * 4)
    hooks = H.new(store: @store, call_tool: mud.hook_call_tool, warn_to: nil)

    result = move_to(mud, hooks).call(destination: "north")

    assert_equal ["north"], mud.move_calls, "refusing to move is what made the dark room a dead end"
    assert_match(/here: Market Square/, result)
  end

  # Abbreviations resolve, because the MUD's own exits line abbreviates and a lost
  # agent copying `d` out of it should not be told it named no direction.
  def test_an_abbreviated_direction_is_walked_too
    @store.clear_player_room!
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE,
                          moves: [{ text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }], polls: [""] * 4)
    hooks = H.new(store: @store, call_tool: mud.hook_call_tool, warn_to: nil)

    move_to(mud, hooks).call(destination: "n")

    assert_equal ["north"], mud.move_calls
  end

  # A place name is not a direction, and walking off in the hope of stumbling into
  # it would be guessing rather than recovering. The answer says what is known.
  def test_a_place_name_with_no_position_still_refuses_and_says_what_is_known
    @store.create_room(name: "Market Square", description: "The square.", weak_fingerprint: "a")
    @store.update_player!(current_room_id: 1, prev_room_id: 1, last_direction: "down")
    @store.clear_player_room!
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = H.new(store: @store, call_tool: mud.hook_call_tool, warn_to: nil)

    result = move_to(mud, hooks).call(destination: "the bakery")

    assert_empty mud.move_calls
    assert_match(/position unknown/, result)
    assert_match(/you walked down out of Market Square \(#1\)/, result)
    assert_match(/ask for a bare direction/, result)
  end

  # ---------- regions: detection (§2 rule 1, rule 3) ---------------------
  #
  # "Detects a new region" is two different events and only one of them is a
  # detection: the cold start MINTS a provisional region because a room with no
  # arrival edge has nothing to inherit from, and every room walked into after
  # that inherits and mints nothing. A subsystem that minted one per arrival
  # would put the scope gate above its threshold within three moves and make
  # every later judgement meaningless.

  def test_a_cold_start_mints_exactly_one_provisional_region_and_the_navigator_reads_it
    mud = south_then_north
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "r" })

    move_to(mud, hooks, navigator: navigator.to_proc,
                        limits: { "max_rooms" => 1 }).call(destination: "bakery")

    assert_equal 1, @store.regions.size
    assert M::Regions.provisional_label?(@store.regions.first[:label]),
           "a machine-made label is provenance, not a claim"
    assert_match(/⟨from Market Square⟩ — unconfirmed/, navigator.calls.first["region"],
                 "the unconfirmed tag is the question the `place` field answers")
  end

  def test_walking_into_a_new_room_inherits_rather_than_minting_a_second_region
    mud, = walked_south

    assert_equal 1, @store.regions.size, "arrival is inheritance; only a rootless room seeds"
    assert_equal @store.region_for_room(1)[:id], @store.region_for_room(2)[:id]
    assert_equal "inherited", @store.region_for_room(2)[:basis]
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

  # ---------- regions: naming and splitting in the same leg -------------
  #
  # The two halves of §5 run back to back against the same leg, and `name_region`
  # MERGES when the label already exists — which DELETES the row the payload was
  # built from. `walk_frontier` re-reads the region between the two calls for
  # exactly this reason, and the failure the re-read prevents is silent rather
  # than loud: `region_descendants` of a merged-away id answers with itself,
  # nothing maps to it, `scope_gate_open?` sees zero rooms and closes, and the
  # cartographer is never called at all. A run like that reports a clean pass
  # having observed nothing.
  def test_a_place_that_merges_still_leaves_the_scope_gate_open_for_the_split
    mud, hooks = walked_south
    journal = FakeJournal.new
    # A region the agent named on some earlier walk. Naming the provisional one
    # "Midgaard" now is a merge into this row, not a rename of that one.
    @store.create_region!(label: "Midgaard", confirmed: true)
    provisional = @store.region_for_room(2)[:id]

    cartographer = ScriptedReasoner.new(
      { "split_at_room_id" => 2, "label" => "The Common Quarter", "within" => "Midgaard",
        "reason" => "everything past the south door is residential" }
    )

    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks, journal: journal,
           cartographer: cartographer.to_proc,
           navigator: ScriptedReasoner.new({ "direction" => "north", "reason" => "r",
                                             "place" => "Midgaard",
                                             "scope_suspect" => true,
                                             "scope_reason" => "median is six" }).to_proc,
           limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 1 }).call(destination: "bakery")

    assert_nil @store.region(provisional), "the merge folded the provisional region away"
    assert_equal 1, cartographer.calls.size,
                 "the split must reason about the merged row, not the deleted one"
    refute_nil journal.find("region_named")
    refute_nil journal.find("region_split")
    assert_equal "The Common Quarter", @store.region_for_room(2)[:label]
    assert_equal "Midgaard", @store.region_for_room(1)[:label], "upstream of the boundary is untouched"
    assert_equal "Midgaard", @store.region(@store.region_for_room(2)[:parent_id])[:label],
                 "a quarter nests inside the town rather than replacing it"
  end

  # ---------- regions: the split that cannot be placed -------------------

  # §5.6 reads the boundary off `rooms.arrived_from_room_id`, and the seed room
  # of a cold start has none. The cartographer is given that room in its payload
  # like any other, so it can and will name it.
  def test_a_split_at_a_room_with_no_arrival_edge_writes_no_boundary
    mud, hooks = walked_south
    journal = FakeJournal.new
    cartographer = ScriptedReasoner.new(
      { "split_at_room_id" => 1, "label" => "The Market", "reason" => "the square is its own place" }
    )

    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks, journal: journal,
           cartographer: cartographer.to_proc,
           navigator: ScriptedReasoner.new({ "direction" => "north", "reason" => "r",
                                             "scope_suspect" => true }).to_proc,
           limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 1 }).call(destination: "bakery")

    assert_empty @store.region_boundaries, "no edge to place it on means no boundary"
    assert_nil @store.region_by_label("The Market")
    # The op is still `region_split` — the tool's refusal is carried in `result`
    # rather than in the op name, so anything counting ops has to read it.
    assert_match(/no first-arrival edge/, journal.find("region_split")[:result])
  end

  # A reasoner that raises must not abort a walk that has already moved the
  # character, and must not leave the failure unattributed.
  def test_a_cartographer_that_raises_is_journalled_and_the_walk_still_returns
    mud, hooks = walked_south
    journal = FakeJournal.new

    result = MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks, journal: journal,
                    cartographer: ScriptedReasoner.new(RuntimeError.new("api down")).to_proc,
                    navigator: ScriptedReasoner.new({ "direction" => "north", "reason" => "r",
                                                      "scope_suspect" => true }).to_proc,
                    limits: { "max_rooms" => 1, "min_rooms_for_scope_check" => 1 })
             .call(destination: "bakery")

    assert_match(/\[move_to\] bakery/, result)
    assert_empty @store.region_boundaries
    failed = journal.find("region_split_failed")
    refute_nil failed, "a boundary that failed to appear must not be indistinguishable from one never asked for"
    assert_equal "api down", failed[:error]
    assert_equal %w[south north], mud.move_calls, "the leg was still walked"
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
