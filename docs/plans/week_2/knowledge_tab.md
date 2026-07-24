## Knowledge tab for Mud Monitor

Add a fifth tab — **Knowledge** — to `week2_capable/mud_monitor`, rendering the
agent's world memory from `.boukensha/knowledge.sqlite3`.

Everything the monitor shows today is a *log*: an append-only record of what
happened, in order, at three layers (`mud_monitor.md` §0.1). Knowledge is the
first thing on the page that is not a log. It is a **snapshot of belief** — what
the agent currently thinks the world is, which rooms it has walked, which mobs
it has appraised, and which exits it has never taken. The distinction drives
nearly every decision below: there is no cursor, no `seq`, no tail, and no SSE,
because there is no ordering to follow. There is one current answer, and it
changes underneath us while we look at it.

Prerequisite: `basic_memory.md` (the store that writes this file). That work has
landed — `week2_capable/boukensha/lib/boukensha/mud/memory/{schema,store,fingerprint}.rb`
exist and the file on disk is at `PRAGMA user_version = 1` with 12 rooms, 39
exits, 11 entities.

---

### 0. What already exists

Three pieces are already in place and must not be re-litigated:

1. **The path is already resolved.** `api/config/initializers/mud_monitor.rb:53`
   sets `c.knowledge_db` from `MUD_KNOWLEDGE_DB`, defaulting to
   `<boukensha_dir>/knowledge.sqlite3` — the same precedence the writer uses
   (`memory/store.rb:59`, `Store.for_dir`). Both halves resolve one file by
   construction. Do not add a second path constant.
2. **Health already reports it.** `health_controller.rb:18` returns
   `knowledge_attached: cfg.knowledge_db.file?`. That flag is now meaningful and
   is the tab's empty-state signal.
3. **The writer is deliberately WAL.** `memory/store.rb:47` sets
   `journal_mode=WAL` with the comment "readers never block the writer" —
   written *for* this feature. A monitor page refresh must never hand the agent
   `SQLITE_BUSY` mid-turn.

What does **not** exist: any `knowledge` entry in `api/config/database.yml`
(single database per environment today), any model, controller, route, or page.

---

### 1. The central decision: no ActiveRecord

`mud_monitor.md` §8 sketched `Knowledge::Room` / `Knowledge::Exit` as
ActiveRecord models on a second `knowledge:` connection with `replica: true`.
**This plan does not do that.** It reads the file with a plain `SQLite3::Database`
in `api/lib/knowledge/reader.rb`, and `database.yml` is left alone.

Four concrete reasons, in ascending order of how much they hurt:

| | Why AR fights us |
|---|---|
| Composite keys | `room_exits` is `PRIMARY KEY (room_id, direction)` and `entity_sightings` is `(entity_id, room_id)` — neither has an `id`. AR needs `self.primary_key =` gymnastics for tables it will only ever `SELECT` from. |
| No `schema_migrations` | `memory/schema.rb` migrates on `PRAGMA user_version` precisely so there is "no `schema_migrations` table to collide with". AR's schema cache and `maintain_test_schema!` both expect one. |
| Rake tasks | `db:prepare`, `db:test:prepare` and `db:schema:dump` enumerate every connection in `database.yml`. `replica: true` blocks *writes through AR*; it does not stop `rails db:*` from touching the file. Excluding it needs `database_tasks: false`, and getting that wrong once means a rake task truncating the agent's memory. |
| It's not our schema | The agent owns this DDL and will change it. A model layer that mirrors someone else's columns is a second copy of a schema we do not control. |

Against that, AR buys us: associations across ~6 tables and 12 rows. Not worth
one afternoon of `database_tasks: false`, let alone the failure mode.

The plain-reader choice is also the *house* choice. `api/lib/session_log/`,
`telnet_log/`, `manager_log/` are all POROs that parse another process's
artifact on request. Rails already "does not ingest logs into its own tables"
(`mud_monitor.md` §1). Knowledge is the same posture with a different file
format. `api/storage/development.sqlite3` remains Rails' own, empty, primary DB.

**Amend `mud_monitor.md` §8** to point at this file rather than at AR models.

---

### 2. Opening the file safely

Four things must all hold, and the naive `SQLite3::Database.new(path, readonly: true)`
fails one of them.

