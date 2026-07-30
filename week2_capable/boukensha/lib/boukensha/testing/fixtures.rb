require "yaml"
require_relative "overrides"
require_relative "map_memory"
require_relative "stage"

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
      #
      # `settings` is the per-run settings override (settings_sweep.md §2) and
      # `arm` is the label the report groups by — never nil, because a median
      # taken across `max_decisions: 4` and `max_decisions: 10` is a number
      # describing nothing and the report needs something to refuse to do that
      # with.
      # `stage` is the scenario's staged model answers (mocking_messages.md §3),
      # or nil for the ordinary case, which is every case that existed before it.
      Case = Struct.new(
        :scenario, :session_name, :player_profile, :goal, :state,
        :base_initial_state, :map_memory, :limits, :expect, :evaluation,
        :settings, :arm, :stage,
        keyword_init: true
      )

      # `gender` and `class` moved to profile.yaml, and Config#player_identity
      # is now their only reader. A state file that also sets them is a silent
      # second opinion, so it is an error rather than a losing bid.
      PROFILE_OWNED = %w[gender class player_class].freeze

      MAP_MEMORY = /\A(none|keep|copy:.+|snapshot:.+|session:.+)\z/.freeze

      # The label an arm carries when no setting was overridden at all — the
      # deployment's own configuration, which is a configuration like any other
      # and has to be named to be compared against.
      DEFAULT_ARM = "default".freeze

      # A settings override may not touch this block at ALL (settings_sweep.md
      # §6). `mcp_servers` is the agent's only source of tools, and its `mud`
      # entry carries the host, the port and — through
      # Config#apply_profile_mud_env! — the character being logged in as. A
      # scenario that could rewrite it could point a test at a different MUD or
      # play as a different character while the report went on naming the profile
      # it thought it was measuring.
      SETTINGS_REFUSED = %w[mcp_servers].freeze

      # Legitimate sweep axes that change the agent under test in ways a reader
      # skimming a report would not expect from a scenario name (§6). That is an
      # argument for saying so out loud, not for forbidding them.
      SETTINGS_LOUD = %w[memory agent].freeze

      attr_reader :dir, :profiles_dir, :settings_file, :warnings

      def initialize(dir:, profiles_dir: nil, settings_file: nil)
        @dir           = dir.to_s
        @profiles_dir  = profiles_dir || File.join(File.dirname(@dir), "profiles")
        @settings_file = settings_file || File.join(File.dirname(@dir), "settings.yaml")
        # Collected rather than warned immediately, because resolution happens
        # before the run log is open and a warning on stderr is the one artifact
        # nobody has six weeks later. The caller drains these into the log and
        # into `--dry-run`.
        @warnings      = []
      end

      def states_dir    = File.join(@dir, "states")
      def scenarios_dir = File.join(@dir, "scenarios")
      def plans_dir     = File.join(@dir, "plans")
      def reports_dir   = File.join(@dir, "reports")

      # Memory sits beside reports rather than under a profile for the same
      # reason a report does: it is a per-run artifact joined by run and session
      # id, and it exists precisely to compare runs that may not have used the
      # same profile.
      def knowledge_dir = File.join(@dir, "knowledge")
      def maps_dir      = File.join(knowledge_dir, "snapshots")

      # Retained maps subdivide by profile because retention is counted per
      # profile and a per-directory count is the cheapest way to express that.
      # Session ids are globally unique, so the subdirectory is for pruning and
      # legibility rather than for avoiding collisions.
      def session_maps_dir(profile) = File.join(knowledge_dir, "sessions", profile.to_s)

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

        # A scenario is the thing being MEASURED, so it may not change the
        # agent's configuration underneath itself: two runs of one scenario name
        # would then be incomparable with nothing saying so
        # (settings_sweep.md §2.1, §11.1). Refused rather than ignored, because
        # an override that reaches nothing is the exact failure §6.1 exists to
        # prevent.
        if doc.key?("settings")
          raise Error, "scenario #{name.inspect} sets `settings:`, which only a plan or --setting may do " \
                       "(a scenario that changed the configuration it is measured under would make two " \
                       "runs of the same scenario name incomparable)"
        end
        # Validated HERE, at load, so a malformed stage costs nothing rather
        # than being discovered by a child three minutes into a seeded run.
        begin
          Stage.validate!(Overrides.normalize(doc["stage"])) if doc["stage"]
        rescue Stage::Error => e
          raise Error, "scenario #{name.inspect}: #{e.message}"
        end
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
          refuse_stage!("plan #{name.inspect} case #{index}", entry)
        end
        refuse_stage!("plan #{name.inspect} defaults", doc["defaults"] || {})
        validate_sweep!(name, doc["sweep"])
        doc["name"] ||= name.to_s
        doc
      end

      # ---------- resolution ----------------------------------------------

      # One scenario, `batch` times, as fully-resolved cases. `overrides` is the
      # plan-case layer (empty for a bare `-ts`); `cli_state` is the `--set`
      # layer and `cli_settings` the `--setting` one.
      def resolve_scenario(name, batch: 1, overrides: {}, cli_state: {}, cli_settings: {},
                           profile: nil, map_memory: nil, arm: nil)
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

        mode = validate_map_memory!(map_memory || overrides["map_memory"] || spec["map_memory"] || "none")

        # `settings.yaml` < plan defaults < plan case < `--setting`. The first two
        # of those arrive already merged, because `resolve_plan` deep-merges
        # `defaults:` underneath each case before it gets here.
        settings = Overrides.resolve(overrides["settings"], cli_settings)
        validate_settings!(settings, label: name)

        session_base = overrides["session_name"] || spec["session_name"] || name.to_s
        label        = (arm || (settings.empty? ? DEFAULT_ARM : Overrides.describe(settings))).to_s
        # A swept case needs a session name that says which arm it is, or thirty
        # rows named `find_bakery_cold #7` describe six configurations
        # indistinguishably. Always, when there is a sweep: a plan writes ONE case
        # entry and the harness multiplies it, so whatever name the author typed
        # cannot have meant one particular arm. A hand-written §3.2 plan has no
        # `arm` here and keeps the name it was given.
        session_base = "#{session_base} (#{label})" if arm

        # Part of the arm key, not a footnote (§7). Staging is a larger
        # difference than any setting, because it changes which agent was doing
        # the thinking, and a report that averaged a staged row together with a
        # live one would be reporting a number about two different experiments.
        stage = Stage.build(spec["stage"])
        if stage
          label = "#{label} · #{stage.arm_label}"
          # §14: with one live task, five samples of that task's judgement is
          # exactly what a batch is for. With none, it is five identical runs
          # and a pass rate of 5/5 that describes no variance at all.
          if stage.fully_staged? && batch > 1
            note "#{name} stages every task and runs #{batch} times — with nothing live these are #{batch} " \
                 "identical runs, and the pass rate they produce describes no variance at all. Promote a " \
                 "task back to live, or run it once."
          end
        end

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
            evaluation:         Overrides.normalize(spec["evaluation"] || {}),
            settings:           settings,
            arm:                label,
            stage:              stage
          )
        end
      end

      # A whole plan, flattened to cases in declaration order. Plan `defaults:`
      # sit UNDER each case's own keys, which is what makes a per-case
      # `player_profile` an override rather than a conflict.
      #
      # A `sweep:` block multiplies each case by the Cartesian product of its
      # axes (settings_sweep.md §3.3), which is why the caller has to state the
      # arm count and the total before anything is seeded: six arms at `batch: 5`
      # is thirty live runs, and that is a reasonable thing to ask for and an
      # unreasonable thing to discover.
      def resolve_plan(name, cli_state: {}, cli_settings: {}, profile: nil, map_memory: nil, batch: nil)
        doc      = plan(name)
        defaults = Overrides.normalize(doc["defaults"] || {})
        arms     = sweep_arms(doc)

        cases = doc["cases"].flat_map do |entry|
          entry = Overrides.deep_merge(defaults, Overrides.normalize(entry))
          arms.flat_map do |arm|
            # The axis wins over a `settings:` the case wrote itself: a sweep IS
            # the arm, and `sweep:` is sugar over per-case settings rather than a
            # second opinion about them.
            merged = Overrides.deep_merge(entry, { "settings" => arm[:settings] })
            resolve_scenario(
              merged["scenario"],
              batch:        batch || merged["batch"] || 1,
              overrides:    merged,
              cli_state:    cli_state,
              cli_settings: cli_settings,
              profile:      profile,
              map_memory:   map_memory,
              arm:          arm[:label]
            )
          end
        end

        warn_about_arms!(cases)
        cases
      end

      # ---------- internals -------------------------------------------------

      private

      # The exact inverse of the `settings:` rule above, for the same underlying
      # reason (mocking_messages.md §7). A scenario may not change the
      # CONFIGURATION it is measured under, because that would make two runs of
      # one name incomparable. A stage changes WHAT IS BEING MEASURED — which
      # agent was doing the thinking — so it is part of the scenario's identity,
      # and a plan or a flag that could attach one to an existing scenario name
      # would produce two incomparable populations under that one name.
      def refuse_stage!(label, doc)
        return unless doc.is_a?(Hash) && doc.key?("stage")

        raise Error, "#{label} sets `stage:`, which only a scenario may do (staging changes which agent " \
                     "was doing the thinking, so it belongs to the scenario's identity — a plan that " \
                     "attached one to an existing scenario name would produce two incomparable " \
                     "populations under that name)"
      end

      # ---------- settings overrides (settings_sweep.md §6) -----------------

      # An override may only address a key path that ALREADY EXISTS in
      # `settings.yaml`. That is a real constraint rather than a schema —
      # settings are not a closed set — and it catches every typo of an existing
      # key, which is the whole population of likely mistakes.
      #
      # It has to be a constraint, because nothing downstream can catch a typo:
      # `--setting tools.navigation.limits.max_decision=10`, singular, merges
      # cleanly, is read by nothing, and produces an arm that looks like a
      # measurement of a changed configuration and is a measurement of the
      # unchanged one. `Config#dig` answers nil for an absent key and every
      # reader has a default.
      #
      # The cost is the ability to introduce a NEW key by override, which nothing
      # needs: a knob absent from the deployment's own file is a knob no reader of
      # that file knows about.
      def validate_settings!(settings, label:)
        return settings if settings.empty?

        doc = deployment_settings
        leaves = Overrides.leaf_pairs(settings)

        leaves.each do |path, _value|
          dotted = path.join(".")
          if SETTINGS_REFUSED.include?(path.first)
            raise Error, "settings override #{dotted} for #{label.inspect} touches #{path.first}, which a " \
                         "test may not change: it carries the MUD host, the port and the character being " \
                         "logged in as, so a case could play as somebody else while the report went on " \
                         "naming the profile it thought it was measuring"
          end
          next if settings_path?(doc, path)

          raise Error, "settings override #{dotted} for #{label.inspect} names no key in #{@settings_file} " \
                       "— an override may only address a key path that already exists there, because a " \
                       "misspelt one merges cleanly, is read by nothing, and produces an arm that measured " \
                       "the unchanged configuration#{settings_siblings(doc, path)}"
        end

        loud = leaves.map { |path, _| path.first }.uniq & SETTINGS_LOUD
        unless loud.empty?
          note "settings override for #{label.inspect} changes #{loud.join(', ')} — a legitimate axis, but " \
               "it changes the agent under test in a way a reader skimming a report would not expect from " \
               "a scenario name"
        end
        settings
      end

      def deployment_settings
        return @deployment_settings if defined?(@deployment_settings)

        unless File.file?(@settings_file)
          raise Error, "a settings override needs #{@settings_file} to check its key paths against, " \
                       "and that file does not exist"
        end

        @deployment_settings = Overrides.normalize(YAML.safe_load(File.read(@settings_file)) || {})
      rescue Psych::SyntaxError => e
        raise Error, "#{@settings_file}: #{e.message}"
      end

      # `key?` rather than a truthiness check, so a key present with a null value
      # is found and an absent one is not.
      def settings_path?(doc, path)
        node = doc
        path.each do |key|
          return false unless node.is_a?(Hash) && node.key?(key)

          node = node[key]
        end
        true
      end

      # What DOES exist at the deepest point the path reached, in the same
      # posture as find!'s "available:" list — a misspelt leaf is usually one
      # glance from being obvious.
      def settings_siblings(doc, path)
        node = doc
        path.each_with_index do |key, index|
          return "" unless node.is_a?(Hash)

          unless node.key?(key)
            under = index.positive? ? " under #{path[0...index].join('.')}" : ""
            return " (available#{under}: #{node.keys.map(&:to_s).sort.join(', ')})"
          end
          node = node[key]
        end
        ""
      end

      # ---------- sweep expansion (settings_sweep.md §3.3) ------------------

      def validate_sweep!(name, sweep)
        return if sweep.nil?
        raise Error, "plan #{name.inspect} has a `sweep:` that is not a mapping of key path to values" unless sweep.is_a?(Hash)

        sweep.each do |path, values|
          unless values.is_a?(Array) && !values.empty?
            raise Error, "plan #{name.inspect} sweep axis #{path.inspect} must be a non-empty list of " \
                         "values, got #{values.inspect}"
          end
        end
      end

      # One arm per point in the Cartesian product of the axes, or a single
      # unlabelled arm when there is no sweep — which is what keeps a plain plan
      # resolving exactly as it did.
      def sweep_arms(doc)
        axes = Overrides.normalize(doc["sweep"] || {})
        return [{ label: nil, settings: {} }] if axes.empty?

        names = axis_names(axes.keys)
        combos = axes.map { |path, values| values.map { |value| [path, value] } }

        combos.first.product(*combos.drop(1)).map do |pairs|
          {
            label:    pairs.map { |path, value| "#{names[path]}=#{Overrides.render(value)}" }.join(" "),
            settings: pairs.reduce({}) { |acc, (path, value)| Overrides.deep_merge(acc, Overrides.nest(path, value)) }
          }
        end
      end

      # An axis is named by the last segment of its key path — `max_decisions=10`
      # reads better than the whole dotted path — except where two axes share
      # one, as `tasks.navigator.model` and `tasks.cartographer.model` do. A
      # label that cannot tell two arms apart is worse than a verbose one.
      def axis_names(paths)
        tails = paths.map { |path| path.to_s.split(".").last }
        paths.each_with_object({}) do |path, out|
          tail = path.to_s.split(".").last
          out[path] = tails.count(tail) > 1 ? path.to_s : tail
        end
      end

      # §8.5: region declarations are earned and never overwritten, so an arm
      # running with `keep` inherits whatever the arm before it wrote. Every arm
      # of a comparison should start from the same map. A warning rather than a
      # refusal, because a sweep that accumulates deliberately is conceivable and
      # this is not the code that gets to decide it isn't.
      def warn_about_arms!(cases)
        arms = cases.map(&:arm).uniq
        return if arms.size < 2

        keeping = cases.select { |kase| kase.map_memory == "keep" }.map(&:scenario).uniq
        return if keeping.empty?

        note "#{arms.size} arms run with map_memory: keep (#{keeping.join(', ')}) — region declarations are " \
             "earned and never overwritten, so each arm inherits whatever the arm before it wrote. A " \
             "comparison wants `none` or a pinned `snapshot:`."
      end

      # Unique, because resolution runs once per case per arm: a `memory:`
      # override in a six-arm plan of five cases would otherwise say the same
      # sentence thirty times, which is how a warning stops being read.
      def note(message)
        @warnings << message unless @warnings.include?(message)
        message
      end

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

      # Checked here as well as in MapMemory, because this is the layer that
      # fails before anything is seeded: a mistyped session id in case 19 costs
      # nothing rather than eighteen real runs.
      def validate_map_memory!(mode)
        mode = mode.to_s
        raise Error, "map_memory #{mode.inspect} must be #{MapMemory::MODES}" unless MAP_MEMORY.match?(mode)

        id = mode[/\Asession:(.+)\z/, 1]
        if id && !MapMemory.session_id?(id)
          raise Error, "map_memory session id #{id.inspect} is not a session id " \
                       "(expected the form 20260729T183933Z-4caca6d5)"
        end
        mode
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
