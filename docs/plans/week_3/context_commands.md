## Context Commands

When the Agent is asked "Find the bakery and read the menu"
It often attempts to use "examine" instead of the "shop" tool.
It will attempt to examine the baker.

The challenge is there could be objects in the world were like examine bulletin board.

It doesn't even make sense they would examine the bakery since its a person
I could understand it going examine menu.

So it does:
```
Let me try to interact with the baker through the shop system to see the menu:
```

Instead of saying:
```
I'm in the bakery, which is a shop that sells thing a menu would list purchasbales
There's only own target that could be selling things I'll use the list command
```

The list command will like the primary seller in the room
and list <target> will be more specific.

We could just update the system prompt but thats not really helping this exmaine issue.

We already extract possible targets in the room.

## Technical Exploration

Note: our code is in week2_capable because week 2 and 3 share the same folder.

### What the logs actually show

Six "find the bakery" sessions on the Dummy profile, 2026-07-27. Best case is
4 iterations (`plan_route`, `execute_route`, `shop`, answer):

| session | advertised `shop`? | iters | what it did in The Bakery |
|---|---|---|---|
| `20260727T220411Z-115338e0` | **no** (6 tools) | 14 | 20 `examine` calls — baker, bakery, bread, pastry, cake, roll, bun, scone, loaf, `chokoladeboller` — then ran out of turns. Never listed the menu. |
| `20260727T223231Z-fef86633` | yes | 5 | `examine(baker)` and `shop(list)` *unprefixed* → two `UnknownToolError`s, retried prefixed, worked |
| `20260727T225423Z-b13fa0f2` | yes | 4 | `examine(menu)` → "You do not see that here.", `examine(baker)`, then `shop(list)` |
| `20260727T230156Z-aadbd5d8` | yes | 4 | `shop(list)` straight away ✓ |
| `20260727T230407Z-8d23587c` | yes | 5 | `examine(baker)` (unprefixed → error), then `shop(list)` ✓ |
| `20260727T230556Z-478e3d49` | yes | 4 | `shop(list)` straight away ✓ |

Two distinct things are tangled here and they need separating.

**The 20-call session is not the `examine` problem.** `tbamud__shop` was not in
the advertised tool list that run — `tools: ["tbamud__examine", "tbamud__move",
"tbamud__consider", "tbamud__poll", "plan_route", "execute_route"]`, six tools,
session log line 21. The model was not choosing `examine` over `shop`; `shop`
did not exist for it. It was doing the only thing it *could* do, badly, for
twenty iterations. `tbamud__shop` is uncommented in `.boukensha/settings.yaml`
now, so that specific run is not reproducible and should not be used as the
baseline for anything below.

**The real, current problem is smaller and still worth fixing**: with `shop`
advertised, 3 of 5 runs still spent 1–2 iterations on `examine` first. That is
the ~25% overhead this doc is about. It is a preference problem, not a
capability problem.

### Two premises in the note above are wrong

Correcting these first, because the fix depends on them.

- *"list \<target\> will be more specific [seller]"* — it will not.
  `shopping_list()` in `src/shop.c` does `one_argument(arg, name)` then
  `if (!*name || isname(name, last_obj->name))`: the argument filters **items**
  by keyword, not sellers. Which keeper answers is not selectable at all —
  `SPECIAL(shop_keeper)` fires for whichever mob owns the shop, and a room has
  at most one. So `shop(action: "list", args: "pastry")` narrows the *stock
  listing*, and there is no seller-disambiguation problem to solve.
