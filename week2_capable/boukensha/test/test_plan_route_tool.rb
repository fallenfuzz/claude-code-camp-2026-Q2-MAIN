require_relative "helper"

# Navigation::PlanRouteTool — the native tool surface over a real Store.
# Zero MUD I/O: the store is the only thing this tool touches.
class TestPlanRouteTool < Minitest::Test
  M = Boukensha::Mud::Memory
  T = Boukensha::Mud::Navigation::PlanRouteTool

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  # `from:`/`dir:` is the first-arrival edge a real walk would have stamped on
  # the room. Rooms created without one are ROOTS, each seeding its own
  # provisional region — correct behaviour, and not what a chain of rooms the
  # agent walked should look like.
  def make_room(name, from: nil, dir: nil)
    desc = "desc of #{name}"
    weak = M::Fingerprint.weak(name: name, description: desc, exit_dirs: %w[north])
    @store.create_room(name: name, description: desc, weak_fingerprint: weak,
                       arrived_from: from, arrived_direction: dir)
  end

  # A walked chain: each room entered from the last, going east.
  def chain(*names)
    names.each_with_index.each_with_object([]) do |(name, i), ids|
      ids << (i.zero? ? make_room(name) : make_room(name, from: ids[i - 1], dir: "east"))
      @store.link_exit!(ids[i - 1], "east", ids[i]) if i.positive?
    end
  end

  def test_position_unknown_before_any_room_is_established
    result = T.call(store: @store, destination: "bakery")
    assert_match(/position unknown/, result)
  end

  def test_blank_destination_is_rejected
    result = T.call(store: @store, destination: "   ")
    assert_match(/error: destination is required/, result)
  end

  def test_known_route_renders_path_and_room_chain
    a = make_room("Market Square")
    b = make_room("Grubby's Bakery")
    @store.link_exit!(a, "east", b)
    @store.update_player!(current_room_id: a)

    result = T.call(store: @store, destination: "bakery")
    assert_match(/\[route\] bakery — known/, result)
    assert_match(/to: Grubby's Bakery \(##{b}\)/, result)
    assert_match(/path: east/, result)
    assert_match(/1 move: Market Square → Grubby's Bakery/, result)
  end

  def test_arrived_when_current_room_is_the_destination
    a = make_room("Grubby's Bakery")
    @store.update_player!(current_room_id: a)

    result = T.call(store: @store, destination: "bakery")
    assert_match(/\[route\] bakery — arrived/, result)
  end

  # plan_route.md §3: "plan_route performs zero MCP calls." Its signature
  # takes a store and a destination string — nothing that could dispatch a
  # tool — so there is no seam through which it could reach the MUD.
  def test_signature_has_no_mud_dispatch_seam
    assert_equal %i[store destination scope], T.method(:call).parameters.map { |(_, name)| name }
  end

  def test_scope_is_validated
    assert_match(/scope must be/, T.call(store: @store, destination: "bakery", scope: "town"))
  end

  # ---------- frontier visibility (boundaries_revised.md §3) ---------------
  #
  # Journal A′ iteration 0: five exits out of the temple, four of them parts of
  # the temple itself, and the model can only rule those out if it is shown
  # their names. The old output printed one of the five.

  def test_the_unknown_result_lists_every_unexplored_exit_by_name
    temple = make_room("The Temple Of Midgaard")
    @store.record_exits!(temple, targets: { "north" => "By The Temple Altar",
                                            "east" => "The Midgaard Donation Room",
                                            "south" => "The Temple Square",
                                            "west" => "The Reading Room" })
    @store.update_player!(current_room_id: temple)

    result = T.call(store: @store, destination: "bakery")

    assert_match(/\[route\] bakery — unknown/, result)
    assert_match(/unexplored, in .+ — all 4:/, result)
    [ "north → By The Temple Altar", "east  → The Midgaard Donation Room",
      "south → The Temple Square", "west  → The Reading Room" ].each do |line|
      assert_includes result, line
    end
    assert_match(/here — The Temple Of Midgaard/, result)
  end

  # The ordering is arithmetic and says so, in the same breath as the ordering
  # it describes — which is why none of this lives in the system prompt (§7).
  def test_the_reason_says_the_ordering_knows_nothing_about_meaning
    temple = make_room("The Temple Of Midgaard")
    @store.record_exits!(temple, targets: { "north" => "By The Temple Altar" })
    @store.update_player!(current_room_id: temple)

    result = T.call(store: @store, destination: "bakery")
    assert_match(/ordered by distance, which knows/, result)
    assert_match(/nothing about what these names mean — you do/, result)
  end

  def test_a_withheld_tail_reports_its_count_and_range
    rooms = chain(*(1..5).map { |i| "Room #{i}" })
    rooms.each { |id| @store.record_exits!(id, targets: { "north" => "Door #{id}", "south" => "Hatch #{id}" }) }
    @store.update_player!(current_room_id: rooms.first)

    result = T.call(store: @store, destination: "bakery")

    # Three bands of two: the third is what crosses the soft cap, and it is
    # shown whole rather than cut, so six land on screen and four are held.
    assert_match(/unexplored, in .+ — 6 of 10, nearest first:/, result)
    assert_match(/4 more from 2 rooms, 3–4 moves away/, result)
  end

  # A frontier two rooms away is only a choice if the agent can get to it.
  def test_a_group_beyond_here_shows_the_walk_to_it
    a, b = chain("Market Square", "Main Street")
    @store.record_exits!(b, targets: { "north" => "The Bakery" })
    @store.update_player!(current_room_id: a)

    result = T.call(store: @store, destination: "hermit")
    assert_match(/1 move — Main Street  \[east\]/, result)
  end
end
