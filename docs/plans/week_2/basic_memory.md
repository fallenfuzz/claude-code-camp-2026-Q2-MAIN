## Lifecycle Hooks and Basic Memory

We need an SQLITE database. Our Rails Mud Monitor I think already expects one in our .boukensha directory as knowledge.sqlite.
I'd check rails for the naming convention.

We know that we need to store room data. our inspect_room has the schema.

We should also have a table of a single row that has current player information state:
 eg. current_room

We are trying to work towards adding lifecycle hooks into our agent
so before it invoke the agent it will check where it currently is.
if it doesn't know anything about this room, we would simply 

inspect_room is exposed as a tool, but its deterministic parsing.
It shouldn't be a tool but something do before a before_agent calls.

Currently we return inspect_room as json payload but we want to inject the least amount of
context the agent needs to know.

before_agent
  → collect any pending MUD output
  → parse room/player state
  → update local memory
  → compute allowed tools
  → call the model

## Technical Solution

> **Status: built.** Steps 0–9 of §13 are implemented and green (169 runs, 497
> assertions, 0 failures). §§1–13 below are the pre-build reasoning and are left
> as written — including the places the build proved them wrong. **[Part II](#part-ii--after-the-build)**
> at the end records what actually shipped, what changed, and what is still
> yours to decide. Read §16 first if you only read one thing.

---

## TL;DR

- **The naming convention is `knowledge.sqlite3`** (not `.sqlite`), in the
  *resolved* boukensha dir, overridable by `MUD_KNOWLEDGE_DB` —
  `mud_monitor/api/config/initializers/mud_monitor.rb:53`. The monitor already
  probes it (`knowledge_attached` in the health endpoint) but its
  `database.yml` was never converted to multi-db, so the `knowledge:` replica
  connection in the spec doesn't exist yet. §2.
- **The agent has no memory, and it shows.** In session `0d023f2a`, 11
  `inspect_room` calls covered **8 distinct rooms** — Market Square and Main
  Street were fully re-surveyed on the second visit. 27% of surveys bought
  information the transcript already contained, at 5 MUD round trips and ~230
  tokens each. §1.
- **`move` output confirms location; it never establishes a room record.** It
  looks like a full `look` and it isn't: `run_command` calls `s.drain` *before
  sending* (`session_pool.rb:70`), so a `move` silently **destroys** every
  async line that arrived while the model was thinking. A room built from move
  output is a room with a hole in it. Move output is an index key — fingerprint
  it, match it against the DB, and otherwise discard it. §5.4.
- **The discarded window is where the dangerous news lives, so `poll` stays —
  and moves.** Of 33 `poll` results across all sessions, 7 were non-empty, and
  they contain combat the agent never asked for (`You are mortally wounded` at
  **-6H**) plus `The cityguard leaves east`. The 79% empty rate is a *placement*
  bug: `poll` runs inside the survey, right after another command drained the
  buffer. The only moment the thinking-gap output is still alive is between the
  model's response and the first tool dispatch — hence the `before_tools` hook.
  `poll` leaves `RoomParser` entirely; it was never a room concern. §5.6.
- **`move`'s tool result is the single largest thing in the model's context —
  and the model needs almost none of it.** 46 results, 19,352 chars ≈ **4,838
  tokens**, permanently accumulating; larger than `inspect_room`'s own 3,611.
  The hook parses it, so the model gets a one-line outcome stub instead. §6.2.
- **Room state stops being a tool result and becomes a rendered state block.**
  A tool result is appended to `@messages` forever and re-sent on every
  subsequent call; a state block lives on the Context, is re-rendered from
  SQLite before each model call, and exists in exactly one copy that is always
  current. ~230 tokens/room accumulating → ~45 tokens, flat. §6.
- **`inspect_room` becomes `Mud::RoomParser` — pure, no injection — plus a
  separate `Mud::RoomSurvey` that owns the round trips.** Losing the `call_tool:`
  arg is the substantive half of the rename: a parser that only parses is
  testable with a string. §5.3, §8.
- **Entities are world-level; sightings are room-level.** Room-owned entity rows
  duplicated "A cityguard stands here." once per room *and* asserted that a
  wandering mob belongs somewhere. The split also makes the appraisal reusable:
  a familiar mob in a brand-new room costs **zero** `consider`/`examine` round
  trips. `threat` is stored with the level it was measured at, because
  `consider`'s answer changes as the player levels. §3.1.
- **Rooms can be uncertain, and later movement can pin them.** Two fingerprints
  (weak = free from any look; strong = adds neighbour *names*, costs one
  `check(exits)`), identity resolved by content **and** arrival edge, and a
  `provisional` confidence for the rest. The merge resolver is deferred — but
  the schema must drop `UNIQUE` on the fingerprint **now**, or adding it later
  means rewriting every foreign key. §4.
- **The hook seam is five call sites in `Agent`**, not a framework. `before_turn`,
  `before_model`, `before_tools`, `after_tool`, `after_turn`, defaulting to a
  null object. §5.2.
- **The plan's `before_agent` is one hook too coarse.** The agent moves
  *inside* the loop — 56 `move` calls in the last four sessions — so room state
  must be refreshed per *iteration*, not per turn. `before_model` is the real
  injection point. §5.1.
- **"Compute allowed tools" needs no new grammar.** `Permissions` already pins
  enum params (`move(direction: north|east)`), and the exits line is
  MUD-authoritative, so the turn policy is expressible in the rule syntax that
  already exists and already validates at startup. §7.
- **Three decisions for you** in §12: room identity, whether to resolve world
  vnums, and whether anything replaces `inspect_room` on the tool surface.

---

## 1. What the sessions actually show

Counted over the four most recent session logs:

| Signal | Count |
|---|---|
| `tbamud__move` calls | 56 |
| `inspect_room` calls | 28 |
| `tbamud__poll` / `look` / `check` inside surveys | 28 each |

And within the one multi-room session (`20260723T165156Z-0d023f2a.jsonl`):

| | |
|---|---|
| `inspect_room` results | 11 |
| Distinct rooms among them | 8 |
| Re-surveys of an already-surveyed room | 3 (Market Square ×2, Main Street ×2) |
| Room JSON accumulated in context | 6,961 chars ≈ **1,740 tokens** |
| Session input tokens | 64,971 |

Two conclusions, and they are different problems:

**Waste #1 — re-surveying.** Three of eleven surveys re-derived a room the
agent had already been told about, at ~5 MUD round trips apiece. A room's name,
prose and exits are *static world data*; they cannot change between visits.
Nothing about the design lets the agent know that.

**Waste #2 — accumulation.** Every survey result is a `tool_result` message, so
it sits in `@messages` permanently and is re-sent on every following API call
(`Agent#handle_tool_calls` → `@context.add_message(:tool_result, …)`). Eleven
surveys means the 11th call carries all ten previous rooms' full prose. The
compaction path (`Context#compact_messages!`, drop-oldest-40%) is what
eventually clears them — by throwing away the *oldest* memories, which are
precisely the rooms nearest the start of an exploration.

Memory fixes both, and they need different mechanisms: a **store** for #1, a
**state block** for #2.

**Waste #3 — what the model is handed but cannot use.** Measured over the last
six sessions, by tool, counting only results that land in the player's
`@messages`:

| Tool | Results | Chars | ≈ Tokens | Avg |
|---|---|---|---|---|
| `tbamud__move` | 46 | 19,352 | **4,838** | 105 |
| `inspect_room` | 21 | 14,446 | 3,611 | 171 |
| `tbamud__shop` | 1 | 416 | 104 | 104 |

`move` is the biggest single consumer of the model's context, ahead of the
survey tool itself — and every byte of it is a room description that
`inspect_room` then re-derived and re-sent one call later. (`look`, `check`,
`consider` and `examine` also appear in the session log at another ~4,000
tokens, but those run under `inspect_room`'s own dispatcher and never enter the
player's context. They cost latency, not tokens.)

---

## 2. Where the state lives

### 2.1 The file

`mud_monitor/api/config/initializers/mud_monitor.rb:53`:

```ruby
c.knowledge_db = Pathname.new(ENV.fetch("MUD_KNOWLEDGE_DB", boukensha_dir.join("knowledge.sqlite3").to_s))
```

So: **`<boukensha_dir>/knowledge.sqlite3`**, where `boukensha_dir` is resolved
by the `BOUKENSHA_DIR` → `~/.boukensharc` → `~/.boukensha` precedence that the
initializer's comment (lines 6–17) documents at length — because getting that
wrong is exactly what made the telnet/manager pages report "logging is off".
The writer must use the *same* precedence, which it gets for free from
`Config` (`config.rb:125`).

Add to `.gitignore` alongside the ONNX artifact — it is a binary that changes
every run:

```
.boukensha/knowledge.sqlite3
.boukensha/knowledge.sqlite3-wal
.boukensha/knowledge.sqlite3-shm
```

### 2.2 One writer, one reader

boukensha is the **only** writer. mud_monitor is a read-only reader of another
process's file, exactly as it is for `sessions/`, `telnet/` and `manager/`.

- **WAL mode, set at open** (`PRAGMA journal_mode=WAL`), so the monitor's reads
  never block the agent's writes and vice versa. Without it a monitor page
  refresh can hand the agent `SQLITE_BUSY` mid-turn.
- `PRAGMA synchronous=NORMAL` — this is a game journal, not a ledger.
- `PRAGMA foreign_keys=ON`.
- `PRAGMA busy_timeout=5000`.

### 2.3 The Rails side is not finished

`mud_monitor.md:699-709` specifies a second `knowledge:` connection with
`replica: true` and `migrations_paths: []`. The shipped
`api/config/database.yml` is still single-database — no `primary:`/`knowledge:`
split. Health reports `knowledge_attached: cfg.knowledge_db.file?`, which is a
`File.exist?`, not a connection.

That's fine and correctly ordered: the agent should create the file first.
Converting `database.yml` and adding `Knowledge::Room` / `Knowledge::Exit`
models is monitor-side work that follows this plan, not part of it. The one
line that must survive the conversion is `migrations_paths: []` — **Rails must
never migrate the agent's file.**

---

## 3. Schema

Five tables. `inspect_room`'s output shape is the starting point, but it is not
a flat copy: its payload mixes three lifetimes that must not share a row.

| Lifetime | Fields | Where it goes |
|---|---|---|
| **Permanent** (world data, cannot change) | name, description, exit directions & destinations | `rooms`, `room_exits` |
| **Volatile** (true only right now) | which mobs/objects are present, hp/mana/move, events | `player_state` + live parse; `entity_sightings` only as "what has been seen here" |
| **Earned** (what the agent learned) | visit counts, threat outcomes, unexplored frontier | `rooms.visit_count`, `encounters` |

```sql
PRAGMA user_version = 1;

-- Permanent world data, one row per room the agent has stood in.
CREATE TABLE rooms (
  id               INTEGER PRIMARY KEY,
  -- NOT UNIQUE, deliberately. §4: two genuinely different rooms may share a
  -- weak fingerprint, and identity is `id`, never the fingerprint. Making this
  -- UNIQUE is what would make the ambiguity resolver in §4.3 impossible to add
  -- later without a migration that rewrites every foreign key.
  weak_fingerprint   TEXT NOT NULL,        -- name|desc|sorted dirs   (free, from any look)
  strong_fingerprint TEXT,                 -- weak + sorted dir→target names (costs check(exits))
  confidence         TEXT NOT NULL DEFAULT 'confirmed'
                       CHECK (confidence IN ('confirmed','provisional')),
  name             TEXT NOT NULL,
  description      TEXT NOT NULL,
  look_candidates  TEXT,                   -- JSON array, from the ONNX extractor
  first_seen_at    TEXT NOT NULL,
  last_seen_at     TEXT NOT NULL,
  visit_count      INTEGER NOT NULL DEFAULT 1,
  surveyed_at      TEXT                    -- NULL = arrived but exits not yet resolved
);
CREATE INDEX idx_rooms_weak ON rooms(weak_fingerprint);
CREATE INDEX idx_rooms_name ON rooms(name);

-- The map. One row per (room, direction). target_room_id is NULL until the
-- agent has actually stood in the destination — that NULL *is* the frontier.
CREATE TABLE room_exits (
  room_id        INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  direction      TEXT NOT NULL,
  target_name    TEXT,                     -- "By The Temple Altar", from check(exits)
  target_room_id INTEGER REFERENCES rooms(id),
  traversals     INTEGER NOT NULL DEFAULT 0,  -- times actually walked; §4.3 confidence
  last_seen_at   TEXT NOT NULL,
  PRIMARY KEY (room_id, direction)
);
CREATE INDEX idx_exits_frontier ON room_exits(target_room_id) WHERE target_room_id IS NULL;

-- A mob/object TYPE, stored once for the whole world. "A cityguard stands
-- here." is one row no matter how many rooms it patrols — which is also what
-- makes the appraisal reusable: a cityguard met in a new room costs zero
-- consider/examine round trips because this row already answers both.
CREATE TABLE entities (
  id            INTEGER PRIMARY KEY,
  kind          TEXT NOT NULL CHECK (kind IN ('mob','object')),
  descr         TEXT NOT NULL,             -- the MUD's own line, verbatim
  keyword       TEXT,                      -- the keyword the MUD actually answered to
  equipment     TEXT,                      -- JSON array, from examine
  -- consider's verdict is relative to the PLAYER'S level, so it is only
  -- meaningful alongside the level it was measured at. Re-appraise on level-up,
  -- never on revisit.
  threat        TEXT,
  threat_level  INTEGER,
  seen_count    INTEGER NOT NULL DEFAULT 1,
  first_seen_at TEXT NOT NULL,
  last_seen_at  TEXT NOT NULL,
  UNIQUE (kind, descr)
);

-- Where a type has been seen, and how recently. This is the many-to-many the
-- old room_entities table collapsed wrongly.
CREATE TABLE entity_sightings (
  entity_id     INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  room_id       INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  count         INTEGER NOT NULL DEFAULT 1,   -- three fidos in one room
  sighting_count INTEGER NOT NULL DEFAULT 1,  -- times seen here at all
  first_seen_at TEXT NOT NULL,
  last_seen_at  TEXT NOT NULL,
  PRIMARY KEY (entity_id, room_id)
);
CREATE INDEX idx_sightings_room ON entity_sightings(room_id);

-- Exactly one row. The CHECK is the constraint, not a convention.
CREATE TABLE player_state (
  id              INTEGER PRIMARY KEY CHECK (id = 1),
  current_room_id INTEGER REFERENCES rooms(id),
  prev_room_id    INTEGER REFERENCES rooms(id),
  last_direction  TEXT,
  hp INTEGER, max_hp INTEGER,
  mana INTEGER, move INTEGER,
  level INTEGER, gold INTEGER, exp INTEGER,
  position        TEXT,                    -- standing/fighting/resting/sleeping
  session_id      TEXT,                    -- the boukensha session that last wrote
  updated_at      TEXT NOT NULL
);

-- Phase 3. This is the table the system prompt's "Strategy" section is asking
-- for: "if it fights the minotaur at level 3 and loses, it should record that."
CREATE TABLE encounters (
  id            INTEGER PRIMARY KEY,
  room_id       INTEGER REFERENCES rooms(id),
  entity_id     INTEGER REFERENCES entities(id),
  player_level  INTEGER,
  outcome       TEXT CHECK (outcome IN ('won','fled','died','abandoned')),
  hp_before INTEGER, hp_after INTEGER,
  at            TEXT NOT NULL
);
CREATE INDEX idx_encounters_entity ON encounters(entity_id);
```

### 3.1 Why entities are world-level, not room-level

You're right that the first cut duplicated them. `UNIQUE (room_id, kind, descr)`
stores "A cityguard stands here." once *per room* — and a cityguard patrols
most of Midgaard, so the same description, keyword, threat and equipment get
written a dozen times over. Worse, mobs **wander**, so a room-owned entity row
is asserting something that was never true: the mob doesn't belong to the room,
it was merely *in* it when we looked.

Splitting into `entities` + `entity_sightings` fixes the duplication, but the
payoff is bigger than normalisation:

- **The appraisal becomes reusable.** `consider` and `examine` are per *type*,
  not per location. Once `A cityguard stands here.` has a verified keyword and
  a threat reading, meeting a cityguard in a brand-new room costs **zero**
  round trips. Today's `@keywords` hash in `InspectRoom` — session-lifetime,
  lost on exit — becomes a persistent cache, which is what its own comment
  already wished for.
- **A new room full of familiar mobs is cheap.** The survey's cost stops being
  a function of how many mobs are present and becomes a function of how many
  are *unfamiliar*. In Midgaard, after the first hour, that is usually zero.
- **"Where does this thing live?" becomes answerable.** `entity_sightings` is
  the query behind "I need a shopkeeper" or "where did I see the minotaur",
  and it is impossible to ask of a room-owned table without a full scan.

One honesty caveat: **same description ≠ same instance.** Two cityguards are two
mobs, and this schema calls them one type. That is the right trade — instance
identity is not recoverable from the MUD's text at all, and what the agent
actually needs to know ("what is this, can it hurt me") is a property of the
type. Instance-varying state (`health`, and the `count` of how many are here)
stays out of `entities`: `count` is on the sighting, and current health is read
live and never stored.

**Threat is level-relative.** `consider`'s verdict changes as the player levels
— "you could take him" becomes "he'd kill you" or the reverse. Storing a bare
`threat` would let the agent act on a reading taken twenty levels ago, which is
precisely the mistake the system prompt's Strategy section is trying to avoid.
Hence `threat_level`: the reading is only reused while the player's level still
matches, and a level-up invalidates every appraisal at once.

### 3.2 What is deliberately absent

- **No `hp`/`mana`/`move` on `rooms`.** The survey returns them because the
  prompt line rides along with every MUD response. They are player state and
  belong in one place.
- **No `events` table.** Events ("Someone arrives from the north") are true for
  one instant. They belong in the state block for that instant and in the
  session log for the record — never in a store the agent later reads as fact.
- **No `UNIQUE` on any fingerprint** — §4.
- **No world vnum column** — see §12, decision 2.

---

## 4. Room identity is the hard part

Everything above depends on answering "have I been here before?" correctly, and
the MUD does not give the agent a room id. Getting it wrong is worse than
having no memory: a false match silently teaches the agent a wrong map.

You asked whether a room can be recorded with *less* than certainty and pinned
later by movements before and after it. Yes — and designing for that changes one
thing in the schema today and defers all the rest.

### 4.1 Two fingerprints, because they cost different amounts

```
weak   = sha256(name | normalized_description | sorted(exit_dirs))
strong = sha256(weak | sorted("dir→target_name" pairs))
```

The split exists because the inputs have different prices:

- **`weak` is free.** Every `look`, and every movement result, carries the name,
  the prose and `[ Exits: n e s w ]`. Computable on arrival at zero cost.
- **`strong` costs a `check(exits)`** — the call that turns `n e s w` into
  `north - By The Temple Altar`. We already spend it once per new room, so
  `strong` is free *for rooms we surveyed*, and unavailable for a room we have
  only glanced at.

`strong` is dramatically more discriminating, because the destination *names*
of a room's neighbours are exactly what differs between two rooms that look
identical. Two `Dark Alley`s with the same prose and the same n/s exits are
separated the moment you learn one leads to `Market Square` and the other to
`The Slums`.

### 4.2 Identity is `rooms.id`, resolved by content *and* arrival edge

Position is a pair — what the room looks like, and how we got there — and
neither half is reliable alone. Content alone merges mazes; dead-reckoning
alone breaks the first time `flee` or a teleport moves the player without a
`move` call (and `flee` is in the player's allowlist).

Lookup, in order:

1. `SELECT … FROM rooms WHERE weak_fingerprint = ?`
2. **Exactly one hit** → that's the room. The common case, zero extra cost.
3. **One hit, and we arrived via a known edge that names a *different* room** →
   conflict. Log `memory_conflict`, trust the content, decrement the edge's
   `traversals`. A room cannot move; a stale edge can.
4. **Several hits** → ambiguous. Disambiguate in increasing order of cost:
   - **By arrival edge.** If we came from room A heading north and exactly one
     candidate is `A.north.target_room_id`, take it. Free.
   - **By strong fingerprint.** Spend one `check(exits)` and compare against
     the candidates' `strong_fingerprint`. One MUD round trip, and it settles
     almost every real case.
   - **Still ambiguous** → §4.3.
5. **No hit** → a new room. Insert `confirmed`, survey it.

### 4.3 Provisional rooms, and pinning them from the future

When step 4 cannot decide, the honest record is not a guess. Insert the room as
`confidence = 'provisional'` and record the arrival edge normally. The agent
carries on; the state block says `Dark Alley (uncertain — 2 candidates)`, which
is *more* useful to a model than a confident lie.

Later evidence resolves it, and it can come from either direction:

- **From the past:** we later confirm that A's north exit leads to X, so the
  provisional room we entered from A-north *was* X.
- **From the future:** we leave the provisional room heading east and arrive
  somewhere unambiguous; if only one candidate has an east exit whose
  `target_name` matches, the provisional room was that candidate.

Both are the same operation — a constraint arrives, candidates are eliminated,
and when one survives the provisional row is **merged** into it: repoint
`room_exits`, `entity_sightings`, `encounters` and `player_state` at the
survivor, sum the counters, delete the provisional row.

**This is why `rooms.fingerprint` must not be `UNIQUE` and why identity is the
surrogate `id`.** That one schema decision is the entire cost of keeping this
door open. With a UNIQUE fingerprint, two rooms that look alike *cannot* both
exist, provisional rows are unrepresentable, and adding the resolver later means
a migration that rewrites every foreign key in the database.

**Recommendation: build 4.1 and 4.2 now, and stop.** Write `confidence`, write
the non-unique fingerprints, log every ambiguity — and do not write the merge
resolver until the logs show it is needed. Midgaard's explored area may contain
no ambiguous rooms at all; a union-find merge over provisional rooms is real
complexity to carry on a maybe. The instrumentation tells us, and the schema
means the answer stays cheap to act on.

Residual risk, stated plainly: mazes of genuinely identical rooms with identical
neighbour names defeat all of the above, and only true dead-reckoning (turn
counting, wall-following) resolves them. That is a different project.

---

## 5. The hooks

### 5.1 The plan's `before_agent` is one hook too coarse

The sketch in the header says "before it invokes the agent it will check where
it currently is". That's right for the *first* model call of a turn, and wrong
after that: the agent moves inside its own loop — 56 `move` calls against 28
turns' worth of surveys in the recent logs. A room refresh that only fires at
turn start means the model reasons about the room it left.

So the refresh belongs at **`before_model`**, which fires before every
iteration including the first. `before_turn` remains for genuinely
once-per-turn work (a `check(score)` refresh, session bookkeeping).

### 5.2 The seam

A null-object `Hooks` on `Agent`, defaulting to no-op, so every existing
caller and test is unaffected:

```ruby
# lib/boukensha/hooks.rb
module Boukensha
  class Hooks
    def before_turn(context:) = nil
    def before_model(context:) = nil
    # Fires ONCE per tool-use batch, before the first dispatch. §5.5: this is
    # the only moment the model's thinking-gap output is still alive.
    def before_tools(calls:, context:) = nil
    # Returns nil to keep the tool result as-is, or a String to REPLACE what
    # the model sees. §6.2 — this is what lets a 105-token room dump the hook
    # has already parsed reach the model as "moved north."
    def after_tool(name:, args:, result:, context:) = nil
    def after_turn(context:, text:) = nil
  end
end
```

Five call sites in `agent.rb`:

| Where | Line today | Call |
|---|---|---|
| `run`, after `reset_turn_tokens` | `agent.rb:30` | `@hooks.before_turn(context: @context)` |
| `run`, top of loop before `@logger.prompt` | `agent.rb:49` | `@hooks.before_model(context: @context)` |
| `handle_tool_calls`, before the `tool_calls.each` | `agent.rb:172` | `@hooks.before_tools(calls: tool_calls, context: @context)` |
| `handle_tool_calls`, after `@registry.dispatch` | `agent.rb:179` | `result = @hooks.after_tool(…) \|\| result` |
| `run`, before returning text | `agent.rb:68` | `@hooks.after_turn(context: @context, text:)` |

The `after_tool` substitution must land **between** `@logger.tool_result`
(`agent.rb:180`) and `@context.add_message` (`agent.rb:186`): the log keeps the
MUD's exact words, the model gets the stub.

`Repl` passes the same `hooks:` through to each per-turn `Agent` (`repl.rb:125`),
and `Boukensha.run`/`.repl` accept `hooks:` the way they already accept
`logger:`.

That is the entire framework change. Everything else in this plan is a hook
implementation.

### 5.3 `InspectRoom` becomes `RoomParser` — and gets smaller

Agreed: it is not a tool any more, so it should not be named or shaped like one.
The rename is also the moment to make the split the class has been resisting.
`InspectRoom` currently does three jobs, and only one of them is parsing:

| Today, inside `InspectRoom` | Goes to |
|---|---|
| `parse_look`, `parse_exits`, `parse_examine`, `guess_keywords`, `classify`, `colour_of` | **`RoomParser`** — pure, no `call_tool:`, no injection, text in / struct out |
| `survey` — the poll→look→exits→consider/examine sequence | **`RoomSurvey`** — owns the dispatcher and the round trips |
| `@keywords` session cache | **the `entities` table** (§3.1) — persistent, world-level |
| `self.call` → JSON for a tool result | **deleted.** No tool, no JSON payload |

`RoomParser` losing its `call_tool:` constructor arg is the substantive part.
It becomes a pure function of text, which means every test is a string in and a
struct out with no lambda and no transcript fixture. `test_inspect_room.rb`'s
parse tests port over directly; only the survey-sequence tests move to
`RoomSurvey`.

`RoomSurvey` keeps the `Boukensha.tool_dispatcher` seam verbatim, and with it
the `tools.inspect_room.allow` slice — renamed to `tools.room_survey.allow`,
same five entries. `look` stays off the player's allowlist and reachable only
here, which was the whole reason that separate slice exists.

### 5.4 What the MUD hook does

`Boukensha::Mud::Hooks` — wired at the entrypoint where the `inspect_room` tool
is registered today (`boukensha_loader.rb:110-152`), for the same reason it was:
deployment-specific glue, not framework.

**`before_tools`** — fires once per batch, before any dispatch. **One `poll`,
unconditionally.** This is the only moment the model's thinking-gap output is
still in the buffer (§5.5), and `poll` is a non-blocking drain
(`session_pool.rb:92-97`) — one MCP pipe round trip, no MUD wait. Its output
feeds `player_state` (HP, which may have changed a lot), entity arrivals and
departures, and death/level detection.

**`after_tool`** — cheap, synchronous, no MUD I/O:
1. Scrape the prompt line (`20H 100M 82V`) off *any* MUD result — it rides on
   all of them — and update `player_state`. Free HP tracking.
2. If the tool was a movement (`move`, `flee`, `track`), hand the text to
   `RoomParser` and use the weak fingerprint for **identification only**
   (§5.6). Do not build a room record from it.
3. Watch for level/death markers to feed `encounters` (phase 3). A level change
   invalidates every stored `threat` (§3.1).
4. **Return the outcome stub** that replaces the raw text in the model's
   context (§6.2).

**`before_model`** — the reconciliation, and the only place that may spend
blocking MUD round trips:
1. **Establish position.** Three cases:
   - **Cold** (fresh login, new session, `/clear`, reconnect — no movement has
     been observed and `player_state.current_room_id` is a stale hint from a
     previous process): spend a full `look`. There is no shortcut; nothing has
     told us where we are.
   - **Moved, weak fingerprint resolves to exactly one known room:** confirmed.
     Zero further round trips.
   - **Moved, ambiguous or unknown:** §4.2 steps 4–5 — arrival edge first, then
     `check(exits)`, then a full survey.
2. **Identify** per §4.2.
3. **Known room → spend nothing more.** Bump `visit_count`/`last_seen_at`,
   `traversals` on the arrival edge, link `room_exits.target_room_id`. This is
   the case Market Square and Main Street hit.
4. **Unknown room → survey it**, via `RoomSurvey`: `check(kind: exits)`, then
   `consider` + `examine` **only for entity descriptions not already in
   `entities`**. A new room whose mobs are all familiar costs one round trip,
   not three.
5. **Persist**, then **render** the state block (§6) and the turn policy (§7).

So a genuinely new room with a genuinely new mob still costs the survey it costs
today. What memory removes is the repeat — of the room (27% of arrivals in the
sampled session) *and*, separately, of the appraisal.

### 5.5 `move` output is an index key, not a room record

A `move` result looks like a complete `look` — `.boukensha/manager/20260723.jsonl`
seq 9 carries the room name in `CCYEL`, the prose, `[ Exits: n e s w ]`, a
`CCYEL` mob line and the prompt stats. It is tempting to treat it as a free
survey. It is not one, for two independent reasons:

**It has a hole in it.** `SessionPool#run_command` (`session_pool.rb:66-72`):

```ruby
s = ensure_ready(id)
s.drain                          # ← everything buffered since the last command, DISCARDED
sent = s.send_command(command)
[ sent, s.read_until_prompt ]
```

The pre-send `drain` throws away every byte that arrived while the model was
thinking — and thinking is the *longest* interval in the loop (5–7s per
inference, measured in `scripted_room_survey.md` §1). So a room built from move
output is a room as it existed after an unbounded amount of unobserved history.
The mob that walked in during the last inference is in the room and in the
`move` text; the mob that walked *out* has already gone, and the line saying so
was destroyed.

**It does not survive a cold start.** A fresh login, a new session, a `/clear`,
a reconnect after `with_reconnect` — in every one of those there is no
preceding move, and `player_state.current_room_id` is a hint from a previous
process that may be hours stale. The only correct action is a real `look`.

Hence the rule: **fingerprint the move output, match it, and throw it away.**

| Move output used for | Verdict |
|---|---|
| Room name + description + exit dirs → weak fingerprint → DB lookup | ✅ Cheap, safe, and the whole point |
| Confirming `A.north.target_room_id` still holds | ✅ Second signal for §4.2 |
| Detecting an *unexpected* location (teleport, `flee`, aggro drag) | ✅ Exactly what it's good for |
| Building a new room's permanent record | ❌ Survey it properly |
| Writing `entity_sightings` | ❌ Missing the arrivals/departures the drain ate |
| Substituting for `poll` | ❌ §5.6 |

`RoomParser#parse_look` is what runs on move output — pure, no round trips.
`RoomSurvey` only ever runs against a real `look`.

### 5.6 The async window, and where `poll` actually has to go

Across every session log, `tbamud__poll` returned content **7 times out of 33**.
That 79% empty rate is not bad luck, it is placement: `poll` runs as step 1 of
`inspect_room`, which the model calls *after* a `move` — and that move's
`run_command` already drained the buffer. It is structurally called at the one
moment it cannot succeed.

Getting the placement right requires being precise about the loop's timeline:

| # | Event | Buffer state |
|---|---|---|
| 1 | `before_model` | — |
| 2 | `@client.call` — **5–7s of inference** | async MUD output accumulates here |
| 3 | response with `tool_use` | still alive |
| 4 | `@registry.dispatch` → `run_command` → `s.drain` | **destroyed** |
| 5 | `after_tool` | gone |

The window that matters is #2, and it dies at #4. So a `poll` at `before_model`
(#1) fires *before* the gap it is supposed to catch and recovers only the
milliseconds of tool-execution time — which is exactly the mistake the current
code makes, one level up. **The only correct placement is between #3 and #4**:
the top of `handle_tool_calls`, before the first dispatch. That is why §5.2 adds
`before_tools` rather than folding the poll into `before_model`.

The 7 non-empty polls are what this is protecting:

```
20260718T165716Z-2f8f712f:
  "You're stunned, but will probably regain consciousness again.
   0H 100M 84V >
   The newbie monster pierces you.
   You are mortally wounded, and will die soon, if not aided.
   -6H 100M 84V >"

20260722T162128Z-3fa54020:
  "The janitor has arrived.
   The cityguard leaves east."

20260722T162321Z-a6188b70:
  "The Mayor has arrived."
```

Two categories, both fatal to a memory design that skips polling:

- **Combat the agent never issued a command for**, carrying the player from
  20H to −6H. Had the agent sent a `move` at that moment instead of a `poll`,
  the pre-send drain would have destroyed the text. It would not appear in the
  session log, in the context, or anywhere else — the agent would simply have
  died with no record of why.
- **Mob arrivals and departures.** `The cityguard leaves east` is precisely the
  update that keeps `entity_sightings` from being a lie, and the reason the
  state block's `here:` line is rendered from the live parse plus poll rather
  than from the DB. Trusting move output alone means reporting a cityguard that
  left.

**So: no, `poll` does not go away — it gets more important, and it moves.** It
leaves `RoomParser` entirely (which is pure and does no I/O), leaves the survey
sequence (where it was structurally useless), and becomes an unconditional
per-batch step in `before_tools`. It is no longer "step 1 of surveying a room";
it is "catch what happened while the model was thinking", which is a concern
that has nothing to do with rooms and must run whether or not we moved.

**Corollary — the mud_manager fix that makes the hook unnecessary.**
`run_command`'s discarded drain *is* the async window, thrown away rather than
returned. Returning it alongside the response (`{ pending:, received: }`) gives
every command the poll-for-free that `move` was wrongly assumed to have, at zero
extra round trips and with no hook-ordering subtlety to get wrong. That is a
~5-line change in `session_pool.rb` plus the dispatcher's result shape. The
`before_tools` poll is the version that needs no MCP change and can ship now;
this is the version that fixes the leak at its source, and it should follow.

---

## 6. What the model is shown

### 6.1 The state block, not a tool result

The header asks to "inject the least amount of context the agent needs". The
mechanism matters more than the wording:

- A **tool result** is `@context.add_message(:tool_result, …)` — permanent,
  re-sent every call, cleared only by compaction, and duplicated on revisit.
- A **state block** is one string on the `Context`, re-rendered by
  `PromptBuilder` at the tail of the request. Never in `@messages`, never
  duplicated, never stale, never compacted away.

`Context` gains `attr_accessor :state_block`; `PromptBuilder` appends it as the
final user-role content of the request. Because it lands at the *tail*, it sits
after any prompt-cache breakpoint on the system+tools+history prefix, so a
per-iteration rewrite costs nothing in cache terms.

Rendered form — the room record is *not* what gets sent:

```
[here] Market Square  (visit 2)
exits: n→The Temple Square ✓ | e→Main Street ✓ | s→The Common Square ✓ | w→Main Street ?
here: a cityguard (mob — "you could take him")
you: 20/20hp 100mana 81mv · lvl 1 · 43 gold · standing
```

Rules that make it small and honest:

- **`description` is sent on the first visit only.** It's static, it's the
  largest field, and the agent has already read it. Revisits get the name.
- **`✓`/`?` marks whether the destination has been stood in.** This one glyph
  is the exploration frontier, and it is information the agent has never had —
  today it cannot distinguish "east, which I've mapped" from "east, unknown".
- **The `here:` line comes from the *live* parse plus the latest poll, never
  from `entity_sightings`.** The DB contributes only the remembered `threat`
  (and only while `threat_level` still matches the player's level, §3.1).
  Rendering presence from stored sightings would report the cityguard that
  `The cityguard leaves east` just removed — the single worst failure mode this
  design can have.
- **Uncertain rooms say so.** A `provisional` room (§4.3) renders as
  `Dark Alley (uncertain — 2 candidates)`. A model told the location is
  ambiguous can act sensibly; a model told a confident lie cannot.
- **`events` are inlined only when non-empty**, and only for the iteration they
  occurred in.
- **`look_candidates` are dropped from the block** and surfaced only in a room
  the agent has not yet examined.

Measured: the sampled `inspect_room` payload is 921 chars ≈ **230 tokens**,
permanent. The block above is ~180 chars ≈ **45 tokens**, transient, one copy.
On the 11-survey session that is ~1,740 accumulated tokens → ~45, and it stops
growing with the length of the exploration.

### 6.2 Movement results are replaced, not forwarded

Once the hook parses move output, forwarding the raw text to the model is pure
waste — and it is the largest single waste in the context: **46 results, 19,352
chars ≈ 4,838 tokens** over six sessions, every one of them a room description
that `inspect_room` re-derived and re-sent one call later (§1, Waste #3).

`after_tool` returns a replacement string; `Agent#handle_tool_calls` uses it for
`@context.add_message(:tool_result, …)` **only**. `@logger.tool_result` still
records the full text — the session log and mud_monitor must keep seeing exactly
what the MUD said, or the monitor stops being a faithful record. The model sees:

```
moved north → Market Square
```

and the state block (§6.1) carries everything else, already reconciled against
the DB. ~105 tokens → ~8, and it stops accumulating.

**Failures pass through unchanged.** This is the part that must not be clever.
The model has to know why it didn't move, or it will retry forever:

| MUD said | Model sees |
|---|---|
| A room name + prose + `[ Exits: ]` (the success shape) | `moved north → Market Square` |
| `Alas, you cannot go that way.` | verbatim |
| `The door is closed.` | verbatim |
| `You are too exhausted.` | verbatim |
| Anything the parser did not confidently recognise | verbatim |

The rule is a **whitelist on success, not a blacklist on failure**: substitute
only when `parse_look` yielded a room name *and* an exits line *and* a prompt
line. Anything else — including text the parser has never seen — reaches the
model untouched. A missed substitution costs 100 tokens; a wrongly swallowed
failure costs a stuck agent.

The same treatment applies to any other player-allowlist tool whose output the
hook fully consumes. Today that is only the movement family; `shop`, `check`,
`say` and the rest are read by the model and must stay verbatim.

---

## 7. Computing allowed tools

No new machinery. `Permissions` already parses value-pinned rules
(`permissions.rb:10-27`) and already validates them against each tool's
declared enum at startup. The turn policy is the same grammar, computed:

```ruby
# Market Square, exits n/e/s/w, cityguard present, not in combat
["tbamud__move(direction: north|east|south|west)"]
```

Wiring: `before_model` sets `context.turn_policy = Permissions.from(rules)`;
`Context#advertised_tools` filters what `PromptBuilder` renders, and `Registry#dispatch`
consults it alongside the task permissions. The policy may only ever
**narrow** — a tool must be permitted by *both* the task's `allow:` block and
the turn policy. It can never grant something `settings.yaml` didn't.

What it buys, in order of confidence:

| Restriction | Signal | Confidence |
|---|---|---|
| `move` pinned to the exits line's directions | The MUD printed them | High — use it |
| Deny `shop`/`practice` outside the relevant room | Requires knowing which rooms those are | Medium — after a few sessions of data |
| Deny non-combat tools while `position = fighting` | The prompt line and combat text | High, but needs a reliable fighting detector first |

Start with the first row only. It removes a whole class of wasted turns ("You
cannot go that way") and cannot be wrong, because the constraint came from the
MUD in the same breath as the room.

The failure mode to respect: **hidden and closed exits.** tbaMUD's `[ Exits: ]`
line omits closed doors. Pinning `move` to that line makes `open door; east`
unreachable. Mitigation: never pin away a direction that `room_exits` has a
remembered `target_name` for, and keep the pin advisory-off (`memory.turn_policy:
false` in settings) until it has been watched for a session.

---

## 8. What happens to `inspect_room`

It stops being a tool, as the header asks, and its parts are redistributed:

| Today | After |
|---|---|
| `inspect_room` in `tasks.player.allow` (`settings.yaml`) | **removed** — the player has no room tool |
| `tools.inspect_room.allow` slice (poll/look/check/consider/examine) | **kept, renamed** `tools.room_survey.allow`, same five entries; `look` stays off the player and reachable only here |
| `RunDSL#tool "inspect_room"` in the loader | **removed**; the loader registers `Mud::Hooks` instead |
| `Tools::InspectRoom` — the parsing half | → **`Mud::RoomParser`**, now pure: no `call_tool:`, no injection, no JSON |
| `Tools::InspectRoom` — the sequencing half | → **`Mud::RoomSurvey`**, owns the dispatcher and the round trips |
| `@keywords` session cache | → the **`entities` table** (§3.1), persistent and world-level |
| The JSON payload and `self.call` | **deleted** — replaced by the state block (§6) |
| `Boukensha.tool_dispatcher(…)` | **kept verbatim** — `RoomSurvey` needs exactly the permission-scoped, logger-bracketed dispatcher it already provides |

The `parent.task(name) { … }` bracketing stays, moved into `RoomSurvey`, so
mud_monitor keeps showing one collapsed group per newly-discovered room with its
MUD calls nested at depth 1 (relabelled `room_survey`). Known rooms produce no
group at all, which is the visible signal that memory is working.

The player's system prompt (`.boukensha/prompts/player/system.md`) loses its
"# Exploring / use the inspect_room tool" section and gains a short note that
its current location is always given to it — one of the few places where
removing a paragraph is the entire change.

---

## 9. Code layout and migrations

The rename is also the chance to fix a standing smell: boukensha's own
documentation insists it is a MUD-agnostic MCP host that "ships no tools of its
own" (`boukensha.rb:40-46`), while `lib/boukensha/tools/inspect_room.rb` knows
about fidos and cityguards. Rather than spread that further, everything
MUD-specific moves under one explicitly-named namespace:

```
boukensha/lib/boukensha/
  hooks.rb                    # FRAMEWORK: null object + the 5 call sites' contract
  mud/                        # everything that knows what a MUD is
    room_parser.rb            # pure text → struct (was Tools::InspectRoom)
    room_survey.rb            # the look/exits/consider/examine round trips
    hooks.rb                  # §5.4 — the Hooks subclass wired at the entrypoint
    state_block.rb            # §6 rendering
    memory/
      store.rb                # sqlite3 open/pragmas/upsert; the ONLY writer
      schema.rb               # versioned DDL, applied on PRAGMA user_version
      fingerprint.rb          # §4.1 weak + strong
      resolver.rb             # §4.3 — provisional/merge. Deferred; file may not exist yet
```

`lib/boukensha/tools/inspect_room.rb` is deleted, not moved, so the framework's
`tools/` directory holds only `mcp.rb` — which is what its own comments have
claimed all along.

- **Migrations are `PRAGMA user_version`, not ActiveRecord.** `Store.open`
  reads it, applies each numbered DDL step above it in one transaction, writes
  the new version. Twenty lines, no dependency, and it cannot collide with the
  Rails migration table because there isn't one.
- **`sqlite3` becomes a gemspec dependency**, `require`d lazily inside
  `Store` so a checkout without it still boots — the same posture
  `onnxruntime` already has (`boukensha.rb:422`).
- **`Store` is the only writer**, and it takes the path from `Config`, so the
  writer and mud_monitor resolve `boukensha_dir` identically by construction.

Testing gets easier than the `InspectRoom` precedent, not just as easy:
`RoomParser` is pure, so its tests are a string in and a struct out with no
lambda at all. `RoomSurvey` and `Mud::Hooks` keep the injected `call_tool`
seam and run against transcript fixtures lifted from the real manager logs;
`Store.open(":memory:")` covers the rest. No MUD, no MCP, no network.

---

## 10. Cost model

Per room arrival, after this lands. `poll` is counted but is a non-blocking
buffer drain (`session_pool.rb:92-97`) — one MCP pipe round trip, no MUD wait:

| | MUD round trips | LLM calls | Tokens into context |
|---|---|---|---|
| **Today**, any room | 5 (poll, look, exits, consider, examine) | 0 | ~230 survey + ~105 move = **335, permanent** |
| **After**, known room | **1** (poll) | 0 | ~8 stub, + ~45 transient block |
| **After**, new room, **familiar** mobs | 3 (poll, look, exits) | 0 | ~8 stub, + ~120 transient (first visit) |
| **After**, new room, 1 **unfamiliar** mob | 5 (poll, look, exits, consider, examine) | 0 | ~8 stub, + ~140 transient |

Two rows are worth reading carefully:

- The worst case is **unchanged from today**, deliberately. §5.5 gives up the
  apparent shortcut of surveying from move output, because it buys ~2 round
  trips at the cost of a room record with the async window missing from it.
- The **familiar-mobs** row is what §3.1's entity split buys, and it is the
  common case after the first hour: cityguards, fidos and janitors are the same
  three descriptions everywhere in Midgaard, and once appraised they never cost
  a `consider`/`examine` again.

Applied to session `0d023f2a` (11 arrivals, 8 distinct rooms, ~1 mob/room):

| | Today | After |
|---|---|---|
| MUD round trips | 55 | ~43 |
| Tokens accumulated in context | 1,740 (survey) + ~1,150 (move) ≈ **2,890** | ~88 (stubs) |
| Largest transient block | — | ~45 |

The round-trip saving is modest and grows with revisit rate. The **token**
saving is the real one, and it is structural rather than proportional: today's
number grows with every arrival and is re-sent on every subsequent API call;
after, it does not grow at all.

---

## 11. Failure modes worth designing for now

- **Stale `current_room` across sessions.** The DB survives process exit; the
  MUD character may have been moved or logged out elsewhere. `player_state`
  records `session_id`; on a new session, `current_room_id` is treated as a
  *hint* and re-confirmed by the turn-start `poll`+`look`, never trusted.
- **The agent is dead / in the void.** Room `0` ("The Void") fingerprints like
  any other room and would be recorded as an explored location. Detect the
  death text and record an `encounters` row instead of a map edge.
- **Colour toggle off.** `RoomParser#classify` already warns and buckets
  everything as mobs. With memory, that wrong guess now *persists* — and worse,
  a mis-kinded row in the world-level `entities` table is wrong everywhere at
  once, not just in one room. `Store` should refuse to write entities or
  sightings when the parse reported uncoloured
  lines — degrade to a room with no entity record rather than a wrong one.
- **Conflicting fingerprints on a known edge.** §4 — log it, trust the fresh
  read, and surface the count so the identity scheme can be judged on evidence.
- **A corrupt/locked DB must not kill the turn.** Every hook body wraps in a
  rescue that logs and returns; an agent with broken memory degrades to today's
  behaviour, not to a dead REPL.
- **A swallowed movement failure.** §6.2's substitution is the one place this
  design can make the agent *stupider*. Whitelist the success shape; anything
  unrecognised passes through verbatim. Worth an explicit test per known failure
  string (`cannot go that way`, `door is closed`, `too exhausted`).
- **The hook's own MUD calls must not recurse.** `before_model` dispatches
  through `Boukensha.tool_dispatcher` (a separate `Registry`), not through the
  player's registry, so its `poll`/`look` never re-enter `after_tool`. This is
  already how `inspect_room` works; keep it that way.

---

## 12. Decisions for you

> **Resolved.** All four were answered as recommended and are built that way.
> The decisions that are still genuinely open are in **§16**, and they are
> different questions — they only became askable once this existed.

**1. How far into room identity do we build now?** Recommend **§4.1 + §4.2 and
stop**: two fingerprints, resolution by content *and* arrival edge, `confidence`
and a non-unique fingerprint in the schema, and a logged `memory_conflict` every
time it can't decide. Defer the §4.3 merge resolver until the logs prove
Midgaard's explored area actually contains ambiguous rooms — a union-find merge
over provisional rooms is real complexity to carry on a maybe. The one thing
that must land now is the **non-unique fingerprint**, because that is what keeps
the door open for free.

**2. Do we resolve world vnums into the agent's DB?** We have
`week0_explore/preview/data/world/wld/*.json` with real ids, names,
descriptions and linked rooms — a fingerprint→vnum table is easy to build.
**Recommend no.** The point of the exercise is knowledge the agent *earned*;
joining against the world files would hand it a complete map on visit one, and
mud_monitor's "rooms known vs rooms that exist" diff (`mud_monitor.md:752-756`)
— the actual measure of exploration — becomes vacuous. The monitor can do that
join itself at read time, where it belongs.

**3. Does anything replace `inspect_room` on the tool surface?** Recommend
nothing at first: state is pushed, the tool surface shrinks by one, and we find
out from the logs whether the agent ever asks for detail it wasn't given. If it
does, add a narrow `recall(room:)` returning a remembered room's prose and
sighting history — but add it because a transcript demanded it, not in
anticipation.

**4. Does `Mud::` live in boukensha at all?** The namespace in §9 makes the
MUD-specific code honest about itself, but it is still inside a gem whose own
docs say it ships no tools and knows nothing about MUDs. The alternative is a
separate `boukensha-mud` gem that registers hooks through the public seam —
which is the *right* boundary and a bigger change than this plan. Recommend the
`Mud::` namespace now (it makes the eventual extraction a directory move) and
revisit when something other than a MUD wants hooks.

---

## 13. Build order

0. **Rename `Tools::InspectRoom` → `Mud::RoomParser` + `Mud::RoomSurvey`**,
   dropping `call_tool:` from the parser. Pure refactor, tool still registered,
   behaviour identical, `test_inspect_room.rb` splits along the same seam. Doing
   this first means every later step is written against the shape we want.
1. **`Store` + schema + fingerprints**, tested in-memory. Creates
   `knowledge.sqlite3`; `/api/v1/health` flips `knowledge_attached` to `true`
   with no agent changes at all. First visible win.
2. **`Hooks` null object + the five `Agent` call sites**, including the
   `after_tool` return-value substitution seam. Framework change, zero
   behaviour change, existing tests must pass untouched.
3. **`Mud::Hooks#before_tools`** — the `poll`, in the one position where it
   works (§5.6). Feeds `player_state` and event detection. Measurable on its
   own: the non-empty poll rate should jump off 21%.
4. **`Mud::Hooks#after_tool`** — player state scraped off the prompt line,
   movement fingerprinted for identification. Still no behaviour change; the DB
   starts filling and the monitor can show it.
5. **`Mud::Hooks#before_model`** — cold/moved/ambiguous position handling,
   identify, known-room path, `entities` reuse. Room memory is live.
   `inspect_room` still exists and now no-ops on revisit.
6. **Move-result substitution** (§6.2), with a test per known failure string
   before the success path is allowed to substitute anything. Biggest single
   token win, and the one most able to make the agent worse if rushed.
7. **State block**, and drop `inspect_room` from `tasks.player.allow` and from
   the loader. The tool surface shrinks by one.
8. **Turn policy** — `move` direction pinning only, behind a settings flag,
   default off for one session of observation.
9. **`encounters`** and the "I lost to the minotaur at level 3" recall the
   system prompt's Strategy section is already asking for.

Deferred by design, built only if the logs demand it: the **§4.3 merge
resolver** for provisional rooms.

Independent of all of the above, and the right long-term fix for §5.6:
**capture `run_command`'s discarded drain** so every command carries its async
window instead of destroying it. ~5 lines in `session_pool.rb` plus the
dispatcher's result shape; it makes step 3's explicit `poll` unnecessary. It
changes an MCP tool's result shape, so it wants its own change window.

Steps 0–4 are additive and independently shippable; the first behaviour change
the player sees is step 5.

---

# Part II — after the build

Written after steps 0–9 landed. §§1–13 above are unedited: where the build
disagreed with them, the disagreement is recorded here rather than backfilled
into the plan, because a plan that was silently corrected to match its outcome
teaches nothing.

---

## 14. What shipped

### 14.1 The framework change, in full

`lib/boukensha/hooks.rb` — 52 lines, a null object with five methods — plus
five call sites in `agent.rb`. That is the entire change to boukensha proper.
Everything else is a subclass of it living under `mud/`, which is what keeps
the gem's claim to be a MUD-agnostic MCP host honest.

| File | Lines | What |
|---|---|---|
| `lib/boukensha/hooks.rb` | 52 | the seam + the ordering contract |
| `lib/boukensha/mud/hooks.rb` | 588 | the three bodies, identity resolution, encounters |
| `lib/boukensha/mud/room_parser.rb` | 237 | pure; text in, struct out |
| `lib/boukensha/mud/room_survey.rb` | 192 | the round trips |
| `lib/boukensha/mud/state_block.rb` | 129 | §6.1 rendering |
| `lib/boukensha/mud/memory/store.rb` | 315 | the only writer |
| `lib/boukensha/mud/memory/schema.rb` | 168 | versioned DDL |
| `lib/boukensha/mud/memory/fingerprint.rb` | 56 | §4.1 |

`lib/boukensha/tools/inspect_room.rb` is **deleted**, not moved, so `tools/`
holds only `mcp.rb` — as its own comments have claimed all along.

Beyond the plan's own list, three framework touches were needed and were not
foreseen:

- **`Context#request_messages`** — the state block cannot be a message
  (§6.1) but must reach the wire. `@messages` stays the pure transcript, and
  `request_messages` appends the block on read, so compaction, `/clear` and the
  turn counter all keep meaning what they meant. All five backends and
  `PromptBuilder` were repointed at it (and at `advertised_tools`).
- **`RunDSL#hooks`** — the plan has hooks passed to `.run`/`.repl`, but a MUD
  hook needs `logger` to exist first, and the logger is built *after* those
  arguments are bound. A DSL setter read back after the block solves it; an
  explicit `hooks:` argument still wins.
- **`Registry#dispatch` consults `context.turn_policy`** in addition to the
  task's permissions, so §7's "may only ever narrow" is enforced structurally
  rather than by the hook remembering to be careful.

### 14.2 Measured, on a scripted six-arrival walk

Three distinct rooms, six arrivals, one mob per room, one mob type shared
between two of them — the shape of session `0d023f2a`, run against the real
code with a scripted MUD:

| # | Room | Trips | Calls |
|---|---|---|---|
| 1 | Market Square | 4 | look, check, consider, examine |
| 2 | Main Street (new, **familiar** mob) | 3 | poll, look, check |
| 3 | Market Square (revisit) | **1** | poll |
| 4 | The Common Square (new, unfamiliar mob) | 5 | poll, look, check, consider, examine |
| 5 | Market Square (revisit) | **1** | poll |
| 6 | Main Street (revisit) | **1** | poll |

Row for row against §10's predicted table, including the familiar-mobs row the
world-level `entities` split exists to produce. Context, same walk:

| | Before | After |
|---|---|---|
| survey payloads | 6 × 415 chars, **permanent** | — |
| raw move results | 938 chars, **permanent** | — |
| move stubs | — | 132 chars, accumulating |
| state block | — | 166 chars, **transient, one copy** |

The round-trip saving is modest and grows with revisit rate, exactly as §10
predicted. The token saving is structural: the "after" column stops growing.

---

## 15. Where the plan was wrong

Three places. Two were caught only by running the thing.

### 15.1 A cold start paid for two `look`s

§5.5's rule — *fingerprint the movement output, match it, throw it away* — is
right, and §13 step 5 applies it to the cold-start path too. That is one
`look` too many. The reason movement text is untrustworthy is the pre-send
drain in `run_command`: it discards everything that arrived while the model was
thinking, so the room may have lost a mob whose departure line was destroyed. A
**cold `look` has no such hole** — we issued it ourselves, a moment earlier,
with nothing in between.

So `RoomSurvey#survey` gained a `look:` parameter and the hook passes the cold
look straight through. Row 1 above is 4 trips, not 5. Movement text is still
never passed, and the parameter carries the only comment in the file that
matters: it is the one place §5.5 can be got wrong.

### 15.2 The frontier glyph could point at a room the agent had never entered

Not in the plan at all. `check(exits)` names a destination; walking that
direction can land somewhere else — because the name was stale, because the
parse was wrong, or because tbaMUD said `south - Too dark to tell.`, which is
not a room name. The edge would then be linked to the room we actually reached
while still *displaying* the name we were told, so the state block rendered
`w→The Grocer ✓` for a room the agent had never stood in. A `✓` that lies is
strictly worse than the `?` it replaced.

Now the room wins — it cannot move, and the exits table can be stale — the
stored `target_name` is corrected to where we actually arrived, and an
`exit_name_mismatch` conflict is logged. As a side effect `Too dark to tell.`
resolves itself into a real name the first time the agent walks it.

### 15.3 `before_agent` was one hook too coarse — and `before_turn` was one too few

§5.1 got this right in principle. In practice a fourth position turned out to
be load-bearing: `open_fight` has to run **before** the response text is
absorbed, because a swing that gets the player killed must have opened the
encounter that the death then closes. Otherwise the fatal fight is filed
against nobody, which is precisely the row the Strategy section wants to read
later. Ordering inside `after_tool` is now: open fight → absorb text (which may
close it as `died`) → score → settle → substitute.

---

## 16. Decisions for you

### 16.1 Verify `parse_score` against the live MUD — do this first

**`check(score)` output has never been observed in this deployment.** Grepping
every `.boukensha/manager/*.jsonl` and `.boukensha/telnet/*.jsonl` for
`ranks you as`, `gold coins`, `movement points` and `scored` returns nothing —
the agent has never called it. So `RoomParser.parse_score`'s four regexes are
written from tbaMUD's `do_score` as understood, **not verified against the
server you are running**.

Why this is the top item rather than a footnote: it **fails open, and silently**.

```
threat_fresh = !threat.nil? && threat_level == level
```

If the level regex never matches, `level` stays `nil`, so `threat_level` is
written `nil`, so `nil == nil` is **true** and every appraisal is considered
fresh forever. The level-up invalidation in §3.1 — the whole reason `threat` is
stored with a level at all — quietly never fires, and nothing in the logs says
so. The agent would act on a `consider` reading from twenty levels ago, which
is the exact mistake §3.1 exists to prevent.

One `check(score)` against the running server settles it. If the wording
differs, the fix is four regexes in one method; the four fields are matched
independently on purpose, so a mismatch costs only the field that missed.

**Decision: run it and paste the output, or tell me to add a
`fail-closed` mode where an unreadable level makes every threat stale rather
than every threat fresh.** The second is the safer default and I would take it
regardless of what the first says.

### 16.2 Ratify or revert `check(kind: score)` in the survey slice

§8 says `tools.room_survey.allow` keeps the "same five entries". It now has six:
`poll`, `look`, `check(kind: exits|score)`, `consider`, `examine`.

The argument for: `threat_level` is meaningless without a level reading, and
§5.1 already assigns "a `check(score)` refresh" to `before_turn`. It costs one
call per session. The argument against: it widens a slice whose entire purpose
is to be narrow, and the model can already call `check(score)` itself — the
hook scrapes the level for free when it does (`after_tool`).

**Decision: keep it, or drop it and depend on the model happening to check its
own score.** I kept it, on the grounds that a correctness property should not
depend on the model's habits. Reverting is a one-line settings change plus
deleting `before_turn`'s body.

### 16.3 When to turn on `memory.turn_policy`

Default `false`, per §7. The constraint cannot be wrong — the directions came
from the MUD in the same breath as the room — but tbaMUD omits **closed doors**
from `[ Exits: ]`, so a naive pin makes `open door; east` unreachable. The
mitigation is in: any direction `room_exits` has ever learned a `target_name`
for is added back, so a door walked once stays reachable on a visit where it is
shut. That mitigation has not been observed against a real closed door, because
nothing in the current logs has ever met one.

**Decision: how long do you want it watched before flipping it on?** My
suggestion is one exploring session with the flag off, then check whether any
room recorded fewer exit directions than it has `room_exits` rows — that
difference *is* the closed-door population, and if it is zero the flag is free.

### 16.4 How much conflict evidence before building the §4.3 merge resolver

Three conflict kinds now log through the session file as `memory_conflict`:

| kind | means |
|---|---|
| `ambiguous_room` | two+ rooms share a weak fingerprint and neither the arrival edge nor the strong fingerprint could separate them — **this is the one that justifies §4.3** |
| `stale_edge` | we walked a known edge and landed somewhere other than where it pointed |
| `exit_name_mismatch` | §15.2 |

Provisional rooms are written, the fingerprint columns are non-UNIQUE, and
identity is the surrogate `id` — so the door §4.3 needs is open and cost
nothing. The resolver itself is not built, per §12 decision 1.

**Decision: what count of `ambiguous_room` over how many sessions makes you
want it?** Mine would be: build it the first time a single session logs more
than two, and never otherwise. A union-find merge over provisional rooms is
real complexity to carry on a maybe, and Midgaard's explored area may contain
no ambiguous rooms at all.

### 16.5 Schedule the two follow-ons the plan explicitly deferred

Both are unblocked now and neither is started:

- **mud_monitor's side (§2.3).** `knowledge.sqlite3` now exists, so
  `/api/v1/health` reports `knowledge_attached: true` with no monitor change —
  verified. What is *not* done is the `database.yml` multi-db split and the
  `Knowledge::Room` / `Knowledge::Exit` models. The one line that must survive
  that conversion is `migrations_paths: []`: **Rails must never migrate the
  agent's file.** The "rooms known vs rooms that exist" diff against the world
  files (§12 decision 2) belongs on that side, at read time.
- **Capturing `run_command`'s discarded drain (§13, last item).** ~5 lines in
  `session_pool.rb` plus the dispatcher's result shape. It gives every command
  its async window for free and makes `before_tools`' explicit `poll`
  unnecessary. It changes an MCP tool's result shape, so §13 asks for its own
  change window.

**Decision: which of these do you want next, and do they go in this branch or
their own?**

### 16.6 Two small things I did not fix, because they are not this plan's

- **`Config#dig` cannot return `false`.** `dig(:memory, :turn_policy)` on
  `turn_policy: false` returns `nil`, because the implementation is
  `node[k.to_s] || node[k.to_sym]`. The loader compares `== true`, so the flag
  behaves correctly in both positions today — but the next boolean setting whose
  default is *on* will silently be off. Pre-existing; a one-line fix
  (`node.key?` instead of `||`) touching every settings reader.
- **14 pre-existing test skips.** `test/helper.rb`'s `MUD_MANAGER_ROOT`
  resolves one directory too high (`../../../../week0_explore/mud_manager` from
  `week2_capable/boukensha/test/`), so every test needing a real MCP server
  skips. Unrelated to this work, but it means `test_tools_mcp.rb` and
  `test_mcp_client.rb` have been asserting nothing for a while.

---

## 17. What is deliberately still not built

Five things are missing on purpose. Each one below is written to stand on its
own — what it is, why it is not there, and what would change your mind — so
nobody has to go back up and re-derive the argument.

### 17.1 Merging duplicate rooms

**What it is.** Two rooms can look identical to the agent — same name, same
prose, same exits. When that happens and nothing can separate them, the agent
records the room as `provisional` and the state block says
`Dark Alley (uncertain — 2 candidates)`. What is missing is the step that goes
back *later* and decides which one it actually was, then folds the duplicate
row into the survivor.

**Why it isn't built.** It might never be needed. Midgaard's explored area may
contain no ambiguous rooms at all, and a merge routine that repoints every exit,
sighting and encounter from one room to another is real, fiddly complexity to
carry on a maybe.

**What it costs to keep waiting: nothing.** This is the important part. The
schema was built so the door stays open for free — the fingerprint columns are
deliberately *not* UNIQUE, and a room's identity is its `id` rather than its
fingerprint. Had those gone the other way, adding this later would mean a
migration that rewrites every foreign key in the database. As it is, adding it
later is purely additive.

**What would change my mind.** The agent already logs `ambiguous_room` every
time it cannot decide. If a single session logs more than two, build it. If
sessions keep coming back with zero, this section can eventually be deleted
rather than implemented.

[Note] 
The most clear example of ambigous rooms is the sewers when you navigate south of the dump
Explore the world data and determine if we still don't need to implement this.

### 17.2 Reading the map out of the world files

**What it is.** `week0_explore/preview/data/world/wld/*.json` contains the real
game: every room's id, name, description and exits. It would be easy to match
what the agent sees against that file and hand it a complete, correct map.

**Why it isn't built.** It would defeat the purpose. The whole exercise is an
agent that learns the world by walking it — and the measure of whether that is
working is the diff between "rooms the agent knows" and "rooms that exist". Join
the two together and that number is 100% on the first visit, permanently, and
tells you nothing ever again.

**Where it does belong.** mud_monitor, at read time. The monitor can join
against the world files to *show* you the diff without the agent ever seeing it.
That is the honest place for a ground truth: the scoreboard, not the player.

**What would change my mind.** Nothing about exploration. If you later want the
agent to *navigate* to a named destination it has never visited, that is a
different feature with a different answer, and it should be argued on its own.

[Note] We made it clear, the agent of the game can never look at raw code and game data
because its a player.

### 17.3 A tool for asking about a room again

**What it is.** The agent no longer has any tool for room information — the
state block is pushed to it before every turn. If it ever needs detail it wasn't
given (the full prose of a room three moves back, say, or where it last saw a
shopkeeper), it currently has no way to ask.

**Why it isn't built.** Because nobody knows yet whether it will want to. The
tool surface just shrank by one, which is the win; adding a replacement in
anticipation would quietly undo it. The state block was designed to carry what
the agent actually uses, and that guess should be tested rather than hedged.

**What would change my mind.** A transcript. If the session logs show the agent
asking for something it wasn't given — describing a room it can't see, or
guessing at where a shop was — then add a narrow `recall(room:)` that returns a
remembered room's prose and what has been seen there. Add it because a
transcript demanded it, not before.

[Note] the agent doesn't need to look ath te room, we store it in memory
already, the only thing that is going to change is who is in the room.

### 17.4 Telling two identical mobs apart

**What it is.** If two cityguards are standing in the same room, the agent
records one entity type with a count of 2, not two individuals. Everything it
knows — the keyword, the threat reading, the equipment — is stored against
"A cityguard stands here." as a *kind of thing*, not against either mob.

**Why it isn't built.** It cannot be. The MUD's text gives no handle on
individual instances; two cityguards are literally the same string. Any attempt
would be inventing an identity the game never exposed.

**Why it doesn't matter much.** What the agent needs to know — *what is this,
and can it hurt me* — is a property of the type, and storing it once per type is
exactly what makes a familiar mob in a brand-new room cost zero round trips. The
things that genuinely do vary per individual are handled elsewhere: how many are
here lives on the sighting, and current health is read live every time and never
stored, so the agent is never told a wounded mob is in "excellent condition"
because a healthy one was once.

**The honest cost.** If the agent fights one of three fidos, the encounter is
recorded against fidos in general. That is the right generalisation nearly
always, and there is no version of this that is both truthful and finer-grained.

### 17.5 Mazes

**What it is.** A stretch of rooms built to be indistinguishable — same name,
same description, same exits, *and* the same neighbouring room names. Classic
MUD area design.

**Why it isn't built.** Nothing in this design can solve it. Identity here rests
on what a room looks like and which edge you arrived by; a maze is specifically
constructed so neither one distinguishes anything. The agent will notice — it
logs `ambiguous_room` and tells the model the location is uncertain, which is
the correct behaviour and better than a confident lie — but it will not resolve
it.

**What it would actually take.** True dead reckoning: counting turns, tracking
orientation, wall-following, maintaining a positional belief independent of what
the rooms say about themselves. That is a navigation project, not a memory one,
and it should not be smuggled in as an extension of this.

**Practical advice in the meantime.** If the agent wanders into one and starts
thrashing, that is expected. The uncertainty marker in the state block is the
signal, and walking out the way it came is the reasonable response.
