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

    assert_equal({ rooms: 1, surveyed: 1, frontier: 1, entities: 0, encounters: 0, skills: 0, items: 0 },
                 @store.stats)
  end

  # --- V2: the player half ---------------------------------------------------

  # The guarantee the whole additive-DDL doctrine rests on. A file written by an
  # older build must reach V2 with every existing row intact — if V2 ever has to
  # rewrite a table to land, the monitor attaching this file read-only is the
  # thing that breaks.
  def test_a_v1_file_migrates_forward_with_every_row_intact
    # A genuine V1 file: only V1's DDL has ever run against it.
    db = SQLite3::Database.new(":memory:")
    db.results_as_hash = true
    db.execute_batch(M::Schema::V1)
    db.execute("PRAGMA user_version = 1")
    old = M::Store.new(db)
    id  = old.create_room(name: "Market Square", description: "A famous square.",
                          weak_fingerprint: F.weak(name: "Market Square", description: "A famous square.",
                                                   exit_dirs: %w[north]))
    old.record_exits!(id, dirs: %w[north])
    old.update_player!(current_room_id: id, hp: 19, level: 10)

    assert_equal 2, M::Schema::LATEST_VERSION, "V2 is appended, never edited into V1"
    assert_equal 2, M::Schema.migrate!(db)
    assert_equal 2, db.get_first_value("PRAGMA user_version")

    # Every V1 row survived.
    assert_equal "Market Square", old.room(id)[:name]
    assert_equal %w[north], old.exits_for(id).map { |e| e[:direction] }
    assert_equal [10, id, 19], [old.player[:level], old.player[:current_room_id], old.player[:hp]]
    # …and the new columns exist, unset. "No reading yet" is a real state and
    # is nil, never a zero that would render as a real value.
    assert_nil old.player[:max_mana]
    assert_equal({ skills: 0, items: 0 }, old.stats.slice(:skills, :items))
    db.close
  end

  # Nil means "no reading this time", never "clear it" — the rule the score
  # sheet's twelve new columns inherit for free from update_player!'s
  # compact-then-merge, and the reason a `poll` cannot wipe a `score`.
  def test_the_widened_score_sheet_merges_rather_than_overwrites
    @store.update_player!(level: 10, max_mana: 162, title: "Derrano the Minister",
                          armor_class: "94/10", conditions: nil)
    @store.update_player!(hp: 19)

    p = @store.player
    assert_equal [10, 162, "Derrano the Minister", "94/10", 19],
                 [p[:level], p[:max_mana], p[:title], p[:armor_class], p[:hp]]
    assert_nil p[:conditions]
  end

  # EARNED. A skill the agent knows does not stop being known because this
  # reading did not mention it, so nothing here ever deletes — and the level it
  # was first seen KNOWN at is stamped once and never moves.
  def test_skills_upsert_in_place_and_pin_the_level_they_were_learned_at
    @store.update_player!(level: 10)
    @store.upsert_skills!([{ name: "armor", proficiency: "not learned", learned: false, kind: "spell" },
                           { name: "cure light", proficiency: "good", learned: true, kind: "spell" }])
    @store.update_player!(level: 14)
    @store.upsert_skills!([{ name: "armor", proficiency: "good", learned: true, kind: "spell" }])

    armor, cure = @store.skills
    assert_equal %w[armor cure\ light], [armor[:name], cure[:name]]
    assert_equal ["good", 1, 14], [armor[:proficiency], armor[:learned], armor[:learned_level]]
    # Not re-stamped to 14 by the second reading: it was already known at 10.
    assert_equal 10, cure[:learned_level]
    assert_equal 2, @store.stats[:skills]
  end

  # VOLATILE. The rule the whole table exists to enforce: an item the agent
  # dropped ten rooms ago must not still appear in its knowledge.
  def test_an_item_snapshot_is_replaced_wholesale_not_accumulated
    @store.replace_items!(location: "inventory", items: [
                            { descr: "a bottle", quantity: 2, keyword: "bottle" },
                            { descr: "a torch", quantity: 1, keyword: "torch" }
                          ])
    @store.replace_items!(location: "inventory", items: [{ descr: "a bottle", quantity: 2, keyword: "bottle" }])

    assert_equal ["a bottle"], @store.items(location: "inventory").map { |i| i[:descr] }
    # An EMPTY list is a legitimate snapshot — the pack really is empty — and
    # clears the table rather than being ignored as "no reading".
    @store.replace_items!(location: "inventory", items: [])
    assert_empty @store.items(location: "inventory")
  end

  # Scoped to the location being replaced, or a routine `inventory` read would
  # silently wipe the last known worn gear.
  def test_replacing_the_pack_does_not_wipe_the_worn_gear
    @store.replace_items!(location: "equipped",
                          items: [{ worn_on: "wielded", descr: "a wooden club", keyword: "club" }])
    @store.replace_items!(location: "inventory", items: [{ descr: "a bottle", quantity: 2 }])

    assert_equal ["a wooden club"], @store.items(location: "equipped").map { |i| i[:descr] }
    assert_equal 2, @store.stats[:items]
  end

  # Staleness is a fact the monitor renders, so it is stamped only by a real
  # replacement — never by a mutation the agent did not follow with a read.
  def test_the_snapshot_stamps_its_own_freshness
    assert_nil @store.player[:items_updated_at]
    @store.replace_items!(location: "inventory", items: [])

    refute_nil @store.player[:items_updated_at]
  end

  # --- generic CDC: every mutation emits a journal delta ---------------------

  # Records upsert/event calls without deduping, so a test can see exactly what
  # the store handed the journal. Real dedup is the Journal's job (test_journal).
  class FakeJournal
    attr_reader :changes, :events

    def initialize
      @changes = []
      @events  = []
    end

    def upsert(stream:, key:, value:)
      return false if value.nil?

      @changes << { stream: stream, key: key, value: value }
      true
    end

    def event(stream:, op:, **fields)
      @events << { stream: stream, op: op }.merge(fields)
      true
    end
  end

  def test_player_writes_emit_a_stat_delta_per_field
    @store.journal = (j = FakeJournal.new)
    @store.update_player!(level: 5, gold: 100, hp: 18)

    by_key = j.changes.select { |c| c[:stream] == "stat" }.each_with_object({}) { |c, h| h[c[:key]] = c[:value] }
    assert_equal 5, by_key["level"]
    assert_equal 100, by_key["gold"]
    assert_equal 18, by_key["hp"], "hp is captured now — generic capture takes everything"
    refute_includes by_key.keys, "updated_at", "the bookkeeping timestamp is noise, never journaled"
  end

  def test_room_lifecycle_emits_events
    @store.journal = (j = FakeJournal.new)
    id = new_room
    @store.touch_room(id)
    @store.mark_surveyed!(id)

    ops = j.events.select { |e| e[:stream] == "room" }.map { |e| e[:op] }
    assert_equal %w[create visit surveyed], ops
  end

  def test_exit_target_is_a_change_detected_upsert
    @store.journal = (j = FakeJournal.new)
    id = new_room
    @store.record_exits!(id, dirs: %w[north], targets: { "north" => "The Temple" })

    exit_change = j.changes.find { |c| c[:stream] == "exit" && c[:key].end_with?("target_name") }
    refute_nil exit_change
    assert_equal "The Temple", exit_change[:value]
  end

  def test_encounter_is_a_discrete_event
    @store.journal = (j = FakeJournal.new)
    @store.update_player!(level: 3)
    @store.record_encounter!(outcome: "died", hp_before: 20, hp_after: -6)

    enc = j.events.find { |e| e[:stream] == "encounter" }
    refute_nil enc
    assert_equal "died", enc[:op]
    assert_equal 3, enc[:player_level]
  end

  def test_no_journal_wired_is_a_silent_no_op
    # @store has no journal by default — every mutation must still work.
    id = new_room
    @store.update_player!(level: 2)
    @store.record_encounter!(outcome: "won")
    assert_equal 2, @store.level   # no raise, writes landed
  end
end
