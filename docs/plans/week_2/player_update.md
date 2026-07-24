# PLAYER — teaching the knowledgebase who the agent *is*

> **Status: plan, for review.** The map half of the knowledgebase is rich (rooms,
> exits, entities, encounters); the *player* half is four numbers on a single
> `player_state` row. This plan closes that gap — score sheet, skills, inventory,
> equipment — using the same three-lifetime doctrine and the same "free reading"
> discipline the room memory already runs on. Nothing here changes how rooms work.

## What this builds

We wired MUD knowledge into the agent's lifecycle hooks (`Mud::Hooks`, with
`RoomParser` as the pure text→struct half). Those hooks already reconcile *where the
agent is* into `knowledge.sqlite3`. They do **not** capture *what the agent is*: the
schema has no notion of the character's skills, inventory, worn equipment, or the two
thirds of the `score` sheet below hit points.

The Observatory plan (`mud_observer.md`) wants a cockpit — vitals, activity, a plan.
It cannot show a character sheet the knowledgebase never recorded. So this is the
prerequisite: **collect player identity into the schema, then surface it on the
Knowledge tab.** Three deliverables, in dependency order:

1. a **collection strategy** that reuses readings the agent already pays for;
2. an **additive schema migration** (V2) for the new player facts;
3. a **Player view** on `mud_monitor`'s Knowledge tab that renders them.

---

## 0. Ground truth first — read the MUD, not CircleMUD memory

The single most important rule for this work: **every field and every wording is taken
from real output this build actually emits, not from what a stock CircleMUD `score`
"should" say.** tbaMUD is forked and re-worded per install; the engine source is not in
this repo. We have something better than memory — the telnet logs already capture the
real bytes. A live `score` from `.boukensha/telnet/20260723.jsonl` (seq 464):

```
You are 17 years old.
You have 20(20) hit, 100(100) mana and 78(85) movement points.
Your armor class is 100/10, and your alignment is 0.
You have 1 exp, 0 gold coins, and 0 questpoints.
You need 1999 exp to reach your next level.
You have earned 0 quest points.
You have completed 0 quests, and you are not on a quest at the moment.
You have been playing for 1 day and 21 hours.
This ranks you as Dummy the Swordpupil (level 1).
You are standing.
You are hungry.
You are thirsty.
```

Two facts fall out of that capture that no amount of remembering would have given us,
and both shape the design:

- **`parse_score` silently drops `exp` in this build.** It matches `/scored (\d+) exp/`,
  but this MUD says *"You have 1 exp"*. So the `exp` column is written only on the rare
  path where some other text carries "scored"; the score sheet's own exp never lands.
  This is a live bug the expansion fixes, and the reason the plan starts from a real
  fixture rather than the existing regexes.
- **`score` carries maxes the prompt line does not.** *"100(100) mana and 78(85)
  movement"* gives `max_mana`/`max_move` — values `mud_observer.md §2` explicitly
  assumed the schema could never hold. Storing them here means the Observatory cockpit
  can later draw mana/move bars it currently has no denominator for. We do not build
  those bars now; we stop throwing the denominator away.

**Fixtures are harvested, not authored.** Every parser test below is seeded from a
string pulled out of the telnet log (score, inventory, equipment, practice), the same
way `knowledge_fixtures.rb` seeds room tests from a real `knowledge.sqlite3`. When a
capture for a given command does not yet exist in the logs, capturing one — issue the
command against the live MUD once, copy the bytes — is step zero of that parser, ahead
of writing its regex.

---

## 1. The doctrine question — which lifetime does each fact belong to?

`memory/schema.rb` opens by refusing to let three lifetimes share a row:

> PERMANENT — world data that cannot change → `rooms`, `room_exits`
> VOLATILE — true only right now → `player_state`
> EARNED — what the agent learned → `entities`, `encounters`

