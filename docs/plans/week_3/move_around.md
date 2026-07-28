# Moving Around Subsystem

Note: our code is in week2_capable because week 2 and 3 share the same folder.

## Problem 1 - Dumb Planing and Exploring of Movement
Despite our agent having a knowledge of previous locations its explored
It does not currently inject into context existing locations or paths to navigate to said location.
Right now exploration exploration is expensive because the agent will reason every single step,
and its not deeply thinking about its movements. So movement is token expensive.

## Problem 2 - Poor Budgeting of Movement
Another problem is that our agent wil stop based on interation count and
max token usage. I want the budget of tokens to be within reason of a task,
and so these hard limits can simply have the agent stop and wait, when its necessary.

Very likely we will delegate planning and exploring to a subtask that will have its
own context, but the question is when its actually moving there's an average cost of movement

ANd since lots of movements look the same, can be more agresive with vacumming, or summarzing prior
reasoning steps than wait to full compact message history so we end up having a more predicatable token flow.

What does agent really need to know about its past?

### Problem 3 - Course Correction

I think I have alot of uncertainty about course correction and 
when agent should have to check in. Can a route me assesed and
then a check happens mid way or should we be more focused on implementing
our polling to watch for event triggers to queue tasks, but then we are getting
into implement goal and task management. Is implementing that system have to happen
first.

## Technical Guesses
This is my guess, but not necessiarly the solution we will implement.
Its intended for technical exploration.

Agent Scenario: (I know where to go)
User asks to go to Bakery
The Player Agent knows We have been to bakery been before.
I can call the tool `plan_route(destination)`.
The tool will a single or multiple routes
The reason it might return multiple routes since there is choice to be made:
- much longer but safer route
- shorter but toll road
- not efficent but better for exploring surrondings before fully proceeding
The Player Agent chooses the best route.
The subsystem automatically moves the player to the destination.

unawnsered question: how does the agent know to check in on it route planning
based on emerging events <saw something cool, someone talked to me, new enemy might be too strong>

