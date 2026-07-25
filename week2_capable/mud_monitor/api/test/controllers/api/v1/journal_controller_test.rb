require "test_helper"

module Api
  module V1
    class JournalControllerTest < ActionDispatch::IntegrationTest
      FIXTURE_DATE = "20260724"

      setup do
        @previous_dir = Rails.application.config.x.mud_monitor.journal_dir
        Rails.application.config.x.mud_monitor.journal_dir =
          Pathname.new(Rails.root.join("test/fixtures/journal"))
      end

      teardown do
        Rails.application.config.x.mud_monitor.journal_dir = @previous_dir
      end

      test "index folds the day into graphable series" do
        get api_v1_journal_path, params: { date: FIXTURE_DATE }

        assert_response :success
        body = response.parsed_body
        assert_equal [ 1, 2 ], body.dig("series", "stats", "level").map { |p| p["value"] }
        assert_equal %w[level_up death], body.dig("series", "milestones").map { |m| m["op"] }
        assert_equal %w[acquire drop], body.dig("series", "items").map { |i| i["op"] }
        assert_equal 9, body["next_seq"]
      end

      test "index returns entries after the cursor" do
        get api_v1_journal_path, params: { date: FIXTURE_DATE, after: 7 }

        assert_response :success
        assert_equal [ 8, 9 ], response.parsed_body["entries"].map { |e| e["seq"] }
      end

      test "index is an empty, non-erroring series when no file exists for the date" do
        get api_v1_journal_path, params: { date: "20200101" }

        assert_response :success
        body = response.parsed_body
        assert_equal({}, body.dig("series", "stats"))
        assert_equal [], body["entries"]
        assert_not body["live"]
      end

      # The join the session transcript needs (work_attribution.md §3). The
      # change log already held the detail of what a unit of work wrote;
      # nothing addressed it BY that unit, so a span's `⛁ wrote 11` could not be
      # expanded into the lines behind it.
      test "index narrows the day to one operation" do
        get api_v1_journal_path, params: { date: FIXTURE_DATE, operation_id: "op_bbb222" }

        assert_response :success
        body = response.parsed_body
        assert_equal [ 4, 5 ], body["entries"].map { |e| e["seq"] }
        assert_equal [ "op_bbb222" ], body["entries"].map { |e| e["operation_id"] }.uniq
        # The series folds only the scoped records — a chart of one operation is
        # a chart of what that operation changed, not of the whole day.
        assert_equal [ 2 ], body.dig("series", "stats", "level").map { |p| p["value"] }
      end

      # A file written before spans existed carries no `operation_id` at all,
      # and "this operation wrote nothing here" is the honest answer — not a 404
      # and not the unfiltered day.
      test "index returns an empty day for an operation that wrote nothing" do
        get api_v1_journal_path, params: { date: FIXTURE_DATE, operation_id: "op_never" }

        assert_response :success
        assert_equal [], response.parsed_body["entries"]
      end

      test "index narrows the day to one session" do
        get api_v1_journal_path, params: { date: FIXTURE_DATE, session: "s1" }
        assert_equal 9, response.parsed_body["entries"].length

        get api_v1_journal_path, params: { date: FIXTURE_DATE, session: "s2" }
        assert_equal [], response.parsed_body["entries"]
      end

      test "stream 404s when there is no journal to tail" do
        get api_v1_journal_stream_path, params: { date: "20200101" }
        assert_response :not_found
      end
    end
  end
end