```ruby
# api/lib/knowledge/reader.rb
db = SQLite3::Database.new(path.to_s)        # NOT readonly: true — see below
db.results_as_hash = true
db.busy_timeout = 2000
db.execute("PRAGMA query_only = 1")          # SQLite itself rejects any write
```

- **`query_only = 1`, not `readonly: true`.** A connection opened `readonly`
  cannot create the `-shm` file a WAL database needs, so if the agent process is
  not currently running (no `-shm` present, or one left behind by a crash) the
  monitor gets `SQLITE_CANTOPEN` — the page breaks exactly when nobody is
  playing, which is most of the time. `query_only` lets SQLite manage
  `-shm`/`-wal` normally while rejecting every `INSERT`/`UPDATE`/`DELETE`/DDL at
  the engine level. That is a stronger guarantee than "we only wrote SELECTs in
  this file", and it survives someone later adding a helper method.
- **Never call `Schema.migrate!`.** The reader does not `require` boukensha at
  all; it speaks SQL. The agent is the only writer and the only migrator.
- **`busy_timeout` is short (2s), not the writer's 5s.** A web request that
  waits is worse than a web request that says "busy"; the writer's patience and
  the reader's are different problems.
- **A connection per request.** Opening SQLite is microseconds, and Puma is
  multi-threaded while `SQLite3::Database` is not thread-safe. No memoized
  global connection, no connection pool. This is why freshness is *not* derived
  from `PRAGMA data_version` — that pragma's value is only comparable within one
  long-lived connection handle, so on a per-request connection it is noise.

#### 2.1 Freshness: watch the `-wal`, not the `.sqlite3`

Every other store in the app decides `live?` from `File.mtime` (e.g.
`telnet_log/store.rb:36`). Knowledge must do the same thing with one correction:

> Under WAL, commits land in `knowledge.sqlite3-wal`. The main `.sqlite3` file's
> mtime only moves on checkpoint, which may be minutes apart or never during a
> session.

A reader that watches only the main file reports "stale" while the agent is
actively exploring. On disk right now: `.sqlite3` at 18:55, `-wal` at 18:56, and
the `-wal` is 1.2 MB against a 4 KB main file. So:

```ruby
def last_write_at
  [ path, "#{path}-wal" ].filter_map { |p| File.mtime(p) if File.exist?(p) }.max
end
```

`live: last_write_at && (Time.now - last_write_at) <= cfg.live_window` — the same
`live_window` (10s) the other pages use, so the `LiveBadge` means one thing
across the app.

#### 2.2 Schema drift

The reader reports `PRAGMA user_version` as `schema_version` in every payload
and knows `1`. Policy:

- **Newer version → serve anyway.** `memory/schema.rb` migrations are additive
  by construction ("append to MIGRATIONS, never edit an applied one"), so a
  newer file still answers our SELECTs. Surface the number in the UI footer so a
  surprising value is visible.
- **A failing SELECT → one clear error, not a 500 backtrace.** Wrap reads and
  translate `SQLite3::SQLException` into
  `{ error: { code: "knowledge_schema_mismatch", message: "…", schema_version: N } }`
  with `503`. The tab renders that as a banner; the rest of the monitor is
  unaffected.
- **Missing file → `200` with `attached: false`.** Same rule as "no telnet log
  for today" (`mud_monitor.md` §4.2): absence is a state, not an error.

---

### 3. HTTP API

Under `/api/v1/knowledge`, JSON, read-only. Every payload carries the same
envelope header so any view can render the live badge and staleness without a
second call:

```jsonc
{
  "attached": true,
  "live": true,
  "last_write_at": "2026-07-23T22:56:01Z",
  "schema_version": 1,
  ...payload
}
```

`routes.rb`, mirroring the existing flat style:

```ruby
get "knowledge",                to: "knowledge#show"
get "knowledge/rooms",          to: "knowledge#rooms"
get "knowledge/rooms/:id",      to: "knowledge#room",     constraints: { id: /\d+/ }
get "knowledge/entities",       to: "knowledge#entities"
get "knowledge/frontier",       to: "knowledge#frontier"
```

#### 3.1 `GET /knowledge` — overview

