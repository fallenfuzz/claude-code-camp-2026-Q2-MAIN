module Boukensha
  # RunDSL is the object that `self` becomes inside a Boukensha.run block.
  # It exposes `tool` plus the run's `logger`, keeping the DSL surface
  # intentionally small.
  class RunDSL
    # The run's session logger. A native tool that delegates to a subagent
    # passes this to Boukensha.run_task so the sub-run writes into THIS session
    # file instead of minting its own (plan Amendment A). Handed over
    # explicitly rather than read from an ambient thread-local, so the
    # delegation graph stays readable and a test can inject a fake.
    attr_reader :logger

    def initialize(registry, logger: nil)
      @registry = registry
      @logger   = logger
      @hooks    = nil
    end

    # Install the run's lifecycle hooks (a Boukensha::Hooks subclass), or read
    # back what was installed. Setting them from inside the block rather than
    # passing them to .run/.repl is what lets a hook reach `logger` — a MUD hook
    # that spends its own round trips has to log them into THIS session file, or
    # mud_monitor shows an agent that moved between rooms it never looked at.
    #
    #   Boukensha.repl do
    #     hooks Boukensha::Mud::Hooks.new(logger: logger)
    #   end
    def hooks(obj = nil)
      @hooks = obj unless obj.nil?
      @hooks
    end

    def tool(name, description:, parameters: {}, &block)
      @registry.tool(name, description: description, parameters: parameters, &block)
    end

    def tool_names
      @registry.tool_names
    end

    # Invoke an already-registered tool by name (including MCP tools such as
    # `tbamud__look`) and return its result. This is what lets a native tool
    # defined in a run/repl block compose over the tools the MCP servers
    # contributed, under the player's own permissions.
    #
    # Note this is NOT what the MUD hooks use: they need a slice the player does
    # not have, so they go through Boukensha.tool_dispatcher and its separate
    # Registry instead.
    def call_tool(name, **args)
      @registry.dispatch(name.to_s, args)
    end
  end
end
