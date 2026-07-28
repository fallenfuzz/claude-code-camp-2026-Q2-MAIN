module Boukensha
  # Repl is the interactive session loop.
  #
  # It wraps the same primitives as a single Boukensha.run call, but instead of
  # running once it stays alive: it reads a task from the user, runs the agent,
  # prints the reply, and loops back to the prompt.
  #
  # The Context is shared across every turn so conversation history accumulates
  # naturally — the agent sees the full transcript each time it is called.
  #
  # Built-in commands (not sent to the agent):
  #   /help    print the command list
  #   /quiet   suppress detailed logging
  #   /loud    re-enable logging
  #   /clear   wipe conversation history (tools stay registered)
  #   /compact drop oldest 40% of messages to free context
  #   /rename  name this session (or print its current name)
  #   /exit    leave the REPL
  #   /quit    alias for /exit
  class Repl
    PROMPT = "boukensha> "

    HELP = <<~HELP
      Commands:
        /quiet    suppress logging output
        /loud     re-enable logging output
        /clear    wipe conversation history (tools stay)
        /compact  drop oldest 40% of messages to free context
        /rename   name this session, e.g. /rename find bakery — cold map
        /exit     leave the REPL
        /help     show this message
    HELP

    attr_reader :logger, :context, :model, :version, :session_name

    def initialize(context:, registry:, builder:, client:, logger:, hooks: nil, config_dir: nil, provider: nil, model: nil, version: nil, api_key: nil, servers: nil, max_iterations: nil, max_turn_tokens: nil, max_output_tokens: nil, session_name: nil)
      @context    = context
      @registry   = registry
      @builder    = builder
      @client     = client
      @logger     = logger
      # Handed to every per-turn Agent below. One Hooks instance for the whole
      # REPL, because what it remembers has to outlive a turn.
      @hooks      = hooks
      @config_dir = config_dir
      @provider   = provider
      @model      = model
      @version    = version
      @api_key    = api_key
      @servers    = servers
      # Mirrors the name already written into `session_start`, so `/rename`
      # with no argument can answer without re-reading the log it just wrote.
      @session_name = session_name
      @max_iterations    = max_iterations
      @max_turn_tokens   = max_turn_tokens
      @max_output_tokens = max_output_tokens
      @turn       = 0
      @output_cb  = nil
    end

    # Register a callback that receives every string the REPL would otherwise
    # print to stdout.  When set, puts/print are suppressed entirely and all
    # output is routed through the callback instead.  Used by Tui.
    def on_output(&block)
      @output_cb = block
    end

    def banner
      key_status    = (@api_key.nil? || @api_key.strip.empty?) ? "✗ API key not set" : "✓ API key set"
      provider_line = "#{@provider || "default"} (#{@model || "default"})  #{key_status}"
      config_exists = @config_dir && Dir.exist?(@config_dir)
      config_line   = config_exists ? @config_dir : "#{@config_dir || "(default)"}  ✗ directory not found"
      ver           = @version || "?.?.?"
      servers_stat  = servers_status_string
      name_line     = @session_name ? "\n  session:   #{@session_name}" : ""

      <<~BANNER

        ╔══════════════════════════════════════╗
        ║  BOUKENSHA MUD Assistant (v#{ver})#{" " * (9 - ver.length)}║
        ╚══════════════════════════════════════╝
          config:    #{config_line}
          provider:  #{provider_line}
          servers:   #{servers_stat}#{name_line}

          /quiet or /loud   toggle logging
          /clear           reset conversation history
          /compact         free context (drop oldest messages)
          /rename NAME     name this session
          /exit or /quit    leave the REPL

      BANNER
    end

    # Handle a slash command.  Returns :quit, :command, or nil (not a command).
    # Output is routed through the registered on_output callback if present.
    def handle_command(input)
      case input
      when "/exit", "/quit"
        output("Goodbye.")
        :quit
      when "/help"
        output(HELP)
        :command
      when "/quiet"
        Boukensha.quiet!
        output("(logging suppressed — type /loud to re-enable)")
        :command
      when "/loud"
        Boukensha.loud!
        output("(logging enabled)")
        :command
      when "/clear"
        before = @context.messages.size
        @context.clear_messages!
        @turn = 0
        @logger.clear(before: before)
        output("(conversation history cleared)")
        :command
      when "/compact"
        before  = @context.messages.size
        dropped = @context.compact_messages!
        @logger.compaction(before: before, dropped: dropped, context_window: @context.context_window)
        output("(compacted context — #{dropped} messages dropped)")
        :command
      when %r{\A/rename\s+(.+)\z}
        @session_name = @logger.rename(name: Regexp.last_match(1).strip, source: "user")
        output("(session renamed to #{@session_name.inspect})")
        :command
      when "/rename"
        # Bare `/rename` prints rather than errors: the far more common reason
        # to type it alone is wanting to know what the session is already called.
        output(@session_name ? "(session name: #{@session_name.inspect})" : "(this session has no name)")
        :command
      end
    end

    def run_turn(input)
      @turn += 1
      @logger.turn(n: @turn)

      @context.add_message(:user, input)

      agent  = Agent.new(
        context:  @context,
        registry: @registry,
        builder:  @builder,
        client:   @client,
        logger:   @logger,
        hooks:    @hooks,
        max_iterations:    @max_iterations,
        max_turn_tokens:   @max_turn_tokens,
        max_output_tokens: @max_output_tokens,
        turn:     @turn
      )
      result = agent.run

      output("")
      output(result)
    rescue LoopError => e
      Boukensha.error_log.record(e, component: "repl", boundary: "run_turn")
      output("\n[error] #{e.message}")
    rescue ApiError => e
      Boukensha.error_log.record(e, component: "repl", boundary: "run_turn")
      output("\n[error] API call failed: #{e.message}")
    end

    def start
      output(banner)
      loop do
        unless @output_cb
          print PROMPT
          $stdout.flush
        end

        input = $stdin.gets
        break unless input  # EOF / Ctrl-D

        input = input.chomp.strip
        next if input.empty?

        result = handle_command(input)
        break if result == :quit
        next  if result

        run_turn(input)
      end
    end

    private

    def output(str)
      if @output_cb
        @output_cb.call(str.to_s)
      else
        puts str
      end
    end

    # Build the MCP servers line shown in the banner. Every tool the agent has
    # came from one of these, so this doubles as "what can I actually do?".
    # No probing needed: a server that answers tools/list is already connected,
    # and one that didn't is either absent here or took the agent down at boot.
    def servers_status_string
      return "(none configured — the agent has no tools)" if @servers.nil? || @servers.empty?

      @servers.map { |name, count| "#{name} (#{count})" }.join("  ")
    end
  end
end