Player data is not one kind of thing, so it does not get one answer. Sorting each piece
into its lifetime **is** the schema design, and getting it wrong is what the doctrine
exists to prevent (inventory is not a fact the agent should later read as belief).

| Player fact | Lifetime | Home | Why |
|---|---|---|---|
| Score core — level, exp, exp-to-next, gold, hp/mana/move **+ their maxes**, AC, alignment, age, title, hunger/thirst, position | **VOLATILE** | **extend `player_state`** | Already the "true right now" single row. These are the same *kind* of value as the `hp`/`level` columns that live there today — slow-drifting current state, exactly one of each. They are additional columns, not a new table. |
| Skills & proficiencies — what the character *knows* and how well | **EARNED** | **new `player_skills`** | A practiced skill is learned knowledge that survives logout and is spent to gain — the textbook EARNED shape, a sibling of `entities`. One row per skill, updated when proficiency changes. |
| Inventory & worn equipment — what is carried / equipped *right now* | **VOLATILE** | **new `player_items`** (wholesale-replaced snapshot) | This is the doctrine's sharpest edge. Inventory changes every `get`/`drop`/`consume`; it is "true only right now," never a fact to read back later. So it is modelled like `player_state`: a snapshot the writer **overwrites in full** on each reading, never an append log. `player_state` is one row because there is one player; `player_items` is N rows because there are N items — but the overwrite semantics are identical. |

The rule this table enforces: **an item the agent dropped ten rooms ago must not still
appear in its knowledge.** That is why inventory is replace-on-read and lives nowhere the
agent reads as durable belief. Skills are the opposite — losing a skill row because the
agent walked away would be a lie of a different kind — so they persist and update in place.

---

## 2. Schema V2 (`memory/schema.rb`)

Additive by construction, applied on `PRAGMA user_version` — **append a `V2` constant to
`MIGRATIONS`, never edit `V1`.** The monitor attaches this file read-only with
`migrations_paths: []`; the agent is the only writer. A reader on an older build sees
new columns/tables it does not query and is unaffected (§7).

```sql
-- V2: the player half of the knowledgebase.

-- 2a. Extend the single volatile row. Every column NULLable — "no reading yet"
--     is a real state, and update_player!'s COMPACT-then-merge already treats
--     nil as "no reading this time", never "clear it".
ALTER TABLE player_state ADD COLUMN max_mana        INTEGER;  -- score gives it; prompt does not
ALTER TABLE player_state ADD COLUMN max_move        INTEGER;
ALTER TABLE player_state ADD COLUMN exp_to_next     INTEGER;  -- "You need N exp to reach your next level"
ALTER TABLE player_state ADD COLUMN armor_class     TEXT;     -- "100/10" — keep verbatim, it is two numbers
ALTER TABLE player_state ADD COLUMN alignment       INTEGER;
ALTER TABLE player_state ADD COLUMN age_years       INTEGER;
ALTER TABLE player_state ADD COLUMN title           TEXT;     -- "Dummy the Swordpupil"
ALTER TABLE player_state ADD COLUMN char_class      TEXT;     -- if/when this build's score prints it (see §3)
ALTER TABLE player_state ADD COLUMN race            TEXT;     -- ditto — column reserved, written only when parsed
ALTER TABLE player_state ADD COLUMN gold_bank       INTEGER;  -- from `check(gold)` if issued; else NULL
ALTER TABLE player_state ADD COLUMN conditions      TEXT;     -- "hungry,thirsty" — small, low-cardinality, joined
ALTER TABLE player_state ADD COLUMN practices_left  INTEGER;  -- practice sessions remaining
ALTER TABLE player_state ADD COLUMN items_updated_at TEXT;    -- when the item snapshot below was last replaced

-- 2b. EARNED: skills the character knows. Survives logout; updated in place.
CREATE TABLE player_skills (
  name          TEXT PRIMARY KEY,          -- "backstab", "second attack" — one row per skill
  proficiency   INTEGER,                    -- percent, when the source gives one; else NULL
  learned_level INTEGER,                    -- player level when first seen known
  first_seen_at TEXT NOT NULL,
  last_seen_at  TEXT NOT NULL
);

-- 2c. VOLATILE snapshot: what is carried / worn RIGHT NOW. Wholesale-replaced on
--     each reading — there is no history here, and there must not be. No FK to a
--     world table: items are the character's, not a room's.
CREATE TABLE player_items (
  id         INTEGER PRIMARY KEY,
  location   TEXT NOT NULL CHECK (location IN ('inventory','equipped')),
  worn_on    TEXT,             -- "wielded", "worn on body" … only for equipped rows
  keyword    TEXT,             -- best-guess handle for acting on it (RoomParser.guess_keywords)
  descr      TEXT NOT NULL,    -- the line as the MUD printed it
  quantity   INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_items_location ON player_items(location);
```