```jsonc
{
  "attached": true, "live": true, "last_write_at": "…", "schema_version": 1,
  "stats": { "rooms": 12, "surveyed": 12, "entities": 11, "mobs": 9,
             "objects": 2, "exits": 39, "frontier": 27, "encounters": 0,
             "traversed": 12 },
  "player": {
    "hp": 20, "max_hp": 20, "mana": 100, "move": 72,
    "level": 1, "gold": 0, "exp": null, "position": null,
    "last_direction": "north",
    "session_id": "20260723T225532Z-7ed8c53a",
    "updated_at": "2026-07-23T22:56:01Z",
    "current_room": { "id": 12, "name": "…" },
    "prev_room":    { "id": 11, "name": "…" }
  }
}
```

`stats` deliberately matches `Store#stats` (`memory/store.rb:289`) plus three
derived counts (`mobs`/`objects`, `exits`, `traversed`) — it is the same
question, asked from the read side, and keeping the names identical means a
future divergence is a bug someone can see.

**`player` may be `null`.** `player_state` is a single row that only exists once
the agent has looked at something. Empty DB is a legitimate state.

**`session_id` is the interesting field.** It names the boukensha run that last
wrote — so the overview links straight to `/sessions/<id>`, joining belief to the
transcript that produced it. That link is the whole reason this tab lives in the
monitor instead of being a `sqlite3` one-liner.

#### 3.2 `GET /knowledge/rooms` — the room table

Params: `q` (substring over name + description), `filter` ∈ `surveyed` |
`unsurveyed` | `provisional`, `limit` (default 200, max 1000).

```jsonc
{ "rooms": [ {
    "id": 1,
    "name": "The Temple Of Midgaard",
    "description": "You are in the southern end of the temple hall…",
    "confidence": "confirmed",
    "look_candidates": ["wall","paintings","giants"],
    "visit_count": 1,
    "first_seen_at": "…", "last_seen_at": "…", "surveyed_at": "…",
    "weak_fingerprint": "7b26410a…",     // first 12 chars in the UI
    "strong_fingerprint": "06c9a44f…",
    "exits": [
      { "direction": "south", "target_name": "The Temple Square",
        "target_room_id": 2, "traversals": 1, "last_seen_at": "…" },
      { "direction": "north", "target_name": "By The Temple Altar",
        "target_room_id": null, "traversals": 0, "last_seen_at": "…" }
    ],
    "entity_count": 3
  } ] }
```

**Two queries, not N+1.** One `SELECT * FROM rooms`, one
`SELECT * FROM room_exits WHERE room_id IN (…)`, one `SELECT room_id, COUNT(*)
FROM entity_sightings GROUP BY room_id`, then group in Ruby. Twelve rooms today
makes this invisible; a thousand rooms after a week of exploration makes it the
difference between a page and a timeout, and the fix costs nothing now.

`look_candidates` is stored as a JSON string (`["wall","paintings","giants"]`).
The serializer parses it, and **returns `[]` on malformed JSON rather than
raising** — one bad row must not blank the whole table.

Sorted by `id` (discovery order) by default; the client sorts columns locally.

#### 3.3 `GET /knowledge/rooms/:id` — one room

The room as above, plus:

```jsonc
{ "room": { … },
  "entities": [ { "id": 3, "kind": "mob", "descr": "A cityguard stands here.",
                  "keyword": "cityguard", "threat": "Are you mad!?",
                  "threat_level": 1, "count": 1, "sighting_count": 6,
                  "first_seen_at": "…", "last_seen_at": "…" } ],
  "encounters": [ { "id": 1, "entity_id": 3, "outcome": "fled",
                    "player_level": 1, "hp_before": 20, "hp_after": 9,
                    "at": "…" } ],
  "inbound": [ { "room_id": 2, "room_name": "The Temple Square",
                 "direction": "north" } ] }
```

`inbound` is `SELECT … FROM room_exits WHERE target_room_id = ?` — how you got
here, which the `rooms` row cannot tell you. `404` with the standard error shape
for an unknown id.

#### 3.4 `GET /knowledge/entities` — the bestiary

Params: `kind` ∈ `mob` | `object`, `q` over `descr`/`keyword`.

Each entity carries its `entity_sightings` rows resolved to room names, so the
table answers "where does this thing live" without a click. Sorted by
`seen_count DESC` — the things the agent keeps running into are the things worth
looking at.

