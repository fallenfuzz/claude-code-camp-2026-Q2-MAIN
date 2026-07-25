# Plan Route

## Goal

When the player asks to reach a destination, the model should not rediscover
pathfinding one move at a time from the `[here]` block. Give it one read-only
native tool:

```text
plan_route(destination: "bakery")
```

The tool searches only knowledge the agent has earned, plans over the known room
graph, and returns one of three honest outcomes:

1. **Known destination** — the destination resolves to a mapped room and the
   tool returns the shortest known route.
2. **Likely search area** — no mapped room is the destination, but remembered
   room text suggests where to search; the tool returns a route to the best
   relevant frontier.
3. **Unknown destination** — memory has no useful clue; the tool returns a route
   to the best general exploration frontier.

`plan_route` never moves the character. Each `move` remains a normal
model-selected tool call, with its raw result, context replacement, memory
update, and timing visible in the session.

---

## 1. Findings from the reviewed session

The confusing calls in session `20260724T221941Z-e99aa04f` are not
`RoomParser` doing hidden I/O. `RoomParser` is pure text-in/struct-out.

| Observation | Actual source | Required treatment |
|---|---|---|
| `check(score)` before iteration 0 | `Mud::Hooks#before_turn`, operation `player_bootstrap` | Keep it off the player's allowlist. Show it as a hook call in the session, including duration. Revisit its refresh policy separately if the initial 1.9s is not worth the data. |
| `look` before an iteration | `Mud::Hooks#before_model`, operation `position_refresh`, or `RoomSurvey` on first discovery | Do not expose `look` to the player. Show the hook/survey provenance rather than attributing it to model choice. |
| Full room output on the `move` card, but `moved west → The Reading Room` in the next request | `after_tool` preserves the raw tool result and replaces only the model-context copy | Render both correlated values on the session card: raw MUD result and “model received.” |
| `move(direction: "d")` rejected | The old compact state block advertised `d`, while the schema accepts `down` | Use canonical full direction names everywhere the model can copy a value. This is already reflected in `StateBlock`; `plan_route` must follow the same grammar. |
| “Thanks for the context” without visible context | `before_model` injected the `[here]` state block | Render `injected_context` in the main session timeline, collapsed when unchanged. |

These are observability requirements for pathing, not part of the routing
algorithm. A route is only debuggable if the session distinguishes:

- model-selected calls (`initiator: model`);
- hook-selected calls (`initiator: hook`, plus `operation` and `trigger`);
- raw tool output;
- the transformed text actually appended to model context;
- injected state that did not originate in a user message.

The current worktree already contains the logger/parser work for those event
types. `plan_route` should use those existing seams rather than introduce a
second trace format.

---

## 2. Why this belongs in a tool

The `[here]` block answers “where am I and what can I do next?” It should remain
small. Route planning answers a different, on-demand question over many rooms.
Injecting the whole map every iteration would make known-world growth increase
prompt cost forever.

Conversely, leaving pathfinding to the model wastes iterations and is less
reliable:

- the model sees only the current room, not the full graph;
- remembered routes are spread across many prior messages;
- short direction aliases can leak from prose into strict tool arguments;
- a wrong turn costs a MUD round trip and another model iteration.

The division is:

| Component | Responsibility |
|---|---|
| Lifecycle hooks | Establish current room, survey new rooms, maintain memory, inject `[here]`. |
| `StateBlock` | Compact live state and immediate choices. |
| `plan_route` | Search persistent room knowledge and compute a route or exploration target. |
| Model | Decide whether to follow the plan, issue each move, react to failures, and re-plan. |

---

## 3. Tool contract

### 3.1 Input

```json
{
  "type": "object",
  "properties": {
    "destination": {
      "type": "string",
      "description": "Place, landmark, service, person, or thing to find, such as 'bakery' or 'Temple Square'."
    }
  },
  "required": ["destination"],
  "additionalProperties": false
}
```

Start with one required field. Do not add `from`, `algorithm`, `max_depth`, or
weights to the model surface. The start room must be the hook-maintained
`player_state.current_room_id`, and implementation policy is not a gameplay
choice.

Reject a blank destination. If the current room is not established, return a
structured `position_unknown` result telling the model to make one safe gameplay
action; do not issue a hidden `look` from the route tool.

