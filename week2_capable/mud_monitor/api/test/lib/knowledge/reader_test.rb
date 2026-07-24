require "test_helper"

module Knowledge
  class ReaderTest < ActiveSupport::TestCase
    include KnowledgeFixtures

    def reader(path = knowledge_db_path, **opts)
      Reader.new(path: path, **opts)
    end

    # ---------- absence -------------------------------------------------

    test "a missing file is a state, not an error" do
      use_missing_knowledge_db
      r = reader

      assert_not r.attached?
      assert_equal Reader::EMPTY_STATS, r.stats
      assert_nil r.player
      assert_equal [], r.rooms
      assert_equal [], r.entities
      assert_equal [], r.frontier
      assert_nil r.room(1)
      assert_not r.envelope[:attached]
      assert_not r.envelope[:live]
      assert_nil r.envelope[:last_write_at]
    end

    # ---------- connection posture --------------------------------------

    # The safety property of the whole feature: mud_monitor must not be able to
    # write the agent's memory even by accident. Asserted, not trusted.
    test "query_only rejects writes at the engine level" do
      use_knowledge_db
      r = reader

      r.stats # force the connection open

      error = assert_raises(SQLite3::Exception) do
        r.send(:db).execute("UPDATE rooms SET name = 'clobbered' WHERE id = 1")
      end
      assert_match(/readonly|read.only|query_only/i, error.message)

      # And the row is untouched.
      assert_equal "The Temple Of Midgaard", r.room(1)[:name]
    ensure
      r&.close
    end

    # The regression test for `readonly: true`. A cleanly-closed WAL database
    # has no -shm on disk; a readonly connection cannot create one and fails
    # with SQLITE_CANTOPEN — i.e. the page would break exactly when the agent
    # is not running, which is most of the time.
    test "opens a WAL database that has no -shm on disk" do
      path = use_knowledge_db(wal: true)

      assert_not File.exist?("#{path}-shm"), "fixture should be cleanly closed"
      assert_equal "wal", SQLite3::Database.new(path.to_s).get_first_value("PRAGMA journal_mode")

      r = reader
      assert_equal 5, r.stats[:rooms]
    ensure
      r&.close
    end

    # ---------- freshness -----------------------------------------------

    # Under WAL, commits land in -wal and the main file's mtime only moves on
    # checkpoint. A reader watching only knowledge.sqlite3 reports "stale" while
    # the agent is actively exploring.
    test "freshness follows the -wal mtime, not the main file" do
      path = use_knowledge_db
      old  = Time.now - 3600
      File.utime(old, old, path)
      File.write("#{path}-wal", "") # empty WAL: valid, and SQLite ignores it
      File.utime(Time.now, Time.now, "#{path}-wal")

      r = reader(live_window: 10)

      assert r.live?, "a fresh -wal means the agent just wrote"
      assert_operator r.last_write_at, :>, old + 1
    end

    test "an old file in both places is not live" do
      path = use_knowledge_db
      old  = Time.now - 3600
      File.utime(old, old, path)

      assert_not reader(live_window: 10).live?
    end

    # ---------- schema drift ---------------------------------------------

    test "a newer user_version is still served" do
      path = use_knowledge_db
      SQLite3::Database.new(path.to_s).tap { |db| db.execute("PRAGMA user_version = 99"); db.close }

      r = reader
      assert_equal 99, r.schema_version
      assert_equal 5, r.stats[:rooms]
    ensure
      r&.close
    end

    test "a missing column raises SchemaMismatch carrying the version" do
      path = use_knowledge_db
      SQLite3::Database.new(path.to_s).tap { |db| db.execute("ALTER TABLE rooms DROP COLUMN visit_count"); db.close }

      r = reader
      error = assert_raises(Reader::SchemaMismatch) { r.rooms }
      assert_equal 2, error.schema_version
    ensure
      r&.close
    end

    # ---------- rooms -----------------------------------------------------

    test "rooms carry their exits and entity counts without an N+1" do
      use_knowledge_db
      r = reader
      rooms = r.rooms

      assert_equal [ 1, 2, 3, 4, 5 ], rooms.map { |x| x[:id] }

      temple = rooms.first
      assert_equal 3, temple[:exits].length
      assert_equal %w[east north south], temple[:exits].map { |e| e[:direction] }.sort
      assert_equal 2, temple[:exits].count { |e| e[:target_room_id].nil? }
      assert_equal 3, temple[:entity_count]
      assert_equal %w[cityguard fido mayor], temple[:entities].map { |entity| entity[:keyword] }
      assert_equal [ "wall", "paintings", "giants" ], temple[:look_candidates]
    ensure
      r&.close
    end

    test "malformed look_candidates degrades to an empty list and the row survives" do
      use_knowledge_db
      r = reader
      common = r.rooms.find { |x| x[:id] == 5 }

      assert_equal [], common[:look_candidates]
      assert_equal "The Common Square", common[:name]
    ensure
      r&.close
    end

    test "rooms filters" do
      use_knowledge_db
      r = reader

      assert_equal [ 3, 4 ], r.rooms(filter: "unsurveyed").map { |x| x[:id] }
      assert_equal [ 4 ], r.rooms(filter: "provisional").map { |x| x[:id] }
      assert_equal [ 1, 2 ], r.rooms(q: "temple").map { |x| x[:id] }
      # description is searched too, not just the name
      assert_equal [ 3 ], r.rooms(q: "famous Square").map { |x| x[:id] }
      # an unknown filter is ignored rather than erroring
      assert_equal 5, r.rooms(filter: "nonsense").length
      assert_equal 2, r.rooms(limit: 2).length
    ensure
      r&.close
    end

    # The only way this stays fixed. Three statements for five rooms and three
    # statements for fifty.
    test "rooms costs a constant number of statements regardless of row count" do
      use_knowledge_db
      baseline = count_statements { |r| r.rooms }

      seed_extra_rooms(50)
      assert_equal 50 + 5, reader.rooms(limit: 1000).length
      assert_equal baseline, count_statements { |r| r.rooms(limit: 1000) }
    end

    test "room detail resolves inbound exits" do
      use_knowledge_db
      r = reader

      assert_equal [ { room_id: 1, room_name: "The Temple Of Midgaard", direction: "south" } ],
                   r.inbound(2)
      # Room 1 is reachable only from room 2.
      assert_equal [ 2 ], r.inbound(1).map { |x| x[:room_id] }
      assert_equal [], r.inbound(4)
    ensure
      r&.close
    end

    # ---------- entities ---------------------------------------------------

    test "entities sort by seen_count and carry their sighting rooms" do
      use_knowledge_db
      r = reader
      list = r.entities

      assert_equal [ 1, 2, 4, 3 ], list.map { |e| e[:id] }

      guard = list.first
      assert_equal [ "Market Square", "The Temple Of Midgaard" ], guard[:sightings].map { |s| s[:room_name] }.sort
      assert_equal "Are you mad!?", guard[:threat]
      assert_equal 1, guard[:threat_level]
    ensure
      r&.close
    end

    # A verdict without the level it was measured at is misleading, so both
    # fields ship together and `threat_level` is allowed to be null.
    test "a threat with no measured level keeps the null rather than inventing one" do
      use_knowledge_db
      r = reader
      mayor = r.entities.find { |e| e[:id] == 4 }

      assert_equal "You ARE mad!", mayor[:threat]
      assert_nil mayor[:threat_level]
      # equipment is JSON.generate'd by the writer, so it comes back a list
      assert_equal [ "a gold ring <worn on finger>" ], mayor[:equipment]
      assert_equal [], r.entities.find { |e| e[:id] == 1 }[:equipment]
    ensure
      r&.close
    end

    test "entities filters by kind and text" do
      use_knowledge_db
      r = reader

      assert_equal [ 1, 2, 4 ], r.entities(kind: "mob").map { |e| e[:id] }.sort
      assert_equal [ 3 ], r.entities(kind: "object").map { |e| e[:id] }
      assert_equal 4, r.entities(kind: "bogus").length
      assert_equal [ 1 ], r.entities(q: "cityguard").map { |e| e[:id] }
    ensure
      r&.close
    end

    test "entities in a room report that room's counters, not the world-wide ones" do
      use_knowledge_db
      r = reader
      guard = r.entities_in_room(3).find { |e| e[:id] == 1 }

      assert_equal 2, guard[:count]
      assert_equal 2, guard[:sighting_count] # world-wide seen_count is 6
      assert_equal 6, guard[:seen_count]
    ensure
      r&.close
    end

    test "encounters resolve their room and entity names" do
      use_knowledge_db
      r = reader
      fight = r.encounters(room_id: 1).sole

      assert_equal "fled", fight[:outcome]
      assert_equal 1, fight[:player_level]
      assert_equal "A beastly fido is mucking through the garbage.", fight[:entity_descr]
      assert_equal "The Temple Of Midgaard", fight[:room_name]
    ensure
      r&.close
    end

    # ---------- frontier ---------------------------------------------------

    test "frontier lists only unwalked exits, with their origin room" do
      use_knowledge_db
      r = reader
      front = r.frontier

      assert_equal 4, front.length
      assert_equal [ [ 1, "east" ], [ 1, "north" ], [ 3, "west" ], [ 5, "down" ] ],
                   front.map { |e| [ e[:room_id], e[:direction] ] }
      assert_equal "The Temple Of Midgaard", front.first[:room_name]
      # An exit the MUD never named is still frontier — it just has no label.
      assert_nil front.find { |e| e[:room_id] == 3 }[:target_name]
      assert_not front.find { |e| e[:room_id] == 3 }[:room_surveyed]
    ensure
      r&.close
    end

    test "stats matches what the tables actually hold" do
      use_knowledge_db
      r = reader

      assert_equal({ rooms: 5, surveyed: 3, provisional: 1, entities: 4, mobs: 3, objects: 1,
                     exits: 8, frontier: 4, traversed: 4, encounters: 1,
                     skills: 4, items: 5 }, r.stats)
    ensure
      r&.close
    end

    test "player resolves both room references and names the writing session" do
      use_knowledge_db
      r = reader
      player = r.player

      assert_equal({ id: 5, name: "The Common Square" }, player[:current_room])
      assert_equal({ id: 4, name: "A Dark Alley" }, player[:prev_room])
      assert_equal "20260723T225532Z-7ed8c53a", player[:session_id]
      assert_equal 18, player[:hp]
      assert_equal 2, player[:level]
    ensure
      r&.close
    end

    # ---------- the player half (V2) --------------------------------------

    test "player carries the whole score sheet, not just the four numbers" do
      use_knowledge_db
      r = reader
      player = r.player

      # The denominators that exist ONLY in `score` — the prompt line carries
      # the currents and throws these away, so nothing else can supply them.
      assert_equal [ 100, 162 ], [ player[:mana], player[:max_mana] ]
      assert_equal [ 72, 94 ], [ player[:move], player[:max_move] ]
      assert_equal 1099, player[:exp_to_next]
      # Verbatim: "94/10" is two numbers and splitting them is a guess.
      assert_equal "94/10", player[:armor_class]
      assert_equal [ 0, 17, 30 ], [ player[:alignment], player[:age_years], player[:practices_left] ]
      assert_equal "Derrano the Minister", player[:title]
    ensure
      r&.close
    end

    # Reserved columns, written the day a capture proves this build prints them
    # and not before. nil here is the honest answer, not a gap to be filled.
    test "class and race are nil because no capture proves the mud prints them" do
      use_knowledge_db
      r = reader

      assert_nil r.player[:char_class]
      assert_nil r.player[:race]
    ensure
      r&.close
    end

    # Stored joined because it is short and low-cardinality; split here so the
    # UI never re-parses a column format.
    test "conditions arrive split and are an empty list when unread" do
      use_knowledge_db
      r = reader
      assert_equal %w[hungry thirsty], r.player[:conditions]
      r.close

      use_knowledge_db(sql: File.read(KnowledgeFixtures::SEED_SQL).sub("'hungry,thirsty'", "NULL"),
                       name: "fed.sqlite3")
      r = reader
      assert_equal [], r.player[:conditions]
    ensure
      r&.close
    end

    # Honest staleness: the bag has its OWN clock, deliberately not
    # `updated_at`. An agent that dropped something and never looked again must
    # not have the UI imply its list is current.
    test "the item snapshot carries its own age, older than the row's" do
      use_knowledge_db
      r = reader
      player = r.player

      assert_equal "2026-07-23T22:55:58Z", player[:items_updated_at]
      assert player[:items_updated_at] < player[:updated_at],
             "the snapshot is older than the row, and the UI has to be able to say so"
    ensure
      r&.close
    end

    test "skills are earned knowledge, graded in the words the mud printed" do
      use_knowledge_db
      r = reader
      skills = r.player_skills

      assert_equal %w[armor bless cure\ light sneak], skills.map { |s| s[:name] }
      armor = skills.first
      # A WORD, never a percent — this build prints "(good)" and there is no
      # number anywhere in the listing to convert.
      assert_equal "good", armor[:proficiency]
      assert armor[:learned]
      assert_equal [ "spell", 2 ], [ armor[:kind], armor[:learned_level] ]
      assert_not skills.find { |s| s[:name] == "bless" }[:learned]
      # NULL grade means the listing carried none, NOT that the skill is absent.
      sneak = skills.find { |s| s[:name] == "sneak" }
      assert_nil sneak[:proficiency]
      assert sneak[:learned]
    ensure
      r&.close
    end

    test "items are readable as one bag, or split by where they are" do
      use_knowledge_db
      r = reader

      assert_equal 5, r.player_items.length
      assert_equal [ [ "a bottle", 2 ], [ "a hooded lantern", 1 ] ],
                   r.player_items(location: "inventory").map { |i| [ i[:descr], i[:quantity] ] }
      assert_equal [ "worn on body", "wielded", "worn on finger" ],
                   r.player_items(location: "equipped").map { |i| i[:worn_on] }
      # A filled slot the MUD named nothing for is still a slot.
      assert_equal "", r.player_items(location: "equipped").last[:descr]
      # An unknown location is not a filter — it would silently show everything,
      # so it is ignored and the caller gets the whole bag it asked wrongly for.
      assert_equal 5, r.player_items(location: "banana").length
    ensure
      r&.close
    end

    # ---------- serving an OLDER agent's file -----------------------------
    #
    # The seam the whole `player_half?` gate exists for. Named columns are the
    # drift detector, and a named SELECT of a column that does not exist RAISES
    # — so without the gate, one monitor upgrade would turn every V1 file into a
    # schema-mismatch banner.

    test "a v1 file still answers, with the player half simply absent" do
      use_knowledge_db(sql: File.read(Rails.root.join("test/fixtures/knowledge/seed_v1.sql")),
                       name: "old.sqlite3")
      r = reader

      assert_equal 1, r.schema_version
      player = r.player
      # Everything V1 knew is still there…
      assert_equal [ 18, 2, 15 ], [ player[:hp], player[:level], player[:gold] ]
      assert_equal({ id: 5, name: "The Common Square" }, player[:current_room])
      # …and everything it did not know reads as "no reading", which is exactly
      # what these fields say on a V2 file the agent has not scored on yet.
      assert_nil player[:max_mana]
      assert_nil player[:title]
      assert_nil player[:items_updated_at]
      assert_equal [], player[:conditions]
      assert_equal [], r.player_skills
      assert_equal [], r.player_items
      assert_equal({ skills: 0, items: 0 }, r.stats.slice(:skills, :items))
      assert_equal 5, r.stats[:rooms], "the map half is unaffected"
    ensure
      r&.close
    end

    # A file the agent created but has not yet looked around in.
    test "player is nil when no player_state row exists" do
      use_knowledge_db(sql: File.read(KnowledgeFixtures::SEED_SQL).sub(/INSERT INTO player_state.*?;/m, ""))
      r = reader

      assert r.attached?
      assert_nil r.player
      assert_equal 5, r.stats[:rooms]
    ensure
      r&.close
    end

    private

    def count_statements
      r = reader
      r.stats # open the connection outside the measurement
      count = 0
      tracer = ->(sql) { count += 1 if sql.to_s.lstrip.match?(/\ASELECT/i) }
      r.send(:db).trace(&tracer)
      yield r
      r.send(:db).trace(nil)
      count
    ensure
      r&.close
    end

    def seed_extra_rooms(n)
      db = SQLite3::Database.new(knowledge_db_path.to_s)
      db.transaction do
        (1..n).each do |i|
          id = 100 + i
          db.execute(<<~SQL, [ id, "weak#{id}", "Filler #{id}", "A filler room.", "[]" ])
            INSERT INTO rooms (id, weak_fingerprint, confidence, name, description, look_candidates,
                               first_seen_at, last_seen_at, visit_count)
            VALUES (?, ?, 'confirmed', ?, ?, ?, '2026-07-23T00:00:00Z', '2026-07-23T00:00:00Z', 1)
          SQL
          db.execute("INSERT INTO room_exits (room_id, direction, traversals, last_seen_at) VALUES (?, 'north', 0, '2026-07-23T00:00:00Z')", [ id ])
        end
      end
      db.close
    end
  end
end
