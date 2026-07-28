require_relative "errors"
require_relative "permissions"

module Boukensha
  # The single enforcement point for a task's `allow:` rules. Every tool
  # reaches the registry through #tool, whether it came from an MCP server
  # (Tools::Mcp.register_client) or was defined natively in a run/repl block
  # (RunDSL#tool) — so both paths get the same name-level (#tool) and
  # value-level (#dispatch) gate for free. `permissions:` defaults to a
  # permissive Permissions (no restriction), matching the standalone/test path
  # that never had gating to begin with.
  class Registry
    def initialize(context, permissions: Permissions.new(nil))
      @context     = context
      @permissions = permissions
    end

    def tool(name, description:, parameters: {}, &block)
      return nil unless @permissions.allow_tool?(name)
      tool = Tool.new(name.to_s, description, parameters, block)
      @context.register_tool(tool)
      tool
    end

    def tool_names
      @context.tools.keys
    end

    def dispatch(name, args = {})
      tool = @context.tools[name.to_s] || resolve_unprefixed(name.to_s)
      raise UnknownToolError, "No tool registered as '#{name}'" unless tool
      # Permissions/turn-policy are checked against the RESOLVED (prefixed)
      # name — that's what `allow:` rules are written against — not the bare
      # name the model may have called with.
      resolved = tool.name
      raise UnauthorizedToolError, "#{resolved} is not permitted with #{args.inspect}" \
        unless @permissions.call_permitted?(resolved, args)
      # A per-iteration narrowing computed from the world (e.g. `move` pinned to
      # the directions the MUD just printed). It is checked in ADDITION to the
      # task's rules, never instead of them, so a turn policy can only ever take
      # something away — it cannot grant what settings.yaml withheld.
      policy = @context.respond_to?(:turn_policy) ? @context.turn_policy : nil
      raise UnauthorizedToolError, "#{resolved} is not available this turn with #{args.inspect}" \
        if policy && !policy.call_permitted?(resolved, args)
      tool.block.call(**args.transform_keys(&:to_sym))
    end

    private

    # A bare call (e.g. "examine") falls back to whatever registered tool is
    # prefixed with it (e.g. "tbamud__examine") — see Tools::Mcp.prefixed,
    # which is the only thing that ever produces a `prefix#{SEPARATOR}name`
    # tool name. We split each registered name on the FIRST separator, since
    # the prefix itself is a single opaque token we control (never contains
    # SEPARATOR); the remainder is the server's own tool name, which may
    # legitimately contain SEPARATOR and must match `name` exactly.
    #
    # Exactly one match resolves silently. Zero falls through to the existing
    # UnknownToolError. More than one is a genuine ambiguity (two mounted
    # servers both expose e.g. `examine`) and must also raise
    # UnknownToolError rather than guess.
    def resolve_unprefixed(name)
      separator = Tools::Mcp::SEPARATOR
      matches = @context.tools.select do |registered_name, _|
        _prefix, remainder = registered_name.split(separator, 2)
        remainder == name
      end.values
      matches.one? ? matches.first : nil
    end
  end
end