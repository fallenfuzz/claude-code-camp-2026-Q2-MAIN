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

        V3 = <<~SQL.freeze
          CREATE TABLE player_state_v3 (
            id              INTEGER PRIMARY KEY CHECK (id = 1),
            current_room_id INTEGER REFERENCES rooms(id),
            prev_room_id    INTEGER REFERENCES rooms(id),
            last_direction  TEXT,
            hp INTEGER, max_hp INTEGER,
            mana INTEGER, move INTEGER,
            level INTEGER, gold INTEGER, exp INTEGER,
            position        TEXT,
            session_id      TEXT,
            updated_at      TEXT NOT NULL,
            max_mana         INTEGER,
            max_move         INTEGER,
            exp_to_next      INTEGER,
            armor_class      TEXT,
            alignment        INTEGER,
            age_years        INTEGER,
            title            TEXT,
            player_class     TEXT CHECK (player_class IN ('magic_user','cleric','thief','warrior')),
            gender           TEXT CHECK (gender IN ('m','f','n')),
            gold_bank        INTEGER,
            conditions       TEXT,
            practices_left   INTEGER,
            items_updated_at TEXT
          );

          INSERT INTO player_state_v3 (
            id, current_room_id, prev_room_id, last_direction,
            hp, max_hp, mana, move, level, gold, exp, position,
            session_id, updated_at, max_mana, max_move, exp_to_next,
            armor_class, alignment, age_years, title, player_class,
            gold_bank, conditions, practices_left, items_updated_at
          )
          SELECT
            id, current_room_id, prev_room_id, last_direction,
            hp, max_hp, mana, move, level, gold, exp, position,
            session_id, updated_at, max_mana, max_move, exp_to_next,
            armor_class, alignment, age_years, title,
            CASE WHEN char_class IN ('magic_user','cleric','thief','warrior') THEN char_class END,
            gold_bank, conditions, practices_left, items_updated_at
          FROM player_state;

          DROP TABLE player_state;
          ALTER TABLE player_state_v3 RENAME TO player_state;
        SQL

        # frontier_attempts records what plan_route.md §6.3 calls the missing
        # memory: which unexplored exits have already been tried and failed
        # ("Alas, you cannot go that way."), so repeated route planning fans
        # outward instead of retrying the same blocked door. Successes are
        # recorded too (outcome: 'succeeded') so a direction's full history is
        # in one table, even though only failures currently feed ranking.
        V4 = <<~SQL.freeze
          CREATE TABLE frontier_attempts (
            room_id      INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            direction    TEXT NOT NULL,
            outcome      TEXT NOT NULL CHECK (outcome IN ('failed','succeeded')),
            attempted_at TEXT NOT NULL
          );
          CREATE INDEX idx_frontier_attempts_room ON frontier_attempts(room_id, direction);
        SQL

        # Regions — boundaries_revised.md §6. Three tables and two columns, and
        # the split between them is the same EARNED/DERIVED line the rest of
        # this file draws: the agent's declarations are kept forever and never
        # overwritten, while membership is rewritten wholesale on every
        # recompute, because a stale membership is a lie rather than a history.
        #
        # The two columns on `rooms` are what §6's SQL does not spell out and
        # cannot work without. Inheritance is defined as "a room takes the
        # region of the room it was first entered from", so the first-arrival
        # edge has to be recorded for EVERY room, not just for the ones a
        # boundary was declared at. Written once, at discovery, and never
        # updated — a room's first arrival is a fact about the past, and a
        # later visit by another route does not revise it.
        V5 = <<~SQL.freeze
          ALTER TABLE rooms ADD COLUMN arrived_from_room_id INTEGER REFERENCES rooms(id);
          ALTER TABLE rooms ADD COLUMN arrived_direction    TEXT;

          -- Backfill for a map explored before this migration existed. There is
          -- no record of the order rooms were actually walked in, but `rooms.id`
          -- IS discovery order (autoincrement, one INSERT per first arrival), so
          -- the lowest-numbered room with a linked exit into this one is the
          -- best available reconstruction of the room it was first entered from.
          --
          -- Getting an individual edge wrong here costs nothing that a later
          -- declaration cannot fix. Leaving the column NULL instead would cost a
          -- great deal: every room would be a root, and a 66-room town would
          -- shatter into 66 provisional regions on the first recompute.
          UPDATE rooms SET arrived_from_room_id = (
            SELECT MIN(e.room_id) FROM room_exits e
            WHERE e.target_room_id = rooms.id AND e.room_id < rooms.id
          );
          UPDATE rooms SET arrived_direction = (
            SELECT e.direction FROM room_exits e
            WHERE e.target_room_id = rooms.id AND e.room_id = rooms.arrived_from_room_id
            ORDER BY e.direction LIMIT 1
          ) WHERE arrived_from_room_id IS NOT NULL;

          -- EARNED: the places the agent named, in its own words. A row with
          -- confirmed = 0 and a bracketed label is machine-made provenance
          -- ("⟨from The Temple Of Midgaard⟩"), never a claim about the world —
          -- nothing anywhere derives "Midgaard" from "The Temple Of Midgaard",
          -- because parsing a place name out of a room name is a lexicon.
          CREATE TABLE regions (
            id            INTEGER PRIMARY KEY,
            label         TEXT NOT NULL UNIQUE,
            confirmed     BOOLEAN NOT NULL DEFAULT 0,
            description   TEXT,
            parent_id     INTEGER REFERENCES regions(id),
            seed_room_id  INTEGER REFERENCES rooms(id),
            first_seen_at TEXT NOT NULL,
            updated_at    TEXT NOT NULL
          );

          -- EARNED: one row per split. The edge IS the boundary, exactly — the
          -- edge the agent walked in on, not a midpoint interpolated between two
          -- claims — which is what makes a crossing cost one tool call and
          -- leaves no session where the line sits silently in the wrong place.
          CREATE TABLE region_boundaries (
            id           INTEGER PRIMARY KEY,
            from_room_id INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            to_room_id   INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            direction    TEXT NOT NULL,
            region_id    INTEGER NOT NULL REFERENCES regions(id) ON DELETE CASCADE,
            reason       TEXT,
            declared_at  TEXT NOT NULL,
            session_id   TEXT
          );
          CREATE INDEX idx_boundaries_to ON region_boundaries(to_room_id);

          -- DERIVED: rewritten wholesale on recompute, the same overwrite
          -- semantics as player_items. No null case — every walked room is a
          -- member of something, from the first turn.
          CREATE TABLE room_regions (
            room_id     INTEGER PRIMARY KEY REFERENCES rooms(id) ON DELETE CASCADE,
            region_id   INTEGER NOT NULL REFERENCES regions(id) ON DELETE CASCADE,
            basis       TEXT NOT NULL,
            computed_at TEXT NOT NULL
          );
          CREATE INDEX idx_room_regions_region ON room_regions(region_id);
        SQL

        # Exit name resolution — docs/plans/week_3/exit_name_resolution.md.
        #
        # The MUD's `exits` output prints "direction - Destination" per line and
        # `room_parser.rb` has parsed it into `room_exits.target_name` since week
        # 2, but nothing ever compared that name against the rooms already in
        # memory. In the recorded Midgaard map five of fifteen unlinked exits
        # name rooms the agent has stood in, so a third of what the planner calls
        # frontier is phantom — and the run that ended in The Dump could not plan
        # a route out of the room it finished in, because the only way back was
        # an exit the MUD had named and the graph did not hold.
        #
        # The presumption goes in its OWN column rather than into
        # `target_room_id`. V1 documents that NULL as being the exploration
        # frontier itself and `state_block.rb` renders `✓`/`?` off it, so writing
        # a name match there would make a guess indistinguishable from a walked
        # traversal in both the frontier calculation and the model's view of the
        # world. An earned target always supersedes a presumed one.
        #
        # This is NOT reverse-edge inference, which week 2 rejected on the
        # grounds that MUD exits may be one-way, gated, or non-Euclidean. Nothing
        # here asserts symmetry: an exit the MUD does not list is never created,
        # a one-way passage stays one-way because no return exit exists to
        # resolve, and room 1's `down` to The Temple Square — an edge no walked
        # traversal implies — is recovered precisely because the game said so.
        V6 = <<~SQL.freeze
          ALTER TABLE room_exits ADD COLUMN presumed_target_id INTEGER REFERENCES rooms(id);
          CREATE INDEX idx_exits_presumed ON room_exits(presumed_target_id) WHERE presumed_target_id IS NOT NULL;

          -- Guard three: names that have proven ambiguous ANYWHERE are never
          -- resolved again, even where only one candidate room is currently
          -- known. Generic MUD room names recur heavily across a world, and a
          -- name that identified two rooms once is not an identifier.
          --
          -- Rows arrive two ways: a name observed on two or more distinct rooms,
          -- and a presumption that walking proved wrong. The second is what
          -- makes a bad guess cost one move and then never repeat.
          CREATE TABLE exit_name_ambiguity (
            name     TEXT PRIMARY KEY,   -- DestinationSearch.normalize'd
            reason   TEXT NOT NULL,
            noted_at TEXT NOT NULL
          );
        SQL

        # The claim ledger — docs/plans/week_3/movement_revisited/claims.md.
        #
        # A survey used to be modelled as coverage: walk enough rooms, then ask a
        # reasoner whether that felt like enough. A count of fourteen rooms
        # carries no information about whether the player's question was
        # answered, which is why that design had to negotiate completion between
        # an arbitrary floor and an unfalsifiable judgement call. A claim states
        # what would settle it, so frontier selection and termination both follow
        # from one structure.
        #
        # These tables exist rather than call-local counters for one reason:
        # `docs/architecture/move_to.md` lists everything a `move_to` call knows
        # about its own exploration under "Local to one move_to call", and none
        # of it survives the call boundary. A record of fourteen rooms walked
        # means nothing at the start of the next session; a `circuit_closes`
        # claim standing at three sides confirmed and one side unexplored tells
        # the next survey exactly where to resume.
        V7 = <<~SQL.freeze
          -- The ledger, keyed by region so a survey of Midgaard resumes from
          -- what the last survey of Midgaard established. `predicate` is drawn
          -- from a closed vocabulary the planner knows how to run; a claim whose
          -- statement cannot be expressed as one is rejected before it gets a
          -- row here, which is what keeps "gather evidence" from being a vague
          -- instruction.
          CREATE TABLE claims (
            id             INTEGER PRIMARY KEY,
            region_id      INTEGER REFERENCES regions(id) ON DELETE CASCADE,
            -- The handle the surveyor addresses a claim by, stable within a
            -- region ("C1"). Surrogate `id` is identity; this is what appears in
            -- a payload small enough for a reasoner to reference reliably.
            ref            TEXT NOT NULL,
            statement      TEXT NOT NULL,
            predicate      TEXT NOT NULL,
            -- What the predicate is about: "feature:wall_road", "class:lodging",
            -- "Midgaard". Together with `predicate` it is the merge key, so a
            -- re-proposed claim accumulates evidence in one place instead of
            -- forking the ledger.
            subject        TEXT,
            status         TEXT NOT NULL DEFAULT 'open'
                             CHECK (status IN ('open','parked','confirmed','refuted','unresolved')),
            confidence     REAL NOT NULL DEFAULT 0.5,
            priority       REAL NOT NULL DEFAULT 0.5,
            answers        TEXT,
            decisive_when  TEXT,
            -- Predicate arguments as JSON: the class list a `composition` is
            -- looking for and the ones it has seen, the `n` of a
            -- `count_at_least`, the ceiling of an `extent_bounded`. Class labels
            -- live HERE and not on rooms, deliberately — the vocabulary arrives
            -- with the objective, so a survey asking what a town offers seeds
            -- different classes from one asking whether it is defensible, and a
            -- global room ontology would have to be the union of every question
            -- anyone might ask.
            args           TEXT,
            room_budget    INTEGER,
            rooms_spent    INTEGER NOT NULL DEFAULT 0,
            settled_reason TEXT,
            objective      TEXT,
            created_at     TEXT NOT NULL,
            updated_at     TEXT NOT NULL,
            UNIQUE (region_id, ref)
          );
          CREATE INDEX idx_claims_region ON claims(region_id, status);

          -- One row per observation. `polarity` is explicit so the ledger can
          -- accumulate DISCONFIRMATION rather than only support — establishing
          -- that Midgaard has no second bridge is a finding, and a schema that
          -- could only record agreement could not hold it. The room reference is
          -- what keeps evidence attached to the graph, so a claim can be
          -- re-evaluated if the room graph is later corrected.
          CREATE TABLE claim_evidence (
            id          INTEGER PRIMARY KEY,
            claim_id    INTEGER NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
            room_id     INTEGER REFERENCES rooms(id) ON DELETE SET NULL,
            polarity    TEXT NOT NULL CHECK (polarity IN ('support','contradict','neutral')),
            note        TEXT,
            observed_at TEXT NOT NULL
          );
          CREATE INDEX idx_claim_evidence_claim ON claim_evidence(claim_id);

          -- The one durable per-room tag the claim model requires, and the
          -- reason it is a join table rather than a column: `circuit_closes`,
          -- `connects` and `bounds` all depend on deciding that several
          -- separately observed rooms belong to ONE road or ONE wall, which is
          -- entity resolution over rooms and not a property of any single room.
          CREATE TABLE features (
            id            INTEGER PRIMARY KEY,
            region_id     INTEGER REFERENCES regions(id) ON DELETE CASCADE,
            slug          TEXT NOT NULL,          -- "wall_road", as named in claims.subject
            label         TEXT,
            first_seen_at TEXT NOT NULL,
            updated_at    TEXT NOT NULL,
            UNIQUE (region_id, slug)
          );

          CREATE TABLE feature_rooms (
            feature_id  INTEGER NOT NULL REFERENCES features(id) ON DELETE CASCADE,
            room_id     INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            note        TEXT,
            observed_at TEXT NOT NULL,
            PRIMARY KEY (feature_id, room_id)
          );
          CREATE INDEX idx_feature_rooms_room ON feature_rooms(room_id);

          -- What the planner genuinely cannot compute: a guess about the room
          -- behind an unwalked exit, since it sees only the exit's target name.
          -- Rather than a deterministic classifier for that, the surveyor
          -- annotates open frontiers while it is revising the ledger — it is
          -- already reading those exits, so the annotation is free, and it puts
          -- the semantic guess in the component that should be making semantic
          -- guesses.
          CREATE TABLE frontier_hints (
            room_id        INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            direction      TEXT NOT NULL,
            expected_class TEXT,
            note           TEXT,
            updated_at     TEXT NOT NULL,
            PRIMARY KEY (room_id, direction)
          );
        SQL

        # An exit that has been WALKED and whose destination could not be
        # identified even after a follow-up `look`. The character is somewhere;
        # nothing here can say where, and no amount of walking it again changes
        # that until whatever prevented the reading changes — an unlit room, a
        # blindness effect, a fog, output this parser has never seen.
        #
        # It is recorded against the EXIT rather than against the room behind
        # it because there is no row for the room behind it, and that absence is
        # the whole condition being recorded. The column exists so the frontier
        # calculation can stop offering the exit: an unexplored exit promises
        # information in return for a move, and this one has already been walked
        # and demonstrably paid nothing. Session 20260730T201603Z-ff25f010 is
        # what its absence costs — the surveyor picked the same trapdoor it had
        # just fallen through, because nothing recorded that it had.
        #
        # Deliberately NOT called `dark`. What the subsystem observed is that
        # the destination could not be read, and darkness is only the most
        # common reason for that; naming the column after one cause would invite
        # every later reader to test for that cause specifically.
        V8 = <<~SQL.freeze
          ALTER TABLE room_exits ADD COLUMN opaque INTEGER NOT NULL DEFAULT 0;
        SQL

        # Two questions about the far side of an unwalked exit that the surveyor
        # can answer and no deterministic scorer can: whether anything about the
        # destination can be weighed before entering it, and whether there is
        # reason to expect trouble there. See blind_step_recovery.md §5.1 and
        # Navigation::Assessment for the vocabulary.
        #
        # They join `frontier_hints` rather than `room_exits` because they are a
        # judgement about an exit, of exactly the kind `expected_class` already is,
        # and because a table whose whole purpose is "what the surveyor thinks is
        # behind this door" is where the next such question will want to go too.
        #
        # Both are nullable and a NULL `assessability` reads as `unknown`, which
        # DEFERS rather than permits. Run 20260731T151434Z-737a23cb is what the
        # other default costs: the surveyor wrote "low priority for surface
        # mapping" against a well, nothing read it, the survey dropped into the
        # sewers and the session ended having walked four rooms.
        V9 = <<~SQL.freeze
          ALTER TABLE frontier_hints ADD COLUMN assessability TEXT;
          ALTER TABLE frontier_hints ADD COLUMN hazard        TEXT;
        SQL

        # The fourth question about an unwalked exit, and the first distinction
        # between two kinds of boundary — docs/plans/week_3/movement_revisited/
        # staying_in_town.md §10.1 and §10.4.
        #
        # `frontier_hints.egress` is `interior`, `boundary` or `leaves`, and NULL
        # reads as `interior` (Navigation::Egress). The other default would make
        # this a new global rule rather than an opt-in one: a map with no hints at
        # all is every map before a surveyor has run on it, and it must walk
        # exactly as it walked yesterday.
        #
        # `region_boundaries.kind` separates two things that were one row.
        # Everything declared before today is a `split` — an internal division of
        # one place into quarters — and the default keeps it that way. An `egress`
        # row means the edge LEAVES the place, and it is deliberately not a
        # region declaration: `Regions.derive` treats a boundary's `to_room_id`
        # as a root that starts a region there, which is exactly what an egress
        # crossing must not do. `Store#recompute_regions!` therefore hands the
        # derivation the `split` rows only.
        #
        # The reason this is an edge rather than a comparison of region labels is
        # §8 of that document, argued on the run's own data: `The Plains` came out
        # a descendant of `The Temple`, its parent moved between two splits twelve
        # iterations apart, the one region actually called `Midgaard` held no
        # rooms, and five of the countryside rooms shared a region with the temple
        # interior. A region's parent records which region it was carved out of,
        # not which place contains it, so containment cannot be read back off the
        # tree. A crossing is an edge, and edges are recorded exactly.
        V10 = <<~SQL.freeze
          ALTER TABLE frontier_hints ADD COLUMN egress TEXT;
          ALTER TABLE region_boundaries ADD COLUMN kind TEXT NOT NULL DEFAULT 'split';
        SQL

        MIGRATIONS = [V1, V2, V3, V4, V5, V6, V7, V8, V9, V10].freeze

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
