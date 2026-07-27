# Tool Call Optimization
NOTE: This is an exploration document, none of it has been implemented, dont use it.

Note: our code is in week2_capable because week 2 and 3 share the same folder.

## The question

The player agent is granted 22 tools. Across 77 recorded sessions it has called
three. Every one of the other nineteen is re-serialized into the request on every
model call, forever.

So: **what does the player agent actually need tool access to?**

The hypothesis this plan tests is the one that follows from where the codebase is
already heading — that most of those tools are not decisions the player agent
makes, they are *steps inside a task* that a subsystem should own. Combat is the
clearest case: `attack` / `skill_strike` / `cast_spell` / `flee` / `set_position`
are five tools and a state machine spanning several tool calls, and the agent's
only real decision
is **whether to fight this thing at all**.

This plan comes before `move_around.md`'s `plan_route` work deliberately.
`plan_route` is not a new tool bolted onto a 22-tool surface — it is the first
subsystem built to a contract, and the contract should exist first.

---

## 1. Findings from the logs

### 1.1 Tool schemas are the largest fixed cost in the request

Measured on session `20260726T171635Z-484352b5` (15 tool-use calls + one wrap-up).
Solved from two calls of known shape: call 1 carries 22 tools and 391 chars of
messages for 3,360 input tokens; the wrap-up carries `tools: []` and 7,565 chars
for 2,305. The message slope across calls 1→15 is 4.32 chars/token.

| Component | Chars | Tokens | Share of call 1 |
|---|---:|---:|---:|
| **Tool schemas (22)** | 6,997 | **~2,716** | **~66%** |
| System prompt | 2,039 | ~554 | ~17% |
| Messages | 391 | ~90 | ~3% |

JSON schemas tokenize at **~2.6 chars/token** against ~3.7 for the prose system
prompt — braces, quotes and repeated keys are dense. Mean cost is **~123 tokens
per tool**, paid on every call: **~40,700 of the turn's 61,509 input tokens are
tool schemas.**

The logger dedups `system` and `tools` between requests
(`logger.rb:454`, `:465`) — a request event without a `system` key means
*unchanged*, not *absent*. Reading it as absent is what makes the wrap-up look
like it had no system prompt; it did.

### 1.2 The model calls three tools

Across **all 77 session logs**, model-initiated calls:

```
tbamud__move      105
tbamud__examine     3
tbamud__check       3
```

Nineteen of twenty-two have never been called once:

```
flee  set_position  track  attack  skill_strike  consider  say  tell
get_item  drop_item  put_item  equip_item  consume_item  use_magic_item
cast_spell  shop  practice  poll  mud_status
```

### 1.3 The honest caveat

**Those 77 sessions were overwhelmingly navigation tasks.** "Find the bakery",
"explore", "go to X". The combat tools are unused because nothing asked the agent
to fight — not because they are dead weight. The finding is **not** "delete 19
tools." It is:

> The tool surface is fixed while the task is not. The agent pays for combat,
> commerce, and inventory on every single call of a walking task.

That reframing is what makes this a subsystem problem rather than a pruning
exercise.

### 1.4 Per-tool cost, exact

Chars are exact from the logged payload; tokens at the measured 2.58 chars/token.

| Tool | Chars | ~Tokens | Model calls (77 sessions) |
|---|---:|---:|---:|
| `use_magic_item` | 472 | 183 | 0 |
| `equip_item` | 437 | 169 | 0 |
| `get_item` | 406 | 157 | 0 |
| `attack` | 380 | 147 | 0 |
| `tell` | 367 | 142 | 0 |
| `drop_item` | 366 | 142 | 0 |
| `put_item` | 364 | 141 | 0 |
| `shop` | 350 | 136 | 0 |
| `set_position` | 333 | 129 | 0 |
| `skill_strike` | 333 | 129 | 0 |
| `cast_spell` | 330 | 128 | 0 |
| `consume_item` | 323 | 125 | 0 |
| `check` | 301 | 117 | 3 |
| `say` | 292 | 113 | 0 |
| `poll` | 290 | 112 | 0 |
| `consider` | 283 | 110 | 0 |
| `track` | 272 | 105 | 0 |
| `practice` | 267 | 103 | 0 |
| `move` | 261 | 101 | 105 |
| `examine` | 244 | 95 | 3 |
| `flee` | 163 | 63 | 0 |
| `mud_status` | 163 | 63 | 0 |
| **total** | **6,997** | **~2,710** | **111** |

---

## 2. The test for what stays

Two questions decide every tool. Both are already implicitly answered by the
choices this codebase has made — `inspect_room` was deleted, `look` was moved off
the player, `check(kind: score)` was moved off the player. This just states the
rule those decisions were following.

**Test A — does the model's choice of argument *constitute* the gameplay decision?**

- `say(message)` — the message *is* the decision. Irreducible. Stays.
- `move(direction)` — the direction is the decision *while exploring*. Once a
  route is chosen it is not, which is the whole argument for `travel`.
- `attack(target)` — choosing to attack *is* a decision. The follow-up swings are
  not.
- `poll()` — no arguments, therefore no decision. The hook already calls it every
  iteration. Delete.

**Test B — does a subsystem own a sequence longer than one call whose steps
follow rules the model cannot improve on?**

If yes, the subsystem gets one intent-level tool and the primitives move to its
own permission slice.

### 2.1 Three tiers, and the precedent for each

The codebase has already walked a subsystem down all three tiers, which is the
strongest evidence available that this works:

> `room_inspector` was an **LLM subagent** → became a **scripted Ruby tool** →
> became a **lifecycle hook** with no tool at all. — `boukensha_loader.rb:150-170`

| Tier | What the model sees | Use when | Existing example |
|---|---|---|---|
| **0 — Hook** | Nothing. It is *told*, never asks. | The information is needed on every iteration (`before_model`) or once per turn (`before_turn`), and the agent has no choice to make about acquiring it. | `RoomSurvey` + position reconciliation (per iteration); `check(score)` refresh (per turn) |
| **1 — Scripted native tool** | One intent tool, ~120 tokens | The sequence is deterministic given the intent. | `plan_route` (specced), `engage` (proposed) |
| **2 — LLM subagent** | One intent tool | The sub-task needs open-ended reasoning over its own context, and would pollute the player's. | `Boukensha.run_task` — built, currently unused |

**Default to Tier 1.** Tier 2 costs a second model, its own context, and latency;
`plan_route.md` §4.2 already rejects it for route search on the grounds that a
subagent cannot learn more from the same database. That reasoning generalizes.

---

## 3. Answering the combat question directly

The prompt for this plan asked whether a combat subsystem could own combat "which
may or may not use LLM". Working it through:

### 3.1 What the hook already does

`Mud::Hooks` is **already half a combat subsystem** and nobody called it that:

- `COMBAT_TOOLS = %w[attack skill_strike cast_spell]` (`hooks.rb:36`)
- `open_fight` / `settle_fight` / `close_fight` — a state machine spanning several
  tool calls, resolving to one of four outcomes including `abandoned` for walking
  away mid-fight (`hooks.rb:524-558`)
