require "yaml"
require_relative "overrides"

module Boukensha
  module Testing
    # Loading and validation for everything under `<boukensha_dir>/tests/`:
    #
    #   states/*.yml       a shareable initial world
    #   scenarios/**/*.yml one test case: goal + starting state + rubric
    #   plans/*.yml        a batched suite of scenarios with overrides
    #
    # Note this is the ROOT config dir, not the profile dir — scenarios and
    # states are shared across profiles, and a scenario names the profile it
    # wants.
    #
    # Everything here fails at LOAD time with a sentence. The alternative is
    # discovering that a cleric state was applied to a warrior twenty minutes
    # into a batch, as a refusal deep inside a telnet exchange.
    class Fixtures
      class Error < StandardError; end

      # A single resolved case: everything one child process needs, with no
      # further file reads and no further merging.
      Case = Struct.new(
        :scenario, :session_name, :player_profile, :goal, :state,
        :base_initial_state, :map_memory, :limits, :expect, :evaluation,
        keyword_init: true
      )

      # `gender` and `class` moved to profile.yaml, and Config#player_identity
      # is now their only reader. A state file that also sets them is a silent
      # second opinion, so it is an error rather than a losing bid.
      PROFILE_OWNED = %w[gender class player_class].freeze

      MAP_MEMORY = /\A(none|keep|copy:.+|snapshot:.+)\z/.freeze

      attr_reader :dir, :profiles_dir

      def initialize(dir:, profiles_dir: nil)
        @dir          = dir.to_s
        @profiles_dir = profiles_dir || File.join(File.dirname(@dir), "profiles")
      end

      def states_dir    = File.join(@dir, "states")
      def scenarios_dir = File.join(@dir, "scenarios")
      def plans_dir     = File.join(@dir, "plans")
      def reports_dir   = File.join(@dir, "reports")
      def maps_dir      = File.join(states_dir, "maps")

      def scenario_names = names_under(scenarios_dir)
      def plan_names     = names_under(plans_dir)
      def state_names    = names_under(states_dir)

      # ---------- individual documents ------------------------------------

      def state(name)
        doc = load_yaml(find!(states_dir, name, "state"))
        bad = PROFILE_OWNED.select { |key| doc.key?(key) }
        unless bad.empty?
          raise Error, "state #{name.inspect} sets #{bad.join(', ')}, which belong to profile.yaml " \
                       "(Config#player_identity is their only reader)"
        end
        doc
      end

      def scenario(name)
        doc = load_yaml(find!(scenarios_dir, name, "scenario"))
        raise Error, "scenario #{name.inspect} has no goal" if doc["goal"].to_s.strip.empty?
        doc["scenario"] = name.to_s
        doc
      end

      def plan(name)
        doc   = load_yaml(find!(plans_dir, name, "plan"))
        cases = doc["cases"]
        raise Error, "plan #{name.inspect} has no `cases:` list" unless cases.is_a?(Array) && !cases.empty?

        # Every scenario a plan names is resolved BEFORE anything is seeded, so
        # a typo in case 19 costs nothing rather than eighteen real runs.
        cases.each_with_index do |entry, index|
          raise Error, "plan #{name.inspect} case #{index} is not a mapping" unless entry.is_a?(Hash)
          raise Error, "plan #{name.inspect} case #{index} names no scenario" if entry["scenario"].to_s.strip.empty?
          find!(scenarios_dir, entry["scenario"], "scenario")
        end
        doc["name"] ||= name.to_s
        doc
      end

      # ---------- resolution ----------------------------------------------

      # One scenario, `batch` times, as fully-resolved cases. `overrides` is the
      # plan-case layer (empty for a bare `-ts`); `cli` is the `--set` layer.
      def resolve_scenario(name, batch: 1, overrides: {}, cli_state: {}, profile: nil, map_memory: nil)
        spec      = scenario(name)
        overrides = Overrides.normalize(overrides)
        batch     = [batch.to_i, 1].max

        # `base_initial_state` is CHOSEN, not merged: naming a different file at
        # a later layer discards the earlier one wholesale. Only the
        # `initial_state_overrides` accumulate.
        base_name = overrides["base_initial_state"] || spec["base_initial_state"]
        base      = base_name ? state(base_name) : {}

        state = Overrides.resolve(
          base,
          spec["initial_state_overrides"],
          overrides["initial_state_overrides"],
          cli_state
        )

        player_profile = profile || overrides["player_profile"] || spec["player_profile"]
        raise Error, "scenario #{name.inspect} names no player_profile and none was given" if player_profile.to_s.empty?

        validate_class!(base_name, base, player_profile) if base_name
        validate_state!(base_name || name, state)

        mode = map_memory || overrides["map_memory"] || spec["map_memory"] || "none"
        raise Error, "map_memory #{mode.inspect} must be none | keep | copy:<profile> | snapshot:<name>" unless MAP_MEMORY.match?(mode.to_s)

        session_base = overrides["session_name"] || spec["session_name"] || name.to_s

        (1..batch).map do |index|
          Case.new(
            scenario:           name.to_s,
            # A batch of one keeps the bare name: "find_bakery #1" reads as the
            # first of several when there are no several.
            session_name:       batch > 1 ? "#{session_base} ##{index}" : session_base.to_s,
            player_profile:     player_profile.to_s,
            goal:               spec["goal"].to_s,
            state:              state,
            base_initial_state: base_name,
            map_memory:         mode.to_s,
            limits:             Overrides.normalize(spec["limits"] || {}),
            expect:             Overrides.normalize(spec["expect"] || {}),
            evaluation:         Overrides.normalize(spec["evaluation"] || {})
          )
        end
      end

      # A whole plan, flattened to cases in declaration order. Plan `defaults:`
      # sit UNDER each case's own keys, which is what makes a per-case
      # `player_profile` an override rather than a conflict.
      def resolve_plan(name, cli_state: {}, profile: nil, map_memory: nil, batch: nil)
        doc      = plan(name)
        defaults = Overrides.normalize(doc["defaults"] || {})

        doc["cases"].flat_map do |entry|
          entry = Overrides.deep_merge(defaults, Overrides.normalize(entry))
          resolve_scenario(
            entry["scenario"],
            batch:      batch || entry["batch"] || 1,
            overrides:  entry,
            cli_state:  cli_state,
            profile:    profile,
            map_memory: map_memory
          )
        end
      end

      # ---------- internals -------------------------------------------------

      private

      # Scenarios may be nested (`scenarios/**/*.yml`), so a name is matched
      # against the basename anywhere under the directory as well as against a
      # relative path. Ambiguity is an error rather than a coin flip.
      def find!(dir, name, kind)
        base    = File.basename(name.to_s, ".yml")
        matches = Dir.glob(File.join(dir, "**", "*.yml")).select do |path|
          File.basename(path, ".yml") == base ||
            path == File.join(dir, "#{name}.yml")
        end.uniq

        if matches.empty?
          raise Error, "no #{kind} named #{base.inspect} under #{dir} " \
                       "(available: #{names_under(dir).join(', ')})"
        end
        if matches.size > 1
          raise Error, "#{kind} #{base.inspect} is ambiguous: #{matches.join(', ')}"
        end
        matches.first
      end

      def names_under(dir)
        return [] unless File.directory?(dir)

        Dir.glob(File.join(dir, "**", "*.yml")).map { |p| File.basename(p, ".yml") }.sort
      end

      def load_yaml(path)
        doc = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
        raise Error, "#{path} must contain a YAML mapping" unless doc.is_a?(Hash)

        Overrides.normalize(doc)
      rescue Psych::SyntaxError => e
        raise Error, "#{path}: #{e.message}"
      end

      # A guardrail, not configuration. The seeder's own comment warns that a
      # dagger is rejected by class restrictions; a cleric state applied to a
      # warrior profile otherwise fails as a refusal deep inside a telnet
      # exchange, minutes in.
      def validate_class!(state_name, doc, profile)
        required = doc["requires_class"]
        return if required.to_s.strip.empty?

        actual = profile_class(profile)
        return if actual.to_s == required.to_s

        raise Error, "state #{state_name.inspect} requires_class #{required.inspect} " \
                     "but profile #{profile.inspect} is #{actual.inspect}"
      end

      def profile_class(profile)
        path = File.join(@profiles_dir, profile.to_s, "profile.yaml")
        raise Error, "profile #{profile.inspect} has no profile.yaml at #{path}" unless File.file?(path)

        doc = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
        doc.dig("player", "class")
      end

      def validate_state!(label, state)
        bad = PROFILE_OWNED.select { |key| state.key?(key) }
        raise Error, "resolved state for #{label.inspect} sets #{bad.join(', ')}; those come from profile.yaml" unless bad.empty?

        if state.key?("location")
          loc = state["location"]
          raise Error, "state #{label.inspect} location must be a positive room vnum, got #{loc.inspect}" unless loc.is_a?(Integer) && loc.positive?
        end
        state
      end
    end
  end
end
