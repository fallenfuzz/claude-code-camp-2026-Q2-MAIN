require "json"
require "set"
require "time"
require_relative "schema"
require_relative "fingerprint"
require_relative "regions"
require_relative "exit_resolution"
# The assessment vocabulary, reached across the layer for the same reason
# `ExitResolution` reaches `DestinationSearch`: it is a dependency-free set of
# constants, and a second copy of the strings written into `frontier_hints` would
# be a second definition of what they mean.
require_relative "../navigation/assessment"
require_relative "../navigation/egress"

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

        # Wraps the SQLite3 handle, counts `execute` by statement kind, and
        # forwards everything else — get_first_value, execute_batch, transaction,
        # last_insert_row_id, close — untouched. `Store#db` is public and the
        # tests reach through it, so transparency is a requirement and not a
        # nicety.
        #
        # Read vs write is the leading SQL keyword, which is exact for every
        # statement this store issues and is the only classification available
        # without parsing SQL. `transaction` forwards to the real handle while
        # the statements INSIDE it still arrive here, so a wholesale
        # `replace_items!` is counted as the N writes it performs.
        class CountingDb
          def initialize(db)
            @db      = db
            @reads   = 0
            @writes  = 0
            @ms      = 0.0
          end

          def execute(sql, *rest, &blk)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            @db.execute(sql, *rest, &blk)
          ensure
            @ms += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
            write?(sql) ? @writes += 1 : @reads += 1
          end

          # Session-lifetime totals. A span publishes only the delta across its
          # own interval, which cannot double-count a nested span — a delta over
          # an interval is exactly what nesting means.
          def counters = { db_reads: @reads, db_writes: @writes, db_ms: @ms.round }

          def method_missing(name, *args, &blk)
            @db.respond_to?(name) ? @db.send(name, *args, &blk) : super
          end

          def respond_to_missing?(name, include_private = false)
            @db.respond_to?(name, include_private) || super
          end

          private

          WRITE = /\A\s*(?:INSERT|UPDATE|DELETE|REPLACE)\b/i.freeze

          def write?(sql) = WRITE.match?(sql.to_s)
        end

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
          # Every query in this class funnels through @db, so ONE proxy at
          # construction instruments all 26 `execute` call sites without
          # touching a single one of them. The PRAGMAs and Schema.migrate! in
          # `.open` run against the raw handle, BEFORE the wrap — correctly, as
          # those are boot, not work.
          @db   = db.is_a?(CountingDb) ? db : CountingDb.new(db)
          @path = path
          # True at open, not false: this process has derived nothing yet, and
          # the file may have been left by a previous one that walked further
          # than the room_regions rows in it describe.
          @regions_dirty = true
        end

        # The meter Logger#operation reads at span open and close. Counters, not
        # statements: every SQL statement as its own transcript entry would bury
        # the narrative under ~20 rows per survey to answer a question nobody
        # asks per-statement. What is wanted is the shape of the work — this
        # operation read 6 rows and wrote 11, in 3ms.
        def counters = @db.counters

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

        # Position is no longer something anyone can assert. This needs its own
        # method because `update_player!` compacts its arguments, so a nil there
        # means "this reading is absent" — the right default for a partial
        # update and exactly wrong here, where the nil IS the reading.
        #
        # Clearing the STORE matters and not only the hook's ivar: `move_to`,
        # `plan_route` and the survey all take their starting room from
        # `player[:current_room_id]`, so a stale value here is a subsystem
        # confidently planning routes out of a room the character has left.
        def clear_player_room!
          @db.execute("UPDATE player_state SET current_room_id = NULL, updated_at = ? WHERE id = 1", [now])
          jupsert("player", "current_room_id", nil)
        end

        def set_player_identity!(player_class:, gender:)
          update_player!(player_class: player_class, gender: gender)
        end

        def level = player[:level]

        # ---------- skills (EARNED) ---------------------------------------

        # Upserted in place, the shape of remember_entity: a skill the agent
        # knows does not stop being known because this reading did not mention
        # it, so nothing here ever deletes. `learned_level` is stamped once, on
        # the reading that first saw the skill KNOWN — after that it is the
        # answer to "when did I get this", and re-learning must not move it.
        def upsert_skills!(skills)
          rows = Array(skills).reject { |s| s[:name].to_s.strip.empty? }
          return if rows.empty?

          t = now
          @db.transaction do
            rows.each do |s|
              learned = s[:learned] ? 1 : 0
              @db.execute(
                "INSERT INTO player_skills (name, proficiency, learned, kind, learned_level, first_seen_at, last_seen_at) " \
                "VALUES (?, ?, ?, ?, ?, ?, ?) " \
                "ON CONFLICT(name) DO UPDATE SET " \
                "proficiency   = COALESCE(excluded.proficiency, player_skills.proficiency), " \
                "learned       = excluded.learned, " \
                "kind          = COALESCE(excluded.kind, player_skills.kind), " \
                "learned_level = COALESCE(player_skills.learned_level, excluded.learned_level), " \
                "last_seen_at  = excluded.last_seen_at",
                [s[:name].to_s, s[:proficiency], learned, s[:kind],
                 (s[:learned] ? level : nil), t, t]
              )
            end
          end
          # The grade is the meaningful series — "armor: not learned -> good" is
          # a progression event. The journal change-detects, so re-reading the
          # same listing every practice writes nothing.
          rows.each { |s| jupsert("skill", "#{s[:name]}:proficiency", s[:proficiency]) }
        end

        def skills
          @db.execute("SELECT * FROM player_skills ORDER BY name").map { |r| row(r) }
        end

        # ---------- items (VOLATILE snapshot) -----------------------------

        # Wholesale replace, in ONE transaction — update_player!'s "overwrite,
        # don't accumulate" with N rows instead of one. A dropped item vanishes
        # the instant the next snapshot lands, which is the entire point: the
        # agent must never read back a bag it no longer has.
        #
        # The delete is scoped to the `location` being replaced, so a fresh
        # `inventory` read never wipes the last known `equipment` and vice
        # versa. An EMPTY list is a legitimate snapshot ("the pack is empty")
        # and clears the table; refusing to read at all is the caller's job,
        # not this method's — see Hooks#capture_items.
        def replace_items!(location:, items:)
          loc = location.to_s
          raise ArgumentError, "unknown item location #{loc.inspect}" unless %w[inventory equipped].include?(loc)

          t = now
          @db.transaction do
            @db.execute("DELETE FROM player_items WHERE location = ?", [loc])
            Array(items).each do |i|
              descr = i[:descr].to_s
              next if descr.empty?

              @db.execute(
                "INSERT INTO player_items (location, worn_on, keyword, descr, quantity, updated_at) " \
                "VALUES (?, ?, ?, ?, ?, ?)",
                [loc, i[:worn_on], i[:keyword], descr, (i[:quantity] || 1).to_i, t]
              )
            end
          end
          # Stamped only on a real replacement, which is what makes staleness
          # honest: a mutation with no following read leaves this untouched and
          # the monitor says "snapshot as of T" rather than inventing a delta.
          update_player!(items_updated_at: t)
        end

        def items(location: nil)
          sql    = "SELECT * FROM player_items"
          params = []
          if location
            sql += " WHERE location = ?"
            params << location.to_s
          end
          @db.execute("#{sql} ORDER BY location, id", params).map { |r| row(r) }
        end

        # ---------- rooms -------------------------------------------------

        def rooms_by_weak(fingerprint)
          @db.execute("SELECT * FROM rooms WHERE weak_fingerprint = ? ORDER BY id", [fingerprint]).map { |r| row(r) }
        end

        def room(id)
          return nil unless id

          row(@db.execute("SELECT * FROM rooms WHERE id = ?", [id]).first)
        end

        # Every room the agent has ever stood in, one query. The snapshot
        # `plan_route` needs: destination search and BFS both run over this
        # in memory rather than issuing a query per room.
        def rooms
          @db.execute("SELECT * FROM rooms ORDER BY id").map { |r| row(r) }
        end

        # `arrived_from`/`arrived_direction` are the first-arrival edge, and
        # they are written HERE and nowhere else — this method runs once per
        # room, on the visit that discovered it, which is exactly the moment
        # the answer is known and the only moment it is true. A later visit by
        # another route must never revise it, or region inheritance would
        # re-parent rooms behind the agent's back.
        def create_room(name:, description:, weak_fingerprint:, strong_fingerprint: nil,
                        look_candidates: nil, confidence: "confirmed", surveyed: false,
                        arrived_from: nil, arrived_direction: nil)
          t = now
          @db.execute(
            "INSERT INTO rooms (weak_fingerprint, strong_fingerprint, confidence, name, description, " \
            "look_candidates, first_seen_at, last_seen_at, visit_count, surveyed_at, " \
            "arrived_from_room_id, arrived_direction) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)",
            [weak_fingerprint, strong_fingerprint, confidence, name, description,
             look_candidates && JSON.generate(look_candidates), t, t, (surveyed ? t : nil),
             arrived_from, arrived_direction&.to_s]
          )
          id = @db.last_insert_row_id
          # A new room is a new leaf on the inheritance forest, so the
          # derivation owes an answer for it.
          @regions_dirty = true
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

        # Every exit the agent has ever recorded, one query — `plan_route`'s
        # other half of the graph snapshot. Linked rows (target_room_id set)
        # are traversable edges; rows with a null target_room_id are the
        # exploration frontier. Ordered for determinism, matching #exits_for.
        def all_exits
          @db.execute("SELECT * FROM room_exits ORDER BY room_id, direction").map { |r| row(r) }
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
          # Both inputs to name resolution have just changed — this room is new
          # or newly named, and its exits may name rooms recorded long ago while
          # rooms recorded long ago may name this one. The pass is over the whole
          # map for that second reason: a new room satisfies exits ELSEWHERE, and
          # a pass scoped to this room's own exits would never find them.
          resolve_exit_names!
        end

        # We walked it and arrived somewhere known: the edge is now real. This
        # is the write that turns a `?` into a `✓` in the state block, and the
        # only place `target_room_id` is ever set.
        def link_exit!(room_id, direction, target_room_id)
          return unless room_id && direction && target_room_id

          # The presumption is cleared in the same statement that earns the edge.
          # An earned target always supersedes a presumed one, and leaving both
          # set would mean every reader had to know which wins.
          @db.execute(
            "INSERT INTO room_exits (room_id, direction, target_room_id, traversals, last_seen_at) " \
            "VALUES (?, ?, ?, 1, ?) " \
            "ON CONFLICT(room_id, direction) DO UPDATE SET " \
            "target_room_id = excluded.target_room_id, presumed_target_id = NULL, " \
            "traversals = room_exits.traversals + 1, last_seen_at = excluded.last_seen_at",
            [room_id, direction.to_s, target_room_id, now]
          )
          jupsert("exit", "#{room_id}:#{direction}:target_room_id", target_room_id)
        end

        # ---------- exit name resolution ------------------------------------
        # docs/plans/week_3/exit_name_resolution.md. The MUD names the room
        # behind an exit and we have been throwing that away; this matches those
        # names against rooms already in memory and records a PRESUMED link.
        #
        # `presumed_target_id` is a separate column from `target_room_id` and the
        # separation is the whole design. An earned edge was walked; a presumed
        # edge was merely named, and the two must stay distinguishable in the
        # frontier calculation, in routing preference, and in what the model is
        # shown. Nothing here ever writes `target_room_id` — `link_exit!` remains
        # its only writer.

        # Recompute every presumption over the whole map. Cheap by design: at the
        # room counts this project measures the pass is a few dozen normalised
        # string comparisons, and a full pass is the only version that handles
        # the case that matters — a newly discovered room satisfying an exit
        # recorded several rooms ago, somewhere else entirely.
        #
        # Returns the number of presumptions that CHANGED, so a caller can tell a
        # pass that did something from one that confirmed the status quo.
        def resolve_exit_names!
          exits = all_exits
          known = rooms
          # A name observed on two distinct rooms is not an identifier, and it
          # stays not-an-identifier: the finding is persisted rather than only
          # derived, so a later map where one of the two rooms has been merged
          # away cannot quietly make the name trustworthy again.
          ExitResolution.ambiguous_names(rooms: known).each do |name|
            note_ambiguous_exit_name!(name, reason: "names more than one known room")
          end

          resolved = ExitResolution.resolve(rooms: known, exits: exits, ambiguous: ambiguous_exit_names)
          current  = exits.to_h { |e| [[e[:room_id], e[:direction].to_s], e[:presumed_target_id]] }

          changed = 0
          @db.transaction do
            resolved.each do |(room_id, direction), target_id|
              next if current[[room_id, direction]] == target_id

              @db.execute("UPDATE room_exits SET presumed_target_id = ? WHERE room_id = ? AND direction = ?",
                          [target_id, room_id, direction])
              jupsert("exit", "#{room_id}:#{direction}:presumed_target_id", target_id)
              changed += 1
            end
          end
          changed
        end

        def ambiguous_exit_names
          @db.execute("SELECT name FROM exit_name_ambiguity").map { |r| r["name"] }
        end

        def note_ambiguous_exit_name!(name, reason:)
          normalized = ExitResolution::Search.normalize(name)
          return if normalized.empty?

          @db.execute(
            "INSERT INTO exit_name_ambiguity (name, reason, noted_at) VALUES (?, ?, ?) " \
            "ON CONFLICT(name) DO NOTHING", [normalized, reason.to_s, now]
          )
        end

        # A presumption that walking proved wrong. The edge is cleared and the
        # NAME is poisoned, which is what gives the mechanism its useful
        # property: a wrong guess costs exactly one move and then never recurs,
        # where the sparse graph it replaced cost every future route that needed
        # the edge.
        #
        # Except for a presumption made on the ARRIVAL edge rather than on the
        # name. That one says "the agent walked in from this specific room by this
        # specific direction and the exit facing back carries that room's name",
        # and a passage that turns out not to run both ways has told us something
        # about the passage, not about the name — poisoning the name would take
        # every other exit that legitimately resolves through it down with it.
        #
        # Nothing re-guesses the refuted edge either way: `Hooks#link_arrival`
        # calls this and then `link_exit!` with the room the walk actually landed
        # in, and `ExitResolution` never revises an earned target. Poisoning was
        # never what protected THIS exit — it protects every other exit that would
        # have been presumed from the same name, which is a claim an arrival edge
        # does not make.
        #
        # The basis is re-derived here and recorded on the journal event, because
        # a refutation whose reasoning is invisible is indistinguishable from a
        # bug in it.
        def refute_presumed_target!(room_id, direction, target_name: nil)
          basis = arrival_presumption?(room_id, direction, target_name) ? "arrival" : "name"
          @db.execute("UPDATE room_exits SET presumed_target_id = NULL WHERE room_id = ? AND direction = ?",
                      [room_id, direction.to_s])
          if target_name && basis == "name"
            note_ambiguous_exit_name!(target_name, reason: "walking the exit did not lead to the named room")
          end
          jevent("exit", "presumption_refuted", room_id: room_id, direction: direction.to_s,
                                                target_name: target_name, basis: basis)
        end

        # Would `ExitResolution` have made this presumption from the arrival edge?
        # Derived rather than stored: the arrival columns are written once, at
        # discovery, and never revised, so the answer is the same whenever it is
        # asked and a column recording it would be a second copy of a fact the
        # rows already carry.
        def arrival_presumption?(room_id, direction, target_name)
          here = room(room_id)
          return false unless here

          ExitResolution.arrival_link?(room: here, source: room(here[:arrived_from_room_id]),
                                       direction: direction, target_name: target_name)
        end

        # We walked this way and landed somewhere the exits table did not name.
        # The room we are standing in wins.
        def rename_exit_target!(room_id, direction, name)
          return unless room_id && direction && name

          @db.execute("UPDATE room_exits SET target_name = ? WHERE room_id = ? AND direction = ?",
                      [name, room_id, direction.to_s])
          jupsert("exit", "#{room_id}:#{direction}:target_name", name)
        end

        # We walked this exit, we are no longer where we were, and a follow-up
        # `look` could not name where we ended up. The exit is recorded as
        # opaque so the frontier calculation stops offering it — see the V8
        # migration for why this is a property of the exit rather than of the
        # room behind it, and why it is not called `dark`.
        def note_opaque_exit!(room_id, direction)
          return unless room_id && direction

          @db.execute(
            "INSERT INTO room_exits (room_id, direction, opaque, last_seen_at) VALUES (?, ?, 1, ?) " \
            "ON CONFLICT(room_id, direction) DO UPDATE SET opaque = 1, last_seen_at = excluded.last_seen_at",
            [room_id, direction.to_s, now]
          )
          # A walk that paid no information has established retrospectively exactly
          # what the surveyor is asked to predict about an unwalked exit, so the
          # finding is recorded in the same place and in the same vocabulary
          # (blind_step_recovery.md §5.1). `opaque` already keeps THIS exit out of
          # the frontier set; the assessment is what tells a later ranker why, and
          # it is the only assessment available for exits no surveyor ever saw.
          # Hazard is left alone: nothing about being unreadable says dangerous.
          record_frontier_hint!(room_id: room_id, direction: direction,
                                assessability: Navigation::Assessment::UNASSESSABLE)
          jupsert("exit", "#{room_id}:#{direction}:opaque", 1)
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

        # ---------- regions -------------------------------------------------
        # boundaries_revised.md §2/§6. Two EARNED tables the agent writes by
        # declaration, one DERIVED table this store rewrites wholesale, and a
        # dirty flag so the derivation runs lazily on the next READ rather than
        # inside a MUD round trip.

        def regions
          @db.execute("SELECT * FROM regions ORDER BY id").map { |r| row(r) }
        end

        def region(id)
          return nil unless id

          row(@db.execute("SELECT * FROM regions WHERE id = ?", [id]).first)
        end

        def region_by_label(label)
          return nil unless label

          row(@db.execute("SELECT * FROM regions WHERE label = ?", [label.to_s]).first)
        end

        def region_boundaries
          @db.execute("SELECT * FROM region_boundaries ORDER BY id").map { |r| row(r) }
        end

        def create_region!(label:, confirmed: false, description: nil, parent_id: nil, seed_room_id: nil)
          t = now
          @db.execute(
            "INSERT INTO regions (label, confirmed, description, parent_id, seed_room_id, first_seen_at, updated_at) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            [label.to_s, (confirmed ? 1 : 0), description, parent_id, seed_room_id, t, t]
          )
          id = @db.last_insert_row_id
          @regions_dirty = true
          jevent("region", "create", id: id, label: label.to_s, confirmed: confirmed)
          id
        end

        # Declarations are EARNED and never silently overwritten, so this
        # touches only the fields it was actually given.
        def update_region!(id, **fields)
          fields = fields.compact
          return if fields.empty? || id.nil?

          fields[:confirmed] = fields[:confirmed] ? 1 : 0 if fields.key?(:confirmed)
          fields[:updated_at] = now
          @db.execute("UPDATE regions SET #{fields.keys.map { |k| "#{k} = ?" }.join(', ')} WHERE id = ?",
                      fields.values + [id])
          @regions_dirty = true
          jevent("region", "update", id: id, **fields)
        end

        # Fold one region into another: the boundaries that declared it, the
        # regions nested inside it, and its seed all move, and then it is gone.
        # This is what "naming it something that already exists merges the two"
        # means, and it is the only operation here that DELETES a declaration —
        # justified because the agent said the two names are one place.
        def merge_region!(from_id, into_id)
          return if from_id.nil? || into_id.nil? || from_id == into_id

          @db.transaction do
            @db.execute("UPDATE region_boundaries SET region_id = ? WHERE region_id = ?", [into_id, from_id])
            @db.execute("UPDATE regions SET parent_id = ? WHERE parent_id = ?", [into_id, from_id])
            seed = @db.execute("SELECT seed_room_id FROM regions WHERE id = ?", [from_id]).first
            target_seed = @db.execute("SELECT seed_room_id FROM regions WHERE id = ?", [into_id]).first
            if seed && seed["seed_room_id"] && !(target_seed && target_seed["seed_room_id"])
              @db.execute("UPDATE regions SET seed_room_id = ? WHERE id = ?", [seed["seed_room_id"], into_id])
            end
            @db.execute("DELETE FROM room_regions WHERE region_id = ?", [from_id])
            @db.execute("DELETE FROM regions WHERE id = ?", [from_id])
          end
          @regions_dirty = true
          jevent("region", "merge", from: from_id, into: into_id)
        end

        # `kind:` separates the two things a boundary row can mean. A `split` is
        # an internal division — this room starts a quarter of the place you are
        # already in — and is what every caller before staying_in_town.md wrote.
        # An `egress` says the edge LEAVES the place, and it is not a declaration
        # about any region's extent: it is never given to `Regions.derive`,
        # because that function reads `to_room_id` as a root that starts a region
        # there, and a room outside the walls does not start Midgaard.
        def declare_boundary!(from_room_id:, to_room_id:, direction:, region_id:, reason: nil,
                              session_id: nil, kind: BOUNDARY_SPLIT)
          kind = BOUNDARY_KINDS.include?(kind.to_s) ? kind.to_s : BOUNDARY_SPLIT
          @db.execute(
            "INSERT INTO region_boundaries (from_room_id, to_room_id, direction, region_id, reason, declared_at, session_id, kind) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [from_room_id, to_room_id, direction.to_s, region_id, reason, now, session_id, kind]
          )
          @regions_dirty = true
          jevent("region_boundary", "declare", from_room_id: from_room_id, to_room_id: to_room_id,
                                               direction: direction.to_s, region_id: region_id, kind: kind)
          @db.last_insert_row_id
        end

        BOUNDARY_SPLIT  = "split".freeze
        BOUNDARY_EGRESS = "egress".freeze
        BOUNDARY_KINDS  = [BOUNDARY_SPLIT, BOUNDARY_EGRESS].freeze

        # The crossings, as unordered room pairs. A boundary is a boundary in
        # both directions — walking back in through a gate crosses the same wall
        # as walking out through it — and every consumer asks a question about
        # SHAPE ("which side of the wall is this room on"), which is the same
        # place `SurveyGraph#undirected` argues direction is noise.
        def egress_edges
          region_boundaries.select { |b| b[:kind].to_s == BOUNDARY_EGRESS }
                           .map { |b| [b[:from_room_id], b[:to_room_id]].sort }
                           .uniq
        end

        # { room_id => { region_id:, basis: } }, derivation-fresh. The lazy
        # recompute hangs off the READ rather than off every graph write,
        # because the graph changes on every arrival and nothing reads the
        # answer until the state block or a route asks for it.
        def room_regions
          recompute_regions! if @regions_dirty
          @db.execute("SELECT * FROM room_regions ORDER BY room_id")
             .each_with_object({}) { |r, h| h[r["room_id"]] = { region_id: r["region_id"], basis: r["basis"] } }
        end

        def region_for_room(room_id)
          return nil unless room_id

          m = room_regions[room_id] or return nil
          region(m[:region_id])&.merge(basis: m[:basis])
        end

        # Every region at or beneath `id`. `scope: "region"` means the place
        # you are in AND everything within it, which is what makes Inn→Pub
        # reachable without a bakery search wandering into every building
        # (§5, "quarters nest rather than partition").
        def region_descendants(id)
          return [] unless id

          children = regions.group_by { |r| r[:parent_id] }
          out  = []
          queue = [id]
          until queue.empty?
            current = queue.shift
            next if out.include?(current)

            out << current
            queue.concat((children[current] || []).map { |r| r[:id] })
          end
          out
        end

        # Rewrite the DERIVED table in full — the same overwrite semantics as
        # `replace_items!`, and for the same reason: a membership that is no
        # longer true is a lie, not a history. Two passes, because seeding a
        # provisional region for a root that has none is a WRITE and the
        # derivation itself is pure; the second pass has nothing left to seed.
        def recompute_regions!
          @regions_dirty = false
          all = rooms
          return if all.empty?

          # SPLITS only. `Regions.derive` reads a boundary's `to_room_id` as a
          # root that starts `region_id` there, which is right for a split and
          # exactly wrong for an egress: an egress row records that the agent
          # walked OUT of a place, and handing it to the derivation would declare
          # the field beyond the gate to be the start of the town.
          splits = region_boundaries.reject { |b| b[:kind].to_s == BOUNDARY_EGRESS }
          memberships, seeds = Regions.derive(rooms: all, regions: regions, boundaries: splits)
          if seeds.any?
            seeds.each { |s| create_region!(label: s[:label], seed_room_id: s[:room_id]) }
            @regions_dirty = false
            memberships, = Regions.derive(rooms: all, regions: regions, boundaries: splits)
          end

          t = now
          @db.transaction do
            @db.execute("DELETE FROM room_regions")
            memberships.each do |m|
              @db.execute("INSERT INTO room_regions (room_id, region_id, basis, computed_at) VALUES (?, ?, ?, ?)",
                          [m[:room_id], m[:region_id], m[:basis], t])
            end
          end
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

        # One batched join for every room's remembered entities, keyed by
        # room_id — `plan_route`'s destination search needs "which rooms has
        # this mob/object been seen in" without an N+1 query per room.
        # Sighting evidence, not presence: this says where a type has EVER
        # been seen, not where it is right now (see entity_sightings' own
        # comment in the schema).
        def entities_by_room
          @db.execute(
            "SELECT s.room_id AS room_id, e.descr AS descr, e.keyword AS keyword, e.kind AS kind " \
            "FROM entity_sightings s JOIN entities e ON e.id = s.entity_id " \
            "ORDER BY s.room_id"
          ).each_with_object(Hash.new { |h, k| h[k] = [] }) do |r, out|
            out[r["room_id"]] << { descr: r["descr"], keyword: r["keyword"], kind: r["kind"] }
          end
        end

        # ---------- frontier attempts ---------------------------------------
        # plan_route.md §6.3's follow-up: what has already been tried at an
        # unexplored exit, so repeated planning fans outward instead of
        # retrying the same blocked door.

        def record_frontier_attempt!(room_id:, direction:, outcome:)
          return unless room_id && direction

          @db.execute(
            "INSERT INTO frontier_attempts (room_id, direction, outcome, attempted_at) VALUES (?, ?, ?, ?)",
            [room_id, direction.to_s, outcome.to_s, now]
          )
          jevent("frontier_attempt", outcome.to_s, room_id: room_id, direction: direction.to_s)
        end

        # { [room_id, direction] => failed_count }, one query — RoutePlanner's
        # frontier ranking tie-break (fewer prior failures wins).
        def frontier_attempt_counts
          @db.execute(
            "SELECT room_id, direction, COUNT(*) AS n FROM frontier_attempts " \
            "WHERE outcome = 'failed' GROUP BY room_id, direction"
          ).each_with_object({}) { |r, h| h[[r["room_id"], r["direction"]]] = r["n"].to_i }
        end

        # ---------- claims (EARNED, and the survey's whole memory) -----------
        # docs/plans/week_3/movement_revisited/claims.md.
        #
        # The ledger is keyed by region and outlives the `move_to` call that
        # opened it, which is the single strongest argument for the model. A
        # coverage counter reading "fourteen rooms walked" means nothing at the
        # start of the next session; a `circuit_closes` claim standing at three
        # sides confirmed and one side unexplored tells the next survey exactly
        # where to resume.

        OPEN_STATUSES = %w[open parked].freeze

        def claims(region_id: nil, status: nil)
          sql    = "SELECT * FROM claims"
          where  = []
          params = []
          if region_id
            where << "region_id = ?"
            params << region_id
          end
          if status
            where << "status IN (#{(['?'] * Array(status).size).join(', ')})"
            params.concat(Array(status).map(&:to_s))
          end
          sql += " WHERE #{where.join(' AND ')}" if where.any?
          @db.execute("#{sql} ORDER BY id", params).map { |r| claim_row(r) }
        end

        def claim(id)
          return nil unless id

          claim_row(@db.execute("SELECT * FROM claims WHERE id = ?", [id]).first)
        end

        # The merge key is (region, predicate, subject) and not the statement,
        # because two surveys will phrase the same proposition differently and a
        # ledger that forked on wording would spread one claim's evidence across
        # several rows where none of them was decisive.
        def claim_by_subject(region_id:, predicate:, subject:)
          claim_row(@db.execute(
            "SELECT * FROM claims WHERE region_id IS ? AND predicate = ? AND subject IS ? ORDER BY id LIMIT 1",
            [region_id, predicate.to_s, subject&.to_s]
          ).first)
        end

        def create_claim!(region_id:, statement:, predicate:, subject: nil, status: "open",
                          confidence: 0.5, priority: 0.5, answers: nil, decisive_when: nil,
                          args: nil, room_budget: nil, objective: nil)
          t = now
          @db.execute(
            "INSERT INTO claims (region_id, ref, statement, predicate, subject, status, confidence, " \
            "priority, answers, decisive_when, args, room_budget, objective, created_at, updated_at) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [region_id, next_claim_ref(region_id), statement.to_s, predicate.to_s, subject&.to_s,
             status.to_s, confidence.to_f, priority.to_f, answers, decisive_when,
             args && JSON.generate(args), room_budget, objective, t, t]
          )
          id = @db.last_insert_row_id
          jevent("claim", "open", id: id, predicate: predicate.to_s, subject: subject,
                                  statement: statement, priority: priority)
          id
        end

        def update_claim!(id, **fields)
          fields = fields.compact
          return if fields.empty?

          fields[:args] = JSON.generate(fields[:args]) if fields[:args].is_a?(Hash)
          fields[:updated_at] = now
          @db.execute("UPDATE claims SET #{fields.keys.map { |k| "#{k} = ?" }.join(', ')} WHERE id = ?",
                      fields.values + [id])
          jevent("claim", "revise", id: id, **fields.slice(:status, :confidence, :priority, :settled_reason))
        end

        # A settled claim leaves the ledger's working set but never the file.
        # `unresolved` is a successful outcome and not a failure — "the wall road
        # runs along the north, east and south sides, and the western
        # continuation was not reached" answers the player's question far better
        # than a room count — and `refuted` is a finding in its own right.
        def settle_claim!(id, status:, reason: nil)
          update_claim!(id, status: status.to_s, settled_reason: reason)
          jevent("claim", "settle", id: id, status: status.to_s, reason: reason)
        end

        def add_claim_evidence!(claim_id:, polarity:, room_id: nil, note: nil)
          @db.execute(
            "INSERT INTO claim_evidence (claim_id, room_id, polarity, note, observed_at) VALUES (?, ?, ?, ?, ?)",
            [claim_id, room_id, polarity.to_s, note, now]
          )
          jevent("claim", "evidence", claim_id: claim_id, room_id: room_id,
                                      polarity: polarity.to_s, note: note)
        end

        def claim_evidence(claim_id)
          @db.execute("SELECT * FROM claim_evidence WHERE claim_id = ? ORDER BY id", [claim_id])
             .map { |r| row(r) }
        end

        # { claim_id => [evidence, …] }, one query — the report renders every
        # claim with its evidence and would otherwise issue a query per claim.
        def claim_evidence_by_claim(region_id: nil)
          sql = "SELECT e.* FROM claim_evidence e JOIN claims c ON c.id = e.claim_id"
          sql += " WHERE c.region_id IS ?" if region_id
          @db.execute("#{sql} ORDER BY e.id", region_id ? [region_id] : [])
             .group_by { |r| r["claim_id"] }
             .transform_values { |rs| rs.map { |r| row(r) } }
        end

        # ---------- features (the one durable per-room tag) -------------------
        # `circuit_closes`, `connects` and `bounds` all turn on deciding that
        # several separately observed rooms belong to ONE road or ONE wall. That
        # is not a property of any room, so it is a join table and not a column.

        def feature(region_id:, slug:)
          row(@db.execute("SELECT * FROM features WHERE region_id IS ? AND slug = ?",
                          [region_id, slug.to_s]).first)
        end

        def upsert_feature!(region_id:, slug:, label: nil)
          t = now
          @db.execute(
            "INSERT INTO features (region_id, slug, label, first_seen_at, updated_at) VALUES (?, ?, ?, ?, ?) " \
            "ON CONFLICT(region_id, slug) DO UPDATE SET " \
            "label = COALESCE(excluded.label, features.label), updated_at = excluded.updated_at",
            [region_id, slug.to_s, label, t, t]
          )
          feature(region_id: region_id, slug: slug)[:id]
        end

        def tag_feature_room!(feature_id:, room_id:, note: nil)
          @db.execute(
            "INSERT INTO feature_rooms (feature_id, room_id, note, observed_at) VALUES (?, ?, ?, ?) " \
            "ON CONFLICT(feature_id, room_id) DO UPDATE SET note = COALESCE(excluded.note, feature_rooms.note)",
            [feature_id, room_id, note, now]
          )
          jevent("feature", "tag", feature_id: feature_id, room_id: room_id, note: note)
        end

        # { slug => [room_id, …] } for one region — what the predicates that
        # reason over chains need, in one query.
        def feature_rooms(region_id: nil)
          sql = "SELECT f.slug, fr.room_id FROM feature_rooms fr JOIN features f ON f.id = fr.feature_id"
          sql += " WHERE f.region_id IS ?" if region_id
          @db.execute(sql, region_id ? [region_id] : [])
             .group_by { |r| r["slug"] }
             .transform_values { |rs| rs.map { |r| r["room_id"] }.uniq.sort }
        end

        # ---------- frontier hints -------------------------------------------
        # The surveyor's guess about what lies behind an unwalked exit. The
        # planner cannot compute this — it sees only the exit's name — and the
        # surveyor is already reading those exits when it revises the ledger, so
        # the annotation is free and the semantic guess sits in the component
        # that should be making semantic guesses.

        # Every field is COALESCEd, so a caller may write one of them without
        # knowing or clearing the others. `note_opaque_exit!` writes only
        # `assessability`, and the surveyor's class guess from three sessions ago
        # survives it.
        def record_frontier_hint!(room_id:, direction:, expected_class: nil, note: nil,
                                  assessability: nil, hazard: nil, egress: nil)
          @db.execute(
            "INSERT INTO frontier_hints (room_id, direction, expected_class, note, " \
            "assessability, hazard, egress, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) " \
            "ON CONFLICT(room_id, direction) DO UPDATE SET " \
            "expected_class = COALESCE(excluded.expected_class, frontier_hints.expected_class), " \
            "note = COALESCE(excluded.note, frontier_hints.note), " \
            "assessability = COALESCE(excluded.assessability, frontier_hints.assessability), " \
            "hazard = COALESCE(excluded.hazard, frontier_hints.hazard), " \
            "egress = COALESCE(excluded.egress, frontier_hints.egress), " \
            "updated_at = excluded.updated_at",
            [room_id, direction.to_s, expected_class&.to_s, note,
             assessability && Navigation::Assessment.assessability(assessability),
             Navigation::Assessment.hazard(hazard),
             # nil stays nil rather than normalising to `interior`, so that
             # "nobody has said" survives in the column and a later surveyor is
             # asked again. The DEFAULT lives in the reader, where silence and
             # `interior` become the same answer (Navigation::Egress).
             egress && Navigation::Egress.egress(egress), now]
          )
        end

        # { [room_id, direction] => { expected_class:, note:, assessability:, hazard:, egress: } }
        #
        # The whole row rather than just the class: `SurveyGraph` reads four of
        # these fields now and a hash keyed to one of them would need a second
        # query per field. Callers that want the class ask for the class.
        def frontier_hints
          @db.execute("SELECT * FROM frontier_hints").each_with_object({}) do |r, h|
            h[[r["room_id"], r["direction"]]] = {
              expected_class: r["expected_class"], note: r["note"],
              assessability: r["assessability"], hazard: r["hazard"],
              egress: r["egress"]
            }
          end
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
            encounters: scalar("SELECT COUNT(*) FROM encounters"),
            skills:     scalar("SELECT COUNT(*) FROM player_skills"),
            items:      scalar("SELECT COUNT(*) FROM player_items")
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

        # Claim rows carry one JSON column. Parsing it here rather than at every
        # read site is what lets the predicates treat `args` as a plain hash —
        # and a row whose JSON was written by a build that has since changed
        # degrades to an empty hash rather than taking the survey down with it.
        def claim_row(hash)
          r = row(hash) or return nil
          r[:args] = begin
            r[:args] ? JSON.parse(r[:args]) : {}
          rescue JSON::ParserError
            {}
          end
          r
        end

        # "C1", "C2" — per region, and never reused, so a ref that appears in a
        # journal line or an old report always means the claim it meant then.
        def next_claim_ref(region_id)
          n = @db.execute("SELECT COUNT(*) AS n FROM claims WHERE region_id IS ?", [region_id]).first["n"].to_i
          "C#{n + 1}"
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
