require "test_helper"

module SessionLog
  class TimingTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/session_logs")

    test "summary rolls up tool/model percentiles, idle time, and wall vs busy time" do
      parser  = Parser.load(FIXTURES.join("monotonic.jsonl"))
      summary = Timing.new(parser).summary

      assert_equal 2000, summary[:p50_tool_ms]
      assert_equal 2000, summary[:p95_tool_ms]
      assert_equal 305, summary[:p50_model_ms]
      assert_equal 305, summary[:p95_model_ms]
      assert_equal 0, summary[:total_idle_ms] # no gap exceeds the 5s idle threshold
      assert_equal 2465, summary[:wall_ms]
      assert_equal 2465, summary[:busy_ms] # wall_ms - total_idle_ms, and idle is 0 here
    end

    # §6: the 1.9s that read as model latency was a blocking MUD `score` the
    # model never asked for. Attribute it, and the two stop being confusable.
    test "tool time splits into what the model spent and what the hooks spent" do
      parser  = Parser.load(FIXTURES.join("provenance.jsonl"))
      summary = Timing.new(parser).summary

      assert_equal 210, summary[:model_tool_ms]          # one move
      assert_equal 2035, summary[:automatic_tool_ms]     # score + look + poll
      # The whole point of the split: nearly all of the automatic time is one
      # blocking `score`, and it is now attributable to `player_bootstrap`
      # rather than sitting adjacent to Iteration 0 looking like inference.
      bootstrap = parser.automatic_operations.find { |r| r[:operation] == "player_bootstrap" }
      assert_equal 1930, bootstrap[:duration_ms]
      assert_operator bootstrap[:duration_ms], :>, summary[:model_tool_ms]
    end

    # A log with no provenance cannot make the split. Reporting 0 automatic ms
    # would claim it did.
    test "a pre-provenance log reports the split as unknown, not as zero" do
      summary = Timing.new(Parser.load(FIXTURES.join("monotonic.jsonl"))).summary

      assert_nil summary[:model_tool_ms]
      assert_nil summary[:automatic_tool_ms]
    end

    # work_attribution.md §2: `dt_ms` charges the model for our own request
    # serialization (the gap since the previous emitted entry), not just the
    # `@client.call`. Once an `llm.generate` span exists, its measured
    # duration must win — 250ms, not the ~3000ms gap to the next entry.
    test "model_ms prefers the llm.generate span duration over dt_ms" do
      parser  = Parser.load(FIXTURES.join("llm_generate.jsonl"))
      summary = Timing.new(parser).summary

      assert_equal 250, summary[:p50_model_ms]
      assert_equal 250, summary[:model_ms]
    end

    test "an empty session reports nil rollups instead of crashing" do
      parser  = Parser.load(FIXTURES.join("empty.jsonl"))
      summary = Timing.new(parser).summary

      assert_nil summary[:p50_tool_ms]
      assert_nil summary[:p50_model_ms]
      assert_equal 0, summary[:total_idle_ms]
      assert_nil summary[:wall_ms]
      assert_nil summary[:busy_ms]
    end
  end
end