`threat` is `consider`'s verdict ("Are you mad!?", "The perfect match!") and is
**only meaningful next to `threat_level`**, the player level it was measured at
(`memory/schema.rb`, `entities.threat_level` comment). The serializer emits both
and the UI renders them together, always. A threat verdict shown without its
level is actively misleading after a single level-up.

#### 3.5 `GET /knowledge/frontier` — what the agent has not walked

```jsonc
{ "frontier": [ { "room_id": 1, "room_name": "The Temple Of Midgaard",
                  "direction": "north", "target_name": "By The Temple Altar",
                  "last_seen_at": "…" } ],
  "count": 27 }
```

`SELECT … WHERE target_room_id IS NULL` — the query the partial index
`idx_exits_frontier` exists to serve. This is the highest-value view in the tab
and the reason it is a first-class endpoint rather than a filter: 27 unwalked
exits against 12 known rooms is the single number that says how much of the
world the agent has actually seen, and it is what a "where should I go next"
feature will read first.

#### 3.6 No SSE; poll instead

Every other live view in the monitor streams because it is tailing an
append-only file with a cursor (`mud_monitor.md` §3.3). Knowledge has no cursor
— an `UPDATE` to `rooms.visit_count` is not an event and cannot be expressed as
"entries after seq N". Streaming it would mean either re-sending the whole
snapshot on every commit or inventing a change-feed the writer does not emit.

So: the page re-fetches the current view every **3s while the document is
visible**, using `document.visibilityState` to stop polling on a hidden tab.
Cost is a handful of SELECTs over a 4 KB database. If the payloads ever get
large enough for that to matter, the fix is a cheap `HEAD`-style version probe,
not SSE — but do not build it before it is needed.

`cfg.stream_gate` is untouched: knowledge holds no long-lived connections and
must not consume an SSE slot.

---

### 4. Frontend

```
web/src/
├── api/
│   ├── client.ts        # + fetchKnowledge, fetchKnowledgeRooms, fetchKnowledgeRoom,
│   │                    #   fetchKnowledgeEntities, fetchKnowledgeFrontier
│   ├── types.ts         # + KnowledgeEnvelope, KnowledgeOverview, KnowledgeRoom,
│   │                    #   KnowledgeExit, KnowledgeEntity, FrontierExit
│   └── usePolling.ts    # NEW — visibility-aware interval refetch
├── components/
│   ├── ThreatChip.tsx   # NEW — threat + level, never one without the other
│   └── FingerprintCode.tsx  # NEW — first 12 chars, full value on hover/title
└── pages/
    └── knowledge/
        ├── Knowledge.tsx      # shell: envelope header, sub-nav, <Outlet/>
        ├── Overview.tsx
        ├── Rooms.tsx
        ├── RoomDetail.tsx
        ├── Entities.tsx
        └── Frontier.tsx
```

**Routing.** `Layout.tsx:15` gets `<Link to="/knowledge">Knowledge</Link>` between
Telnet and Health. `App.tsx` gets a nested route so every sub-view is
linkable — `/knowledge`, `/knowledge/rooms`, `/knowledge/rooms/:id`,
`/knowledge/entities`, `/knowledge/frontier`:

```tsx
<Route path="knowledge" element={<Knowledge />}>
  <Route index element={<Overview />} />
  <Route path="rooms" element={<Rooms />} />
  <Route path="rooms/:id" element={<RoomDetail />} />
  <Route path="entities" element={<Entities />} />
  <Route path="frontier" element={<Frontier />} />
</Route>
```

Sub-views as routes rather than `useState` tabs: a room the agent got wrong is
something you paste into chat, and "click Knowledge, then Rooms, then find #7"
is not a link.

**States, in the app's existing idiom** (`.empty`, `.error`, `.meta`,
`.stat-grid`, `.stat-tile`, `.nowrap`, `LiveBadge`):

- `attached: false` → `.empty`: "No knowledge file yet — the agent writes
  `knowledge.sqlite3` the first time it looks at a room." Include the resolved
  path from `/health` so a wrong-directory bug is diagnosable on sight. This is
  the same failure that made telnet/manager report "logging is off"
  (`initializers/mud_monitor.rb:14-17`); do not repeat it silently.
- `attached: true`, no `player` row → tables render; overview shows "no player
  state recorded yet".
- `knowledge_schema_mismatch` → `.error` banner naming the version found.

