require_relative "helper"

# The claim ledger and the deterministic planner over it — docs/plans/week_3/
# movement_revisited/claims.md.
#
# The property every one of these is protecting is that survey behaviour is
# ARITHMETIC. The surveyor writes claims and never names a frontier, so the same
# ledger over the same map must always produce the same next leg, and every
# claim must have a settlement condition a computation can check.
class TestClaims < Minitest::Test
  M  = Boukensha::Mud::Memory
  N  = Boukensha::Mud::Navigation
  P  = Boukensha::Mud::Navigation::Predicates

  def setup
    @store = M::Store.open(":memory:")
    @ledger = N::ClaimLedger.new(store: @store, region_id: nil)
    @planner = N::ClaimPlanner.new(store: @store, region_id: nil)
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown = @store&.close

  def room(name, description: "A place.")
    @store.create_room(name: name, description: description,
                       weak_fingerprint: M::Fingerprint.weak(name: name, description: description, exit_dirs: []))
  end

  # A graph built by hand rather than walked, so a predicate can be pinned
  # against a topology chosen to exercise it.
  def graph(here:, rooms:, exits:, hints: {}, feature_rooms: {})
    N::SurveyGraph.new(
      here: here, rooms: rooms, exits: exits, hints: hints, feature_rooms: feature_rooms,
      distances: N::RoutePlanner.distances(exits: exits, from: here)
    )
  end

  def frontier(room_id, direction, target_name: nil)
    { room_id: room_id, direction: direction, target_name: target_name, target_room_id: nil }
  end

  # ---------- validation: what may enter the ledger ------------------------

  def test_a_predicate_outside_the_vocabulary_is_rejected
    @ledger.apply!("open" => [{ "statement" => "The town is prosperous", "predicate" => "vibes",
                                "decisive_when" => "it feels rich" }])

    assert_empty @store.claims
    assert_match(/not in the vocabulary/, @ledger.rejected.first[:reason])
  end

  # The rule that keeps unfalsifiable statements out. A claim with no decisive
  # test would sit open forever, contributing to frontier scoring and never
  # being answerable — which is precisely the failure the coverage design had.
  def test_a_claim_with_no_decisive_test_is_rejected
    @ledger.apply!("open" => [{ "statement" => "Midgaard is pleasant", "predicate" => "composition" }])

    assert_empty @store.claims
    assert_match(/decisive test/, @ledger.rejected.first[:reason])
  end

  def test_a_re_proposed_claim_merges_rather_than_forking_the_ledger
    spec = { "statement" => "Midgaard's offerings span classes", "predicate" => "composition",
             "subject" => "Midgaard", "decisive_when" => "every class has an instance",
             "args" => { "classes" => %w[civic religious], "classes_observed" => %w[religious] },
             "evidence" => [{ "polarity" => "support", "note" => "a temple" }] }
    @ledger.apply!("open" => [spec])
    @ledger.apply!("open" => [spec.merge("statement" => "Midgaard offers several kinds of place",
                                         "args" => { "classes_observed" => %w[commercial] },
                                         "evidence" => [{ "polarity" => "support", "note" => "a market" }])])

    assert_equal 1, @store.claims.size, "same predicate and subject is the same proposition"
    claim = @store.claims.first
    assert_equal %w[religious commercial], claim[:args]["classes_observed"],
                 "argument lists grow; a shorter answer never means the rest are gone"
    assert_equal 2, @store.claim_evidence(claim[:id]).size, "evidence accumulates in one place"
  end

  def test_evidence_records_disconfirmation_as_first_class
    @ledger.apply!("open" => [{ "statement" => "There is a second bridge", "predicate" => "exists",
                                "subject" => "class:bridge", "decisive_when" => "a bridge is classified",
                                "args" => { "class" => "bridge" },
                                "evidence" => [{ "polarity" => "contradict", "note" => "the river ends here" }] }])

    assert_equal "contradict", @store.claim_evidence(@store.claims.first[:id]).first[:polarity]
  end

  # ---------- predicates: settlement is a computation ----------------------

  def test_composition_confirms_when_every_named_class_has_an_instance
    claim = { predicate: "composition", rooms_spent: 4,
              args: { "classes" => %w[civic religious], "classes_observed" => %w[religious civic] } }

    assert_equal "confirmed", P.settle(claim, graph(here: 1, rooms: [], exits: []))&.first
  end

  # The saturation rule: what stops a `composition` claim running forever when
  # the class list it was seeded with was never going to be completed.
  def test_composition_confirms_on_saturation_when_no_new_class_appears
    claim = { predicate: "composition", rooms_spent: 9,
              args: { "classes" => %w[civic religious transport], "classes_observed" => %w[religious civic],
                      "last_class_at_rooms" => 2 } }
    verdict = P.settle(claim, graph(here: 1, rooms: [], exits: []), limits: { "survey_saturation_rooms" => 6 })

    assert_equal "confirmed", verdict.first
    assert_match(/no new class of place in 7 rooms/, verdict.last)
  end

  def test_extent_bounded_confirms_when_the_frontier_set_drains
    drained = graph(here: 1, rooms: [{ id: 1, name: "Here" }], exits: [])
    open    = graph(here: 1, rooms: [{ id: 1, name: "Here" }], exits: [frontier(1, "north")])
    claim   = { predicate: "extent_bounded", rooms_spent: 3, args: {} }

    assert_equal "confirmed", P.settle(claim, drained)&.first
    assert_nil P.settle(claim, open)
  end

  # `circuit_closes` is the claim the whole design was motivated by: a road that
  # comes back round is a cycle in the feature's own subgraph, which is a
  # computation and not a judgement.
  def test_circuit_closes_confirms_when_the_feature_chain_re_enters_itself
    rooms = (1..3).map { |i| { id: i, name: "Wall #{i}" } }
    ring  = [{ room_id: 1, direction: "east", target_room_id: 2 },
             { room_id: 2, direction: "east", target_room_id: 3 },
             { room_id: 3, direction: "west", target_room_id: 1 }]
    claim = { predicate: "circuit_closes", subject: "feature:wall_road", rooms_spent: 3, args: {} }
    closed = graph(here: 1, rooms: rooms, exits: ring, feature_rooms: { "wall_road" => [1, 2, 3] })

    assert_equal "confirmed", P.settle(claim, closed)&.first
  end

  def test_circuit_closes_is_refuted_when_the_chain_ends_with_nowhere_to_go
    rooms = (1..3).map { |i| { id: i, name: "Wall #{i}" } }
    chain = [{ room_id: 1, direction: "east", target_room_id: 2 },
             { room_id: 2, direction: "east", target_room_id: 3 }]
    claim = { predicate: "circuit_closes", subject: "feature:wall_road", rooms_spent: 3, args: {} }
    dead  = graph(here: 1, rooms: rooms, exits: chain, feature_rooms: { "wall_road" => [1, 2, 3] })

    assert_equal "refuted", P.settle(claim, dead)&.first
  end

  # `region_distinct` replaces the navigator's `scope_suspect` side channel, and
  # the difference is that it can be refuted rather than only ever escalating.
  def test_region_distinct_confirms_on_a_single_entrance_and_is_refuted_on_two
    one_way = [{ room_id: 1, direction: "east", target_room_id: 2 },
               { room_id: 2, direction: "east", target_room_id: 3 }]
    two_way = one_way + [{ room_id: 1, direction: "south", target_room_id: 3 }]
    rooms   = (1..3).map { |i| { id: i, name: "Room #{i}" } }
    claim   = { predicate: "region_distinct", subject: "subset", rooms_spent: 2,
                args: { "rooms" => [2, 3] } }

    assert_equal "confirmed", P.settle(claim, graph(here: 1, rooms: rooms, exits: one_way))&.first
    assert_equal "refuted", P.settle(claim, graph(here: 1, rooms: rooms, exits: two_way))&.first
  end

  # ---------- scoring: strategy is a consequence, not a decision -----------

  # The clearest single illustration of what the model buys. The navigator had
  # no way to express "we already know what an inn is"; `composition` expresses
  # exactly that, as arithmetic over observed classes.
  def test_composition_prefers_a_frontier_whose_expected_class_is_not_yet_observed
    claim = { predicate: "composition", rooms_spent: 2,
              args: { "classes" => %w[lodging commercial], "classes_observed" => %w[lodging] } }
    g = graph(here: 1, rooms: [{ id: 1, name: "Entrance Hall" }],
              exits: [frontier(1, "east", target_name: "The Grunting Boar"),
                      frontier(1, "south", target_name: "Market Square")],
              hints: { [1, "east"] => "lodging", [1, "south"] => "commercial" })

    unseen = P.score(claim, g.frontiers.find { |f| f[:direction] == "south" }, g)
    seen   = P.score(claim, g.frontiers.find { |f| f[:direction] == "east" }, g)

    assert_operator unseen, :>, seen
  end

  # And the same decision reached WITHOUT reading a name. Rooms 4, 5 and 6 of
  # the recorded map are reachable only through room 3, which a breadth-seeking
  # survey can discount using graph maths alone — lexical classification would
  # have failed here anyway, since "The Reception" and "The Post Office" share
  # no vocabulary with "The Entrance Hall Of The Grunting Boar Inn".
  def test_a_frontier_behind_a_single_entrance_is_discounted_without_reading_names
    rooms = (1..4).map { |i| { id: i, name: "Room #{i}" } }
    exits = [{ room_id: 1, direction: "east", target_room_id: 3 },
             { room_id: 3, direction: "west", target_room_id: 1 },
             { room_id: 3, direction: "up", target_room_id: 4 },
             { room_id: 4, direction: "down", target_room_id: 3 },
             frontier(4, "north"), frontier(1, "south")]
    g = graph(here: 1, rooms: rooms, exits: exits)
    claim = { predicate: "composition", rooms_spent: 2, args: { "classes" => [], "classes_observed" => [] } }

    inside  = P.score(claim, g.frontiers.find { |f| f[:room_id] == 4 }, g)
    outside = P.score(claim, g.frontiers.find { |f| f[:room_id] == 1 }, g)

    assert_operator inside, :<, outside
    assert_includes g.behind_articulation, 4
  end

  def test_circuit_closes_prefers_the_unexplored_end_of_the_chain
    rooms = (1..3).map { |i| { id: i, name: "Wall #{i}" } }
    exits = [{ room_id: 1, direction: "east", target_room_id: 2 },
             { room_id: 2, direction: "east", target_room_id: 3 },
             frontier(3, "east"), frontier(2, "north")]
    g = graph(here: 1, rooms: rooms, exits: exits, feature_rooms: { "wall_road" => [1, 2, 3] })
    claim = { predicate: "circuit_closes", subject: "feature:wall_road", rooms_spent: 2, args: {} }

    chain_end = P.score(claim, g.frontiers.find { |f| f[:room_id] == 3 }, g)
    middle    = P.score(claim, g.frontiers.find { |f| f[:room_id] == 2 }, g)

    assert_operator chain_end, :>, middle, "the circuit closes at an end, not through the middle"
  end

  # ---------- arbitration --------------------------------------------------

  def seed_wall_and_extent_claims
    @ledger.apply!("open" => [
      { "statement" => "The wall forms a circuit", "predicate" => "circuit_closes",
        "subject" => "feature:wall_road", "priority" => 0.9,
        "decisive_when" => "a wall room is re-entered by an unwalked edge",
        "args" => { "feature" => "wall_road" } },
      { "statement" => "The town is bounded", "predicate" => "extent_bounded",
        "subject" => "Midgaard", "priority" => 0.3, "decisive_when" => "the frontier set empties" }
    ])
  end

  # Strategy as a consequence: an open `circuit_closes` produces perimeter
  # following because that is what its scoring function prefers, and nothing
  # anywhere selected a perimeter strategy.
  def test_the_highest_priority_claim_decides_between_frontiers_of_equal_cost
    seed_wall_and_extent_claims
    rooms = (1..3).map { |i| { id: i, name: "Room #{i}" } }
    exits = [{ room_id: 1, direction: "east", target_room_id: 2 },
             { room_id: 1, direction: "south", target_room_id: 3 },
             frontier(2, "east"), frontier(3, "north")]
    g = graph(here: 1, rooms: rooms, exits: exits, feature_rooms: { "wall_road" => [1, 2] })

    first  = @planner.choose(g)
    second = @planner.choose(g)

    assert_equal 2, first.frontier[:room_id], "the wall claim wins the vote between two frontiers one move away"
    assert_equal "circuit_closes", first.claim[:predicate], "the leg is charged to the claim that won it"
    assert_equal first.frontier, second.frontier, "same ledger, same map, same next leg"
  end

  # And the counterweight, which is what stops a single loud claim marching the
  # survey across the map for one observation: the priority-weighted total is
  # divided by the cost of walking there, so a claim has to outweigh the
  # distance as well as the other claims.
  def test_walking_cost_divides_the_vote_so_a_distant_frontier_must_earn_it
    seed_wall_and_extent_claims
    rooms = (1..4).map { |i| { id: i, name: "Room #{i}" } }
    exits = [{ room_id: 1, direction: "east", target_room_id: 2 },
             { room_id: 2, direction: "east", target_room_id: 3 },
             { room_id: 3, direction: "east", target_room_id: 4 },
             frontier(4, "east"), frontier(1, "south")]
    g = graph(here: 1, rooms: rooms, exits: exits, feature_rooms: { "wall_road" => [3, 4] })

    assert_equal 1, @planner.choose(g).frontier[:room_id],
                 "three moves to reach the wall outweighs the wall claim's priority"
  end

  def test_a_claim_that_can_learn_nothing_more_ends_the_survey
    @ledger.apply!("open" => [{ "statement" => "The town is bounded", "predicate" => "extent_bounded",
                               "subject" => "Midgaard", "decisive_when" => "the frontier set empties" }])
    drained = graph(here: 1, rooms: [{ id: 1, name: "Here" }], exits: [])

    refute @planner.settleable?(drained, 30)
  end

  # The claim room budget: `circuit_closes` can consume an entire survey if
  # nothing stops it, and this is what stops it — with the evidence intact.
  def test_a_claim_that_spends_its_room_budget_is_left_unresolved_not_deleted
    @ledger.apply!("open" => [{ "statement" => "The wall forms a circuit", "predicate" => "circuit_closes",
                               "subject" => "feature:wall_road", "room_budget" => 4,
                               "decisive_when" => "a wall room is re-entered by an unwalked edge",
                               "evidence" => [{ "polarity" => "support", "note" => "a road inside a wall" }] }])
    claim = @store.claims.first

    @planner.charge!(claim, 5)

    settled = @store.claim(claim[:id])
    assert_equal "unresolved", settled[:status]
    assert_match(/room budget of 4/, settled[:settled_reason])
    assert_equal 1, @store.claim_evidence(claim[:id]).size, "an unresolved claim keeps what it established"
  end

  # ---------- hygiene ------------------------------------------------------

  def test_over_the_cap_the_lowest_priority_claims_are_parked_and_can_come_back
    5.times do |i|
      @ledger.apply!("open" => [{ "statement" => "Claim #{i}", "predicate" => "extent_bounded",
                                 "subject" => "place-#{i}", "priority" => 0.1 * i,
                                 "decisive_when" => "the frontier set empties" }])
    end
    planner = N::ClaimPlanner.new(store: @store, region_id: nil, limits: { "max_open_claims" => 3 })

    planner.enforce_open_cap!
    parked = @store.claims(status: "parked")

    assert_equal 2, parked.size
    assert_equal ["Claim 0", "Claim 1"], parked.map { |c| c[:statement] }.sort,
                 "the lowest-priority claims are parked, not the newest"
    assert_equal 1, @store.claim_evidence_by_claim.size + parked.count { |c| c[:settled_reason] } - 1,
                 "parking records why"

    N::ClaimPlanner.new(store: @store, region_id: nil, limits: { "max_open_claims" => 6 }).unpark_if_room!
    assert_empty @store.claims(status: "parked"), "budget freeing brings a parked claim back"
  end

  # The strongest practical argument for the model: a ledger outlives the call
  # that opened it, so a second survey resumes where the first stopped instead
  # of restarting its counters at zero.
  def test_the_ledger_outlives_the_call_that_opened_it
    here = room("Along The Northern Wall")
    @ledger.apply!("open" => [{ "statement" => "A road runs inside the wall and closes",
                                "predicate" => "circuit_closes", "subject" => "feature:wall_road",
                                "decisive_when" => "a wall room is re-entered by an unwalked edge",
                                "evidence" => [{ "room_id" => here, "polarity" => "support",
                                                 "note" => "a road immediately inside a city wall" }] }],
                    "features" => [{ "slug" => "wall_road", "rooms" => [here] }])

    later = N::ClaimPlanner.new(store: @store, region_id: nil)
    resumed = later.open_claims.first

    assert_equal "circuit_closes", resumed[:predicate]
    assert_equal [here], @store.feature_rooms["wall_road"]
    assert_equal "a road immediately inside a city wall",
                 @store.claim_evidence(resumed[:id]).first[:note]
  end
end