- *"We already extract possible targets in the room"* — we do, but they are not
  reaching the model here. `rooms.look_candidates` for The Bakery is `["sign"]`
  (knowledge.sqlite3, room #12), and `StateBlock.render` only emits the
  `worth a look:` line when `first_visit` is true (`state_block.rb:41`,
  `hooks.rb:647`). Every one of these sessions was visit 4+, so the model saw
  no candidates line at all — and `["sign"]` would not have helped if it had.

### What a "context command" is, precisely

This is not a fuzzy category. tbaMUD has a closed set of commands routed to
`do_not_here` in the `cmd_info` table (`src/interpreter.c`):

```
balance  buy  check  deposit  identify  list  mail
offer    receive      rent    sell      value  withdraw
```

```c
ACMD(do_not_here)
{
  send_to_char(ch, "Sorry, but you cannot do that here!\r\n");
}
```

Every one of them does nothing on its own. Each only works because something in
the room carries a `SPECIAL()` proc that intercepts it *before* the interpreter
gets there. The full inventory, read off `src/spec_assign.c` (the assignment
table) and each proc's own file — **this is all of them**, not a sample:

| proc | bound to | intercepts | our tool | probe |
|---|---|---|---|---|
| `shop_keeper` (`shop.c`) | **mob**, via `.shp` keeper vnum + room list | `steal` `buy` `sell` `value` `list` `identify` — **not `offer`** | `tbamud__shop` | `list` |
| `pet_shops` (`spec_procs.c`) | **room** — vnums 3031, 10738, 23281, 25722, 27155, 27616, 31523 | `list` `buy` | `tbamud__shop` (2 verbs of 5) | `list` |
| `bank` (`spec_procs.c`) | **object** — vnums 115, 334, 336, 3034, 3036, 3907, 10640, 10751, 25758 | `balance` `deposit` `withdraw` | `P.bank` → expose as `tbamud__bank` (§6) | `balance` |
| `postmaster` (`mail.c`) | **mob** — vnums 110, 1201, 3010, 10412, 10719, 25710, 27164, 30128, 31510 | `mail` `check` `receive` | `check`/`receive` only — `mail` enters an editor (§6) | `check` |
| `receptionist` / `cryogenicist` (`objsave.c` → `gen_receptionist`) | **mob** — 1200, 3005, 5404, 27713, 27730 / 3095 | `offer` `rent` | `offer` only — `rent` disconnects (§6) | `offer` |
| `guild` (`spec_procs.c`) | **mob** — ~40 vnums incl. 3020–3023 | `practice` | `tbamud__practice` | **none — see below** |
| `gen_board` (`boards.c`) | **object** — vnums 1226–1228, 3096–3099 | `read` `write` `remove` `look` `examine` | none | `look` |
| `dump` (`spec_procs.c`) | **room** | `drop` | — | — |
| `mayor` (`spec_procs.c`) | mob 3105 | *nothing* — movement only | — | — |

Four things in that table are not what §1's first draft assumed, and each
changes the design:

- **`bank` and `gen_board` are OBJECT procs, not mob procs.** The Temple Of
  Midgaard's `"An automatic teller machine has been installed in the wall here."`
  — already sitting in the `entities` table as an object — *is* bank vnum
  3034/3036. A probe gate of "the room has ≥1 mob" would miss every bank in the
  world.
- **`pet_shops` is a ROOM proc.** It needs neither a mob nor an object. Nothing
  observable in the room has to be present for `list` to work there.
- **`gen_board` intercepts `examine`.** The note above worries about "objects in
  the world like examine bulletin board" — that is this proc, and it is the one
  case where `examine` genuinely *is* the context command. Any design that
  suppresses `examine` in favour of a room-proc tool would break boards.
- **`practice` is not probe-able, and is not even `do_not_here`.**
  `ACMD(do_practice)` (`act.other.c`) is a real command:

  ```c
  if (*arg)
    send_to_char(ch, "You can only practice skills in your guild.\r\n");
  else
    list_skills(ch);
  ```

  Bare `practice` calls `list_skills()` and works **anywhere** — which is why
  `Mud::Hooks#capture_practice` can read it off any turn. Only
  `practice <skill>` is guild-gated, and the guild proc consumes a practice
  session on success. So the guild affordance can only ever be learned from a
  failed attempt, never probed. It gets a row like the others; it just never
  gets a probe.

`MudManager::Primitives` already half-knows all this — the methods are grouped
under a literal `# ---------- Room-procedural (SPEC_PROC-mediated) ----------`
heading (`primitives.rb:367`), and `shop`/`bank`/`mail`/`rent`/`house_admin` sit
under it. The concept exists in the codebase; it has never been data the agent
can read, and only `shop` was ever promoted to an MCP tool
(`mcp/tool_spec.rb` has no `bank`, `mail` or `rent` entry).

So: a context command is a command whose validity is a property of **the room
you are standing in**, and the agent is told a great deal about the room it is
standing in and nothing at all about this.

### Why the model reaches for `examine`

Look at what it was actually given on arrival (session `115338e0`, log line 72):

```
[here] The Bakery  (visit 4)
exits: south→Main Street ✓
here: The baker looks at you calmly, wiping flour from his face with one hand. (mob — "Consider killing who?")
you: 20/20hp 100mana 51mv · lvl 1 · 0 gold · standing
```

Nothing in that block says the room sells anything. The only handle offered is a
mob description, and the only tool that takes a mob is `examine`. The model is
reading the state block correctly and acting on it; the block is what is
incomplete. That is the same shape of problem as the `d`/`down` bug already
documented in `state_block.rb:59-72` — the model copies what the block offers
it — and it wants the same shape of fix.

(That `"Consider killing who?"` in the `here:` line is a separate real bug. See
§"Adjacent defect" below.)

### Decision: learn the affordance, then render it

Not a system-prompt rule. A prompt line ("if the room is a shop, use `shop`")
does not help, because the model has no way to know the room is a shop — the
premise of the rule is exactly the fact that is missing. Adding world knowledge
("bakeries are shops") is worse: it is a guess that fails on The Reading Room
(saleswoman, no shop proc) and on rooms named nothing like a store.

Instead, make room-procedural affordance a **learned, stored property of the
room**, exactly like `room_exits.target_room_id` and `frontier_attempts` are —
then spend it twice: once as a line the model reads (§3), once as the tool list
it is given (§5). Five pieces, in dependency order.

#### 1. Schema V5 — `room_affordances`

```sql
CREATE TABLE room_affordances (
  room_id      INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  affordance   TEXT NOT NULL,        -- 'shop', later 'bank', 'practice', 'rent', 'mail'
  available    INTEGER NOT NULL,     -- 1 = confirmed present, 0 = confirmed absent
  evidence     TEXT,                 -- the MUD line that settled it
  checked_at   TEXT NOT NULL,
  PRIMARY KEY (room_id, affordance)
);
```

Room-owned, not entity-owned, and that is deliberate. Shop-ness is a property of
the `(keeper vnum, room vnum)` pair in tbaMUD's `.shp` files — the keeper does
not wander, and an entity row is world-level (`schema.rb:64-91`), so recording
"this description is a shopkeeper" would make one wrong appraisal wrong in every
room the type appears in. Same argument the entities table already makes for
`health`.

**Storing `available = 0` is the point.** A negative is what stops the probe
below from running again in the same room forever, and it is a genuine fact:
`do_not_here` fired, so nothing in this room has a shop proc.

#### 2. Acquisition, at two seams that already exist

**a) Learn on use — free, no round trips.** `Mud::Hooks#after_tool` already sees
every result. Any `shop` call the model makes is a probe we did not pay for:

