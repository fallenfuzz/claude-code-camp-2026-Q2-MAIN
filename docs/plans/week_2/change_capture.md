# JOURNAL — an append-only change log for progression over time

> **Status: implemented (2026-07-24).** Spun out of `player_update.md` review, where the
> question surfaced: how do we track *when* things changed — levels gained, items
> gained/lost/used, skills practiced — so we can graph progression rather than only
> show a current snapshot? This is that layer. It deliberately does **not** live in
> `knowledge.sqlite3`; it is a fourth append-only jsonl log in `.boukensha/`, sibling
> to `telnet/`, `manager/`, and `sessions/`, written through one generic upsert-capturing
> class and read by the monitor exactly like the other three logs.
>
> **Amendment (as built) — capture is generic, at the Store layer.** The plan below first
> proposed a *selective* seam in `Mud::Hooks` that hand-picked a few player stats and
> excluded hp/mana/move jitter (original invariant 4). On review the goal was restated:
> capture **every** upsert/update/delete across the whole knowledgebase, not a player
> subset. So the capture moved **down into `Memory::Store`** — every mutating method
> (`update_player!`, `create_room`, `touch_room`, `record_exits!`, `link_exit!`,
> `remember_entity`, `record_sighting!`, `record_encounter!`, `demote_exit!`, …) emits a
> delta through the journal. The journal still owns change-detection, so no-ops write
> nothing; hp/mana/move are now captured (on change), and the jitter-throttling question
> is **deferred until we can measure real volume from the log** rather than pre-filtered.
> The hook now journals only signals that are *not* store writes: text-derived milestones
> (level-up, death) and item ops (until `player_items` exists). Sections below are kept as
> the original reasoning; the "as built" notes mark where reality diverged.

## The question this answers

`knowledge.sqlite3` is, by design, a **snapshot of current belief** — the reader's own
doc says so: *"no cursor, no `seq`, nothing to tail… a snapshot that changes underneath
the reader."* It can tell you the agent is level 5 with 3 items. It cannot tell you
*when* it hit level 5, how the exp curve got there, or that it picked up and then sold a
sword an hour ago. That history is gone the instant the snapshot overwrites itself.

We want progression: level(t), exp(t), gold(t), deaths on a timeline, skills climbing,
items appearing and disappearing. That is a **time series**, and a time series is a log,
not a snapshot.

## Why a jsonl log, not CDC inside SQLite

The instinct to reach for Change Data Capture is right; the mechanism matters. The
options, decided:

| Mechanism | Verdict |
|---|---|
| **SQLite Session extension** (`sqlite3session`) | **Unavailable and wrong shape.** Confirmed not compiled into this project's gem (`sqlite_compileoption_used('ENABLE_SESSION')` → 0; no `session` API). It also emits binary *changesets* for replication, not queryable time-series. |
| **Triggers → audit table** | Built-in and dependency-free, but `update_player!` fires on nearly every tool call (the free prompt-line hp scrape), so an `AFTER UPDATE` trigger captures a firehose of hp jitter. It is also magic-at-a-distance — the opposite of this schema's explicit *"a pragma and an array, not ActiveRecord"* posture. |
| **Roll-your-own append-only jsonl log** | **Chosen.** It *is* this project's native idiom for "things that happened, in order": `telnet/`, `manager/`, and `sessions/` are already exactly this — daily-rotated jsonl in `.boukensha/`, each read by a `Parser`/`Follower`/`Store` trio and streamed over SSE with a `seq` cursor. A progression log inherits all of that machinery for free and keeps `knowledge.sqlite3` a pure snapshot. |

**The load-bearing separation:** snapshot answers *"what is true now"* (SQLite, polled);
log answers *"what happened, in what order"* (jsonl, streamed). We already run both kinds
side by side; progression is a log, so it goes where logs go.

## The generic piece: an upsert-that-captures-changes

The heart of this, per the review, is **one generic class that takes upserts and captures
only the changes** — callers stay dumb (they hand it the current value every time they
read it), and the class decides what is actually a transition worth recording. That is
Change Data Capture in the honest sense: *emit on change, swallow the no-ops.*

