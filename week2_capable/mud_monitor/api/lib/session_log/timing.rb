require "time"

module SessionLog
  # Session-level timing rollups (spec §4.4), derived from the per-entry
  # `dt_ms`/`duration_ms` a Parser already computed. Read time between agent
  # "think" (model latency) and "MUD time" (tool duration) is exactly what the
  # dropped-strip UI needs to separate.
  class Timing
    def initialize(parser)
      @parser = parser
    end

    def summary
      {
        p50_tool_ms: percentile(tool_durations, 50),
        p95_tool_ms: percentile(tool_durations, 95),
        p50_model_ms: percentile(model_durations, 50),
        p95_model_ms: percentile(model_durations, 95),
        # Where the tool time actually went (observ_improvements.md §6). The
        # percentiles above mix a hook's 1.9s blocking `score` in with the
        # model's own calls, which is how that 1.9s came to sit next to
        # Iteration 0 looking like inference. Both are nil on a log with no
        # provenance — the file cannot make the split, and reporting 0 would
        # claim it did.
        model_tool_ms: sum_or_nil(initiated_durations { |e| e.initiator != "hook" }),
        automatic_tool_ms: sum_or_nil(initiated_durations { |e| e.initiator == "hook" }),
        model_ms: model_durations.sum,
        total_idle_ms: idle_ms,
        wall_ms: wall_ms,
        busy_ms: busy_ms
      }
    end

    private

    IDLE_THRESHOLD_MS = 5_000

    def tool_entries
      @parser.entries.select { |e| e.type == :tool }
    end

    def tool_durations
      tool_entries.filter_map(&:duration_ms)
    end

    # nil rather than 0 when the log carries no provenance at all: "we cannot
    # tell" and "there was none" are different answers and only one is honest.
    def initiated_durations(&predicate)
      return [] unless tool_entries.any?(&:initiator)

      tool_entries.select(&predicate).filter_map(&:duration_ms)
    end

    def sum_or_nil(values)
      values.empty? ? nil : values.sum
    end

    # Prefer the `llm.generate` span's MEASURED duration — `@client.call`
    # alone, nothing either side of it — over the `assistant` entry's `dt_ms`,
    # which is the gap since the previous emitted entry and so also charges the
    # model for our own request/response serialization (work_attribution.md
    # §2). Falls back to `dt_ms` for a log written before the span existed, the
    # same way the parser keeps its adjacency fold for pre-span nesting.
    def model_durations
      spans = @parser.entries.select { |e| e.type == :operation_end && e.operation == "llm.generate" }
      return spans.filter_map(&:duration_ms) if spans.any?

      @parser.entries.select { |e| e.type == :assistant }.filter_map(&:duration_ms)
    end

    # Sum of gaps between consecutive entries greater than the idle threshold
    # — think time or MUD time, distinct from dead air waiting on nothing.
    def idle_ms
      @parser.entries.filter_map(&:dt_ms).select { |dt| dt > IDLE_THRESHOLD_MS }.sum
    end

    def wall_ms
      return nil unless @parser.started_at && @parser.ended_at

      ((Time.parse(@parser.ended_at) - Time.parse(@parser.started_at)) * 1000).round
    rescue ArgumentError, TypeError
      nil
    end

    def busy_ms
      w = wall_ms
      return nil unless w

      w - idle_ms
    end

    def percentile(values, pct)
      return nil if values.empty?

      sorted = values.sort
      index  = ((pct / 100.0) * (sorted.length - 1)).round
      sorted[index]
    end
  end
end