```
" ##   Available   Item ... Cost"            → available = 1
"Sorry, but you cannot do that here!"        → available = 0
"Currently, there is nothing for sale."      → available = 1  (a shop with empty stock)
```

All three strings are from `src/shop.c` / `src/act.other.c`, not from memory.
This alone makes the *second* visit to any shop correct at zero cost, and it is
the piece to build first because it cannot regress anything.

**b) Probe on discovery — one round trip, once per room, ever.** One
`shop(action: "list")` the first time the agent stands in a room, in its own
`before_model` step (see "Decisions taken" §2 — deliberately *not* folded into
`Mud::RoomSurvey`, so it can be switched off independently of the survey).
The trigger condition is the survey's: a room with no affordance rows yet.

**On the gate.** Probe only rooms with ≥1 mob — 32 probes over the 56 rooms
currently known rather than 56. Note that this is a gate per *affordance*,
matching what each proc is bound to, not one global rule; the proc table shows
`bank` and `gen_board` are **object** procs, so a blanket "has a mob" test would
be silently wrong for banks, and a false negative here is invisible because the
room simply never offers the affordance:

| affordance | probe | gate | bound to |
|---|---|---|---|
| `shop` | `shop(action: list)` | room has ≥1 mob | mob (`shop_keeper`); **room** for `pet_shops` — see Decisions §1 |
| `bank` | `balance` | room has ≥1 **object** | object |
| `mail` | `check` | room has ≥1 mob | mob |
| `rent` | `offer` | room has ≥1 mob | mob |
| `practice` | — | never probed | mob, but unprobeable (see §"What a context command is") |

`shop` and `bank` are the two rows to build (§6 promotes `bank` to an MCP tool);
`mail`/`rent` follow only if their tools ever land. Two probes per newly
discovered room, gated as above — against the current knowledgebase that is 32
`shop` probes and however many rooms hold an object, one per room, once, ever.
Revisits cost zero, the same accounting `RoomSurvey`'s header documents for the
survey itself.

This needs one line in `.boukensha/settings.yaml` under
`tools.room_survey.allow` — the probe shares the survey's permission slice
because it is the same actor from the MUD's point of view (code reading the
world without the player asking), even though it no longer shares the survey's
call site:

```yaml
      - "tbamud__shop(action: list)"
```

The rule grammar already supports pinning an enum param (`permissions.rb:8-26`),
and `action` declares `SHOP_OPS` as its enum (`tool_spec.rb:266`), so this
validates at startup and the survey provably cannot `buy` or `sell`.

#### 3. Rendering — one line in the state block

`StateBlock.render` gains an affordance line, emitted only when something is
known to be available:

```
[here] The Bakery  (visit 4)
exits: south→Main Street ✓
here: The baker looks at you calmly, wiping flour from his face. (mob — "you could take him")
shop here: list | buy | sell | value | offer
you: 20/20hp 100mana 51mv · lvl 1 · 0 gold · standing
```

Unlike `worth a look:`, this renders on **every** visit, not just the first.
It is ~10 tokens, it never changes, and it is the answer to a question the model
asks itself every single time it stands in the room. The prose is sent once
because re-reading it is waste; this is not prose.

Verbs come from `Permissions#allowed_values` for the task's own `shop` rule, so
a task allowed only `shop(action: list)` is not shown `buy`. The block and the
tool schema speak one grammar — the same rule `state_block.rb:59-72` established
for directions.

#### 4. Correction at the seam — only if 1–3 are not enough

`after_tool` already rewrites results (`movement_outcome` replaces a ~105-token
room dump). When the model calls `examine` on a mob in a room whose
`room_affordances` says `shop`, append one line to the result it gets back:

```
(This room is a shop — tbamud__shop(action: "list") lists what is for sale.)
```

Zero round trips, arrives at the exact moment of the mistake, and — the part
that matters — it is emitted only when the store *knows*, so it can never be the
confident lie a prompt rule would be. Build this only if the numbers after 1–3
still show `examine`-first, because it is the one piece that talks to the model
rather than informing it.

#### 5. Conditional tools — the affordance drives what is advertised

Yes. This is the payoff, and the seam is already built and already exercised.

