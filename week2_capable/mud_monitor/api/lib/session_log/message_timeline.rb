require "json"

module SessionLog
  # Reconstructs *what the model was actually handed* on every model call.
  #
  # The definitive source is the `request` event (boukensha logs the exact
  # `to_api_payload` body at the moment of invocation): system prompt, full tool
  # schemas, and messages in provider wire format. `system`/`tools` are logged in
  # full only when they change (the logger dedups constants), so this walker
  # carries the last value forward across `*_unchanged` events.
  #
  # Logs written before `request` landed carry only `prompt` events — a
  # reconstruction of Context#messages (role + content, no system, no tool
  # schemas, no wire transform). Those still parse: if a file has no `request`
  # events we fall back to `prompt`, and each checkpoint reports source: "prompt"
  # so the UI can say "this is a reconstruction, not the real payload".
  #
  # Either way the message array is append-only except for front-trimming
  # (compaction/clear drop from the head; the loop appends to the tail), so a
  # checkpoint's delta from its predecessor is "dropped N from the front" +
  # "appended these to the tail", with an unchanged window carried between.
  class MessageTimeline
    Checkpoint = Struct.new(
      :seq, :source,            # "request" (definitive) | "prompt" (reconstruction)
      :turn, :iteration, :at,
      :model, :max_tokens,
      :system, :system_changed, # the carried-forward system prompt + whether it changed here
      :tools, :tool_count, :tools_changed,
      :message_count, :dropped, :carried, :marker,
      :messages,                # the full array on this call
      # Authoritative token usage, from the `response` that answered this call.
      # nil when no response was logged (truncated / died mid-call).
      :input_tokens, :output_tokens, :cache_read, :cache_creation,
      :context_tokens,          # input + cache_read + cache_creation (the real prompt size)
      :context_delta,           # growth in context_tokens vs the previous checkpoint
      keyword_init: true
    )

    attr_reader :id, :path, :checkpoints

    def self.load(path)
      new(path).tap(&:parse!)
    end

    def initialize(path)
      @path        = path
      @id          = File.basename(path, ".jsonl")
      @checkpoints = []
    end

    def parse!
      request_cps = []
      prompt_cps  = []
      turn = 0
      iter = 0
      pending_req    = nil     # compaction/clear seen since the last request
      pending_prompt = nil     # …and since the last prompt (tracked separately so
                               # the two builders don't steal each other's marker)
      await_req_cp    = nil    # the request checkpoint still awaiting its response usage
      await_prompt_cp = nil    # …and the prompt checkpoint (a response answers both)
      prev_req    = []
      prev_prompt = []
      sys  = nil               # carried system prompt across *_unchanged events
      tools = nil
      tool_count = 0
      rseq = 0
      pseq = 0

      File.foreach(@path) do |line|
        line = line.strip
        next if line.empty?

        event = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        case event["phase"]
        when "turn"
          turn = event["n"].to_i
        when "iteration"
          iter = event["n"].to_i
        when "compaction"
          pending_req = pending_prompt = "compaction"
        when "clear"
          pending_req = pending_prompt = "clear"
        when "response"
          # The model's own token accounting for the call these checkpoints
          # describe. One response answers both the prompt and the request event
          # of an iteration, so it fills in whichever is still awaiting usage.
          [ await_req_cp, await_prompt_cp ].compact.each { |cp| apply_usage(cp, event) }
          await_req_cp = await_prompt_cp = nil
        when "request"
          messages = event["messages"] || []
          delta    = diff(prev_req, messages)

          sys_changed = event.key?("system")
          sys = event["system"] if sys_changed

          tools_changed = event.key?("tools")
          if tools_changed
            tools      = event["tools"]
            tool_count = event["tool_count"] || tools.size
          elsif event["tool_count"]
            tool_count = event["tool_count"]
          end

          cp = Checkpoint.new(
            seq: rseq += 1, source: "request",
            turn: turn, iteration: iter, at: event["at"],
            model: event["model"], max_tokens: event["max_tokens"],
            system: sys, system_changed: sys_changed,
            tools: tools, tool_count: tool_count, tools_changed: tools_changed,
            message_count: messages.size,
            dropped: delta[:dropped], carried: delta[:carried],
            marker: pending_req || (delta[:dropped].positive? ? "trim" : nil),
            messages: messages
          )
          request_cps << cp
          await_req_cp = cp
          prev_req     = messages
          pending_req  = nil
        when "prompt"
          messages = event["messages"] || []
          delta    = diff(prev_prompt, messages)

          cp = Checkpoint.new(
            seq: pseq += 1, source: "prompt",
            turn: turn, iteration: iter, at: event["at"],
            model: nil, max_tokens: nil,
            system: nil, system_changed: false,
            tools: nil, tool_count: event["tool_count"], tools_changed: false,
            message_count: messages.size,
            dropped: delta[:dropped], carried: delta[:carried],
            marker: pending_prompt || (delta[:dropped].positive? ? "trim" : nil),
            messages: messages
          )
          prompt_cps << cp
          await_prompt_cp = cp
          prev_prompt     = messages
          pending_prompt  = nil
        end
      end

      # Prefer the definitive request log; fall back to the reconstruction only
      # for legacy sessions that never logged one.
      @checkpoints = request_cps.any? ? request_cps : prompt_cps

      # Growth in the real prompt size from one call to the next — the number
      # that answers "watch it grow". Only spans checkpoints that actually have
      # usage (a missing response in between leaves a gap, not a fake delta).
      prev_ctx = nil
      @checkpoints.each do |cp|
        cp.context_delta = cp.context_tokens - prev_ctx if cp.context_tokens && prev_ctx
        prev_ctx = cp.context_tokens if cp.context_tokens
      end
    end

    private

    # Copy the model's authoritative token accounting onto the checkpoint the
    # response answered, and derive the real prompt size (input + both cache
    # buckets). Also backfills the model for legacy prompt-mode checkpoints,
    # which don't carry one of their own, so cost can still be priced.
    def apply_usage(cp, event)
      usage = event["usage"] || {}
      cp.input_tokens   = usage["input_tokens"].to_i
      cp.output_tokens  = usage["output_tokens"].to_i
      cp.cache_read     = usage["cache_read_input_tokens"].to_i
      cp.cache_creation = usage["cache_creation_input_tokens"].to_i
      cp.context_tokens = cp.input_tokens + cp.cache_read + cp.cache_creation
      cp.model        ||= event["model"]
    end

    # Smallest front-trim of `prev` whose remainder is a prefix of `curr`, so the
    # carried window is maximised and whatever of `curr` sticks out past it is the
    # appended tail. k == prev.size always matches, so a hard reset falls out as
    # "dropped everything, all of curr is new".
    def diff(prev, curr)
      (0..prev.size).each do |k|
        remaining = prev[k..] || []
        next unless curr[0, remaining.size] == remaining

        return { dropped: k, carried: remaining.size }
      end
      { dropped: prev.size, carried: 0 }
    end
  end
end
