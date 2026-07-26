module Boukensha
  class Agent
    # Default iteration ceiling. The *enforced* value comes from the
    # max_iterations: constructor arg (sourced from Config at the run/repl path),
    # which falls back to this constant. 0 (or nil) disables the ceiling.
    MAX_ITERATIONS = 25

    # The wind-down call is deliberately short and cheap.
    WRAP_UP_OUTPUT_TOKENS = 400
    WRAP_UP_DIRECTIVE = <<~MSG.strip
      You have reached your action limit for this turn. Do not call any more tools.
      Briefly summarize what you accomplished, what is still unfinished, and the
      single next action you would take.
    MSG

    def initialize(context:, registry:, builder:, client:, logger: Logger.new, hooks: nil,
                   max_iterations: MAX_ITERATIONS, max_turn_tokens: nil, max_output_tokens: nil,
                   root_trace: true, turn: 1)
      @context           = context
      @registry          = registry
      @builder           = builder
      @client            = client
      @logger            = logger
      # A null object by default, so an agent with no hooks runs the identical
      # code path rather than a branchier one.
      @hooks             = hooks || Hooks.new
      @max_iterations    = (max_iterations || MAX_ITERATIONS).to_i
      @max_turn_tokens   = max_turn_tokens.to_i      # 0 = disabled
      @max_output_tokens = max_output_tokens
      @iteration         = 0
      @root_trace        = root_trace
      # The turn number the REPL already tracks and logs (`@logger.turn`)
      # BEFORE this span opens — passed in so the `invoke_agent` span can title
      # itself "Turn N" at open rather than the reader having to walk its
      # entries to find one. 1 for callers (single-shot run, task delegation)
      # that never call `@logger.turn` at all: there is exactly one.
      @turn              = turn
    end

    def run
      @context.reset_turn_tokens
      # The `turn` span is the trace id's one child that spans the whole call:
      # every iteration, the compaction check, and wrap_up re-parent under it
      # for free, because Operation reads the ambient stack rather than being
      # handed a parent explicitly.
      agent_name = @logger.current_task
      @logger.operation("invoke_agent #{agent_name}", root: @root_trace, attributes: {
        "gen_ai.operation.name" => "invoke_agent",
        "gen_ai.agent.name" => agent_name,
        "boukensha.max_iterations" => @max_iterations,
        "boukensha.max_turn_tokens" => @max_turn_tokens,
        "boukensha.turn.n" => @turn
      }) do |turn_frame|
        compact_if_needed
        @hooks.before_turn(context: @context)

        loop do
          # Two independent ceilings; stop at whichever trips first. Limits are
          # *trigger thresholds*, not hard caps: when one is reached we stop
          # starting new work iterations and make exactly one terminal wind-down
          # call (counted in tokens, but not as another iteration) — a sibling
          # of the iteration spans above it, never one itself.
          if iteration_limit_reached?
            @logger.limit_reached(kind: "max_iterations", n: @iteration, max: @max_iterations)
            return wrap_up("max_iterations")
          end
          if token_limit_reached?
            @logger.limit_reached(kind: "max_tokens", n: @context.turn_tokens, max: @max_turn_tokens)
            return wrap_up("max_tokens")
          end

          @iteration += 1
          # `outcome` is nil while the turn keeps going (a tool_use round) and
          # the final text once the model stops — so a single non-nil check
          # after the span closes decides whether to loop again or return,
          # without duplicating the return sites inside the block.
          outcome = @logger.operation("iteration", attributes: { "boukensha.iteration.n" => @iteration }) do
            @logger.iteration(n: @iteration, max: @max_iterations)
            # Before EVERY model call, not just the first: the agent moves
            # inside this loop, so anything that reconciles "where am I" has to
            # run per iteration or the model reasons about the room it left.
            @hooks.before_model(context: @context)

            parsed = perform_chat_exchange(**call_opts)

            if parsed[:stop_reason] == "tool_use"
              handle_tool_calls(parsed[:content])
              nil
            else
              text = parsed[:text]
              turn_frame.set("boukensha.turn.reason" => "completed",
                             "boukensha.turn.iterations" => @iteration,
                             "boukensha.turn.tokens" => @context.turn_tokens)
              @logger.turn_end(reason: "completed", iterations: @iteration, tokens: @context.turn_tokens)
              @context.add_message(:assistant, text)
              @hooks.after_turn(context: @context, text: text)
              text
            end
          end
          return outcome if outcome
        end
      end
    end

    private

    def iteration_limit_reached?
      @max_iterations.positive? && @iteration >= @max_iterations
    end

    def token_limit_reached?
      @max_turn_tokens.positive? && @context.turn_tokens >= @max_turn_tokens
    end

    # Per-call options shared by every model round-trip of the turn.
    def call_opts
      @max_output_tokens ? { max_output_tokens: @max_output_tokens } : {}
    end

    # Add this call's input+output to the cumulative turn total (the spend
    # budget) and refresh the known context size from input_tokens (compaction
    # pressure). The trigger is evaluated on pre-wrap-up spend; the reported
    # total includes the wind-down call too.
    def record_usage(response)
      usage = response["usage"] || {}
      @context.add_turn_tokens(usage["input_tokens"], usage["output_tokens"])
      @context.update_tokens(usage["input_tokens"].to_i)
    end

    def compact_if_needed
      return unless @context.needs_compaction?

      @logger.operation("compaction") do
        before  = @context.current_tokens
        dropped = @context.compact_messages!
        @logger.compaction(before: before, dropped: dropped, context_window: @context.context_window)
      end
    end

    # The `chat` span, widened to the whole exchange (work_attribution.md /
    # session_story_tree.md §Phase 1.2): everything from the point the request
    # is finalized through the point the response is recorded lives inside it,
    # so the span's window matches what a reader means by "the model call" —
    # gen_ai semconv's own definition of `chat`. Previously it bracketed only
    # `@client.call`, which is adjacent to nothing: no event fell inside it, so
    # the one span a reader most wants to open was guaranteed empty.
    #
    # Yields `frame` so the caller can log injected context / prompt / request
    # before the wire call and reasoning / response after it, all inside the
    # span. Model/provider attributes are set at open, before the block runs,
    # so an interrupted exchange still reports what it was calling.
    def chat_operation
      backend  = @builder.backend
      provider = backend.respond_to?(:provider_name) ? backend.provider_name : nil
      @logger.operation("chat #{backend&.model}", kind: :client, attributes: {
        "gen_ai.operation.name" => "chat",
        "gen_ai.provider.name" => provider,
        "gen_ai.request.model" => backend&.model,
        "boukensha.backend" => provider
      }) do |frame|
        frame.set(provider: provider, model: backend&.model,
                  iteration: @iteration, tools_advertised: @context.advertised_tools.size,
                  context_tokens: @context.current_tokens)
        yield frame
      end
    end

    # The actual network round trip, timed on its own so the span can report
    # BOTH numbers instead of losing one: "the exchange took 1.9s" (the span's
    # own duration) and "1.73s of that was on the wire" (`boukensha.wire_ms`).
    # `work_attribution.md §2` deliberately excluded our own request/response
    # serialization from measured model time, and widening the span must not
    # quietly re-include it — this is what keeps that promise.
    def call_and_measure(frame, **opts)
      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @client.call(**opts)
      wire_ms  = since_ms(started)
      usage    = response["usage"] || {}
      frame.set(
        "gen_ai.usage.input_tokens" => usage["input_tokens"],
        "gen_ai.usage.output_tokens" => usage["output_tokens"],
        "gen_ai.response.finish_reasons" => Array(response["stop_reason"]).compact,
        "gen_ai.client.operation.duration" => wire_ms / 1000.0,
        "boukensha.wire_ms" => wire_ms
      )
      response
    end

    # One full model exchange: injected context, the readable `prompt`
    # reconstruction, the definitive `request` payload, the timed wire call,
    # reasoning, and the response (a `plan` + tool-use placeholder, or the
    # final text) — all inside one `chat` span. Returns the parsed response
    # plus `:text` when the turn ended, so the iteration loop can decide
    # whether to dispatch tool calls or return without re-opening the span.
    def perform_chat_exchange(**opts)
      parsed = nil
      chat_operation do |frame|
        log_injected_context
        # request_messages/advertised_tools, not messages/tools: this event
        # is the readable view of the call, and it would be lying if it
        # showed the transcript without the state block or a tool the turn
        # policy hid.
        @logger.prompt(messages: @context.request_messages, tools: @context.advertised_tools,
                       context_window: @context.context_window)
        # The definitive record: the exact body about to go on the wire.
        # Built from the same (context, opts) the client will use a line
        # later, so it is byte-identical to what @client.call sends.
        @logger.request(payload: @builder.to_api_payload(**opts))

        response = call_and_measure(frame, **opts)
        @logger.raw(data: response)
        parsed = @builder.parse_response(response)
        record_usage(response)
        log_reasoning(parsed[:content])

        if parsed[:stop_reason] == "tool_use"
          log_tool_use_response(parsed[:content], response)
        else
          text = extract_text(parsed[:content])
          @logger.response(text: text, usage: response["usage"], stop_reason: parsed[:stop_reason], backend: @builder.backend)
          parsed[:text] = text
        end
      end
      parsed
    end

    # The preamble text (if any) and the tool-use placeholder — logged inside
    # the `chat` span, since both are part of what the model returned on this
    # exchange, not part of dispatching the calls it asked for.
    def log_tool_use_response(content, response)
      preamble = extract_text(content)
      @logger.plan(text: preamble) unless preamble.strip.empty?
      tool_calls = content.select { |b| b["type"] == "tool_use" }
      # `backend:` matters here as much as on the final response: in an
      # agentic loop most of the turn's spend rides on tool-use placeholders,
      # and without it those calls land in the cost breakdown as
      # provider/model "unknown" — the per-task cost table Amendment A exists
      # to enable.
      @logger.response(text: "(tool use — #{tool_calls.size} call#{'s' if tool_calls.size != 1})",
                       usage: response["usage"], stop_reason: "tool_use", backend: @builder.backend)
    end

    # One final, tools-disabled model call so the agent ends the turn in
    # character rather than aborting. Runs *outside* the counted loop: it never
    # re-checks the limits (so it cannot re-trigger) and does not increment
    # @iteration, though its tokens still count toward the reported turn total.
    # Falls back to a deterministic message if the call fails.
    def wrap_up(reason)
      @logger.operation("wrap_up") do
        @context.add_message(:user, WRAP_UP_DIRECTIVE)
        wrap_opts = { tools: [], max_output_tokens: WRAP_UP_OUTPUT_TOKENS }
        text = nil
        chat_operation do |frame|
          @logger.request(payload: @builder.to_api_payload(**wrap_opts))
          response    = call_and_measure(frame, **wrap_opts)
          parsed_wrap = @builder.parse_response(response)
          text        = extract_text(parsed_wrap[:content])
          text        = fallback_message(reason) if text.strip.empty?
          record_usage(response)
          @logger.response(text: text, usage: response["usage"], stop_reason: parsed_wrap[:stop_reason], backend: @builder.backend)
        end
        @logger.turn_end(reason: reason, iterations: @iteration, tokens: @context.turn_tokens)
        @context.add_message(:assistant, text)
        @hooks.after_turn(context: @context, text: text)
        text
      end
    rescue ApiError
      msg = fallback_message(reason)
      @logger.turn_end(reason: reason, iterations: @iteration, tokens: @context.turn_tokens)
      @context.add_message(:assistant, msg)
      @hooks.after_turn(context: @context, text: msg)
      msg
    end

    def fallback_message(reason)
      "I reached my #{@max_iterations}-action limit for this turn before finishing " \
      "(#{reason}). Ask me to continue and I'll pick up from here."
    end

    def extract_text(content)
      content.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
    end

    def since_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    # What `before_model` just appended to the conversation on the model's
    # behalf — the `[here]` state block, in the MUD deployment. The `request`
    # event remains the definitive wire record; this one exists so the
    # transcript itself can answer "what context is it thanking us for?", which
    # previously required opening the request drawer and reading a payload.
    #
    # `changed:` is what lets the monitor collapse an unchanged refresh: the
    # block is re-rendered every iteration and is usually identical to the last.
    def log_injected_context
      block = @context.state_block.to_s
      return if block.strip.empty?

      @logger.injected_context(kind: "state_block", content: block, source: "memory",
                               changed: block != @last_state_block)
      @last_state_block = block
    end

    # Emit one `reasoning` event per reasoning block so the viewer can show the
    # model's thinking as a first-class step. Empty, non-redacted blocks are
    # skipped to avoid noise (a redacted/omitted block still renders, since it
    # tells the viewer "the model thought here").
    def log_reasoning(content)
      content.each do |block|
        next unless block["type"] == "reasoning"

        redacted = block["redacted"] == true
        text     = block["text"].to_s
        next if text.strip.empty? && !redacted

        @logger.reasoning(text: text, redacted: redacted)
      end
    end

    # The preamble and placeholder are already logged (inside the `chat` span,
    # by `log_tool_use_response`) by the time this runs — dispatching the
    # calls the model asked for is a separate concern from the exchange that
    # asked for them, and happens outside that span as a sibling of it.
    def handle_tool_calls(content)
      tool_calls = content.select { |b| b["type"] == "tool_use" }

      @context.add_message(:assistant, content)

      # The last moment the output that arrived during inference is still in the
      # buffer. The first dispatch below drains it.
      @hooks.before_tools(calls: tool_calls, context: @context)

      tool_calls.each { |block| dispatch_tool_call(block) }
    end

    # One model-chosen tool call, spanned end to end — dispatch, the hook's
    # `after_tool` reaction, and the substitution it may produce. Wrapping this
    # (rather than just the registry dispatch) is what attributes the 153
    # journal lines `after_tool`'s downstream store/journal writes used to leave
    # unattributed: they run inside this span now, off the ambient stack, with
    # no change to Journal or Store.
    def dispatch_tool_call(block)
      name   = block["name"]
      args   = block["input"]
      use_id = block["id"]

      tool_name = short_tool_name(name)
      @logger.operation("execute_tool #{tool_name}", kind: :client, attributes: {
        "gen_ai.operation.name" => "execute_tool",
        "gen_ai.tool.name" => tool_name,
        "boukensha.tool.full_name" => name,
        "boukensha.tool.initiator" => "model",
        "boukensha.tool.call_id" => use_id
      }) do |tool_frame|
        # `initiator: "model"` is the counterpart to the `"hook"` the hook
        # dispatcher stamps: these are the calls the model actually chose, and
        # a session that cannot tell them apart reports a hook's bootstrap
        # `score` as the agent being tool-hungry.
        call_id = @logger.tool_call(name: name, args: args, initiator: "model")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ok = true
        begin
          result = @registry.dispatch(name, args)
          @logger.tool_result(name: name, result: result, ok: true, call_id: call_id,
                              initiator: "model", duration_ms: since_ms(started))
        rescue StandardError => e
          ok     = false
          tool_frame.record_error(e)
          error_id = Boukensha.error_log.record(
            e, component: "agent", boundary: "tool_dispatch",
            context: { tool: name, call_id: call_id }
          )
          result = "ERROR: #{e.class}: #{e.message}"
          @logger.tool_result(name: name, result: result, ok: false, error: e.message,
                              error_id: error_id, call_id: call_id,
                              initiator: "model", duration_ms: since_ms(started))
        end

        # Deliberately AFTER @logger.tool_result and BEFORE add_message: the
        # session log keeps the MUD's exact words (mud_monitor stops being a
        # faithful record otherwise), and only the model's copy is replaced. A
        # hook never gets to rewrite a failure — it never sees one.
        if ok
          replacement = @logger.operation("after_tool") do
            @hooks.after_tool(name: name, args: args, result: result, context: @context)
          end
          if replacement
            # The substitution used to be visible only by diffing the
            # transcript against the request drawer, which is how a movement
            # card could show a full room dump while the model demonstrably saw
            # `moved west → The Reading Room`. Both halves are now on the
            # record, correlated by call_id, and neither replaces the other.
            @logger.context_transform(call_id: call_id, kind: "tool_result_replacement",
                                      raw_chars: result.to_s.length, content: replacement)
            result = replacement
          end
        end

        @context.add_message(:tool_result, result.to_s, tool_use_id: use_id)
      end
    end

    # `tbamud__move` → `move`. Matches the web viewer's `shortToolName` — the
    # prefix is constant across a session and earns no space in a span name.
    def short_tool_name(name)
      name.to_s.sub(/\A.*__/, "")
    end
  end
end