- `VICTORY` / `FLED` / `DEATH` regexes against the MUD's own words
- `encounters` table keyed by `(entity_id, player_level, outcome, hp_before, hp_after)`
- `entity_for` returns `threat_fresh`, and `encounter_note` renders
  *"you died against this at level 3"* into the `here:` line

Everything needed to *decide* a fight is already computed and already in front of
the model. What is not owned anywhere is the *execution*.

### 3.2 Does executing combat need an LLM?

Almost certainly not, on the same grounds that killed the `room_inspector`
subagent. A combat loop is: swing, read HP off the prompt line, keep swinging,
break off below a threshold, rest to recover. The prompt line arrives with every
single MUD response and `RoomParser.parse_prompt` already extracts hp/mana/move.
`set_position`'s own description in `primitives.json` states the recovery rule:

> "Use 'rest'/'sleep' between fights to recover HP and mana. Must be standing to
> move or fight."

That is arithmetic against a threshold, not judgement. **Judgement is whether to
engage**, and that stays with the player agent — informed by `threat`,
`threat_fresh`, and the encounter history the hook already renders.

**Unverified and load-bearing:** this build exposes `check(kind: wimpy)`, so a
wimpy threshold exists, but *how tbaMUD's wimpy auto-flee actually behaves* is not
something to assume from CircleMUD memory — the engine source is not in this repo
(only world files under `week0_explore/circlemud-world-parser/assets/`). Read
`fight.c` / `interpreter.c` before the flee policy is written. If wimpy already
auto-flees server-side, the subsystem's break-off logic is much smaller than
assumed.

### 3.3 Proposed shape

```text
engage(target:, intent: "kill" | "test")
  → { outcome: won|fled|died|abandoned|declined,
      rounds:, hp_before:, hp_after:, xp_gained:, entity_id: }
```

Owns: `attack`, `skill_strike`, `cast_spell`, `flee`, `set_position`, `consider`.
Six tools ≈ **706 tokens** collapse to one ≈ **120**.

`intent: "test"` exists so the agent can probe an unknown mob and break off — the
thing `consider` was for — without holding five tools open to do it.

The subsystem writes `encounters` itself instead of the hook inferring outcomes
from text, which removes the `settle_fight` guesswork. That is a simplification,
not just a move.

---

## 4. Classification of all 22

| Cluster | Tools | ~Tokens | Verdict |
|---|---|---:|---|
| **Free deletions** | `poll`, `mud_status` | 175 | **Delete now.** The hook polls every iteration (`before_tools`); the model has never called either in 77 sessions, and the system prompt exists partly to tell it to *ignore* status. Zero capability loss. |
| **Combat** | `attack`, `skill_strike`, `cast_spell`, `flee`, `set_position`, `consider` | 706 | → `engage` (Tier 1). §3. |
| **Navigation** | `move`, `track` | 206 | `move` stays (exploration is a real per-step decision). `track` → navigation subsystem. `travel` added by `move_around.md`. |
| **Items** | `get_item`, `drop_item`, `put_item`, `equip_item`, `consume_item`, `use_magic_item` | 917 | Largest cluster, **least evidence**. Never exercised. Defer — see §7. |
| **Commerce** | `shop`, `practice` | 239 | Defer. Both are single-call intents already; a subsystem buys little. Candidates for removal-until-needed. |
| **Social** | `say`, `tell` | 255 | **Stay.** Test A: the message *is* the decision, irreducibly. |
| **Perception** | `check`, `examine` | 212 | **Stay, narrowed.** `check` kinds already pinned; `examine` is model-driven curiosity the hook cannot anticipate. |

---

## 5. Target surface and the token math

Illustrative — new-tool sizes are estimates at the measured ~123 tokens/tool mean.

| | Tools | ~Tokens |
|---|---:|---:|
| Today | 22 | 2,710 |
| After free deletions | 20 | 2,535 |
| After `engage` | 15 | 1,949 |
| After `travel` + items collapse | ~11 | **~940** |

At ~940 tokens the fixed prefix becomes `554 + 940 = 1,494`. Solving
`1,494N + 50N² = 60,000` (the message-growth slope measured in §1.1) gives
**~23 iterations against today's 15** — before `execute_route` makes each
iteration cover more ground.

### 5.1 The tension you have to decide

Shrinking the surface and prompt-caching it pull in **opposite directions**:

| Strategy | Prefix | Effective per-call | Trade |
|---|---:|---:|---|
| **A — shrink** | ~1,494 | ~1,494 | Loses capability unless subsystems absorb it |
| **B — grow past 4,096 and cache** | 4,096+ | **~410** (reads bill ~0.1×) | Keeps every tool; needs `cache_control` in `Backends::Anthropic` |

B is *cheaper than A and keeps more capability*, but `claude-haiku-4-5` will not
cache a prefix under **4,096 tokens** and you are at 3,270 — so shrinking moves
*away* from cacheable. Note also that **B is incompatible with
`memory.turn_policy`**: tools render first, so rewriting the tool list per room
invalidates every cache tier.

There is a third option worth naming: Anthropic's API supports `defer_loading:
true` on tool definitions plus a tool-search tool, which appends schemas on demand
*without* breaking the cached prefix. `Backends::Anthropic#to_tools`
(`anthropic.rb:62`) does not emit it. That is the shape that gets both — but it is
a backend change, not a MUD change, and should not be bundled into this plan
without its own measurement.

**This plan assumes A** (subsystems genuinely absorb capability, so the surface
shrinks without losing it) and treats caching as a separate decision. Flagging it
because doing A first forecloses the cheap version of B.

---

## 6. The seam already exists

No framework changes are needed. Verified against the code:

**A subsystem gets its own permission slice by name.** `Boukensha.tool_dispatcher`
reads `cfg.dig(:tools, <name>, :allow)` (`boukensha.rb:418`), so adding a
`tools.combat.allow` block to `settings.yaml` works today with zero code change.
This is exactly how `tools.room_survey.allow` already scopes the survey to `look`
and `check(kind: exits|score)` — tools the player deliberately cannot call.

**A subsystem gets a separate Registry**, which is what keeps its own MUD calls
from re-entering `after_tool` and recursing (`boukensha.rb:391`).

**Its calls are attributed, not hidden.** `tool_dispatcher(..., initiator: "hook")`
stamps every call, and `RoomSurvey` opens its own operation span so the monitor
renders `room survey` nested inside `establish position` rather than four
unexplained commands. A combat subsystem must do the same or the session log
becomes a lie — the MUD round trips still happened.

**A native tool is registered and gated identically to an MCP tool.**
`RunDSL#tool` → `Registry#tool`, which returns `nil` unless
`permissions.allow_tool?(name)` (`registry.rb:19`). So a subsystem tool must be
added to `tasks.player.allow` or it silently will not register.
`validate_referenced!` runs *after* the run/repl block so a rule naming a native
tool resolves (`boukensha.rb:104`).

**One gap:** `Permissions#validate_tool!` — which is what makes
`check(kind: exits)` fail loudly at startup on a typo — is called from
`Tools::Mcp.register_client`, not from `Registry#tool`. Enum pinning on a *native*
tool would therefore not be validated at boot. Either wire native tools through
the same validation or document that native tool rules are name-level only.

