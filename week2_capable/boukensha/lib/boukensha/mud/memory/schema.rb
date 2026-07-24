module Boukensha
  module Mud
    module Memory
      # Versioned DDL, applied on `PRAGMA user_version`.
      #
      # Migrations are a pragma and an array, not ActiveRecord. Twenty lines, no
      # dependency, and no `schema_migrations` table to collide with — which
      # matters because mud_monitor attaches this same file read-only and its
      # `knowledge:` connection is specified with `migrations_paths: []`. Rails
      # must never migrate the agent's file; the agent is the only writer.
      #
      # To add a migration: append to MIGRATIONS. Never edit an applied one.
      module Schema
        # Three lifetimes share this file and must not share a row:
        #
        #   PERMANENT  world data that cannot change  -> rooms, room_exits
        #   VOLATILE   true only right now            -> player_state, live parse
        #   EARNED     what the agent learned         -> visit_count, entities, encounters
        #
        # `inspect_room`'s old JSON payload mixed all three, which is why hp/mana
        # /move are conspicuously absent from `rooms` below and `events` has no
        # table at all: an event is true for one instant and belongs in the state
        # block and the session log, never in a store the agent later reads as
        # fact.
        V1 = <<~SQL.freeze
          -- Permanent world data, one row per room the agent has stood in.
          CREATE TABLE rooms (
            id               INTEGER PRIMARY KEY,
            -- NOT UNIQUE, deliberately. Two genuinely different rooms may share a
            -- weak fingerprint, and identity is `id`, never the fingerprint.
            -- Making this UNIQUE is what would make the ambiguity resolver
            -- impossible to add later without a migration that rewrites every
            -- foreign key in the database. That one decision is the entire cost
            -- of keeping the door open, and it is paid here, once.
            weak_fingerprint   TEXT NOT NULL,
            strong_fingerprint TEXT,
            confidence         TEXT NOT NULL DEFAULT 'confirmed'
                                 CHECK (confidence IN ('confirmed','provisional')),
            name             TEXT NOT NULL,
            description      TEXT NOT NULL,
            look_candidates  TEXT,
            first_seen_at    TEXT NOT NULL,
            last_seen_at     TEXT NOT NULL,
            visit_count      INTEGER NOT NULL DEFAULT 1,
            surveyed_at      TEXT
          );
          CREATE INDEX idx_rooms_weak ON rooms(weak_fingerprint);
          CREATE INDEX idx_rooms_name ON rooms(name);

          -- The map. One row per (room, direction). target_room_id is NULL until
          -- the agent has actually stood in the destination — that NULL *is* the
          -- exploration frontier, and it is information the agent has never had.
          CREATE TABLE room_exits (
            room_id        INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            direction      TEXT NOT NULL,
            target_name    TEXT,
            target_room_id INTEGER REFERENCES rooms(id),
            traversals     INTEGER NOT NULL DEFAULT 0,
            last_seen_at   TEXT NOT NULL,
            PRIMARY KEY (room_id, direction)
          );
          CREATE INDEX idx_exits_frontier ON room_exits(target_room_id) WHERE target_room_id IS NULL;

          -- A mob/object TYPE, stored once for the whole world. "A cityguard
          -- stands here." is one row no matter how many rooms it patrols — which
          -- is what makes the appraisal reusable: a cityguard met in a brand-new
          -- room costs ZERO consider/examine round trips, because this row
          -- already answers both questions.
          --
          -- Honesty caveat: same description != same instance. Two cityguards are
          -- two mobs and this calls them one type. That is the right trade —
          -- instance identity is not recoverable from the MUD's text at all, and
          -- what the agent needs to know ("what is this, can it hurt me") is a
          -- property of the type. Instance-varying state stays out: `count` lives
          -- on the sighting, and current health is read live and never stored.
          CREATE TABLE entities (
            id            INTEGER PRIMARY KEY,
            kind          TEXT NOT NULL CHECK (kind IN ('mob','object')),
            descr         TEXT NOT NULL,
            keyword       TEXT,
            equipment     TEXT,
            -- consider's verdict is relative to the PLAYER'S level, so it is only
            -- meaningful alongside the level it was measured at. Re-appraise on
            -- level-up, never on revisit.
            threat        TEXT,
            threat_level  INTEGER,
            seen_count    INTEGER NOT NULL DEFAULT 1,
            first_seen_at TEXT NOT NULL,
            last_seen_at  TEXT NOT NULL,
            UNIQUE (kind, descr)
          );

          -- Where a type has been seen, and how recently. Mobs WANDER, so a
          -- room-owned entity row asserts something that was never true: the mob
          -- does not belong to the room, it was merely in it when we looked.
          CREATE TABLE entity_sightings (
            entity_id      INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            room_id        INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            count          INTEGER NOT NULL DEFAULT 1,
            sighting_count INTEGER NOT NULL DEFAULT 1,
            first_seen_at  TEXT NOT NULL,
            last_seen_at   TEXT NOT NULL,
            PRIMARY KEY (entity_id, room_id)
          );
          CREATE INDEX idx_sightings_room ON entity_sightings(room_id);

          -- Exactly one row. The CHECK is the constraint, not a convention.
          CREATE TABLE player_state (
            id              INTEGER PRIMARY KEY CHECK (id = 1),
            current_room_id INTEGER REFERENCES rooms(id),
            prev_room_id    INTEGER REFERENCES rooms(id),
            last_direction  TEXT,
            hp INTEGER, max_hp INTEGER,
            mana INTEGER, move INTEGER,
            level INTEGER, gold INTEGER, exp INTEGER,
            position        TEXT,
            -- The boukensha session that last wrote. On a NEW session,
            -- current_room_id is a hint from a previous process that may be hours
            -- stale — the character may have been moved or logged out elsewhere —
            -- so it is re-confirmed by a real look and never trusted.
            session_id      TEXT,
            updated_at      TEXT NOT NULL
          );

          -- What the system prompt's Strategy section is actually asking for:
          -- "if it fights the minotaur at level 3 and loses, it should record
          -- that, and refer to it along with its current level when deciding
          -- whether it can win."
          CREATE TABLE encounters (
            id            INTEGER PRIMARY KEY,
            room_id       INTEGER REFERENCES rooms(id),
            entity_id     INTEGER REFERENCES entities(id),
            player_level  INTEGER,
            outcome       TEXT CHECK (outcome IN ('won','fled','died','abandoned')),
            hp_before INTEGER, hp_after INTEGER,
            at            TEXT NOT NULL
          );
          CREATE INDEX idx_encounters_entity ON encounters(entity_id);
        SQL

        # The player half of the knowledgebase. The map half was rich — rooms,
        # exits, entities, encounters — while the character was four numbers on
        # one row, so a monitor could draw the world and not the adventurer in
        # it.
        #
        # Player data is not one KIND of thing, so it does not get one answer,
        # and sorting each fact into its lifetime IS the design:
        #
        #   score core   VOLATILE  extra columns on player_state  (one of each)
        #   skills       EARNED    player_skills                  (in place)
        #   items        VOLATILE  player_items                   (replaced whole)
        #
        # The sharpest edge is the last one. An item the agent dropped ten rooms
        # ago must not still appear in its knowledge, so the bag is a snapshot
        # the writer OVERWRITES in full on each reading — never an append log,
        # and never somewhere the agent reads durable belief. player_state is
        # one row because there is one player; player_items is N rows because
        # there are N items, and the overwrite semantics are identical.
        # The add/remove/use HISTORY is the journal's job, not this file's.
        V2 = <<~SQL.freeze
          -- Extend the single volatile row. Every column NULLable — "no reading
          -- yet" is a real state, and update_player!'s compact-then-merge
          -- already treats nil as "no reading this time", never "clear it".
          ALTER TABLE player_state ADD COLUMN max_mana         INTEGER; -- score gives it; the prompt does not
          ALTER TABLE player_state ADD COLUMN max_move         INTEGER;
          ALTER TABLE player_state ADD COLUMN exp_to_next      INTEGER; -- "You need N exp to reach your next level"
          ALTER TABLE player_state ADD COLUMN armor_class      TEXT;    -- "94/10" — verbatim, it is two numbers
          ALTER TABLE player_state ADD COLUMN alignment        INTEGER;
          ALTER TABLE player_state ADD COLUMN age_years        INTEGER;
          ALTER TABLE player_state ADD COLUMN title            TEXT;    -- "Derrano the Minister"
          -- Reserved, and written only the day a capture proves this build
          -- prints them. `score` does not (test/fixtures/player/score.txt), so
          -- they stay NULL. Reserving a column is free; inventing a parser for
          -- text the MUD never emits is not.
          ALTER TABLE player_state ADD COLUMN char_class       TEXT;
          ALTER TABLE player_state ADD COLUMN race             TEXT;
          ALTER TABLE player_state ADD COLUMN gold_bank        INTEGER; -- from `check(gold)` if ever issued
          ALTER TABLE player_state ADD COLUMN conditions       TEXT;    -- "hungry,thirsty" — small and joined
          ALTER TABLE player_state ADD COLUMN practices_left   INTEGER; -- practice sessions remaining
          ALTER TABLE player_state ADD COLUMN items_updated_at TEXT;    -- when the snapshot below was last replaced

          -- EARNED: what the character knows. Survives logout, updated in place.
          -- Losing a skill row because the agent walked away would be a lie of a
          -- different kind from a stale bag, so this is the opposite of
          -- player_items: upserted, never wiped.
          CREATE TABLE player_skills (
            name          TEXT PRIMARY KEY,
            -- TEXT, not INTEGER. This build grades in WORDS — "(good)",
            -- "(not learned)" — and there is no percent anywhere in the output
            -- (test/fixtures/player/practice_guild.txt). Mapping "good" onto a
            -- number would be a remembered-CircleMUD guess dressed as data, so
            -- the grade is stored as printed and `learned` — the MUD's own
            -- "(not learned)" — is the only derived field.
            proficiency   TEXT,
            learned       INTEGER NOT NULL DEFAULT 0,
            kind          TEXT,                    -- 'spell' | 'skill', from the listing header
            learned_level INTEGER,                 -- player level when first seen known
            first_seen_at TEXT NOT NULL,
            last_seen_at  TEXT NOT NULL
          );

          -- VOLATILE snapshot: what is carried / worn RIGHT NOW. Wholesale
          -- replaced on each reading — there is no history here, and there must
          -- not be. No FK to a world table: items are the character's, not a
          -- room's.
          CREATE TABLE player_items (
            id         INTEGER PRIMARY KEY,
            location   TEXT NOT NULL CHECK (location IN ('inventory','equipped')),
            worn_on    TEXT,                       -- "wielded", "worn on body" … equipped rows only
            keyword    TEXT,                       -- best-guess handle (RoomParser.guess_keywords)
            descr      TEXT NOT NULL,              -- the line as the MUD printed it
            quantity   INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL
          );
          CREATE INDEX idx_items_location ON player_items(location);
        SQL

        MIGRATIONS = [V1, V2].freeze

        LATEST_VERSION = MIGRATIONS.size

        # Apply every migration above the file's current `user_version`, each in
        # its own transaction, then stamp the new version. A file already at
        # LATEST_VERSION costs one pragma read and nothing else.
        def self.migrate!(db)
          # get_first_value, not execute().flatten: the store sets
          # results_as_hash, so a row comes back as a Hash and flattening it
          # yields the Hash rather than the number inside it.
          from = db.get_first_value("PRAGMA user_version").to_i
          return from if from >= LATEST_VERSION

          (from...LATEST_VERSION).each do |i|
            db.transaction do
              db.execute_batch(MIGRATIONS[i])
              # Pragmas do not accept bound parameters, and `i` is a loop index
              # over a frozen literal array — there is no user input on this line.
              db.execute("PRAGMA user_version = #{i + 1}")
            end
          end
          LATEST_VERSION
        end
      end
    end
  end
end
