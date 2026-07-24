## Observ Improvements

Now with all my observability I can reset the player and find the bakery
http://localhost:5173/sessions/20260724T221941Z-e99aa04f

Here is what I noticed.

Observations
Iteration 0
- the agent should not have to check 'score' manually as hooks should collect information
  - context about the user should have been injected already from our memory
  - we might want to remove score from our tool list to stop it
  - 1.9s seems really slow
Iteration 1
- look should have not been called, since inspect_room gets us all the information we need
  - if we need to deeper search that would be a future logic step and it would just search across the knowledgebase of room descriptions
Did the agent actually call score or look or is this our underling calls from RoomParser
I don't think we updated anyway to expose that kind of logging of RoomParser into the Agent Session
Request 1:
it doesn't show those two tool calls look and score so maybe it is RoomParser

```sh
[here] The Temple Of Midgaard  (visit 6)
exits: d→The Temple Square ? | e→The Midgaard Donation Room ✓ | n→By The Temple Altar ✓ | s→The Temple Square ✓ | w→The Reading Room ?
here: Admin the Implementor (linkless) is standing here. (mob) | Derrano the Minister (linkless) is standing here. (mob) | An automatic teller machine has been installed in the wall here. (object)
you: 20/20hp 100mana 85mv · lvl 1 · 0 gold · standing
```
Is this summary optimal, maybe we should let our agent know of the template in the system prompt
or have a legend, might allow us to have more compact summary for multiple messages.
Iternation 2
- tbamud_move is called, and see the full description but in the request 2 we see 'moved west → The Reading Room'
  - we obviously want the latter but why wouldn't this be shown in our tbamud_move, did we wrap tbamud_move with a native move tool or there is a hook.
    - it should better reflect in the actual session so its not confusing.
Iteration 3
tbamud__move(direction: "d") error: error [argument_error]: invalid direction: "d" (expected one of north, east, south, west, up, down)
  - why is this invalid? seems like it would be down, maybe when navigating it should use at least two character or whatever will avoid this issue.
Iteration 4
- the agent thanks us for the context, what context is it even talking about? did we insert something we donk't see let me check the requests.

Request 4
```txt
user
tool_result · toolu_01JgqvJLYvpzpPR6LSbg59pd
error: error [argument_error]: invalid direction: "d" (expected one of north, east, south, west, up, down)
user
[here] The Temple Of Midgaard  (visit 7)
exits: d→The Temple Square ? | e→The Midgaard Donation Room ✓ | n→By The Temple Altar ✓ | s→The Temple Square ✓ | w→The Reading Room ✓
here: Admin the Implementor (linkless) is standing here. (mob) | Derrano the Minister (linkless) is standing here. (mob) | An automatic teller machine has been installed in the wall here. (object)
you: 20/20hp 100mana 83mv · lvl 1 · 0 gold · standing
```
- Yep it clearly does give context, but this doesn't show up during our main session information.

We need a plan to investigate and improve the session logging information so its clear.

## Technical Solutions

### Finding from the linked session

This is not `RoomParser` issuing commands. `RoomParser` is pure text parsing.
The commands come from `Mud::Hooks`:

- `before_turn` calls `check(kind: "score")` once per process to initialize the
  player record.
- `before_model` calls `look` when the process has not established its current
  room. It also performs the first-visit survey (`check(exits)`, `consider`,
  `examine`) when the room is not in memory.
- `before_tools` calls `poll` before dispatching a model-selected tool batch.

The session JSONL already contains these calls. In
`20260724T221941Z-e99aa04f`, `score` ran at `18:20:12`, the cold-start `look` at
`18:20:14`, and the first model request followed at `18:20:14`. The roughly
1.9-second delay is the blocking MUD `score` request, not model latency.

The underlying problem is provenance. Hook calls and model calls are both
logged as ordinary `tool_call` / `tool_result` events with `task: "player"` and
`depth: 0`. The monitor therefore cannot explain who initiated a call or why.
It also shows the raw movement result in the transcript even though
`Hooks#after_tool` replaces that result with the compact
`moved west → The Reading Room` string before adding it to model context. The
request drawer is currently the only place that reveals the replacement and the
injected `[here]` block.

### Goal

Make one session answer three different questions without conflating them:

1. What did the model request?
2. What work did framework/hook code perform on the model's behalf?
3. What exactly did the model receive on the next request?

Keep the raw MUD response for diagnosis, but make the model-visible value and
injected state first-class rather than requiring comparison with the request
drawer.

### 1. Add provenance and correlation to tool events

Extend `Logger#tool_call` and `Logger#tool_result` with optional metadata:

```json
{
  "phase": "tool_call",
  "call_id": "call_...",
  "name": "tbamud__look",
  "args": {},
  "initiator": "hook",
  "operation": "position_refresh",
  "trigger": "before_model",
  "parent_call_id": null
}
```

Fields:

- `call_id`: generated by the logger and returned from `tool_call`; the matching
  result carries the same ID. Stop pairing calls and results heuristically by
  name/depth for new logs.
- `initiator`: `model`, `hook`, or `delegated_task`.
- `operation`: stable semantic reason such as `player_bootstrap`,
  `position_refresh`, `room_survey`, or `async_poll`.
- `trigger`: lifecycle seam (`before_turn`, `before_model`, `before_tools`, or
  `after_tool`).
- `parent_call_id`: set when internal work is caused by a model tool call.

`Agent#handle_tool_calls` logs `initiator: "model"`. The hook dispatcher is
constructed with a small logging context rather than a bare logger:

```ruby
call_tool = Boukensha.tool_dispatcher(
  name,
  logger: parent,
  initiator: "hook"
)
```