`char_class`/`race` are reserved but written **only if** a real capture proves this
build's `score` (or `who`/`whoami`) actually prints them — the §0 capture does not, so
they stay NULL until a fixture says otherwise. Reserving the column is free; inventing a
parser for text the MUD never emits is not.

`LATEST_VERSION` becomes 2 automatically (`MIGRATIONS.size`). Nothing else in the file
changes.

---

## 3. Parsing (`RoomParser`, still pure text→struct)

The parser stays what it is: strings in, structs out, no round trips — that purity is
what lets it run in `after_tool`'s hot path. Four changes, each backed by a harvested
fixture (§0):

- **`parse_score` — expand + fix.** Keep the existing four keys, correct the `exp`
  regex to this build's *"You have (\d+) exp"*, and add `max_mana`/`max_move` (the
  `N(M)` maxes), `exp_to_next`, `armor_class`, `alignment`, `age_years`, `title`
  (from *"ranks you as (.+?) \(level"*), `practices_left`, and `conditions` (hungry/
  thirsty/drunk lines collapsed to a comma list). Every field independently matched and
  `.compact`ed — the existing contract that "a MUD that words one line differently must
  not cost us the others" is exactly why this stays a bag of optional regexes, not one
  brittle template.
- **`parse_inventory(text)` → `[{descr, quantity, keyword}]`.** tbaMUD prints
  *"You are carrying:"* then item lines, collapsing duplicates as *"(N) a torch"*.
  Reuse `guess_keywords` (already used for mob handles) for the actionable keyword. An
  empty pack (*"You are not carrying anything."*) parses to `[]`, which is a valid
  snapshot, not a failure.
- **`parse_equipment(text)` → `[{worn_on, descr, keyword}]`.** *"You are using:"* then
  `<worn on body>  a leather jerkin` lines. The `<slot>` is the `worn_on`. This is the
  same shape `parse_examine` already reads off a *mob's* `is using:` block — factor the
  shared line-reader so we parse our own gear and a mob's with one function.
- **`parse_skills(text)` → `[{name, proficiency}]`.** From `practice`'s listing. **This
  is the one with a live-behaviour caveat that must be verified against the MUD, not
  assumed:** in stock CircleMUD `practice` with no argument lists skills *only at a
  guildmaster*, and elsewhere says *"You can't practice here."* If this build behaves
  that way, `parse_skills` returns `[]` on the refusal line and the collector simply
  does not fire outside a guild — capture both cases from the log before trusting either.

All four degrade to `[]`/`{}` on unrecognised text, never raise.

---

## 4. Collection strategy — pay only for readings the agent already makes

The room memory's whole ethos is that the expensive readings are ones the agent was
going to make anyway (`before_turn`'s score, `after_tool`'s free prompt-line scrape).
Player collection follows the same rule — **no new unconditional round trips** — sorted
by how often each fact changes:

