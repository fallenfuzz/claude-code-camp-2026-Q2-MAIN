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
                 max_automatic_tool_calls max_iterations max_cost_usd max_duration_ms
                 max_no_progress_calls max_destination_repeats max_rooms_outside_scope
                 region_named region_split region_split_at_room no_provisional_regions
                 journal_op journal_op_not].freeze

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
        # Two ceilings on movement that bought nothing, both read off `move_to`'s
        # `answered` journal event. `max_model_tool_calls` bounds how much the
        # session spent; these bound how much of it turned into coverage, which
        # is the distinction run 20260731T140528Z-34c846bf passed every existing
        # budget rule while failing.
        results << at_most("max_no_progress_calls", expect["max_no_progress_calls"], facts.no_progress_calls)      if expect.key?("max_no_progress_calls")
        results << at_most("max_destination_repeats", expect["max_destination_repeats"], facts.max_destination_repeats) if expect.key?("max_destination_repeats")
        # A third ceiling, and it measures somewhere rather than how much:
        # `rooms_known_delta` says forty-one and cannot say that fifteen of them
        # were countryside. Counted off recorded crossings rather than off region
        # labels (staying_in_town.md §13), so it is deterministic, free, and
        # attributable to the leg that caused it rather than to whichever call a
        # judge's digest happened to make legible.
        results << at_most("max_rooms_outside_scope", expect["max_rooms_outside_scope"], facts.rooms_outside_scope) if expect.key?("max_rooms_outside_scope")
        Array(expect["region_named"]).each   { |label| results << region_named(label, facts) }
        Array(expect["journal_op"]).each     { |op| results << journal_op(op, facts) }
        Array(expect["journal_op_not"]).each { |op| results << journal_op_not(op, facts) }
        results << region_split(expect["region_split"], facts)                       if expect.key?("region_split")
        results << region_split_at_room(expect["region_split_at_room"], facts)       if expect.key?("region_split_at_room")
        results << no_provisional_regions(expect["no_provisional_regions"], facts)   if expect.key?("no_provisional_regions")
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

      # ---------- regions (mocking_messages.md §9) ---------------------------
      #
      # Every rule below is a projection of the post-run knowledge database or
      # of the navigation journal, which is the whole point: the region cases
      # were gradeable only by the judge, as prose, and half of what the rubrics
      # ask is mechanical.

      # Case-insensitive, matching `final_room`, because a label is prose the
      # model wrote and "Bridge Quarter" and "bridge quarter" are the same
      # declaration.
      def region_named(label, facts)
        labels = facts.region_labels
        ok     = labels.any? { |actual| actual.to_s.casecmp?(label.to_s) }
        Result.new(kind: "region_named", rule: label.to_s, ok: ok,
                   detail: labels.empty? ? "no regions" : labels.join(", "))
      end

      # `false` is as useful as `true` here and is NOT the default: a
      # large-but-coherent region that the cartographer declined to split is a
      # correct outcome, and asserting it was the thing §9 says there was no way
      # to say.
      def region_split(expected, facts)
        splits = facts.region_splits
        Result.new(kind: "region_split", rule: expected.to_s, ok: !splits.empty? == !!expected,
                   detail: splits.empty? ? "no boundary declared this session" : describe_splits(splits))
      end

      # Placement, not occurrence. A boundary on the wrong edge is the failure
      # the case is written about, and it passes every count-based rule.
      def region_split_at_room(expected, facts)
        splits = facts.region_splits
        ok     = splits.any? { |split| split[:room_id].to_i == expected.to_i }
        Result.new(kind: "region_split_at_room", rule: expected.to_s, ok: ok,
                   detail: splits.empty? ? "no boundary declared this session" : describe_splits(splits))
      end

      # A `⟨from …⟩` label is provenance, not a claim, and one still standing at
      # the end is a region nobody ever named.
      def no_provisional_regions(expected, facts)
        left = facts.provisional_region_labels
        Result.new(kind: "no_provisional_regions", rule: expected.to_s, ok: left.empty? == !!expected,
                   detail: left.empty? ? nil : left.join(", "))
      end

      # `move_to.region_split_declined` — stream and op, spelled as the journal
      # spells them. A dotted name rather than the `name(arg: value)` grammar
      # because there is no argument to match on: a journal op is an occurrence,
      # and `count:` belongs to the tripwires rather than here.
      def journal_op(op, facts)
        seen = facts.journal_ops[op.to_s]
        Result.new(kind: "journal_op", rule: op.to_s, ok: seen.positive?,
                   detail: seen.positive? ? "#{seen}×" : "never")
      end

      def journal_op_not(op, facts)
        seen = facts.journal_ops[op.to_s]
        Result.new(kind: "journal_op_not", rule: op.to_s, ok: seen.zero?,
                   detail: seen.positive? ? "#{seen}×" : nil)
      end

      def describe_splits(splits)
        splits.map { |s| "#{s[:region]} at ##{s[:room_id]} #{s[:room]} (#{s[:direction]})" }.join("; ")
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