### 3.2 Output

Return compact text because this becomes a permanent tool result in context:

```text
[route] bakery — known
to: Grubby's Bakery (#42)
path: west → south → down
3 moves: The Reading Room → Temple Square → Grubby's Bakery
```

When the current room is already the destination:

```text
[route] bakery — arrived
here: Grubby's Bakery (#42)
```

When the destination is not known but there is relevant evidence:

```text
[route] bakery — explore
clue: Market Street (#18) mentions shops and food
frontier: east from Market Street
path: north → east
2 known moves, then explore east
```

When there is no evidence:

```text
[route] bakery — unknown
frontier: down from The Temple Of Midgaard
path: down
reason: nearest unvisited exit; no remembered room matches "bakery"
```

When known graph components are disconnected:

```text
[route] bakery — unreachable
to: Grubby's Bakery (#42)
reason: destination is remembered, but no known path connects room #6 to room #42
next: explore the nearest frontier from the current component
path: west → north
```

Every direction in output is one of:

```text
north east south west up down northeast northwest southeast southwest
```

The exact set must be derived from `RoomParser::DIRECTIONS.values`, not copied
into another independent constant.

### 3.3 Internal result

Keep a structured result internally even if v1 renders text:

```ruby
RoutePlan = Data.define(
  :status,              # arrived | known | explore | unknown | unreachable
  :query,
  :start_room,
  :destination_room,
  :steps,               # [{ direction:, from_room_id:, to_room_id: }]
  :frontier,            # { room_id:, direction: } or nil
  :evidence,            # matched fields/snippets, never hidden reasoning
  :alternatives         # ambiguous destination matches
)
```

This makes the algorithm testable without asserting prose and leaves a clean
future path for a monitor route overlay.

---

## 4. Destination resolution

Search the knowledge database, not conversation history and not the bundled
world files. The agent must not learn unvisited rooms from
`week0_explore/preview/data/world`.

### 4.1 Search corpus

Build one document per known room from:

- room `name`;
- room `description`;
- `look_candidates`;
- remembered entity descriptions and keywords;
- known exit target names.

This supports both a place (`bakery`) and a landmark/entity (“the fountain”,
“the baker”). Entity evidence identifies the room where it was seen; it does
not claim the entity is still present.

### 4.2 Normalization and ranking

V1 should be deterministic and dependency-free:

1. Unicode-normalize and lowercase.
2. Replace punctuation with spaces and collapse whitespace.
3. Compare the full normalized query, then all query tokens.
4. Rank fields:
   - exact room name;
   - room-name phrase/prefix;
   - room-name token match;
   - entity keyword/description;
   - room description or look candidate;
   - exit target name.
5. Break ties by shortest known distance from the current room, then room id.

Do not use an LLM or spawn a subagent for the initial search. A subagent cannot
discover more facts from the same database, adds latency, and is unsafe if it is
allowed to share and drive the live MUD connection. If later logs show semantic
queries that lexical search systematically misses, add an offline embedding or
FTS-backed ranker behind the same interface.

Return `alternatives` when top matches are close. For a clearly ambiguous query
such as “square,” do not silently pick one destination. The compact result
should list up to three candidates and ask the model to refine from the user's
wording or choose the nearest only when the task makes that acceptable.

### 4.3 What counts as “known”

A room is a known destination when:

- it is in `rooms`; and
- destination resolution gives it a decisive top score.

It does not need to be in the current connected component to be known. In that
case the status is `unreachable`, which is materially different from
`unknown`.

---

## 5. Route calculation

Treat each row with non-null `target_room_id` as a directed edge:

```text
room_id --direction--> target_room_id
```

Use breadth-first search for v1. Every move has unit cost and the discovered
map is small, so BFS gives the shortest known move count without a dependency.

Determinism matters because repeated calls should not produce route churn:

- visit outgoing edges in canonical direction order;
- use room id as the final tie-break;
- never depend on SQL row order unless the query has `ORDER BY`;
- reconstruct steps from predecessor edges, not just predecessor rooms.

Do not infer a reverse edge. If the database has `A --east--> B` but has not
earned `B --west--> A`, only the first direction exists for planning. MUD exits
may be one-way, gated, or non-Euclidean.