```
boukensha/lib/boukensha/journal.rb          NEW — Boukensha::Journal
```

`Boukensha::Journal` mirrors `Boukensha::Logger`'s exact posture — `File.open(path, "a")`,
one `JSON.generate` per line, `flush`, daily rotation, `seq`/`at`/`mono_ms`/`session_id`
stamping, directory resolved from `Boukensha.config.dir` — so it reads as a sibling of the
logger, not a new idiom. Its API is small:

```ruby
# The upsert. Compares `value` to the last value seen for [stream, key] this
# process; appends a change line ONLY if it differs. Returns whether it wrote.
# Callers upsert the current reading unconditionally and never track prev state
# themselves — the journal is the single owner of "did this change?".
journal.upsert(stream: "stat", key: "level", value: 5, **meta)
#   → {"seq":.., "at":.., "session_id":.., "stream":"stat", "key":"level",
#      "from":4, "to":5, ...}   (nothing written if it was already 5)

# The discrete-event escape hatch, for things that are ops, not keyed-value
# transitions: an item picked up, dropped, or consumed.
journal.event(stream: "item", op: "acquire", descr: "a long sword", keyword: "sword", qty: 1)
```

- **`stream`** partitions the log the way `phase` partitions the session log: `stat`
  (player scalars), `skill` (proficiencies), `item` (inventory ops), and it is open for
  later non-player use (room discovery, encounter outcomes) — this class is world-agnostic
  infrastructure; the player is merely its first client.
- **Change detection lives in exactly one place** (`upsert`), keyed on `[stream, key]`
  with an in-memory `@last` map. No call site re-implements it; none can disagree.
- **Baselines.** On construction the `@last` map is empty, so the first reading of every
  key after a restart would look like a change. The class provides `seed` (populate `@last`
  without writing) and `snapshot` (seed + write one `session_open` anchor line) for this.
  *(As built: with capture at the Store layer, neither is wired by default. The store only
  emits for rows it actually touches this session, so on a fresh process the first write of
  each field is a `nil → value` change that serves as its own per-session baseline; no full
  DB re-scan on open. `seed`/`snapshot` remain available — and tested — if a cleaner
  cross-session anchor is wanted later.)*
- **Robustness.** Every write is wrapped like the hooks' `guard`: a broken journal must
  degrade to "no progression captured," never kill a turn. It is telemetry, not the game.

## Where the writes happen

> **As built:** capture lives in `Memory::Store`, not `Mud::Hooks`. `Store` gained an
> optional `journal` accessor (wired at the entrypoint: `store.journal = journal`), and
> every mutating method emits a delta after its SQL — `jupsert(stream, key, value)` for
> re-written-frequently fields (change-detected, so re-recording the same value is silent)
> and `jevent(stream, op, **fields)` for genuinely discrete writes. This makes the log
> **generic CDC over the whole knowledgebase**, and keeps the hook free of per-field
> knowledge. The original hook-seam design (below) is retained only for the two signals
> that are *not* store writes.

What the store emits, as built:

| Store mutation | Journal delta |
|---|---|
| `update_player!(**fields)` | `jupsert("stat", <column>, value)` per field (all columns, incl. hp/mana/move; `updated_at` skipped) |
| `create_room` / `touch_room` / `mark_surveyed!` | `jevent("room", "create"/"visit"/"surveyed", id:)` |
| `record_exits!` / `link_exit!` / `rename_exit_target!` | `jupsert("exit", "<room>:<dir>:target_name\|target_room_id", value)` |
| `demote_exit!` | `jevent("exit", "demote", room_id:, direction:)` |
| `remember_entity` | `jupsert("entity", "<id>:threat", value)` (the appraisal is the delta; descr/keyword are static) |
| `record_sighting!` | `jupsert("sighting", "<entity>:<room>:count", value)` |
| `record_encounter!` | `jevent("encounter", <outcome>, room_id:, entity_id:, player_level:, hp_before:, hp_after:)` |

What the **hook** still emits (not store writes):

