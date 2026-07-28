require "json"
require "fileutils"
require "securerandom"
require "time"

module Boukensha
  module Testing
    # One JSON document per RUN — one CLI invocation, N cases.
    #
    # Design choices worth defending, because each one is a way of being wrong
    # that this shape prevents:
    #
    # - **`cases[].session_id` is the join key.** The report LINKS to sessions;
    #   it does not duplicate them. Everything shown per case is either a fact
    #   derived from that session or a judgement about it, and the monitor's
    #   report screen is one click from the full transcript.
    # - **`resolved_state` is embedded, not referenced.** State files change. A
    #   report saying `base_initial_state: cleric` is worthless six weeks later;
    #   one saying `gold: 0, level: 10` still means something.
    # - **Distributions, not just a mean.** The whole point of `--batch 20` is
    #   that the agent is stochastic. median/p90 on tool calls and cost turns
    #   "it usually works" into a number, and `failure_modes` turns twenty logs
    #   into one sentence.
    # - **`status` is `pass` | `fail` | `error`.** `error` (seeding failed,
    #   timeout, crash) is NOT `fail`. Conflating a broken harness with a
    #   failing agent is how you spend an afternoon debugging a model that was
    #   never called.
    class Report
      SCHEMA = 1

      attr_reader :run_id, :kind, :name, :started_at, :cases

      def self.new_run_id
        "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
      end

      def initialize(kind:, name:, environment: {}, run_id: nil)
        @run_id      = run_id || self.class.new_run_id
        @kind        = kind.to_s
        @name        = name.to_s
        @environment = environment
        @started_at  = Time.now.utc
        @cases       = []
      end

      def <<(case_row)
        @cases << case_row
        self
      end

      def to_h
        {
          schema: SCHEMA,
          run_id: @run_id,
          kind: @kind,
          name: @name,
          started_at: iso(@started_at),
          ended_at: iso(Time.now.utc),
          environment: @environment,
          summary: summary,
          cases: @cases
        }
      end

      # `tests/reports/<scenario-or-plan>/<run_id>.json`, matching the
      # `reports/**/*.json` glob. `run_id` has the same shape as a session id,
      # so a directory listing sorts chronologically by filename exactly as
      # SessionLog::Store already relies on.
      def write!(reports_dir, path: nil)
        target = path || File.join(reports_dir, safe(@name), "#{@run_id}.json")
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, JSON.pretty_generate(to_h))
        target
      end

      def summary
        statuses = @cases.map { |c| c[:status] }
        judged   = @cases.filter_map { |c| c.dig(:judge, :cost_usd) }
        agent    = @cases.filter_map { |c| c.dig(:facts, :cost_usd) }

        {
          cases: @cases.size,
          passed: statuses.count("pass"),
          failed: statuses.count("fail"),
          errored: statuses.count("error"),
          # Deliberately over ALL cases, errors included: a run where five cases
          # crashed did not pass 15/15, and a rate that hides the crashes is the
          # number you would quote by accident.
          pass_rate: @cases.empty? ? nil : (statuses.count("pass").to_f / @cases.size).round(4),
          cost_usd: { agent: round(agent.sum), judge: round(judged.sum),
                      total: round(agent.sum + judged.sum) },
          median: percentiles(0.5),
          p90: percentiles(0.9),
          failure_modes: failure_modes
        }
      end

      # Clustered by WHICH expectation failed, which is what turns twenty logs
      # into one sentence. A judge-only failure and a crash get their own
      # buckets rather than being invisible.
      def failure_modes
        @cases.each_with_object(Hash.new(0)) do |row, out|
          next if row[:status] == "pass"

          failures = Array(row[:expectations]).reject { |e| e[:ok] }
          if failures.empty?
            out[row[:status] == "error" ? (row[:error_kind] || "error") : "judge"] += 1
          else
            failures.each { |e| out["#{e[:kind]}: #{e[:rule]}"] += 1 }
          end
        end
      end

      private

      METRICS = %i[model_tool_calls automatic_tool_calls iterations duration_ms cost_usd].freeze

      def percentiles(q)
        METRICS.each_with_object({}) do |key, out|
          values = @cases.filter_map { |c| c.dig(:facts, key) }.sort
          next if values.empty?

          out[key] = quantile(values, q)
        end
      end

      # Nearest-rank. With 20 samples there is nothing to interpolate between
      # that is more honest than the observed value itself.
      def quantile(sorted, q)
        index = (q * (sorted.size - 1)).round
        value = sorted[index]
        value.is_a?(Float) ? value.round(6) : value
      end

      def round(value) = value.nil? ? nil : value.round(6)
      def iso(time)    = time.iso8601(3)
      def safe(text)   = text.to_s.gsub(/[^\w.-]+/, "_")
    end
  end
end