| Fact | Trigger | Cost | Rationale |
|---|---|---|---|
| **Score core** | `before_turn` already issues `check(score)` once per process (and again after level-up, via the `@scored = false` reset). | **Zero added.** | The reading is already paid for; today we throw two thirds of it away. Widening `parse_score` and passing the whole hash to `update_player!` captures it for free. Also keep the existing `after_tool` catch of the *model's own* `check(score)`. |
| **Inventory / equipment** | Opportunistic, in `after_tool`: parse the result whenever the model itself issues `check(inventory)` / `check(equipment)`, **and** re-derive after any mutation it already performs — `get_item`, `drop_item`, `equip_item`, `consume_item`, `get`/`put`. | **Zero added round trips**; one snapshot rewrite per relevant tool. | Same trick as the free score-catch: the agent looks in its pack and moves items on its own initiative for gameplay reasons; we ride those results. A mutation without a following inventory read marks the snapshot **stale** (`items_updated_at` untouched) rather than guessing the delta — honest staleness over a fabricated bag. |
| **Skills** | Opportunistic on `practice` results, plus a dirty-flag on level-up (reuse the `LEVEL_UP` regex that already clears `@scored`). | **Zero added.** | Skills change only on practice or level. Capturing the `practice` listing the agent requests, and re-reading opportunistically after a level, covers every moment they can change without a polling loop. |

Everything is wrapped in the hooks' existing `guard` — a broken player-capture path must
degrade to "no player detail," never kill the turn, exactly as room capture does.

**Deliberately NOT done:** a scheduled `check(inventory)` every N turns. It would buy
freshness with round trips the doctrine spends nowhere else, and the monitor can show
"snapshot as of T" honestly instead. If review wants guaranteed-fresh inventory, it is a
one-line addition to `before_turn` behind a config flag — but it is opt-in, not the default.

---

## 5. Writer (`memory/store.rb`)

`update_player!` already does exactly the right thing for the new `player_state`
columns — `.compact` then merge, nil means "no reading," and it builds its column list
dynamically — so the widened score hash flows through it with **no store change at all**.
Two new methods for the two new tables, each mirroring an existing pattern:

```ruby
# EARNED, upsert-in-place — the shape of remember_entity.
def upsert_skills!(skills)          # [{name:, proficiency:}]
  # INSERT … ON CONFLICT(name) DO UPDATE SET proficiency = COALESCE(excluded.proficiency, …),
  #                                          last_seen_at = excluded.last_seen_at
end

# VOLATILE snapshot, wholesale replace in ONE transaction — the shape of
# update_player!'s "overwrite, don't accumulate". A dropped item vanishes here
# the instant the next snapshot lands, which is the whole point.
def replace_items!(location:, items:)  # DELETE WHERE location=? ; INSERT … ; stamp items_updated_at
end
```

`replace_items!` scopes its delete to the `location` it is replacing so a fresh
`inventory` read never wipes the last known `equipment` and vice-versa. Both run under
the same WAL/`busy_timeout` connection already open.

Add `player_skills` / `player_items` counts to `Store#stats` so the writer's own tally
stays symmetric with the reader's (§7) — the "what the writer counts vs what the reader
counts, side by side" property `stats` exists to preserve.

---

## 6. Rendering to the model (`state_block.rb`) — restraint on purpose

The state block is ~45 transient tokens and its discipline is *don't re-send what the
model already read.* Player identity is mostly **not** state-block material: the model
does not need its full inventory re-printed every 5 seconds. So the block changes little:

- The existing `you:` line gains nothing by default — hp/level/gold/position already
  suffice per-iteration.
- **On demand only:** when the model just issued `check(inventory)`/`check(score)`, that
  result is already in its context; we do not duplicate it into the block.
- The captured detail's job is the **monitor** (§7–8) and the **Observatory cockpit
  later**, not the per-turn prompt. This keeps the token win of the room work intact.

If review wants one addition, the honest candidate is a single `gear:` line naming
*wielded/worn* items on first entry to combat — but that is a follow-up, flagged not built.