| Moment (in `Mud::Hooks`) | Journal write |
|---|---|
| level-up line (`LEVEL_UP` regex) | `event(stream:"milestone", op:"level_up", level:)` |
| death (`DEATH` regex → `note_death`) | `event(stream:"milestone", op:"death", level:)` |
| item op (`get_item`/`drop_item`/`put_item`/`equip_item`/`consume_item`/`use_magic_item`) | `event(stream:"item", op:, tool:, keyword:)` |

The item events are a stopgap until `player_update.md` adds a `player_items` table and a
`replace_items!` store method; once that lands, item changes flow through the store's
generic CDC like everything else, and this resolves `player_update.md`'s open question the
same way: **`player_items` stays a replace-on-read snapshot** ("what's in the bag now"),
and the add/remove/use *history* lives in the journal. Skills (`skill` stream) likewise
wait on `player_update.md`'s `parse_skills`/`upsert_skills!`.

## The monitor side — a reader trio, exactly like ManagerLog

The progression log is append-only with a per-record `seq`, so it **streams** (SSE), unlike
knowledge which polls. Mirror `ManagerLog::*` one-for-one:

```
mud_monitor/api/lib/journal/
  parser.rb     NEW — Journal::Parser: jsonl → ordered Records; seq READ from file
                       (daily-rotated, daemon may restart mid-day → seq must be stable,
                        same reasoning as ManagerLog::Parser)
  follower.rb   NEW — Journal::Follower: reload-on-change, records_after(seq)
  store.rb      NEW — Journal::Store: DATE_RE path_for/path_for!/live?, byte-for-byte
                       the ManagerLog::Store shape
  series.rb     NEW — Journal::Series: fold events → time-series per key for graphing
                       (level(t), exp(t), gold(t), deaths[], skills{name→points})
app/controllers/api/v1/journal_controller.rb   NEW — #index (+ ?after= cursor) and #stream
config/routes.rb        + get "journal", get "journal/stream"
config/initializers/mud_monitor.rb  + c.journal_dir = boukensha_dir.join("journal")
                                       (overridable via MUD_MONITOR_JOURNAL_DIR)
```

`#stream` uses the shared `cfg.stream_gate` and `stream_idle_timeout` already governing
sessions/telnet/manager — so the progression stream counts against the same 8-slot cap and
needs no new streaming infrastructure.

## Display — a Progression view that reuses Sparkline

Graphing infrastructure already exists: `web/src/components/Sparkline.tsx` is in use on
`SessionDetail`. So:

