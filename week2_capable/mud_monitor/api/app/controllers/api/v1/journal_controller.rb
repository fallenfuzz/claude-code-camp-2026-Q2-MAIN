module Api
  module V1
    # The agent's progression log, read-only. Unlike knowledge (a snapshot that
    # is polled), the journal is an append-only file with a per-record `seq`, so
    # it streams — and it counts against the same 8-slot StreamGate as
    # sessions/telnet/manager, needing no new streaming infrastructure.
    class JournalController < ApplicationController
      include ActionController::Live

      POLL_INTERVAL      = 0.25
      HEARTBEAT_INTERVAL = 15

      rescue_from ::Journal::Store::NotFound, with: :render_not_found

      # GET /journal?date=&after=
      #
      # Returns the whole day folded into graphable series (a chart wants the
      # full history, not a page) plus the raw entries after `after` for a
      # lightweight "anything new?" poll.
      def index
        path    = store.path_for(date_param)
        records = path ? ::Journal::Parser.load(path).records : []
        after   = params[:after].to_i
        pending = records.select { |r| r.seq > after }

        render json: {
          date:     date_param,
          series:   ::Journal::Series.fold(records),
          entries:  pending.map { |r| JournalRecordSerializer.call(r) },
          next_seq: records.last&.seq || after,
          live:     path ? store.live?(path) : false
        }
      end

      # GET /journal/stream?date=&after=   (text/event-stream)
      def stream
        path = store.path_for!(date_param)

        cfg.stream_gate.acquire { serve_stream(path) }
      rescue StreamGate::AtCapacity
        render json: { error: { code: "too_many_streams",
                                message: "Max concurrent streams (#{cfg.max_streams}) reached" } },
               status: :service_unavailable
      end

      private

      def serve_stream(path)
        response.headers["Content-Type"]  = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"

        sse           = ActionController::Live::SSE.new(response.stream, retry: 1000)
        follower      = ::Journal::Follower.new(path)
        cursor        = (request.headers["Last-Event-ID"].presence || params[:after]).to_i
        last_beat     = Time.now
        last_activity = Time.now

        loop do
          new_records = follower.records_after(cursor)

          if new_records.any?
            new_records.each do |record|
              sse.write(JournalRecordSerializer.call(record), event: "entry", id: record.seq)
              cursor = record.seq
            end
            last_beat = last_activity = Time.now
          elsif Time.now - last_beat >= HEARTBEAT_INTERVAL
            sse.write({ at: Time.now.iso8601(3) }, event: "heartbeat")
            last_beat = Time.now
          end

          if Time.now - last_activity >= cfg.stream_idle_timeout
            sse.write({ reason: "session_end" }, event: "eof")
            break
          end

          sleep POLL_INTERVAL
        end
      rescue IOError, Errno::EPIPE
        # client disconnected mid-stream — nothing left to do
      ensure
        begin
          sse&.close
        rescue IOError
        end
      end

      def date_param
        params[:date].presence || store.today
      end

      def store
        # `journal_dir` is set by the initializer, which only runs at boot — a
        # server started before this feature was added reloads this controller
        # but not that config, leaving journal_dir nil. Fall back to deriving it
        # from boukensha_dir (the same rule the initializer uses) so a stale boot
        # self-heals instead of 500ing; a restart still picks up any env override.
        dir = cfg.journal_dir || cfg.boukensha_dir&.join("journal")
        @store ||= ::Journal::Store.new(dir: dir, live_window: cfg.live_window)
      end

      def cfg
        profile_config
      end

      def render_not_found(_error)
        render json: { error: { code: "not_found", message: "No journal for #{date_param}" } },
               status: :not_found
      end
    end
  end
end