**Tier 2 is available if a subsystem ever needs it.** `Boukensha.run_task` resolves
provider/model/prompt/`max_iterations` per task from `settings.yaml`
(`tasks/base.rb`), shares the same MCP clients (no second login), and appends to
the parent's session log when passed the caller's logger. So a subsystem could run
on a cheaper local model later as a config-only change.

---

## 7. Risks

1. **Capability cliff — the real one.** An intent tool hides its primitives, so
   anything the subsystem's author did not anticipate becomes impossible. `engage`
   with no `intent: "test"` means the agent can never probe-and-withdraw. Mitigation:
   design each intent tool's argument set from the *decisions* enumerated in Test A,
   and keep `send_raw` (already present, commented out at `settings.yaml:118`) as a
   documented escape hatch behind its own permission.

2. **Deleting on absence of evidence.** §1.3. The items cluster is the biggest
   token win *and* has the least evidence behind it — no session has ever exercised
   inventory. **Do not collapse items on the strength of a zero call count.** Run an
   item-heavy task first and classify from what it actually does. This is why §4
   defers items and commerce rather than cutting them.

3. **Caching tension.** §5.1. Decide A vs B before shrinking, not after.

4. **Attribution.** Collapsing N MUD round trips into one tool result must not
   collapse them in the session log. `mud_monitor` reads `tool_call`/`tool_result`
   pairs; the subsystem must emit them through `tool_dispatcher` and open its own
   span, as `RoomSurvey` does.

5. **A subsystem is another place memory can go stale.** The hook maintains
   `player_state`; a combat subsystem mutating HP and writing `encounters`
   concurrently needs the same "who is the writer" discipline the store's header
   comment lays out.

6. **Prompt coupling.** Every tool removed from the surface may be referenced by
   the system prompt. `.boukensha/prompts/player/system.md` currently documents
   `consider` output in its Strategy section — that section needs rewriting the day
   `consider` leaves the player's surface, or the prompt describes a tool that is
   gone.

---

## 8. Tests

**Surface**
- The player registry contains exactly the intended tool names; `poll` and
  `mud_status` are absent.
- Each subsystem's `tools.<name>.allow` slice grants exactly its primitives, and
  the player's slice grants none of them.
- A native subsystem tool absent from `tasks.player.allow` does not register
  (guards the `registry.rb:19` behaviour).

**Combat subsystem**
- `engage` opens and closes exactly one `encounters` row per call, with the right
  outcome for each of won / fled / died / abandoned.
- `hp_before` is the reading from before the first blow (the invariant
  `hooks.rb:171` already protects).
- A death inside `engage` clears `current_room_id` — the Void must never be
  recorded as an explored room (`note_death`).
- `engage` performs zero calls through the *player's* registry.
- Every MUD call it makes appears in the session log with `initiator: "hook"` and
  a parent operation span.

**Token accounting** (the point of the exercise)
- A recorded session's tool-schema token count is asserted against a committed
  baseline, so a re-added tool shows up as a diff rather than silently costing
  123 tokens per call forever.

---

## 9. Delivery order

1. **Free deletions** — drop `poll` and `mud_status` from `tasks.player.allow`.
   ~175 tokens/call for a two-line change and no capability loss. Ships alone.
2. **Instrument the baseline** — log tool-schema tokens per session so every later
   step is measured rather than argued. Without this, step 4 is unfalsifiable.
3. **Write the subsystem contract** — one page: the two tests, the three tiers,
   the attribution requirement, the escape-hatch rule. This is what `plan_route`
   is then built against.
4. **Combat subsystem (`engage`)** — the largest evidenced win (~586 tokens) and
   the case that proves the contract on something with a real state machine.
5. **Hand off to `move_around.md`** — `plan_route` / `travel` lands as the second
   subsystem, built to the contract rather than retrofitted.
6. **Re-classify items and commerce** — only after a task has exercised them.
7. **Decide caching vs. dynamic surface** — §5.1, with §2's numbers in hand.

Steps 1–2 are independent of everything else and can land immediately.

---

## 10. Acceptance

Re-run the recorded **"Find the bakery and list the menu"** task from
`20260726T171635Z` after steps 1–4:

- tool-schema tokens per call drop from ~2,716 to ~1,950 (combat collapsed, free
  deletions gone);
- the turn reaches more iterations before `max_tokens` — the ceiling that ended
  all three bakery sessions at 15;
- no model-initiated call to a tool that has moved into a subsystem;
- the session log still shows every MUD round trip the subsystem made, attributed
  to it.

And one adversarial run — a **combat** task, which no recorded session has ever
been — to check that §7.1's capability cliff is not real: the agent must be able
to size up a mob, decline a bad fight, take a good one, and break off a losing
one, using only `engage`.

---

## Open questions for review

- **Is `move` still a player tool once `travel` exists?** Keeping both means the
  model chooses between them on every iteration, which is a decision it has no
  basis for.
  Dropping `move` means exploration has to be expressible as a `travel` intent.
  I lean toward keeping both with the prompt drawing the line at explore-vs-navigate,
  but this is genuinely arguable.
- **Should `engage` be allowed to move?** Fleeing changes rooms, which desynchronizes
  position mid-tool. The hook reconciles on the next `before_model`, so it is
  probably safe — but the fight state machine and the position resolver would be
  writing near each other for the first time.
- **A vs B in §5.1** — shrink, or grow-and-cache. This plan assumes A.
- **Does `tools.<name>.allow` need a general subsystem registry**, or is one
  `tool_dispatcher` call per subsystem at the entrypoint sufficient? Two subsystems
  is not enough repetition to justify an abstraction; four might be.

---

# Scenarios

Two directions. **Forward** starts from something a player would ask for and
unfurls what the agent must be able to do. **Reverse** starts from a tool we
already grant and asks what world it implies exists — because a tool is evidence
of an affordance, and an affordance implies a scenario nobody has written down.

Three of these overturn conclusions from §1–§9 above. Those are marked
**⚠ contradicts**.

### Vocabulary (used precisely below)

| Term | Meaning | In code |
|---|---|---|
| **Turn** | One user request → one response back to the user. | One `Agent#run`. Opens `invoke_agent`, calls `reset_turn_tokens`, ends with `turn_end`. |
| **Iteration** | One step of the agent reasoning with itself inside a turn — one model call plus the tools it dispatches. The user sees none of these. | `@iteration` in the `loop do`. Logged as `iteration`, spanned as `iteration`. |
| **Step** | One unit of work *inside* a single tool call — e.g. one `move` within a route. | Not a framework concept; a subsystem's own business. |

The budget is **per turn**: `max_turn_tokens: 60_000` resets at the top of
`Agent#run` and iterations accumulate against it until it trips. So "this costs
five iterations" means five model calls billed to one turn's budget — which is why
collapsing iterations is worth more than shaving tokens off any single one.

The bakery sessions ended `max_tokens` at **15 iterations inside one turn**
(16 model calls — the wrap-up is billed but is deliberately not counted as an
iteration).

The distinction is the whole argument for subsystems: a subsystem tool turns N
iterations into N steps inside 1 iteration. Steps still cost MUD round trips
(~46ms each) but cost no model inference (~1.9s and ~4,100 input tokens each).

