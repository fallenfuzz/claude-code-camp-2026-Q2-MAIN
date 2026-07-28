require_relative "../permissions"

module Boukensha
  module Testing
    # The deterministic gate. Evaluates a scenario's `expect:` block against
    # tier-1 facts and returns one row per rule, with evidence.
    #
    # `tool_called` entries use the same `name(arg: value|value)` grammar
    # `tasks.player.allow` already uses in settings.yaml, parsed by the existing
    # `Permissions` rule parser. One grammar for "which calls do I mean", not
    # two — a scenario author who has written an allowlist already knows this
    # syntax, and a second dialect would be a second thing to get subtly wrong.
    #
    # Matching is STRICTER here than in Permissions, deliberately.
    # `Permissions#call_permitted?` lets a missing or empty argument through
    # (an absent value cannot violate an allowlist); an expectation asking for
    # `shop(action: list)` is asking whether that call was actually MADE with
    # that value, so an absent argument is a non-match.
    module Expectations
      class Error < StandardError; end

      Result = Struct.new(:kind, :rule, :ok, :detail, keyword_init: true) do
        def as_json = { kind: kind, rule: rule, ok: ok, detail: detail }.compact
      end

      KINDS = %w[tool_called tool_not_called final_room max_model_tool_calls
                 max_automatic_tool_calls max_iterations max_cost_usd max_duration_ms].freeze

      module_function

      # facts: a SessionFacts. Returns [Result].
      def evaluate(expect, facts)
        expect = expect || {}
        unknown = expect.keys.map(&:to_s) - KINDS
        raise Error, "unknown expectation#{'s' if unknown.size > 1}: #{unknown.join(', ')} (known: #{KINDS.join(', ')})" unless unknown.empty?

        results = []
        Array(expect["tool_called"]).each     { |rule| results << called(rule, facts) }
        Array(expect["tool_not_called"]).each { |rule| results << not_called(rule, facts) }
        results << final_room(expect["final_room"], facts)                   if expect.key?("final_room")
        results << at_most("max_model_tool_calls", expect["max_model_tool_calls"], facts.model_tool_calls)         if expect.key?("max_model_tool_calls")
        results << at_most("max_automatic_tool_calls", expect["max_automatic_tool_calls"], facts.automatic_tool_calls) if expect.key?("max_automatic_tool_calls")
        results << at_most("max_iterations", expect["max_iterations"], facts.iterations)                           if expect.key?("max_iterations")
        results << at_most("max_cost_usd", expect["max_cost_usd"], facts.cost_usd)                                 if expect.key?("max_cost_usd")
        results << at_most("max_duration_ms", expect["max_duration_ms"], facts.duration_ms)                        if expect.key?("max_duration_ms")
        results.compact
      end

      def passed?(results) = results.all?(&:ok)

      # ---------- rule kinds -------------------------------------------------

      def called(rule, facts)
        hit = matches(rule, facts).first
        Result.new(kind: "tool_called", rule: rule.to_s, ok: !hit.nil?,
                   detail: hit ? "called at #{hit.call_id}" : "never called")
      end

      def not_called(rule, facts)
        hits = matches(rule, facts)
        Result.new(kind: "tool_not_called", rule: rule.to_s, ok: hits.empty?,
                   detail: hits.empty? ? nil : "called at #{hits.map(&:call_id).join(', ')}")
      end

      def final_room(expected, facts)
        actual = facts.final_room
        Result.new(kind: "final_room", rule: expected.to_s,
                   ok: actual.to_s.casecmp?(expected.to_s),
                   detail: actual || "unknown (no current_room_id in the agent's memory)")
      end

      # A ceiling that cannot be checked is reported as a failure, not quietly
      # passed. `cost_usd` is nil when no response carried a price, and
      # "we did not measure it" must not read as "it was under budget".
      def at_most(kind, limit, actual)
        return Result.new(kind: kind, rule: limit.to_s, ok: false, detail: "not measured") if actual.nil?

        Result.new(kind: kind, rule: limit.to_s, ok: actual <= limit, detail: actual.to_s)
      end

      # ---------- matching ---------------------------------------------------

      # Only calls the MODEL made are matchable. The rubric is written about
      # what the agent CHOSE, and the framework's bootstrap `score`/`look` would
      # otherwise satisfy — or violate — a rule the agent had nothing to do with.
      def matches(rule, facts)
        parsed = Permissions.parse_rule(rule)
        facts.tool_calls.select do |call|
          call.model? && tool_matches?(parsed.tool, call.name) && args_match?(parsed.where, call.args)
        end
      rescue Permissions::Error => e
        raise Error, "expectation #{rule.inspect}: #{e.message}"
      end

      # A bare name matches regardless of the MCP prefix, exactly as it does in
      # an allowlist — `shop` matches `tbamud__shop`.
      def tool_matches?(wanted, actual)
        actual = actual.to_s
        wanted.to_s == actual || wanted.to_s == actual.sub(/\A.*__/, "")
      end

      def args_match?(where, args)
        args = args || {}
        where.all? do |param, pattern|
          value = args[param] || args[param.to_s] || args[param.to_sym]
          next !value.nil? && !value.to_s.strip.empty? if pattern == :any

          pattern.include?(value.to_s)
        end
      end
    end
  end
end
