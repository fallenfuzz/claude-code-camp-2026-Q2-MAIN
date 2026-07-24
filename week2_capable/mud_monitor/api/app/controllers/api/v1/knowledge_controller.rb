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

      # GET /knowledge/entities?kind=&q=
      def entities
        with_reader do |reader|
          render json: reader.envelope.merge(
            entities: reader.entities(kind: params[:kind], q: params[:q])
          )
        end
      end

      # GET /knowledge/frontier
      def frontier
        with_reader do |reader|
          exits = reader.frontier
          render json: reader.envelope.merge(frontier: exits, count: exits.length)
        end
      end

      private

      def with_reader(&block)
        ::Knowledge::Reader.open(path: cfg.knowledge_db, live_window: cfg.live_window, &block)
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
