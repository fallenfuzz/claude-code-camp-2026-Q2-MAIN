require_relative "helper"

# Regions — boundaries_revised.md §2, §6, §8.
#
# The derivation, the two declaration tools, and the properties §8 asks to be
# held: inheritance is deterministic under shuffled row order, a late
# declaration re-derives everything downstream of it and nothing upstream,
# `within:` nesting is respected by `scope: "region"`, a room arriving with no
# edge seeds exactly one provisional region and a known room never seeds one,
# and neither tool can reach the MUD.
class TestRegions < Minitest::Test
  M = Boukensha::Mud::Memory
  T = Boukensha::Mud::Navigation::RegionTools
  P = Boukensha::Mud::Navigation::PlanRouteTool

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  # A room, optionally with the first-arrival edge that walking there would
  # have stamped on it.
  def mk(name, from: nil, dir: nil)
    d = "desc of #{name}"
    @store.create_room(name: name, description: d, arrived_from: from, arrived_direction: dir,
                       weak_fingerprint: M::Fingerprint.weak(name: name, description: d, exit_dirs: %w[north]))
  end

  def walk(from, dir, name, back: nil)
    id = mk(name, from: from, dir: dir)
    @store.link_exit!(from, dir, id)
    @store.link_exit!(id, back, from) if back
    id
  end

  def region_label(room_id) = @store.region_for_room(room_id)&.[](:label)

  # A three-room chain: temple → square → market, each entered from the last.
  def town
    a = mk("The Temple Of Midgaard")
    b = walk(a, "south", "The Temple Square", back: "north")
    c = walk(b, "south", "Market Square", back: "north")
    @store.update_player!(current_room_id: c)
    [ a, b, c ]
  end

  # ---------- rule 1: inheritance ---------------------------------------

  def test_every_walked_room_belongs_to_a_region_from_the_first_turn
    a, b, c = town
    labels = [ a, b, c ].map { |id| region_label(id) }

    assert_equal 3, labels.compact.size, "there is no unassigned state"
    assert_equal 1, labels.uniq.size, "all three inherited from the room the first was entered from"
    assert_equal "⟨from The Temple Of Midgaard⟩", labels.first
    refute @store.regions.first[:confirmed] == 1, "a machine-made label is never confirmed"
  end

  def test_a_room_takes_the_region_of_the_room_it_was_first_entered_from
    a, = town
    # A second visit by another route must not re-parent anything: the arrival
    # edge is written once, at discovery.
    d = walk(a, "north", "By The Temple Altar", back: "south")
    @store.link_exit!(d, "west", a)

    assert_equal region_label(a), region_label(d)
    assert_equal a, @store.room(d)[:arrived_from_room_id]
  end

  # §6's determinism obligation. The derivation reads rows out of SQLite and
  # must not depend on the order they come back in.
  def test_inheritance_is_deterministic_under_shuffled_row_order
    a, b, c = town
    # Seed first: `derive` is pure and REPORTS the provisional region a root
    # needs rather than writing it, so a first pass over a store with no
    # regions row resolves nothing at all — by design (§2 rule 3).
    @store.room_regions
    rooms = @store.rooms
    regions = @store.regions
    boundaries = @store.region_boundaries

    baseline, = M::Regions.derive(rooms: rooms, regions: regions, boundaries: boundaries)
    10.times do
      shuffled, = M::Regions.derive(rooms: rooms.shuffle, regions: regions.shuffle,
                                    boundaries: boundaries.shuffle)
      assert_equal baseline, shuffled
    end
    assert_equal [ a, b, c ], baseline.map { |m| m[:room_id] }, "membership comes back in room id order"
  end

  # ---------- rule 3: provisional regions -------------------------------

  def test_a_room_with_no_arrival_edge_seeds_exactly_one_provisional_region
    mk("The Temple Of Midgaard")
    @store.room_regions

    assert_equal 1, @store.regions.size
    assert M::Regions.provisional_label?(@store.regions.first[:label])
  end

  def test_a_known_room_never_seeds_a_second_region
    a, = town
    @store.room_regions
    before = @store.regions.size
    # Arriving again in a room already on the map — a flee back, say. No new
    # room row, so nothing to seed.
    @store.touch_room(a)
    @store.room_regions

    assert_equal 1, before
    assert_equal before, @store.regions.size
  end

  def test_two_edgeless_rooms_sharing_a_name_get_distinguishable_labels
    mk("The Void")
    mk("The Void")
    @store.room_regions

    assert_equal 2, @store.regions.size
    assert_equal 2, @store.regions.map { |r| r[:label] }.uniq.size
  end

  # ---------- name_region ------------------------------------------------

  def test_name_region_renames_in_place_and_confirms
    _, _, c = town
    out = T.name_region(store: @store, region: "Midgaard", description: "walled town")

    assert_match(/⟨from The Temple Of Midgaard⟩ → Midgaard, confirmed/, out)
    assert_match(/3 rooms carry the name/, out)
    assert_match(/no boundary moved/, out)
    assert_equal "Midgaard", region_label(c)
    assert_equal 1, @store.regions.size, "renaming is not creating"
    assert_empty @store.region_boundaries, "no boundary moved, so none was written"
  end

  # §9's second failure mode, made loud rather than prevented: the tool prints
  # the room count it renamed, so renaming a whole town when you meant one
  # field is visible in the same turn.
  def test_name_region_reports_the_room_count_it_renamed
    town
    out = T.name_region(store: @store, region: "The Great Field")

    assert_match(/3 rooms carry the name/, out)
  end

  def test_name_region_merges_on_a_label_that_already_exists
    a, _, c = town
    T.name_region(store: @store, region: "Midgaard")

    field = walk(a, "north", "The Great Field Of Midgaard", back: "south")
    @store.update_player!(current_room_id: field)
    T.split_region(store: @store, region: "The Great Field")
    assert_equal 2, @store.regions.size

    out = T.name_region(store: @store, region: "Midgaard")
    assert_match(/merged into the existing Midgaard/, out)
    assert_equal 1, @store.regions.size, "two names for one place is one place"
    assert_equal "Midgaard", region_label(c)
    assert_equal "Midgaard", region_label(field)
  end

  def test_name_region_reparents_the_whole_region_with_within
    _, _, c = town
    T.name_region(store: @store, region: "Midgaard")
    out = T.name_region(store: @store, region: "North Midgaard", within: "Midgaard")

    assert_match(/within Midgaard \(a new parent\)/, out)
    assert_equal 2, @store.regions.size
    parent = @store.region_by_label("Midgaard")
    assert_equal parent[:id], @store.region_for_room(c)[:parent_id]
    assert_nil parent[:seed_room_id], "a container holds regions, not rooms directly"
  end

  def test_a_region_cannot_be_its_own_parent_or_nest_inside_itself
    a, _, c = town
    T.name_region(store: @store, region: "Midgaard")
    assert_match(/cannot be within itself/, T.name_region(store: @store, region: "Midgaard", within: "Midgaard"))

    # A real cycle: put The Great Field inside Midgaard, then try to put
    # Midgaard inside The Great Field. Left unguarded, every walk over the
    # parent chain would have to defend against a loop forever.
    field = walk(a, "north", "The Great Field Of Midgaard", back: "south")
    @store.update_player!(current_room_id: field)
    T.split_region(store: @store, region: "The Great Field", within: "Midgaard")

    @store.update_player!(current_room_id: c)
    out = T.name_region(store: @store, region: "Midgaard", within: "The Great Field")
    assert_match(/already inside/, out)
    assert_nil @store.region_by_label("Midgaard")[:parent_id]
  end

  # ---------- split_region -----------------------------------------------

  def test_split_region_uses_the_first_arrival_edge_and_leaves_the_previous_room_alone
    a, _, _ = town
    altar  = walk(a, "north", "By The Temple Altar", back: "south")
    behind = walk(altar, "north", "Behind The Temple Altar", back: "south")
    field  = walk(behind, "north", "The Great Field Of Midgaard", back: "south")
    T.name_region(store: @store, region: "Midgaard")

    @store.update_player!(current_room_id: field)
    out = T.split_region(store: @store, region: "The Great Field",
                         reason: "the busy city of Midgaard lies to the south")

    assert_match(/boundary: Behind The Temple Altar —north→ The Great Field Of Midgaard/, out)
    assert_match(/Behind The Temple Altar keeps its region/, out)
    assert_equal "Midgaard", region_label(behind), "the room behind you keeps its region"
    assert_equal "The Great Field", region_label(field)

    boundary = @store.region_boundaries.first
    assert_equal [ behind, field, "north" ],
                 boundary.values_at(:from_room_id, :to_room_id, :direction)
    assert_equal "the busy city of Midgaard lies to the south", boundary[:reason]
  end

  def test_everything_reached_through_the_split_room_comes_with_it
    a, = town
    field = walk(a, "north", "The Great Field Of Midgaard", back: "south")
    beyond = walk(field, "north", "The Dirt Path", back: "south")
    T.name_region(store: @store, region: "Midgaard")

    @store.update_player!(current_room_id: field)
    T.split_region(store: @store, region: "The Great Field")

    assert_equal "The Great Field", region_label(beyond)
  end

  # §2's rule 2, and the reason declaring late is not declaring too late.
  def test_a_late_declaration_re_derives_downstream_and_nothing_upstream
    a, b, _ = town
    field  = walk(b, "east", "The Great Field Of Midgaard", back: "west")
    beyond = walk(field, "north", "The Dirt Path", back: "south")
    T.name_region(store: @store, region: "Midgaard")
    assert_equal "Midgaard", region_label(beyond)

    @store.update_player!(current_room_id: field)
    T.split_region(store: @store, region: "The Great Field")

    assert_equal "The Great Field", region_label(beyond), "downstream re-derived"
    assert_equal "Midgaard", region_label(a), "upstream untouched"
    assert_equal "Midgaard", region_label(b), "the room behind the boundary untouched"
  end

  # §2 again: the exactness of a split is that the boundary IS the edge walked
  # in on. A room with no such edge has none to offer, and inventing one would
  # give away the only property that makes a split trustworthy.
  def test_split_region_refuses_in_a_room_with_no_first_arrival_edge
    a = mk("The Temple Of Midgaard")
    @store.update_player!(current_room_id: a)

    out = T.split_region(store: @store, region: "Somewhere")
    assert_match(/no first-arrival edge/, out)
    assert_match(/use name_region/, out)
    assert_empty @store.region_boundaries
  end

  # ---------- both tools --------------------------------------------------

  def test_both_tools_refuse_when_position_is_unknown
    mk("The Temple Of Midgaard")

    assert_match(/position has not been established/, T.name_region(store: @store, region: "X"))
    assert_match(/position has not been established/, T.split_region(store: @store, region: "X"))
  end

  def test_both_tools_require_a_region_name
    town
    assert_match(/region is required/, T.name_region(store: @store, region: "  "))
    assert_match(/region is required/, T.split_region(store: @store, region: ""))
  end

  # The same guarantee plan_route.md §3 makes of `plan_route`: the signature
  # takes a store, some strings and (for `split_region`) a room id, so there is
  # no seam through which either could dispatch a MUD tool. `at_room_id` is
  # move_to.md §5.6 — a room to place the boundary at instead of the one the
  # player is standing in — and an integer is not a call_tool lambda.
  def test_neither_tool_has_a_mud_dispatch_seam
    assert_equal %i[store region within description],
                 T.method(:name_region).parameters.map { |(_, name)| name }
    assert_equal %i[store region within description reason at_room_id],
                 T.method(:split_region).parameters.map { |(_, name)| name }
  end

  # ---------- scope --------------------------------------------------------

  def test_scope_region_includes_descendants
    _, _, c = town
    T.name_region(store: @store, region: "Midgaard")
    T.name_region(store: @store, region: "North Midgaard", within: "Midgaard")

    parent = @store.region_by_label("Midgaard")
    child  = @store.region_by_label("North Midgaard")
    assert_equal [ parent[:id], child[:id] ].sort, @store.region_descendants(parent[:id]).sort
    assert_equal [ child[:id] ], @store.region_descendants(child[:id])
    assert_equal child[:id], @store.region_for_room(c)[:id]
  end

  def test_region_exhausted_fires_only_when_every_frontier_crosses
    a, = town
    # A door left open in town, so that when the field runs out the arithmetic
    # has somewhere to point that is NOT in scope.
    @store.record_exits!(a, targets: { "west" => "The Reading Room" })
    field = walk(a, "north", "The Great Field Of Midgaard", back: "south")
    @store.record_exits!(field, targets: { "north" => "The Great Field Of Midgaard" })
    T.name_region(store: @store, region: "Midgaard")
    @store.update_player!(current_room_id: field)
    T.split_region(store: @store, region: "The Great Field")

    # Standing in the field, whose own north exit is unexplored and in scope.
    refute_match(/region_exhausted/, P.call(store: @store, destination: "hermit"))

    # Walk that last one off, and every remaining door is back in town.
    beyond = walk(field, "north", "The Dirt Path", back: "south")
    @store.update_player!(current_room_id: beyond)
    out = P.call(store: @store, destination: "hermit")

    assert_match(/region_exhausted/, out)
    assert_match(/scope: "world"/, out, "the refusal carries the widening call as text")
    refute_match(/region_exhausted/, P.call(store: @store, destination: "hermit", scope: "world"))
  end

  # Scope constrains exploration and never travel.
  def test_a_known_destination_routes_across_a_boundary_under_the_default_scope
    a, = town
    bakery = walk(a, "north", "The Bakery", back: "south")
    T.name_region(store: @store, region: "Midgaard")
    @store.update_player!(current_room_id: bakery)
    T.split_region(store: @store, region: "The Outskirts")
    @store.update_player!(current_room_id: a)

    out = P.call(store: @store, destination: "bakery")
    assert_match(/\[route\] bakery — known/, out)
    assert_match(/path: north/, out)
  end

  # ---------- recompute ----------------------------------------------------

  def test_membership_is_rewritten_wholesale_and_never_accumulates
    _, _, c = town
    @store.room_regions
    before = @store.db.get_first_value("SELECT COUNT(*) FROM room_regions")
    T.name_region(store: @store, region: "Midgaard")
    @store.room_regions

    assert_equal before, @store.db.get_first_value("SELECT COUNT(*) FROM room_regions")
    assert_equal "Midgaard", region_label(c)
  end

  # §6: the recompute runs lazily on the next READ. Nothing in Regions or in
  # the store's derivation path dispatches a tool, so it cannot land inside a
  # MUD round trip.
  def test_the_derivation_reaches_no_mud
    source = File.read(File.expand_path("../lib/boukensha/mud/memory/regions.rb", __dir__))
    refute_match(/call_tool|@call_tool|RoomSurvey/, source)
    assert_equal %i[rooms regions boundaries], M::Regions.method(:derive).parameters.map { |(_, n)| n }
  end

  # §1: the engine's own metadata places open countryside inside town — the
  # step from Behind The Temple Altar to The Great Field is CITY→CITY inside
  # zone 30, and the terrain flip does not arrive until two rooms later. So
  # there is no ground truth to recover by reading the world files, and any
  # code that reached for them would be dressing a wrong answer as a fact.
  # "In town" is a judgement, and the model is the only participant that can
  # make it.
  def test_no_library_code_reads_the_world_files
    root = File.expand_path("../lib", __dir__)
    offenders = Dir.glob("#{root}/**/*.rb").select { |f| File.read(f).include?("data/world") }

    assert_empty offenders.map { |f| f.sub("#{root}/", "") },
                 "region membership is declared by the agent, never read out of the world files"
  end

  # ---------- the region line in the state block ---------------------------

  def test_the_state_block_carries_the_region_and_its_unconfirmed_tag
    _, _, c = town
    block = Boukensha::Mud::StateBlock.render(room: @store.room(c), exits: @store.exits_for(c),
                                              region: @store.region_for_room(c), player: @store.player)

    assert_match(/region: ⟨from The Temple Of Midgaard⟩ — unconfirmed \(inherited\)/, block)

    T.name_region(store: @store, region: "Midgaard")
    named = Boukensha::Mud::StateBlock.render(room: @store.room(c), exits: @store.exits_for(c),
                                              region: @store.region_for_room(c), player: @store.player)

    assert_match(/region: Midgaard \(inherited\)/, named)
    refute_match(/unconfirmed/, named, "the tag disappears once the question is answered")
  end
end
