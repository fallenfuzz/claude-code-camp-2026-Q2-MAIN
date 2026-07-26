require "json"
require "time"

module SessionLog
  # Parses a Boukensha session .jsonl log into an ordered list of entries
  # suitable for rendering as a human-readable transcript.
  # Port of week1_baseline/log_viz/lib/log_viz/session.rb.
  class Parser
    Entry = Struct.new(:seq, :type, :text, :usage, :turn, :iteration, :at, :mono_ms,
                       :dt_ms, :duration_ms,
                       :tool_name, :tool_args, :tool_result, :tool_ok, :tool_error,
                       :stop_reason, :reason, :iterations, :tokens, :before, :dropped,
                       :running_turn_tokens, :redacted, :raw,
                       :task, :depth, :task_name, :max_iterations,
                       :provider, :model, :input_tokens, :output_tokens,
                       :cost_usd, :usage_unit, :usage_level,
                       :request_seq, :message_count,
                       # Provenance (observ_improvements.md §1). `initiator` is
                       # "model" for a call the model chose and "hook" for work
                       # the framework did on its behalf; `operation`/`trigger`
                       # say why and from which lifecycle seam. All nil on logs
                       # written before the contract existed — which is exactly
                       # how the legacy display path is selected.
                       :call_id, :initiator, :operation, :trigger, :parent_call_id,
                       # Operation spans (work_attribution.md §1). `operation_id`
                       # is on every event a span contains; `parent_operation_id`
                       # is on the span's own start and is what makes nesting a
                       # FACT rather than an inference from adjacency. Nil on
                       # every log written before spans existed, which is how the
                       # adjacency fallback is selected.
                       :operation_id, :parent_operation_id, :ok, :rollup,
                       :trace_id, :span_id, :otel_kind, :semantic_kind,
                       :attributes,
                       # The local ONNX classifier's per-call record (§2).
                       :backend, :artifact, :pool, :kept, :threshold, :top_k,
                       :available, :unit,
                       # What the model actually received when a hook replaced
                       # the result (`tool` entries), and the source/changed
                       # flags of an injected_context entry.
                       :model_result, :model_result_chars, :raw_chars,
                       :kind, :source, :changed, :content,
                       keyword_init: true)

    # One sample per `response`, in order. Drives the cost breakdown and the
    # trend sparkline.
    UsagePoint = Struct.new(:turn, :iteration, :input, :output,
                            :cache_read, :cache_creation, :running, :at,
                            :task, :provider, :model, :cost_usd,
                            :usage_unit, :usage_level,
                            keyword_init: true)

    attr_reader :id, :path, :started_at, :entries,
                :total_input_tokens, :total_output_tokens, :snapshot,
                :usage_series, :peak_input_tokens

    def self.load(path)
      new(path).tap(&:parse!)
    end

    def initialize(path)
      @path                = path
      @id                  = File.basename(path, ".jsonl")
      @entries             = []
      @started_at          = nil
      @total_input_tokens  = 0
      @total_output_tokens = 0
      @snapshot            = {}
      @usage_series        = []
      @peak_input_tokens   = 0
    end

    def parse!
      current_turn      = 0
      current_iteration = 0
      pending_user      = true
      pending_calls     = []
      running_turn      = 0   # cumulative input+output within the current turn
      seq               = 0
      turn_started      = nil # {at:, mono_ms:} of the current "turn" event
      open_tasks        = [] # task_start events awaiting their task_end
      open_operations   = {} # operation_id => operation_start timing
      request_ordinal   = 0   # 1-based index among request events → sidebar checkpoint seq
      # call_id → the emitted :tool entry, so a later context_transform can be
      # folded into the card it belongs to rather than becoming a second one.
      tool_entries_by_call_id = {}

      File.foreach(@path) do |line|
        line = line.strip
        next if line.empty?

        event = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next # truncated final line of a log still being written
        end

        case event["phase"]
        when "session_start"
          @started_at = event["at"]
          @snapshot   = event           # carries the limits/model denominators
        when "turn"
          current_turn = event["n"]
          pending_user = true
          running_turn = 0
          turn_started = { at: event["at"], mono_ms: event["mono_ms"] }
        when "iteration"
          current_iteration = event["n"]
        when "request"
          # The full request payload (system + tool schemas + wire messages) is
          # far too large to render inline — it belongs in the messages sidebar
          # (SessionLog::MessageTimeline). Here we emit only a compact marker so
          # the transcript can place a button at the exact point the call was
          # made; `request_seq` maps 1:1 to the sidebar checkpoint to open.
          request_ordinal += 1
          @entries << seq_entry(seq += 1, event, type: :request,
                                 request_seq: request_ordinal,
                                 message_count: event["message_count"],
                                 turn: current_turn, iteration: current_iteration)
        when "prompt"
          next unless pending_user

          message = event["messages"]&.last
          if message && message["role"] == "user"
            @entries << seq_entry(seq += 1, event, type: :user, text: extract_text(message["content"]),
                                   turn: current_turn, iteration: current_iteration)
          end
          pending_user = false
        when "compaction"
          @entries << seq_entry(seq += 1, event, type: :compaction, before: event["before"],
                                 dropped: event["dropped"],
                                 turn: current_turn, iteration: current_iteration)
        when "clear"
          @entries << seq_entry(seq += 1, event, type: :clear, before: event["before"],
                                 dropped: event["dropped"] || event["before"],
                                 turn: current_turn, iteration: current_iteration)
        when "reasoning"
          @entries << seq_entry(seq += 1, event, type: :reasoning, text: event["text"],
                                 redacted: event["redacted"],
                                 turn: current_turn, iteration: current_iteration)
        when "plan"
          @entries << seq_entry(seq += 1, event, type: :plan, text: event["text"],
                                 turn: current_turn, iteration: current_iteration)
        when "response"
          usage = event["usage"]
          if usage
            input  = (event["input_tokens"] || usage["input_tokens"]).to_i
            output = (event["output_tokens"] || usage["output_tokens"]).to_i
            @total_input_tokens  += input
            @total_output_tokens += output
            running_turn         += input + output
            @peak_input_tokens    = input if input > @peak_input_tokens
            @usage_series << UsagePoint.new(
              turn: current_turn, iteration: current_iteration,
              input: input, output: output,
              cache_read: usage["cache_read_input_tokens"].to_i,
              cache_creation: usage["cache_creation_input_tokens"].to_i,
              running: running_turn, at: event["at"],
              task: event["task"], provider: event["provider"], model: event["model"],
              cost_usd: numeric(event["cost_usd"]),
              usage_unit: event["usage_unit"], usage_level: event["usage_level"])
          end
          entry = seq_entry(seq += 1, event, type: :assistant, text: event["text"], usage: usage,
                            stop_reason: event["stop_reason"],
                            running_turn_tokens: running_turn,
                            provider: event["provider"],
                            model: event["model"], input_tokens: event["input_tokens"],
                            output_tokens: event["output_tokens"],
                            cost_usd: numeric(event["cost_usd"]),
                            usage_unit: event["usage_unit"],
                            usage_level: event["usage_level"],
                            turn: current_turn, iteration: current_iteration)
          # §4.4: model latency is measured from the previous iteration/tool_result
          # to this response — which, in the ordered entries list, is simply the
          # previous entry (no Entry is emitted for "iteration" or a skipped
          # "prompt"), so it is exactly dt_ms.
          entry.duration_ms = entry.dt_ms
          @entries << entry
        when "operation_start"
          # A unit of work opening. Everything until the matching
          # `operation_end` belongs to it — by id, not by proximity.
          open_operations[event["operation_id"]] = {
            at: event["at"], mono_ms: event["mono_ms"]
          }
          @unclosed_operations = open_operations.size
          @entries << seq_entry(seq += 1, event, type: :operation_start,
                                 operation: event["operation"], trigger: event["trigger"],
                                 operation_id: event["operation_id"],
                                 parent_operation_id: event["parent_operation_id"],
                                 trace_id: event["trace_id"], span_id: event["span_id"],
                                 otel_kind: event["otel_kind"],
                                 semantic_kind: event["semantic_kind"],
                                 attributes: event["attributes"] || {},
                                 turn: current_turn, iteration: current_iteration)
        when "operation_end"
          opened = open_operations.delete(event["operation_id"]) || {}
          @entries << seq_entry(seq += 1, event, type: :operation_end,
                                 operation: event["operation"],
                                 operation_id: event["operation_id"],
                                 trace_id: event["trace_id"], span_id: event["span_id"],
                                 otel_kind: event["otel_kind"],
                                 semantic_kind: event["semantic_kind"],
                                 attributes: event["attributes"] || {},
                                 ok: event.fetch("ok", true),
                                 duration_ms: event["duration_ms"] ||
                                              elapsed_ms(opened[:mono_ms], opened[:at],
                                                         event["mono_ms"], event["at"]),
                                 rollup: event.reject { |k, _| SPAN_ENVELOPE.include?(k) },
                                 turn: current_turn, iteration: current_iteration)
        when "local_inference"
          @entries << seq_entry(seq += 1, event, type: :local_inference,
                                 model: event["model"], backend: event["backend"],
                                 artifact: event["artifact"], operation_id: event["operation_id"],
                                 duration_ms: event["duration_ms"],
                                 pool: event["pool"], kept: event["kept"],
                                 threshold: event["threshold"], top_k: event["top_k"],
                                 # Explicitly $0 rather than absent: "free, and
                                 # here is the latency it cost instead".
                                 cost_usd: numeric(event["cost_usd"]), unit: event["unit"],
                                 available: event.fetch("available", true),
                                 reason: event["reason"],
                                 turn: current_turn, iteration: current_iteration)
        when "tool_call"
          pending_calls << { name: event["name"], args: event["args"], at: event["at"],
                             mono_ms: event["mono_ms"], depth: event["depth"].to_i,
                             call_id: event["call_id"], initiator: event["initiator"],
                             operation: event["operation"], trigger: event["trigger"],
                             operation_id: event["operation_id"],
                             parent_call_id: event["parent_call_id"] }
        when "tool_result"
          call = take_pending_call(pending_calls, event) || {}
          entry = seq_entry(seq += 1, event, type: :tool, tool_name: event["name"] || call[:name],
                            tool_args: call[:args],
                            tool_result: event["result"], tool_ok: event.fetch("ok", true),
                            tool_error: event["error"],
                            # The dispatcher now times the call itself; fall back
                            # to the gap between the two events for older logs.
                            duration_ms: event["duration_ms"] ||
                                         elapsed_ms(call[:mono_ms], call[:at], event["mono_ms"], event["at"]),
                            # Prefer the call's own labels: `tool_result` repeats
                            # them, but the call is where they originate and a
                            # partially-written result must not un-label a call.
                            call_id: event["call_id"] || call[:call_id],
                            initiator: call[:initiator] || event["initiator"],
                            operation: call[:operation] || event["operation"],
                            trigger: call[:trigger] || event["trigger"],
                            operation_id: call[:operation_id] || event["operation_id"],
                            parent_call_id: call[:parent_call_id],
                            turn: current_turn, iteration: current_iteration)
          @entries << entry
          tool_entries_by_call_id[entry.call_id] = entry if entry.call_id
        when "context_transform"
          # NOT a second card. The replacement belongs to the call it replaced —
          # showing it as its own row is what made one movement look like two
          # contradictory events. Attached to the tool entry; emitted standalone
          # only if its call is missing, so a malformed log still shows it.
          target = tool_entries_by_call_id[event["call_id"]]
          if target
            target.model_result       = event["content"]
            target.model_result_chars = event["content"].to_s.length
            target.raw_chars          = event["raw_chars"] || target.tool_result.to_s.length
          else
            @entries << seq_entry(seq += 1, event, type: :context_transform,
                                   call_id: event["call_id"], kind: event["kind"],
                                   content: event["content"], raw_chars: event["raw_chars"],
                                   turn: current_turn, iteration: current_iteration)
          end
        when "injected_context"
          @entries << seq_entry(seq += 1, event, type: :injected_context,
                                 kind: event["kind"], content: event["content"],
                                 source: event["source"], changed: event["changed"],
                                 turn: current_turn, iteration: current_iteration)
        when "task_start"
          # A delegated sub-run opening inside this session (plan Amendment A).
          # Its own limits/model ride on this event — the parent's session_start
          # snapshot describes the parent, not the subagent.
          open_tasks << { at: event["at"], mono_ms: event["mono_ms"] }
          @entries << seq_entry(seq += 1, event, type: :task_start,
                                 task_name: event["task_name"],
                                 model: event["model"], provider: event["provider"],
                                 max_iterations: event["max_iterations"],
                                 turn: current_turn, iteration: current_iteration)
        when "task_end"
          opened   = open_tasks.pop || {}
          @entries << seq_entry(seq += 1, event, type: :task_end,
                                 task_name: event["task_name"],
                                 duration_ms: elapsed_ms(opened[:mono_ms], opened[:at],
                                                          event["mono_ms"], event["at"]),
                                 turn: current_turn, iteration: current_iteration)
        when "turn_end"
          duration = turn_started && elapsed_ms(turn_started[:mono_ms], turn_started[:at],
                                                 event["mono_ms"], event["at"])
          @entries << seq_entry(seq += 1, event, type: :turn_end, reason: event["reason"],
                                 iterations: event["iterations"], tokens: event["tokens"],
                                 duration_ms: duration,
                                 turn: current_turn, iteration: current_iteration)
        else
          @entries << seq_entry(seq += 1, event, type: :unknown, raw: event,
                                 turn: current_turn, iteration: current_iteration)
        end
      end

      @unclosed_tasks      = open_tasks.size
      @unclosed_operations = open_operations.size
    end

    # Everything on an `operation_end` that is NOT the span's own identity or
    # timing is a counter it accumulated. Subtracted generically rather than
    # enumerated, so a new meter on the writing side needs no change here — the
    # same reason Journal::Parser keeps its open set of `fields`.
    SPAN_ENVELOPE = %w[phase operation operation_id parent_operation_id trigger
                       trace_id span_id otel_kind semantic_kind attributes
                       duration_ms ok session_id task depth at mono_ms].freeze

    # "monotonic" once every logged event carries `mono_ms` (§4.1); "wallclock"
    # for ms-resolution `at` from before that upgrade landed but after logger
    # timestamps gained sub-second digits; "wallclock_coarse" for the original
    # whole-second `at` — durations under 1s on those are unknowable, not zero.
    def timing_source
      return "monotonic" if @snapshot["mono_ms"] || entries.any?(&:mono_ms)
      return "wallclock" if @started_at.to_s.include?(".") || entries.any? { |e| e.at.to_s.include?(".") }

      "wallclock_coarse"
    end

    def turn_count
      entries.map(&:turn).max.to_i + 1
    end

    def iteration_count
      entries.map(&:iteration).max.to_i
    end

    # ---- denominators sourced from the session_start snapshot ------------
    def iteration_max   = @snapshot["max_iterations"]
    def max_turn_tokens = @snapshot["max_turn_tokens"]
    def context_window  = @snapshot["context_window"]
    def model           = @snapshot["model"]
    def provider        = @snapshot["provider"]
    def response_models = @usage_series.map(&:model).compact.uniq
    def response_providers = @usage_series.map(&:provider).compact.uniq

    # ---- task roster (plan Amendment A) ----------------------------------
    # The root task is whatever depth 0 was doing; the roster is every task that
    # ran in this file. A session that IS a sub-run (a standalone room_inspector,
    # or one of the orphaned files written before Amendment A) is a valid session
    # whose root task is `room_inspector` — nothing here assumes "player".
    def root_task
      entries.find { |e| e.depth.to_i.zero? && e.task }&.task
    end

    def task_roster = entries.map(&:task).compact.uniq
    def sub_runs    = entries.count { |e| e.type == :task_start }

    # A sub-run whose task_end never arrived — the process died mid-delegation.
    # The group is closed at EOF for rendering; this is how the UI knows not to
    # present that closing as a fact.
    def unclosed_tasks = @unclosed_tasks.to_i

    def model_summary
      labels = @usage_series.map { |p| model_label(p.provider, p.model) }.compact.uniq
      labels = [ model_label(provider, model) ].compact if labels.empty?
      labels.length <= 2 ? labels.join(", ") : "#{labels.length} models"
    end

    # ---- per-turn outcomes ----------------------------------------------
    def turn_ends   = entries.select { |e| e.type == :turn_end }
    def end_reason  = turn_ends.last&.reason
    def stopped?    = !end_reason.nil? && end_reason != "completed"

    # Iterations/tokens of the final turn (falls back to whole-session figures
    # for older logs that predate turn_end).
    def last_iterations = turn_ends.last&.iterations || iteration_count
    def turn_tokens     = turn_ends.last&.tokens || (@total_input_tokens + @total_output_tokens)

    # ---- per-turn rollup --------------------------------------------------
    # One row per turn, built from turn_end events. Falls back to a single
    # synthetic row for older logs that predate turn_end.
    def turns
      rows = turn_ends.map do |e|
        { n: e.turn, iterations: e.iterations, tokens: e.tokens.to_i, reason: e.reason,
          started_at: nil, ended_at: e.at, duration_ms: nil }
      end
      return rows unless rows.empty?

      [ { n: entries.map(&:turn).max.to_i, iterations: iteration_count,
         tokens: @total_input_tokens + @total_output_tokens, reason: end_reason,
         started_at: nil, ended_at: nil, duration_ms: nil } ]
    end

    def limit_reason?(reason) = !reason.nil? && reason != "completed"

    # Worst turn by token spend — the one closest to (or over) the cap.
    def largest_turn      = turns.max_by { |t| t[:tokens] }
    def busiest_turn      = turns.max_by { |t| t[:iterations].to_i }
    def any_limit_tripped? = turns.any? { |t| limit_reason?(t[:reason]) }
    def turn_count_real    = turns.length

    # ---- cost estimate ----------------------------------------------------
    # Prefer logger-emitted per-response cost. Older logs fall back to local
    # model rates; nil means no trustworthy cost is available.
    def estimated_cost
      costs = @usage_series.map { |p| point_cost(p) }.compact
      return nil if costs.empty?

      costs.sum
    end

    def cost_breakdown
      rows = {}
      @usage_series.each do |p|
        key = [ p.task || "unknown", p.provider || provider || "unknown", p.model || model || "unknown" ]
        row = rows[key] ||= {
          task: key[0], provider: key[1], model: key[2],
          calls: 0, input: 0, output: 0, cost: 0.0, cost_known: true
        }
        row[:calls] += 1
        row[:input] += p.input.to_i
        row[:output] += p.output.to_i
        cost = point_cost(p)
        if cost
          row[:cost] += cost
        else
          row[:cost_known] = false
        end
      end
      rows.values.sort_by { |row| [ -row[:cost], row[:task], row[:provider], row[:model] ] }
    end

    def task
      entries.find { |e| e.type == :user }&.text
    end

    def final_response
      entries.reverse.find do |e|
        e.type == :assistant &&
          e.stop_reason != "tool_use" &&
          !e.text.to_s.start_with?("(tool use")
      end&.text
    end

    def ended_at
      entries.last&.at
    end

    def tool_calls_count
      entries.count { |e| e.type == :tool }
    end

    # Model actions and automatic work, counted apart (§3). One number for both
    # let a hook's `score`, `look` and eight empty `poll`s make the model look
    # far more tool-hungry than it was. A log with no provenance has no
    # automatic calls to report — not zero because none happened, but because
    # the file cannot say — so everything there stays in `model_tool_calls`,
    # which is what that number meant before this split existed.
    def tool_entries       = entries.select { |e| e.type == :tool }
    def automatic_tools    = tool_entries.select { |e| e.initiator == "hook" }
    def model_tool_calls   = tool_entries.count { |e| e.initiator != "hook" }
    def automatic_tool_calls = automatic_tools.size
    def has_provenance?    = tool_entries.any? { |e| e.initiator }

    # Wall time spent inside automatic work, so §6's "was the 1.9s the MUD or
    # the model?" is answerable without reading the transcript.
    def automatic_tool_ms
      durations = automatic_tools.filter_map(&:duration_ms)
      durations.empty? ? nil : durations.sum
    end

    # Per-operation rollup — `player_bootstrap`, `position_refresh`,
    # `room_survey`, `async_poll` — for the automatic-work group header.
    def automatic_operations
      automatic_tools.group_by { |e| e.operation || "unattributed" }.map do |operation, rows|
        { operation: operation,
          trigger: rows.first.trigger,
          calls: rows.size,
          duration_ms: rows.filter_map(&:duration_ms).sum,
          empty: rows.count { |e| e.tool_result.to_s.strip.empty? },
          failed: rows.count { |e| e.tool_ok == false } }
      end.sort_by { |row| -row[:duration_ms].to_i }
    end

    # ---- spans (work_attribution.md §1, §4) ------------------------------

    def operation_starts = entries.select { |e| e.type == :operation_start }
    def operation_ends   = entries.select { |e| e.type == :operation_end }
    def operations_count = operation_starts.size

    # A file predating spans has none, and the transcript falls back to folding
    # runs of adjacent hook calls exactly as it does today.
    def has_operations? = operation_starts.any?

    # An operation whose `operation_end` never arrived — the process died
    # mid-flight. Rendered as incomplete rather than as a clean finish, the same
    # treatment `task_end` already gets.
    def unclosed_operations = @unclosed_operations.to_i

    # Session totals in the two currencies that are not dollars. Summed over
    # ROOT spans only: a nested span's counters are already inside its parent's
    # delta, so adding every span would multiply the same work by its depth.
    def span_totals
      roots = operation_ends.select { |e| root_operation?(e.operation_id) }
      %i[db_reads db_writes db_ms journal_lines inference_ms mud_ms].to_h do |key|
        [ key, roots.sum { |e| (e.rollup || {})[key.to_s].to_i } ]
      end
    end

    def local_inferences = entries.select { |e| e.type == :local_inference }

    # The cost table's row for a model that is free. Priced at $0 explicitly,
    # with the call count and total latency that replaced three LLM calls —
    # "no cost information" and "no cost" are different claims.
    def local_cost_rows
      local_inferences.group_by(&:model).map do |name, rows|
        { task: "local", provider: "local", model: name,
          calls: rows.size, input: 0, output: 0, cost: 0.0, cost_known: true,
          duration_ms: rows.filter_map(&:duration_ms).sum,
          unavailable: rows.count { |e| e.available == false } }
      end
    end

    private

    # Every span's opening, by id.
    def starts_by_id
      @starts_by_id ||= operation_starts.each_with_object({}) { |e, h| h[e.operation_id] = e }
    end

    # A span with no parent, or whose parent is missing from this file (a log
    # truncated above its own opening). Both are roots for summing purposes.
    def root_operation?(operation_id)
      parent = starts_by_id[operation_id]&.parent_operation_id
      parent.nil? || !starts_by_id.key?(parent)
    end

    # Pair a tool_result with the tool_call that opened it.
    #
    # `call_id` is exact and is preferred whenever the log carries one
    # (observ_improvements.md §1). Everything below it is the heuristic that
    # served logs written before the id existed, kept because those files must
    # still load:
    #
    # Plain FIFO breaks as soon as a delegating tool is in flight: the player's
    # `inspect_room` call is still pending while the sub-run's own calls open and
    # close inside it, so the first result to arrive is the INNER one and a
    # `shift` hands it the outer call's timestamp. Matching on name+depth (most
    # recent first, since nesting is strictly LIFO) pairs both correctly, and the
    # name-only fallback keeps pre-Amendment-A logs, which carry no depth,
    # behaving as before.
    def take_pending_call(pending, event)
      call_id = event["call_id"]
      name    = event["name"]
      depth   = event["depth"].to_i
      index   = (call_id && pending.rindex { |c| c[:call_id] == call_id }) ||
                pending.rindex { |c| c[:name] == name && c[:depth] == depth } ||
                pending.rindex { |c| c[:name] == name }
      return nil if index.nil?

      pending.delete_at(index)
    end

    # `task`/`depth` are stamped here, from the record, for EVERY entry type —
    # the logger stamps them in its own write path for the same reason (plan
    # §A.3.1): a field a call site can forget is a field that goes dead. Logs
    # written before Amendment A carry neither; they read as one unlabelled root
    # task at depth 0, which is what they were.
    def seq_entry(seq, event, **attrs)
      ts = ts_ms(event)
      dt = (ts && @last_ts_ms) ? (ts - @last_ts_ms).round : nil
      @last_ts_ms = ts if ts
      # Correlation is part of the event envelope, not a type-specific detail.
      # Carry it on every parsed entry so request/reasoning/assistant and future
      # content phases do not silently fall back to interval inference.
      attrs[:operation_id] = event["operation_id"] unless attrs.key?(:operation_id)
      attrs[:call_id] = event["call_id"] unless attrs.key?(:call_id)
      attrs[:initiator] = event["initiator"] unless attrs.key?(:initiator)

      Entry.new(seq: seq, at: event["at"], mono_ms: event["mono_ms"], dt_ms: dt,
                task: event["task"], depth: event["depth"].to_i, **attrs)
    end

    # Prefers the monotonic clock (immune to NTP steps / DST); falls back to
    # wall-clock for logs predating §4.1.
    def ts_ms(event)
      return event["mono_ms"].to_f if event["mono_ms"]
      return nil unless event["at"]

      Time.parse(event["at"]).to_f * 1000
    rescue ArgumentError, TypeError
      nil
    end

    def elapsed_ms(mono1, at1, mono2, at2)
      return (mono2 - mono1).round if mono1 && mono2

      return nil unless at1 && at2

      ((Time.parse(at2) - Time.parse(at1)) * 1000).round
    rescue ArgumentError, TypeError
      nil
    end

    def extract_text(content)
      case content
      when String
        content
      when Array
        content.map do |block|
          case block["type"]
          when "text"        then block["text"]
          when "tool_use"    then "[tool_use: #{block["name"]}]"
          when "tool_result" then "[tool_result]"
          else block.to_s
          end
        end.join("\n")
      else
        content.to_s
      end
    end

    def numeric(value)
      return nil if value.nil?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def model_label(provider, model)
      return nil if provider.nil? && model.nil?

      [ provider, model ].compact.join(" / ")
    end

    def point_cost(point)
      Pricing.cost_for(point, fallback_model: model)
    end
  end
end