Ignore frontier rows (`target_room_id IS NULL`) during known-route BFS. They are
candidate goals for exploration, not traversable graph edges.

### Route validity

A returned plan is a snapshot, not a reservation. The model should:

1. call `plan_route` once for a navigation goal;
2. execute the returned directions one at a time;
3. rely on the next `[here]` block to confirm each arrival;
4. stop and call `plan_route` again if a move fails, the named arrival differs,
   the room becomes uncertain, or the route is exhausted without reaching the
   goal.

Do not add an `execute_route` tool in v1. Batched movement would hide the exact
step that failed, bypass per-step state refresh, and make asynchronous events
harder to attribute.

---

## 6. Planning when the destination is not mapped

“Best reason where to look” should be a deterministic frontier ranking, with
the evidence exposed in the result. It is not hidden chain-of-thought.

### 6.1 Candidate frontiers

A frontier is a `room_exits` row whose `target_room_id` is null. For each
frontier reachable from the current room through known edges, calculate:

- known distance to its source room;
- relevance of the source room document to the destination query;
- relevance of the exit's `target_name`, when known;
- whether the source room has other unvisited exits;
- how recently the source room/frontier was attempted, when attempt data exists.

### 6.2 Ranking

Use a lexicographic policy in v1 rather than opaque floating-point weights:

1. frontier with an exact/phrase clue in `target_name`;
2. frontier attached to the best matching room;
3. frontier attached to any room with matching description/entity evidence;
4. nearest frontier by known move count;
5. fewer prior traversals/attempts;
6. canonical direction order, then source room id.

This yields a useful plan for “find the bakery” if memory contains a market,
food shop, baker, or exit named for the bakery, while still having a predictable
fallback when it does not.

The plan routes to the frontier's **source room**, then appends the frontier
direction as an exploration step. The final step must be labelled unknown:

```text
path: west → south
then explore: east (destination beyond this exit is not mapped)
```

It must never render the frontier as if it were a confirmed route to the
destination.

### 6.3 Broad exploration

If no document matches the query, select the nearest reachable frontier.
Prefer lower traversal/attempt count so repeated plans gradually fan outward
instead of oscillating around the same door.

The current schema records successful traversals but not failed frontier
attempts. V1 can ship without attempt memory, but repeated blocked exits will
remain a loop risk. The first follow-up should add:

```text
frontier_attempts(room_id, direction, outcome, attempted_at)
```

and record movement failures in `Hooks#after_tool`. Until then, the model must
re-plan after a failed move and the prompt should explicitly forbid retrying the
same failed step unchanged.

If the current known component has no frontier, return `exhausted` rather than
inventing a direction. A disconnected remembered component may have frontiers,
but it is not a usable target until the agent learns a connection.

---

## 7. State block and prompt language

The four-line state summary is close to optimal for iteration-by-iteration
navigation: it is compact, separates current room/exits/entities/player, and
marks mapped versus frontier exits. Keep it as state, not as a route transcript.

Two refinements are required:

1. Always render full canonical directions. This prevents `d` being copied into
   a schema that requires `down`.
2. Put its grammar in the player system prompt once, not in every state block.

Recommended prompt section:

```text
# Navigation
Before every model call, `[here]` gives your current state:
- `exits:` lists canonical move directions.
- `✓` means the destination is mapped.
- `?` means the exit is an exploration frontier.
- `here:` lists what is present now; `you:` lists your current player state.

For any goal to find or travel to a place, call `plan_route` first. Follow a
known route one move at a time. If the route says `explore`, its final direction
is a frontier, not a confirmed destination. Re-plan after a failed move,
unexpected arrival, uncertain room, or exhausted plan.

Do not call `look` or `check(score)` for context. Hooks maintain the `[here]`
block and player state.
```

Avoid phrases such as “thanks for the context.” The block is ambient state, not
a conversational request from the user.

---

## 8. Code layout

Keep pathfinding MUD-specific and keep the graph/search logic independent of
the agent framework:

```text
week2_capable/boukensha/lib/boukensha/mud/navigation/
  destination_search.rb   # query normalization, evidence, ranked room matches
  route_planner.rb        # BFS, frontier selection, RoutePlan
  plan_route_tool.rb      # validates input, reads current room, renders result
```

