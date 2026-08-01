require "json"
require "set"
require_relative "../mud/memory/regions"

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

      def self.load(path, knowledge_db: nil, rooms_at_start: nil, regions_at_start: nil,
                    journal_dir: nil)
        new(path, knowledge_db: knowledge_db, rooms_at_start: rooms_at_start,
                  regions_at_start: regions_at_start, journal_dir: journal_dir).tap(&:parse!)
      end

      def initialize(path, knowledge_db: nil, rooms_at_start: nil, regions_at_start: nil,
                     journal_dir: nil)
        @path             = path.to_s
        @session_id       = File.basename(@path, ".jsonl")
        @knowledge_db     = knowledge_db
        @rooms_at_start   = rooms_at_start
        @regions_at_start = regions_at_start
        @journal_dir      = journal_dir
        @events           = []
        @tool_calls       = []
        @span_parents     = {}
        @span_ends        = []
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

      # ---------- regions (mocking_messages.md §9) ---------------------------
      #
      # Neither `expect:` nor a tripwire could previously say "a boundary was
      # placed", which made the region cases gradeable only by the judge — prose
      # where a projection would do. Everything below reads a database this class
      # already has open, plus the journal file it did not read before.

      def regions_known
        knowledge { |db| db.execute("SELECT COUNT(*) FROM regions").first.first.to_i }
      end

      # The count is not the interesting number. A case running against
      # `snapshot:midgaard` inherits whatever the snapshot declared, so only the
      # delta says what THIS run decided.
      def regions_delta
        return nil unless @regions_at_start && regions_known

        regions_known - @regions_at_start
      end

      def region_labels
        knowledge { |db| db.execute("SELECT label FROM regions ORDER BY label").map(&:first) } || []
      end

      # A `⟨from …⟩` label is provenance rather than a claim (Regions §2), and
      # one still standing at the end of a run is a region the agent never
      # answered the question about. Asserting its absence is the cheapest
      # possible check that naming happened at all.
      def provisional_region_labels
        region_labels.select { |label| Mud::Memory::Regions.provisional_label?(label) }
      end

      # The boundaries THIS session declared, with the edge each one used —
      # which is what `find_mayor_split`'s `undesired_behaviour` is actually
      # about ("the boundary should not land on an interior edge"). Scoped by
      # `region_boundaries.session_id`, so a snapshot's inherited boundaries are
      # not reported as this run's work.
      # `kind = 'split'`, because an egress row is not a split and reporting one
      # as such would say the agent divided a place when what it did was walk out
      # of it (staying_in_town.md §10.4).
      def region_splits
        knowledge do |db|
          db.execute(<<~SQL, [@session_id]).map do |row|
            SELECT b.to_room_id, b.from_room_id, b.direction, b.reason, r.label,
                   (SELECT name FROM rooms WHERE id = b.to_room_id)
            FROM region_boundaries b JOIN regions r ON r.id = b.region_id
            WHERE b.session_id = ? AND b.kind = 'split' ORDER BY b.id
          SQL
            { room_id: row[0], from_room_id: row[1], direction: row[2], reason: row[3],
              region: row[4], room: row[5] }
          end
        end || []
      end

      def region_split? = !region_splits.empty?

      # ---------- movement that left the place (staying_in_town.md §13) --------
      #
      # `rooms_known_delta` already appears in the report and says nothing about
      # WHERE the rooms are. This is the conduct measure beside it: rooms not
      # reachable from the session's origin room over known exits without
      # traversing a recorded `egress` boundary.
      #
      # Run 20260731T171650Z-09259cd5 is the case it exists for. That run passed
      # every mechanical gate in the suite — one `no_progress_call` of twenty, two
      # destination repeats against a ceiling of two — and mapped forty-one rooms,
      # fifteen of them countryside outside the city walls. The only thing in the
      # whole harness that noticed was a Sonnet judge reading a rubric line the
      # agent could not see, and it cited the wrong two calls when it did, because
      # every crossing happened inside a leg of a call whose arguments look
      # innocuous. This makes the same failure deterministic, free, and
      # attributable to the leg that caused it.
      #
      # Computed from recorded crossings and not from region identity, for the
      # reason §8 gives at length: a region's parent records which region it was
      # split out of rather than which place contains it, `The Plains` came out a
      # descendant of `The Temple`, and half that run's countryside shared a
      # region with the temple interior. An edge the walker recorded at the moment
      # it crossed cannot be moved by a later relabelling.

      # Where this session's walking began: the starting room of the first
      # `move_to` call it answered, travel or survey. Both modes journal it.
      def origin_room_id
        move_to_answers.filter_map { |e| e["from_room_id"] }.first
      end

      def rooms_outside_scope
        origin = origin_room_id
        return nil unless origin

        knowledge do |db|
          rooms = db.execute("SELECT id FROM rooms").map(&:first)
          next nil if rooms.empty?

          inside = reachable_without_egress(db, origin)
          (rooms - inside.to_a).size
        end
      end

      # ---------- the navigation journal --------------------------------------

      # `region_split`, `region_split_declined` and `region_split_rejected` are
      # journal events rather than session events (MoveTo#journal), so they are
      # invisible to every projection above. A declined split is a CORRECT
      # outcome for a large-but-coherent region, and until this existed there was
      # no way to assert one.
      #
      # Joined by `session_id` across the journal's daily files, in append order.
      def journal_events(stream: nil)
        @journal_events ||= read_journal
        return @journal_events unless stream

        @journal_events.select { |e| e["stream"] == stream.to_s }
      end

      # { "move_to.region_split" => 1, "move_to.decision" => 6 } — the shape an
      # expectation names, so a rule and the fact behind it spell the op the
      # same way.
      def journal_ops
        journal_events.each_with_object(Hash.new(0)) do |event, out|
          next unless event["kind"] == "event"

          out["#{event['stream']}.#{event['op']}"] += 1
        end
      end

      # ---------- movement that bought nothing ---------------------------------
      #
      # `move_to` journals one `answered` event per call carrying the status and
      # the number of rooms it walked, and the two facts below are the only
      # mechanical read on whether a session's movement budget turned into
      # coverage. Run 20260731T140528Z-34c846bf is what they are for: twenty-one
      # model calls, all of them `move_to`, twelve of them answering
      # `unreachable` without moving and one more answering `arrived` from where
      # it already stood.
      #
      # ZERO ROOMS is the whole test. It is deliberately not "walked nothing
      # useful" — that run also spent two calls walking one room north and one
      # room back south, which a human reading the transcript counts as waste and
      # no projection can, so the number here is smaller than the number in the
      # diagnosis and means something a grep can decide.
      def move_to_answers = journal_events(stream: "move_to").select { |e| e["op"] == "answered" }

      def no_progress_calls = move_to_answers.count { |e| e["rooms_walked"].to_i.zero? }

      # How many times the session asked for the SAME place. One repeat is an
      # agent re-planning after a setback; nine is an agent with no reason inside
      # the answer to expect the tenth call to differ.
      def max_destination_repeats
        counts = move_to_answers.each_with_object(Hash.new(0)) { |e, h| h[e["destination"].to_s] += 1 }
        counts.values.max.to_i
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
          rooms_known_delta: rooms_known_delta,
          regions_known: regions_known,
          regions_delta: regions_delta,
          region_labels: region_labels,
          # The placement, not just the fact of it. A boundary is only as good as
          # the edge it sits on, and the report is where that has to be legible
          # without opening the database.
          region_splits: region_splits,
          journal_ops: journal_ops,
          no_progress_calls: no_progress_calls,
          max_destination_repeats: max_destination_repeats,
          rooms_outside_scope: rooms_outside_scope
        }.merge(span_totals)
      end

      private

      # The same walk `RoutePlanner.reachable_within` does, in SQL, because this
      # class reads a database rather than a live store and must not require the
      # agent's object graph to grade a log. Undirected for the same reason it is
      # undirected there: the question is which side of the wall a room is on, and
      # a room reached through a one-way drop is still on the side it landed on.
      def reachable_without_egress(db, origin)
        barrier = db.execute("SELECT from_room_id, to_room_id FROM region_boundaries WHERE kind = 'egress'")
                    .map { |a, b| [a, b].sort }.to_set
        adjacent = Hash.new { |h, k| h[k] = [] }
        db.execute("SELECT room_id, COALESCE(target_room_id, presumed_target_id) FROM room_exits " \
                   "WHERE COALESCE(target_room_id, presumed_target_id) IS NOT NULL").each do |from, to|
          adjacent[from] << to
          adjacent[to]   << from
        end

        seen  = Set.new([origin])
        queue = [origin]
        until queue.empty?
          room_id = queue.shift
          adjacent[room_id].each do |neighbour|
            next if barrier.include?([room_id, neighbour].sort)
            next unless seen.add?(neighbour)

            queue << neighbour
          end
        end
        seen
      end

      def phase(name)   = @events.select { |e| e["phase"] == name }
      def responses     = phase("response")

      # Every journal line this session wrote, oldest first. The files rotate
      # daily and `seq` restarts with them, so the files are read in name order
      # and each is read in append order — which IS chronological, and does not
      # pretend `seq` is a global cursor.
      def read_journal
        return [] unless @journal_dir && File.directory?(@journal_dir.to_s)

        Dir.glob(File.join(@journal_dir.to_s, "*.jsonl")).sort.flat_map do |path|
          File.foreach(path).filter_map do |line|
            event = begin
              JSON.parse(line)
            rescue JSON::ParserError
              next
            end
            event if event["session_id"] == @session_id
          end
        end
      end

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