`Context#advertised_tools` (`context.rb:69-74`) filters the registered tools
through `turn_policy` before every model call, and every backend passes the
result — not `@tools` — as the request's `tools:` array
(`backends/anthropic.rb:81`, and the same line in `openai.rb`, `gemini.rb`,
`ollama.rb`, `ollama_cloud.rb`). `Mud::Hooks#compute_turn_policy`
(`hooks.rb:669-689`) already rebuilds a `Permissions` object once per iteration
from the current room's state. Today it restates every granted tool and narrows
only `move`. Room-proc tools become conditional by *omitting them from that
restated list* when the store says the affordance is not here:

```ruby
rules = context.tools.keys.filter_map do |name|
  next "#{move}(direction: #{dirs.join('|')})" if name == move
  next nil if suppressed?(name)          # room-proc tool, affordance known absent
  verbs = affordance_verbs(name) and next "#{name}(action: #{verbs.join('|')})"
  name
end
```

Three behaviours out of one mechanism, all in the rule grammar that already
exists and is already validated against each tool's enum at startup:

- **omit** → the tool is not in the request payload at all;
- **pin** → the tool is advertised with its enum narrowed, which is the correct
  answer for pet shops (`shop(action: list|buy)` — `pet_shops` implements two of
  the five verbs, so advertising all five invites three guaranteed failures);
- **unchanged** → everything else.

**The rule that matters more than any other: three-valued, and unknown means
visible.**

| store says | advertise? |
|---|---|
| `available = 1` | yes, verbs pinned to what the proc implements |
| `available = 0` | no |
| **no row** — never probed, or probe inconclusive | **yes** |

Defaulting unknown to hidden would be a closed loop: a cold knowledgebase would
advertise `shop` nowhere, the model could never call it, learn-on-use (§2a)
could never fire, and no room would ever acquire a row. The system would be
permanently, silently unable to shop. Absence of evidence has to advertise.

**Why this is worth doing beyond token count.** The saving is real but modest
today: the `shop` schema is roughly 90–110 tokens (name, description, two params,
a five-value enum) out of a request carrying a ~700-token system prompt, seven
tool schemas and a growing transcript. Hiding it in the ~90% of rooms that are
not shops saves ~100 tokens an iteration. That alone would not justify the
machinery.

What justifies it is that it is **the same fact as §3, enforced instead of
stated**. In The Bakery the model is not merely told a shop is here — `shop` is
the only room-procedural tool in its list, and everywhere else it is not there
to be reached for at all. A shorter list of applicable tools is a stronger
signal than a line of text, and it degrades in the right direction: text can be
skimmed past, an absent tool cannot be called. The token argument also scales
the way the surface is going to scale — `.boukensha/settings.yaml` has ~20 tools
commented out, and bank/mail/rent/board would add four more room-proc tools.
At that size roughly a quarter of the advertised surface is room-conditional.

There is no prompt-cache interaction to weigh: `grep -rn cache_control` over
`week2_capable/boukensha/lib/` returns nothing — the client sets no cache
breakpoints — so churn in the tools array costs nothing it would not otherwise
cost.

**Failure modes are asymmetric, and that decides the flag.** A wrong *positive*
costs one wasted call and self-corrects (learn-on-use overwrites the row). A
wrong *negative* removes the tool, so the model cannot discover the mistake and
cannot correct it — the only recovery is a human noticing. That is a strictly
worse failure than the one this doc set out to fix, which is why:

- `memory.turn_policy` must **not** be the flag that turns this on.
  `compute_turn_policy`'s existing job is pinning `move` to directions the MUD
  printed in the same breath as the room — settings.yaml's own comment says that
  constraint "cannot be wrong". Suppressing a tool on the strength of a stored
  negative that may be hours old is a completely different risk. Give it its own
  key, `memory.conditional_tools`, defaulting off, so the two can be A/B'd
  independently.
- A suppressed tool that is somehow still called must fail legibly.
  `Registry#dispatch` checks `call_permitted?` against the turn policy, so the
  model would get `UnauthorizedToolError`. The message should say the room does
  not afford it and name the evidence, not read like a config bug — and
  `after_tool`/the error path should clear the `available = 0` row, since a call
  arriving at all is a sign the belief is worth re-testing.
- Never suppress `examine`. `gen_board` intercepts it (see the proc table), so
  it is a context command in its own right, and it is the general-purpose
  fallback the model reaches for when nothing else fits. Only tools in the
  room-procedural family are ever candidates for omission.

#### 6. Expose the missing room-procedural tools

`mcp/tool_spec.rb` exposes `shop` and stops. `MudManager::Primitives` has
`bank`, `mail`, `rent` and `house_admin` sitting unused under its
`# Room-procedural (SPEC_PROC-mediated)` heading — the store can learn a room is
a bank and the agent still cannot act on it. Promote them, but **not uniformly**:
read against the source, these three tools have three very different risk
profiles, and two of them can damage the session.

**`bank` — expose all three ops. This is the one that earns its place.**

The strategic case is real and checkable. `make_corpse()` (`src/fight.c`) moves
carried gold onto a lootable corpse and zeroes it:

