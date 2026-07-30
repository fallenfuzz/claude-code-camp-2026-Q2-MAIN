require "json"
require "sqlite3"
require "time"

module Knowledge
  # Read-only view onto the agent's world memory
  # (`week2_capable/boukensha/lib/boukensha/mud/memory/`).
  #
  # Deliberately NOT ActiveRecord. `room_exits` and `entity_sightings` have
  # composite primary keys and no `id`; the file has no `schema_migrations`
  # table (memory/schema.rb migrates on `PRAGMA user_version` precisely to avoid
  # one); and every connection listed in database.yml gets walked by `db:prepare`
  # / `db:test:prepare`, which must never happen to the agent's file. So this is
  # a PORO that speaks SQL, exactly like SessionLog/TelnetLog/ManagerLog are
  # POROs that speak jsonl. Rails owns storage/development.sqlite3 and nothing
  # else.
  #
  # Unlike those three, this is not a log: there is no cursor, no `seq`, and
  # nothing to tail. It is a snapshot of belief that changes underneath the
  # reader, which is why the controller polls rather than streams.
  class Reader
    # The `user_version` this reader was written against. A NEWER file is served
    # anyway — memory/schema.rb migrations are additive by construction ("append
    # to MIGRATIONS, never edit an applied one") — but the number is reported so
    # a surprise is visible rather than silent.
    KNOWN_SCHEMA_VERSION = 7

    # V2 added the player half — the score sheet's other two thirds, plus
    # `player_skills` and `player_items`. Additive DDL means a NEWER file is
    # served without changes here, but an OLDER one is the real problem: a
    # NAMED select of a column that does not exist raises, and named columns are
    # the whole drift-detection mechanism, so they cannot simply be dropped. So
    # every V2 read is gated on the version the file itself reports, and one
    # monitor serves both an old and a new agent.
    PLAYER_HALF_VERSION = 2

    # V5 added regions. Gated the same way and for the same reason as the
    # player half: an older file has no `regions` table at all, and a named
    # SELECT against a missing table raises. One monitor serves an agent that
    # has never declared a region and one that has.
    REGIONS_VERSION = 5

    # V6 added presumed exit targets — an exit whose MUD-reported name was
    # matched to a room already in memory. V7 added the claim ledger. Both are
    # gated the same way as the two above and for the same reason: a named
    # SELECT against a table that does not exist raises, and named columns are
    # the whole drift-detection mechanism, so one monitor has to serve an agent
    # that has never surveyed anything and one that has.
    PRESUMED_VERSION = 6
    SURVEY_VERSION   = 7

    # A SELECT that the file's schema can't answer. Carries the version so the
    # UI can say *which* schema it choked on.
    class SchemaMismatch < StandardError
      attr_reader :schema_version

      def initialize(message, schema_version)
        super(message)
        @schema_version = schema_version
      end
    end

    attr_reader :path

    # Opens for the duration of the block and always closes. A connection per
    # request is the point: opening SQLite costs microseconds, Puma is
    # multi-threaded, and SQLite3::Database is not thread-safe — so there is no
    # memoized connection and no pool.
    def self.open(path:, live_window: 10, session: nil)
      reader = new(path: path, live_window: live_window, session: session)
      begin
        yield reader
      ensure
        reader.close
      end
    end

    # `session:` names the session whose RETAINED map this reader is serving,
    # and is nil for the profile's live file. Nothing about the reading changes
    # — a retained map is the same schema read the same way — but every payload
    # says which one it is, because a page that looks exactly like the live map
    # while showing a two-day-old one is worse than no page.
    def initialize(path:, live_window: 10, session: nil)
      @path        = Pathname.new(path)
      @live_window = live_window
      @session     = session
    end

    attr_reader :session

    def retained? = !@session.nil?

    # Absence is a state, not an error — same rule as "no telnet log for today".
    # The agent writes this file the first time it looks at a room.
    def attached? = @path.file?

    def close
      @db&.close
      @db = nil
    end

    # Everything the client needs to render freshness, on every payload, so no
    # view needs a second call to know whether it is looking at live data.
    def envelope
      {
        attached: attached?,
        live: live?,
        last_write_at: last_write_at&.utc&.iso8601,
        schema_version: schema_version,
        wal_bytes: wal_bytes,
        session: @session
      }
    end

    # Under WAL, commits land in `-wal` and the main file's mtime only moves on
    # checkpoint — which may be minutes apart, or never within a session. A
    # freshness check that watches only `knowledge.sqlite3` reports "stale" while
    # the agent is actively exploring. Watch both, take the newer.
    def last_write_at
      [ @path, wal_path ].filter_map { |p| p.mtime if p.exist? }.max
    end

    # A retained map is never live whatever its mtime says: the file was written
    # minutes ago by the case runner, but the world it describes stopped moving
    # when that session ended.
    def live?
      return false if retained?

      at = last_write_at
      !at.nil? && (Time.now - at) <= @live_window
    end

    def wal_bytes
      wal_path.exist? ? wal_path.size : nil
    end

    def schema_version
      return nil unless attached?

      db.get_first_value("PRAGMA user_version").to_i
    rescue SQLite3::Exception
      nil
    end

    # ---------- overview ------------------------------------------------

    # One statement, not nine. Keeps the shape of Store#stats (memory/store.rb)
    # so a future divergence between what the writer counts and what the reader
    # counts is something a person can see side by side.
    def stats
      return EMPTY_STATS unless attached?

      row = query_one(<<~SQL) || {}
        SELECT
          (SELECT COUNT(*) FROM rooms)                                       AS rooms,
          (SELECT COUNT(*) FROM rooms WHERE surveyed_at IS NOT NULL)         AS surveyed,
          (SELECT COUNT(*) FROM rooms WHERE confidence = 'provisional')      AS provisional,
          (SELECT COUNT(*) FROM entities)                                    AS entities,
          (SELECT COUNT(*) FROM entities WHERE kind = 'mob')                 AS mobs,
          (SELECT COUNT(*) FROM entities WHERE kind = 'object')              AS objects,
          (SELECT COUNT(*) FROM room_exits)                                  AS exits,
          (SELECT COUNT(*) FROM room_exits WHERE target_room_id IS NULL)     AS frontier,
          (SELECT COUNT(*) FROM room_exits WHERE traversals > 0)             AS traversed,
          (SELECT COUNT(*) FROM encounters)                                  AS encounters
      SQL

      # The player half is a SECOND statement rather than two more subselects,
      # because a V1 file has neither table and the whole statement would raise.
      # Keeps Store#stats' shape either way — a divergence between what the
      # writer counts and what the reader counts stays visible side by side.
      row = row.merge(query_one(<<~SQL) || {}) if player_half?
        SELECT (SELECT COUNT(*) FROM player_skills) AS skills,
               (SELECT COUNT(*) FROM player_items)  AS items
      SQL

      # A third and fourth statement, gated the same way and for the same
      # reason: a pre-V6 file has neither table, and one missing table takes the
      # whole statement — and therefore the whole Overview — with it.
      row = row.merge(query_one(<<~SQL) || {}) if presumed?
        SELECT (SELECT COUNT(*) FROM room_exits WHERE presumed_target_id IS NOT NULL
                  AND target_room_id IS NULL)                                  AS presumed
      SQL
      row = row.merge(query_one(<<~SQL) || {}) if survey?
        SELECT (SELECT COUNT(*) FROM claims)                                   AS claims,
               (SELECT COUNT(*) FROM claims WHERE status IN ('open','parked')) AS claims_open,
               (SELECT COUNT(*) FROM features)                                 AS features
      SQL

      # `frontier` above counts every unlinked exit including the presumed ones,
      # which is not what the tab shows. Subtract here so the tile and the table
      # under it can never disagree.
      stats = EMPTY_STATS.merge(row.transform_keys(&:to_sym).transform_values(&:to_i))
      stats.merge(frontier: stats[:frontier] - stats[:presumed])
    end

    EMPTY_STATS = {
      rooms: 0, surveyed: 0, provisional: 0, entities: 0, mobs: 0, objects: 0,
      exits: 0, frontier: 0, traversed: 0, encounters: 0, skills: 0, items: 0,
      presumed: 0, claims: 0, claims_open: 0, features: 0
    }.freeze

    # ---------- the player ----------------------------------------------

    PLAYER_V1_COLUMNS = "ps.current_room_id, ps.prev_room_id, ps.last_direction, " \
                        "ps.hp, ps.max_hp, ps.mana, ps.move, ps.level, ps.gold, ps.exp, " \
                        "ps.position, ps.session_id, ps.updated_at".freeze
    PLAYER_V2_COLUMNS = "ps.max_mana, ps.max_move, ps.exp_to_next, ps.armor_class, ps.alignment, " \
                        "ps.age_years, ps.title, ps.char_class AS player_class, ps.gold_bank, " \
                        "ps.conditions, ps.practices_left, ps.items_updated_at".freeze
    PLAYER_V3_COLUMNS = "ps.max_mana, ps.max_move, ps.exp_to_next, ps.armor_class, ps.alignment, " \
                        "ps.age_years, ps.title, ps.player_class, ps.gender, ps.gold_bank, " \
                        "ps.conditions, ps.practices_left, ps.items_updated_at".freeze

    SKILL_COLUMNS = "name, proficiency, learned, kind, learned_level, first_seen_at, last_seen_at".freeze
    ITEM_COLUMNS  = "id, location, worn_on, keyword, descr, quantity, updated_at".freeze

    # nil until the agent has looked at something — `player_state` is a single
    # row that does not exist in a fresh file. Against a V1 file the score
    # sheet's new fields come back nil, which is the same thing they say on a V2
    # file the agent has not read `score` on yet: "no reading".
    def player
      return nil unless attached?

      extra_cols =
        case schema_version
        when 3.. then PLAYER_V3_COLUMNS
        when 2 then PLAYER_V2_COLUMNS
        end
      cols = extra_cols ? "#{PLAYER_V1_COLUMNS}, #{extra_cols}" : PLAYER_V1_COLUMNS
      row  = query_one(<<~SQL)
        SELECT #{cols},
               cr.name AS current_room_name, pr.name AS prev_room_name
          FROM player_state ps
          LEFT JOIN rooms cr ON cr.id = ps.current_room_id
          LEFT JOIN rooms pr ON pr.id = ps.prev_room_id
         WHERE ps.id = 1
      SQL
      return nil unless row

      {
        hp: row["hp"], max_hp: row["max_hp"],
        mana: row["mana"], move: row["move"],
        # The denominators live only in `score` (the prompt line carries the
        # currents and throws these away), so they are frequently nil even on a
        # V2 file — a bar without one must render as a bare number, not as 0%.
        max_mana: row["max_mana"], max_move: row["max_move"],
        level: row["level"], gold: row["gold"], exp: row["exp"],
        exp_to_next: row["exp_to_next"], gold_bank: row["gold_bank"],
        position: row["position"],
        last_direction: row["last_direction"],
        title: row["title"],
        player_class: row["player_class"], gender: row["gender"],
        armor_class: row["armor_class"], alignment: row["alignment"],
        age_years: row["age_years"], practices_left: row["practices_left"],
        # Stored joined because it is short and low-cardinality; split here so
        # the UI renders chips without re-parsing a column format.
        conditions: row["conditions"].to_s.split(",").map(&:strip).reject(&:empty?),
        # When the item snapshot below was last REPLACED — deliberately not the
        # same clock as updated_at. A bag the agent has not looked in since it
        # dropped something says so, and the UI shows the age instead of
        # implying the list is current.
        items_updated_at: row["items_updated_at"],
        # The boukensha run that last wrote — what lets the overview link belief
        # back to the transcript that produced it.
        session_id: row["session_id"],
        updated_at: row["updated_at"],
        current_room: room_ref(row["current_room_id"], row["current_room_name"]),
        prev_room: room_ref(row["prev_room_id"], row["prev_room_name"])
      }
    end

    # EARNED: what the character knows. Empty on a V1 file, which is the same
    # answer as "the agent has never run `practice`" — both are honestly "we
    # have no skill readings", and neither is an error.
    def player_skills
      return [] unless attached? && player_half?

      query("SELECT #{SKILL_COLUMNS} FROM player_skills ORDER BY name").map do |row|
        {
          name: row["name"],
          # A WORD — "good", "not learned" — because that is what this MUD
          # prints. There is no percent anywhere in the output, so there is no
          # percent here, and NULL means the listing carried no grade rather
          # than that the character has no ability.
          proficiency: row["proficiency"],
          learned: row["learned"].to_i == 1,
          kind: row["kind"],
          learned_level: row["learned_level"],
          first_seen_at: row["first_seen_at"],
          last_seen_at: row["last_seen_at"]
        }
      end
    end

    # VOLATILE: the bag and the paperdoll as of the last reading. Not a history
    # — the writer replaces this wholesale — so there is nothing to page through
    # and no `since` cursor to offer.
    def player_items(location: nil)
      return [] unless attached? && player_half?

      sql    = +"SELECT #{ITEM_COLUMNS} FROM player_items"
      params = []
      if %w[inventory equipped].include?(location.to_s)
        sql << " WHERE location = ?"
        params << location.to_s
      end
      sql << " ORDER BY location, id"

      query(sql, params).map do |row|
        {
          id: row["id"],
          location: row["location"],
          worn_on: row["worn_on"],
          keyword: row["keyword"],
          descr: row["descr"],
          quantity: row["quantity"],
          updated_at: row["updated_at"]
        }
      end
    end

    # ---------- rooms ---------------------------------------------------

    # Columns are named, never `SELECT *`. This is the whole drift-detection
    # mechanism: against `*`, a column the agent renames or drops comes back as
    # a silent nil and the UI quietly shows blanks forever. Named columns turn
    # that into one SQLException, which `query` converts into a
    # `knowledge_schema_mismatch` banner naming the version it choked on.
    ROOM_COLUMNS   = "id, weak_fingerprint, strong_fingerprint, confidence, name, description, " \
                     "look_candidates, first_seen_at, last_seen_at, visit_count, surveyed_at".freeze
    EXIT_COLUMNS   = "room_id, direction, target_name, target_room_id, traversals, last_seen_at".freeze
    ENTITY_COLUMNS = "e.id, e.kind, e.descr, e.keyword, e.equipment, e.threat, e.threat_level, " \
                     "e.seen_count, e.first_seen_at, e.last_seen_at".freeze

    FILTERS = {
      "surveyed"    => "surveyed_at IS NOT NULL",
      "unsurveyed"  => "surveyed_at IS NULL",
      "provisional" => "confidence = 'provisional'"
    }.freeze

    # Three statements regardless of room count. Twelve rooms makes an N+1
    # invisible; a thousand makes it the difference between a page and a
    # timeout, and grouping in Ruby costs nothing today.
    def rooms(q: nil, filter: nil, limit: 200)
      return [] unless attached?

      where  = []
      params = []

      if q.to_s.strip != ""
        where << "(name LIKE ? OR description LIKE ?)"
        like = "%#{q.to_s.strip}%"
        params.push(like, like)
      end
      where << FILTERS.fetch(filter) if FILTERS.key?(filter)

      sql = +"SELECT #{ROOM_COLUMNS} FROM rooms"
      sql << " WHERE #{where.join(' AND ')}" unless where.empty?
      sql << " ORDER BY id LIMIT ?"
      params << limit

      rows = query(sql, params)
      ids  = rows.map { |r| r["id"] }

      exits  = exits_for(ids)
      entities = entity_summaries_for(ids)
      # One statement for the whole page, like exits and entities above — the
      # map tints every cell it draws, so this cannot be a lookup per room.
      regions = region_of_room

      rows.map do |row|
        room_entities = entities.fetch(row["id"], [])
        room_payload(row).merge(
          exits: exits.fetch(row["id"], []),
          entity_count: room_entities.length,
          entities: room_entities,
          region_id: regions[row["id"]]
        )
      end
    end

    def room(id)
      return nil unless attached?

      row = query_one("SELECT #{ROOM_COLUMNS} FROM rooms WHERE id = ?", [ id ])
      return nil unless row

      room_entities = entity_summaries_for([ id ]).fetch(id, [])
      room_payload(row).merge(
        exits: exits_for([ id ]).fetch(id, []),
        entity_count: room_entities.length,
        entities: room_entities,
        region_id: region_of_room[id]
      )
    end

    # Who points *at* this room — the one thing the room's own row cannot say,
    # and the answer to "how did I get here".
    def inbound(room_id)
      return [] unless attached?

      sql = <<~SQL
        SELECT e.room_id, e.direction, r.name AS room_name
          FROM room_exits e
          JOIN rooms r ON r.id = e.room_id
         WHERE e.target_room_id = ?
         ORDER BY r.id, e.direction
      SQL

      query(sql, [ room_id ]).map do |row|
        { room_id: row["room_id"], room_name: row["room_name"], direction: row["direction"] }
      end
    end

    # ---------- entities ------------------------------------------------

    def entities(kind: nil, q: nil, room_id: nil)
      return [] unless attached?

      where  = []
      params = []

      if %w[mob object].include?(kind)
        where << "e.kind = ?"
        params << kind
      end
      if q.to_s.strip != ""
        where << "(e.descr LIKE ? OR e.keyword LIKE ?)"
        like = "%#{q.to_s.strip}%"
        params.push(like, like)
      end
      if room_id
        where << "EXISTS (SELECT 1 FROM entity_sightings s WHERE s.entity_id = e.id AND s.room_id = ?)"
        params << room_id
      end

      sql = +"SELECT #{ENTITY_COLUMNS} FROM entities e"
      sql << " WHERE #{where.join(' AND ')}" unless where.empty?
      # The things the agent keeps running into are the things worth looking at.
      sql << " ORDER BY e.seen_count DESC, e.id"

      rows = query(sql, params)
      ids  = rows.map { |r| r["id"] }
      seen = sightings_for(ids)

      rows.map { |row| entity_payload(row).merge(sightings: seen.fetch(row["id"], [])) }
    end

    # Entities sighted in one room, with that room's sighting counters rather
    # than the world-wide ones.
    def entities_in_room(room_id)
      return [] unless attached?

      sql = <<~SQL
        SELECT #{ENTITY_COLUMNS}, s.count AS here_count, s.sighting_count AS here_sighting_count,
               s.first_seen_at AS here_first_seen_at, s.last_seen_at AS here_last_seen_at
          FROM entity_sightings s
          JOIN entities e ON e.id = s.entity_id
         WHERE s.room_id = ?
         ORDER BY e.kind, e.id
      SQL

      query(sql, [ room_id ]).map do |row|
        entity_payload(row).merge(
          count: row["here_count"],
          sighting_count: row["here_sighting_count"],
          first_seen_at: row["here_first_seen_at"],
          last_seen_at: row["here_last_seen_at"]
        )
      end
    end

    def encounters(room_id: nil, entity_id: nil)
      return [] unless attached?

      where  = []
      params = []
      if room_id
        where << "c.room_id = ?"
        params << room_id
      end
      if entity_id
        where << "c.entity_id = ?"
        params << entity_id
      end

      sql = +<<~SQL
        SELECT c.id, c.room_id, c.entity_id, c.player_level, c.outcome,
               c.hp_before, c.hp_after, c.at,
               e.descr AS entity_descr, r.name AS room_name
          FROM encounters c
          LEFT JOIN entities e ON e.id = c.entity_id
          LEFT JOIN rooms r ON r.id = c.room_id
      SQL
      sql << " WHERE #{where.join(' AND ')}" unless where.empty?
      sql << " ORDER BY c.at DESC, c.id DESC"

      query(sql, params).map do |row|
        {
          id: row["id"],
          room_id: row["room_id"], room_name: row["room_name"],
          entity_id: row["entity_id"], entity_descr: row["entity_descr"],
          player_level: row["player_level"],
          outcome: row["outcome"],
          hp_before: row["hp_before"], hp_after: row["hp_after"],
          at: row["at"]
        }
      end
    end

    # ---------- frontier ------------------------------------------------

    # The query `idx_exits_frontier` exists to serve, and the single most useful
    # number on the tab: exits the agent has seen named but never walked.
    #
    # An exit carrying a PRESUMED target is excluded, because something already
    # knows what is behind it and counting it here would overstate how much of
    # the world is left. Those are listed separately by `presumed_exits`, on the
    # same tab, so the difference is visible rather than merely applied.
    def frontier
      return [] unless attached?

      presumed_clause = presumed? ? "AND e.presumed_target_id IS NULL" : ""
      sql = <<~SQL
        SELECT e.room_id, e.direction, e.target_name, e.last_seen_at,
               r.name AS room_name, r.surveyed_at
          FROM room_exits e
          JOIN rooms r ON r.id = e.room_id
         WHERE e.target_room_id IS NULL #{presumed_clause}
         ORDER BY r.id, e.direction
      SQL

      query(sql).map do |row|
        {
          room_id: row["room_id"],
          room_name: row["room_name"],
          direction: row["direction"],
          target_name: row["target_name"],
          last_seen_at: row["last_seen_at"],
          room_surveyed: !row["surveyed_at"].nil?
        }
      end
    end

    # ---------- regions -------------------------------------------------

    # The places the agent named, the edges it declared them at, and which
    # rooms ended up in each — boundaries_revised.md §7.
    #
    # Boundaries and memberships are served TOGETHER and kept distinct on
    # purpose. A tinted cell is simultaneously the most authoritative-looking
    # thing the map will ever draw and the least earned — it is derived, and
    # rewritten wholesale on every recompute — so the declarations that
    # generated it travel alongside it and stay visible on top of it.
    def regions
      return [] unless attached? && regions?

      members    = region_members
      boundaries = region_boundaries

      query("SELECT id, label, confirmed, description, parent_id, seed_room_id, first_seen_at, updated_at " \
            "FROM regions ORDER BY id").map do |row|
        id = row["id"]
        {
          id: id,
          label: row["label"],
          confirmed: row["confirmed"].to_i == 1,
          description: row["description"],
          parent_id: row["parent_id"],
          seed_room_id: row["seed_room_id"],
          first_seen_at: row["first_seen_at"],
          updated_at: row["updated_at"],
          rooms: members.fetch(id, []),
          room_count: members.fetch(id, []).length,
          boundaries: boundaries.fetch(id, [])
        }
      end
    end

    # { room_id => region_id }, for stamping onto room payloads.
    def region_of_room
      return {} unless attached? && regions?

      query("SELECT room_id, region_id FROM room_regions")
        .each_with_object({}) { |r, h| h[r["room_id"]] = r["region_id"] }
    end

    def regions? = schema_version.to_i >= REGIONS_VERSION

    # ---------- survey: the claim ledger --------------------------------

    # What the agent is trying to ESTABLISH about a place, as opposed to what it
    # has recorded about one — docs/plans/week_3/movement_revisited/claims.md.
    #
    # Everything else on this tab is observation: a room was entered, an entity
    # was seen, an exit was walked. A claim is an investigation, and it is the
    # only thing in this file that can be WRONG in an interesting way — it
    # carries a confidence, it accumulates evidence for and against, and it can
    # end up `refuted`. That is why the evidence travels with it here rather
    # than behind a second request: a verdict without the rooms that produced it
    # is exactly as reviewable as a region boundary without its reason, which is
    # to say not at all.
    #
    # Served as one payload with features and hints because they are the same
    # investigation seen from three sides. Feature membership is what
    # `circuit_closes` and `connects` are computed over, and a hint is the guess
    # that moved the survey somewhere; splitting them across three tabs would
    # make the reader assemble by hand what the writer already relates.
    def survey
      return EMPTY_SURVEY unless attached? && survey?

      { claims: claims, features: features, hints: frontier_hints }
    end

    EMPTY_SURVEY = { claims: [], features: [], hints: [] }.freeze

    CLAIM_COLUMNS = "c.id, c.region_id, c.ref, c.statement, c.predicate, c.subject, c.status, " \
                    "c.confidence, c.priority, c.answers, c.decisive_when, c.args, c.room_budget, " \
                    "c.rooms_spent, c.settled_reason, c.objective, c.created_at, c.updated_at".freeze

    def claims
      evidence = claim_evidence

      query(<<~SQL).map do |row|
        SELECT #{CLAIM_COLUMNS}, g.label AS region_label
          FROM claims c
          LEFT JOIN regions g ON g.id = c.region_id
         ORDER BY c.region_id, c.id
      SQL
        rows = evidence.fetch(row["id"], [])
        {
          id: row["id"],
          ref: row["ref"],
          region_id: row["region_id"],
          region_label: row["region_label"],
          statement: row["statement"],
          # The predicate is what the deterministic planner actually ran, and the
          # statement is prose for a human. Both, always — a statement without
          # its predicate cannot be checked against what the survey did.
          predicate: row["predicate"],
          subject: row["subject"],
          status: row["status"],
          confidence: row["confidence"],
          priority: row["priority"],
          answers: row["answers"],
          decisive_when: row["decisive_when"],
          # The class lists a `composition` is tracking, the `n` of a
          # `count_at_least`, the feature a `circuit_closes` is following.
          args: parse_json_object(row["args"]),
          room_budget: row["room_budget"],
          rooms_spent: row["rooms_spent"],
          settled_reason: row["settled_reason"],
          objective: row["objective"],
          created_at: row["created_at"],
          updated_at: row["updated_at"],
          evidence: rows,
          # Counted here rather than in the client because "three for, one
          # against" is the shape of the claim and every view wants it.
          support_count: rows.count { |e| e[:polarity] == "support" },
          contradict_count: rows.count { |e| e[:polarity] == "contradict" }
        }
      end
    end

    # { claim_id => [{ room_id:, room_name:, polarity:, note: }] }, one statement
    # for the whole ledger.
    def claim_evidence
      sql = <<~SQL
        SELECT e.id, e.claim_id, e.room_id, e.polarity, e.note, e.observed_at, r.name AS room_name
          FROM claim_evidence e
          LEFT JOIN rooms r ON r.id = e.room_id
         ORDER BY e.id
      SQL

      query(sql).each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, out|
        out[row["claim_id"]] << {
          id: row["id"],
          room_id: row["room_id"], room_name: row["room_name"],
          # `contradict` is first-class and not an absence of support:
          # establishing that a town has no second bridge is a finding.
          polarity: row["polarity"], note: row["note"], observed_at: row["observed_at"]
        }
      end
    end

    # The one durable per-room tag the claim model needs: which separately
    # observed rooms belong to ONE road or ONE wall. Three predicates are
    # computed over these chains, so a chain assembled wrongly is the most
    # likely reason a survey walked somewhere strange.
    def features
      members = query(<<~SQL).each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, out|
        SELECT fr.feature_id, fr.room_id, fr.note, fr.observed_at, r.name AS room_name
          FROM feature_rooms fr
          LEFT JOIN rooms r ON r.id = fr.room_id
         ORDER BY fr.feature_id, fr.room_id
      SQL
        out[row["feature_id"]] << { room_id: row["room_id"], room_name: row["room_name"],
                                    note: row["note"], observed_at: row["observed_at"] }
      end

      query("SELECT f.id, f.region_id, f.slug, f.label, f.first_seen_at, f.updated_at, " \
            "g.label AS region_label FROM features f LEFT JOIN regions g ON g.id = f.region_id " \
            "ORDER BY f.id").map do |row|
        rooms = members.fetch(row["id"], [])
        {
          id: row["id"], slug: row["slug"], label: row["label"],
          region_id: row["region_id"], region_label: row["region_label"],
          first_seen_at: row["first_seen_at"], updated_at: row["updated_at"],
          rooms: rooms, room_count: rooms.length
        }
      end
    end

    # The surveyor's guess about what lies behind an unwalked exit — the one
    # thing the deterministic scorer cannot work out for itself, and therefore
    # the field that explains most surprising frontier choices.
    def frontier_hints
      sql = <<~SQL
        SELECT h.room_id, h.direction, h.expected_class, h.note, h.updated_at,
               r.name AS room_name, e.target_name
          FROM frontier_hints h
          LEFT JOIN rooms r ON r.id = h.room_id
          LEFT JOIN room_exits e ON e.room_id = h.room_id AND e.direction = h.direction
         ORDER BY h.room_id, h.direction
      SQL

      query(sql).map do |row|
        {
          room_id: row["room_id"], room_name: row["room_name"],
          direction: row["direction"], target_name: row["target_name"],
          expected_class: row["expected_class"], note: row["note"], updated_at: row["updated_at"]
        }
      end
    end

    def survey? = schema_version.to_i >= SURVEY_VERSION

    # ---------- presumed edges ------------------------------------------

    # Exits the MUD NAMED as a room already in memory, matched by name and never
    # walked. They sit beside the frontier rather than on a tab of their own
    # because they are precisely the exits that stopped being frontier: reading
    # the two lists apart is how you tell "the agent has not been there" from
    # "the agent believes it knows, on a name alone".
    def presumed_exits
      return [] unless attached? && presumed?

      sql = <<~SQL
        SELECT e.room_id, e.direction, e.target_name, e.presumed_target_id, e.last_seen_at,
               r.name AS room_name, t.name AS presumed_target_name
          FROM room_exits e
          JOIN rooms r ON r.id = e.room_id
          LEFT JOIN rooms t ON t.id = e.presumed_target_id
         WHERE e.presumed_target_id IS NOT NULL AND e.target_room_id IS NULL
         ORDER BY e.room_id, e.direction
      SQL

      query(sql).map do |row|
        {
          room_id: row["room_id"], room_name: row["room_name"],
          direction: row["direction"], target_name: row["target_name"],
          presumed_target_id: row["presumed_target_id"],
          presumed_target_name: row["presumed_target_name"],
          last_seen_at: row["last_seen_at"]
        }
      end
    end

    # Names that identified more than one room, or that walking disproved. A
    # name in here is never resolved again, so this is the list that explains
    # why an obviously-matching exit was left as frontier.
    def ambiguous_exit_names
      return [] unless attached? && presumed?

      query("SELECT name, reason, noted_at FROM exit_name_ambiguity ORDER BY name").map do |row|
        { name: row["name"], reason: row["reason"], noted_at: row["noted_at"] }
      end
    end

    def presumed? = schema_version.to_i >= PRESUMED_VERSION

    private

    # { region_id => [{ room_id:, basis: }] } — `basis` is what separates a
    # room the agent declared from one that merely inherited, which is the
    # difference between a boundary in the wrong place and a room on the wrong
    # side of a right one (§9).
    def region_members
      query("SELECT rr.room_id, rr.region_id, rr.basis, r.name AS room_name " \
            "FROM room_regions rr JOIN rooms r ON r.id = rr.room_id ORDER BY rr.room_id")
        .each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, out|
          out[row["region_id"]] << { room_id: row["room_id"], room_name: row["room_name"], basis: row["basis"] }
        end
    end

    # { region_id => [{ from_room_id:, to_room_id:, direction:, reason: }] }.
    # The `reason` rides along because it is the one claim a human reviewing a
    # wrong boundary needs to see, and it is a property of the edge rather than
    # of the place.
    def region_boundaries
      sql = <<~SQL
        SELECT b.id, b.from_room_id, b.to_room_id, b.direction, b.region_id, b.reason, b.declared_at,
               f.name AS from_room_name, t.name AS to_room_name
          FROM region_boundaries b
          JOIN rooms f ON f.id = b.from_room_id
          JOIN rooms t ON t.id = b.to_room_id
         ORDER BY b.id
      SQL

      query(sql).each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, out|
        out[row["region_id"]] << {
          id: row["id"],
          from_room_id: row["from_room_id"], from_room_name: row["from_room_name"],
          to_room_id: row["to_room_id"], to_room_name: row["to_room_name"],
          direction: row["direction"], reason: row["reason"], declared_at: row["declared_at"]
        }
      end
    end

    def wal_path = Pathname.new("#{@path}-wal")

    # Does this file have the player half at all? Read from the file's OWN
    # reported version, not from KNOWN_SCHEMA_VERSION — the point is to serve a
    # file older than this reader, so the file is the authority. Memoized
    # because `player` and `stats` both ask within one request and the pragma is
    # constant for the life of a connection.
    def player_half?
      return @player_half unless @player_half.nil?

      @player_half = schema_version.to_i >= PLAYER_HALF_VERSION
    end

    def db
      @db ||= begin
        # NOT `readonly: true`. A readonly connection cannot create the `-shm`
        # that a WAL database needs, so when the agent is not currently running
        # — no `-shm` present, or one left behind by a crash — the page breaks
        # with SQLITE_CANTOPEN. That is exactly when nobody is playing, which is
        # most of the time. `query_only` below is the stronger guarantee anyway:
        # SQLite itself rejects every write at the engine level, which survives
        # someone later adding a helper method to this class.
        handle = SQLite3::Database.new(@path.to_s)
        handle.results_as_hash = true
        # Shorter than the writer's 5s (memory/store.rb): a web request that
        # waits is worse than one that says "busy". Patience is asymmetric here.
        handle.busy_timeout = 2000
        handle.execute("PRAGMA query_only = 1")
        handle
      end
    end

    def query(sql, params = [])
      db.execute(sql, params)
    rescue SQLite3::SQLException => e
      raise SchemaMismatch.new(e.message, schema_version)
    end

    def query_one(sql, params = []) = query(sql, params).first

    def room_ref(id, name)
      id && { id: id, name: name }
    end

    def room_payload(row)
      {
        id: row["id"],
        name: row["name"],
        description: row["description"],
        confidence: row["confidence"],
        look_candidates: parse_json_list(row["look_candidates"]),
        visit_count: row["visit_count"],
        first_seen_at: row["first_seen_at"],
        last_seen_at: row["last_seen_at"],
        surveyed_at: row["surveyed_at"],
        weak_fingerprint: row["weak_fingerprint"],
        strong_fingerprint: row["strong_fingerprint"]
      }
    end

    def entity_payload(row)
      {
        id: row["id"],
        kind: row["kind"],
        descr: row["descr"],
        keyword: row["keyword"],
        # Written as JSON.generate(array) (memory/store.rb#remember_entity) and
        # parsed back by the writer's own reader — so it is a list here too, not
        # the raw string.
        equipment: parse_json_list(row["equipment"]),
        # `threat` is consider's verdict and is only meaningful next to the
        # player level it was measured at (memory/schema.rb). Both, always —
        # a verdict without its level is actively misleading after a level-up.
        threat: row["threat"],
        threat_level: row["threat_level"],
        seen_count: row["seen_count"],
        first_seen_at: row["first_seen_at"],
        last_seen_at: row["last_seen_at"]
      }
    end

    # `look_candidates` and `equipment` are both JSON array strings. One
    # malformed row must not blank the whole table, so a parse failure is an
    # empty list, not an exception.
    # `args` on a claim is a JSON OBJECT, not a list — the class lists a
    # composition is tracking, the `n` of a count_at_least. Same posture as
    # `parse_json_list`: one malformed row must not blank the ledger.
    def parse_json_object(raw)
      return {} if raw.nil? || raw.to_s.strip.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def parse_json_list(raw)
      return [] if raw.nil? || raw.to_s.strip.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    def exits_for(room_ids)
      return {} if room_ids.empty?

      rows = query(<<~SQL, room_ids)
        SELECT #{EXIT_COLUMNS} FROM room_exits
         WHERE room_id IN (#{placeholders(room_ids)})
         ORDER BY room_id, direction
      SQL

      rows.group_by { |r| r["room_id"] }.transform_values do |group|
        group.map do |row|
          {
            direction: row["direction"],
            target_name: row["target_name"],
            target_room_id: row["target_room_id"],
            traversals: row["traversals"],
            last_seen_at: row["last_seen_at"]
          }
        end
      end
    end

    def entity_summaries_for(room_ids)
      return {} if room_ids.empty?

      rows = query(<<~SQL, room_ids)
        SELECT s.room_id, e.id, e.kind, e.descr, e.keyword
          FROM entity_sightings s
          JOIN entities e ON e.id = s.entity_id
         WHERE s.room_id IN (#{placeholders(room_ids)})
         ORDER BY s.room_id, e.kind, e.keyword, e.id
      SQL

      rows.group_by { |r| r["room_id"] }.transform_values do |group|
        group.map do |row|
          {
            id: row["id"],
            kind: row["kind"],
            descr: row["descr"],
            keyword: row["keyword"]
          }
        end
      end
    end

    def sightings_for(entity_ids)
      return {} if entity_ids.empty?

      rows = query(<<~SQL, entity_ids)
        SELECT s.entity_id, s.room_id, s.count, s.sighting_count, s.last_seen_at, r.name AS room_name
          FROM entity_sightings s
          JOIN rooms r ON r.id = s.room_id
         WHERE s.entity_id IN (#{placeholders(entity_ids)})
         ORDER BY s.last_seen_at DESC
      SQL

      rows.group_by { |r| r["entity_id"] }.transform_values do |group|
        group.map do |row|
          {
            room_id: row["room_id"],
            room_name: row["room_name"],
            count: row["count"],
            sighting_count: row["sighting_count"],
            last_seen_at: row["last_seen_at"]
          }
        end
      end
    end

    # Ids come from the database itself (or from a route constrained to \d+),
    # never from free text — but they are bound as parameters regardless.
    def placeholders(values) = Array.new(values.length, "?").join(", ")
  end
end
