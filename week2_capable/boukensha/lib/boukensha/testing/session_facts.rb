require "json"

module Boukensha
  module Testing
    # Tier 1: deterministic facts about one case.
    #
    # A pure function of the session `.jsonl` the harness just wrote, plus the
    # post-run `knowledge.sqlite3`. No model, no cost, no variance — which is
    # the whole reason `expect:` exists at all: the interesting regressions
    # ("it called `examine` on the menu again", "it took 14 tool calls instead
    # of 6") are all mechanically detectable, and a model should never be asked
    # to judge something a grep can decide.
    #
    # Every field below already exists in the log today. `mud_calls`, `mud_ms`,
    # `db_reads` and `db_writes` come straight off `operation_end`'s counter
    # deltas, and the `initiator: "model" | "hook"` split is what makes
    # `max_model_tool_calls` a budget rather than a count of framework chatter.
    # NO new instrumentation is required for tier 1 — that is the payoff for
    # work_attribution.md and observ_improvements.md having already landed.
    class SessionFacts
      ToolCall = Struct.new(:call_id, :name, :args, :initiator, :ok, :duration_ms, :result,
                            keyword_init: true) do
        # A hook's bootstrap `score`/`look` is framework chatter, not a choice
        # the agent made. A log written before the provenance contract has no
        # initiator at all, and everything there counts as the model's — which
        # is what that number meant before the split existed.
        def model? = initiator != "hook"
      end

      SPAN_COUNTERS = %i[db_reads db_writes db_ms journal_lines inference_ms mud_ms mud_calls].freeze

      attr_reader :path, :session_id, :launch, :session_name, :events

      def self.load(path, knowledge_db: nil, rooms_at_start: nil)
        new(path, knowledge_db: knowledge_db, rooms_at_start: rooms_at_start).tap(&:parse!)
      end

      def initialize(path, knowledge_db: nil, rooms_at_start: nil)
        @path           = path.to_s
        @session_id     = File.basename(@path, ".jsonl")
        @knowledge_db   = knowledge_db
        @rooms_at_start = rooms_at_start
        @events         = []
        @tool_calls     = []
        @span_parents   = {}
        @span_ends      = []
      end

      def parse!
        by_call_id = {}
        File.foreach(@path) do |line|
          line = line.strip
          next if line.empty?

          event = begin
            JSON.parse(line)
          rescue JSON::ParserError
            next # a truncated final line of a log still being written
          end
          @events << event

          case event["phase"]
          when "session_start"
            @launch       = event["launch"]
            @session_name = event["session_name"]
          when "session_rename"
            # Last one wins — the name is the last one the file mentions, not
            # the first (Logger#rename).
            @session_name = event["session_name"]
          when "tool_call"
            call = ToolCall.new(call_id: event["call_id"], name: event["name"],
                                args: event["args"] || {}, initiator: event["initiator"])
            @tool_calls << call
            by_call_id[event["call_id"]] = call
          when "tool_result"
            call = by_call_id[event["call_id"]]
            next unless call

            call.ok          = event["ok"] != false
            call.duration_ms = event["duration_ms"]
            call.result      = event["result"]
          when "operation_start"
            @span_parents[event["operation_id"]] = event["parent_operation_id"]
          when "operation_end"
            @span_ends << event
          end
        end
        self
      end

      # ---------- projections ----------------------------------------------

      def tool_calls           = @tool_calls
      def model_tool_calls     = @tool_calls.count(&:model?)
      def automatic_tool_calls = @tool_calls.count { |c| !c.model? }
      def has_provenance?      = @tool_calls.any? { |c| c.initiator }

      def iterations = phase("iteration").map { |e| e["n"].to_i }.max.to_i
      def turns      = phase("turn").size

      # Why the last turn stopped. `turn_end.reason` is the agent's own word for
      # it; a log that never reached one ended some other way, and saying so is
      # more useful than inventing "completed".
      def end_reason = phase("turn_end").last&.dig("reason") || (@events.empty? ? "empty" : "incomplete")

      def input_tokens  = responses.sum { |e| e["input_tokens"].to_i }
      def output_tokens = responses.sum { |e| e["output_tokens"].to_i }

      def cost_usd
        costs = responses.filter_map { |e| e["cost_usd"] }
        costs.empty? ? nil : costs.sum
      end

      def started_at = @events.first&.dig("at")
      def ended_at   = @events.last&.dig("at")

      def duration_ms
        first = @events.first&.dig("mono_ms")
        last  = @events.last&.dig("mono_ms")
        return nil unless first && last

        (last - first).round
      end

      # Summed over ROOT spans only. A nested span's counters are already inside
      # its parent's delta, so adding every span would multiply the same work by
      # its depth.
      def span_totals
        roots = @span_ends.select { |e| @span_parents[e["operation_id"]].nil? }
        SPAN_COUNTERS.to_h { |key| [key, roots.sum { |e| e[key.to_s].to_i }] }
      end

      def errors(error_log_path)
        return [] unless error_log_path && File.file?(error_log_path)

        File.foreach(error_log_path).filter_map do |line|
          record = JSON.parse(line) rescue next
          next unless record["session_id"] == @session_id

          { id: record["id"], component: record["component"], boundary: record["boundary"],
            message: record["message"], class: record["class"] }
        end
      end

      # ---------- world state ------------------------------------------------

      # Where the agent ended up, by name. Read out of the store rather than
      # parsed out of the transcript: the transcript's last room mention may be
      # a room it looked INTO, and `player_state.current_room_id` is the one
      # thing that means "standing in".
      def final_room
        knowledge do |db|
          row = db.execute(
            "SELECT r.name FROM player_state p JOIN rooms r ON r.id = p.current_room_id WHERE p.id = 1"
          ).first
          row && row.first
        end
      end

      def rooms_known
        knowledge { |db| db.execute("SELECT COUNT(*) FROM rooms").first.first.to_i }
      end

      def rooms_known_delta
        return nil unless @rooms_at_start && rooms_known

        rooms_known - @rooms_at_start
      end

      # The whole tier-1 projection, as it lands in the report.
      def to_h
        {
          model_tool_calls: model_tool_calls,
          automatic_tool_calls: automatic_tool_calls,
          has_provenance: has_provenance?,
          iterations: iterations,
          turns: turns,
          end_reason: end_reason,
          duration_ms: duration_ms,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_usd: cost_usd,
          final_room: final_room,
          rooms_known: rooms_known,
          rooms_known_delta: rooms_known_delta
        }.merge(span_totals)
      end

      private

      def phase(name)   = @events.select { |e| e["phase"] == name }
      def responses     = phase("response")

      def knowledge
        return nil unless @knowledge_db && File.file?(@knowledge_db.to_s)

        require "sqlite3"
        db = SQLite3::Database.new(@knowledge_db.to_s)
        begin
          yield db
        ensure
          db.close
        end
      rescue LoadError, SQLite3::Exception
        nil
      end
    end
  end
end
