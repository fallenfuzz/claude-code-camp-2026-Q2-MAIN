# move_to

One movement tool on the player's surface, with route planning, frontier
reasoning and walking moved behind it.

Note: code lives in `week2_capable/`. Numbers come from committed session logs
and batch reports under `.boukensha/`; file and line references were checked
against the working tree.

---

## 1. Why

The player agent has three ways to move — `tbamud__move`, `plan_route`,
`execute_route` — and in the cold case only the worst one is usable.
`execute_route`'s own description says it walks "a sequence of directions
already returned by plan_route's `known` result" (`boukensha_loader.rb:477`),
and in an unmapped world `plan_route` returns `unknown` with a frontier listing
and no path. There are no steps to pass, so the agent correctly falls back to
`move` and pays one full model call per room.

Session `20260729T182950Z-c79e9b97` is the case in full: fourteen iterations,
thirteen model tool calls, of which eleven were a single `move`. It found the
bakery and listed the menu, and still failed its scenario. It cost 49,819 input
tokens against 1,179 output tokens — **97.6% of the turn's spend was re-sending
context** — for $0.0557 against a $0.02 gate.

The turn budget is the scarce resource: five of ten cases in
`boundaries_gate/20260729T182757Z-48647145.json` ended on `max_tokens` rather
than on the agent finishing.

---

## 2. Design

`move_to(destination:)` becomes the only movement tool the player can call.
Everything else moves behind it.

```
move_to("the bakery")
  │
  ├─ plan_route (internal)
  │     known    → walk the path. No reasoning step; there is nothing to decide.
  │     arrived  → return immediately.
  │     unknown  → ↓
  │
  └─ bounded loop:
        Tasks::Navigator            one turn, own context, own prompt
          in:  destination, candidate exits with target names, region label
          out: { direction, reason }
        walk it                     existing execute_route loop —
                                    reconcile_move!, poll, EventClassifier
        re-plan
          arrived? → done
          region_exhausted / exhausted? → stop, say so
          interrupted? → stop, return remaining state
          budget spent? → stop, return where it got to
          else → repeat
```

Two decisions, split by who is competent to make them:

| decision | owner | why |
|---|---|---|
| which direction | `Tasks::Navigator` | Exit *names* carry meaning. `plan_route` orders frontiers by distance and says so in its own output: ordering "knows nothing about what these names mean — you do." |
| how far to walk it, when to stop | the subsystem | Walk, reconcile, poll, classify. Already written and tested. |

The frontier choice is real judgement and the evidence says so both ways. In
`find_bakery_cold` the judge passed the agent specifically for choosing south
(The Temple Square) over north (By The Temple Altar). In
`20260728T190719Z-d2fa7ec6` the agent took the first listed exit repeatedly and
walked through the altar, into The Great Field, and onto a chessboard two zones
outside Midgaard before running out of tokens.

### 2.1 Why a subagent and not the player

`tool_call_opitmize.md` §HN3's separability test decides it: does the
sub-decision need the player's **goals and history**, or only its own **subject
matter**? Choosing a frontier needs the destination string and the candidate
names. It does not need the preceding eleven room descriptions or the
instruction to say good morning. Separable, so Tier 2.

The economics follow from `Boukensha.run_task` building its own `Context` and
its own `Agent` with its own `max_turn_tokens` (`boukensha.rb:243-264`): the
navigator's spend does not land on the player's turn budget, and each navigator
call is a fresh ~600-token context with no tool-schema prefix and no
accumulating transcript.

Estimated against the c79e9b97 trace. This is arithmetic under an assumed
number of frontier decisions, not a measurement:

| | player budget | elsewhere | player-turn calls |
|---|---:|---:|---:|
| today | 49,819 | — | 14 |
| move_to | ~9,000 | ~3,000 | ~3 |

### 2.2 What this replaces that a prompt could not

Every existing mechanism pointing the agent at batched movement is advisory.
`.boukensha/prompts/player/system.md` already says to call `plan_route` first
"rather than picking exits off the `[here]` block one at a time" and to re-plan
after a failed move. The agent obeys on iteration 1 of essentially every session
and then drifts. `move_to` puts the reasoning on the code path instead of
requesting it.

---

## 3. Surface change

| tool | today | after |
|---|---|---|
| `move_to` | — | `tasks.player.allow` |
| `plan_route` | `tasks.player.allow` | `tools.navigation.allow` |
| `execute_route` | `tasks.player.allow` | internal to the subsystem |
| `tbamud__move` | `tasks.player.allow` | `tools.navigation.allow` |

