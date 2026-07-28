# Tool Name Resolution (unprefixed → prefixed fallback)

Note: our code is in week2_capable because week 2 and 3 share the same folder.

## Problem

Session `20260727T223231Z-fef86633` (Dummy profile, task "Find the bakery and
read the menu"), iteration 3:

```
call_e56fe67fc920  examine(target: "baker")  → ERROR: Boukensha::UnknownToolError: No tool registered as 'examine'
call_a4c9afb62d7f  shop(action: "list")      → ERROR: Boukensha::UnknownToolError: No tool registered as 'shop'
```

The tools were advertised that same turn as `tbamud__examine` and
`tbamud__shop` (session log line 22/48/74, `tools:` array) — the model had the
correct names in front of it and called the bare verb anyway. Iteration 4,
seeing its own errors reflected back as tool results, retried with
`tbamud__examine` / `tbamud__shop` and both succeeded. Cost: one wasted
iteration (~1.4s, ~2,500 input tokens) per mistake, self-healing but not free,
and not guaranteed — nothing stops a model from giving up instead of retrying.

The `tbamud__` prefix exists for a real reason, not decoration:
`Tools::Mcp.register_client` (`boukensha/lib/boukensha/tools/mcp.rb:63-68`)
raises `CollisionError` at *registration* time if two servers would register
the same bare name, and the prefix is how a server avoids that collision. It's
config-level (`prefix:` per `mcp_servers` entry), not a naming convention the
model is meant to parse.

## Decision: fallback resolution, not a prompt fix

A system-prompt reminder ("always use the full `tbamud__` name") is unlikely
to hold up — the model already had the correct name sitting in its own tool
list on iteration 3 and dropped the prefix anyway. Prompt text competes with
everything else in context; it's the same class of fix as "tell the model to
try harder."

Instead: resolve unprefixed calls at dispatch time, in the one place all tool
calls already funnel through — `Registry#dispatch`
(`boukensha/lib/boukensha/registry.rb:29-31`):

```ruby
def dispatch(name, args = {})
  tool = @context.tools[name.to_s] || resolve_unprefixed(name.to_s)
  raise UnknownToolError, "No tool registered as '#{name}'" unless tool
  ...
```

`resolve_unprefixed` looks for exactly one registered tool whose name ends in
`Tools::Mcp::SEPARATOR + name` (i.e. `__examine` matching `tbamud__examine`).
Exactly one match resolves silently; zero matches falls through to the
existing `UnknownToolError`; more than one match is a genuine ambiguity (two
mounted servers both expose e.g. `examine`) and must also raise
`UnknownToolError` rather than guess — silently picking one would be the same
class of mistake `CollisionError` already refuses to make at registration
time.

This keeps the collision safety the prefix exists for. It only makes the
prefix *transparent* when there is no collision to protect against, which is
the common case today (one MCP server, `tbamud`).

## Scope

- `Boukensha::Registry#dispatch` — add the fallback lookup described above.
- No change to `Tools::Mcp.register_client` or `prefixed` — registration keeps
  producing `tbamud__examine` etc. exactly as today. This is purely a dispatch-
  side lookup, so it applies uniformly to MCP-derived and natively-registered
  tools without either caller knowing about it.
- No change to what's advertised to the model — it still sees `tbamud__examine`
  in the tool list. This does not teach the model to prefer the bare name; it
  just stops punishing it when the model (any model, not just this session's
  Haiku) reaches for the bare name anyway.

## Out of scope / not proposed here

- Removing the prefix entirely. It's a per-server config knob
  (`mcp_servers: prefix:`) for exactly the multi-server case; deleting it would
  reopen the collision problem it was built to prevent, for a cosmetic win.
- Fuzzy/typo matching (`examin` → `examine`). Different failure mode (spelling,
  not namespacing) and a different risk profile — silently correcting a typo is
  much more likely to mask a real mistake than silently stripping a prefix the
  model was never supposed to need to know about.
- Touching the system prompt. Not removing whatever prefix guidance already
  exists there, just not treating it as the fix.

## Edge cases

- **Two servers, same bare name** (e.g. a second MUD server also exposing
  `examine`): `resolve_unprefixed` sees ≥2 matches, raises `UnknownToolError`
  exactly as it would today. No new failure mode introduced.
- **A native tool already named exactly the bare name** (e.g. someone defines
  `RunDSL#tool("examine")` directly, unprefixed): `@context.tools[name.to_s]`
  finds it directly on the first lookup, `resolve_unprefixed` is never
  consulted. No shadowing risk.
- **Permissions**: `Registry#dispatch` still runs `call_permitted?` and the
  turn-policy check against the *resolved* (prefixed) name, since that's what
  `Permissions` rules are written against (`check(kind: exits)`-style,
  matching registered names). The resolver only changes lookup, not
  enforcement order.

## Test plan (extends `test_registry.rb`)

1. Register `tbamud__examine`; `dispatch("examine")` succeeds and returns the
   same result as `dispatch("tbamud__examine")`.
2. Register `tbamud__examine` and `other__examine`; `dispatch("examine")`
   raises `UnknownToolError` (ambiguous), both prefixed names still dispatch
   directly.
3. Register nothing named `*__nope`; `dispatch("nope")` raises
   `UnknownToolError` (existing behavior, unaffected).
4. Register bare `examine` directly (no prefix) alongside `tbamud__examine`;
   `dispatch("examine")` returns the bare tool's result, not the prefixed one
   (direct lookup wins, resolver never runs).
5. A denied-by-permissions bare call still raises `UnauthorizedToolError`, not
   `UnknownToolError` — i.e. resolution happens before the permission check,
   matching current dispatch order.

## Open question for you

`resolve_unprefixed` as sketched matches on suffix (`__examine`). If a future
server is mounted with a prefix that itself contains `__`, or a tool name
containing `__`, suffix matching could get ambiguous in a way `Tools::Mcp`'s
own collision check wouldn't catch (that check is exact-name, not suffix).
Worth deciding whether to split strictly on the last `__` and compare the
remainder, versus a plain suffix match — the doc above assumes the latter for
simplicity; flag if you want the stricter split.
[Decision] We are the ones adding this prefix in our mcp_server defintion so we should really just split on the prefix__ 