```c
if (GET_GOLD(ch) > 0) { money = create_money(GET_GOLD(ch)); obj_to_obj(money, corpse); }
GET_GOLD(ch) = 0;
```

`GET_BANK_GOLD` is never referenced in `make_corpse()` or `die()`. Death costs
half of total experience (`gain_exp(ch, -(GET_EXP(ch) / 2))`) and **all** carried
coin; banked coin survives intact. For a level-1 character that has died
repeatedly in the logged sessions, "deposit before going somewhere dangerous" is
a genuine strategy the agent currently cannot express.

Every op is safe and reversible, and `SPECIAL(bank)`'s messages parse cleanly
for both the affordance probe and the player-state hook:

```
"Your current balance is %d coins."          → affordance yes, and gold_bank = N
"You currently have no money deposited."     → affordance yes, gold_bank = 0
"You deposit %d coins."  /  "You withdraw %d coins."
"You don't have that many coins!"            → refused, no state change
"You don't have that many coins deposited!"  → refused, no state change
"How much do you want to deposit?"           → bad/missing amount
```

`balance` is the probe (read-only, no side effects) *and* the reading that
finally populates `player_state.gold_bank` — the column V2 reserved with the
comment "from `check(gold)` if ever issued" and which has been NULL ever since.
Add `bank` to `SCORE_STALE_TOOLS` alongside `shop`: a deposit moves gold without
printing the new carried total.

**`mail` — expose `check` and `receive` only. Never `mail` (send).**

`postmaster_send_mail` ends in `string_write(ch->desc, mailwrite, MAX_MAIL_SIZE,
recipient, NULL)`. That puts the connection into tbaMUD's **string editor**: the
postmaster says `"Write your message. (/s saves /h for help)."` and from that
moment every line the daemon sends is message body, not a command, until `/s`.
`MudManager::Primitives#cmd` has no concept of a mode — it builds one raw line
and expects one response — so a single `mail <someone>` call silently converts
every subsequent tool call in the session into prose appended to an unsent
letter. That is not a tool that occasionally fails; it is a tool that
irreversibly breaks the session on first use.

`check` and `receive` are ordinary request/response and safe:

```
"$n tells you, 'You have mail waiting.'"
"$n tells you, 'Sorry, you don't have any mail waiting.'"   → affordance yes, no mail
```

Note the affordance probe for `mail` must use `check`, and must not read
"Sorry, you don't have any mail waiting" as a `do_not_here`. The two "Sorry"
strings are unrelated and only one of them means "wrong room".

**`rent` — expose `offer` only. Never `rent`.**

`gen_receptionist` (`src/objsave.c`) ends the rent branch with:

```c
Crash_rentsave(ch, cost);
mudlog(...);
extract_char(ch);        /* It saves. */
```

`extract_char()` removes the character from the game and drops the connection.
The agent renting means the daemon's telnet session dies and every subsequent
tool call in the session fails. There is no gameplay reason for the agent to
ever call it — renting is how a *human* logs out safely, and the agent's
equivalent is `save_character`, which is already exposed.

`offer` is the harmless half: it is the receptionist's price quote and changes
nothing.

```
"$n tells you, 'For a total of %ld coins%s.'"   → affordance yes
```

**Two defects in the existing `shop` tool, found by the same reading.**

`SHOP_OPS = %w[buy sell list value offer]` (`primitives.rb:43`) is wrong at both
ends. `SPECIAL(shop_keeper)`'s branches are `steal`, `buy`, `sell`, `value`,
`list`, `identify` — there is **no `offer` branch**. So `shop(action: "offer")`
sends a command the shopkeeper ignores, it falls through to `do_not_here`, and
the model is handed a guaranteed failure that the enum advertises as valid.
Meanwhile `identify` *is* a shop verb and is missing. Fix both:

```ruby
SHOP_OPS = %w[buy sell list value identify].freeze
RENT_OPS = %w[offer].freeze          # offer belongs to gen_receptionist, not the shop
```

This also removes the §"Edge cases" pet-shop wrinkle by one verb: the gap
between what `tbamud__shop` advertises and what `pet_shops` implements is
`sell|value|identify`, not four verbs including a phantom.

**New tool table entries** (`mcp/tool_spec.rb`, category `utility`, mode
`:primitive`), and the primitives they need:

| tool | params | primitive | notes |
|---|---|---|---|
| `bank` | `action` (enum `BANK_OPS`, required), `amount` (integer) | `P.bank` — exists | full access |
| `mail_check` | none | new: `P.mail_check` → `check` | split out of `P.mail` |
| `mail_receive` | none | new: `P.mail_receive` → `receive` | |
| `rent_offer` | none | new: `P.rent_offer` → `offer` | `P.rent` stays in the gem, unexposed |

`P.mail` and `P.rent` are not deleted — the gem is a general MUD client and a
human driver may legitimately want them. They simply get no MCP tool, which is
the existing pattern for the admin/immortal primitives already sitting below
them in the same file.

**Ordering.** `bank` is worth building with §1–§3; `mail_check`/`mail_receive`/
`rent_offer` are low-value and can wait, but the `SHOP_OPS` fix and the decision
*not* to expose `mail`/`rent` should land now, before someone uncomments them in
settings.yaml on the assumption that anything in `Primitives` is fair game.

