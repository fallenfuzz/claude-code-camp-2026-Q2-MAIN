require_relative "helper"

# Mud::Memory — the schema, the fingerprints, and the store.
#
# Everything runs against Store.open(":memory:"). No MUD, no MCP, no network,
# and no file on disk.
class TestMemoryStore < Minitest::Test
  M = Boukensha::Mud::Memory
  F = Boukensha::Mud::Memory::Fingerprint

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def new_room(name: "Market Square", desc: "A famous square.", dirs: %w[north east south west])
    @store.create_room(name: name, description: desc,
                       weak_fingerprint: F.weak(name: name, description: desc, exit_dirs: dirs))
  end

  # --- fingerprints ----------------------------------------------------------

  # The weak fingerprint is FREE — name, prose and the autoexit line ride on
  # every look and every movement result — which is what makes the revisit fast
  # path possible without spending a round trip to check.
  def test_weak_fingerprint_ignores_line_wrapping_and_exit_order
    a = F.weak(name: "Market Square", description: "Roads lead\nin every direction.", exit_dirs: %w[n e s w])
    b = F.weak(name: "market square", description: "Roads   lead in every direction.", exit_dirs: %w[w s e n])

    assert_equal a, b, "wrapping is a property of the connection, not of the room"
  end

  def test_weak_fingerprint_separates_genuinely_different_rooms
    refute_equal F.weak(name: "A", description: "x", exit_dirs: %w[n]),
                 F.weak(name: "B", description: "x", exit_dirs: %w[n])
    refute_equal F.weak(name: "A", description: "x", exit_dirs: %w[n]),
                 F.weak(name: "A", description: "x", exit_dirs: %w[n s])
  end

  # Two Dark Alleys with identical prose and identical n/s exits separate the
  # moment you learn one leads to Market Square and the other to The Slums. That
  # is the whole reason `strong` exists, and why it costs a check(exits).
  def test_strong_fingerprint_separates_lookalikes_by_their_neighbours
    weak = F.weak(name: "The Dark Alley", description: "Dark.", exit_dirs: %w[north south])

    assert_equal F.strong(weak, { "north" => "Market Square", "south" => "The Slums" }),
                 F.strong(weak, { "south" => "The Slums", "north" => "Market Square" })
    refute_equal F.strong(weak, { "north" => "Market Square" }),
                 F.strong(weak, { "north" => "The Slums" })
  end

  # --- schema ----------------------------------------------------------------

  def test_migrations_are_idempotent_and_stamp_the_version
    assert_equal M::Schema::LATEST_VERSION, @store.db.get_first_value("PRAGMA user_version")
    assert_equal M::Schema::LATEST_VERSION, M::Schema.migrate!(@store.db)
  end

  # NOT UNIQUE, deliberately. Two genuinely different rooms may share a weak
  # fingerprint, identity is the surrogate `id`, and making this UNIQUE is what
  # would make a later merge resolver impossible to add without a migration that
  # rewrites every foreign key.
  def test_two_rooms_may_share_a_weak_fingerprint
    a = new_room(name: "The Dark Alley", desc: "Dark.")
    b = new_room(name: "The Dark Alley", desc: "Dark.")

    refute_equal a, b
    assert_equal 2, @store.rooms_by_weak(@store.room(a)[:weak_fingerprint]).size
  end

  def test_player_state_is_exactly_one_row
    @store.update_player!(hp: 20, level: 1)
    @store.update_player!(hp: 18, gold: 43)

    assert_equal 1, @store.db.get_first_value("SELECT COUNT(*) FROM player_state")
    # nil means "no reading this time", never "clear it": a poll that returns
    # nothing must not wipe the level a score check taught us.
    assert_equal({ hp: 18, level: 1, gold: 43 },
                 @store.player.slice(:hp, :level, :gold))
  end

  # --- rooms and the frontier -----------------------------------------------

  def test_a_revisit_bumps_the_counter_and_spends_nothing
    id = new_room
    @store.touch_room(id)
    @store.touch_room(id)

    assert_equal 3, @store.room(id)[:visit_count]
  end

  # The NULL target_room_id IS the exploration frontier, and the one glyph the
  # state block renders from it is information the agent has never had.
  def test_an_exit_is_a_frontier_until_it_is_walked
    here  = new_room
    there = new_room(name: "Main Street", desc: "A street.")
    @store.record_exits!(here, dirs: %w[north east], targets: { "north" => "Main Street" })

    north = @store.exit_at(here, "north")
    assert_equal "Main Street", north[:target_name]
    assert_nil north[:target_room_id], "named but never stood in"
    assert_equal 2, @store.stats[:frontier], "north and east are both unexplored"

    @store.link_exit!(here, "north", there)
    assert_equal there, @store.exit_at(here, "north")[:target_room_id]
    assert_equal 1, @store.exit_at(here, "north")[:traversals]
    assert_equal "Main Street", @store.exit_at(here, "north")[:target_name], "linking must not erase the name"
    assert_equal 1, @store.stats[:frontier]
  end

  # A room cannot move; a stale edge can. So the fresh reading wins and the edge
  # pays for it.
  def test_demoting_an_edge_drops_the_link_but_keeps_the_direction
    here = new_room
    there = new_room(name: "Elsewhere", desc: "e")
    @store.record_exits!(here, dirs: %w[north], targets: { "north" => "Main Street" })
    @store.link_exit!(here, "north", there)

    @store.demote_exit!(here, "north")

    assert_nil @store.exit_at(here, "north")[:target_room_id]
    assert_equal 0, @store.exit_at(here, "north")[:traversals]
    assert_equal "Main Street", @store.exit_at(here, "north")[:target_name]
  end

  # --- entities: world-level, so the appraisal is reusable ------------------

  def test_an_entity_is_stored_once_for_the_whole_world
    a = new_room(name: "Market Square", desc: "m")
    b = new_room(name: "Main Street", desc: "s")
    guard = "A cityguard stands here."

    id1 = @store.remember_entity(kind: "mob", descr: guard, keyword: "cityguard", threat: "easy")
    @store.record_sighting!(entity_id: id1, room_id: a)
    id2 = @store.remember_entity(kind: "mob", descr: guard)
    @store.record_sighting!(entity_id: id2, room_id: b)

    assert_equal id1, id2, "a cityguard patrolling two rooms is one type, not two"
    assert_equal 1, @store.stats[:entities]
    assert_equal 2, @store.db.get_first_value("SELECT COUNT(*) FROM entity_sightings")
    # A later sighting with no new appraisal must not erase the one we paid for.
    assert_equal "cityguard", @store.entity_for(guard)[:keyword]
    assert_equal "easy", @store.entity_for(guard)[:threat]
  end

  # `consider`'s verdict is relative to the player's level, so a reading taken
  # twenty levels ago must not be acted on. It is flagged rather than deleted —
  # the keyword it came with is still perfectly good.
  def test_threat_goes_stale_on_level_up_but_the_keyword_does_not
    @store.update_player!(level: 3)
    @store.remember_entity(kind: "mob", descr: "A minotaur.", keyword: "minotaur", threat: "Death!")

    fresh = @store.entity_for("A minotaur.")
    assert fresh[:threat_fresh]
    assert_equal 3, fresh[:threat_level]

    @store.update_player!(level: 8)
    stale = @store.entity_for("A minotaur.")
    refute stale[:threat_fresh]
    assert_equal "minotaur", stale[:keyword], "a keyword is not level-relative"
  end

  def test_equipment_round_trips_as_json
    @store.remember_entity(kind: "mob", descr: "A guard.", keyword: "guard",
                           equipment: ["<wielded> a long sword"])

    assert_equal ["<wielded> a long sword"], @store.entity_for("A guard.")[:equipment]
  end

  # --- encounters ------------------------------------------------------------

  # "if it fights the minotaur at level 3 and loses, it should record that."
  def test_encounters_are_ordered_worst_news_first
    room = new_room
    mino = @store.remember_entity(kind: "mob", descr: "A minotaur.", keyword: "minotaur")
    @store.update_player!(level: 3)
    @store.record_encounter!(outcome: "died", room_id: room, entity_id: mino, hp_before: 20, hp_after: -6)
    @store.update_player!(level: 8)
    @store.record_encounter!(outcome: "won", room_id: room, entity_id: mino)

    rows = @store.encounters_for(mino)
    assert_equal %w[died won], rows.map { |r| r[:outcome] }
    assert_equal 3, rows.first[:player_level], "the level is what makes the outcome usable"
    assert_equal(-6, rows.first[:hp_after])
  end

  def test_stats_counts_what_the_monitor_reads
    id = new_room
    @store.record_exits!(id, dirs: %w[north])
    @store.mark_surveyed!(id)

    assert_equal({ rooms: 1, surveyed: 1, frontier: 1, entities: 0, encounters: 0 }, @store.stats)
  end
end