`Mud::Hooks#call` supplies the current `operation` and `trigger`. The room survey
should wrap its group of calls in an operation span so `look`, `check(exits)`,
`consider`, and `examine` appear together as one `room_survey`, not as
unexplained player actions.

This is additive. The parser continues its current name/depth pairing for old
logs and prefers `call_id` when present.

### 2. Log the model-visible transformation explicitly

Keep the existing raw `tool_result`, then emit an event when `after_tool`
changes what is placed in context:

```json
{
  "phase": "context_transform",
  "call_id": "call_...",
  "kind": "tool_result_replacement",
  "raw_chars": 512,
  "content": "moved west → The Reading Room"
}
```

Do not replace or discard the raw result. Both views are useful:

- **Raw result**: what the MUD returned, for parser and transport debugging.
- **Model received**: what was appended as the tool result, for agent-behaviour
  debugging.

In the monitor, one movement card should show the compact result by default and
offer an expandable **raw MUD response**. This removes the current apparent
contradiction without duplicating two unrelated-looking tool cards.

Also emit an `injected_context` event after `before_model` finalizes
`context.state_block`:

```json
{
  "phase": "injected_context",
  "kind": "state_block",
  "content": "[here] The Temple Of Midgaard ...",
  "source": "memory",
  "changed": true
}
```

The request remains the definitive wire record. This event is a readable
explanation in the transcript, not a second source of truth. The monitor renders
it as a compact **Context injected** card immediately before the request marker,
collapsed by default with the first line visible. That makes the assistant's
"Thank you for the context" traceable.

### 3. Distinguish model actions from automatic work in the monitor

Update the API entry type and React transcript renderer to display:

- model calls as the existing prominent tool cards;
- hook operations as a muted, collapsible **Automatic context work** group;
- context transformations inside their associated model tool card;
- injected state immediately before the request that consumed it.

Suggested automatic group summary:

```text
Automatic context work · 2.03s
  bootstrap player   check(score)       1.93s
  establish position look               0.10s
```

Empty `poll` calls should be collapsed into the group count (for example,
`poll × 8, all empty`) rather than occupying the main narrative. A non-empty or
failed poll expands automatically. First-visit survey calls remain available
but collapsed under `room survey`.

Session-level tool counts should split into:

- `model_tool_calls`
- `automatic_tool_calls`
- `all_tool_calls`

This prevents a hook's `score`, `look`, and `poll` from making the model appear
more tool-hungry than it was.

### 4. Fix the direction mismatch at the producer

The invalid `"d"` was a model call. The model copied the abbreviation from the
injected state:

```text
exits: d→The Temple Square
```

but the advertised `move.direction` contract accepts only full names. The state
block and tool schema currently speak different grammars.

Render full direction names in model-facing state:

```text
exits: down→The Temple Square ? | east→... | north→...
```

Do not loosen the tool schema to accept abbreviations. One canonical spelling
keeps policy pinning, validation, memory keys, and logs consistent. This costs
only a few tokens per state refresh and removes an avoidable failed iteration.
Add a prompt sentence only as reinforcement: “Exit directions are valid
`move.direction` values; copy them exactly.” The renderer/schema alignment is
the actual fix.

### 5. Keep `score` and `look` off the player tool surface

No player-tool removal is required for the two calls observed here:

- `look` is already absent from the player's advertised tools.
- `check` remains useful for inventory, equipment, gold, weather, and other
  gameplay queries, so removing it would remove legitimate capability.

Instead, narrow the player's `check.kind` permission to exclude `score` if
score is always maintained by hooks. Keep `score` in the hook/survey dispatcher
allowlist. This makes duplicate manual score checks impossible while preserving
the automatic bootstrap.

Before enabling that restriction, add a refresh policy for stale stats. The
current hook reads full score once per process and after a detected level-up;
prompt lines update only HP/mana/movement. Recommended refresh triggers are
login/reconnect, detected level-up, and explicit invalidation after operations
known to change gold/experience. Do not poll score before every model call.

### 6. Measure hook overhead separately from model latency

Add operation timing from monotonic timestamps:

- `hook_duration_ms` by operation/trigger;
- MCP/MUD duration for every internal call;
- `model_duration_ms` from request to response;
- total iteration duration.

The monitor should render these as separate segments. For the linked session it
would attribute the initial ~1.9 seconds to `player_bootstrap/check(score)`,
instead of leaving it adjacent to Iteration 0 where it looks like model time.

### Implementation order

1. **Direction correctness** — render full direction names and add state-block
   tests. This is small and immediately removes a real failure.
2. **Event contract** — add `call_id`, provenance fields,
   `context_transform`, and `injected_context`; keep legacy parser fallback.
3. **Monitor presentation** — automatic-work groups, compact/raw result toggle,
   injected-context cards, and split counts.
4. **Tool policy** — deny player-selected `check(score)` after adding and
   testing the refresh/invalidation policy.
5. **Performance follow-up** — use the new timings to decide whether the
   cold-start score can be deferred, cached with a freshness bound, or combined
   with another MUD round trip. Do not optimize the 1.9 seconds until it is
   measured across multiple sessions.

### Acceptance criteria

- The linked scenario clearly labels `score` and cold `look` as automatic hook
  work, not model tool calls.
- A movement card shows `moved west → The Reading Room` as the model-visible
  result and exposes the full MUD room text on demand.
- Every request has a visible, expandable injected `[here]` card matching the
  state block in the definitive request payload.
- The model never receives an exit spelling rejected by `move.direction`.
- Model and automatic tool counts are reported separately.
- Existing session JSONL files still load and use the legacy pairing/display
  path.
- Failed and non-empty automatic calls are never hidden by default.
