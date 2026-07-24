require "json"
require "time"
require_relative "schema"
require_relative "fingerprint"

module Boukensha
  module Mud
    module Memory
      # The agent's knowledge of the world, on disk.
      #
      # boukensha is the ONLY writer. mud_monitor is a read-only reader of
      # another process's file, exactly as it already is for sessions/, telnet/
      # and manager/ — which is why WAL is set at open and is not optional: a
      # monitor page refresh must never be able to hand the agent SQLITE_BUSY
      # mid-turn.
      #
      # The path comes from Config, so the writer and mud_monitor resolve
      # `boukensha_dir` identically by construction rather than by both
      # remembering to. Getting that resolution wrong is exactly what made the
      # monitor's telnet/manager pages report "logging is off".
      class Store
        # The naming convention is mud_monitor's, not ours — its initializer
        # already probes `<boukensha_dir>/knowledge.sqlite3` for the health
        # endpoint's `knowledge_attached` flag. Creating this file is what flips
        # that to true with no monitor changes at all.
        FILENAME = "knowledge.sqlite3".freeze

        class Unavailable < StandardError; end

        attr_reader :db, :path

        # Optional progression journal. When wired, every mutation below also
        # emits a delta, so the change log is generic CDC over the WHOLE
        # knowledgebase (rooms, exits, entities, sightings, encounters, player
        # state), not a hand-picked subset. The journal owns change-detection, so
        # upserting an unchanged value writes nothing — no-ops are free here, and
        # the field-level keys make per-field volume measurable after the fact.
        attr_accessor :journal

        # `sqlite3` is required lazily, the same posture `onnxruntime` already
        # has: a checkout without the gem still boots, and only a caller that
        # actually wants memory pays for it.
        def self.open(path)
          begin
            require "sqlite3"
          rescue LoadError => e
            raise Unavailable, "the sqlite3 gem is not installed, so the agent has no memory (#{e.message})"
          end

          db = SQLite3::Database.new(path.to_s)
          db.results_as_hash = true

          # This is a game journal, not a ledger; and the monitor reads it while
          # we write it.
          db.execute("PRAGMA journal_mode=WAL")     # readers never block the writer
          db.execute("PRAGMA synchronous=NORMAL")
          db.execute("PRAGMA foreign_keys=ON")
          db.execute("PRAGMA busy_timeout=5000")

          Schema.migrate!(db)
          new(db, path)
        end

        # The store for a resolved boukensha dir. Mirrors mud_monitor's own
        # MUD_KNOWLEDGE_DB override so an operator can point both halves at one
        # file without editing two configs.
        def self.for_dir(dir)
          open(ENV.fetch("MUD_KNOWLEDGE_DB", File.join(dir.to_s, FILENAME)))
        end

        def initialize(db, path = nil)
          @db   = db
          @path = path
        end

        def close = @db.close

        # ---------- player ------------------------------------------------

        # Always a Hash — the single row if it exists, an empty one if not, so
        # no caller has to branch on "have we ever run before".
        def player
          row(@db.execute("SELECT * FROM player_state WHERE id = 1").first) || {}
        end

        # Merge non-nil fields into the single row. Nil means "no reading this
        # time", never "clear it": a `poll` that returns nothing must not wipe
        # the level we learned from the last `check(score)`.
        def update_player!(**fields)
          fields = fields.compact
          return if fields.empty?

          fields[:updated_at] = now
          cols = fields.keys
          @db.execute(
            "INSERT INTO player_state (id, #{cols.join(', ')}) VALUES (1, #{(['?'] * cols.size).join(', ')}) " \
            "ON CONFLICT(id) DO UPDATE SET #{cols.map { |c| "#{c} = excluded.#{c}" }.join(', ')}",
            fields.values
          )
          capture_player!(fields)
        end

        def level = player[:level]

        # ---------- rooms -------------------------------------------------

        def rooms_by_weak(fingerprint)
          @db.execute("SELECT * FROM rooms WHERE weak_fingerprint = ? ORDER BY id", [fingerprint]).map { |r| row(r) }
        end

        def room(id)
          return nil unless id

          row(@db.execute("SELECT * FROM rooms WHERE id = ?", [id]).first)
        end

        def create_room(name:, description:, weak_fingerprint:, strong_fingerprint: nil,
                        look_candidates: nil, confidence: "confirmed", surveyed: false)
          t = now
          @db.execute(
            "INSERT INTO rooms (weak_fingerprint, strong_fingerprint, confidence, name, description, " \
            "look_candidates, first_seen_at, last_seen_at, visit_count, surveyed_at) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)",
            [weak_fingerprint, strong_fingerprint, confidence, name, description,
             look_candidates && JSON.generate(look_candidates), t, t, (surveyed ? t : nil)]
          )
          id = @db.last_insert_row_id
          jevent("room", "create", id: id, name: name, confidence: confidence, surveyed: surveyed)
          id
        end

        # A revisit. This is the call that replaces five MUD round trips.
        def touch_room(id)
          @db.execute("UPDATE rooms SET visit_count = visit_count + 1, last_seen_at = ? WHERE id = ?", [now, id])
          jevent("room", "visit", id: id)
        end

        # Promote a room the survey has now fully resolved: the strong
        # fingerprint exists only once `check(exits)` has been paid for.
        def mark_surveyed!(id, strong_fingerprint: nil, look_candidates: nil, confidence: nil)
          sets = { surveyed_at: now, last_seen_at: now }
          sets[:strong_fingerprint] = strong_fingerprint if strong_fingerprint
          sets[:look_candidates]    = JSON.generate(look_candidates) if look_candidates
          sets[:confidence]         = confidence if confidence
          @db.execute("UPDATE rooms SET #{sets.keys.map { |k| "#{k} = ?" }.join(', ')} WHERE id = ?",
                      sets.values + [id])
          jevent("room", "surveyed", id: id)
        end

        # ---------- exits -------------------------------------------------

        def exits_for(room_id)
          @db.execute("SELECT * FROM room_exits WHERE room_id = ? ORDER BY direction", [room_id]).map { |r| row(r) }
        end

        def exit_at(room_id, direction)
          return nil unless room_id && direction

          row(@db.execute("SELECT * FROM room_exits WHERE room_id = ? AND direction = ?",
                          [room_id, direction.to_s]).first)
        end

        # Record what the room says its exits are. `dirs` is the free autoexit
        # line; `targets` is the { dir => name } that cost a check(exits) and may
        # be empty. Neither ever clears a target_room_id we have already earned.
        def record_exits!(room_id, dirs: [], targets: {})
          t = now
          (Array(dirs) | targets.keys.map(&:to_s)).each do |dir|
            name = targets[dir] || targets[dir.to_sym]
            @db.execute(
              "INSERT INTO room_exits (room_id, direction, target_name, last_seen_at) VALUES (?, ?, ?, ?) " \
              "ON CONFLICT(room_id, direction) DO UPDATE SET " \
              "target_name = COALESCE(excluded.target_name, room_exits.target_name), last_seen_at = excluded.last_seen_at",
              [room_id, dir.to_s, name, t]
            )
            # nil names are swallowed by upsert (no reading), so re-recording the
            # same autoexit line every turn is silent; only a newly-learned
            # target_name lands.
            jupsert("exit", "#{room_id}:#{dir}:target_name", name)
          end
        end

        # We walked it and arrived somewhere known: the edge is now real. This
        # is the write that turns a `?` into a `✓` in the state block, and the
        # only place `target_room_id` is ever set.
        def link_exit!(room_id, direction, target_room_id)
          return unless room_id && direction && target_room_id

          @db.execute(
            "INSERT INTO room_exits (room_id, direction, target_room_id, traversals, last_seen_at) " \
            "VALUES (?, ?, ?, 1, ?) " \
            "ON CONFLICT(room_id, direction) DO UPDATE SET " \
            "target_room_id = excluded.target_room_id, traversals = room_exits.traversals + 1, " \
            "last_seen_at = excluded.last_seen_at",
            [room_id, direction.to_s, target_room_id, now]
          )
          jupsert("exit", "#{room_id}:#{direction}:target_room_id", target_room_id)
        end

        # We walked this way and landed somewhere the exits table did not name.
        # The room we are standing in wins.
        def rename_exit_target!(room_id, direction, name)
          return unless room_id && direction && name

          @db.execute("UPDATE room_exits SET target_name = ? WHERE room_id = ? AND direction = ?",
                      [name, room_id, direction.to_s])
          jupsert("exit", "#{room_id}:#{direction}:target_name", name)
        end

        # A room cannot move; a stale edge can. So a conflict between the edge we
        # walked and the room we actually landed in is resolved in the room's
        # favour, and the edge pays for it.
        def demote_exit!(room_id, direction)
          return unless room_id && direction

          @db.execute(
            "UPDATE room_exits SET traversals = MAX(traversals - 1, 0), target_room_id = NULL " \
            "WHERE room_id = ? AND direction = ?", [room_id, direction.to_s]
          )
          jevent("exit", "demote", room_id: room_id, direction: direction.to_s)
        end

        # ---------- entities ----------------------------------------------

        # A remembered mob/object TYPE, with the one piece of level-relative
        # judgement flagged rather than silently served: `threat_fresh` is false
        # once the player has levelled past the reading, because "you could take
        # him" measured twenty levels ago is precisely the confident lie the
        # Strategy section is trying to avoid.
        def entity_for(descr, kind: "mob")
          r = row(@db.execute("SELECT * FROM entities WHERE kind = ? AND descr = ?", [kind, descr.to_s]).first)
          return nil unless r

          r[:equipment]    = r[:equipment] ? (JSON.parse(r[:equipment]) rescue nil) : nil
          r[:threat_fresh] = !r[:threat].nil? && r[:threat_level] == level
          r
        end

        # The reverse lookup combat needs: the agent attacks `fido`, and the
        # encounter has to be filed against the type that keyword resolved to.
        # Most recently seen wins, because that is the one we are standing next
        # to.
        def entity_by_keyword(keyword, kind: "mob")
          return nil unless keyword

          row(@db.execute("SELECT * FROM entities WHERE kind = ? AND keyword = ? ORDER BY last_seen_at DESC LIMIT 1",
                          [kind, keyword.to_s.downcase]).first)
        end

        def remember_entity(kind:, descr:, keyword: nil, threat: nil, equipment: nil)
          t = now
          @db.execute(
            "INSERT INTO entities (kind, descr, keyword, equipment, threat, threat_level, first_seen_at, last_seen_at) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?) " \
            "ON CONFLICT(kind, descr) DO UPDATE SET " \
            "keyword      = COALESCE(excluded.keyword,      entities.keyword), " \
            "equipment    = COALESCE(excluded.equipment,    entities.equipment), " \
            "threat       = COALESCE(excluded.threat,       entities.threat), " \
            "threat_level = COALESCE(excluded.threat_level, entities.threat_level), " \
            "seen_count   = entities.seen_count + 1, " \
            "last_seen_at = excluded.last_seen_at",
            [kind, descr.to_s, keyword, equipment && JSON.generate(equipment), threat, (threat && level), t, t]
          )
          id = @db.execute("SELECT id FROM entities WHERE kind = ? AND descr = ?", [kind, descr.to_s]).first["id"]
          # The appraisal is the meaningful delta over time; descr/keyword are
          # static, so they are not journaled as a series.
          jupsert("entity", "#{id}:threat", threat)
          id
        end

        def record_sighting!(entity_id:, room_id:, count: 1)
          return unless entity_id && room_id

          t = now
          @db.execute(
            "INSERT INTO entity_sightings (entity_id, room_id, count, sighting_count, first_seen_at, last_seen_at) " \
            "VALUES (?, ?, ?, 1, ?, ?) " \
            "ON CONFLICT(entity_id, room_id) DO UPDATE SET " \
            "count = excluded.count, sighting_count = entity_sightings.sighting_count + 1, " \
            "last_seen_at = excluded.last_seen_at",
            [entity_id, room_id, count, t, t]
          )
          jupsert("sighting", "#{entity_id}:#{room_id}:count", count)
        end

        # ---------- encounters --------------------------------------------

        def record_encounter!(outcome:, room_id: nil, entity_id: nil, hp_before: nil, hp_after: nil)
          @db.execute(
            "INSERT INTO encounters (room_id, entity_id, player_level, outcome, hp_before, hp_after, at) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            [room_id, entity_id, level, outcome.to_s, hp_before, hp_after, now]
          )
          jevent("encounter", outcome.to_s, room_id: room_id, entity_id: entity_id,
                                            player_level: level, hp_before: hp_before, hp_after: hp_after)
          @db.last_insert_row_id
        end

        # Every outcome we have ever had against this type, worst news first.
        # `died` sorts above `fled` above `won` because that is the order the
        # agent needs to read them in when deciding whether to swing.
        def encounters_for(entity_id)
          return [] unless entity_id

          @db.execute(
            "SELECT * FROM encounters WHERE entity_id = ? " \
            "ORDER BY CASE outcome WHEN 'died' THEN 0 WHEN 'fled' THEN 1 WHEN 'abandoned' THEN 2 ELSE 3 END, at DESC",
            [entity_id]
          ).map { |r| row(r) }
        end

        # ---------- counters ----------------------------------------------

        # What mud_monitor's "rooms known vs rooms that exist" diff reads, and
        # the only honest measure of whether any of this is working.
        def stats
          {
            rooms:      scalar("SELECT COUNT(*) FROM rooms"),
            surveyed:   scalar("SELECT COUNT(*) FROM rooms WHERE surveyed_at IS NOT NULL"),
            frontier:   scalar("SELECT COUNT(*) FROM room_exits WHERE target_room_id IS NULL"),
            entities:   scalar("SELECT COUNT(*) FROM entities"),
            encounters: scalar("SELECT COUNT(*) FROM encounters")
          }
        end

        private

        # ---------- change journal helpers --------------------------------
        # All no-ops when no journal is wired; `upsert` itself is internally
        # guarded, so a broken journal never breaks a store write.

        # A keyed-value delta (change-detected: unchanged values write nothing).
        # Use for anything re-written frequently with often-identical values —
        # player fields, exit targets, entity threat, sighting counts.
        def jupsert(stream, key, value)
          @journal&.upsert(stream: stream, key: key.to_s, value: value)
        end

        # A discrete occurrence (always appended). Use for genuinely one-off
        # writes — a room discovered, an encounter resolved.
        def jevent(stream, op, **fields)
          @journal&.event(stream: stream, op: op.to_s, **fields)
        end

        # Player_state is one row of scalars, so each written field becomes its
        # own `stat` series keyed by column. `updated_at` is skipped — it changes
        # on every write and would be pure noise.
        def capture_player!(fields)
          fields.each do |col, val|
            next if col == :updated_at

            jupsert("stat", col, val)
          end
        end

        def scalar(sql) = @db.execute(sql).first.values.first.to_i

        def now = Time.now.utc.iso8601

        # sqlite3 hands back string keys; everything above this line speaks
        # symbols. One conversion, in one place.
        def row(hash)
          return nil unless hash

          hash.each_with_object({}) { |(k, v), out| out[k.to_sym] = v if k.is_a?(String) }
        end
      end
    end
  end
end