---

## 7. Monitor reader + controller (`mud_monitor`)

The reader is the drift-detector: it names every column and turns a missing one into a
`knowledge_schema_mismatch` banner rather than silent blanks. Changes:

- **Bump `Reader::KNOWN_SCHEMA_VERSION` 1 → 2.** A newer file is already served (the
  reader's own doc says migrations are additive), but the number is what the footer shows.
- **Widen `player`'s SELECT** with the new `player_state` columns, extending the named-
  column list. Because the columns are additive and NULLable, a **V1 file still answers**
  — but a named SELECT of a column that does not exist raises, so guard the new columns
  behind the reported `schema_version` (select the V2 set only when `schema_version >= 2`;
  fall back to the V1 projection otherwise). This is the forward/backward-compatible seam
  that lets one monitor read both an old and a new agent file.
- **New reader methods**, each named-column and read-only, mirroring `entities`:
  `player_skills` (ordered by name), `player_items(location:)` (inventory / equipped),
  and their counts folded into `stats`.
- **`KnowledgeController`:** extend `#show`'s payload with `skills` + `items`, or — given
  the volume — add a dedicated `GET /knowledge/player` action returning
  `envelope.merge(player:, skills:, items:)`. A dedicated action keeps the Overview
  poll light and matches the existing one-action-per-view shape (`rooms`, `entities`,
  `frontier`). Route + serializer follow the established pattern; nothing streams (this
  is belief, polled at 3s, no `StreamGate` slot).

---

## 8. Frontend — a Player subtab on the Knowledge page

Overview already renders four player tiles (hp/level/mana-move/gold) from the `player`
payload. Skills + inventory + equipment + the full score sheet is too much for the
Overview summary, so:

- **Keep** the four-tile summary on `Overview.tsx` (it is a glance, and it stays), and
  add the new maxes where they now exist (mana/move gain a `/ max` denominator).
- **Add a `Player` subtab** — `web/src/pages/knowledge/Player.tsx`, a fifth entry in
  `Knowledge.tsx`'s `TABS`, polling the new endpoint. It renders:
  - a **score sheet** (`<dl className="knowledge-facts">`, the existing pattern): class/
    race/title, level + exp + exp-to-next, AC, alignment, age, practices-left, conditions;
  - **Equipment** — worn slots (`worn_on` → item), the character-sheet paperdoll;
  - **Inventory** — the carried list with quantities, headed by *"snapshot as of
    {items_updated_at}"* so staleness is a visible fact, not a silent one (the same
    honesty the Overview footer already applies to `player_state`);
  - **Skills** — name + proficiency, sorted, reusing the existing progress-bar / chip
    components rather than new CSS.
- Types in `api/types.ts`, `fetchKnowledgePlayer` in `client.ts`, wired through the same
  `useReportEnvelope` so the freshness badge and footer work with no extra request.

No new dependencies; every element reuses `stat-tile`, `knowledge-facts`, `ProgressBar`,
`ThreatChip`-style chips, and the existing token palette.

---

## 9. Phasing (each step independently verifiable)

- **P0 — Fixtures.** Harvest real `score`, `inventory`, `equipment`, `practice` captures
  from the telnet logs (score already exists at seq 464; capture the others live if
  absent) into `test/fixtures`. *Done when* each command has a real string on disk.
- **P1 — Parser.** Expand `parse_score` (fix `exp`, add the new fields), add
  `parse_inventory`/`parse_equipment`/`parse_skills`, all as pure functions with
  fixture-seeded unit tests including the empty-pack / practice-refusal cases. *Done
  when* the parser suite is green against the harvested strings.
- **P2 — Schema + store.** Append `V2`; add `upsert_skills!`, `replace_items!`; extend
  `stats`. Migration test: a V1 file migrates to V2 with no data loss and
  `user_version == 2`. *Done when* store tests seed, write, and read back all three.
