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

  # A room the agent walked into, with the arrival edge a real walk would have
  # stamped on it at discovery.
  def walked_into(name, from:, dir:, description: "A place.")
    @store.create_room(name: name, description: description, arrived_from: from, arrived_direction: dir,
                       weak_fingerprint: M::Fingerprint.weak(name: name, description: "#{description} #{from}#{dir}",
                                                             exit_dirs: []))
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

  # ---------- the arrival edge (fix_surveying.md §3.4) ---------------------
  #
  # The rule that runs ahead of both ambiguity guards, and the one that took
  # reachability from the recorded concourse from three rooms to seventeen. It
  # needs the arrival edge AND the name to agree, so neither half can carry it
  # alone.

  def arrived(id, name, from:, dir:)
    { id: id, name: name, arrived_from_room_id: from, arrived_direction: dir }
  end

  # Three rooms called "Wall Road" poison the name globally, and the walk down
  # the western wall earned one southward edge per move. The name identifies none
  # of them; the name plus "the agent came in from #12 heading south one move
  # ago" identifies exactly one.
  def test_the_arrival_edge_resolves_a_globally_ambiguous_name
    rooms = [arrived(12, "Wall Road", from: 11, dir: "south"),
             arrived(13, "Wall Road", from: 12, dir: "south"),
             arrived(14, "Wall Road", from: 13, dir: "south")]
    exits = [{ room_id: 13, direction: "north", target_name: "Wall Road", target_room_id: nil }]

    assert_equal 12, ER.resolve(rooms: rooms, exits: exits, ambiguous: ["wall road"])[[13, "north"]]
  end

  # Room #13 of the recorded map has north AND south both named "Wall Road",
  # which is the within-room collision guard — and the arrival says which of the
  # two is the way back. The other is already earned.
  def test_the_arrival_edge_resolves_a_within_room_name_collision
    rooms = [arrived(12, "Wall Road", from: 11, dir: "south"),
             arrived(13, "Wall Road", from: 12, dir: "south"),
             arrived(14, "Wall Road", from: 13, dir: "south")]
    exits = [{ room_id: 13, direction: "north", target_name: "Wall Road", target_room_id: nil },
             { room_id: 13, direction: "south", target_name: "Wall Road", target_room_id: nil }]

    resolved = ER.resolve(rooms: rooms, exits: exits)

    assert_equal 12, resolved[[13, "north"]]
    assert_nil resolved[[13, "south"]], "the collision guard still holds for the exit the arrival says nothing about"
  end

  # The name half. An exit facing back the way the agent came but labelled with
  # somewhere else is not the way back.
  def test_a_reverse_exit_naming_another_room_is_refused
    rooms = [arrived(1, "Market Square", from: nil, dir: nil),
             arrived(2, "Main Street", from: 1, dir: "west")]
    exits = [{ room_id: 2, direction: "east", target_name: "The Bakery", target_room_id: nil }]

    assert_nil ER.resolve(rooms: rooms, exits: exits)[[2, "east"]]
  end

  # The direction half, and the week 2 decision it protects: a passage is not
  # assumed to run both ways just because a room on the other side shares the
  # name. Room 3 is called "Market Square" too, so the name matches — and the
  # arrival came from the west, so the SOUTH exit is not the way back.
  def test_an_exit_that_is_not_the_reverse_of_the_arrival_is_refused
    rooms = [arrived(1, "Market Square", from: nil, dir: nil),
             arrived(2, "Main Street", from: 1, dir: "west"),
             arrived(3, "Market Square", from: 2, dir: "south")]
    exits = [{ room_id: 2, direction: "south", target_name: "Market Square", target_room_id: nil }]

    assert_nil ER.resolve(rooms: rooms, exits: exits, ambiguous: ["market square"])[[2, "south"]],
               "a shared name plus the wrong direction is the guess the guards exist to refuse"
  end

  # A room nobody walked into — a cold start's first room — has no arrival edge,
  # so there is no local evidence and only the global rule applies.
  def test_a_room_with_no_arrival_edge_falls_back_to_the_guards
    rooms = [{ id: 1, name: "Wall Road" }, { id: 2, name: "Wall Road" }]
    exits = [{ room_id: 1, direction: "north", target_name: "Wall Road", target_room_id: nil }]

    assert_nil ER.resolve(rooms: rooms, exits: exits)[[1, "north"]]
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

  # A one-way passage refutes the arrival presumption the first time it is
  # walked, and that costs one move and one edge. It must not also cost the NAME:
  # the presumption was made from the arrival, so what it got wrong is this
  # passage, and poisoning "Wall Road" would take every other exit that resolves
  # through the arrival edge down with it.
  def test_refuting_an_arrival_link_clears_the_edge_without_poisoning_the_name
    street = room("Main Street")
    here   = walked_into("Wall Road", from: street, dir: "south")
    @store.record_exits!(here, targets: { "north" => "Main Street" })
    assert_equal street, @store.exit_at(here, "north")[:presumed_target_id]

    @store.refute_presumed_target!(here, "north", target_name: "Main Street")

    assert_nil @store.exit_at(here, "north")[:presumed_target_id]
    assert_empty @store.ambiguous_exit_names,
                 "the arrival was wrong about the passage, not about the name"
  end

  # The same store, the same name, an exit that is not the way back: the
  # presumption there could only have come from the name, and refuting it says
  # the name is not an identifier.
  def test_the_basis_is_the_direction_not_the_name
    street = room("Main Street")
    here   = walked_into("Wall Road", from: street, dir: "south")

    @store.refute_presumed_target!(here, "east", target_name: "Main Street")

    assert_includes @store.ambiguous_exit_names, "main street"
  end

  # And the name-based presumption keeps poisoning, which is what makes a wrong
  # guess cost one move rather than every future route.
  def test_refuting_a_name_link_still_poisons_the_name
    room("The Temple Of Midgaard")
    square = room("The Temple Square")
    @store.record_exits!(square, targets: { "north" => "The Temple Of Midgaard" })

    @store.refute_presumed_target!(square, "north", target_name: "The Temple Of Midgaard")

    assert_includes @store.ambiguous_exit_names, "the temple of midgaard"
  end

  # An exit walked for no information has established retrospectively exactly what
  # the surveyor is asked to predict about an unwalked one, so the finding is
  # recorded in the same place and the same vocabulary — which is also the only
  # assessment travel mode ever has, since it has no surveyor to ask
  # (blind_step_recovery.md §5.1).
  def test_marking_an_exit_opaque_records_it_as_unassessable
    here = room("The Clerics' Inner Sanctum")
    @store.record_exits!(here, targets: { "down" => "Too dark to tell." })

    @store.note_opaque_exit!(here, "down")

    assert_equal "unassessable", @store.frontier_hints.dig([here, "down"], :assessability)
    assert_nil @store.frontier_hints.dig([here, "down"], :hazard),
               "being unreadable says nothing about being dangerous"
  end

  # A class guess made three sessions ago survives it, because the columns are
  # written independently.
  def test_marking_an_exit_opaque_keeps_the_class_the_surveyor_guessed
    here = room("The Clerics' Inner Sanctum")
    @store.record_frontier_hint!(room_id: here, direction: "down", expected_class: "religious")

    @store.note_opaque_exit!(here, "down")

    hint = @store.frontier_hints[[here, "down"]]
    assert_equal "religious", hint[:expected_class]
    assert_equal "unassessable", hint[:assessability]
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