---

## Forward: intent → surface

### S1. "Buy a loaf of bread at the bakery"

The compound errand. Looks like one sentence; is not.

One turn. Five iterations inside it, ~20,000 tokens against a 60,000 budget —
a third of the turn spent on a two-word errand.

```
iter 1   travel(bakery)                  → arrives, 2 moves (2 steps, 1 iteration)
iter 2   ???                             → what is even for sale here?
iter 3   ???                             → can I afford it?
iter 4   buy                             → gold leaves the purse
iter 5   ???                             → did I actually get it?
```

Turn 2 needs a shop listing. `shop` exists with a mode enum. Fine.

Turn 3 is already free — `StateBlock#you_line` renders `43 gold` from
`player_state`, so affordability needs no tool at all. Good: one decision the
agent can make without spending anything.

**Turn 5 is a hole.** `Hooks::SCORE_STALE_TOOLS` includes `shop`, so a purchase
marks the *character sheet* dirty and the next turn re-reads `score` — gold gets
corrected. But `player_items` is only ever rewritten by
`capture_items` off a model-initiated `check(kind: inventory)`. **Nothing marks
the bag dirty after a purchase.** The agent buys bread and its own knowledge of
what it is carrying does not change until it happens to look.

> `items_updated_at` exists precisely so the monitor can say "snapshot as of T"
> rather than invent a delta. The scenario shows the snapshot going stale in a way
> the agent cannot notice.

*Question this raises:* should an item-mutating op mark a `bag_stale` flag the way
`shop` marks `@scored = false`, with the next turn spending one `check(inventory)`
to clear it? That is the identical pattern already proven for `score`, and it is
~6 lines.

*Surface demanded:* `travel`, `shop(list|buy)`. Not a commerce subsystem — the
sequence has a genuine decision in the middle (is this worth 12 gold?) that only
the model can make.

---

### S2. "Get strong enough to beat the minotaur"

A **goal**, not a task. The interesting one.

```
what the agent knows already, free, from the here: line and encounters:
  "you died against this at level 3"   ← encounter_note renders this today
  threat, threat_fresh                 ← entity_for computes this today

what it must then do:
  find things it CAN beat
  fight them
  rest between fights
  repeat ~N times
  re-evaluate
```

The decision — *am I strong enough yet* — is already fully informed. The
codebase renders it into the state block for free.

The **execution is a loop**, and the loop is where the money is. If the player
agent calls `engage` twenty times, that is twenty iterations at ~4,100 input
tokens ≈ 82,000 tokens, which blows the 60k budget before the sixth fight. The
agent would hit `max_tokens` mid-grind exactly the way it hit it mid-walk.

**⚠ contradicts §3.** I framed `engage` as the terminal answer for combat. This
scenario says `engage` is a *primitive at the grind altitude*. The same call is
Tier 1 when the agent decides to fight one mob, and a Tier 0/1 loop-body when the
goal is "level up".

That generalizes uncomfortably: **every subsystem tool is a primitive to whatever
sits above it.** `move` → `travel` → ? and `attack` → `engage` → `grind`. There is
no natural stopping altitude, which means "how many layers" is a design decision,
not something the domain hands us.

*Question this raises:* is the right shape one tool per cluster, or one tool that
takes an **intent and a stopping condition**?

```text
engage(target: "kraken", until: "dead")
grind(until: "level 5", avoid: ["minotaur"])
travel(to: "bakery")
```

That is the same shape three times — *do this until that* — which is suspicious in
a good way. It suggests the real primitive is **a bounded autonomous run with a
stop condition**, and combat/navigation/grinding are arguments to it rather than
three separate tools. Worth arguing about before building `engage`.

---

### S3. "Walk to the bakery" — and something attacks you en route

```
travel(bakery)  step 1 of 4  ok
                step 2 of 4  poll → "The creepy crawler misses a wild punch at you."
                step 3 ???
```

The navigation subsystem cannot answer this. It has no combat remit and no
authority to spend the player's HP.

What it can do is **stop cleanly**:

```text
travel → { status: "interrupted",
           reason: "combat",
           completed: 2, remaining: ["north","north"],
           at_room: 14 }
```

The player agent then decides — fight, flee, or resume — and if it fights and
wins, resuming costs one `travel(resume:)` rather than a re-plan.

*This is the escalation contract*, and it is the thing that makes subsystems safe:
**a subsystem that meets something outside its remit returns control with state
intact and never improvises.** Without it, subsystems silently make decisions the
player agent was supposed to make — which is the capability cliff of §7.1 arriving
by a different road.

*Cross-reference:* `move_around.md` §5 proposes exactly this classifier. One
classifier serves both plans; it should be built once.

