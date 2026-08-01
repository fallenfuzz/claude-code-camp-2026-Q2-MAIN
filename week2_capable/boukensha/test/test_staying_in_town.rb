require_relative "helper"
require "json"
require "yaml"
require "fileutils"
require "tmpdir"
require "boukensha/testing/session_facts"
require "boukensha/testing/expectations"

# Staying inside the place being surveyed — docs/plans/week_3/movement_revisited/
# staying_in_town.md, and one test per acceptance criterion in its §12.
#
# The run this exists for is 20260731T171650Z-09259cd5, the first
# `explore_midgaard` to pass every mechanical gate and fail on the judge alone.
# It mapped forty-one rooms, eight regions, both gates, the wall road and the
# bridge — and fifteen of those rooms are countryside outside the city walls. The
# survey walked into the fields on three consecutive legs after its own surveyor
# had written that the fields were out of scope; travel walked out of both gates
# because the player asked for bearings rather than places; and the constraint the
# run was graded on was never written anywhere the run could read it.
#
# Everything below is arithmetic, a scripted MUD and a scripted reasoner. There
# is no model, no network and no key, which is the same trade `test_survey.rb`
# and `test_move_to.rb` already make.
class TestStayingInTown < Minitest::Test
  H  = Boukensha::Mud::Hooks
  M  = Boukensha::Mud::Memory
  N  = Boukensha::Mud::Navigation
  MT = Boukensha::Mud::Navigation::MoveTo
  SF = Boukensha::Testing::SessionFacts
  EX = Boukensha::Testing::Expectations

  TRANSCRIPTS = JSON.parse(
    File.read(File.expand_path("fixtures/mud_transcripts.json", __dir__))
  ).freeze

  MARKET_SQUARE_MOVE = "\e[0;33mMarket Square\e[0m\r\n   You are standing on the market square, the famous " \
                       "Square of Midgaard.\r\nRoads lead in every direction.\r\n\e[0;36m[ Exits: n e s w ]" \
                       "\e[0m\r\n\r\n20H 100M 81V (news) (motd) > ".freeze

  MARKET_SQUARE = {
    "look" => MARKET_SQUARE_MOVE,
    "check:exits" => "Obvious exits:\r\nnorth - The Temple Square\r\neast  - Main Street\r\n" \
                     "south - The Common Square\r\nwest  - Main Street\r\n\r\n20H 100M 81V > ",
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

  DARK_ALLEY_MOVE = "\e[0;33mThe Dark Alley\e[0m\r\n   A narrow alley between two buildings.\r\n" \
                    "\e[0;36m[ Exits: w ]\e[0m\r\n\r\n20H 100M 80V > ".freeze

  DARK_ALLEY = {
    "look" => DARK_ALLEY_MOVE,
    "check:exits" => "Obvious exits:\r\nwest  - The Common Square\r\n\r\n20H 100M 80V > ",
    "check:score" => "This ranks you as Dummy the Man (level 1).\r\n20H 100M 80V > ",
    "poll" => ""
  }.freeze

  class ScriptedMud
    attr_reader :move_calls

    def initialize(start_fixtures:, moves: [], polls: [])
      @current    = start_fixtures.dup
      @moves      = moves.dup
      @polls      = polls.dup
      @move_calls = []
    end

    def nav_call_tool
      lambda do |name, args = {}|
        case name
        when "tbamud__move"
          @move_calls << args["direction"]
          step = @moves.shift || {}
          @current = step[:fixtures] if step[:fixtures]
          step[:text].to_s
        when "tbamud__poll" then @polls.shift.to_s
        else ""
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

  class ScriptedReasoner
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls   = []
    end

    def to_proc
      lambda do |payload|
        @calls << payload
        @answers.shift || {}
      end
    end
  end

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

  SEED = {
    "open" => [
      { "statement" => "Midgaard is a settlement of walkable, bounded extent",
        "predicate" => "extent_bounded", "subject" => "Midgaard", "priority" => 0.9, "confidence" => 0.3,
        "decisive_when" => "every in-scope frontier is drained" }
    ]
  }.freeze

  # The scope tests need a claim that does NOT answer itself the moment the
  # frontier set is fenced. `extent_bounded` does exactly that and correctly —
  # a town whose only remaining exits are the gate roads is a town of bounded
  # extent — so it would end the survey with a finding rather than with the
  # `region_exhausted` report those two cases are about.
  SEED_COMPOSITION = {
    "open" => [
      { "statement" => "Midgaard's offerings span a describable set of classes",
        "predicate" => "composition", "subject" => "Midgaard", "priority" => 1.0, "confidence" => 0.2,
        "decisive_when" => "every named class has a confirmed instance",
        "args" => { "classes" => %w[commercial civic], "classes_observed" => %w[commercial] } }
    ]
  }.freeze

  def south_to_common_square
    ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE }],
      polls: [""] * 8
    )
  end

  # Every exit out of Market Square marked as leaving the town, which is the
  # shape §12.1 and §12.2 both ask about: a map on which the only remaining leads
  # are all egress.
  def fence_market_square
    %w[north east south west].each do |direction|
      @store.record_frontier_hint!(room_id: 1, direction: direction, egress: "leaves",
                                   expected_class: "civic", assessability: "assessable",
                                   note: "open countryside beyond the town boundary")
    end
  end

  # ---------- §12.1 region scope never selects a known egress ---------------

  # The correction the review of the first draft asked for, and it is the whole
  # difference between a soft rule and a usable one. Deferral would let a
  # `leaves` frontier be taken once everything better had drained, and §8 shows
  # the system cannot reconstruct afterwards which side of the wall a room is on
  # — so the result is not a recoverable mistake, it is a permanently
  # mislabelled fixture. The honest answer to having no legal move is a report.
  def test_region_scope_walks_nothing_when_every_lead_leaves_the_place
    mud = south_to_common_square
    hooks = hooks_at_market_square(mud)
    fence_market_square

    result = move_to(mud, hooks, surveyor: ScriptedReasoner.new(SEED_COMPOSITION).to_proc)
             .call(survey: "how big is this town", scope: "region")

    assert_empty mud.move_calls, "an exit the surveyor says leaves Midgaard is not a lead of last resort"
    assert_match(/every remaining frontier leaves this region/, result)
    assert_equal 1, @store.player[:current_room_id]
  end

  # The remedy travels with the refusal. `region_exhausted` is "a question rather
  # than a wall" (boundaries_revised.md §2), so the player is told the call that
  # would proceed anyway rather than being left to guess.
  def test_the_report_names_the_widening_call
    mud = south_to_common_square
    hooks = hooks_at_market_square(mud)
    fence_market_square
    result = move_to(mud, hooks, surveyor: ScriptedReasoner.new(SEED_COMPOSITION).to_proc)
             .call(survey: "how big is this town", scope: "region")

    assert_match(/scope: "world"/, result)
  end

  # ---------- §12.2 world scope may select it ------------------------------

  # Nothing here bans leaving a place. `scope: "world"` lifts the constraint, and
  # every survey-side consumer is conditional on the resolved scope so that it
  # does — which is what keeps `find_hermit_mapped` passing, a case entirely
  # about widening deliberately because a hermit by definition lives away from
  # people.
  def test_world_scope_walks_the_same_frontier_the_region_scope_refused
    mud = south_to_common_square
    hooks = hooks_at_market_square(mud)
    fence_market_square

    move_to(mud, hooks, surveyor: ScriptedReasoner.new(SEED_COMPOSITION).to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "how big is this town", scope: "world")

    refute_empty mud.move_calls, "a player who asked to leave is not told it cannot"
  end

  # And no egress-specific penalty applies once it is eligible: the frontier is
  # scored by its assessability tier and its claim contributions like any other.
  # `extent_bounded` is the exception and is deliberately scope-independent — it
  # is the predicate stating what its own statement means, not a permission rule,
  # and crossing the edge of a place tells you nothing about the extent of the
  # place on an expedition either.
  def test_world_scope_keeps_a_leaves_frontier_in_the_candidate_set
    exits = [{ room_id: 1, direction: "north", target_name: "The Field", target_room_id: nil },
             { room_id: 1, direction: "east", target_name: "Main Street", target_room_id: nil }]
    hints = { [1, "north"] => { egress: "leaves" } }
    graph = N::SurveyGraph.new(here: 1, rooms: [{ id: 1, name: "Market Square" }], exits: exits,
                               hints: hints, distances: { 1 => 0 })

    assert_equal 2, graph.frontiers.size, "world scope is scope_room_ids nil, and nothing is excluded"
    assert graph.leaves?(graph.frontiers.find { |f| f[:direction] == "north" })
  end

  # ---------- §12.3 the travel veto precedes the movement command ----------

  # The correction to the first draft, which said the call ended "after the step"
  # while describing an exit that had been declined. The two cannot both be true,
  # and stopping after the step would leave travel one room outside town on every
  # attempt — which is precisely what `max_rooms_outside_scope: 0` forbids.
  def test_a_leaves_region_answer_stops_the_walk_before_any_move_is_sent
    mud = south_to_common_square
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new(
      { "direction" => "south", "reason" => "the destination is west along Main Street",
        "leaves_region" => true }
    )

    result = move_to(mud, hooks, navigator: navigator.to_proc)
             .call(destination: "Main Street heading west", scope: "region")

    assert_empty mud.move_calls, "no tbamud__move is dispatched for a declined exit"
    assert_equal 1, @store.player[:current_room_id], "the agent has not moved"
    assert_match(/south from here/, result)
    assert_match(/leaves/, result)
  end

  # The refusal hands the decision back rather than swallowing it: the player
  # keeps the judgement and gets it back with a model call to spend on it,
  # instead of losing five rooms of budget to a bearing.
  def test_the_refusal_names_the_call_that_would_proceed_anyway
    mud = south_to_common_square
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "east", "leaves_region" => true })
    journal = FakeJournal.new

    result = move_to(mud, hooks_at_market_square(mud), navigator: navigator.to_proc, journal: journal)
             .call(destination: "Main Street heading west")

    assert_match(/scope: "world"/, result)
    refute_nil journal.find("egress_refused")
  end

  # Under `scope: "world"` the field is still required and still journalled — it
  # is what marks the crossing — but it does not stop anything.
  def test_world_scope_records_the_crossing_instead_of_refusing_it
    mud = south_to_common_square
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new(
      { "direction" => "south", "reason" => "out of town", "leaves_region" => true }
    )

    move_to(mud, hooks, navigator: navigator.to_proc, limits: { "max_rooms" => 1 })
      .call(destination: "the wilderness", scope: "world")

    assert_equal ["south"], mud.move_calls
    egress = @store.region_boundaries.select { |b| b[:kind] == "egress" }
    assert_equal 1, egress.size
    assert_equal [1, 2, "south"], egress.first.values_at(:from_room_id, :to_room_id, :direction)
  end

  # An egress row is not a region declaration and must never become one.
  # `Regions.derive` reads a boundary's `to_room_id` as a root that starts a
  # region there, and the field beyond the gate does not start the town.
  def test_an_egress_row_does_not_declare_a_region
    mud = south_to_common_square
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "out", "leaves_region" => true })
    move_to(mud, hooks, navigator: navigator.to_proc, limits: { "max_rooms" => 1 })
      .call(destination: "the wilderness", scope: "world")

    assert_equal @store.room_regions[1][:region_id], @store.room_regions[2][:region_id],
                 "walking out of a place does not make the far side the start of a new one"
  end

  # ---------- §12.4 scope membership follows crossings, not labels ---------

  # The objection that defeated the first draft, tested directly. A `split` is an
  # internal division — Market Square into a Market District — and crossing one
  # is not leaving. Only a recorded `egress` removes anything from the graph, so
  # the temple, the city wall, the quarters and both banks of the river all stay
  # in scope however the cartographer later re-parents them.
  def test_a_split_boundary_is_not_a_departure
    walk_south_and_back
    @store.declare_boundary!(from_room_id: 1, to_room_id: 2, direction: "south",
                             region_id: region_id_for(2), reason: "a distinct quarter",
                             kind: M::Store::BOUNDARY_SPLIT)

    inside = N::RoutePlanner.reachable_within(exits: @store.all_exits, from: 1,
                                              blocked: @store.egress_edges)
    assert_includes inside, 2, "a quarter of a town is still in the town"
  end

  def test_an_egress_boundary_is_a_departure
    walk_south_and_back
    @store.declare_boundary!(from_room_id: 1, to_room_id: 2, direction: "south",
                             region_id: region_id_for(1), reason: "out of the gate",
                             kind: M::Store::BOUNDARY_EGRESS)

    inside = N::RoutePlanner.reachable_within(exits: @store.all_exits, from: 1,
                                              blocked: @store.egress_edges)
    refute_includes inside, 2
    assert_includes inside, 1
  end

  # Undirected, and deliberately: the question is which side of the wall a room
  # is on, and a room reached through a one-way drop is still on the side it
  # landed on. Walking back in through a gate crosses the same wall as walking
  # out through it.
  def test_the_crossing_blocks_the_way_back_as_well_as_the_way_out
    walk_south_and_back
    @store.declare_boundary!(from_room_id: 1, to_room_id: 2, direction: "south",
                             region_id: region_id_for(1), kind: M::Store::BOUNDARY_EGRESS)

    inside = N::RoutePlanner.reachable_within(exits: @store.all_exits, from: 2,
                                              blocked: @store.egress_edges)
    refute_includes inside, 1
  end

  # ---------- §12.5 the backstop ends the call with the way back -----------

  # It should almost never fire, and it exists for what the veto and the planner
  # do not cover: a navigator that answered `false` about a gate it misread. What
  # makes it able to fire at all is that a crossing recorded once stays recorded
  # — the first walk through a gate is not caught, because nothing had yet said
  # the gate was a gate, and every later walk through it is.
  def test_a_leg_that_lands_beyond_a_recorded_crossing_ends_the_call
    mud, hooks = replanted_at_market_square
    @store.declare_boundary!(from_room_id: 1, to_room_id: 2, direction: "south",
                             region_id: region_id_for(1), reason: "out of the gate",
                             kind: M::Store::BOUNDARY_EGRESS)
    navigator = ScriptedReasoner.new(
      { "direction" => "south", "reason" => "the alley is south of the square", "leaves_region" => false }
    )

    result = move_to(mud, hooks, navigator: navigator.to_proc).call(destination: "The Dark Alley")

    assert_match(/stopped/, result)
    assert_match(/this leaves/, result)
    # The leg ran to its end and the call stopped after it. The backstop
    # overshoots by exactly one room, which is the price of not having to predict
    # anything — it is a backstop rather than a mechanism, and the veto in §10.3
    # is what is supposed to prevent the crossing.
    assert_equal %w[south south], mud.move_calls
  end

  # The edge it records is the one actually crossed, walked forward from where
  # the leg began — not wherever the leg happened to finish. That distinction is
  # §7's complaint about the judge restated as arithmetic: a judge grading
  # boundary-crossing from call arguments kept pointing at the wrong call,
  # because every crossing in the recorded run happened inside a leg whose
  # arguments look innocuous.
  def test_the_recorded_edge_is_the_crossing_and_not_the_end_of_the_leg
    mud, hooks = replanted_at_market_square
    @store.declare_boundary!(from_room_id: 1, to_room_id: 2, direction: "south",
                             region_id: region_id_for(1), kind: M::Store::BOUNDARY_EGRESS)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "south", "leaves_region" => false })

    move_to(mud, hooks, navigator: navigator.to_proc).call(destination: "The Dark Alley")

    recorded = @store.region_boundaries.select { |b| b[:kind] == "egress" }.last
    assert_equal [1, 2, "south"], recorded.values_at(:from_room_id, :to_room_id, :direction),
                 "the crossing is Market Square → The Common Square, not the far end of the walk"
    refute_equal 2, @store.player[:current_room_id], "and the agent really did overshoot"
  end

  # The recovery §10.5 owes, and the reason it is named as a ROOM rather than as
  # a direction: `from_room_id` is by construction a room the agent has stood in,
  # so `plan_route` answers `known`, `move_to` dispatches to `walk_known`, and the
  # known branch takes no navigator and no candidate list at all. It therefore
  # cannot hit the defect §5 documents, where a navigator answering `west` toward
  # the gate was overruled twice because the way back was already explored and so
  # not a frontier candidate.
  def test_the_backstop_report_carries_a_route_home_that_resolves
    mud, hooks = replanted_at_market_square
    @store.declare_boundary!(from_room_id: 1, to_room_id: 2, direction: "south",
                             region_id: region_id_for(1), kind: M::Store::BOUNDARY_EGRESS)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "south", "leaves_region" => false })

    result = move_to(mud, hooks, navigator: navigator.to_proc).call(destination: "The Dark Alley")

    assert_match(/back: move_to\(destination: "Market Square"\)/, result)
    assert_match(/known route/, result)

    # And it is a route, not a sentence: the same destination resolves through
    # `plan_route` as `known` with a non-empty step list back to the room the
    # boundary names.
    plan, = N::PlanRouteTool.resolve(store: @store, destination: "Market Square", scope: "world")
    assert_equal "known", plan.status
    refute_empty plan.steps
    assert_equal 1, plan.destination_room
  end

  # The crossing it fired on is recorded, so the next call does not have to
  # rediscover it and §13's measure can count what is behind it.
  def test_the_backstop_records_the_crossing_it_fired_on
    mud, hooks = replanted_at_market_square
    @store.declare_boundary!(from_room_id: 1, to_room_id: 2, direction: "south",
                             region_id: region_id_for(1), kind: M::Store::BOUNDARY_EGRESS)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "south", "leaves_region" => false })
    journal = FakeJournal.new

    move_to(mud, hooks, navigator: navigator.to_proc, journal: journal).call(destination: "The Dark Alley")

    refute_nil journal.find("egress_recorded")
    assert_equal 2, @store.region_boundaries.count { |b| b[:kind] == "egress" }
  end

  # The survey gets the same backstop, and it is the mode §10.4 names the
  # uncovered cases for: "a hint that was absent" is a surveyor that was never
  # asked about an exit, or was asked and said nothing. Under region scope the
  # planner never offers a frontier the surveyor called `leaves`, so this only
  # catches a crossing nothing predicted — one room late, which is the price of
  # not having to predict anything.
  def test_a_survey_leg_beyond_a_recorded_crossing_ends_the_survey
    mud, hooks = replanted_at_market_square
    @store.declare_boundary!(from_room_id: 1, to_room_id: 2, direction: "south",
                             region_id: region_id_for(1), kind: M::Store::BOUNDARY_EGRESS)
    # No hint on room 1's south exit at all, which is exactly the case: nothing
    # said the gate was a gate, so the planner offered it like any other lead.
    result = move_to(mud, hooks, surveyor: ScriptedReasoner.new(SEED_COMPOSITION).to_proc)
             .call(survey: "how big is this town", scope: "region")

    assert_match(/walked out of the place being surveyed/, result)
    assert_match(/move_to\(destination: "Market Square"\) walks back/, result)
    assert_equal 2, @store.region_boundaries.count { |b| b[:kind] == "egress" }
  end

  # ---------- §12.6 egress defaults to in-scope ----------------------------

  # The regression that says the change is opt-in rather than a new global rule.
  # A map with no hints at all is every map before a surveyor has run on it, and
  # it must walk exactly as it walked yesterday.
  def test_a_map_with_no_hints_offers_every_frontier_under_region_scope
    exits = %w[north east south west].map do |direction|
      { room_id: 1, direction: direction, target_name: "Somewhere", target_room_id: nil }
    end
    graph = N::SurveyGraph.new(here: 1, rooms: [{ id: 1, name: "Market Square" }], exits: exits,
                               distances: { 1 => 0 }, scope_room_ids: [1])

    assert_equal 4, graph.frontiers.size
    graph.frontiers.each do |frontier|
      assert_equal N::Egress::INTERIOR, graph.egress(frontier), "silence permits"
      refute graph.leaves?(frontier)
      assert_in_delta 1.0, N::Predicates.score_extent_bounded(nil, frontier, graph), 1e-9
    end
  end

  # And the cold walk really is unchanged end to end, not merely at the graph.
  def test_a_cold_survey_walks_exactly_as_it_did_before
    mud = south_to_common_square
    move_to(mud, hooks_at_market_square(mud), surveyor: ScriptedReasoner.new(SEED).to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "how big is this town")

    refute_empty mud.move_calls
  end

  # `leaves` is a claim about geography rather than about interest, and a
  # surveyor that invents a value must not thereby impose a fence — the same
  # rule, inverted, that stops an invented assessability granting permission.
  def test_an_unrecognised_egress_answer_is_treated_as_no_answer
    mud = south_to_common_square
    surveyor = ScriptedReasoner.new(SEED.merge(
      "hints" => [{ "room_id" => 1, "direction" => "north", "egress" => "probably outside" }]
    ))
    move_to(mud, hooks_at_market_square(mud), surveyor: surveyor.to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "how big is this town")

    assert_nil @store.frontier_hints.dig([1, "north"], :egress)
  end

  # `boundary` is the third value and it stays IN scope, because a claim about
  # what bounds a place is settled by standing on the bound — and because
  # "Inside The East Gate Of Midgaard" is a room in the town.
  def test_a_boundary_exit_is_not_a_departure
    exits = [{ room_id: 1, direction: "east", target_name: "Inside The East Gate", target_room_id: nil }]
    graph = N::SurveyGraph.new(here: 1, rooms: [{ id: 1, name: "Main Street" }], exits: exits,
                               hints: { [1, "east"] => { egress: "boundary" } },
                               distances: { 1 => 0 }, scope_room_ids: [1])

    assert_equal 1, graph.frontiers.size
    refute graph.leaves?(graph.frontiers.first)
  end

  # ---------- the predicate pair (§10.2) -----------------------------------

  # §3.3's arithmetic, corrected. The flat constant is what chose leg 6 of the
  # recorded run: C2 contributed 0.9 unconditionally to a frontier underfoot
  # while the nearest street frontier was three moves away and divided by four.
  def test_extent_bounded_scores_an_exit_that_leaves_at_zero
    graph = fenced_graph
    leaving = graph.frontiers.find { |f| f[:direction] == "north" }
    staying = graph.frontiers.find { |f| f[:direction] == "east" }

    assert_in_delta 0.0, N::Predicates.score_extent_bounded(nil, leaving, graph), 1e-9
    assert_in_delta 1.0, N::Predicates.score_extent_bounded(nil, staying, graph), 1e-9
  end

  # A town whose streets are all walked and whose only remaining exits are the
  # gate roads is a town of bounded extent, and that is precisely the observation
  # the claim was opened to make. On the recorded run C2 settled `unresolved`
  # with The Great Field Of Midgaard recorded as evidence AGAINST it.
  def test_extent_bounded_confirms_when_only_leaving_exits_remain
    graph = N::SurveyGraph.new(
      here: 1, rooms: [{ id: 1, name: "Market Square" }],
      exits: [{ room_id: 1, direction: "north", target_name: "The Field", target_room_id: nil }],
      hints: { [1, "north"] => { egress: "leaves" } }, distances: { 1 => 0 }
    )
    claim = { predicate: "extent_bounded", args: {}, subject: "Midgaard" }

    status, reason = N::Predicates.settle(claim, graph)
    assert_equal "confirmed", status
    assert_match(/stays in the place/, reason)
  end

  # §3.2, closed. Writing an honest "out of scope" hint used to make an exit MORE
  # attractive: the surveyor must pick `expected_class` from the claims' own
  # vocabulary, answered `civic` for an open field because there was nothing else
  # to answer, and `civic` was a class two open claims were looking for. The
  # warning and the promotion travelled in the same record and only the promotion
  # had a consumer.
  def test_a_leaving_frontier_is_never_promoted_by_a_claim_that_wants_its_class
    graph = N::SurveyGraph.new(
      here: 1, rooms: [{ id: 1, name: "Behind The Temple Altar" }],
      exits: [{ room_id: 1, direction: "north", target_name: "The Great Field", target_room_id: nil }],
      hints: { [1, "north"] => { expected_class: "civic", assessability: "unassessable", egress: "leaves" } },
      distances: { 1 => 0 }
    )
    claim = { id: 1, predicate: "exists", priority: 1.0,
              args: { "class" => "civic", "classes_observed" => [] } }
    planner = N::ClaimPlanner.new(store: @store, region_id: nil)

    refute planner.claimed?(graph.frontiers.first, graph, [claim])
  end

  # ---------- §12.7 the scenario carries the constraint --------------------

  # §6 is a defect in the harness rather than in the movement subsystem, and it
  # is the cheapest change in the whole proposal. The rule lived only in
  # `evaluation.undesired_behaviour`, which the tier-2 judge reads and the agent
  # cannot — so the agent knew the difference between the town and the
  # countryside, noticed each departure within one iteration, spent five of its
  # twenty model calls walking back, and was never told that avoiding the
  # departures was part of the task.
  #
  # The split is right for questions about CONDUCT, where an agent told it will
  # be marked down for repeating a destination learns to hide the repetition
  # rather than to stop needing it. It is wrong for a constraint on the task
  # itself: a constraint the agent cannot read can only be satisfied by luck.
  def test_explore_midgaard_states_the_rule_to_the_agent_and_to_the_judge
    scenario = YAML.load_file(
      File.expand_path("../../../.boukensha/tests/scenarios/explore_midgaard.yml", __dir__)
    )

    assert_match(/stay inside midgaard/i, scenario["goal"],
                 "the goal is the only part of the scenario that reaches the player's context")
    assert_match(/should not leave Midgaard/, scenario.dig("evaluation", "undesired_behaviour"),
                 "and the judge's rubric still names it too")
    assert_equal 0, scenario["expect"]["max_rooms_outside_scope"]
  end

  # ---------- §13 the measure ----------------------------------------------

  # `rooms_known_delta` already appears in the report and says nothing about
  # where the rooms are. This is the number that does, and it is computed from
  # recorded crossings rather than from region identity — the first draft
  # anchored on "the region in which the first movement began", and that region
  # was a one-room placeholder that later grew to hold five town rooms and five
  # field rooms and never distinguished them.
  def test_rooms_outside_scope_counts_what_is_behind_a_recorded_crossing
    dir = Dir.mktmpdir
    facts = facts_over(dir, egress: [[1, 2, "south"]])

    assert_equal 2, facts.rooms_outside_scope, "rooms 2 and 3 sit behind the gate"
    assert EX.passed?(EX.evaluate({ "max_rooms_outside_scope" => 2 }, facts))
    refute EX.passed?(EX.evaluate({ "max_rooms_outside_scope" => 0 }, facts))
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # With nothing recorded, every room is on the same side of nothing — which is
  # the honest answer for a run that never left, and the same answer this
  # projection gave before it could see crossings at all.
  def test_rooms_outside_scope_is_zero_when_no_crossing_was_recorded
    dir = Dir.mktmpdir
    assert_equal 0, facts_over(dir, egress: []).rooms_outside_scope
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # A split is not a crossing, which is §12.4 restated where the harness reads it.
  def test_a_split_does_not_count_against_the_measure
    dir = Dir.mktmpdir
    facts = facts_over(dir, egress: [], splits: [[1, 2, "south"]])

    assert_equal 0, facts.rooms_outside_scope
    assert_empty facts.region_splits.select { |s| s[:room_id] == 3 }
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  private

  # Market Square (1) --south--> The Common Square (2), and back, so both rooms
  # are walked and the agent is standing in room 1 again.
  def walk_south_and_back
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE },
              { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }],
      polls: [""] * 8
    )
    hooks = hooks_at_market_square(mud)
    navigator = ScriptedReasoner.new({ "direction" => "south", "reason" => "exploring" })
    move_to(mud, hooks, navigator: navigator.to_proc, limits: { "max_rooms" => 1 })
      .call(destination: "The Common Square")
    move_to(mud, hooks, navigator: ScriptedReasoner.new.to_proc).call(destination: "Market Square")
    [mud, hooks]
  end

  # The same two rooms walked, then a fresh MUD scripted for the leg the backstop
  # is about: south into The Common Square, which is behind the recorded
  # crossing, and on south again into a room beyond it. The leg runs to its end
  # and the call stops after it, which is the overshoot the backstop accepts.
  def replanted_at_market_square
    walk_south_and_back
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE },
              { text: DARK_ALLEY_MOVE, fixtures: DARK_ALLEY }],
      polls: [""] * 8
    )
    [mud, H.new(store: @store, call_tool: mud.hook_call_tool, warn_to: nil)]
  end

  def region_id_for(room_id) = @store.region_for_room(room_id)[:id]

  def fenced_graph
    exits = [{ room_id: 1, direction: "north", target_name: "The Great Field", target_room_id: nil },
             { room_id: 1, direction: "east", target_name: "Main Street", target_room_id: nil }]
    N::SurveyGraph.new(here: 1, rooms: [{ id: 1, name: "Market Square" }], exits: exits,
                       hints: { [1, "north"] => { egress: "leaves" } }, distances: { 1 => 0 })
  end

  # A three-room chain — 1 --south--> 2 --south--> 3 — in a database on disk,
  # plus a session log and a journal naming room 1 as where the walking began.
  def facts_over(dir, egress: [], splits: [])
    db_path = File.join(dir, "knowledge.sqlite3")
    store = M::Store.open(db_path)
    build_chain(store, egress: egress, splits: splits)
    store.close

    id = "20260731T171719Z-e39eb364"
    log = File.join(dir, "#{id}.jsonl")
    File.write(log, JSON.generate(phase: "session_start", session_id: id, at: "2026-07-31T17:17:19.000Z"))
    journal_dir = File.join(dir, "journal")
    FileUtils.mkdir_p(journal_dir)
    File.write(File.join(journal_dir, "20260731.jsonl"),
               JSON.generate(kind: "event", stream: "move_to", op: "answered", session_id: id,
                             destination: "walk Midgaard", rooms_walked: 3, from_room_id: 1))
    SF.load(log, knowledge_db: db_path, journal_dir: journal_dir)
  end

  def build_chain(store, egress:, splits:)
    3.times do |i|
      name = "Room #{i + 1}"
      store.create_room(name: name, description: "A place.",
                        weak_fingerprint: M::Fingerprint.weak(name: name, description: "A place.", exit_dirs: []))
    end
    [[1, 2], [2, 3]].each do |from, to|
      store.record_exits!(from, targets: { "south" => "Room #{to}" })
      store.link_exit!(from, "south", to)
      store.record_exits!(to, targets: { "north" => "Room #{from}" })
      store.link_exit!(to, "north", from)
    end
    region = store.region_for_room(1)
    (egress.map { |e| [e, M::Store::BOUNDARY_EGRESS] } +
     splits.map { |s| [s, M::Store::BOUNDARY_SPLIT] }).each do |(from, to, direction), kind|
      store.declare_boundary!(from_room_id: from, to_room_id: to, direction: direction,
                              region_id: region[:id], kind: kind)
    end
  end
end
