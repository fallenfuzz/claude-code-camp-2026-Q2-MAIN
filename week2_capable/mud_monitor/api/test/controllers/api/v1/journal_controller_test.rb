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

      test "stream 404s when there is no journal to tail" do
        get api_v1_journal_stream_path, params: { date: "20200101" }
        assert_response :not_found
      end
    end
  end
end