- **P3 — Collection.** Wire the widened score through `before_turn`, the opportunistic
  inventory/equipment capture through `after_tool`, skills on practice/level-up — all
  inside `guard`. Hook tests assert: score sheet lands in `player_state`; a
  `drop_item` followed by an `inventory` read shrinks the snapshot; a broken parse
  leaves the turn alive. *Done when* the hook suite is green.
- **P4 — Reader + controller.** Bump `KNOWN_SCHEMA_VERSION`, widen `player`, add
  `player_skills`/`player_items`, the `/knowledge/player` action; the V1-fallback
  projection. *Done when* the reader reads both a V1 and a V2 fixture without a mismatch.
- **P5 — Frontend.** Overview maxes + the `Player` subtab. *Done when* a live/seeded
  file renders score sheet, equipment, inventory-with-staleness, and skills.
- **P6 — Ship.** `npm run build`, commit `web/dist/`, update the monitor README's page
  list (a new subtab).

---

## 10. Testing

Mirror the knowledge tests. `knowledge_fixtures.rb` builds a real `knowledge.sqlite3`
from `seed.sql`; extend `seed.sql` with V2 tables + a few `player_skills`/`player_items`
rows and an expanded `player_state`, so the reader/controller tests exercise the new
shape. The parser is the correctness spine (harvested fixtures, exact asserts). The
migration test is non-negotiable: **a V1 file must migrate forward with every existing
row intact** — that is the guarantee the whole additive-DDL doctrine rests on.

---

## 11. Invariants

1. **Ground truth is the log, never memory.** Every parser field traces to a captured
   MUD string; unproven fields (class/race here) stay NULL, not guessed.
2. **One fact, one lifetime.** Score core → `player_state` (volatile row); skills →
   `player_skills` (earned, in-place); items → `player_items` (volatile snapshot,
   wholesale-replaced). Inventory is never an append log and never durable belief.
3. **No new unconditional round trips.** Collection rides readings the agent already
   makes; a scheduled inventory poll is opt-in, off by default.
4. **Additive schema only.** Append `V2`; never edit `V1`. Every new column NULLable.
5. **The monitor reads only named columns**, guarded by `schema_version`, and serves a
   V1 file and a V2 file from the same code.
6. **Honest staleness.** A snapshot the agent has not refreshed says so
   (`items_updated_at`); the writer never fabricates a delta it did not read.
7. **Broken capture degrades, never crashes.** Every new hook path is inside `guard`.
8. **Writer and reader counts stay symmetric** — new tables land in both `Store#stats`
   and `Reader#stats`.

---

## 12. Deferred / Not now

- **`gear:` state-block line** on entering combat (§6) — a token-budget call, follow-up.
- **Scheduled inventory refresh** (§4) — opt-in config flag, not built.
- **Item identity / appraisal** — treating owned items like `entities` (remembered value,
  keywords, sell price). Real, but a separate EARNED design; today items are a snapshot,
  not a knowledgebase.
- **Progression history over time** — *when* level/gold/items/skills changed, for graphing
  — is **out of scope here by decision**, and lives in its own plan (`change_capture.md`):
  an append-only jsonl journal in `.boukensha/`, not this snapshot DB. That decision
  settles the one open question this plan had: **`player_items` stays a replace-on-read
  snapshot** ("what's in the bag now"); the add/remove/use *history* is the journal's job.
  The two plans share one capture seam in `Mud::Hooks` — every point here that writes the
  store also upserts the journal — so build them adjacent.
- **Observatory cockpit wiring** — this plan fills `player_state.max_mana`/`max_move` and
  the skills/items tables; `mud_observer.md`'s cockpit consuming them is that plan's job,
  and only its composer changes, never its contract.
- **`char_class`/`race` parsing** — columns reserved; written the day a capture proves
  this build prints them (`score`, `who`, or `whoami`), not before.
