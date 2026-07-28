require_relative "helper"

# Registry is the single enforcement point for a task's `allow:` rules: every
# tool reaches it through #tool, whether it's MCP-derived (Tools::Mcp) or
# registered natively (RunDSL#tool). These
# tests exercise that gate directly, independent of either caller.
class TestRegistry < Minitest::Test
  def test_permissive_default_registers_and_dispatches_freely
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx) # no permissions: — permissive, current default

    tool = reg.tool("anything", description: "d") { |**_| "ok" }

    refute_nil tool
    assert_includes reg.tool_names, "anything"
    assert_equal "ok", reg.dispatch("anything")
  end

  def test_deny_all_registers_nothing
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx, permissions: Boukensha::Permissions.deny_all)

    tool = reg.tool("anything", description: "d") { |**_| "ok" }

    assert_nil tool
    refute_includes reg.tool_names, "anything"
  end

  def test_dispatch_raises_unknown_tool_for_a_name_never_registered
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)

    assert_raises(Boukensha::UnknownToolError) { reg.dispatch("nope") }
  end

  def test_dispatch_raises_unauthorized_for_a_value_the_rule_forbids
    ctx = Boukensha::Context.new(system: "t")
    perms = Boukensha::Permissions.from(["check(kind: exits)"])
    reg = Boukensha::Registry.new(ctx, permissions: perms)
    reg.tool("check", description: "d") { |**kwargs| "ok:#{kwargs[:kind]}" }

    assert_equal "ok:exits", reg.dispatch("check", kind: "exits")
    err = assert_raises(Boukensha::UnauthorizedToolError) { reg.dispatch("check", kind: "score") }
    assert_match(/not permitted/, err.message)
  end

  # The exact seam RunDSL#tool uses (a bare Registry#tool call, no MCP
  # involved) — a native tool is gated identically to an MCP tool.
  def test_a_native_style_tool_not_named_by_any_rule_is_never_registered
    ctx = Boukensha::Context.new(system: "t")
    perms = Boukensha::Permissions.from(["poll"]) # does not name native_probe
    reg = Boukensha::Registry.new(ctx, permissions: perms)

    reg.tool("native_probe", description: "d") { |**_| "json" }

    refute_includes reg.tool_names, "native_probe"
    assert_raises(Boukensha::UnknownToolError) { reg.dispatch("native_probe") }
  end

  # Tool-name resolution: a model that drops the `tbamud__` prefix (which it
  # was never supposed to need to parse) should still reach the tool, as long
  # as there's exactly one registered tool ending in `__<bare name>`.
  def test_dispatch_resolves_a_bare_call_to_its_one_prefixed_tool
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    reg.tool("tbamud__examine", description: "d") { |**kwargs| "examined:#{kwargs[:target]}" }

    assert_equal reg.dispatch("tbamud__examine", target: "baker"),
                 reg.dispatch("examine", target: "baker")
  end

  def test_dispatch_raises_unknown_tool_when_bare_call_is_ambiguous
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    reg.tool("tbamud__examine", description: "d") { |**_| "a" }
    reg.tool("other__examine", description: "d") { |**_| "b" }

    assert_raises(Boukensha::UnknownToolError) { reg.dispatch("examine") }
    assert_equal "a", reg.dispatch("tbamud__examine")
    assert_equal "b", reg.dispatch("other__examine")
  end

  def test_dispatch_prefers_a_directly_registered_bare_tool_over_resolution
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    reg.tool("examine", description: "d") { |**_| "bare" }
    reg.tool("tbamud__examine", description: "d") { |**_| "prefixed" }

    assert_equal "bare", reg.dispatch("examine")
  end

  def test_dispatch_raises_unauthorized_not_unknown_for_a_denied_bare_call
    ctx = Boukensha::Context.new(system: "t")
    perms = Boukensha::Permissions.deny_all
    reg = Boukensha::Registry.new(ctx, permissions: perms)

    # deny_all means `tool` never registers it in the first place, so exercise
    # the permission gate directly at the dispatch layer instead.
    ctx.register_tool(Boukensha::Tool.new("tbamud__examine", "d", {}, proc { |**_| "ok" }))

    err = assert_raises(Boukensha::UnauthorizedToolError) { reg.dispatch("examine") }
    assert_match(/not permitted/, err.message)
  end
end