**`tbamud__move` cannot simply be deleted.** `execute_route` dispatches it
through the *player's* registry today — `player_call_tool = ->(name, args) {
self.call_tool(name, **args) }` (`boukensha_loader.rb:457`), which reaches
`RunDSL#call_tool` → `@registry.dispatch`, gated by `tasks.player.allow`. Drop
`tbamud__move` from that list and `Registry#tool` never registers it, so the
walk raises `UnknownToolError` on step 1. It has to move to a navigation slice
and the walker has to be rebound to
`Boukensha.tool_dispatcher("navigation", initiator: "hook")`.

Hiding it via `turn_policy` instead does not work either: `Registry#dispatch`
checks the turn policy on every call (`registry.rb:41-43`), and the walk runs
inside a model iteration, so a policy withholding `move` blocks the subsystem's
own steps.

The precedent is `tools.room_survey.allow`, where `tbamud__look` is granted to
the survey and appears nowhere on the player's surface.

---

## 4. Limits and tunables

This is the part worth getting right, because an unbounded loop inside one tool
call is precisely how the pre-bootcamp outer layer failed, and because a limit
that is declared but not enforced is worse than no limit.

### 4.1 Two config precedents already exist

| kind | read by | example today |
|---|---|---|
| **task** — provider, model, prompt, iteration and output ceilings | `Tasks::Base` (`tasks/base.rb`) | `tasks.judge.max_iterations: 1`, `tasks.judge.max_output_tokens: 2048` |
| **subsystem** — permission slice and behavioural knobs | `cfg.dig(:tools, <name>, ...)` (`boukensha.rb:432`) | `tools.room_survey.allow`, `tools.room_survey.look_candidates.extractor` |

`move_to` needs both, because it is both. `Tasks::Navigator` is a task and gets
task settings for free; the walking subsystem is not a task and needs its own
block.

### 4.2 Proposed settings

```yaml
tasks:
  navigator:
    provider: anthropic
    model: claude-haiku-4-5
    max_iterations: 1          # one turn: read candidates, answer with a direction
    max_output_tokens: 256     # a direction and a sentence of reasoning
    prompt_override:
      system: true

  # Fires only when the navigator raises `scope_suspect` (§5.4), so it is the
  # one place a stronger model is affordable. Starting equal to the navigator;
  # find_mayor_split is the case that settles whether it needs more.
  cartographer:
    provider: anthropic
    model: claude-haiku-4-5
    max_iterations: 1
    max_output_tokens: 512     # a room id, a label, and the reasoning for the boundary
    prompt_override:
      system: true

tools:
  navigation:
    # The subsystem's own slice. `tbamud__move` appears here and nowhere in
    # tasks.player.allow, exactly as `tbamud__look` does for room_survey.
    allow:
      - tbamud__move
      - tbamud__poll

    limits:
      max_rooms: 12            # total rooms walked in one move_to call
      max_decisions: 6         # navigator invocations in one move_to call
      max_steps_per_leg: 4     # moves walked before re-planning

      # A gate, not a classifier (§5.7): below this the scope question is not
      # put to the navigator at all.
      min_rooms_for_scope_check: 3
```

### 4.3 Which limits are load-bearing, and why each exists

- **`max_rooms`** is the one that prevents the old failure. Without it a single
  `move_to` can walk the map, and the player agent has no visibility into it and
  no chance to intervene. On hitting it the call returns like an interrupted
  route — where it got to, how far it went, and that it stopped on budget rather
  than on failure.
- **`max_decisions`** bounds *spend* rather than *distance*. These are the two
  things that can run away independently: a long corridor is many rooms and one
  decision, a dense town is few rooms and many decisions.
- **`max_steps_per_leg`** decides how stale a direction is allowed to get. Walk
  the whole way on one decision and you re-derive the chessboard failure; re-plan
  every step and you have rebuilt the per-move model call this design exists to
  remove.
- **`tasks.navigator.max_iterations: 1`** is what keeps the navigator a
  judgement and not a second agent. It has no tools and nothing to iterate on.
  Same posture as `tasks.judge.max_iterations: 1`.
- **`min_rooms_for_scope_check`** keeps the scope question off the payload in the
  common case. It suppresses obvious negatives without encoding the judgement —
  the distinction §5.7 turns on.

None of these should be constants in Ruby. "Is Haiku good enough to pick a
frontier" and "how far is too far" are questions the batch harness answers, and
they can only be swept if they are configuration.

### 4.4 On `max_iterations` for the player agent

