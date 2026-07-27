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

  def self.profiles
    root = File.expand_path(ENV["BOUKENSHA_DIR"] || File.join(Dir.home, ".boukensha"))
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

    root = File.expand_path(ENV["BOUKENSHA_DIR"] || File.join(Dir.home, ".boukensha"))
    dir = File.expand_path(File.join(root, "profiles", actual))
    profiles_root = File.expand_path(File.join(root, "profiles")) + File::SEPARATOR
    abort "boukensha: profile resolves outside profiles directory" unless dir.start_with?(profiles_root)
    ENV["BOUKENSHA_PROFILE"] = actual
    ENV["BOUKENSHA_PROFILE_DIR"] = dir
  end

  def self.extract_profile_argument
    if ARGV.delete("--list-profiles")
      puts profiles
      exit 0
    end
    index = ARGV.index("--profile")
    return nil unless index
    abort "boukensha: --profile requires a name" unless ARGV[index + 1]
    ARGV.slice!(index, 2).last
  end

  def self.load_and_start_repl
    main = resolve
    resolve_profile!
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

    # --no-tui falls back to the plain terminal REPL (no charm-ruby).
    no_tui = ARGV.delete("--no-tui")

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
    Boukensha.repl(tui: !no_tui) do
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
        tool "plan_route",
             description: "Plan a route to a known place, landmark, or thing using only what you " \
                          "have already explored. Never moves you and performs no MUD actions.",
             parameters: { destination: { type: "string",
               description: "Place, landmark, or thing to find, e.g. 'bakery' or 'Temple Square'." } } do |destination:|
          Boukensha::Mud::Navigation::PlanRouteTool.call(store: store, destination: destination)
        end

        # `call_tool` is already bound above to the HOOK's own room-survey-
        # scoped dispatcher (poll/look/check/consider/examine — no `move`).
        # execute_route must dispatch under the PLAYER's own permissions
        # instead, which is RunDSL#call_tool — reached here with an explicit
        # `self.` receiver so it is not shadowed by the local variable of the
        # same name.
        player_call_tool = ->(name, args) { self.call_tool(name, **args) }

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

        # Batched movement over a route `plan_route` already confirmed
        # `known` — collapses N model round-trips into one while still
        # reconciling position and polling for interrupting events between
        # every internal step (Mud::Hooks#reconcile_move!, Mud::EventClassifier).
        tool "execute_route",
             description: "Walk a sequence of directions already returned by plan_route's " \
                          "`known` result, one MUD move per step inside a single call. Stops " \
                          "early if a move fails or something worth reacting to happens.",
             parameters: { steps: { type: "array",
               items: { type: "string", enum: Boukensha::Mud::RoomParser::DIRECTIONS.values },
               description: "Directions to walk in order, e.g. [\"west\", \"north\"]." } } do |steps:|
          Boukensha::Mud::Navigation::ExecuteRouteTool.call(steps: steps, call_tool: player_call_tool, hooks: mud_hooks)
        end
      rescue Boukensha::Mud::Memory::Store::Unavailable => e
        Boukensha.error_log.record(e, component: "mud_hooks_setup", boundary: "memory_store")
        # No memory is a degraded agent, not a dead one: it explores exactly as
        # it did before this feature existed.
        warn "[boukensha] #{e.message} — continuing without room memory"
      end
    end
  end
end