**Cross-links are the point.** Room names in the exit column link to
`/knowledge/rooms/:id` when `target_room_id` is set and render as plain text
when it is `null` — the visual difference between "known" and "frontier" is then
free and consistent everywhere. `player.session_id` links to
`/sessions/<id>`. Frontier rows link back to their origin room.

**Rooms table columns:** `#`, Name, Conf, Visits, Exits (`N/M walked`),
Entities, Look targets, Last seen. Description truncated with the full text in
`title` (same treatment as `manager-sent`, `Manager.tsx:213`). `provisional`
confidence gets a distinct row class — a provisional room is the fingerprint
resolver admitting it might be wrong, and that is exactly what someone opening
this page is hunting for.

**Explicitly out of scope: the map.** `mud_monitor.md` §8 wants
`@xyflow/react` + `dagre` rendering rooms-as-nodes against the world bundles.
`/knowledge/rooms` already returns nodes (`id`, `name`) and edges (`exits[]` with
`target_room_id`), so the map is a renderer added later over an unchanged
endpoint. Building it now would drag in the world-bundle join (§7) and two
dependencies before anyone has confirmed the table is even right.

---

### 5. Testing

**Fixture: SQL, not a binary.** `api/test/fixtures/knowledge/seed.sql` holds the
DDL (copied from `memory/schema.rb` V1, plus `PRAGMA user_version = 1`) and a
dozen INSERTs; a `test_helper` method builds a temp DB from it and points
`cfg.knowledge_db` at it, mirroring the `manager_dir` swap in
`manager_controller_test.rb:8-16`. A committed `.sqlite3` cannot be reviewed in a
diff and rots the first time the agent's schema moves.

The fixture must contain, deliberately: a `provisional` room; a room with
`surveyed_at IS NULL`; an exit with `target_room_id IS NULL`; a room with
`look_candidates` = `[]` and one with malformed JSON; both entity kinds; an
entity with `threat` but no `threat_level`; and at least one `encounters` row —
the live DB has zero, so combat readout is otherwise untested.

Reader tests:

- Missing file → `attached: false`, `200`, empty payloads. No exception.
- `query_only` actually rejects a write (assert the `SQLite3::ReadOnlyException`)
  — this is the safety property; assert it rather than trust it.
- Freshness uses the `-wal` mtime: touch only the `-wal` and assert `live: true`
  while the main file's mtime is old. **The regression test for §2.1.**
- A DB with no `-shm` present opens successfully (the `readonly: true` trap).
- Malformed `look_candidates` yields `[]`, and the other rooms still render.
- `user_version = 99` still serves; a dropped column yields
  `knowledge_schema_mismatch` / `503`, not a 500.

Controller tests: overview shape with and without a `player_state` row; `rooms`
filters (`q`, `filter=unsurveyed`, `filter=provisional`); exits grouped onto the
right rooms; `rooms/:id` 404s on an unknown id and includes `inbound`;
`entities?kind=mob` excludes objects; `frontier` returns only null-target exits
and its `count` matches.

Query-count guard on `rooms`: assert a fixed number of statements regardless of
room count (seed 3 rooms, then 30, expect the same count). Cheap, and it is the
only way the N+1 stays fixed.

Frontend: `npm run lint` (`tsc -b --noEmit`) is the bar the rest of `web/`
holds; no component test harness exists and this plan does not add one.

---

### 6. Phasing

| # | Deliverable | Done when |
|---|---|---|
| 1 | `Knowledge::Reader` + `GET /knowledge` + nav tab + Overview page | The tab shows live stats and player state from the real file, and links to the writing session |
| 2 | `rooms`, `rooms/:id` + Rooms / RoomDetail pages | Every known room, its exits, and its inhabitants are browsable; frontier exits are visually distinct |
| 3 | `entities`, `frontier` + their pages | The bestiary shows threat-with-level; the frontier list is the "where next" answer |
| 4 | Visibility-aware polling on every view | Walking the agent into a new room makes the tab update without a reload |

Phase 1 is the whole risk: the connection posture (§2), WAL freshness (§2.1),
and the absent-file path. Phases 2–4 are additional SELECTs against a reader
that already works. Ship 1 before writing any of 2.

---

### 7. Risks

- **The agent's schema moves under us.** Mitigated, not solved: `user_version`
  is reported, additive migrations serve fine, and a broken SELECT degrades to
  one banner. Accepted — the alternative is a schema copy in Rails, which is
  worse (§1).