Agent Scenario: (I don't know where to go)
User asks to go to Bakery
The Player Agent has never been to bakery before.
<Should the agent be able toa ask clarifying questions before executing a plan?>
The Player Agent takes a look of it known memory of map of the world
and it reasons based on froniters possible places the Bakery could be.
It create a task list of possible explore paths
It called plan_route to help navigatie to said frontiers.
<does the agent have to reason every single turn>
<does it move randomly X amount of times and then reformulate if the plan should be given up>
<will it know when to avoid calling plan_route vs exploring>

Probably need to use Dijkstra's algorithm
Can hold entire map in memory
probably have to score nodes on the route based on danger to make suggested paths etc
We need a semantic search for sqlite possible to help match a title name based on the location the agent picked out.

## Technical Exploration

Measured against the code in `week2_capable/` and the Dummy profile's real data
(`.boukensha/profiles/Dummy/`) on 2026-07-27. Every number below came from the
repo, not from reasoning about it.

### 0. The session that proves the whole document

Three sessions on 2026-07-26 were given the task **"Find the bakery and list the
menu"**. All three ended the same way:

```
20260726T165359Z  max_tokens  15 iterations  66,240 tokens   bakery not found
20260726T170121Z  max_tokens  15 iterations  63,496 tokens   bakery not found
20260726T171635Z  max_tokens  15 iterations  65,269 tokens   bakery not found
```

**The Bakery is room 12 in `knowledge.sqlite3`. First seen 2026-07-23, visited 3
times.** It has been in the agent's own knowledgebase for three days.

At iteration 4 of the last session the agent was standing in Market Square and
its state block read:

```
[here] Market Square  (visit 15)
exits: east→Main Street ✓ | north→The Temple Square ✓ | south→The Common Square ✓ | west→Main Street ✓
```

The Bakery is `Market Square --west--> Main Street --north--> The Bakery`. Two
moves. It went east, and spent the remaining eleven iterations walking into the
sewers. The wrap-up text it wrote itself:

> "I've been exploring the MUD systematically... I've mapped out several areas
> but have not yet found the bakery."

This is Problem 1 in one artifact. The agent is not bad at pathfinding — it has
never been shown the graph. `StateBlock` renders exactly one room's exits
(`state_block.rb:73`), and the system prompt tells it to read that line and
prefer `?` over `✓`. Nothing in the entire context path can express "a room
called The Bakery exists, two hops west-then-north."

### 1. What already exists (verified)

| Piece | Where | Status |
|---|---|---|
| Room graph in SQLite | `mud/memory/schema.rb` V1, `rooms` + `room_exits` | Built, populated |
| Frontier marker | `room_exits.target_room_id IS NULL` + partial index | Built |
| Position reconciliation | `Mud::Hooks#before_model` → `resolve_position` | Built |
| Per-iteration state injection | `Context#state_block`, trailing user turn | Built |
| Turn-scoped tool narrowing | `Hooks#compute_turn_policy` + `Permissions` | Built, **off** (`settings.yaml:13`) |
| Async event capture | `Hooks#before_tools` one `poll` | Built |
| Subagent delegation seam | `Boukensha.run_task` | Built, **unused** |
| Native tool registration | `RunDSL#tool` → `Registry#tool` | Built, unused |
| **`plan_route`** | `docs/plans/week_2/plan_route.md` | **Specced, not implemented** |
| `Store#rooms` / `#all_exits` / `#entities_for_room` | — | Do not exist |

`grep -rn "plan_route\|RoutePlan\|navigation" week2_capable --include=*.rb` returns
nothing. The week-2 plan is a complete, good design that was never built. Most of
this document's Problem 1 is already answered there; read it before re-deriving.

### 2. The map is real and Dijkstra is unnecessary

Dummy profile, live data:

```
rooms       50    (all surveyed)
room_exits 118    79 linked, 39 frontier
entities    36    encounters 3
```

Graph properties, computed over the actual edges:

- **Fully connected** — all 50 rooms reachable from Market Square through linked edges.
- **Average shortest path 5.84 hops**, max 17, over 1,698 ordered pairs.
- **All 39 frontier exits are reachable**; the nearest is 1 hop from Market Square.
- **38 of 39 frontier exits already carry a `target_name`** — `check(exits)` named
  the destination before the agent ever walked there. The frontier is not blind.
- **22 of 79 linked edges have no learned reverse.** One-way until proven otherwise;
  `plan_route.md` §5 is right to refuse reverse inference.
- Ground truth for scale: the bundled world files hold **1,880 rooms** across 29
  zones; Midgaard city (`30.wld`) is 59. The agent knows 50. This graph will stay
  small for a long time.

**Every edge costs one `move`. There are no weights.** Dijkstra degenerates to BFS
here, which is what `plan_route.md` §5 already specifies. Danger-scoring nodes
(the doc's guess) would give Dijkstra something to do — but there are 3 encounter
rows in the whole database. There is no evidence to weight with yet. Build BFS;
add weights when `encounters` has enough rows to justify them.

Name ambiguity is real but small: `Main Street` ×4, `Wall Road` ×3, `The Great
Field Of Midgaard` ×2. And world-wide there are three rooms named `*Bakery*`
(`30.wld`, `65.wld`, `120.wld`) — "bakery" is not globally unique, so
destination resolution must return alternatives rather than assume one match.

### 3. Semantic search: FTS5 is available, and 50 rows do not need vectors

Checked against the installed gem: **SQLite 3.53.2, FTS5 compiled in,
`enable_load_extension` available.** So the options are all open.

At 50 rooms with a name index already in place (`idx_rooms_name`), a normalized
lexical match — `plan_route.md` §4.2 — resolves "bakery" → room 12 with zero
dependencies. FTS5 becomes worth it when the corpus is descriptions and entity
lines rather than names. Embeddings become worth it only for queries lexical
search *structurally* cannot answer ("somewhere to buy bread", "where I can
sell this sword"), and the local ONNX runtime is already wired
(`Extractors::Model`, 41M params, ~7ms) if that day comes.

Recommendation: lexical → FTS5 → vectors, in that order, each gated on a logged
failure. This is `plan_route.md` §4.2 and §10.8's position and I found nothing to
contradict it.

### 4. Problem 2 is not the problem the document thinks it is

The budget question was framed as "prior reasoning steps accumulate; vacuum or
summarize them." The measurements say otherwise.

Session `20260726T171635Z`, 15 tool-use calls plus one wrap-up:

```
call  1  in=3360  out= 84      call  9  in=4235  out=93
call  2  in=3470  out= 87      call 10  in=4323  out=89
call  3  in=3577  out=104      call 11  in=4412  out=86
call  4  in=3657  out= 85      call 12  in=4511  out=84
call  5  in=3759  out= 78      call 13  in=4610  out=77
call  6  in=3903  out= 90      call 14  in=4720  out=81
call  7  in=3985  out= 89      call 15  in=4869  out=81
call  8  in=4118  out= 79      wrap-up  in=2305  out=168
```

Decomposition of the 61,509 input tokens across the 15 counted calls:

| Component | Tokens | Share |
|---|---:|---:|
| Fixed prefix (system 2,039 chars + 22 tool schemas 7,020 chars), re-sent 15× | ~49,000 | **80%** |
| Transcript growth (`moved west → X` pairs + tool_use blocks) | ~12,500 | 20% |
| Model output for the whole turn | 1,455 | 2% of total spend |

**The agent spent ~60,000 tokens to emit 1,455 tokens of decisions, and four
fifths of that was re-sending the same system prompt and tool list fifteen
times.** Compaction and "vacuuming prior reasoning" attack the 20%. The 80% is
untouched by anything in this document's Problem 2.

Two more things the logs settle:

- **`cache_read_input_tokens` is 0 on every call in every session.** There is no
  prompt caching. `Backends::Anthropic#to_payload` (`anthropic.rb:76`) emits no
  `cache_control` anywhere. `Context`'s own comment claims the state block sits
  "after any prompt-cache breakpoint" — architecturally true, but no breakpoint
  exists.
- **The iteration ceiling never binds.** Across 15 turns on 2026-07-24…26:
  `max_tokens` 11, `completed` 4, `max_iterations` **0**. `agent.max_iterations`
  (25) is dead config; the real limiter is `max_turn_tokens: 60_000`, and it
  trips at ~15 moves regardless of what the task is.

#### The caching catch — worth knowing before planning on it

Minimum cacheable prefix is model-dependent and **`claude-haiku-4-5` requires
4,096 tokens**. The current fixed prefix is ~3,270. Adding `cache_control` today
would silently do nothing — no error, `cache_creation_input_tokens: 0`. Three
honest paths:

1. Do nothing yet. Adding `plan_route` + its prompt section pushes the prefix
   over 4,096 on its own, and caching starts working as a side effect.
2. Switch the player model (`claude-sonnet-5` / `claude-sonnet-4-6` minimum is
   1,024; `claude-opus-5` is 512).
3. Accept ~$0.06/turn and treat the token budget as a capability limit, not a
   cost one — which is what it actually is.

**And `memory.turn_policy` is in direct tension with caching.** Tools render
first in the request, so changing the advertised tool set invalidates the tools
*and* system *and* messages cache tiers. Pinning `move` to the current room's
exits rewrites the tool list every iteration, which would guarantee a 0% cache
hit rate. These two features cannot both be on. Worth deciding deliberately
rather than discovering.

#### "What does the agent really need to know about its past?"

From the transcript: almost nothing. The 12,500 tokens of history are pairs of
`{"type":"tool_use","name":"tbamud__move","input":{"direction":"east"}}` and
`moved east → Main Street`. Everything durable in them is already in
`knowledge.sqlite3` and re-rendered fresh each iteration.

The one thing the transcript carries that memory does not is **what this turn has
already tried** — and even that is better served by a `tried: east, north` line in
the state block than by thirty messages. That is a ~15-token replacement for
~12,500.

### 5. Problem 3: the event stream already exists

The doc asks how the agent learns to check in on emerging events. It already
receives them. Across the same sessions, **161 polls, 22 non-empty (14%)** — and
the payloads are exactly the class of thing the doc is worried about:

```
The creepy crawler misses a wild punch at you. / You barely pierce the creepy crawler.
A kind soul says, 'get some clothes on! Here, I will help.'
The Beginning Of The Passage / You find yourself entering a long corridor...
You are hungry. / You are thirsty.
The sun slowly disappears in the west.
```

Unbidden combat, an NPC initiating conversation, hunger, nightfall. All of it
already reaches the model — `Hooks#before_tools` polls, `event_lines` filters the
prompt line, and `StateBlock#events_line` renders it as `just now: …` for exactly
one iteration.

What is missing is not the signal. It is that **every event has the same weight**.
"You are hungry" and "the creepy crawler is attacking you" arrive as the same
undifferentiated `just now:` string, and nothing tells a route-follower that one
of them should abort the route.

So the answer to *"does goal and task management have to be built first?"* is
**no**. The minimal interrupt contract is small and does not require a task system:

1. Classify poll lines into `informational` / `notable` / `interrupting` using the
   regexes `Hooks` already owns (`DEATH`, `VICTORY`, `FLED`, `DEPARTURE`,
   `ARRIVAL`) plus a combat-damage pattern.
2. A route in progress carries a `stop_on:` set. Anything `interrupting` ends the
   route and hands control back to the model with the remaining steps intact.
3. The state block says which step of which route it is on, so a re-plan is a
   single tool call rather than a rediscovery.

That is a field on the route object and one classifier method. Goal/task
management is a *later* generalization of it, not a prerequisite.

Also relevant to course correction: **7 of 151 moves (5%) failed with "Alas, you
cannot go that way."** `plan_route.md` §6.3 already flags the missing
`frontier_attempts` table for exactly this, and the 5% is the evidence that it
matters.

### 6. Where this document and `plan_route.md` disagree

One real conflict, and it needs your decision rather than my inference.

**This document's "Technical Guesses" says:** *"The subsystem automatically moves
the player to the destination."*

**`plan_route.md` §5 says:** *"Do not add an `execute_route` tool in v1. Batched
movement would hide the exact step that failed, bypass per-step state refresh,
and make asynchronous events harder to attribute."*

The measurements support both sides, which is why it is a real decision:

- *For batching:* a move costs **46ms of MUD time and ~4,100 input tokens plus
  1.9s of inference**. 30.2s of the 33.6s turn was model inference; 684ms was the
  MUD. Per-step model reasoning is ~98% of the cost of walking. Batching a
  5-step known route into one tool call turns 5 iterations into 1 — a ~5×
  reduction on the dominant cost, and the single highest-leverage change available.
- *Against batching:* the 14% non-empty poll rate means roughly **one in seven
  steps has something happening during it**, and `Hooks#before_tools` only polls
  between model calls. A batched walk skips those windows entirely, so a fight
  that starts mid-route is discovered on arrival rather than when it starts.

The resolution I'd suggest, though it is your call: **`execute_route` that
executes step-by-step inside one tool call**, polling and reconciling between
steps, and returning early with a structured reason when the step-level
classifier from §5 says to stop. That keeps per-step observability and the poll
window while collapsing N model round-trips into one. It is strictly more work
than either v1 position, which is exactly why it should be a deliberate choice.

Two constraints on how it could be built:

- `tbamud__move` takes exactly one direction (`primitives.json:71`). A route
  cannot be expressed as one existing tool call.
- `MudManager::Session` drains the buffer before send and reads to prompt after.
  Multiple directions in one `send_raw` would return one merged blob whose
  per-step attribution is ambiguous, and `Hooks#movement_outcome` parses a single
  look. **Whether tbaMUD even accepts `;`-separated commands is unverified** —
  the engine source is not in this repo (only world files under
  `week0_explore/circlemud-world-parser/assets/`), and per the standing rule we
  should read tbaMUD's `interpreter.c` rather than assume CircleMUD behaviour.
  The safe design is N sequential sends inside one tool call, which needs no such
  assumption.

### 7. Open questions I could not answer from the repo

- **Does the state block change if the model gets a map summary?** A "known
  destinations" line would compete with the ~45-token discipline `StateBlock` was
  built to protect. `plan_route.md` §2 says keep the map out of the block and put
  it behind a tool; I agree, but it means the agent must *think to call the tool*,
  which is precisely the failure the bakery session shows. Prompt wording carries
  this, and prompt wording is not testable from here.
- **Should `plan_route` be a subagent?** `plan_route.md` §4.2 argues no — a
  subagent cannot learn more from the same database and adds latency. The
  delegation seam (`Boukensha.run_task`) exists and is unused, so this is
  available either way. Nothing measured here changes that answer.
- **`max_iterations` vs `max_turn_tokens`.** Since the iteration ceiling has never
  fired in 15 turns, either it should be lowered to something meaningful or the
  token budget should be the only documented limit. Two ceilings where one is
  dead is worse than one.

### 8. Suggested order, by measured leverage

1. **`plan_route` (BFS + lexical resolution)** — turns the 66k-token bakery
   failure into a 2-move success. `plan_route.md` §10 steps 1–3 are ready to build;
   they need `Store#rooms`, `#all_exits`, `#entities_for_room`.
2. **Prompt contract** — `plan_route.md` §7. Without it the tool exists and the
   model doesn't call it.
3. **Decide `execute_route`** — the 5× iteration reduction, gated on §6 above.
4. **Event classification + route interrupt** — §5. Small, and it is what makes
   (3) safe.
5. **`frontier_attempts`** — the 5% failed-move rate, `plan_route.md` §6.3.
6. **Budget** — resolve caching-vs-`turn_policy`, drop the dead
   `max_iterations`, and only then look at transcript compaction (the 20%).


Here's a concrete trace of what §11's acceptance scenario ("bakery already mapped") looks like turn-by-turn, using the real data from the doc — Bakery is room #12, reachable from Market Square via west → north — plus the v1 tool contract from plan_route.md. This merges two documents: the shipped v1 spec (no execute_route) and the week_3 doc's proposed extension (batched execute_route), which is explicitly an open decision, not something built. I've labeled which is which.

Trace A — v1 as specced (one move per iteration)

Iteration 0
- Sees: [here] Market Square (visit 15) / exits: east→Main Street ✓ | north→The Temple Square ✓ | south→The Common Square ✓ | west→Main Street ✓ + user goal "find the bakery and list the menu"
- Reasons: system prompt (§7) says: "For any goal to find or travel to a place, call plan_route first."
- Calls: plan_route(destination: "bakery")
- Returns (per §3.2, known format, computed by BFS ov
[route] bakery — known
to: The Bakery (#12)
path: west → north
2 moves: Market Square → Main Street → The Bakery

Iteration 1
- Sees: the route result above; [here] still Market Square (plan_route did no MUD I/O)
- Reasons: follow step 1 of the returned path
- Calls: tbamud__move(direction: "west")
- Returns: raw MUD text ("You walk west.\n[Main Stree moved west → Main Street per the raw/model-receivedsplit in §1. Hook rebuilds [here] for next turn.

Iteration 2
- Sees: [here] Main Street ... (no new user message — this is the "does the agent have to reason every turn" question from
move_around.md; under v1, yes, one call per iteration
- Reasons: follow step 2
- Calls: tbamud__move(direction: "north")
- Returns: moved north → The Bakery

Iteration 3
- Sees: [here] The Bakery ... — arrival confirmed by y an extra look (§11 explicitly requires this)
- Reasons: destination reached; task also needs the menu, so a model-selected look/examine here is legitimate (the forbidden case is only pre-context look before iteration 0)
- Calls: tbamud__look(target: "menu") (or whatever thspecified in either doc)
- Returns: menu text → model writes the final answer.

Result: 1 plan_route + 2 move + 1 look = 4 tool calls6k-token session that never arrived.

Trace B — with the proposed execute_route (week_3 doc §6, undecided)

Iteration 0 is identical. Then:

Iteration 1
- Sees: the same known route result
- Reasons: route is fully known, so hand off the wholon at a time
- Calls: execute_route(steps: ["west", "north"]) — internally this is N sequential MUD sends inside one tool call, polling and
reconciling between each step (not a raw ;-joined commmand support is unverified)
- Returns:
[route] executed 2/2
step 1: west → Main Street (ok)
step 2: north → The Bakery (ok)
arrived: The Bakery (#12)
unless an interrupting-classified poll event fires mi, in which case it returns early:
[route] executed 1/2 — stopped
step 1: west → Main Street (ok)
stopped: combat detected ("The creepy crawler misses
remaining: north

Iteration 2 — the menu lookup, same as Trace A's iteration 3.

Result: 1 plan_route + 1 execute_route + 1 look = 3 travel iterations into 1. This is the 5× leverage claimin §6, but it's the part of the plan that isn't built and isn't agreed — it needs the event classifier
(informational/notable/interrupting) built first, or in progress becomes invisible until arrival.

The unmapped-destination case (briefer, since neitherrace)

Same iteration 0 shape, but plan_route returns explore:
[route] bakery — explore
clue: Market Street (#18) mentions shops and food
frontier: east from Market Street
path: north → east
2 known moves, then explore east
The model walks the two known moves as normal move calls, then issues one more move in the frontier direction — which is just an ordinary tbamud__move, not a special tool. Whatever room that reveals, Hooks#before_model's survey logic writes it into rooms/room_exits, and the
next plan_route call sees it. If it's not the bakery,an continuing to explore blind — that re-plan is themechanism answering move_around.md's "does it move randomly X times and reformulate" question: no, it re-plans after every unmatched
frontier step, not after a fixed count.
-----
What's actually undecided, per the doc's own §6 and §cute_route gets built at all, and whether the eventclassifier needed to make it safe gets built first or after.

Pulling directly from what both docs flag as open (not settled by the doc itself), here are the real decisions, ordered by how much they block everything else:

1. Build execute_route (batched movement) or not? — the one the doc calls out explicitly as your call

- A — Stay v1-only: one move per model turn, forever. Safest, fully observable, but the ~98%-of-cost-is-model-reasoning problem stays.
- B — Add execute_route now: collapses a known route into one tool call (~5× fewer iterations on travel). But it's unsafe without the event classifier (decision below) — a fight starting mid-route is invisible until arrival.
- C — Build plan_route now, gate execute_route behind the classifier: what the doc leans toward without quite saying so.
[Decision] B: An event classified should be built but at this stage? Yes but lets keep it simple with the regex first.

2. Prompt caching vs. per-turn tool narrowing (memory.turn_policy) — mutually exclusive, not just a tradeoff

turn_policy rewrites the advertised tool list every iteration (pinning move to the current room's real exits). Caching requires the tool list to stay identical across calls. You cannot have both.
- A — Leave turn_policy off (its current state), get caching once the prefix crosses the 4,096-token minimum.
- B — Turn turn_policy on, accept 0% cache hit rate permanently.
[Decision] I have currently just commented out most tools, to defer this decision for later. I am going to add tools back when I explore different scenarios to best figure out if they even need to be honestly cached or another conditional system can be built.

3. How to actually get caching working

The fixed prefix (~3,270 tokens) is currently under haiku's 4,096-token minimum, so cache_control today would silently do nothing.
- A — Do nothing: adding plan_route + its prompt section pushes the prefix over 4,096 as a side effect.
- B — Switch the player model to sonnet/opus (lower minimums: 1,024 / 512).
- C — Accept ~$0.06/turn and treat token budget as a capability limit, not a cost problem.
[Decision] No change to caching right now.

4. Ambiguous-destination policy

When plan_route's search returns several close-scoring rooms (e.g. "square" matching 4 rooms) — always surface alternatives and make the model ask the user, or allow picking-nearest when the task context makes that safe? plan_route.md leans toward always surfacing, but explicitly leaves the exception open.
[Decision] the human user never decides. The player agent does. The agent would reason a turn to choose the path to execute

5. max_iterations vs max_turn_tokens

max_iterations (25) has never fired in any measured session; max_turn_tokens (60,000) is the real limiter. Two ceilings, one dead.
- A — Delete max_iterations, document token budget as the only limit.
- B — Lower it to something that actually binds, as a genuine second guardrail.
[Decision] its true that max_iterations is useless right now. We will leave it alone and revisit later.


6. Does the state block ever hint at known destinations?

Both docs lean toward "no — keep [here] minimal, put the map behind plan_route" — but that's why the bakery session failed: the agent never thought to call the tool. Confirming "prompt wording alone fixes this" vs. adding some lightweight nudge is a real call, not just a formality.
[Decision] We dont know how the model with act, so we will need to ship the simple rule in the system prompt

---
Not open — already settled by the docs, no action needed: plan_route as a native tool (not a subagent), BFS over Dijkstra, lexical search before FTS5/embeddings.