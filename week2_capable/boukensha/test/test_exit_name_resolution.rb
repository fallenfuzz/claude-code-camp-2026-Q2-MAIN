require_relative "helper"

# Exit name resolution — docs/plans/week_3/exit_name_resolution.md.
#
# The MUD prints the name of the room behind every exit and week 2 parsed those
# names into `room_exits.target_name` without ever comparing them to the rooms
# already in memory. These tests pin the three guards that decide when a name is
# an identifier, the preference that keeps a walked route ahead of a named one,
# and the self-healing that makes a wrong guess cost one move rather than every
# future route.
class TestExitNameResolution < Minitest::Test
  M  = Boukensha::Mud::Memory
  ER = Boukensha::Mud::Memory::ExitResolution
  RP = Boukensha::Mud::Navigation::RoutePlanner

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown = @store&.close

  def room(name, description: "A place.")
    @store.create_room(name: name, description: description,
                       weak_fingerprint: M::Fingerprint.weak(name: name, description: description, exit_dirs: []))
  end

  # ---------- the rule, as a pure function -------------------------------

  def test_a_uniquely_named_target_resolves
    resolved = ER.resolve(
      rooms: [{ id: 1, name: "The Temple Of Midgaard" }, { id: 2, name: "The Temple Square" }],
      exits: [{ room_id: 2, direction: "north", target_name: "The Temple Of Midgaard", target_room_id: nil }]
    )

    assert_equal 1, resolved[[2, "north"]]
  end

  # Guard two, and the reason it cannot be relaxed. Room 7 of the recorded
  # Midgaard map has east and west exits BOTH named "Main Street"; resolving
  # them against one room would fuse the two ends of a street into a single
  # vertex, which corrupts the graph rather than merely leaving it sparse.
  def test_two_exits_from_one_room_sharing_a_target_name_both_stay_unresolved
    resolved = ER.resolve(
      rooms: [{ id: 7, name: "Market Square" }, { id: 20, name: "Main Street" }],
      exits: [{ room_id: 7, direction: "east", target_name: "Main Street", target_room_id: nil },
              { room_id: 7, direction: "west", target_name: "Main Street", target_room_id: nil }]
    )

    assert_nil resolved[[7, "east"]]
    assert_nil resolved[[7, "west"]]
  end

  def test_a_name_matching_two_known_rooms_identifies_neither
    resolved = ER.resolve(
      rooms: [{ id: 1, name: "Main Street" }, { id: 2, name: "Main Street" }, { id: 3, name: "Market Square" }],
      exits: [{ room_id: 3, direction: "east", target_name: "Main Street", target_room_id: nil }]
    )

    assert_nil resolved[[3, "east"]]
  end

  # Guard three: a name that has proven ambiguous ANYWHERE is refused even where
  # only one candidate is currently known, because generic MUD room names recur
  # across a world and one that identified two rooms once is not an identifier.
  def test_a_poisoned_name_stays_unresolved_with_only_one_candidate
    rooms = [{ id: 1, name: "Market Square" }, { id: 2, name: "The Dark Alley" }]
    exits = [{ room_id: 2, direction: "north", target_name: "Market Square", target_room_id: nil }]

    assert_equal 1, ER.resolve(rooms: rooms, exits: exits)[[2, "north"]]
    assert_nil ER.resolve(rooms: rooms, exits: exits, ambiguous: ["market square"])[[2, "north"]]
  end

  def test_an_earned_target_is_never_overwritten_by_a_name
    resolved = ER.resolve(
      rooms: [{ id: 1, name: "The Temple Square" }, { id: 2, name: "Market Square" }],
      exits: [{ room_id: 2, direction: "north", target_name: "The Temple Square", target_room_id: 99 }]
    )

    refute_includes resolved.keys, [2, "north"], "a walked traversal is not up for revision"
  end

  # ---------- through the store -------------------------------------------

  def test_recording_exits_resolves_names_against_rooms_recorded_earlier
    temple = room("The Temple Of Midgaard")
    square = room("The Temple Square")
    @store.record_exits!(square, targets: { "north" => "The Temple Of Midgaard" })

    exit_row = @store.exit_at(square, "north")
    assert_equal temple, exit_row[:presumed_target_id]
    assert_nil exit_row[:target_room_id], "a presumption is not a traversal"
  end

  # The pass runs over the whole map for exactly this case: the exit was
  # recorded before the room it names existed, so a pass scoped to the new
  # room's own exits would never find it.
  def test_a_newly_discovered_room_satisfies_an_exit_recorded_earlier
    square = room("The Temple Square")
    @store.record_exits!(square, targets: { "north" => "The Temple Of Midgaard" })
    assert_nil @store.exit_at(square, "north")[:presumed_target_id]

    temple = room("The Temple Of Midgaard")
    @store.record_exits!(temple, dirs: %w[south])

    assert_equal temple, @store.exit_at(square, "north")[:presumed_target_id]
  end

  def test_walking_an_edge_supersedes_and_clears_its_presumption
    temple = room("The Temple Of Midgaard")
    square = room("The Temple Square")
    @store.record_exits!(square, targets: { "north" => "The Temple Of Midgaard" })

    @store.link_exit!(square, "north", temple)

    exit_row = @store.exit_at(square, "north")
    assert_equal temple, exit_row[:target_room_id]
    assert_nil exit_row[:presumed_target_id], "earned supersedes presumed; both set would be ambiguous"
  end

  def test_a_refuted_presumption_poisons_the_name_so_it_is_never_guessed_again
    room("The Temple Of Midgaard")
    square = room("The Temple Square")
    @store.record_exits!(square, targets: { "north" => "The Temple Of Midgaard" })

    @store.refute_presumed_target!(square, "north", target_name: "The Temple Of Midgaard")
    @store.resolve_exit_names!

    assert_nil @store.exit_at(square, "north")[:presumed_target_id],
               "a guess that walking disproved must not be made a second time"
  end

  # ---------- planning over presumed edges ---------------------------------

  def test_presumed_edges_are_traversable_but_lose_to_earned_ones
    exits = [
      # A short route resting on a name…
      { room_id: 1, direction: "north", target_room_id: nil, presumed_target_id: 3 },
      # …and a longer one every step of which has been walked.
      { room_id: 1, direction: "east", target_room_id: 2 },
      { room_id: 2, direction: "east", target_room_id: 3 }
    ]
    plan = RP.plan(query: "Somewhere", current_room_id: 1,
                   rooms: [{ id: 1, name: "Here" }, { id: 2, name: "Middle" }, { id: 3, name: "Somewhere" }],
                   exits: exits)

    assert_equal "known", plan.status
    assert_equal %w[east east], plan.steps.map { |s| s[:direction] }
    refute plan.presumed, "a route made only of walked edges does not depend on a presumption"
  end

  def test_a_presumed_route_is_offered_when_it_is_the_only_one_and_says_so
    plan = RP.plan(query: "Somewhere", current_room_id: 1,
                   rooms: [{ id: 1, name: "Here" }, { id: 2, name: "Somewhere" }],
                   exits: [{ room_id: 1, direction: "north", target_room_id: nil, presumed_target_id: 2 }])

    assert_equal "known", plan.status
    assert_equal %w[north], plan.steps.map { |s| s[:direction] }
    assert plan.presumed
  end

  def test_an_exit_with_a_presumed_target_is_no_longer_a_frontier
    plan = RP.plan(query: "bakery", current_room_id: 1,
                   rooms: [{ id: 1, name: "Here" }, { id: 2, name: "There" }],
                   exits: [{ room_id: 1, direction: "north", target_room_id: nil, presumed_target_id: 2 },
                           { room_id: 1, direction: "south", target_room_id: nil, target_name: "Unknown Road" }])

    assert_equal 1, plan.unexplored_total, "something already knows what is behind the north exit"
    assert_equal %w[south], plan.unexplored.flat_map { |g| g[:exits].map { |e| e[:direction] } }
  end

  # The regression guard for the week 2 decision, restated here because name
  # resolution is the thing most likely to be mistaken for reverse inference.
  # Nothing above asserts symmetry: an exit the MUD never printed is never
  # created, so a one-way passage stays one-way.
  def test_resolution_never_manufactures_an_exit_the_mud_did_not_print
    resolved = ER.resolve(
      rooms: [{ id: 1, name: "Top Of The Cliff" }, { id: 2, name: "The Ravine" }],
      exits: [{ room_id: 1, direction: "down", target_room_id: 2 }]
    )

    assert_empty resolved, "room 2 has no exit rows, so there is nothing to resolve and none is invented"
  end
end