- **WAL grows unbounded during a long session.** 1.2 MB after one short run,
  and the reader does not checkpoint (it cannot — `query_only`). That is the
  writer's problem and belongs in `basic_memory.md`, but the monitor is where it
  will first be *noticed*: surface `-wal` size in the overview footer so it is
  observable before it is a bug.
- **Polling multiplies with open tabs.** Three browser tabs on `/knowledge` is
  one SELECT-set per second against the DB the agent is writing. Visibility
  gating handles the common case (background tabs); `busy_timeout = 2000` bounds
  the bad case. Revisit only if the agent ever reports contention.
- **Belief shown as fact.** Everything on this tab is what the agent *thinks*,
  including rooms it fingerprinted wrong. The `provisional` badge and the
  visible fingerprints are the honesty mechanism; the page must never present a
  provisional room the same way it presents a confirmed one.

---

## Amendment A — what execution changed

Implemented 2026-07-23. Six corrections the plan got wrong or left out, each
found by a test or by running against the real file.

**A.1 Named columns, never `SELECT *`.** §2.2 promised that a schema the reader
can't query degrades to one clear banner. It doesn't, if the query is
`SELECT *`: dropping `rooms.visit_count` produces no error at all, just a
column of silent `nil`s that the UI renders as blanks forever. The drift is
invisible in exactly the case the section was written for. `Reader::ROOM_COLUMNS`
/ `EXIT_COLUMNS` / `ENTITY_COLUMNS` name every column, which turns drift into the
`SQLException` that `SchemaMismatch` was already waiting for. The test that
caught this is the one that was written to prove §2.2 worked.

**A.2 `equipment` is JSON too.** The plan only knew about `look_candidates`.
`entities.equipment` is written with `JSON.generate` (`memory/store.rb#remember_entity`)
and parsed back by the writer's own reader at `store.rb:214` — so passing it
through as a raw string would have shown `["<wielded>"]` in the UI. Both fields
now share one `parse_json_list`, and malformed input degrades to `[]` for both.

**A.3 `get "knowledge/rooms/:id"` needs an explicit `as:`.** Rails derives the
helper name from the *static* segments, so it produces `knowledge_rooms` for
both the index and the member route, notices the collision, and silently leaves
the member route with no helper at all. It is a 404-shaped failure that only
shows up in tests. Named `as: :knowledge_room`.

**A.4 Search boxes are debounced (`useDebouncedValue`, 250ms).** Unforeseen
interaction between two decisions the plan made separately: `usePolling` clears
its data when `deps` change (§3.6, so a new query never shows the old answer),
and the room/entity filters are free text. Together, typing "temple" blanks the
table six times and fires six requests. The other pages get away with
fetch-per-keystroke because their filters are short codes.

**A.5 Sub-views publish the envelope upward rather than the shell re-fetching
it.** §4's shell needed `live`/`schema_version` for the header, but every
sub-view's payload already carries the envelope (§3) — a second request every
3s to render one badge would have been pure waste. `useReportEnvelope` in
`pages/knowledge/Knowledge.tsx` is a context callback children hand their
envelope to.

**A.6 `stats` gained `provisional`.** Not in §3.1's list. Provisional rooms are
the thing this tab exists to surface (§7), so the count belongs on the overview,
not only as a row-level badge.

### Not amended, but found

`bin/rails test` **hangs under the parallel runner** on this machine — the
suite passes 141/141 in 0.47s with `PARALLEL_WORKERS=1`, and hangs indefinitely
without it. This reproduces with the knowledge tests *excluded*, so it predates
this work; it is recorded here because `config/ci.rb` runs `bin/rails test`
unqualified, which means CI cannot currently verify any of it.

`GET /api/v1/health` reports `boukensha_dir: ""` on the running dev server. The
initializer's fallback chain is `ENV["BOUKENSHA_DIR"] || rc || ~/.boukensha`,
and an empty-string env var is truthy in Ruby, so it wins and resolves to
nothing. Harmless today because `MUD_KNOWLEDGE_DB` and the three
`MUD_MONITOR_*_DIR` vars are all set explicitly — but the empty value is exactly
what `KnowledgeEmpty` would show an operator hunting a wrong-directory bug.
