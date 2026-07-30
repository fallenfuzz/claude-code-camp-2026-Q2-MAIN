module Api
  module V1
    # The agent's world memory, read-only.
    #
    # No SSE here, unlike every other live view in this app. Sessions, telnet
    # and manager stream because they tail an append-only file with a cursor;
    # an UPDATE to `rooms.visit_count` is not an event and cannot be expressed
    # as "entries after seq N". The client polls instead (3s, gated on tab
    # visibility), so `cfg.stream_gate` is untouched and knowledge never
    # consumes one of the 8 SSE slots.
    class KnowledgeController < ApplicationController
      DEFAULT_LIMIT = 200
      MAX_LIMIT     = 1000

      # `Boukensha::Logger#generate_session_id`, exactly. Every action accepts
      # `?session=<id>` and turns it into a filesystem path, which makes this
      # the one parameter in this application where a traversal is possible —
      # so the id is matched against the grammar before it is joined to
      # anything, and a value that does not match is refused rather than
      # sanitised.
      SESSION_ID = /\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/

      rescue_from ::Knowledge::Reader::SchemaMismatch, with: :render_schema_mismatch

      # GET /knowledge
      def show
        with_reader do |reader|
          render json: reader.envelope.merge(stats: reader.stats, player: reader.player)
        end
      end

      # GET /knowledge/rooms?q=&filter=&limit=
      def rooms
        with_reader do |reader|
          render json: reader.envelope.merge(
            rooms: reader.rooms(q: params[:q], filter: params[:filter], limit: clamp_limit(params[:limit]))
          )
        end
      end

      # GET /knowledge/rooms/:id
      def room
        with_reader do |reader|
          room = reader.room(params[:id].to_i)
          return render_room_not_found unless room

          render json: reader.envelope.merge(
            room: room,
            entities: reader.entities_in_room(room[:id]),
            encounters: reader.encounters(room_id: room[:id]),
            inbound: reader.inbound(room[:id])
          )
        end
      end

      # GET /knowledge/player
      #
      # Its own action rather than more keys on #show, for the same reason
      # `rooms` and `entities` are: #show is the Overview poll and runs every
      # 3s on the busiest tab, and a full skill list plus two item snapshots is
      # not something that page renders. One action per view keeps the cheap
      # poll cheap.
      #
      # Against a V1 file this answers with the four numbers that existed then
      # and empty lists for the rest — an older agent's memory is served, not
      # rejected.
      def player
        with_reader do |reader|
          render json: reader.envelope.merge(
            player: reader.player,
            skills: reader.player_skills,
            inventory: reader.player_items(location: "inventory"),
            equipped: reader.player_items(location: "equipped")
          )
        end
      end

      # GET /knowledge/entities?kind=&q=
      def entities
        with_reader do |reader|
          render json: reader.envelope.merge(
            entities: reader.entities(kind: params[:kind], q: params[:q])
          )
        end
      end

      # GET /knowledge/regions
      #
      # The places the agent named, with their declared boundary edges and the
      # rooms that ended up in each. Its own action beside the other
      # `knowledge/*` reads, and a snapshot like all of them — a declaration is
      # a row that changes, not an event with a cursor to tail.
      def regions
        with_reader do |reader|
          rows = reader.regions
          render json: reader.envelope.merge(regions: rows, count: rows.length)
        end
      end

      # GET /knowledge/frontier
      #
      # Two lists, one request. Presumed exits are what USED to be counted here
      # and no longer is — the MUD named a room the agent has already stood in,
      # so the exit is routable and is not exploration. Serving them apart on
      # the same tab is what lets a reader tell "nobody has been there" from
      # "something believes it knows, on a name alone", and the ambiguity set
      # explains the exits that look resolvable and were deliberately refused.
      def frontier
        with_reader do |reader|
          exits    = reader.frontier
          presumed = reader.presumed_exits
          render json: reader.envelope.merge(
            frontier: exits, count: exits.length,
            presumed: presumed, presumed_count: presumed.length,
            ambiguous_names: reader.ambiguous_exit_names
          )
        end
      end

      # GET /knowledge/survey
      #
      # The claim ledger, its evidence, the feature chains three predicates are
      # computed over, and the surveyor's expected-class hints — one payload,
      # because they are one investigation seen from four sides and a reader
      # asked to join them across four tabs would be doing the writer's work.
      #
      # A snapshot like every other knowledge read. A claim's confidence moves
      # by UPDATE and cannot be expressed as "entries after seq N", so there is
      # nothing to tail here any more than there is for a room's visit count.
      def survey
        with_reader do |reader|
          payload = reader.survey
          render json: reader.envelope.merge(payload).merge(
            count: payload[:claims].length,
            open_count: payload[:claims].count { |c| %w[open parked].include?(c[:status]) }
          )
        end
      end

      private

      # Live by default; `?session=<id>` serves the map that session ENDED with,
      # out of the harness's retained directory.
      #
      # The reader needs no teaching for this. It already takes a path, opens a
      # connection per request rather than memoizing one, reports absence as a
      # state instead of raising, and gates every read on the schema version the
      # file itself reports — so a past session's memory is a different path,
      # not a different reader.
      def with_reader(&block)
        session = params[:session].presence
        return render_invalid_session if session && !SESSION_ID.match?(session)

        path = session ? retained_map_path(session) : cfg.knowledge_db
        ::Knowledge::Reader.open(path: path, live_window: cfg.live_window, session: session, &block)
      end

      # Off the boukensha ROOT and under the harness's directory, exactly where
      # `CaseRunner` writes it — the monitor resolves the writer's path rather
      # than guessing a parallel one.
      #
      # A missing file here is NOT an error: retention keeps thirty per profile,
      # so an older session having no map is the policy working. The reader
      # answers `attached: false` and the UI says which policy removed it.
      def retained_map_path(session)
        cfg.tests_dir.join("knowledge", "sessions", cfg.profile.to_s, "#{session}.sqlite3")
      end

      def render_invalid_session
        render json: { error: { code: "invalid_session",
                                message: "#{params[:session].inspect} is not a session id " \
                                         "(expected the form 20260729T183933Z-4caca6d5)" } },
               status: :bad_request
      end

      def clamp_limit(raw)
        limit = raw.presence&.to_i || DEFAULT_LIMIT
        limit.clamp(1, MAX_LIMIT)
      end

      def cfg
        profile_config
      end

      def render_room_not_found
        render json: { error: { code: "not_found", message: "No room #{params[:id]} in the agent's memory" } },
               status: :not_found
      end

      # A SELECT the file's schema can't answer. One clear banner beats a 500
      # backtrace, and the rest of the monitor is unaffected — this endpoint is
      # the only thing that reads someone else's DDL.
      def render_schema_mismatch(error)
        render json: { error: { code: "knowledge_schema_mismatch",
                                message: error.message,
                                schema_version: error.schema_version } },
               status: :service_unavailable
      end
    end
  end
end
