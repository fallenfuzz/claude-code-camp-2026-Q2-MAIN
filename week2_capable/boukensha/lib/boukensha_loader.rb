# BoukenshaLoader resolves which step folder and config directory to use, then
# boots the REPL.
#
# Each setting is resolved independently in this order:
#   1. BOUKENSHA_PATH / BOUKENSHA_DIR environment variable
#   2. boukensha_path / boukensha_dir in ~/.boukensharc
#   3. The bundled lib / ~/.boukensha default
#
# ~/.boukensharc is YAML:
#   boukensha_path: ~/Sites/boukensha/09_global_executable
#   boukensha_dir: ~/projects/mybot/.boukensha
# A bare single-line path (the pre-step-9 format) is still accepted and is
# treated as boukensha_path.
#
# --no-tui falls back to the plain terminal REPL (no charm-ruby).
#
# Examples:
#   boukensha                                                              # uses bundled lib + ~/.boukensha
#   BOUKENSHA_PATH=~/Sites/boukensha/04_api_client boukensha              # loads step 4
#   BOUKENSHA_DIR=~/projects/mybot/.boukensha boukensha                   # custom config dir
#   boukensha --no-tui                                                     # plain REPL, no TUI
require "yaml"

module BoukenshaLoader
  PROFILE_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
  # Absolute path to this gem's own bundled boukensha lib.
  BUNDLED_LIB = File.expand_path("../boukensha.rb", __FILE__)

  def self.rc_file
    File.expand_path("~/.boukensharc")
  end

  def self.load_rc
    return {} unless File.exist?(rc_file)

    parsed = YAML.safe_load(
      File.read(rc_file),
      permitted_classes: [],
      aliases: false
    )

    case parsed
    when Hash
      parsed
    when String
      # Backward compatibility with the original single-path format.
      { "boukensha_path" => parsed }
    when nil
      {}
    else
      abort "boukensha: #{rc_file} must contain a YAML mapping"
    end
  rescue Psych::SyntaxError => e
    abort "boukensha: invalid YAML in #{rc_file}: #{e.message}"
  end

  def self.expand_rc_path(path)
    return nil unless path.is_a?(String)
    return nil if path.strip.empty?

    File.expand_path(path, File.dirname(rc_file))
  end

  def self.resolve
    rc = load_rc

    # Apply this before requiring the selected implementation. An explicit
    # environment variable always wins over the rc file.
    rc_config_dir = expand_rc_path(rc["boukensha_dir"])
    ENV["BOUKENSHA_DIR"] = rc_config_dir if !ENV["BOUKENSHA_DIR"] && rc_config_dir
    source = ENV["BOUKENSHA_PATH"] || expand_rc_path(rc["boukensha_path"])
    return BUNDLED_LIB unless source

    dir = File.expand_path(source)
    main = File.join(dir, "lib", "boukensha.rb")
    return main if File.exist?(main)

    abort <<~MSG
      boukensha: no lib/boukensha.rb found at:
             #{dir}
             Check BOUKENSHA_PATH or #{rc_file}.
    MSG
  end

  # The resolved .boukensha directory. `resolve` has already applied the rc
  # file to ENV by the time anything below runs, so this is the one expression
  # every path in this file agrees on.
  def self.root_dir
    File.expand_path(ENV["BOUKENSHA_DIR"] || File.join(Dir.home, ".boukensha"))
  end

  def self.profiles
    root = root_dir
    base = File.join(root, "profiles")
    return [] unless File.directory?(base)

    Dir.children(base).select do |name|
      PROFILE_PATTERN.match?(name) && File.file?(File.join(base, name, "profile.yaml"))
    end.sort_by(&:downcase)
  end

  def self.resolve_profile!
    requested = extract_profile_argument || ENV["BOUKENSHA_PROFILE"]
    available = profiles
    if requested.nil? || requested.empty?
      abort "boukensha: select a profile with --profile NAME or BOUKENSHA_PROFILE.\nAvailable profiles: #{available.join(', ')}"
    end
    abort "boukensha: invalid profile name #{requested.inspect}" unless PROFILE_PATTERN.match?(requested)

    actual = available.find { |name| name.casecmp?(requested) }
    abort "boukensha: profile #{requested.inspect} not found.\nAvailable profiles: #{available.join(', ')}" unless actual

    apply_profile!(actual)
  end

  # Point this process's config at `name`, with the same containment check
  # `resolve_profile!` performs. Split out because the test harness resolves a
  # profile from a scenario file rather than from ARGV, and must not have to
  # reimplement the check to do it.
  def self.apply_profile!(name)
    available = profiles
    actual    = available.find { |candidate| candidate.casecmp?(name.to_s) }
    abort "boukensha: profile #{name.inspect} not found.\nAvailable profiles: #{available.join(', ')}" unless actual

    root = root_dir
    dir = File.expand_path(File.join(root, "profiles", actual))
    profiles_root = File.expand_path(File.join(root, "profiles")) + File::SEPARATOR
    abort "boukensha: profile resolves outside profiles directory" unless dir.start_with?(profiles_root)
    ENV["BOUKENSHA_PROFILE"] = actual
    ENV["BOUKENSHA_PROFILE_DIR"] = dir
    actual
  end

  def self.extract_profile_argument
    if ARGV.delete("--list-profiles")
      puts profiles
      exit 0
    end
    extract_option("--profile")
  end

  # Pull `--flag VALUE` out of ARGV and return VALUE, or nil when absent.
  # Aliases are tried in order, so `-ts` and `--test-scenario` are one call.
  def self.extract_option(*names)
    names.each do |flag|
      index = ARGV.index(flag)
      next unless index
      abort "boukensha: #{flag} requires a value" unless ARGV[index + 1]
      return ARGV.slice!(index, 2).last
    end
    nil
  end

  # Repeatable `--flag KEY=VALUE`, collected in the order given so a later
  # occurrence wins in the merge downstream.
  def self.extract_repeated_option(*names)
    out = []
    loop do
      value = extract_option(*names)
      break unless value
      out << value
    end
    out
  end

  def self.extract_flag(*names)
    names.map { |flag| !ARGV.delete(flag).nil? }.any?
  end

  def self.load_and_start_repl
    main = resolve

    # The test harness owns profile resolution (a scenario names the profile it
    # wants, and a plan can name a different one per case), so `--profile` stops
    # being mandatory the moment a test flag is present. Parsed before
    # `resolve_profile!` for exactly that reason.
    test_options = extract_test_arguments

    resolve_profile! unless test_options
    step_dir = File.dirname(File.dirname(main))

    puts "[boukensha] loading from: #{step_dir}" if ENV["BOUKENSHA_DEBUG"]

    require main

    unless Boukensha.respond_to?(:repl)
      abort <<~MSG
        boukensha: the step at #{step_dir}
               does not support the interactive REPL (added in step 7).
               Run its examples directly, e.g.:
                 ruby #{step_dir}/examples/*.rb
               Or point BOUKENSHA_PATH at step 7 or later.
      MSG
    end

    if test_options
      # Loaded relative to the RESOLVED implementation, never `require_relative`.
      # This file may be the installed gem's copy while `main` resolved to a
      # checkout via `boukensha_path` — the whole point of the rc file. A
      # `require_relative` here would then pull the GEM's testing tree, whose
      # own `require_relative "../permissions"` reopens
      # `Boukensha::Permissions` and `Tasks::Base` on top of the checkout's,
      # redefining constants and methods from a different version of the
      # library that is already running. That is the warning storm, and the
      # half of it that is not warnings is a silently mismatched agent.
      require File.join(File.dirname(main), "boukensha", "testing")
      exit Boukensha::Testing::CLI.new(test_options, root_dir: root_dir).run
    end

    # --no-tui falls back to the plain terminal REPL (no charm-ruby).
    no_tui = ARGV.delete("--no-tui")
    session_name = extract_option("--session-name")

    Boukensha.repl(
      tui: !no_tui,
      launch: Boukensha::Launch.interactive(
        profile: ENV["BOUKENSHA_PROFILE"], session_name: session_name, config: Boukensha.config
      ),
      &mud_agent_setup
    )
  end

  # Test-mode arguments, or nil when this is an ordinary interactive launch.
  # Extracted from ARGV before anything is required so the branch is decided
  # without loading the framework.
  #
  #   boukensha -ts find_bakery                  # one case
  #   boukensha --test-scenario find_bakery
  #   boukensha -ts find_bakery --batch 20       # same scenario, 20 times
  #   boukensha -tsp banking                     # a plan
  def self.extract_test_arguments
    # Internal: one child process running exactly one case (§5.2). Checked
    # first because it is the one form that must never be confused with a
    # user-typed flag.
    if (payload = extract_option("--test-case"))
      return { mode: :case, payload: payload }
    end

    listing = extract_flag("--list-scenarios") ? :scenarios : (extract_flag("--list-plans") ? :plans : nil)
    return { mode: :list, kind: listing } if listing

    if (name = extract_option("--snapshot-map"))
      # `--from-session <id>` promotes a RETAINED session map instead of the
      # profile's current one, which is the only way to pin the map of a run
      # that has already been overwritten by whatever ran after it.
      return { mode: :snapshot_map, name: name, profile: extract_option("--profile"),
               from_session: extract_option("--from-session") }
    end

    scenario = extract_option("-ts", "--test-scenario")
    plan     = extract_option("-tsp", "--test-scenario-plan")
    return nil unless scenario || plan

    {
      mode:       plan ? :plan : :scenario,
      name:       plan || scenario,
      # `-batch` is accepted alongside `--batch` because that is the spelling
      # the brief was written in, and a flag that silently means nothing is
      # worse than one extra alias.
      batch:      extract_option("--batch", "-batch")&.to_i,
      profile:    extract_option("--profile"),
      set:        extract_repeated_option("--set"),
      map_memory: extract_option("--map-memory"),
      report:     extract_option("--report"),
      no_judge:   extract_flag("--no-judge"),
      dry_run:    extract_flag("--dry-run"),
      # §5.4. `--quiet` still writes the run log file; it only stops the echo,
      # because the file is the artifact and the echo is the convenience.
      quiet:      extract_flag("--quiet"),
      verbose:    extract_flag("--verbose", "-v")
    }
  end

  # The MUD wiring, as a proc both the REPL and a headless test case can be
  # built with. It was inline in `load_and_start_repl` and therefore reachable
  # only from the REPL, which meant `Boukensha.run` produced an agent with no
  # hooks, no memory and no navigation tools — an agent a test session could
  # not honestly be compared against. Extracted verbatim: the harness reaches
  # into production code by SHARING this setup rather than reimplementing it,
  # which is the only version where a test session is genuinely the same agent
  # as a real one.
  #
  def self.mud_agent_setup
    # Every tool the player has comes from settings.yaml's `mcp_servers:` block.
    # It used to have one native tool as well — `inspect_room`, which it called
    # to get the current room back as JSON — and it does not any more.
    #
    # The reason is in the session logs. 11 surveys covered 8 distinct rooms:
    # 27% of them re-derived a room the agent had already been told about, at
    # ~5 MUD round trips each, because nothing let it know it had been there.
    # And every result was a tool_result, so it sat in the transcript forever
    # and was re-sent on every following API call.
    #
    # So room state stops being something the model asks for and becomes
    # something it is given: `Mud::Hooks` reconciles position against SQLite
    # before each model call and renders one small, always-current state block.
    # A revisit now costs zero round trips and zero accumulated tokens. The
    # `look`/`exits`/`consider`/`examine` sequence still exists — it is
    # `Mud::RoomSurvey`, it still runs under its own allowlist, and it runs only
    # for a room the agent has genuinely never stood in.
    #
    # This glue is deployment-specific, which is why it lives at the entrypoint
    # and not in the framework core: boukensha is an MCP host that ships no
    # tools and knows nothing about MUDs. `Hooks` is the seam that keeps that
    # true.
    #
    # Note the MUD_* env override was dropped upstream. A spawned server
    # inherits this process's environment, so exporting MUD_HOST still reaches
    # the daemon, but only for keys its `env:` block doesn't set: config now
    # wins over the environment, where it used to lose.
    proc do
      # Captured out of the DSL so the hook's own MUD calls append to the
      # player's session file instead of opening one file per room visited
      # (plan Amendment A).
      parent = logger
      cfg    = Boukensha.config

      # Built once per session, not per room: the dispatcher resolves the
      # allowlist and MCP registry, and the extractor loads a ~40MB ONNX graph.
      #
      # This dispatcher is a SEPARATE Registry from the player's, which is what
      # keeps the hook's own poll/look from re-entering after_tool and
      # recursing — and what keeps `look` off the player's tool surface while
      # remaining reachable here.
      #
      # `initiator: "hook"` labels everything that goes through here as work
      # the framework did on the model's behalf. Without it the session log
      # shows the cold-start `score` and `look` as player tool calls, which is
      # how a 1.9s blocking MUD read came to look like model latency.
      name       = Boukensha::Mud::RoomSurvey::NAME
      call_tool  = Boukensha.tool_dispatcher(name, logger: parent, initiator: "hook")
      # The logger is what turns the classifier from an unmeasured ~10ms into a
      # line in the session that says what it scored, what it kept, and whether
      # the weights were installed at all.
      candidates = Boukensha::Extractors.look_candidates(logger: parent)

      begin
        store = Boukensha::Mud::Memory::Store.for_dir(cfg.profile_dir)
        at_exit { store.close rescue nil }
        # Registered as a counter source, so every operation span reports the
        # rows it read and wrote. The writes themselves were always logged — as
        # CDC, in the journal — but nothing connected "the survey wrote 3
        # entities and 4 exits" to the survey in the session transcript.
        parent&.add_meter(store)

        # The store's time-series sibling: an append-only jsonl progression log
        # in `.boukensha/journal/`, sharing the session file's id so telnet /
        # manager / session / journal all join on one key. A failure here must
        # not cost the agent its memory, so it is best-effort.
        journal = begin
          j = Boukensha::Journal.new(session_id: parent&.session_id)
          at_exit { j.close rescue nil }
          # Generic CDC: every Store mutation emits a delta through this journal.
          store.journal = j
          # …and the count of those deltas is reported per span, so the gap
          # between rows written and lines appended is visible rather than
          # implied.
          parent&.add_meter(j)
          j
        rescue StandardError => e
          Boukensha.error_log.record(e, component: "journal", boundary: "setup")
          warn "[boukensha] #{e.message} — continuing without progression journal"
          nil
        end

        store.set_player_identity!(**cfg.player_identity)

        # Read-only: plans a route over the room graph already in `store`,
        # never moves the character and never touches the MUD. Registered as
        # a plain native tool (RunDSL#tool) so it is gated by
        # tasks.player.allow exactly like any MCP tool — see
        # docs/plans/week_2/plan_route.md §8.
        # The `# Navigation` prompt section was cut to policy only
        # (boundaries_revised.md §7): guidance about what a result MEANS
        # belongs here and in the tool's own output, where it is read at the
        # moment it applies, rather than in 290 permanent words of system
        # prompt restating six status names.
        #
        # It is still REGISTERED here, and it is no longer on the player's
        # allowlist (move_to.md §3, §10): `move_to` owns the plan-then-walk
        # sequence now, and leaving `plan_route` on the surface next to it would
        # reintroduce the fork that design exists to remove. Registration is
        # what `Permissions` filters, so a tool listed here and absent from
        # `tasks.player.allow` is simply not on the model's surface — the same
        # arrangement `tbamud__look` has had since the room survey stopped being
        # a tool.
        tool "plan_route",
             description: "Plan a route to a known place, landmark, or thing using only what you " \
                          "have already explored. Never moves you and performs no MUD actions. " \
                          "Returns `known` (a path to somewhere you have stood — walk it with " \
                          "move_to), `arrived`, `unreachable`, `exhausted`, or, when the " \
                          "destination is not on your map, the whole set of unexplored exits in " \
                          "distance bands with the names the MUD printed. That set is ordered by " \
                          "arithmetic, which knows nothing about what the names mean — read them " \
                          "and choose, rather than taking the first. Each group shows the walk to " \
                          "the room it leaves from.",
             parameters: {
               destination: { type: "string",
                 description: "Place, landmark, or thing to find, e.g. 'bakery' or 'Temple Square'." },
               scope: { type: "string", enum: %w[region world],
                 description: "Where to look for something not yet on your map. 'region' (the " \
                              "default) confines the search to the place you are standing in and " \
                              "everything within it; 'world' lifts that. Travel to a place you " \
                              "have already stood in is never scoped." }
             } do |destination:, scope: "region"|
          Boukensha::Mud::Navigation::PlanRouteTool.call(store: store, destination: destination, scope: scope)
        end

        # The two declaration tools — boundaries_revised.md §2. Both are
        # read-mostly store writes with zero MUD I/O, registered as native
        # tools so they are gated by tasks.player.allow exactly like plan_route.
        #
        # They are two tools rather than one with a mode flag because the agent
        # has to MEAN one or the other, and §9 records what goes wrong when it
        # picks the second while meaning the first.
        tool "name_region",
             description: "Say what the place you are standing in is called. Renames the region " \
                          "you are already in — usually one still carrying a machine-made " \
                          "⟨from …⟩ label — and clears its unconfirmed mark. Creates no boundary, " \
                          "because nothing moved. Use this when you have worked out what the place " \
                          "you have been walking through IS. It renames the WHOLE region you are " \
                          "standing in, so check the room count it reports back. Naming it " \
                          "something that already exists merges the two.",
             parameters: {
               region: { type: "string", description: "What this place is called, e.g. 'Midgaard'." },
               within: { type: "string",
                 description: "Optional. The larger place this one sits inside, by name; created " \
                              "if it does not exist yet." },
               description: { type: "string",
                 description: "Optional. What this place is like, in your own words." }
             } do |region:, within: nil, description: nil|
          Boukensha::Mud::Navigation::RegionTools.name_region(
            store: store, region: region, within: within, description: description
          )
        end

        tool "split_region",
             description: "Say that a DIFFERENT place starts in the room you are standing in. The " \
                          "boundary is the edge you first walked into this room by, exactly: the " \
                          "room behind you keeps its region, and this room plus everything you " \
                          "first reached through it becomes the new one. Call it in the FIRST room " \
                          "of the new place — called deep inside, it puts the boundary on an " \
                          "interior edge. The edge it used is printed back to you every time.",
             parameters: {
               region: { type: "string", description: "What the new place is called, e.g. 'The Great Field'." },
               within: { type: "string",
                 description: "Optional. The larger place this one sits inside, by name; created " \
                              "if it does not exist yet." },
               description: { type: "string",
                 description: "Optional. What this place is like, in your own words." },
               reason: { type: "string",
                 description: "Optional. What made you say a new place starts here — the one claim " \
                              "someone reviewing a wrong boundary needs to see." }
             } do |region:, within: nil, description: nil, reason: nil|
          Boukensha::Mud::Navigation::RegionTools.split_region(
            store: store, region: region, within: within, description: description, reason: reason
          )
        end

        # The walking subsystem's OWN slice — `tools.navigation.allow`, which is
        # where `tbamud__move` lives now (move_to.md §3).
        #
        # This used to be `->(name, args) { self.call_tool(name, **args) }`: the
        # PLAYER's registry, which is the only reason `tbamud__move` had to stay
        # on `tasks.player.allow`. Dropping it from that list without moving it
        # would make `Registry#tool` never register it, and the walk would raise
        # `UnknownToolError` on step 1.
        #
        # Hiding it behind `turn_policy` instead does not work either:
        # `Registry#dispatch` checks the turn policy on every call
        # (registry.rb:42-44) and the walk runs inside a model iteration, so a
        # policy withholding `move` would block the subsystem's own steps.
        #
        # The precedent is `tools.room_survey.allow`, where `tbamud__look` is
        # granted to the survey and appears nowhere on the player's surface.
        nav_call_tool = Boukensha.tool_dispatcher(
          Boukensha::Mud::Navigation::MoveTo::NAVIGATION_SLICE, logger: parent, initiator: "hook"
        )

        mud_hooks = Boukensha::Mud::Hooks.new(
          store: store,
          call_tool: call_tool,
          look_candidates: candidates,
          logger: parent,
          journal: journal,
          # Default off for a session of observation: pinning `move` to the
          # exits line cannot be WRONG, but tbaMUD omits closed doors from that
          # line, and a mitigation deserves to be watched before it is trusted.
          turn_policy: cfg.dig(:memory, :turn_policy) == true
        )
        hooks mud_hooks

        # The ONLY movement tool on the player's surface — move_to.md §2.
        #
        # `plan_route`, `execute_route` and `tbamud__move` all moved behind it.
        # Every mechanism that previously pointed the agent at batched movement
        # was advisory: `.boukensha/prompts/player/system.md` already asked it to
        # call `plan_route` first "rather than picking exits off the `[here]`
        # block one at a time", and the agent obeyed on iteration 1 of
        # essentially every session and then drifted. This puts the reasoning on
        # the code path instead of requesting it.
        #
        # The navigator and cartographer are built only when settings.yaml
        # declares them, which is what makes §9's delivery order runnable: the
        # known branch ships and can be measured with no subagent at all, and the
        # region judgement can be observed in the logs before it is allowed to
        # write.
        move_to = Boukensha::Mud::Navigation::MoveTo.new(
          store: store, call_tool: nav_call_tool, hooks: mud_hooks,
          navigator: (Boukensha::Mud::Navigation::Reasoners.navigator(logger: parent) if cfg.tasks(:navigator).any?),
          cartographer: (Boukensha::Mud::Navigation::Reasoners.cartographer(logger: parent) if cfg.tasks(:cartographer).any?),
          limits: cfg.dig(:tools, Boukensha::Mud::Navigation::MoveTo::NAVIGATION_SLICE, :limits),
          # Default ON. Set `tools.navigation.act_on_place: false` to keep the
          # field in the schema and out of the store — §9 step 5's observation
          # window, and the switch to flip if renaming ever goes wrong in a batch.
          act_on_place: cfg.dig(:tools, Boukensha::Mud::Navigation::MoveTo::NAVIGATION_SLICE, :act_on_place) != false,
          logger: parent, journal: journal
        )

        tool "move_to",
             description: "Travel to a place, landmark, or thing — the only way to move. Walks " \
                          "there over what you have already explored when the destination is on " \
                          "your map, and explores towards it when it is not, several rooms per " \
                          "call. Reconciles position and watches for interrupting events between " \
                          "every step, and stops early — reporting where it got to — if something " \
                          "worth reacting to happens, if the way is blocked, or if it runs out of " \
                          "its own travel budget. Call it again to continue.",
             parameters: {
               destination: { type: "string",
                 description: "Where you want to be, in your own words, e.g. 'the bakery', " \
                              "'Temple Square', or 'the mayor'." },
               scope: { type: "string", enum: %w[region world],
                 description: "Where to explore when the destination is not on your map. 'region' " \
                              "(the default) stays in the place you are standing in; 'world' lifts " \
                              "that. Travel to somewhere you have already stood is never scoped, so " \
                              "this only matters when exploring. Use 'world' when you have been told " \
                              "every remaining lead leaves this place, or when what you are looking " \
                              "for is by its nature somewhere else." }
             } do |destination:, scope: "region"|
          move_to.call(destination: destination, scope: scope)
        end
      rescue Boukensha::Mud::Memory::Store::Unavailable => e
        Boukensha.error_log.record(e, component: "mud_hooks_setup", boundary: "memory_store")
        # No memory is a degraded agent, not a dead one: it explores exactly as
        # it did before this feature existed.
        warn "[boukensha] #{e.message} — continuing without room memory"
      end
    end
  end

  # One headless case: the same agent the REPL builds, handed one goal and run
  # to completion. `Boukensha.run` already does exactly this; what it lacked
  # was the MUD setup, which is now `mud_agent_setup` above.
  #
  # `on_progress:` — called once per iteration with the running tool-call count
  # and cost. The agent turn is the longest single stretch of a case and the one
  # that can legitimately take a minute, so without this a run log goes quiet
  # exactly where a reader most needs it not to (§5.4). It rides on
  # `Logger#subscribe`, which already exists and already sees every event — no
  # new callback plumbed through the agent loop.
  #
  # `limits:` — the scenario's own `limits:` block, as a hash of strings. Two of
  # its keys are agent ceilings and are applied here; `wall_timeout_s` is the
  # parent's and is not. Before move_to.md §4.5 this parameter did not exist,
  # which meant a scenario's declared budget was logged, asserted against, and
  # never actually imposed — cases ran under the settings.yaml defaults and the
  # reports compared them to a limit nothing was enforcing.
  def self.run_case(goal:, launch: nil, max_output_tokens: nil, on_progress: nil, limits: nil)
    setup  = mud_agent_setup
    limits = (limits || {}).transform_keys(&:to_s)
    Boukensha.run(task: goal, launch: launch, max_output_tokens: max_output_tokens,
                  max_iterations: agent_limit(limits, "max_iterations"),
                  max_turn_tokens: agent_limit(limits, "max_turn_tokens")) do
      # Explicit receiver: this block is `instance_eval`d on `RunDSL`, so a bare
      # call would resolve there and not here.
      BoukenshaLoader.attach_progress(logger, on_progress) if on_progress
      # The MUD setup runs in this same DSL context, so it registers its tools
      # and hooks exactly as it does for the REPL.
      instance_eval(&setup)
    end
  end

  # One agent ceiling out of a scenario's limits block, or nil for "leave the
  # configured default alone". A limit that cannot be read as an integer is
  # dropped rather than passed on as a zero: `Agent` treats 0 as "disabled", so
  # a typo'd budget would silently REMOVE the ceiling it meant to tighten.
  def self.agent_limit(limits, key)
    value = limits[key]
    return nil if value.nil?

    Integer(value)
  rescue ArgumentError, TypeError
    warn "[boukensha] limits.#{key} = #{value.inspect} is not an integer — using the configured default"
    nil
  end

  # Fold the event stream down to the three numbers a watcher wants. Hook calls
  # are excluded from the count for the same reason they are everywhere else:
  # the figure is meant to track what the MODEL is doing.
  def self.attach_progress(logger, on_progress)
    tools = 0
    cost  = 0.0
    logger.subscribe do |event|
      phase = event[:phase] || event["phase"]
      case phase
      when "tool_call"
        tools += 1 unless (event[:initiator] || event["initiator"]) == "hook"
      when "response"
        cost += (event[:cost_usd] || event["cost_usd"]).to_f
      when "iteration"
        on_progress.call(iteration: (event[:n] || event["n"]), tool_calls: tools, cost_usd: cost)
      end
    rescue StandardError
      # A watcher that raises costs its own line, never the run it is watching.
      nil
    end
  end
end
