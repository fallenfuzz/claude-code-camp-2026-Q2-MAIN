module Api
  module V1
    class ErrorsController < ApplicationController
      include ActionController::Live

      POLL_INTERVAL = 0.25
      HEARTBEAT_INTERVAL = 15
      DEFAULT_LIMIT = 100
      MAX_LIMIT = 500

      def index
        records = store.existing_path ? ::ErrorLog::Parser.load(store.path) : []
        records = filter(records)
        after = params[:after].to_i
        before = params[:before].presence&.to_i
        records = records.select { |record| record.seq > after } if after.positive?
        records = records.select { |record| record.seq < before } if before
        entries = records.last(limit).reverse

        render json: {
          entries: entries.map(&:as_json),
          next_cursor: records.last&.seq || after,
          previous_cursor: entries.last&.seq,
          live: store.live?,
          available: !store.existing_path.nil?
        }
      end

      def stream
        cfg.stream_gate.acquire { serve_stream }
      rescue StreamGate::AtCapacity
        render json: { error: { code: "too_many_streams",
                                message: "Max concurrent streams (#{cfg.max_streams}) reached" } },
               status: :service_unavailable
      end

      private

      def serve_stream
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"
        sse = ActionController::Live::SSE.new(response.stream, retry: 1000)
        cursor = (request.headers["Last-Event-ID"].presence || params[:after]).to_i
        follower = ::ErrorLog::Follower.new(store.path)
        last_beat = last_activity = Time.now

        loop do
          records = filter(follower.records_after(cursor))
          if records.any?
            records.each do |record|
              sse.write(record.as_json, event: "entry", id: record.seq)
              cursor = [cursor, record.seq].max
            end
            last_beat = last_activity = Time.now
          elsif Time.now - last_beat >= HEARTBEAT_INTERVAL
            sse.write({ at: Time.now.iso8601(3) }, event: "heartbeat")
            last_beat = Time.now
          end
          break if Time.now - last_activity >= cfg.stream_idle_timeout
          sleep POLL_INTERVAL
        end
        sse.write({ reason: "idle" }, event: "eof")
      rescue IOError, Errno::EPIPE
        nil
      ensure
        sse&.close rescue nil
      end

      def filter(records)
        records = records.select { |r| r["component"] == params[:component] } if params[:component].present?
        if params[:exception_class].present?
          records = records.select { |r| r["exception_class"] == params[:exception_class] }
        end
        records = records.select { |r| r["session_id"] == params[:session_id] } if params[:session_id].present?
        records = records.select { |r| r["operation_id"] == params[:operation_id] } if params[:operation_id].present?
        if params[:q].present?
          query = params[:q].downcase
          records = records.select do |r|
            [r["exception_class"], r["message"], r["component"], *Array(r["backtrace"])]
              .compact.any? { |value| value.to_s.downcase.include?(query) }
          end
        end
        records
      end

      def limit
        value = params.fetch(:limit, DEFAULT_LIMIT).to_i
        [[value, 1].max, MAX_LIMIT].min
      end

      def store
        @store ||= ::ErrorLog::Store.new(path: cfg.error_log, live_window: cfg.live_window)
      end

      def cfg = profile_config
    end
  end
end
