require "json"

# Renders a SessionLog::MessageTimeline::Checkpoint into the JSON the messages
# sidebar consumes.
#
# `source` tells the UI whether this is the definitive request payload
# ("request") or a legacy reconstruction ("prompt"). `system`/`tools` are
# carried-forward constants; `*_changed` marks the call where they changed.
#
# Token accounting is split into two kinds, clearly labelled for the UI:
#   * `tokens` / `input_cost_usd` — AUTHORITATIVE, from the model's own usage on
#     the response that answered this call. `tokens.context` is the real prompt
#     size (input + both cache buckets); `context_delta` is its growth since the
#     previous call — the "watch it grow" number.
#   * `composition` — an ESTIMATE of how those tokens split across system /
#     tools / messages, from a chars-per-token heuristic over the payload, then
#     scaled to the authoritative context total so the parts sum to the whole.
class MessageCheckpointSerializer
  CHARS_PER_TOKEN = 4.0

  def self.call(checkpoint)
    input_cost = SessionLog::Pricing.input_cost(
      model:          checkpoint.model,
      input:          checkpoint.input_tokens.to_i,
      cache_read:     checkpoint.cache_read.to_i,
      cache_creation: checkpoint.cache_creation.to_i
    ) if checkpoint.context_tokens

    {
      seq:            checkpoint.seq,
      source:         checkpoint.source,
      turn:           checkpoint.turn,
      iteration:      checkpoint.iteration,
      at:             checkpoint.at,
      model:          checkpoint.model,
      max_tokens:     checkpoint.max_tokens,
      system:         checkpoint.system,
      system_changed: checkpoint.system_changed,
      tools:          checkpoint.tools,
      tool_count:     checkpoint.tool_count,
      tools_changed:  checkpoint.tools_changed,
      message_count:  checkpoint.message_count,
      dropped:        checkpoint.dropped,
      carried:        checkpoint.carried,
      marker:         checkpoint.marker,
      tokens:         token_summary(checkpoint),
      input_cost_usd: input_cost,
      composition:    composition(checkpoint, input_cost),
      messages:       checkpoint.messages.map { |m| serialize_message(m) }
    }
  end

  # Authoritative usage from the model, or nil counts when no response was logged.
  def self.token_summary(cp)
    {
      input:          cp.input_tokens,
      output:         cp.output_tokens,
      cache_read:     cp.cache_read,
      cache_creation: cp.cache_creation,
      context:        cp.context_tokens,
      context_delta:  cp.context_delta
    }
  end

  # Estimated split of the prompt across its three parts. Raw estimates come
  # from a chars/token heuristic; when the authoritative context total is known
  # they are scaled to sum to it, and priced at the call's blended input rate so
  # the component costs sum to `input_cost_usd`. `estimated: true` on every row —
  # this is guidance, not billing.
  def self.composition(cp, input_cost)
    raw = {
      "system"   => estimate(cp.system),
      "tools"    => estimate(cp.tools),
      "messages" => estimate(cp.messages)
    }
    total = raw.values.sum
    return raw.map { |label, tokens| { label: label, tokens: tokens, estimated: true } } if total.zero?

    context = cp.context_tokens
    scale   = context ? context.to_f / total : nil
    blended = (input_cost && context && context.positive?) ? input_cost / context : nil

    raw.map do |label, tokens|
      scaled = scale ? (tokens * scale).round : tokens
      {
        label:    label,
        tokens:   scaled,
        share:    tokens.to_f / total,
        cost_usd: blended && (scaled * blended),
        estimated: true
      }
    end
  end

  # A rough token count for a value: chars of its serialized form over a fixed
  # chars-per-token ratio. Deliberately simple — proportions matter here, not
  # exactness, and the result is scaled to the model's real count anyway.
  def self.estimate(value)
    return 0 if value.nil?

    text = value.is_a?(String) ? value : JSON.generate(value)
    (text.length / CHARS_PER_TOKEN).ceil
  end

  def self.serialize_message(msg)
    { role: msg["role"], content: msg["content"] }
  end
end
