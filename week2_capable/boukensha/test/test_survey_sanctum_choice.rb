require_relative "helper"
require "json"

# The deterministic gate for blind_step_recovery.md §4 and §6.
#
# `ClaimPlanner#choose` is arithmetic, so the decision that dropped a survey down
# a well can be replayed exactly. This is that run's own ledger, map and frontier
# hints as they stood on the fifth leg — read out of the session's
# `knowledge.sqlite3` with only the descent's own `opaque` mark cleared, since the
# descent set it — and the assertions are the three lines of the §6 table.
#
# Every other survey test is a hand-built two- or three-room graph, which is how a
# scoring inversion this large went unnoticed: at those sizes the divisor and the
# predicate agree.
class TestSurveySanctumChoice < Minitest::Test
  M = Boukensha::Mud::Memory
  N = Boukensha::Mud::Navigation
  A = Boukensha::Mud::Navigation::Assessment

  FIXTURE = JSON.parse(
    File.read(File.expand_path("fixtures/sanctum_choice_20260731T151434Z.json", __dir__)),
    symbolize_names: true
  ).freeze

  SANCTUM = 5 # The Clerics' Inner Sanctum, where the fifth leg was chosen from
  WELL    = { room_id: 5, direction: "down" }.freeze
  MARKET  = { room_id: 2, direction: "south" }.freeze

  def setup
    @store = M::Store.open(":memory:")
    load_fixture
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown = @store&.close

  def load_fixture
    FIXTURE[:rooms].each do |r|
      @store.create_room(name: r[:name], description: r[:description].to_s,
                         weak_fingerprint: "wf#{r[:id]}",
                         arrived_from: r[:arrived_from_room_id], arrived_direction: r[:arrived_direction])
    end
    FIXTURE[:exits].each do |e|
      @store.record_exits!(e[:room_id], targets: { e[:direction] => e[:target_name] })
      @store.link_exit!(e[:room_id], e[:direction], e[:target_room_id]) if e[:target_room_id]
    end
    FIXTURE[:claims].each do |c|
      id = @store.create_claim!(region_id: nil, statement: c[:statement], predicate: c[:predicate],
                                subject: c[:subject], priority: c[:priority], confidence: c[:confidence],
                                decisive_when: c[:decisive_when], args: args_of(c))
      # C4 was already confirmed by this point in the run, so it contributed
      # nothing to the choice. A fixture that left it open would score four
      # frontiers against a claim the run had finished with.
      @store.settle_claim!(id, status: c[:status], reason: "recorded") unless c[:status] == "open"
    end
    FIXTURE[:frontier_hints].each do |h|
      @store.record_frontier_hint!(room_id: h[:room_id], direction: h[:direction],
                                   expected_class: h[:expected_class], note: h[:note])
    end
    @store.update_player!(current_room_id: SANCTUM)
  end

  # The recorded `args` column is JSON text; a claim with none had none.
  def args_of(claim)
    JSON.parse(claim[:args].to_s)
  rescue JSON::ParserError
    {}
  end

  def planner = N::ClaimPlanner.new(store: @store, region_id: nil)

  def graph = N::SurveyGraph.build(store: @store, here: SANCTUM)

  def score_of(frontier)
    claims = planner.open_claims
    g = graph
    f = g.frontiers.find { |x| x[:room_id] == frontier[:room_id] && x[:direction] == frontier[:direction] }
    refute_nil f, "#{frontier.inspect} is not in the frontier set"
    total = claims.sum { |c| c[:priority].to_f * N::Predicates.score(c, f, g) }
    total / (1 + f[:distance].to_i)
  end

  # The fixture is the run's own state, including the surveyor's written verdict on
  # the well — which nothing could read.
  def test_the_fixture_is_the_recorded_ledger_and_its_hints
    assert_equal 5, @store.rooms.size
    assert_equal "Too dark to tell.", @store.exit_at(*WELL.values_at(:room_id, :direction))[:target_name]

    note = @store.frontier_hints.dig([5, "down"], :note)
    assert_match(/low priority for surface mapping/, note,
                 "the judgement was made and recorded; §4 is about it having no effect")
    assert_equal "commercial", @store.frontier_hints.dig([2, "south"], :expected_class)
  end

  # §5.2 removed the double count, which lifts every distant frontier rather than
  # lowering the near one. Market Square rises from 0.2888 to 0.4575 and the well
  # keeps 1.0800, so this correction alone does not change the decision — the
  # earlier draft of the plan claimed it did, on a mis-derived figure.
  def test_removing_the_double_count_is_not_enough_on_its_own
    assert_in_delta 1.0800, score_of(WELL), 0.0001
    assert_in_delta 0.4575, score_of(MARKET), 0.0001

    assert_equal WELL, planner.choose(graph).frontier.slice(:room_id, :direction),
                 "the divisor still favours the door in the room the agent is standing in"
  end

  # …and with the assessment the surveyor is now asked for, the well is deferred
  # and the survey walks to the frontier a claim's decisive test actually names.
  def test_the_assessment_sends_the_survey_to_market_square
    @store.record_frontier_hint!(room_id: 5, direction: "down", assessability: A::UNASSESSABLE)

    assert_equal MARKET, planner.choose(graph).frontier.slice(:room_id, :direction)
  end

  # The deferral is a threshold, not a ban. With every other door assessed away,
  # the well is what is left and the survey takes it and reports what happened.
  def test_the_well_is_still_available_when_nothing_else_is
    @store.record_frontier_hint!(room_id: 5, direction: "down", assessability: A::UNASSESSABLE)
    graph.frontiers.reject { |f| f[:room_id] == 5 }.each do |f|
      @store.record_frontier_hint!(room_id: f[:room_id], direction: f[:direction],
                                   assessability: A::UNASSESSABLE)
    end

    refute_nil planner.choose(graph)
    assert_equal 7, graph.frontiers.size, "nothing was removed from the set, only ordered"
  end
end