Two ceilings run in parallel today: `max_iterations` and `max_turn_tokens`, and
`Agent#run` stops at whichever trips first. In every failing case examined the
reason was `max_tokens`. `max_iterations` has never been the binding constraint,
because iterations vary in cost — a `move` iteration and an `execute_route`
iteration are one each and are not comparable, and that gap widens once one
tool call can cover a dozen rooms.

That is an argument for demoting `max_iterations`, not deleting it. It remains
the only thing that stops a zero-token pathology — a loop that dispatches, gets
an error, and retries cheaply — from spinning until the wall clock kills it.
Keep it as a backstop set well above the expected working range; treat
`max_turn_tokens` as the real budget. Delete nothing until a batch run shows
`end_reason: max_iterations` is genuinely unreachable.

### 4.5 A gap to fix first

**Scenario limits are declared but not enforced.** `limits.max_iterations` and
`limits.max_turn_tokens` are logged (`case_runner.rb:63`) and used as
expectations (`expectations.rb:43`), but never reach the agent —
`BoukenshaLoader.run_case(goal:, launch:, max_output_tokens:, on_progress:)`
(`boukensha_loader.rb:504`) takes no limits parameter. Only `wall_timeout_s` is
enforced, by the parent (`runner.rb:135`).

The traces confirm it: `find_bakery.yml` declares `max_iterations: 15` and
`max_turn_tokens: 40000`, and cases ran to 16, 17 and 19 iterations and 60,000+
turn tokens — the `settings.yaml` defaults of 25 and 60,000.

This has to be fixed before any of §4.2 is tuned, or the sweep measures nothing.
It also means the scenarios have been reporting against a budget they were not
running under.

---

## 5. Regions

`boundaries_revised.md` gives exploration its scope, and nothing has ever
exercised it — the journal records that the agent "never called its new region
commands to create a region or split a region." Moving direction-choosing to the
navigator does not fix that by itself: the navigator would skip those tools for
the same reason the player did.

### 5.1 What is already automatic, and what is not

Region *membership* needs no tool. Every room inherits the region of the room it
was first entered from, and a room reached with no arrival edge seeds a
provisional region labelled after the seed room and marked unconfirmed
(`boundaries_revised.md` §2). `StateBlock.region_line` renders it, and
`plan_route` already scopes exploration through `store.region_descendants`.

What never happens is the *judgement*: turning
`⟨from The Temple Of Midgaard⟩ — unconfirmed` into "Midgaard", and noticing that
a distinct quarter began at a particular door. Those are `name_region` and
`split_region`, which have been on the player's surface and uncalled.

### 5.2 Hooks are the wrong lever

A hook injects context; it cannot make a model produce anything. The unconfirmed
tag is *already* the nudge — boundaries_revised calls it "the whole prompt for
naming" — it is already in the state block, and it already fails. A
navigator-side hook would be the same advisory nudge in a smaller context.

Separately, `run_task` builds its own `Context` and `Agent`, and with no explicit
hooks argument the navigator gets the null `Hooks.new`. That is correct: the
navigator should not be reconciling position or rendering state blocks. The
subsystem hands it a purpose-built payload, and that construction *is* the
injection.

**The lever is the output schema.** A field the navigator must fill cannot be
skipped the way a tool it may call can be.

### 5.3 Naming: a required field

```
navigator out: { direction, reason, place, scope_suspect, scope_reason }
```

`place` is what the navigator believes it is standing in. The subsystem applies
it — calling `name_region` when `place` is given and the current region is still
unconfirmed — rather than the model reaching for a tool.

This adds no new reasoning: the navigator already has the room name, the region
label, the candidate exits and the destination in front of it. "Which way now"
and "what place is this" are the same look at the same data.

**`place` must have a legal "unchanged / don't know" value.** boundaries_revised
forbids deriving a place name from a room name — the temple is *in* Midgaard — so
a field that demands an answer every leg will manufacture confident bad labels at
one per leg. Fire a rename only on a non-null `place` against an unconfirmed
region.

### 5.4 Splitting: detection and placement are different jobs

They need different data, which is what makes them separable:

| | asks | needs | fires |
|---|---|---|---|
| `Tasks::Navigator` | is this scope still meaning *here*? | the shape line it already sees | every leg, as output fields |
| `Tasks::Cartographer` | where does the new place begin? | the region's rooms, edges, arrival edges | only when signalled |

Placement needs the region's room graph to find the single entrance a quarter
hangs off. Shipping that graph into every leg decision is expensive, and letting
the navigator guess without it produces exactly the interior-edge boundary
`find_mayor_split.yml` names as the failure.

