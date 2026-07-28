require "test_helper"
require "tmpdir"

module Api
  module V1
    class ReportsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @dir = Pathname.new(Dir.mktmpdir("reports-controller"))
        @original = Rails.application.config.x.mud_monitor.boukensha_dir
        Rails.application.config.x.mud_monitor.boukensha_dir = @dir
        FileUtils.mkdir_p(@dir.join("tests", "reports"))
      end

      teardown do
        Rails.application.config.x.mud_monitor.boukensha_dir = @original
        FileUtils.remove_entry(@dir)
      end

      test "index lists run summaries newest first" do
        write("find_bakery", "20260728T090000Z-00000000", profile: "Dummy")
        write("banking", "20260728T143000Z-a1b2c3d4", profile: "Derrano")

        get api_v1_reports_path

        assert_response :success
        reports = response.parsed_body["reports"]
        assert_equal %w[20260728T143000Z-a1b2c3d4 20260728T090000Z-00000000], reports.map { |r| r["id"] }
        assert_equal 20, reports.first["cases"]
        assert_equal "sha256:9f21", reports.first["settings_digest"]
      end

      # The list renders twenty of these; it does not need twenty embedded case
      # arrays. What it DOES need is the per-case series, because variance is
      # the measurement.
      test "index carries the tool-call series but not the full case documents" do
        write("find_bakery", "20260728T143000Z-a1b2c3d4")

        get api_v1_reports_path
        report = response.parsed_body["reports"].first

        assert_equal [6], report["tool_calls_series"]
        assert_nil report["cases_detail"]
      end

      test "index filters by profile" do
        write("find_bakery", "20260728T090000Z-00000000", profile: "Dummy")
        write("banking", "20260728T143000Z-a1b2c3d4", profile: "Derrano")

        get api_v1_reports_path, params: { profile: "Derrano" }

        assert_equal ["20260728T143000Z-a1b2c3d4"], response.parsed_body["reports"].map { |r| r["id"] }
      end

      test "an empty reports directory is an empty list, not an error" do
        get api_v1_reports_path

        assert_response :success
        assert_empty response.parsed_body["reports"]
      end

      test "show returns the full document with its cases" do
        write("find_bakery", "20260728T143000Z-a1b2c3d4")

        get api_v1_report_path("20260728T143000Z-a1b2c3d4")

        assert_response :success
        report = response.parsed_body["report"]
        assert_equal "find_bakery", report["name"]
        assert_equal 1, report["cases"].length
        # The join key back to the session. The report links; it does not copy.
        assert_equal "20260728T143241Z-fef86633", report.dig("cases", 0, "session_id")
      end

      test "an unknown id is a 404 with a message" do
        get api_v1_report_path("nope")

        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
      end

      test "a traversing id is a 404 rather than a file read" do
        get api_v1_report_path("..%2f..%2fetc%2fpasswd")

        assert_response :not_found
      end

      test "a half-written report is 503 with an explanation rather than a 500" do
        FileUtils.mkdir_p(@dir.join("tests", "reports", "find_bakery"))
        File.write(@dir.join("tests", "reports", "find_bakery", "20260728T160000Z-cccccccc.json"), '{"run_id": "trunc')

        get api_v1_report_path("20260728T160000Z-cccccccc")

        assert_response :service_unavailable
        assert_equal "report_unreadable", response.parsed_body.dig("error", "code")
      end

      private

      def write(name, run_id, profile: "Derrano")
        dir = @dir.join("tests", "reports", name)
        FileUtils.mkdir_p(dir)
        File.write(dir.join("#{run_id}.json"), JSON.generate(
          schema: 1, run_id: run_id, kind: "scenario", name: name,
          started_at: "2026-07-28T14:30:00.000Z", ended_at: "2026-07-28T14:52:11.000Z",
          environment: { profile: profile, provider: "anthropic", model: "claude-haiku-4-5",
                         settings_digest: "sha256:9f21", git_sha: "710e23e" },
          summary: { cases: 20, passed: 17, failed: 2, errored: 1, pass_rate: 0.85,
                     cost_usd: { agent: 0.31, judge: 0.08, total: 0.39 },
                     median: { model_tool_calls: 6 }, p90: { model_tool_calls: 9 },
                     failure_modes: { "timeout" => 1 } },
          cases: [{ index: 1, scenario: name, session_id: "20260728T143241Z-fef86633",
                    session_name: "#{name} #1", profile: profile, status: "pass",
                    facts: { model_tool_calls: 6, cost_usd: 0.0161 } }]
        ))
      end
    end
  end
end