Minimal store additions:

```ruby
Store#rooms
Store#all_exits
Store#entities_for_room(room_id)   # or one batched all-room query
```

Prefer batched reads. `plan_route` should obtain one consistent in-memory
snapshot and perform search/BFS without N+1 SQLite queries.

Register `plan_route` as a native tool in the player registry, then add it to
`tasks.player.allow`. It should have no entry in `tools.room_survey.allow`
because it performs no MUD I/O.

The native tool needs the same `Store` instance used by `Mud::Hooks`, not a
second database connection with independently resolved profile paths. Wire it
at the entrypoint where hooks are created.

Logging needs no special path: normal native dispatch produces
`tool_call(name: "plan_route", initiator: "model")` and `tool_result`. Add an
optional result summary (`status`, destination room id, step count, frontier)
only if the monitor later needs filtering without parsing the text.

---

## 9. Tests

### Destination search

- exact and case-insensitive room-name match;
- partial room name and multi-token query;
- match through description, look candidate, entity, and exit target;
- stale entity evidence is labelled as remembered, not currently present;
- deterministic tie ordering;
- ambiguous match returns alternatives rather than a confident choice;
- no query match.

### Known graph

- shortest directed path;
- cycles terminate;
- one-way exits are not reversed;
- `up` and `down` remain canonical;
- disconnected known destination returns `unreachable`;
- current room equals destination returns `arrived`;
- provisional/uncertain current position returns `position_unknown`;
- stable result regardless of input row order.

### Frontier planning

- target-named frontier wins;
- relevant-room frontier wins over nearer irrelevant frontier;
- with no clue, nearest reachable frontier wins;
- tied frontiers use traversal count, direction, and room id deterministically;
- route to source plus explicitly unknown final step;
- no reachable frontier returns `exhausted`.

### Integration

- player tool list contains `plan_route` and does not contain `look` or
  `check(score)`;
- calling `plan_route` performs zero MCP calls;
- a route result uses only values accepted by `tbamud__move.direction`;
- hook `score`/`look` calls retain `initiator: hook`;
- `plan_route` retains `initiator: model`;
- raw move result and model-context replacement share one `call_id`;
- injected `[here]` context is visible in the session transcript.

---

## 10. Delivery order

1. **Graph snapshot and BFS** — store read methods, `RoutePlan`, known
   destination routes, deterministic unit tests.
2. **Native tool surface** — registration, permissions, compact renderer, and
   zero-MCP integration test.
3. **Destination search** — names first, then descriptions, candidates,
   entities, and target names; ambiguous alternatives.
4. **Frontier planner** — relevant-frontier and broad-exploration outcomes.
5. **Prompt contract** — document the `[here]` template, require
   `plan_route` for destination goals, and require full canonical directions.
6. **Monitor acceptance** — verify hook/model provenance, injected context, and
   raw-versus-transformed move output in a recorded reset-to-bakery run.
7. **Evaluate from logs** — measure route calls per goal, failed moves, repeated
   frontiers, route length versus shortest known path, tool latency, and total
   iterations.
8. **Only if observed** — add `frontier_attempts`; later consider semantic
   search. Do not add subagents or batched route execution without a recorded
   failure mode they solve.

---

## 11. Acceptance scenario: reset and find the bakery

Run the same task twice.

### Bakery already mapped

- iteration 0 receives visible injected `[here]`;
- the first model-selected navigation call is `plan_route("bakery")`;
- it returns `known` and a canonical direction sequence;
- the model issues one `move` per step;
- no model-selected `look` or `score` appears;
- each move card shows raw MUD output and “model received” compact output;
- arrival is confirmed by `[here]`, not by an extra look;
- the executed move count equals the shortest known path.

### Bakery not mapped

- `plan_route` returns `explore` or `unknown`, never a fabricated bakery route;
- evidence and frontier choice are visible;
- the model follows known steps, explores exactly one frontier, then re-plans
  with the newly learned room;
- a failed frontier is not retried unchanged in the same turn;
- hook-initiated survey calls are visible and attributed to the hook/survey,
  not to the model.

This is the boundary for v1: reliable shortest-path travel over known memory,
honest frontier-directed exploration over unknown space, and enough provenance
to explain every round trip.
