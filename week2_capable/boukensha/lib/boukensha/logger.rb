require "json"
require "fileutils"
require "securerandom"
require "time"
require "digest"
require_relative "operation"
require_relative "telemetry"

module Boukensha
  class Logger
    DEFAULT_SESSION_DIR = "sessions".freeze

    attr_reader :session_id, :path

    DEFAULT_TASK = "player".freeze

    def initialize(session_id: nil, dir: nil, log: nil, snapshot: {}, task: DEFAULT_TASK,
                   telemetry: nil)
      @session_id = session_id || generate_session_id
      # So `Operation.wire_meta` can hand an MCP call the id of the session
      # that made it, with no session_id parameter threaded through Hooks, the
      # dispatcher, and Tools::Mcp to get there.
      Operation.session_id = @session_id
      @path       = log || File.join(dir || default_dir, "#{@session_id}.jsonl")
      @task_stack = [ task.to_s ]
      # Cumulative session-lifetime tallies. A span reports the DELTA across its
      # own interval, which is strictly cheaper than a callback per event and
      # cannot double-count a nested span — a delta over an interval is exactly
      # what nesting means.
      @counters   = Hash.new(0)
      @meters     = []
      @telemetry  = telemetry || Telemetry::Noop.new

      FileUtils.mkdir_p(File.dirname(@path))
      @log_io = File.open(@path, "a")
      write_log({ phase: "session_start" }.merge(snapshot))
    end

    # Register a counter source outside the logger — the store's CountingDb, the
    # journal's line tally. Anything answering `#counters` with a
    # { Symbol => Integer } of monotonically-increasing totals.
    #
    # A key present in the snapshot is a key SOME meter is reporting, so a span
    # in a session with no store attached omits `db_reads` entirely rather than
    # claiming zero — "we did not read" and "we cannot say" are different
    # answers and the log should not conflate them.
    def add_meter(meter)
      @meters << meter if meter.respond_to?(:counters)
      meter
    end

    # An operation span: a unit of work that started, contained other things,
    # and finished, having spent this much of what.
    #
    #   logger.operation("room_survey") { ... }
    #
    # Writes `operation_start` / `operation_end` around the block, and the id it
    # mints is what every event inside correlates on — `tool_call`,
    # `local_inference` and the journal's CDC lines all stamp
    # `operation_id` from the ambient stack, so no call site has to be handed
    # one. `parent_operation_id` is the span below it on that stack, which is
    # what makes the monitor's nesting a fact rather than a guess about
    # adjacency.
    #
    # `trigger` is inherited from the enclosing span when omitted (see
    # Operation::Frame). Returns the block's value; a raise still closes the
    # span, flagged `ok: false`, rather than leaving it open to mislabel
    # everything that follows.
    def operation(name, trigger: nil, kind: :internal, attributes: {}, root: false)
      semantic_kind = semantic_kind_for(name)
      span_attributes = {
        "session.id" => @session_id,
        "boukensha.session_id" => @session_id,
        "boukensha.task" => current_task,
        "boukensha.trigger" => trigger
      }.merge(attributes).compact
      @telemetry.in_span(name, kind: kind, attributes: span_attributes, root: root) do |span|
        Operation.open(name, trigger: trigger) do |frame|
          frame.trace_id = span.trace_id
          frame.span_id = span.span_id
          frame.telemetry_span = span
          frame.propagation_carrier = @telemetry.propagation_carrier
          write_log({ phase: "operation_start", operation_id: frame.id,
                      parent_operation_id: frame.parent_id, operation: frame.name,
                      trigger: frame.trigger, trace_id: frame.trace_id,
                      span_id: frame.span_id, otel_kind: kind.to_s,
                      semantic_kind: semantic_kind, initiator: attributes[:initiator] ||
                        attributes["boukensha.tool.initiator"],
                      attributes: span_attributes }.compact)
          started = monotonic_ms
          opened  = counter_snapshot
          ok      = true
          error   = nil
          begin
            yield frame
          rescue StandardError => e
            ok = false
            error = e
            span.record_exception(e)
            span.error!(e)
            raise
          ensure
            final = frame.attributes.merge(counter_delta(opened))
            span.set_attributes(otel_attributes(final))
            # `frame.attributes` first so nothing a call site sets through
            # `frame.set` can clobber the span's own identity/timing fields.
            write_log(frame.attributes.merge(
                        phase: "operation_end", operation_id: frame.id, operation: frame.name,
                        trace_id: frame.trace_id, span_id: frame.span_id,
                        otel_kind: kind.to_s, semantic_kind: semantic_kind,
                        attributes: final,
                        duration_ms: (monotonic_ms - started).round, ok: ok,
                        error_type: error&.class&.name
                      ).compact.merge(counter_delta(opened)))
          end
        end
      end
    end

    def semantic_kind_for(name)
      value = name.to_s
      return "invoke_agent" if value == "turn" || value.start_with?("invoke_agent ")
      return "iteration" if value == "iteration"
      return "chat" if value == "llm.generate" || value.start_with?("chat ")
      return "execute_tool" if value.start_with?("tool.") || value.start_with?("execute_tool ")
      return "after_tool" if ["after_tool", "record outcome"].include?(value)
      return "compaction" if value == "compaction"
      return "wrap_up" if value == "wrap_up"
      return "hook" if ["player_bootstrap", "bootstrap player", "position_refresh",
                        "establish position", "room_disambiguation", "room_survey",
                        "async_poll", "poll"].include?(value)
      return "state" if value.include?("state") || value.include?("render")

      "internal"
    end
    private :semantic_kind_for

    # The local ONNX token classifier that picks look candidates, priced in the
    # two currencies that are not dollars.
    #
    # `available: false` is the field that matters most: a missing artifact
    # degrades to Model::Null, which warns ONCE to stderr and then returns []
    # forever. Without this the session cannot say whether `look_candidates` is
    # empty because the model is absent or because the room had nothing worth
    # looking at — and those are opposite conclusions when you are deciding
    # whether the extractor earns its probes.
    #
    # `cost_usd: 0.0` is stated rather than omitted. The cost table has no row
    # for this model at all today, which reads as "no cost information" when the
    # truth is "free, and here is the latency it cost instead". Three LLM calls
    # used to do this job; saying $0 out loud is the measurement that replaced
    # them.
    def local_inference(model:, duration_ms:, available: true, backend: nil, artifact: nil,
                        pool: nil, kept: nil, threshold: nil, top_k: nil, reason: nil)
      @counters[:inference_ms]    += duration_ms.to_i
      @counters[:inference_calls] += 1
      write_log({
        phase: "local_inference", operation_id: Operation.current_id,
        model: model, backend: backend, artifact: artifact,
        duration_ms: duration_ms, pool: pool, kept: kept,
        threshold: threshold, top_k: top_k,
        cost_usd: 0.0, unit: "local",
        # `reason` is why it is unavailable ("no manifest at …", "model file not
        # downloaded"), which is the difference between an operator fixing the
        # install and an operator concluding the extractor does not work.
        reason: reason
      }.compact.merge(available: available))
    end

    # Bracket a delegated sub-run so its events land in THIS file, labelled with
    # the task that produced them. Without this, every delegation minted a fresh
    # logger and therefore a fresh session file, leaving neither file a complete
    # account of the turn and nothing on disk linking them (plan Amendment A).
    #
    # Reentrant: the stack keeps nesting honest if a subagent ever delegates
    # further, and `ensure` guarantees a raise inside the sub-run still closes
    # the group rather than mislabelling everything that follows.
    def task(name, snapshot: {})
      @task_stack.push(name.to_s)
      write_log({ phase: "task_start", task_name: name.to_s }.merge(snapshot))
      yield
    ensure
      write_log(phase: "task_end", task_name: name.to_s)
      @task_stack.pop
    end

    # The task currently on top of the stack — what the agent is doing *now*.
    def current_task
      @task_stack.last
    end

    def turn(n:)
      write_log(phase: "turn", n: n)
    end

    def iteration(n:, max:)
      write_log(phase: "iteration", n: n, max: max)
    end

    def limit_reached(kind:, n:, max:)
      write_log(phase: "limit_reached", kind: kind, n: n, max: max)
    end

    def turn_end(reason:, iterations:, tokens: nil)
      write_log(phase: "turn_end", reason: reason, iterations: iterations, tokens: tokens)
    end

    def prompt(messages:, tools:, context_window:)
      write_log(
        phase:          "prompt",
        message_count:  messages.size,
        messages:       messages.map { |m| serialize_message(m) },
        tool_count:     tools.size,
        tools:          tools.keys,
        context_window: context_window
      )
    end

    # The *definitive* record of what the model was handed: the exact request
    # body built by the backend (`to_api_payload`) — system prompt, full tool
    # schemas, and messages in provider wire format — logged at the moment of
    # invocation. This is distinct from `prompt`, which logs a reconstruction of
    # Context#messages (role + content) that omits the system prompt, the tool
    # schemas, and the wire transform (tool_result → user block, reasoning
    # denormalization, …). `prompt` drives the transcript; `request` is "what the
    # agent actually received".
    #
    # `system` and `tools` are effectively constant across a turn's iterations,
    # so they are logged in full only when they change from the previous request;
    # otherwise a `*_unchanged` flag stands in and the reader carries the last
    # value forward. `messages` — the part that actually grows — is always logged
    # in full.
    def request(payload:)
      payload = stringify(payload)
      messages = payload["messages"] || []

      event = {
        phase:         "request",
        model:         payload["model"],
        max_tokens:    payload["max_tokens"],
        message_count: messages.size,
        messages:      messages
      }

      merge_system!(event, payload["system"])
      merge_tools!(event, payload["tools"] || [])

      write_log(event)
    end

    def compaction(before:, dropped:, context_window:)
      write_log(phase: "compaction", before: before, dropped: dropped, context_window: context_window)
    end

    # A `/clear` wiped the conversation history. `before` is the message count at
    # the moment of the wipe (all of which were dropped) — the next `prompt`
    # snapshot starts the history over from empty. Distinct from `compaction`,
    # which only trims a prefix; a clear drops everything.
    def clear(before:)
      write_log(phase: "clear", before: before, dropped: before)
    end

    # PROVENANCE. A session contains two kinds of tool call that used to be
    # indistinguishable on disk — both `tool_call` at `task: "player"`,
    # `depth: 0`:
    #
    #   the model asked for it        initiator: "model"
    #   framework/hook code ran it    initiator: "hook"   on the model's behalf
    #
    # Without the split, a hook's cold-start `score`/`look` reads as the agent
    # checking its own sheet, and the ~1.9s that `score` blocks for reads as
    # model latency. `operation` says WHY (player_bootstrap, position_refresh,
    # room_survey, async_poll) and `trigger` says from WHICH lifecycle seam.
    #
    # `operation`/`trigger`/`operation_id` are NOT parameters: they are read
    # from the span this call is happening inside, for the same reason `task` is
    # not a parameter. They used to be threaded from Hooks through the
    # dispatcher's third `meta` argument — one call site per hop that could
    # forget them, which is how the survey's own calls could come out
    # unattributed. The ambient version cannot go dead.
    #
    # The `operation` STRING is written alongside the id even though the id is
    # what the tree is built from: it is human-readable, and it survives a log
    # whose spans were truncated mid-write.
    #
    # Returns the generated `call_id`. The matching `tool_result` carries the
    # same id, so a reader pairs the two exactly instead of guessing by
    # name+depth — which is ambiguous the moment two identical calls are in
    # flight. Every field is optional and additive: a caller outside any span
    # writes the pre-provenance event shape, and the monitor keeps its legacy
    # pairing path for files already on disk.
    def tool_call(name:, args:, initiator: nil, parent_call_id: nil)
      call_id = "call_#{SecureRandom.hex(6)}"
      write_log({
        phase: "tool_call", call_id: call_id, name: name, args: args,
        initiator: initiator, parent_call_id: parent_call_id
      }.compact)
      call_id
    end

    def tool_result(name:, result:, ok: true, error: nil, call_id: nil,
                    initiator: nil, duration_ms: nil, error_id: nil)
      # The MUD round trips a span paid for. Counted here rather than at the
      # dispatcher because this is the one place every tool result passes
      # through, hook-initiated or not. Gated on `duration_ms` so the callers
      # that use this event as a carrier for a non-tool fact (Hooks#log_conflict
      # and its `memory_conflict` records) do not inflate the round-trip count.
      if duration_ms
        @counters[:mud_calls] += 1
        @counters[:mud_ms]    += duration_ms.to_i
      end
      write_log({
        phase: "tool_result", call_id: call_id, name: name, result: result.to_s,
        ok: ok, error: error, error_id: error_id,
        initiator: initiator, duration_ms: duration_ms
      }.reject { |k, v| v.nil? && k != :error })
    end

    # What the model actually received, when it is NOT what the tool returned.
    # `Hooks#after_tool` replaces a 105-token room dump with `moved west → The
    # Reading Room` before it reaches context; the raw `tool_result` above still
    # holds the MUD's exact words (the log stops being a faithful record
    # otherwise), and this event holds the substitution. Both are useful and
    # neither is derivable from the other: the raw result debugs the parser and
    # the transport, the replacement debugs the agent's behaviour.
    def context_transform(call_id:, kind:, content:, raw_chars: nil)
      write_log({
        phase: "context_transform", call_id: call_id, kind: kind,
        raw_chars: raw_chars, content: content.to_s
      }.compact)
    end

    # State appended to the conversation by something other than the model or a
    # tool — today, the `[here]` block `before_model` renders from memory. The
    # `request` event remains the definitive wire record; this is the readable
    # explanation in the transcript, and it is what makes an assistant turn that
    # thanks us "for the context" traceable to the context it was given.
    def injected_context(kind:, content:, source: nil, changed: nil)
      write_log({
        phase: "injected_context", kind: kind, content: content.to_s,
        source: source, changed: changed
      }.compact)
    end

    # `task` is deliberately NOT a parameter here: write_log stamps it on every
    # event from the task stack, so no call site can forget it (and none can
    # disagree with another — two sources of truth for one field is how the old
    # `task:` argument ended up nil at every call site and dead in every log).
    def response(text:, usage: nil, stop_reason: nil, backend: nil)
      write_log(
        {
          phase: "response",
          text: text.to_s.strip,
          usage: usage,
          stop_reason: stop_reason
        }.merge(execution_metadata(backend: backend, usage: usage))
      )
    end

    def reasoning(text:, redacted: false)
      write_log(phase: "reasoning", text: text.to_s, redacted: redacted)
    end

    def plan(text:)
      write_log(phase: "plan", text: text.to_s.strip)
    end

    def raw(data:)
      return unless Boukensha.debug?

      write_log(phase: "raw", data: data)
    end

    def subscribe(&block)
      @subscribers ||= []
      @subscribers << block
    end

    def close
      @telemetry.force_flush(timeout: 5)
      @log_io&.close
    end

    private

    def default_dir
      File.join(Boukensha.config.profile_dir, DEFAULT_SESSION_DIR)
    end

    # The three fields every event inside a span inherits — stamped here,
    # generically, rather than at each call site (which is how `prompt`,
    # `request`, `injected_context`, `plan` and `response` ended up with no
    # `operation_id` at all: nobody had written a call site for them yet).
    # `operation_start`/`operation_end` are excluded: they carry the identity
    # of the span they OPEN or CLOSE, not the one they run inside, and already
    # set `operation_id` explicitly at their own call site in `#operation`.
    # Empty (bar operation_id, passed through as-is) at top level, which is the
    # honest record for a call the model itself chose.
    STRUCTURAL_PHASES = %w[operation_start operation_end].freeze

    def operation_stamp(event)
      phase       = (event[:phase] || event["phase"]).to_s
      existing_id = event[:operation_id] || event["operation_id"]
      return { operation_id: existing_id } if STRUCTURAL_PHASES.include?(phase)

      frame = Operation.current
      return { operation_id: existing_id } unless frame

      {
        operation:    event[:operation] || event["operation"] || frame.name,
        trigger:      event[:trigger] || event["trigger"] || frame.trigger,
        operation_id: existing_id || frame.id
      }.compact
    end

    # The logger's own tallies plus every registered meter's, summed. Meters
    # report session-lifetime totals; only the difference across a span is ever
    # published.
    def counter_snapshot
      @meters.each_with_object(@counters.dup) do |meter, out|
        (meter.counters || {}).each { |key, value| out[key] = out[key].to_i + value.to_i }
      rescue StandardError
        # A meter that raises costs its numbers, never the span reporting them.
        next
      end
    end

    def counter_delta(opened)
      counter_snapshot.each_with_object({}) do |(key, value), out|
        out[key] = value - opened[key].to_i
      end
    end

    def monotonic_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000

    def write_log(event)
      now = Time.now
      @telemetry.capture_event(event)
      correlation = @telemetry.current_ids
      @log_io.puts JSON.generate(event.merge(correlation).merge(operation_stamp(event)).merge(
        session_id: @session_id,
        task:       @task_stack.last,
        depth:      @task_stack.size - 1,
        at:         now.iso8601(3),
        mono_ms:    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      ))
      @log_io.flush
      @subscribers&.each { |s| s.call(event) }
    end

    def otel_attributes(attributes)
      attributes.each_with_object({}) do |(key, value), out|
        next if value.nil?

        name = key.to_s.include?(".") ? key.to_s : "boukensha.#{key}"
        out[name] = value
      end
    end

    def generate_session_id
      "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}"
    end

    def serialize_message(msg)
      { role: msg.role, content: msg.content }
    end

    # JSON-round-trip a symbol-keyed payload into the string-keyed shape it will
    # have on disk, so dedup comparisons below see the same thing the reader will.
    def stringify(payload)
      JSON.parse(JSON.generate(payload))
    end

    # Log the system prompt in full only when it changed since the last request;
    # otherwise mark it unchanged and let the reader carry the last value forward.
    def merge_system!(event, system)
      if system == @last_system && defined?(@last_system)
        event[:system_unchanged] = true
      else
        event[:system]  = system
        @last_system    = system
      end
    end

    # Same treatment for the tool schemas, keyed on a content hash so a large
    # unchanged toolset isn't re-serialized on every iteration.
    def merge_tools!(event, tools)
      sig = Digest::SHA256.hexdigest(JSON.generate(tools))
      if sig == @last_tools_sig
        event[:tools_unchanged] = true
        event[:tool_count]      = @last_tool_count
      else
        event[:tools]        = tools
        event[:tool_count]   = tools.size
        @last_tools_sig      = sig
        @last_tool_count     = tools.size
      end
    end

    def execution_metadata(backend:, usage:)
      return {} unless backend || usage

      tokens = usage_tokens(usage)
      metadata = {
        provider: provider_name(backend),
        model: backend&.model,
        usage_unit: backend&.respond_to?(:usage_unit) ? backend.usage_unit : nil,
        usage_level: backend&.respond_to?(:usage_level) ? backend.usage_level : nil,
        input_tokens: tokens[:input],
        output_tokens: tokens[:output],
        cost_usd: estimate_cost(backend, tokens)
      }
      metadata.compact
    end

    # Computed inline rather than delegating to Backends::Base#provider_name:
    # this call site has always tolerated a bare test double for `backend` (any
    # object with a `.model`), and requiring a `provider_name` method on it
    # would break every one of those fakes across the suite.
    def provider_name(backend)
      return nil unless backend

      backend.class.name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def usage_tokens(usage)
      usage ||= {}
      {
        input: first_integer(usage, "input_tokens", "prompt_tokens", "promptTokenCount", "prompt_eval_count"),
        output: first_integer(usage, "output_tokens", "completion_tokens", "candidatesTokenCount", "eval_count")
      }
    end

    def first_integer(hash, *keys)
      keys.each do |key|
        value = hash[key] || hash[key.to_sym]
        return Integer(value) unless value.nil?
      end
      nil
    rescue ArgumentError, TypeError
      nil
    end

    def estimate_cost(backend, tokens)
      return nil unless backend&.respond_to?(:estimate_cost)
      return nil unless tokens[:input] && tokens[:output]

      backend.estimate_cost(input_tokens: tokens[:input], output_tokens: tokens[:output])
    end
  end
end
