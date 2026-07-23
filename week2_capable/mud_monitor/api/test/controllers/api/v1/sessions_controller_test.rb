require "test_helper"

module Api
  module V1
    class SessionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @previous_dir = Rails.application.config.x.mud_monitor.sessions_dir
        Rails.application.config.x.mud_monitor.sessions_dir =
          Pathname.new(Rails.root.join("test/fixtures/session_logs"))
      end

      teardown do
        Rails.application.config.x.mud_monitor.sessions_dir = @previous_dir
      end

      test "index lists sessions from the configured directory" do
        get api_v1_sessions_path

        assert_response :success
        body = response.parsed_body
        ids = body["sessions"].map { |s| s["id"] }
        assert_includes ids, "complete"
        assert_includes ids, "empty"
      end

      test "show returns the full detail payload for a known session" do
        get api_v1_session_path("complete")

        assert_response :success
        body = response.parsed_body
        assert_equal "complete", body["session"]["id"]
        assert_equal 5, body["entries"].length
        assert body["entries"].any? { |e| e["type"] == "tool" && e["result_html"].present? }
      end

      test "show 404s for an unknown session id" do
        get api_v1_session_path("does-not-exist")

        assert_response :not_found
        assert_equal "not_found", response.parsed_body["error"]["code"]
      end

      test "show 404s instead of escaping the sessions directory via path traversal" do
        get "/api/v1/sessions/#{ERB::Util.url_encode('../../../../etc/passwd')}"

        assert_response :not_found
      end

      test "events pages through entries newer than `after`, clamped to `limit`" do
        get events_api_v1_session_path("complete"), params: { after: 0, limit: 2 }

        assert_response :success
        body = response.parsed_body
        assert_equal [ 1, 2 ], body["entries"].map { |e| e["seq"] }
        assert_equal 2, body["next_seq"]
        assert_not body["eof"]

        get events_api_v1_session_path("complete"), params: { after: body["next_seq"] }

        assert_response :success
        body = response.parsed_body
        assert_equal [ 3, 4, 5 ], body["entries"].map { |e| e["seq"] }
        assert_equal 5, body["next_seq"]
        assert body["eof"]
      end

      test "events clamps a non-positive limit up to 1 rather than returning nothing" do
        get events_api_v1_session_path("complete"), params: { after: 0, limit: 0 }

        assert_response :success
        assert_equal 1, response.parsed_body["entries"].length
      end

      test "events 404s for an unknown session id" do
        get events_api_v1_session_path("does-not-exist")

        assert_response :not_found
      end

      test "messages returns the definitive per-call payload — system, tools and wire messages" do
        get messages_api_v1_session_path("request_timeline")

        assert_response :success
        cps = response.parsed_body["checkpoints"]

        assert_equal 4, cps.length
        assert_equal "request", cps.first["source"]
        # the system prompt and full tool schemas — invisible in the transcript
        assert_equal "You are a MUD player.", cps.first["system"]
        assert_equal %w[look move], cps.first["tools"].map { |t| t["name"] }
        # constants carried forward on the next call
        assert_equal "You are a MUD player.", cps[1]["system"]
        assert_not cps[1]["system_changed"]
        # compaction + clear surfaced as markers with the delta
        assert_equal "compaction", cps[2]["marker"]
        assert_equal 1, cps[2]["dropped"]
        assert_equal "clear", cps[3]["marker"]
      end

      test "messages includes authoritative token totals, input cost and an estimated composition" do
        get messages_api_v1_session_path("request_timeline")

        assert_response :success
        cps = response.parsed_body["checkpoints"]

        # authoritative: real prompt size and its growth, from the model's usage
        assert_equal 150, cps[1]["tokens"]["context"]
        assert_equal 100, cps[1]["tokens"]["context_delta"]
        assert_equal 30, cps[1]["tokens"]["cache_read"]
        # input-side cost priced from the model rate (haiku input = $1/MTok):
        # 120*1e-6 + 30*1e-6*0.1 = 0.000123
        assert_in_delta 0.000123, cps[1]["input_cost_usd"], 1e-9
        # estimated composition sums to the authoritative context total
        comp = cps[1]["composition"]
        assert_equal %w[system tools messages], comp.map { |c| c["label"] }
        assert comp.all? { |c| c["estimated"] }
        assert_equal 150, comp.sum { |c| c["tokens"] }
        # a call with no logged response has null token/cost fields, not fake zeros
        assert_nil cps[3]["tokens"]["context"]
        assert_nil cps[3]["input_cost_usd"]
      end

      test "messages 404s for an unknown session id" do
        get messages_api_v1_session_path("does-not-exist")

        assert_response :not_found
      end

      test "stream flushes pending entries as SSE frames, then sends eof once idle" do
        cfg = Rails.application.config.x.mud_monitor
        previous_timeout = cfg.stream_idle_timeout
        cfg.stream_idle_timeout = 0

        begin
          get stream_api_v1_session_path("complete"), params: { after: 3 }

          assert_response :success
          assert_equal "text/event-stream", response.media_type
          assert_includes response.body, "event: entry"
          assert_includes response.body, "id: 4"
          assert_includes response.body, "id: 5"
          assert_includes response.body, "event: eof"
          assert_not_includes response.body, "id: 3"
        ensure
          cfg.stream_idle_timeout = previous_timeout
        end
      end

      test "stream responds 503 when the concurrent stream cap is already reached" do
        cfg = Rails.application.config.x.mud_monitor
        previous_gate = cfg.stream_gate
        cfg.stream_gate = StreamGate.new(max: 0)

        begin
          get stream_api_v1_session_path("complete")

          assert_response :service_unavailable
          assert_equal "too_many_streams", response.parsed_body["error"]["code"]
        ensure
          cfg.stream_gate = previous_gate
        end
      end
    end
  end
end
