require_relative "helper"

# Navigation::RoutePlanner — BFS over the known graph plus frontier ranking.
# See docs/plans/week_2/plan_route.md §5, §6, §9.
class TestNavigationRoutePlanner < Minitest::Test
  R = Boukensha::Mud::Navigation::RoutePlanner

  def room(id, name:, description: "")
    { id: id, name: name, description: description, look_candidates: nil }
  end

  # Directed edge room_id --direction--> target_room_id.
  def edge(room_id, direction, target_room_id, target_name: nil)
    { room_id: room_id, direction: direction, target_room_id: target_room_id, target_name: target_name }
  end

  def frontier(room_id, direction, target_name: nil)
    { room_id: room_id, direction: direction, target_room_id: nil, target_name: target_name }
  end

  def plan(query, current_room_id, rooms:, exits:, entities_by_room: {}, frontier_attempt_counts: {})
    R.plan(query: query, current_room_id: current_room_id, rooms: rooms, exits: exits,
           entities_by_room: entities_by_room, frontier_attempt_counts: frontier_attempt_counts)
  end

  # 1 --east--> 2 --east--> 3(Bakery). 1 --west--> 4 (dead end, longer way round via nothing).
  def linear_rooms
    [room(1, name: "Market Square"), room(2, name: "Main Street"), room(3, name: "Grubby's Bakery")]
  end

  def linear_exits
    [edge(1, "east", 2), edge(2, "west", 1), edge(2, "east", 3), edge(3, "west", 2)]
  end

  def test_shortest_directed_path
    p = plan("bakery", 1, rooms: linear_rooms, exits: linear_exits)
    assert_equal "known", p.status
    assert_equal 3, p.destination_room
    assert_equal %w[east east], p.steps.map { |s| s[:direction] }
  end

  def test_current_room_equals_destination_returns_arrived
    p = plan("market square", 1, rooms: linear_rooms, exits: linear_exits)
    assert_equal "arrived", p.status
    assert_equal 1, p.destination_room
    assert_empty p.steps
  end

  def test_one_way_exits_are_not_reversed
    rooms = [room(1, name: "A"), room(2, name: "B")]
    exits = [edge(1, "east", 2)] # no reverse edge recorded
    p = plan("A", 2, rooms: rooms, exits: exits)
    assert_equal "unreachable", p.status, "B has no known edge back to A"
  end

  def test_disconnected_known_destination_returns_unreachable
    rooms = [room(1, name: "A"), room(2, name: "B"), room(3, name: "Island")]
    exits = [edge(1, "east", 2), edge(2, "west", 1)] # 3 is disconnected
    p = plan("island", 1, rooms: rooms, exits: exits)
    assert_equal "unreachable", p.status
    assert_equal 3, p.destination_room
  end

  def test_cycles_terminate
    rooms = [room(1, name: "A"), room(2, name: "B"), room(3, name: "C")]
    exits = [edge(1, "east", 2), edge(2, "east", 3), edge(3, "west", 1)]
    p = plan("C", 1, rooms: rooms, exits: exits)
    assert_equal "known", p.status
    assert_equal %w[east east], p.steps.map { |s| s[:direction] }
  end

  def test_up_and_down_remain_canonical
    rooms = [room(1, name: "Surface"), room(2, name: "Cellar")]
    exits = [edge(1, "down", 2)]
    p = plan("cellar", 1, rooms: rooms, exits: exits)
    assert_equal ["down"], p.steps.map { |s| s[:direction] }
  end

  def test_provisional_current_position_returns_position_unknown
    p = plan("bakery", nil, rooms: linear_rooms, exits: linear_exits)
    assert_equal "position_unknown", p.status
  end

  def test_stable_result_regardless_of_input_row_order
    a = plan("bakery", 1, rooms: linear_rooms, exits: linear_exits)
    b = plan("bakery", 1, rooms: linear_rooms.reverse, exits: linear_exits.reverse)
    assert_equal a.status, b.status
    assert_equal a.steps, b.steps
  end

  # --- frontier planning, §6 -------------------------------------------

  def test_target_named_frontier_wins
    rooms = [room(1, name: "Market Square"), room(2, name: "Side Street")]
    exits = [edge(1, "east", 2), frontier(2, "north", target_name: "Grubby's Bakery"),
             frontier(1, "south")]
    p = plan("bakery", 1, rooms: rooms, exits: exits)
    assert_equal "explore", p.status
    assert_equal({ room_id: 2, direction: "north" }, p.frontier)
  end

  def test_relevant_room_frontier_wins_over_nearer_irrelevant_frontier
    # Room 2's description merely MENTIONS the query (tier 5, non-decisive —
    # §4.3) rather than naming the room itself, so it must not become a
    # confident "known" answer on its own; it should still out-rank a nearer
    # frontier with no clue at all when ranking WHERE to explore next.
    rooms = [room(1, name: "Market Square"),
             room(2, name: "Side Street", description: "A street known for its bakery smells.")]
    exits = [frontier(1, "north"), edge(1, "east", 2), frontier(2, "south")]
    p = plan("bakery", 1, rooms: rooms, exits: exits)
    assert_equal "explore", p.status
    assert_equal({ room_id: 2, direction: "south" }, p.frontier)
  end

  def test_no_clue_nearest_reachable_frontier_wins
    rooms = [room(1, name: "A"), room(2, name: "B"), room(3, name: "C")]
    exits = [edge(1, "east", 2), frontier(2, "north"), edge(2, "east", 3), frontier(3, "north")]
    p = plan("dragon's lair", 1, rooms: rooms, exits: exits)
    assert_equal "unknown", p.status
    assert_equal({ room_id: 2, direction: "north" }, p.frontier)
  end

  def test_tied_frontiers_use_direction_then_room_id
    rooms = [room(1, name: "A")]
    exits = [frontier(1, "south"), frontier(1, "north")]
    p = plan("dragon's lair", 1, rooms: rooms, exits: exits)
    assert_equal "north", p.frontier[:direction], "canonical order: north before south"
  end

  def test_frontier_with_fewer_failed_attempts_ranks_first
    rooms = [room(1, name: "A")]
    exits = [frontier(1, "north"), frontier(1, "east")]
    counts = { [1, "north"] => 3 }
    p = plan("dragon's lair", 1, rooms: rooms, exits: exits, frontier_attempt_counts: counts)
    assert_equal "east", p.frontier[:direction]
  end

  def test_no_reachable_frontier_returns_exhausted
    rooms = [room(1, name: "A"), room(2, name: "B")]
    exits = [edge(1, "east", 2), edge(2, "west", 1)] # fully linked, no frontier
    p = plan("dragon's lair", 1, rooms: rooms, exits: exits)
    assert_equal "exhausted", p.status
  end

  def test_route_to_source_plus_explicit_unknown_final_step
    rooms = [room(1, name: "A"), room(2, name: "B")]
    exits = [edge(1, "east", 2), frontier(2, "north", target_name: "Bakery")]
    p = plan("bakery", 1, rooms: rooms, exits: exits)
    assert_equal %w[east], p.steps.map { |s| s[:direction] }, "path stops at the frontier's source room"
    assert_equal "north", p.frontier[:direction]
  end

  def test_ambiguous_match_returns_alternatives_rather_than_a_confident_choice
    rooms = [room(1, name: "Wall Road"), room(2, name: "Wall Road"), room(3, name: "Start")]
    exits = [edge(3, "east", 1), edge(1, "east", 2)]
    p = plan("Wall Road", 3, rooms: rooms, exits: exits)
    assert_equal "known", p.status
    assert_equal 1, p.destination_room, "nearer of the two ties wins as primary"
    assert_equal [{ room_id: 2, name: "Wall Road" }], p.alternatives
  end

  # ---------- frontier visibility (boundaries_revised.md §2, §8 step 1) -----
  #
  # The failure this fixes: the planner returned ONE frontier and hid the other
  # four, so the agent was never shown that there was a choice to make.

  # A chain 1→2→3→4, with unexplored exits scattered along it at increasing
  # distance from the start. Journal A′ iteration 4's shape, in miniature.
  def banded
    rooms = (1..4).map { |i| room(i, name: "Room #{i}") }
    exits = [edge(1, "east", 2), edge(2, "east", 3), edge(3, "east", 4),
             frontier(1, "north", target_name: "A"), frontier(1, "south", target_name: "B"),
             frontier(2, "north", target_name: "C"), frontier(2, "south", target_name: "D"),
             frontier(3, "north", target_name: "E"), frontier(3, "south", target_name: "F"),
             frontier(4, "north", target_name: "G"), frontier(4, "south", target_name: "H")]
    [rooms, exits]
  end

  def test_the_whole_reachable_frontier_is_returned_not_just_one
    rooms, exits = banded
    p = plan("dragon's lair", 1, rooms: rooms, exits: exits)

    assert_equal 8, p.unexplored_total
    assert_equal %w[A B C D E F], p.unexplored.flat_map { |g| g[:exits].map { |e| e[:target_name] } },
                 "the names the MUD printed, in distance order"
  end

  # The soft cap bounds the listing loosely; the BAND is what is never cut,
  # because "the nearest ones are all here" has to be true for the ordering to
  # mean anything.
  def test_a_distance_band_is_never_cut_in_half
    rooms, exits = banded
    p = plan("dragon's lair", 1, rooms: rooms, exits: exits)

    shown = p.unexplored.sum { |g| g[:exits].size }
    assert_operator shown, :>=, R::FRONTIER_SOFT_CAP
    p.unexplored.group_by { |g| g[:distance] }.each_value do |band|
      band_total = band.sum { |g| g[:exits].size }
      complete = exits.count { |e| e[:target_room_id].nil? && band.any? { |g| g[:room_id] == e[:room_id] } }
      assert_equal complete, band_total, "band at distance #{band.first[:distance]} is shown whole"
    end
  end

  def test_withheld_carries_a_count_and_the_range_it_spans
    rooms, exits = banded
    p = plan("dragon's lair", 1, rooms: rooms, exits: exits)

    assert_equal({ count: 2, rooms: 1, min_distance: 3, max_distance: 3 }, p.withheld)
  end

  def test_nothing_is_withheld_when_the_whole_set_fits
    rooms = [room(1, name: "The Temple Of Midgaard")]
    exits = [frontier(1, "north", target_name: "By The Temple Altar"),
             frontier(1, "south", target_name: "The Temple Square")]
    p = plan("bakery", 1, rooms: rooms, exits: exits)

    assert_nil p.withheld
    assert_equal 2, p.unexplored.first[:exits].size
  end

  # A frontier the agent cannot walk to is not a choice it can make, and the
  # whole point of listing more than one is that the choice is the agent's.
  def test_every_group_carries_the_walk_to_the_room_it_leaves_from
    rooms, exits = banded
    p = plan("dragon's lair", 1, rooms: rooms, exits: exits)

    assert_equal [[], %w[east], %w[east east]], p.unexplored.map { |g| g[:path] }
  end

  # ---------- region_hops (§2, §3) -----------------------------------------

  # Three moves without leaving town beats one move out of the gate.
  def test_region_hops_outranks_raw_distance
    rooms = (1..4).map { |i| room(i, name: "Room #{i}") }
    # 1 is the gate: east leaves into region 2 immediately; north stays in
    # region 1 but is three moves away.
    exits = [edge(1, "east", 4), edge(1, "north", 2), edge(2, "north", 3),
             frontier(4, "east", target_name: "Out"), frontier(3, "north", target_name: "In")]
    regions = { 1 => 10, 2 => 10, 3 => 10, 4 => 20 }

    p = R.plan(query: "bakery", current_room_id: 1, rooms: rooms, exits: exits,
               regions_by_room: regions, scope_region_ids: nil)
    assert_equal 3, p.frontier[:room_id], "the nearer frontier is the one that left the region"

    # Without regions, plain distance wins and the gate is chosen.
    q = plan("bakery", 1, rooms: rooms, exits: exits)
    assert_equal 4, q.frontier[:room_id]
  end

  def test_scope_confines_exploration_to_the_region_and_its_descendants
    rooms = (1..3).map { |i| room(i, name: "Room #{i}") }
    exits = [edge(1, "east", 2), edge(2, "east", 3),
             frontier(2, "north", target_name: "In"), frontier(3, "north", target_name: "Out")]
    regions = { 1 => 10, 2 => 11, 3 => 20 }

    p = R.plan(query: "bakery", current_room_id: 1, rooms: rooms, exits: exits,
               regions_by_room: regions, scope_region_ids: [ 10, 11 ])
    assert_equal 1, p.unexplored_total, "only the in-scope frontier is a candidate"
    assert_equal "In", p.unexplored.first[:exits].first[:target_name]
  end

  def test_region_exhausted_when_every_reachable_frontier_leaves
    rooms = (1..2).map { |i| room(i, name: "Room #{i}") }
    exits = [edge(1, "east", 2), frontier(2, "north", target_name: "Out")]
    regions = { 1 => 10, 2 => 20 }

    p = R.plan(query: "bakery", current_room_id: 1, rooms: rooms, exits: exits,
               regions_by_room: regions, scope_region_ids: [ 10 ])
    assert_equal "region_exhausted", p.status
    assert_equal 1, p.unexplored_total, "it says how much is on the other side of the answer"
  end
end