**Detection reads distances, not counts.** The count misleads —
`find_mayor_split.yml` is explicit that twelve exits in a dense little town was
scope working perfectly, and that sixteen doors at a median of six with half
withheld six to twelve moves away is scope that has stopped meaning "here".
`RegionShape.line` already prints all four numbers, inserted by `plan_route` on
`explore` / `unknown` / `region_exhausted`:

```
region: ⟨from The Temple Of Midgaard⟩ — unconfirmed (1 room · 5 unexplored exits · nearest 0 moves, median 0)
```

The evidence therefore reaches the navigator for free, and `scope_suspect` is a
boolean plus a sentence on an answer it is already producing.

### 5.5 The cartographer

Fires only on `scope_suspect`. In: the region's rooms with names, their
connectivity, each room's stored arrival edge, which rooms hold unexplored exits
and at what distance, and the current room. Out:

```
{ split_at_room_id, label, within, reason }   or   { split: false, reason }
```

**It must be able to decline.** A navigator that flags a large-but-coherent
region is a false positive, and the cartographer holding the full graph is the
only thing positioned to say so. Without a legal "no split", the first uneasy leg
manufactures a permanent boundary — worse than no boundary, since `⟨brackets⟩`
exist precisely so a machine-made label reads as provenance rather than a claim.

### 5.6 Placement stays exact even when the signal is late

A leg covers up to `max_steps_per_leg` rooms, so "this is somewhere different"
arrives after the boundary was crossed, and `find_mayor_split.yml` marks
splitting from deep inside a region as the failure — the boundary is the edge the
room was *first entered by*.

That is recoverable because the edge is persisted per room rather than only held
transiently: `rooms.arrived_from_room_id` and `rooms.arrived_direction`
(`schema.rb:295-296`), written by `create_room` at discovery. The cartographer
names a room; the subsystem reads that room's stored edge and places the boundary
there, however long ago it was walked.

### 5.7 A gate, not a classifier

boundaries_revised deliberately refuses to code a threshold — "nothing in the
code branches on either number, and the judgement is the model's." Keep that. A
deterministic *gate* is a different thing from a deterministic *decision*: do not
put the scope question to the navigator at all when the region has one room and a
median of zero. That suppresses obvious negatives without encoding the judgement,
and keeps the fields off the payload in the common case.

---

## 6. Attribution

Collapsing N round trips into one tool call must not collapse them in the
session log. The subsystem must, exactly as `RoomSurvey` does:

- dispatch through `Boukensha.tool_dispatcher(..., initiator: "hook")` so every
  MUD call appears with an initiator;
- open its own operation span per leg, so `mud_monitor` nests the walk rather
  than scattering unexplained commands;
- journal each navigator decision with its `reason`, because otherwise a wrong
  turn goes from eleven visible `move` calls to one opaque "walked 9 rooms,
  found nothing" and becomes undebuggable;
- journal every region declaration the subsystem makes on the model's behalf —
  the `place` that triggered a rename, and the cartographer's `reason` and chosen
  room for a split. A boundary that appears with no recorded justification is
  indistinguishable from a bug in the derivation.

---

## 7. Risks

1. **Unbounded loop.** §4.3. Bound it before building it.
2. **Latency concentrates.** ~1.9s per model call, so six decisions is ~11s
   blocked inside one tool call. Total wall clock may not worsen — the whole
   c79e9b97 session was 31s — but it becomes one long span, which is only
   acceptable if §6 holds.
3. **Unnamed frontiers.** `plan_route` renders `e[:target_name] || '(unnamed)'`.
   A room reached by movement text without a survey has no target names and the
   navigator degrades to guessing. Needs a defined fallback rather than an
   arbitrary pick.
4. **Capability cliff.** With `move` gone, anything the subsystem's author did
   not anticipate becomes impossible — notably opening a door, since the
   `[ Exits: ]` line omits closed ones. There is no `open` tool on the surface
   today, so nothing regresses, but the cliff is real the day one is added.
5. **Two writers near each other.** The navigator reads the store while the
   walker writes position through `reconcile_move!`. The store's
   "who is the writer" discipline has to hold.
6. **A wrong boundary is durable.** Declarations are earned and never
   overwritten, and membership re-derives through them, so a false split
   permanently mis-scopes every later `plan_route` in that area. This is why
   §5.5 requires a legal decline and §5.3 a legal "unchanged" — the failure mode
   is not a missing region, it is a confident wrong one.

---

## 8. Tests