*Nasty detail:* `flee` moves the player in a **random direction** with no `move`
call. So the combat subsystem fleeing invalidates the navigation subsystem's route
*and* its position assumption. The hook already handles the position half
(`resolve_position` uses content + arrival edge precisely because "flee moves the
player without a move call"). But a held route is a new thing that can go stale.
**Any subsystem that can flee must invalidate any held route.**

---

### S4. Someone talks to you

From a real poll payload in the logs:

```
A kind soul says, 'get some clothes on! Here, I will help.'
```

An NPC — or player — addressed the agent directly, offered help, and **the agent
said nothing.** `say` has been called **0 times in 77 sessions.**

I previously filed `say`/`tell` under "stays, irreducible" and moved on. The
scenario shows something else entirely.

**⚠ contradicts §1.2.** I read 19 never-called tools as "the surface is fixed while
the task isn't." At least some of those tools are unused for a different reason:
**nothing ever triggers them.** The line arrives via `events_line` as
`just now: A kind soul says…`, renders for exactly one iteration, and is gone. No
prompt section tells the agent that being spoken to invites a reply. No memory
table records that anyone spoke.

The same pattern, twice more in the same logs:

- `You are hungry. / You are thirsty.` — and `consume_item` has never been called.
  The agent was told it was hungry and never ate.
- `The sun slowly disappears in the west.` — no behavioural consequence anywhere.

So a zero call-count means one of **three** things, and they have opposite fixes:

| Reading | Fix |
|---|---|
| The task never needed it | Leave it; classify per task profile |
| A subsystem should own it | Collapse into an intent tool |
| **Nothing ever prompted it** | **Add the trigger — deleting the tool makes it permanently impossible** |

Deleting on a zero count without distinguishing these is how you amputate a
capability that was one prompt line away from working.

*Question this raises:* should the state block carry a `pending:` line for things
that invite a response — someone spoke to you, you are hungry, your bag is full —
distinct from `just now:` which is pure narration? That is a state-block change,
not a tool change, and it might light up several "unused" tools at once for ~15
tokens.

---

### S5. "I found a sword. Is it better than mine?"

```
iter 1  get_item(sword)
iter 2  examine(sword)            → stats?
iter 3  check(equipment)          → what am I wielding?
iter 4  compare                   → pure reasoning, no tool
iter 5  equip_item(sword)  or  drop_item(sword)
```

Five iterations, one turn — and unlike S1, **none of them is collapsible.**
Iteration 4 is the point of the whole sequence and it calls nothing.

**⚠ contradicts §4.** I flagged the six-tool item cluster as the biggest token win
(~917) and a candidate for collapse into one intent tool. The scenario says no:
**every step here is a decision, and the decision is the whole point.** Test A
puts each of them on the player's surface.

A `handle_items(intent:)` wrapper would have to expose `get`, `examine-and-compare`,
`equip`, and `drop` as intents — which is the same tools with an extra layer of
indirection and *more* schema, not less.

What the cluster actually needs is **narrowing, not collapsing**:

- `put_item` implies containers. Nothing in the knowledgebase models a container.
  Until something does, it is a tool for a mechanic the agent cannot reason about.
- `use_magic_item` is the single most expensive schema on the surface (183 tokens,
  the largest of all 22) for wands and staves with charges — a mechanic no session
  has touched and no table represents.

So the honest cut here is **two tools on grounds of "no supporting model", not six
on grounds of "collapse into a subsystem."** ~324 tokens, and it is defensible.

---

## Reverse: tool → implied world

Reading the surface as evidence. Each tool asserts that something exists.

### R1. `track(target)` — "Requires the Track skill."

The description says so outright. So a granted tool may be **unusable by this
character**, and calling it wastes a full iteration on a refusal.

`player_skills` exists and is populated by `capture_practice`. **Nothing filters
the advertised surface by what the character has actually learned.**

*Scenario:* a level-1 fighter is shown `cast_spell`, `skill_strike`, and `track`.
It has none of those skills. Three tools ≈ 362 tokens, every call, advertising
capability the character does not have — and an iteration burned the first time it
believes them.

*This is a new idea, and it is `turn_policy`-shaped.* `compute_turn_policy` already
narrows the surface per iteration from world state, and `Context#advertised_tools`
already hides tools the policy withholds. Narrowing by `player_skills` instead of
by exits is the same machinery pointed at a different table — and unlike the exits
pin, it changes only on level-up, so it does not thrash the prompt cache every room
the way §5.1 warns about.

**This may be a better first move than deleting anything.** It costs no capability
at all: a tool hidden because the character cannot use it becomes visible the
moment it can.

### R2. `practice(skill)` — implies `practices_left`, implies a guild

`player_state.practices_left` is a real column and `capture_practice` parses the
counter. Practice happens at a guild, which is a *place* — rooms 16, 17, 18 in the
Dummy map are the Guild of Swordsmen and its yard.

*Scenario:* "learn to backstab" is a **navigation task wearing a skill costume**:
travel to the right guild → practice → verify the grade moved. It needs `travel`
and `practice` and nothing else, and it is the cleanest test of two subsystems
composing.

*Question:* does the agent know *which* guild teaches what? Nothing links a skill
to a room. Third table, or prompt knowledge, or discovery.

### R3. `set_position(rest|sleep)` — implies time passes, and there is no `wait`

Recovery needs elapsed time. The surface has no way to spend time deliberately.

*Scenario:* HP 4/20, no threat in the room. The correct play is rest and wait.
What the agent can actually do:

```
iter 1  set_position(rest)     ~4,100 tokens
iter 2  poll / check           ~4,100 tokens   still 6/20
iter 3  poll / check           ~4,100 tokens   still 9/20
...
```

Every iteration of that loop is a full model call whose only job is to observe
that time has passed. This is the purest case in either plan of iterations being
spent on something that required no reasoning at all.

**Regenerating to full could cost more tokens than the fight did.** A `rest_until(hp: "full")`
that blocks server-side and returns once — the same shape S2 arrived at
independently — turns a dozen iterations into one. Note this is the *third* time
the "bounded run with a stop condition" shape has appeared.

*Unverified:* tbaMUD's regen rate and whether sleep is meaningfully faster than
rest. Read the source rather than assume CircleMUD behaviour.

### R4. `tell(target, message)` — implies named others exist

Remote, targeted communication. So there are entities addressable by name that are
not in the current room. **There is no `players` table, no NPC registry, nothing
that remembers who you have spoken to or what they said.**

`entities` stores mob/object *types* keyed by description, explicitly not
instances — the schema says so and is right to. A person you can `tell` is exactly
the thing that model cannot hold.

*Scenario:* another player says "meet me at the temple, I'll heal you." On the
next iteration it is gone from `events`, unrecorded anywhere. The agent cannot act
on it two rooms later — and it never reached the user at all, because nothing that
happens mid-turn does.

*Question:* is a social memory in scope at all, or is `tell` a tool for a mode of
play (co-op) this agent is not built for yet? Either answer is fine; leaving it
granted with no supporting memory is the one that is not.

### R5. `check(kind: where)` — a possible shortcut worth probing

`where` is in the enum and has never been called. In this build it plausibly lists
who or what is where.

*Scenario:* "find the baker." If `where` names a room, it is an **oracle that
short-circuits the entire frontier search** in `move_around.md` §6 — resolve
target → `travel` → done, no exploration at all.

*Unverified and worth ten minutes:* run `where` against a live session and read
the output. If it answers location queries, `move_around.md`'s destination
resolution gets materially simpler for the *mob*-target case. If it only lists
players, it is near-useless here. **This is the cheapest open question in either
plan.**

### R6. `mud_status` — implies the connection drops

I called this a free deletion in §4. The reverse read is fairer: the tool exists
because *reconnection is a real state*, and the system prompt spends four lines
telling the agent not to trust it.

The **hook** should own connection state and render it in the state block — the
agent should be *told* it reconnected, not have to ask. That is Tier 0.

Deleting the tool is still right. Deleting the *concern* is not, and the prompt
lines that exist to work around the tool should go with it.

---

## What the scenarios demand, unioned

| Scenario | Surface it needs |
|---|---|
| S1 buy bread | `travel`, `shop`, + a `bag_stale` flag (no tool) |
| S2 get stronger | `engage`-with-stop-condition, or a bounded-run primitive |
| S3 interrupted walk | `travel` returning structured interruption + one event classifier |
| S4 spoken to | `say` — plus a `pending:` state-block line to ever trigger it |
| S5 found a sword | `get_item`, `examine`, `check(equipment)`, `equip_item`, `drop_item` — all five, unchanged |
| R1 track | *no new tool* — filter the surface by `player_skills` |
| R2 practice | `travel`, `practice`, + skill→guild link |
| R3 rest | `rest_until(...)` replacing a poll loop |
| R5 where | possibly nothing — or a large shortcut |

**Union: fewer new tools than §5 assumed, and two of the biggest wins are not
tools at all** — the skills filter (R1) and the `pending:` line (S4).

---

## What I got wrong above, restated plainly

1. **Items should not collapse (S5).** Every step is a decision. Cut `put_item` and
   `use_magic_item` for having no supporting world model (~324 tokens); leave the
   other four.
2. **Zero calls has three causes, not one (S4).** Some tools are unused because
   nothing triggers them. `say` and `consume_item` are both in that class, with
   log evidence. Deleting them would make a capability permanently unreachable.
3. **`engage` is not a terminal answer (S2).** It is a primitive to grinding. The
   recurring shape across S2, S3 and R3 is *bounded autonomous run with a stop
   condition* — which may be the actual abstraction, with combat, travel and rest
   as arguments rather than three hand-built subsystems.

## Revised first move

§9 ordered: free deletions → baseline → contract → combat.

The scenarios argue for a different opening, because it costs zero capability and
is measurable immediately:

1. **Filter the advertised surface by `player_skills` (R1).** Reuses
   `compute_turn_policy` + `advertised_tools`. Cache-safe (changes on level-up, not
   per room). Hides ~362 tokens *today* on a level-1 character.
2. **Instrument the tool-schema token baseline.** Unchanged from §9.2 — nothing
   below is falsifiable without it.
3. **Add the `pending:` state-block line (S4)** and re-measure the call
   distribution. If `say` and `consume_item` start being called, the "19 unused
   tools" number was measuring the prompt, not the surface — and every later cut
   should be re-derived from the new distribution.
4. **Run `check(kind: where)` once (R5).** Ten minutes, may simplify the sibling plan.
5. *Then* the contract and `engage` — with S2's stop-condition question settled
   first.

Steps 1–4 are all cheap, all measurable, and none of them delete a capability.


## Human Notes
1. some tool calls might be class specific, easy win to remove tools
2. soom tool calls are situational, if we only can use 'practice' in the guild, does the agent need the tool in their schema to know that they can go and do practice or once they arrive at that location that tool becomes avaliable.
2. Claude sayings multiple tool calls cant be rolled up in this scenario:
```txt
### S5. "I found a sword. Is it better than mine?"
iter 1  get_item(sword)`
iter 2  examine(sword)            → stats?
iter 3  check(equipment)          → what am I wielding?
iter 4  compare                   → pure reasoning, no tool
iter 5  equip_item(sword)  or  drop_item(sword)
```
But this can be compacted into single tool powered by a subagent via task with its own context and token budget with no full history of the player message history:
Wouldn't it be cheaper and reduce our tool scope by having a tool called: 
evaluate_item_upgrade(item: "sword")
Or even to generallize it further
consider_equip_change(item: "sword") - a single item
consider_equip_change(item: :all) - optimize the entire equipment we are wearking.

---

# Response to human notes

## HN1 — class-specific tools
[todo] our knowledge should store the class, gender and remove race.

**Right in principle. Blocked today, and it blocks my own §"Revised first move" too.**

Checked against the Dummy knowledgebase:

```
player_skills   0 rows
player_items    0 rows
char_class      NULL
race            NULL
title           "Dummy the Swordpupil"
```

And `test/fixtures/player/score.txt` confirms *why* — `score` prints age, hp/mana/
move, AC, alignment, exp, gold, questpoints, playing time, rank title and position.
**It never prints class or race.** The V2 schema comment already called this
exactly:

> "Reserved, and written only the day a capture proves this build prints them.
> `score` does not (`test/fixtures/player/score.txt`), so they stay NULL."

So there is **no data source for class filtering at all** right now.

**⚠ this also breaks R1 as I wrote it.** I proposed filtering the surface by
`player_skills` as the cheap first move. `player_skills` is empty — because it is
only ever written by `capture_practice`, and `practice` has never been called in
77 sessions. The filter has nothing to filter on.

`title` is class-derived ("Swordpupil" ↔ swordsman, and the fixture's "Derrano the
Minister" ↔ a caster). Deriving class from title needs a title→class table, which
is precisely the remembered-CircleMUD guessing the schema comment exists to
prevent. **Don't.**

The honest route is empirical, and it happens to be a scenario already written:

> **Class is discoverable by doing, not by asking.** In tbaMUD you practice at your
> *own* guild. The guild that lets you practice *is* the class signal — earned, not
> inferred. R2's practice errand is therefore the **enabler for R1**, not a peer
> of it.

Revised ordering consequence: the skills filter cannot be step 1. Step 1 is
running R2's errand once so the table exists.

*Worth probing alongside R5:* `check(kind: levels)` has no fixture and unknown
output. If it prints a class/level table it may be a direct source. Two probes,
one session.

## HN2 — situational tools (`practice` only in the guild)

**The strongest idea in the notes, and the question as posed contains its own
answer.**

The worry — *"does the agent need the tool in their schema to know that they can
go and do practice"* — is the capability cliff arriving by a new road. If
`practice` only appears once you are standing in a guild, the agent can never form
the intent *"go to the guild and practice"*, because nothing tells it practising
is a thing that exists.

The resolution is to stop treating those as the same fact:

> **An affordance is knowledge. A tool is an invocation. They do not have to live
> in the same place.**

Knowing practice exists is ~15 tokens of prompt, paid once. Being able to *call*
`practice` is 103 tokens of schema, currently paid on every iteration of every
turn forever.

| Where | Carries | Cost |
|---|---|---|
| System prompt | "You can practise skills at your guild." | ~15 tokens, once |
| State block | `here: you can practise` — only in a guild room | ~8 tokens, only there |
| Tool schema | `practice(skill)` — advertised only in a guild room | 103 tokens, only there |

**Precedent already shipped:** `worth a look: water` is exactly this. The state
block already tells the agent what is actionable *here* without a tool existing
for it. `candidates_line` is the pattern; this just extends it from nouns to verbs.

**How does a room know it affords practice?** Not from the world files —
`plan_route.md` §4 rightly forbids learning from `week0_explore/.../assets`, and
that prohibition should hold here. Earn it instead: **the room where `practice`
succeeded is a practice room.** Same philosophy as `room_exits.target_name` — one
success writes the fact, and it is true forever after.

```sql
-- sketch: earned, not injected
room_affordances(room_id, affordance, first_seen_at)
--   'practice' | 'shop' | 'bank' | 'heal'
```

This generalizes immediately to `shop` (136 tokens) — shops are rooms too. Between
them that is **~239 tokens moved from always-on to situational**, which is more
than the combat cluster's free deletions.

*Two honest caveats:*

1. **Bootstrapping.** A room affords practice only after practice has worked there
   once. So the first visit must have the tool available to discover it. Either
   advertise the situational tools until the affordance table is warm, or seed
   affordances from room name on first arrival and let a failure clear it.
2. **Cache churn.** Per-room tool changes invalidate the prompt cache (§5.1). Guild
   and shop rooms are rare — 3 of 50 in the Dummy map are guild rooms — so churn is
   low, but it is not free. Unlike R1's skills filter (changes on level-up), this
   one changes on arrival. Measure before assuming it is cheap.

This is `compute_turn_policy` machinery pointed at a third table, alongside exits
(built) and skills (HN1).

## HN3 — S5 as a subagent

**You are right and I was wrong, in a way that matters beyond S5.**

My Test B reads: *"does a subsystem own a sequence longer than one call whose steps
follow **rules the model cannot improve on**?"* That test can only ever return
Tier 1 candidates. It has **no branch for "this needs judgement, but not the
*player's* judgement"** — which is Tier 2, defined in my own §2.1 table and then
never applied. S5 is its archetype and I filed it as un-collapsible.

### The economics I missed

`Boukensha.run_task` builds its **own `Context` and its own `Agent`**, with its own
`max_turn_tokens` (`boukensha.rb:243-264`). So a subagent's spend does not land on
the player's turn budget. The player's turn pays for one tool call and its result.

| | Player turn budget | Elsewhere | Total |
|---|---:|---:|---:|
| S5 today (5 iterations) | ~20,500 | — | ~20,500 |
| S5 as subagent | **~4,100** | ~4,800 | ~8,900 |

~2.3× cheaper in total — but the number that matters is the first column.
**The player's turn budget is the scarce resource**; it is what ended all three
bakery sessions at 15 iterations. Delegation does not just reduce spend, it moves
spend off the constrained budget onto an unconstrained one. That is a categorically
better move than shaving tokens off a schema, and I had the mechanism documented in
§2.1 without connecting it.

`consider_equip_change(item: :all)` is the stronger form: N items × 5 iterations is
catastrophic on a player turn and is exactly what a scratch context is for.

### Test B, corrected

Split it, and add the separability question that decides the tier:

**B1 — is the sequence deterministic given the intent?** → **Tier 1**, scripted.
(`travel`, `engage`, `rest_until`.)

**B2 — does it need judgement, but only over its own subject matter?** → **Tier 2**,
subagent.

> *The separability test:* does the sub-decision need the player's **goals and
> history**, or only its own **subject matter**?
>
> - Comparing a sword to your current weapon needs the item, your equipment, maybe
>   your level. It does **not** need "the user asked me to find a bakery."
>   **Separable → Tier 2.**
> - `say(message)` depends entirely on the conversation and the goal.
>   **Not separable → stays a primitive.**
> - *Whether* to fight needs the player's goal (am I levelling, or passing
>   through?). **Not separable → stays with the player**, which leaves §3's
>   conclusion intact.

Neither B1 nor B2 → the tool stays on the player's surface.

So §2's "**Default to Tier 1**" was too broad. Corrected: **default to Tier 1 when
the sequence is scriptable; reach for Tier 2 when it needs judgement that is
separable from the player's context.** `plan_route.md` §4.2's rejection of a
subagent still stands on its own facts — a route-search subagent cannot learn more
from the same database — but that is an argument about *route search*, not a
general prohibition, and I over-generalized it.

### What Tier 2 costs, to weigh against the above

1. **Latency.** The subagent runs serially inside the player's tool call. Four or
   five model calls at ~1.9s each ≈ **8s blocked**, during which the player agent
   does nothing. Cheaper in tokens, worse in wall-clock.
2. **Authority.** `mcp_clients` is memoized, so the subagent drives the *same live
   telnet session* — no second login, but it can really equip and really drop.
   It needs a tight `tools.equip_advisor.allow` slice, and `drop_item` in that
   slice means a subagent can destroy player property.
3. **Model choice is config-only.** `Tasks::Base` resolves provider/model/
   `max_iterations`/prompt per task, so this could run on Haiku or a local Ollama
   model without touching code.
4. **Attribution is already solved.** `run_task(logger:)` appends to the parent
   session file bracketed by `task_start`/`task_end` with every event stamped
   (Amendment A). The monitor will render it nested.
5. **Plumbing is trivial.** It needs a `Tasks::` subclass; `Tasks::Player` is nine
   lines.

### Revised surface for S5

```text
consider_equip_change(item: "sword" | :all)
  → { recommend: "equip"|"keep"|"drop", reason:, compared_against: }
```

Owns `get_item`, `examine`, `check(kind: equipment)`, `equip_item`, `drop_item`.
Five tools ≈ **786 tokens** off the player's surface for one ≈ **130**.

Combined with HN2 moving `practice` + `shop` to situational (~239) and the free
deletions (~175), that is **~1,200 tokens off every iteration** without a single
capability lost — and it does not depend on the empty `player_skills` table that
HN1 showed blocks the filter idea.

## Consolidated first move, after the notes

The notes invalidate my earlier ordering (R1 cannot be step 1 — the table is empty).

1. **`consider_equip_change` as the first Tier 2 subagent (HN3).** Largest
   player-budget win (~786 tokens), needs no new data, and proves the Tier 2 seam
   that `run_task` has been holding open unused since it was written.
2. **Instrument the tool-schema token baseline.** Unchanged — nothing is
   falsifiable without it.
3. **Situational advertising for `practice` + `shop` (HN2)**, with the affordance
   earned on first success and the *knowledge* moved to the prompt/state block.
4. **Run the practice errand once (R2)** — this is what populates `player_skills`
   and unblocks the skills filter. Probe `check(kind: levels)` and
   `check(kind: where)` in the same session.
5. **Then** the skills filter (R1), now that it has rows to work with.
6. **Then** the contract and `engage`, with S2's stop-condition question settled.

---

## HN4 — a fact base, and whether it needs modes

### The pattern is already here three times; it just has no name

Before designing anything: **situational fact injection already ships in this
codebase.** Three instances, none of which call themselves that:

| Instance | Key | Fact injected | Where |
|---|---|---|---|
| `encounter_note` | entity present | *"you died against this at level 3"* | `here:` line |
| `entity_for` → `threat` | entity present | *"you could take him"* | `here:` line |
| `look_candidates` | room, first visit | `worth a look: water` | `worth a look:` line |

And this plan proposes two more without noticing they are the same shape: HN2's
room affordances (`here: you can practise`) and S4's `pending:` line.

So the question is not *"should we build fact retrieval"* — it is **"we have five
instances of one pattern; is it time to name it, and what is the key?"**

That reframing matters because it sets the bar: a general mechanism has to be
better than five special cases, not better than nothing.

### Why it becomes necessary rather than nice

The system prompt is 2,039 chars ≈ **554 tokens, always-on, every iteration**.
It is the second-largest fixed cost in the request after tool schemas.

Now suppose the fact base grows the way the user describes — mechanics, strategies,
things learned over time. At ~25 tokens a fact, **200 facts is ~5,000 tokens**,
always-on, on every iteration of every turn.

> **A fact base that grows and is always-on is the tool-schema problem again, with
> prose instead of JSON.** Same failure, same cause, ~2× the size.

That is the real argument for situational retrieval, and it is the same argument
this whole plan makes about tools. Consistency is a good sign.

### Split by provenance, not by storage

Three kinds of thing are being called "facts", and they have different lifetimes —
which is exactly the distinction `Schema` V1's header comment already draws for
world data (PERMANENT / VOLATILE / EARNED):

| Kind | Example | Changes? | Who writes it |
|---|---|---|---|
| **Authored rule** | "You practise at your *own* guild." | Never | A human, in git |
| **Observed fact** | "The Bakery is room 12." / "I died to the minotaur at level 3." | On discovery | Hooks, from the MUD's own words |
| **Proposed rule** | "Minotaurs are unbeatable." | On evidence | The model, generalizing |

**Observed facts are already in SQLite** — `rooms`, `room_exits`, `entities`,
`encounters`. That half is done.

**Authored rules should not go in SQLite.** They never change, so a database buys
nothing, and every prose edit becomes a migration. More importantly,
`knowledge.sqlite3` is *the agent's earned knowledge* — the schema is emphatic that
boukensha is the only writer and that each row has a lifetime. Authored assertions
are a **fourth lifetime the schema does not have**, and mixing them in blurs the
one distinction the file was built to protect: the difference between *what I
learned* and *what I was told*.

Put authored rules in a versioned YAML pack next to `prompts/`, loaded at boot.
Reviewable, diffable, no migration to fix a typo. Retrieval queries both and the
caller cannot tell the difference — the same two-source shape `prompts/` already
has (bundled default + profile override).

**Proposed rules are the dangerous one** — see risks below. Recommend deferring
them entirely for now.

### Four keys — and the mode already exists

The question asks whether this needs "modes... like states to conditionally pull
facts." Working through what the keys would actually be:

| Scope | Pulled when | Example |
|---|---|---|
| `global` | always | "You must be standing to move or fight." |
| `room` | you are in that room | "You can practise here." |
| `entity` | it is in the room with you | "You died to this at level 3." |
| `activity` | that subsystem is running or available | "Fleeing sends you a random direction." |

Three of those four are **already how the shipped instances work** — room, entity,
and (for the prompt) global. Only `activity` is new.

And here is the part worth sitting with:

> **The active subsystem *is* the mode.** If `travel` is running, the agent is
> travelling. If `engage` is running, it is fighting. The mode does not have to be
> declared, inferred, or stored — it is the tool that is executing.

So the answer to *"do we need modes/states?"* is **no new concept, provided the
subsystem work in this plan happens first.** Building an explicit mode state
machine *and* subsystems would be modelling the same thing twice, and the two would
drift. This is a strong argument for sequencing: subsystems first, facts keyed to
them second.

The cost of an explicit mode machine, for comparison — because it is worth knowing
what we are avoiding:

- **The model sets the mode** → a tool call, i.e. a whole iteration (~4,100 tokens)
  spent declaring intent instead of acting on it, and it can be wrong.
- **A hook infers it** → an inference rule that can disagree with what is actually
  running.
- **It is the running subsystem** → free, always correct, no new state.

### The one thing that genuinely is a mode

There is a case the subsystem trick does not cover: **the goal the user gave**,
before any subsystem is running. "Find the bakery" and "get strong enough to beat
the minotaur" should pull different facts on iteration 1, and no tool is executing
yet.

That is one string. A `goal:` line on the state block, set from the user's turn and
carried until it changes, is ~10 tokens and gives retrieval something to key on
from the first iteration. It is also the smallest possible down-payment on
`move_around.md`'s Problem 3 — which I argued was not a prerequisite, and still
is not, but **this is where it first earns its place.**

### Retrieval: tagged, not embedded

Same conclusion as `move_around.md` §3 and for the same reason. At a corpus of
~15 authored rules and a few dozen observed facts, tag-and-filter is exact,
debuggable, and free. Embedding retrieval is nondeterministic, needs a model the
repo does not have (`Extractors::Model` is a token classifier, not an embedder),
and is unjustifiable at this size.

**Lexical/tagged now; revisit only on a logged retrieval miss.**

### The contract

```sql
-- learned half only; authored rules load from YAML into the same interface
facts(
  id, scope, key, text,
  provenance,        -- 'observed' | 'proposed'
  confidence,
  measured_at_level, -- NULL unless the fact is level-relative
  first_seen_at, last_seen_at
)
```

Rendered into the state block on a `know:` line, and **hard-capped**:

> **Budget cap: at most 3 facts / ~60 tokens per iteration, ranked by specificity
> (entity > room > activity > global).**

Without the cap this recreates the problem it exists to solve. With it, the fact
base can grow to thousands of rows and the per-iteration cost stays flat — which is
the same property the state block already has versus `inspect_room`, and the reason
that trade worked.

### Where facts must live, and the caching trade

Tempting shortcut: put mechanics in the **tool description**, since under HN2 the
tool is only advertised situationally anyway — the fact rides along free.

**That works under §5.1 strategy A and breaks under B.** Tool descriptions are part
of the cached prefix; changing them per room invalidates every cache tier. The
state block is a trailing user turn *after* any breakpoint, so rewriting it every
iteration is free.

| §5.1 choice | Where situational facts go |
|---|---|
| **A — shrink, no caching** | Tool descriptions are fine, and cheapest |
| **B — grow + cache** | Facts **must** go in the state block; descriptions must stay static |

This is a third thing riding on the A/B decision (after tool narrowing and HN2's
per-room advertising). It is becoming the load-bearing open question of this plan
and should be settled early rather than accumulating dependents.

### Risks, in order of how much they would hurt

1. **A stale learned rule is worse than no rule.** "I died to the minotaur at
   level 3" is a fact forever. "Minotaurs are unbeatable" is an inference that
   expires. The codebase already solved exactly this once — `entity_for` returns
   `threat_fresh` and the state block prints *"threat unknown at this level"* the
   moment the player out-levels the reading. **Any level-relative fact needs
   `measured_at_level` and the same invalidation**, or the agent will confidently
   repeat an expired lesson. This is the single most important thing to copy.
2. **Hallucinated mechanics.** If the model may propose rules, it can invent
   tbaMUD behaviour that does not exist and then act on it — and it will look
   identical to a learned fact. Mitigation: `provenance` is not decoration; a
   `proposed` fact should be rendered with a hedge or not rendered at all until
   corroborated by an observation. **Recommend: do not implement `proposed` in v1.**
   Hooks write what the MUD said; humans write rules.
3. **Silent retrieval misses.** A fact that exists but was not pulled fails
   invisibly. `injected_context` already logs the state block with a `changed:`
   flag; extend it to log *which* facts were pulled and how many were eligible but
   cut by the cap, so misses are measurable rather than anecdotal.
4. **Two sources of truth for the same claim.** An authored rule and an observed
   fact can disagree — the pack says "you practise at your own guild", the agent
   observed practising somewhere else. Observation should win, loudly, and log the
   conflict the way `log_conflict("stale_edge", …)` already does for exits.

### Verdict, and when to build it

The idea is right and the direction is where this plan already points. But the
corpus today is **one system prompt and zero learned rules**, and building a
retrieval engine for ~15 authored facts is precisely the over-engineering this
codebase has consistently refused — `room_inspector` earned its way down the tiers
by evidence, not by design-up-front.

**Rule of three.** Ship the first fact type as a special case, and let the general
mechanism emerge only if a second and third actually want it:

1. **HN2's room affordances** — the first fact type, already justified on its own
   token savings (~239). Build it as an affordances table, not a fact engine.
2. **S4's `pending:` line** — the second, event-keyed. Build it as a state-block
   line, not a fact engine.
3. **If a third arrives** — activity-keyed mechanics — *then* the three special
   cases have earned a `facts` table, and the shape above is what it should be.

What to do **now**, cheaply, regardless:

- **Add `goal:` to the state block** (~10 tokens). It is useful immediately for
  focus, it is the key retrieval will need later, and it costs nothing to be
  early.
- **Audit the system prompt for facts that are already situational.** The Strategy
  section's `consider` explanation is entity-keyed; the MUD Session paragraph is
  a startup-only fact that is re-sent on every iteration forever. Moving even two
  paragraphs out of always-on is a real saving today with no new machinery.
- **Settle §5.1 A vs B**, which now gates three separate decisions.


- create a facts table
- make sure we ahve class and gender information
- conditional tools based on class
- conditional tools based on location, situation
- reitroduce tools when need or force through a new composite tool.