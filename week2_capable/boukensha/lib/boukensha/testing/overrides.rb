module Boukensha
  module Testing
    # The merge that resolves a case's starting state out of four layers
    # (batch_sesssion_testing.md §2.4), later wins:
    #
    #   1. states/<base_initial_state>.yml          the file
    #   2. scenario.initial_state_overrides         deep merge
    #   3. plan case                                deep merge
    #   4. CLI  --set money.gold=0                  deep merge, scalars only
    #
    # The rules are stated once, here, so nobody has to guess which one applies:
    #
    # - **Mappings deep-merge.** `money: {gold: 0}` over
    #   `money: {gold: 5000, bank: 10000}` yields `{gold: 0, bank: 10000}`.
    # - **Sequences replace.** An `inventory:` in an override wipes the base
    #   list. This is the only rule that is a judgement call, and it goes this
    #   way because "replace" is the one you can always express in terms of the
    #   other, and it has no ordering ambiguity.
    # - **Append forms exist for when you meant append.** `inventory+:` and
    #   `equipment+:` — any `key+` — concatenate onto the base list instead.
    # - **`null` deletes a key.** `bank: ~` removes the field entirely, which is
    #   a different claim from `bank: 0`.
    #
    # `base_initial_state` is deliberately NOT handled here: it is chosen, not
    # merged. Naming a different state file at any layer discards the previous
    # file wholesale, and only the overrides accumulate (see Fixtures).
    module Overrides
      class Error < StandardError; end

      APPEND_SUFFIX = "+".freeze

      module_function

      # Fold every layer in order. Nil layers are skipped so a caller never has
      # to compact its own list.
      def resolve(*layers)
        layers.compact.reduce({}) { |acc, layer| deep_merge(acc, normalize(layer)) }
      end

      def deep_merge(base, override)
        base     = normalize(base)
        override = normalize(override)
        return base if override.empty?

        out = base.dup
        override.each do |key, value|
          if key.end_with?(APPEND_SUFFIX) && key.length > 1
            target = key[0..-2]
            out[target] = Array(out[target]) + Array(value)
          elsif value.nil? && override.key?(key)
            # Explicit null deletes. `override.key?` matters: a key that is
            # simply absent leaves the base alone, which is the whole point of
            # a partial override.
            out.delete(key)
          elsif value.is_a?(Hash) && out[key].is_a?(Hash)
            out[key] = deep_merge(out[key], value)
          else
            out[key] = value
          end
        end
        out
      end

      # `--set money.gold=0` → { "money" => { "gold" => 0 } }. Scalars only —
      # a CLI flag that could inject a nested structure would be a second,
      # worse YAML with no file to review.
      def parse_set(assignment)
        path, raw = assignment.to_s.split("=", 2)
        raise Error, "--set expects KEY=VALUE, received #{assignment.inspect}" if raw.nil? || path.to_s.strip.empty?

        keys = path.strip.split(".")
        raise Error, "--set key #{path.inspect} is empty" if keys.empty? || keys.any? { |k| k.strip.empty? }

        keys.reverse.reduce(coerce(raw)) { |value, key| { key => value } }
      end

      def parse_sets(assignments)
        Array(assignments).map { |a| parse_set(a) }.reduce({}) { |acc, h| deep_merge(acc, h) }
      end

      # YAML-ish scalar coercion, kept narrow on purpose: integers, floats,
      # booleans, and the two spellings of null. Everything else is a string,
      # so `--set session_name=cold map` cannot become something surprising.
      def coerce(raw)
        case raw.to_s.strip
        when /\A-?\d+\z/          then Integer(raw)
        when /\A-?\d+\.\d+\z/     then Float(raw)
        when "true"               then true
        when "false"              then false
        when "null", "~", ""      then nil
        else raw.to_s
        end
      end

      # String-keyed, recursively — YAML gives strings, a scenario author may
      # write symbols in a test, and a merge that treats "money" and :money as
      # different keys silently drops half of an override.
      def normalize(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), out| out[k.to_s] = normalize(v) }
        when Array then value.map { |v| normalize(v) }
        else value
        end
      end
    end
  end
end