### Scope

- `Mud::Memory::Schema` — V5 as above; `MIGRATIONS = [V1, V2, V3, V4, V5]`.
- `Mud::Memory::Store` — `record_affordance!(room_id:, affordance:, available:,
  evidence:)` and `affordances_for(room_id)`.
- `Mud::RoomParser` — one classifier, `parse_shop_probe(text)` →
  `true | false | nil`, against the three strings quoted above. `nil` (anything
  unrecognised) writes nothing, same asymmetry `movement_outcome` uses: a missed
  reading costs one probe, a wrong one costs a permanently wrong room.
- `Mud::AffordanceProbe` (new, small) — the mob/object-gated probe, run from
  `Mud::Hooks#before_model` in its own `affordance_probe` span. Takes an
  injected `call_tool` exactly as `RoomSurvey` does, so it tests against a
  transcript with no MUD. Deliberately not part of `RoomSurvey` — Decisions §2.
- `Mud::Hooks` — call the probe; learn-on-use in `after_tool`; pass affordances
  into `render_state`; extend `compute_turn_policy` with the omit/pin logic
  from §5.
- `Mud::StateBlock` — `affordance_line`.
- `MudManager::Primitives` — fix `SHOP_OPS` (drop `offer`, add `identify`); add
  `RENT_OPS`, `P.mail_check`, `P.mail_receive`, `P.rent_offer`.
- `MudManager::Mcp::ToolSpec` — new `bank` entry (§6), then `mail_check`,
  `mail_receive`, `rent_offer`. `P.mail` and `P.rent` stay unexposed **by
  decision, not by omission** — leave a comment saying so at both call sites, or
  they will be promoted by someone reading the file top to bottom.
- `Mud::Hooks` — add `bank` to `SCORE_STALE_TOOLS`; capture `gold_bank` off any
  `balance` result in `capture_player`.
- `.boukensha/settings.yaml` — the survey/probe allowlist entries
  (`"tbamud__shop(action: list)"`, `"tbamud__bank(action: balance)"`), the
  player's `tbamud__bank`, plus `memory.affordance_probe: false` and
  `memory.conditional_tools: false`.
- One table mapping affordance → tool name → verbs the proc actually implements
  (`shop` → `tbamud__shop` → all five for `shop_keeper`, `list|buy` for a pet
  shop). It belongs next to `Hooks::SCORE_STALE_TOOLS`, which is the same kind
  of deployment fact.

### Out of scope / not proposed here

- **Reading the bundled `.shp` files.** `week0_explore/infrastructure/lib/world/shp/`
  is the ground truth — `30.shp` maps keeper 3001 to room 3009 — and reading it
  would make every shop known for free with no probes at all. Rejected on the
  principle `DestinationSearch` already states in its own header: the agent
  searches "the agent's OWN knowledge — never the bundled world files." An agent
  that knows where the shops are without ever having walked into one is not the
  agent this project is building.
- **`mail` (send) and `rent`.** Not "later" — **not at all**, for the reasons in
  §6: `mail` enters tbaMUD's string editor and converts every subsequent tool
  call into letter body, and `rent` calls `extract_char()` and drops the
  session. Both would be exposed by a well-meaning reading of `Primitives`, so
  the refusal is recorded here rather than left implicit.
- **`practice` and `gen_board`.** `practice` gets an affordance row but never a
  probe (§"What a context command is"); `gen_board` has no tool and needs none —
  boards are reached through `examine`, which works today.
- **`house_admin`.** The fourth entry under the room-procedural heading. Player
  housing is not in play for this agent; no tool, no affordance, no probe.
- **Putting the stock list in the state block.** The bakery's listing is ~10
  lines and prices change; the block is ~45 tokens and must stay that way.
- **Suppressing non-room-procedural tools.** §5's mechanism could hide `attack`
  in a room with no mobs, `move` where there are no exits, and so on. Out of
  scope: those are inferences about *live* state, not the static room property
  this doc is about, and the `here:` line's own header comment explains why live
  presence is the thing most likely to be wrong.

### Edge cases

- **Probe in a room whose only mob is a janitor.** Returns "Sorry, but you cannot
  do that here!", writes `available = 0`, and the room is never probed again.
  Correct and cheap. (The Bakery has *both* a janitor and the baker — mobs are
  not one-per-room, and nothing in the design needs to know which one answered.)
- **Shop closed for the day.** `src/shop.c` has `MSG_NOT_OPEN_YET` /
  `MSG_CLOSED_FOR_DAY`, which are neither the listing header nor `do_not_here`.
  `parse_shop_probe` returns `nil`, nothing is written, and the room is probed
  again next discovery. It is a shop; we just have not proved it yet, and
  writing `available = 0` here would be the wrong lie to tell forever.
- **Keeper killed or moved.** `available = 1` becomes stale. Learn-on-use
  corrects it: the next `shop` call returns `do_not_here` and `after_tool`
  overwrites the row to 0. A stale positive costs one wasted call; a stale
  negative costs nothing, since the state block simply omits the line.