**Surface**
- The player registry contains `move_to` and neither `tbamud__move`,
  `plan_route`, nor `execute_route`.
- `tools.navigation.allow` grants `tbamud__move`; `tasks.player.allow` does not.
- `move_to` performs zero calls through the player's registry.

**Behaviour**
- Known destination: one `plan_route`, zero navigator calls, one walk.
- Unknown destination: navigator called once per leg, never more than
  `max_decisions`.
- `max_rooms` reached returns a structured stop naming budget as the reason, not
  a failure.
- An interrupting event mid-leg returns remaining state, as `execute_route`
  already does.
- A death mid-walk clears `current_room_id` — the Void must never be recorded as
  explored (`note_death`).

**Regions**
- A navigator answer with `place` set against an unconfirmed region calls
  `name_region`; against a confirmed one it does not.
- A navigator answer with `place` null or "unchanged" never renames anything.
- `scope_suspect` is not asked for at all below `min_rooms_for_scope_check`.
- A cartographer returning `split: false` leaves the region untouched.
- A split lands on the arrival edge of the room the cartographer named, read from
  `rooms.arrived_from_room_id` / `arrived_direction`, even when that room was
  several legs back.
- Every rename and split appears in the journal with the reason that produced it.

**Limits**
- A scenario's `limits.max_iterations` and `max_turn_tokens` are actually
  enforced on the agent (guards §4.5).
- `tasks.navigator.max_iterations` is read from settings, not hardcoded.

**Accounting**
- Player-turn input tokens for `find_bakery_cold` are asserted against a
  committed baseline, so a regression shows up as a diff.

---

## 9. Delivery order

1. **Fix §4.5.** Two lines of plumbing. Everything downstream is unmeasurable
   without it, and the existing reports are currently misleading.
2. **Baseline.** Record player-turn tokens and calls for `find_bakery_cold` as
   it stands.
3. **Navigation slice.** Move `tbamud__move` to `tools.navigation.allow`, rebind
   the walker to its own dispatcher. No behaviour change; proves the seam.
4. **`move_to`, known branch only.** Wraps `plan_route` + the existing walk. No
   navigator. Should be neutral-to-better immediately and collapses the current
   two-iteration plan-then-execute into one.
5. **`Tasks::Navigator` and the unknown branch**, bounded per §4.2. Direction
   only — `place` and `scope_suspect` present in the schema but ignored by the
   subsystem, so the fields can be read in the logs before anything acts on them.
6. **Act on `place`** (§5.3). Renaming is the safe half: it clears an unconfirmed
   label and creates no boundary. `find_bakery_cold` should start showing named
   regions.
7. **`Tasks::Cartographer` and splitting** (§5.5), measured by
   `find_mayor_split`, which needs the `snapshot:midgaard` map its file already
   calls for.
8. **Sweep the limits** against the batch harness.

Steps 1 and 2 are independent of the rest and can land now. Steps 5–7 are
deliberately staged so the region judgement can be observed before it is allowed
to write, since §7.6 makes a wrong boundary durable.

---

## 10. Open questions

- **Should `plan_route` come back to the player's surface?** Removing it means
  the agent cannot ask "do I already know where X is" without committing to
  travel. No scenario needs that today. Add it back on evidence.
  - [Decision] no, the player agent will not have access to move or plan_route
- **What does `move_to` take?** A destination string is the natural intent, but
  the agent sometimes wants "explore that way" with no destination in mind. One
  optional direction argument may cover it; two tools would reintroduce the fork
  this design exists to remove.
  - [Decision] natural itent for now, we'll need to see how the agnet performs
- **Does the navigator need the region label?** `boundaries_revised.md` argues
  region is what makes scope meaningful. If the navigator reasons about place on
  every decision, it is also the natural place for `split_region` to get called
  — which the player agent has never volunteered to do.
  - [Decesion] It sounds like this whole region and labeling needs to be considered, and worked in our exploring loop.
  - Worked into §5. Naming becomes a required navigator output field rather than
    a tool it may call; splitting separates detection (navigator, from the shape
    line) from placement (`Tasks::Cartographer`, from the region graph). Two
    questions §5 leaves open: whether one navigator call can carry both the
    direction judgement and the place judgement without degrading either, and
    whether `min_rooms_for_scope_check` is the right kind of gate or should key
    on median distance instead of room count.
    - [Decision] Welp we'll just have it handle two repsonsibiltiies that or you can make it a turn turn call? 
- **Which model.** Starting position is Haiku, matching the player. Whether a
  frontier choice needs more than that is a config change and a batch run.
    - [Decision] keep with haiku for now