- **New `Progression` subtab** on the Knowledge page (a sixth `TABS` entry in
  `Knowledge.tsx`), fed by `fetchJournal`/an event stream, rendering:
  - **level / exp / gold over time** — line or sparkline series from `Journal::Series`;
  - **deaths & level-ups** — a milestone timeline;
  - **skills** — proficiency climbing per skill;
  - **item ledger** — a scrollable acquire/drop/use feed (the "when was this added/removed/
    used" the review asked for), which is just the `item` stream rendered in order.
- Or, if lighter is preferred, a **Progression panel on the Player subtab** from
  `player_update` — same data, one fewer tab. Recommend the dedicated subtab: charts want
  room, and it keeps the Player subtab a clean character sheet.

No new dependencies; reuse `Sparkline`, the token palette, and the existing
`useEventStream`/`usePolling` hooks.

> **As built:** the subtab exists and polls `fetchJournal`. It renders a self-contained
> `SeriesChart` (reusing the `.spark`/`.spark-line` styling, since `Sparkline` is bound to
> per-iteration token usage), charting the numeric progression/vitals stats
> (`CHARTED_STATS`: level/exp/gold/hp/mana/move + maxes/alignment) — every *other* captured
> field (positions, directions, room/exit/entity/encounter streams) shows only in the raw
> feed to keep the charts meaningful. Added beyond the plan: a **"Change log (raw)" CDC
> feed** at the bottom rendering every record in order (`kind` · `stream.key: from → to` or
> `stream op`), which is the "tab for CDC logs so we can parse it" the review asked for and
> the thing that makes a walk-only session visibly non-empty.

## Phasing

*(All phases implemented 2026-07-24; ✅ = done, with as-built notes.)*

- **P0 — Journal writer.** ✅ `Boukensha::Journal` (`upsert`, `event`, `seed`/`snapshot`,
  rotation, `guard`); `test_journal.rb` (10 tests): unchanged upsert writes nothing, a
  changed one writes `from`/`to`, `seq` resumes from line count across a restart, a write
  failure degrades instead of raising.
- **P1 — Capture seam.** ✅ *As built: capture is in `Memory::Store`, not `Mud::Hooks`.*
  Every `Store` mutation emits a delta (`store.journal = journal` at the entrypoint);
  `test_memory_store.rb` covers per-field stat deltas, room lifecycle events, change-detected
  exit upserts, encounter events, and the no-journal no-op. The hook retains only the
  milestone + item events (`test_mud_hooks.rb`). *Not blocked on `player_update.md`* — it
  captures whatever columns exist today; skill/item store-capture arrives with that plan.
- **P2 — Reader trio.** ✅ `Journal::Parser`/`Follower`/`Store` + `Series`; fixture-seeded
  tests; cursors monotonic across a simulated mid-day restart.
- **P3 — Controller + route.** ✅ `#index` (folds the day into series + `?after=` entries) +
  `#stream` (shared stream gate), `journal_dir` config (with a controller-side fallback to
  `boukensha_dir/journal` so a pre-feature server boot self-heals instead of 500ing).
- **P4 — Progression view.** ✅ `Progression` subtab: charted stats (level/exp/gold/vitals),
  milestone timeline, skills, item ledger, **plus a raw "Change log (CDC)" feed** rendering
  every record — so even a walk-only session shows something to parse.
- **P5 — Ship.** ✅ `npm run build` (dist is gitignored here, so nothing to commit there);
  README updated with the Progression page + `MUD_MONITOR_JOURNAL_DIR`.

## Invariants

1. **Snapshot and log are separate homes.** Current state → `knowledge.sqlite3` (polled);
   history → `.boukensha/journal/*.jsonl` (streamed). Neither reaches into the other.
2. **One owner of change-detection.** Only `Journal#upsert` decides what is a transition;
   call sites hand it current values and never diff.
3. **Append-only, stable `seq`.** Records are never rewritten; `seq` is read from the file
   so cursors survive daemon restarts (the ManagerLog rule).
4. **Emit on change, swallow no-ops.** An unchanged reading writes nothing — that is the
   whole point. *(As built: this is the ONLY volume control. The original invariant also
   pre-excluded hp/mana/move; that exclusion was dropped — every field is captured on
   change, and any per-field throttling is a later decision driven by measured volume, not
   a guess baked into the capture layer. Field-level keys make that measurement a line
   count per key.)*
5. **Telemetry never breaks the game.** Every journal write is guarded; a failure degrades
   to "no progression captured."
6. **Path resolution is shared, never guessed** — `journal_dir` derives from `boukensha_dir`
   exactly as `telnet_dir`/`manager_dir` do, or the monitor reports "logging is off" for a
   log that is actually writing elsewhere.
7. **Generic, not player-specific.** `Journal` is world-agnostic infrastructure; the player
   streams are its first client, not its definition. *(As built, this is realised fully:
   capture lives in `Memory::Store` and covers rooms/exits/entities/sightings/encounters as
   well as player state — genuine CDC over the whole knowledgebase, not a player subset.)*

## Not now

- **Retention / compaction** of old daily journal files (the logs already rotate; a sweeper
  is a later ops concern).
- **Reconstructing history from existing telnet logs** to backfill progression from before
  this ships — possible (the telnet log has timestamped `score` output), but a one-off
  migration, not part of the live path.
- **Cross-run analytics** (compare two characters, two sessions) — the log supports it; the
  UI for it is later.
- **Jitter throttling for hp/mana/move** — *(changed from "excluded" to "captured, tuning
  deferred")*. These are now journaled on change like every other field. If the measured
  volume proves noisy, the throttle options are: a per-key denylist, a threshold (only log a
  delta ≥ N), or coarsening to milestones (level-up/death). Decide from the log, not up front.
  Fine-grained per-tick curves still belong in the telnet/manager logs if ever wanted.
