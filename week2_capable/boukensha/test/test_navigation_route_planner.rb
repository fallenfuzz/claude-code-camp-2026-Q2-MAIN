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
end