- **Provisional rooms** (`confidence = 'provisional'`, `hooks.rb:394`). They get
  affordance rows like any other room. If the ambiguity resolver is ever built
  it will have to merge them, the same as exits and sightings.
- **Pet shops.** `pet_shops` implements only `list` and `buy` of the five verbs
  `tbamud__shop` offers, so a naive positive would render all five and invite
  three guaranteed failures. This is exactly what §5's *pin* case exists for:
  store the implemented verb set with the row, and the state-block line and the
  advertised enum both narrow to `list|buy`. The probe cannot tell a pet shop
  from a real shop by its `list` output alone, so the verb set starts as all
  five and is corrected on the first `sell`/`value`/`offer` failure — which is
  learn-on-use doing its job at param granularity rather than tool granularity.
  Midgaard has one (room #40); the world has seven.
- **A tool suppressed by §5 in a room whose negative is stale.** The model
  cannot call it, so it cannot self-correct. This is the design's worst failure
  and the reason `memory.conditional_tools` defaults off and is separate from
  `memory.turn_policy`. Mitigations, in order: unknown always advertises; a
  negative older than the current session is treated as unknown; and the
  `UnauthorizedToolError` path clears the row.
- **`gen_board` objects.** `examine <board>` is genuinely the right call there,
  and `examine` is never suppressed. No interaction — noted only because the
  original problem statement raised bulletin boards, and this is the answer:
  they are a context command whose command happens to be `examine`.

### Test plan

Everything below is a transcript in, a hash out — `RoomSurvey` takes an injected
`call_tool` and `StateBlock` is pure, so none of this needs a MUD.

1. `RoomParser.parse_shop_probe` — `true` for the real bakery listing header
   (capture it from session `478e3d49` line 86), `false` for
   `"Sorry, but you cannot do that here!"`, `true` for
   `"Currently, there is nothing for sale."`, `nil` for `MSG_CLOSED_FOR_DAY`
   text and for `""`.
2. `AffordanceProbe` — a room with ≥1 mob and no affordance rows yields exactly
   one `shop` call; a room with no mob yields zero (the gate); a room that
   already has a `shop` row yields zero (probed once, ever).
3. `Store` — `record_affordance!` upserts: 1 then 0 leaves one row reading 0.
4. `Hooks#after_tool` — a `tbamud__shop` result containing `do_not_here` writes
   `available = 0` for `@current_room_id`; a listing writes 1; a `shop` result
   while `@current_room_id` is nil writes nothing and does not raise.
5. `StateBlock.render` — the line appears when an affordance is available and on
   a **revisit** (`first_visit: false`), and is absent entirely when the list is
   empty or all-negative. Assert the rendered verbs are a subset of `SHOP_OPS`,
   the same drift guard `DIRECTIONS` already gets (`state_block.rb:132`).
6. Permissions — `"tbamud__shop(action: list)"` validates against the tool's
   enum at startup, and the survey's registry raises on `shop(action: "buy")`.

Conditional tools (§5) — these are the ones worth writing first, because they
are the ones whose failure is silent:

7. `compute_turn_policy` with `conditional_tools` **off** advertises exactly
   what it advertises today. The flag genuinely gates.
8. Affordance `available = 0` for the current room ⇒ `advertised_tools` omits
   `tbamud__shop` and every other tool is still present. `available = 1` ⇒
   present. **No row ⇒ present** — assert this one explicitly and by name, since
   it is the invariant that keeps the system able to learn.
9. Verb pinning: a row carrying `list|buy` advertises `shop` with `action`
   narrowed to those two, and `call_permitted?` rejects `shop(action: "sell")`.
10. `turn_policy` can only narrow: with `tbamud__shop` absent from
    `tasks.player.allow`, an affordance saying `available = 1` does **not**
    make it callable.
11. A suppressed tool called anyway raises `UnauthorizedToolError` (not
    `UnknownToolError`), the message names the room, and the row is cleared.
12. `compute_turn_policy` raising anywhere inside the new logic still returns
    `nil` rather than a policy that denies everything — the existing
    `rescue StandardError` (`hooks.rb:687`) must keep covering this.

New tools (§6):

13. `Primitives.shop` raises `ArgumentError` on `"offer"` and accepts
    `"identify"`. This is a deliberate behaviour change to an existing enum;
    assert it so the removal is not quietly reverted.
14. `Primitives.bank("deposit", amount: 100)` builds `deposit 100`;
    `bank("balance")` builds bare `balance`; a negative or non-integer amount
    raises rather than sending `deposit -5`.
15. `ToolSpec.find("mail")` and `ToolSpec.find("rent")` return **nil**. Assert
    the absence directly — this is the only executable record that they are
    withheld on purpose.
16. `RoomParser` bank classifier — `"Your current balance is 250 coins."` →
    affordance yes and `gold_bank: 250`; `"You currently have no money
    deposited."` → yes and `gold_bank: 0`; `"You don't have that many coins!"`
    → yes (a bank answered) with no `gold_bank` write; `"Sorry, but you cannot
    do that here!"` → no.
17. Mail classifier does **not** treat `"Sorry, you don't have any mail
    waiting."` as `do_not_here`. The two "Sorry" strings mean opposite things
    and this is the one place they can be confused.
18. `Hooks#after_tool` on a `tbamud__bank` result sets `@scored = false`
    (`SCORE_STALE_TOOLS`) and writes `gold_bank`.

### Adjacent defect found while investigating (file separately?)

`RoomParser::NOT_HERE` is `/aren't here|isn't here|no one here|nothing here/i`
(`room_parser.rb:60`). tbaMUD's actual miss messages are neither of those:

```c
/* src/act.informative.c */
ACMD(do_consider) {
  if (!(victim = get_char_vis(ch, buf, NULL, FIND_CHAR_ROOM))) {
    send_to_char(ch, "Consider killing who?\r\n");
```

So `RoomSurvey#resolve` (`room_survey.rb:171-183`) never detects a miss: its
first keyword guess is always accepted, and the error string is stored as the
mob's `threat`. In knowledge.sqlite3 right now:

| id | descr | keyword | threat |
|---|---|---|---|
| 11 | The baker looks at you calmly, wiping flour… | `hand` | `Consider killing who?` |
| 28 | A bartender watches you calmly, while he… | `drink` | `Consider killing who?` |
| 33 | There is a Pet Shop Boy standing here cuddling… | `there` | `Consider killing who?` |

Two compounding causes:

- `RoomParser::VERB` (`room_parser.rb:54`) lists `is|are|was|were|has|have|had|
  stands?|sits?|lies?|rests?|sleeps?|hangs?|leans?|waits?|guards?|paces?|walks?|
  blocks?|kneels?|floats?` — but not `looks`, `watches`, or `cuddling`. The verb
  split never fires, the whole sentence is treated as the noun phrase, and
  `guess_keywords` reads it right-to-left to `hand` / `drink` / `there`.
- `NOT_HERE` then fails to reject the resulting miss, so the bad keyword and the
  error text are written to the **world-level** `entities` table, where they are
  reused in every room the description ever appears in.

That garbage is being rendered to the model today —
`here: The baker … (mob — "Consider killing who?")` — and it is not an accident
that all three affected rows are shopkeepers: they are the mobs whose
descriptions are written in the "X looks/watches you calmly" register that
`VERB` does not cover.

Fix is small: add the real strings to `NOT_HERE` (`Consider killing who\?`,
`You do not see that here\.`), widen `VERB`, and delete the three poisoned rows.
Worth doing regardless of anything above, and arguably ahead of it.

### Decisions taken

**1. Gate the probe.** [Decided] Rooms with no mob are not probed: 32 probes
over the 56 rooms currently known instead of 56.

One consequence to accept knowingly, because the proc table above is what
uncovered it: `pet_shops` is a **room** proc and needs no mob, so a mob gate is
not sound for it in principle. In practice all seven pet-shop rooms in the
stock world are staffed — Midgaard's (#40) holds `"There is a Pet Shop Boy
standing here cuddling something furry."` — so the gate costs nothing today.
It is a heuristic riding on a world-building convention, not on the engine, and
that is worth writing down where the gate is implemented rather than
rediscovering it against an unstaffed pet shop later. Learn-on-use (§2a) is the
backstop: an unstaffed pet shop is still learned the first time the model calls
`shop` there.

The gate is per affordance and matches what each proc binds to (see the table in
§2b) — mob for `shop`/`mail`/`rent`, **object** for `bank`, never for
`practice`. A single global "has a mob" rule would be wrong for banks.

**2. The probe lives outside `RoomSurvey`.** [Decided] Its own `before_model`
step rather than a fifth command inside the survey, so affordance discovery can
be switched off independently of the survey it would otherwise ride.

This costs a little of the tidiness the alternative had — the survey's header
comment claims the first visit's spend as one unit, and this puts a round trip
next to it rather than in it — so it needs its own operation span
(`during("affordance_probe", "before_model")`, alongside `position_refresh` and
`state_render`) or the monitor will show an unexplained `shop` call as a sibling
of the model's own actions. That is the same reason `RoomSurvey` opens its span
from inside `#survey` rather than letting its caller name it.

It also needs its own settings key. Three flags now, each gating a different
risk, and they should not be collapsed:

```yaml
memory:
  turn_policy:         false   # pin `move` — a constraint that cannot be wrong
  affordance_probe:    false   # spend a round trip per new room
  conditional_tools:   false   # suppress a tool on a stored negative
```

**3. Expose the missing MCP tools.** [Decided] `bank` in full — the strategy is
real and verified (carried gold becomes corpse loot on death, banked gold is
untouched), and it finally populates the `gold_bank` column V2 reserved and
never filled. `mail_check`, `mail_receive` and `rent_offer` follow when
convenient. `mail` (send) and `rent` are refused outright — see §6; they enter
an editor and disconnect the session respectively, and neither failure is
recoverable from inside a turn.

**4. Open — does §3 alone fix it?** §4 (the `after_tool` nudge) is still
deliberately optional. Ship 1–3, run "find the bakery and list the menu" 10×
against a cold and a warm knowledgebase, count `examine`-before-`shop`, and
decide then. §5 is worth building regardless of that number, since its argument
is the tool surface rather than this one task.