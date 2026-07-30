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
    # - **A run describing more than one configuration says so.** A median taken
    #   across `max_decisions: 4` and `max_decisions: 10` is a number describing
    #   nothing, and it is the number the run's final line would otherwise print.
    #   So a multi-arm run reports counts and cost — which aggregate honestly —
    #   puts statistics under `arms`, and omits run-level `median`, `p90` and
    #   `pass_rate`. Omitting a misleading number beats qualifying it in a comment
    #   nobody reads.
    class Report
      # 2 — settings_sweep.md. Two changes a reader needs to know about:
      #
      #   * `summary.arms` exists, and a multi-arm run omits run-level
      #     `pass_rate` / `median` / `p90` (§5). A single-arm run keeps exactly
      #     the shape schema 1 had, plus the additive per-case `arm`, `settings`
      #     and `settings_digest` fields.
      #   * `settings_digest` now hashes the RESOLVED settings rather than the
      #     bytes of `settings.yaml` (§4), because an override applied in memory
      #     does not change the file and every arm of a sweep would otherwise
      #     carry an identical digest. A canonical serialisation of a parsed YAML
      #     document does not hash to the same value as that document's bytes, so
      #     every digest changed on the day this landed even though no
      #     configuration did: reports at schema 1 and schema 2 cannot be compared
      #     on digest equality. That is a one-time discontinuity, and it is
      #     recorded here so a reader six months from now is not left guessing.
      SCHEMA = 2

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

      # One arm label per distinct configuration in the run, in the order the
      # cases were declared. A run with nothing overridden has one arm and is the
      # shape every report before settings_sweep.md had.
      def arms
        @cases.map { |row| row[:arm] }.uniq
      end

      def multi_arm? = arms.size > 1

      def summary
        base = counts(@cases)

        if multi_arm?
          # No run-level pass_rate / median / p90. See the class comment: across
          # two configurations they are numbers describing nothing.
          base.merge(cost_usd: cost(@cases), arms: arm_summaries, failure_modes: failure_modes(@cases))
        else
          base.merge(
            # Deliberately over ALL cases, errors included: a run where five
            # cases crashed did not pass 15/15, and a rate that hides the crashes
            # is the number you would quote by accident.
            pass_rate: pass_rate(@cases),
            cost_usd: cost(@cases),
            median: percentiles(@cases, 0.5),
            p90: percentiles(@cases, 0.9),
            failure_modes: failure_modes(@cases)
          )
        end
      end

      # One entry per arm: its label, the overrides that define it, its own
      # digest, and the same statistics `summary` computes, scoped to its cases.
      # A reader who distrusts an aggregate can rebuild every one of these from
      # the case rows, which carry the same three fields each.
      def arm_summaries
        @cases.group_by { |row| row[:arm] }.map do |label, rows|
          identity = { arm: label,
                       settings: rows.first[:settings] || {},
                       settings_digest: rows.first[:settings_digest] }.compact
          statistics = { pass_rate: pass_rate(rows),
                         cost_usd: cost(rows),
                         median: percentiles(rows, 0.5),
                         p90: percentiles(rows, 0.9),
                         failure_modes: failure_modes(rows) }
          identity.merge(counts(rows)).merge(statistics)
        end
      end

      # Clustered by WHICH expectation failed, which is what turns twenty logs
      # into one sentence. A judge-only failure and a crash get their own
      # buckets rather than being invisible.
      def failure_modes(rows = @cases)
        rows.each_with_object(Hash.new(0)) do |row, out|
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

      def counts(rows)
        statuses = rows.map { |row| row[:status] }
        { cases: rows.size, passed: statuses.count("pass"),
          failed: statuses.count("fail"), errored: statuses.count("error") }
      end

      def pass_rate(rows)
        return nil if rows.empty?

        (rows.count { |row| row[:status] == "pass" }.to_f / rows.size).round(4)
      end

      def cost(rows)
        agent  = rows.filter_map { |row| row.dig(:facts, :cost_usd) }.sum
        judged = rows.filter_map { |row| row.dig(:judge, :cost_usd) }.sum
        { agent: round(agent), judge: round(judged), total: round(agent + judged) }
      end

      def percentiles(rows, q)
        METRICS.each_with_object({}) do |key, out|
          values = rows.filter_map { |row| row.dig(:facts, key) }.sort
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
