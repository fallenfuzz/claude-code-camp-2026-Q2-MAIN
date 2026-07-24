# OBSERVATORY — a live-session tab for Mud Monitor

> **Status: adapted plan, for review.** This is the reverse-engineered
> `mud_observer.md` re-targeted onto *this* repo's stack (Rails 8 API + Vite/React
> monitor reading `knowledge.sqlite3` + the boukensha logs). The original assumed a
> standalone Python stdlib server reading a play-mud skill's flat files; almost
> none of that survives contact with our stack, and where it doesn't, this document
> says so out loud in §0 so the divergence is reviewable rather than buried.

## What this builds

A new **Observatory** tab in Mud Monitor for *watching the agent play*: the map
growing room by room, the agent's position, vitals, live activity (fighting /
resting / shopping / exploring / thinking), the real combat text, and the agent's
own running commentary. It is a pure **observer** — it reads sources the play
session already produces and never writes, never talks to the MUD, and the playing
agent does not know it exists. Same spirit as the original; different plumbing.

Unlike Sessions/Telnet/Manager (which answer *"what happened, in what order"*) and
unlike Knowledge (which answers *"what does the agent believe"*), the Observatory
answers *"what is happening right now, on a map."* It is the first page that
**fuses** belief (the SQLite snapshot) with the live logs.

Target location: a new `observatory/` page tree under `web/src/pages/`, a single
new controller + composer under `api/`, one route, one nav link. Nothing else in
the monitor depends on it.

---

## 0. The adaptation — what changed from the reverse-engineered spec

This is the most important section for review. The original spec's architecture was
shaped by constraints we don't have, and blind to affordances we do. The table maps
every original mechanism to its fate here.

| Original mechanism | Fate in this stack | Why |
|---|---|---|
| Standalone `serve.py` stdlib server on :8790, committed `dist/` | **Dropped.** Becomes one Rails controller + one React page tree inside the existing monitor. | We already have a Rails API + Vite/React app with an established Reader/Controller/Serializer pattern and a nav shell. A second server is pure duplication. |
| The **one `/state` contract**, sha1-hashed, conditional-GET | **Kept, and it is the load-bearing idea.** Becomes `GET /api/v1/observatory`, one merged frame, `?hash=` → `{"unchanged":true}`. | The map/cockpit UI genuinely wants a single coherent frame per tick, and the monitor already polls snapshots (Knowledge polls, doesn't stream). This is the seam that keeps the front end ignorant of every source format. |
| `.mud_memory.json` / `player.md` / `plan.json` flat-file readers | **Replaced by `Knowledge::Reader`** (already exists) reading `knowledge.sqlite3`, plus the existing `SessionLog` / `ManagerLog` / `TelnetLog` parsers. | These readers already exist, are tested, and already resolve `boukensha_dir` the same way the writer does. The composer reuses them; it does not read files directly. |
| **World mode + Localizer + `.wld` parsing** (the original §5, ~a third of the spec) | **Deleted entirely.** | The agent *already localized itself*. `knowledge.sqlite3` stores stable room identity (fingerprints → `rooms.id`), the walked graph (`room_exits.target_room_id`), and the current room (`player_state.current_room_id`). The belief-set narrowing the original had to do at render time is precomputed and persisted. This is the single biggest simplification. |
| Title-keyed fallback identity ("duplicate titles merge") | **Dropped.** Identity is always `rooms.id`. | Fingerprints already keep five "Main Street" segments distinct as five rows. There is no ambiguous mode to fall back to. |
| `derive_activity` by tailing a transcript and *inferring* fighting/resting | **Simplified.** `player_state.position` gives standing/resting/fighting/sleeping **directly**; the last `ManagerLog` command refines intent (shopping/reading/exploring). | The agent's own hooks already reconciled MUD position into SQLite. We read a verdict instead of re-deriving one from text. |
| Ghost rooms from `peeks` | **Becomes** exits with a `target_name` but no `target_room_id` (frontier), plus a one-ring halo of synthetic ghost nodes. | Same concept, already modelled in `room_exits`. `idx_exits_frontier` exists precisely to serve this. |
| Narration harvest by globbing `~/.claude/projects/**.jsonl` | **Replaced** by the last `reasoning`/`assistant` text from the **live boukensha session log** (`SessionLog::Parser`), selected via `player_state.session_id`. | We have first-party session logs with typed `reasoning`/`plan`/`assistant` events. No need to scrape Claude Code's private jsonl. |
| `plan.json` panel (goal + subtasks) | **`plan: null` for now, field preserved.** | Task/plan management isn't in this stack yet (you flagged it returns later). The contract keeps the field and the cockpit degrades gracefully; when tasks land, only the composer changes. |
| OpenAI `/speak` TTS proxy + `useVoice` | **Deferred** (§9). | Out of place in a monitor tab; add later behind a flag if wanted. |
| Ink & Parchment second theme + turbulence filter | **Deferred** (§9). | A whole second palette for a data tab; not now. |
| Tailwind v4 + framer-motion + d3-zoom dependency set | **Partially adopted.** Add `d3-zoom`/`d3-selection` for the camera only; do materialization/pulse/trail-fade with **CSS transitions + keyframes** against the monitor's existing token palette. No Tailwind, no framer-motion. | The monitor is plain CSS ported from `log_viz`. Matching that keeps the dep footprint honest; the app already ships hand-written keyframes. |
| `--selftest` in the server | **Becomes** Minitest unit tests for the composer, seeded from a fixture `knowledge.sqlite3` + fixture jsonl logs (the `knowledge_fixtures.rb` pattern already in the repo). | Rails has a test harness; use it. The composer's correctness spine is a set of asserts exactly as the original insisted, just in Minitest. |

**Net:** roughly half the original spec (world mode, localizer, wld parsing,
title-fallback, narration scraping, TTS, ink theme, the whole second runtime)
evaporates because our persistence layer already did the hard part. What remains is
the good part: the single contract, the map, the cockpit, the activity/combat
overlays.

---

## 1. Runtime shape & where it lives

```
api/
  config/routes.rb                      + get "observatory", to: "observatory#show"
  app/controllers/api/v1/
    observatory_controller.rb           NEW — one action, composes + hashes + conditional-GET
  lib/observatory/
    state.rb                            NEW — Observatory::State: merges the readers into the frame
    activity.rb                         NEW — Observatory::Activity: position + last command → Activity/combat
  (reuses) lib/knowledge/reader.rb, lib/session_log/*, lib/manager_log/*, lib/telnet_log/*

web/src/
  App.tsx                               + <Route path="observatory" element={<Observatory/>}/>
  components/Layout.tsx                 + <Link to="/observatory">Observatory</Link>
  pages/observatory/
    Observatory.tsx                     NEW — tab shell: poller + <MapView/> + <Cockpit/> + overlays
    state.ts                            NEW — StateC types, EMPTY_STATE, useObservatory() poller
    map/layout.ts                       NEW — deterministic grid-BFS layout
    map/MapView.tsx                     NEW — SVG scene, camera (d3-zoom)
    cockpit/Cockpit.tsx                 NEW — vitals, activity, events, plan(null-safe)
    overlays.tsx                        NEW — combat panel, toasts
  api/client.ts                         + fetchObservatory(hash?)
  api/types.ts                          + ObservatoryState and friends
  index.css                             + observatory tokens/keyframes (extend, don't fork)
```

No new config keys: the composer reuses `cfg.knowledge_db`, `cfg.sessions_dir`,
`cfg.manager_dir`, `cfg.telnet_dir`, `cfg.live_window` from
`config/initializers/mud_monitor.rb`. Runtime is unchanged: `bin/dev`, then open the
Observatory tab.

---

## 2. The one contract (`web/src/api/types.ts` ↔ composer output)

The spine. Every field is filled by the composer; the UI reads *only* this shape.

```ts
interface RoomC   { id: number; name: string; exits: string[]; flags: RoomFlag[];
                    confidence: "confirmed" | "provisional"; surveyed: boolean; }
                  // exits: long dir names present on this room ("north","up",…)
type RoomFlag = "current" | "ghost" | "unsurveyed" | "provisional" | "death";
interface LinkC   { from: number; to: number; dir: string; ghost?: boolean; }
                  // ghost: a frontier exit (target_name known, target_room_id null) → halo node
interface Vitals  { hp: number|null; max_hp: number|null; mana: number|null;
                    move: number|null; level: number|null; gold: number|null; exp: number|null; }
                  // NOTE: knowledge has NO max_mana / max_move / exp_to_next. Bars exist only
                  // where a max exists (hp). mana/move/exp render as plain figures.
type ActivityKind = "fighting"|"resting"|"sleeping"|"shopping"|"reading"
                  | "exploring"|"thinking"|"dead"|"busy"|"idle";
interface Activity{ kind: ActivityKind; detail: string; }

interface ObservatoryState {
  rooms: Record<string, RoomC>;        // key = String(room.id)
  links: LinkC[];
  trail: LinkC[];                      // recent traversed edges, oldest→newest (fading route)
  position: number | null;            // current_room_id; null = unknown
  vitals: Vitals;
  deaths: number;                      // COUNT(encounters WHERE outcome='died')
  events: string[];                    // rotating window, capped server-side
  plan: { goal: string; steps: { text: string; done: boolean }[] } | null; // null until tasks exist
  thought: string;                     // latest reasoning/assistant text from the live session
  thought_age_s: number | null;        // quantized //15
  activity: Activity | null;
  combat: { foe: string; lines: string[] } | null;
  feed: string[];                      // last raw telnet game lines (terminal drawer)
  quiet_seconds: number | null;        // quantized //5
  session_id: string | null;           // the boukensha run belief was last written by
  envelope: KnowledgeEnvelope;         // reuse the existing shape: attached/live/last_write_at/schema_version/wal_bytes
  hash?: string;
}
```

Also export `EMPTY_STATE` (all-empty) and `type Mode = "live"|"idle"|"waiting"`. The
UI always spreads `{...EMPTY_STATE, ...payload}` so a partial payload never yields
`undefined`.

**Identity rule:** a room's key *is* `String(room.id)`. No title merging, no vnum
mode. The UI only ever compares keys.

---

## 3. The composer (`api/lib/observatory/state.rb` → `Observatory::State`)

A PORO, exactly like the log parsers and `Knowledge::Reader` — *not* ActiveRecord.
It opens the readers, builds the frame, and closes them. Every source is optional and
degrades silently: no knowledge file → `waiting`; no live session → `thought:""`; no
manager/telnet logs → activity falls back to `player_state.position` alone.

```ruby
Observatory::State.build(cfg) → Hash   # the ObservatoryState above, minus hash
```

### 3.1 rooms / links / ghost halo — from knowledge

Source: `Knowledge::Reader#rooms(limit: …)` and the per-room `exits` it already
returns. For each room:

- `RoomC.id/name/confidence/surveyed` straight from the row (`surveyed = surveyed_at != nil`).
- `exits` = the room's `room_exits.direction` values (already long-form; no expansion
  table needed — that was an original-spec problem we don't have).
- `flags`: `"provisional"` if `confidence == "provisional"`; `"unsurveyed"` if
  `surveyed_at` is null; `"death"` if any encounter in this room has `outcome == "died"`;
  `"current"` if `id == player_state.current_room_id`.
- **Links:** one `LinkC{from,to,dir}` per exit where `target_room_id` is present.
- **Ghost halo:** for each exit with a `target_name` but **null** `target_room_id`
  (a frontier — the agent named the exit but never walked it), synthesize a ghost room
  keyed by a stable negative id (`-(room_id*100 + dir_index)`) with `flags:["ghost"]`
  and a `LinkC{ghost:true}`. This is the "still exploring" preview and reuses exactly
  the data `idx_exits_frontier` is built to serve. Never duplicate a walked link.

### 3.2 position / vitals / deaths — from player_state + encounters

- `position` = `player_state.current_room_id` (null when the agent hasn't looked yet,
  or knowledge is fresh).
- `vitals` = `{hp, max_hp, mana, move, level, gold, exp}` from `player_state`. There is
  no `max_mana`/`max_move`/`exp_to_next` in this schema — the type reflects that and the
  cockpit does not draw bars it has no denominator for.
- `deaths` = count of `encounters.outcome == "died"`. Add a tiny `Reader#death_count`
  (one `SELECT COUNT(*)`) rather than pulling all encounter rows.

### 3.3 trail

`knowledge` persists only the single last edge (`prev_room_id --last_direction-->
current_room_id`). For a fading route, take **the most-recently-traversed linked
edges**: order `room_exits` with `target_room_id NOT NULL AND traversals > 0` by
`last_seen_at DESC`, take the newest 15, emit as `LinkC[]` oldest→newest. The current
`prev→current` edge is guaranteed newest. Truthful, uses data already on disk, and
needs no manager-log correlation. Degrades to `[]` on a fresh file.

### 3.4 thought — from the live boukensha session

Pick the session (§4). From its `SessionLog::Parser`, take the **last** entry whose
type is `:reasoning` or `:assistant` with non-empty text; truncate to ~220 chars.
`thought_age_s = (now - entry_at) // 15 * 15` (quantized so the hash doesn't churn
every second). This is the first-party replacement for the original's Claude-Code
jsonl scraping.

### 3.5 activity / combat / feed — from position + manager + telnet

`Observatory::Activity.derive(player_state, manager_tail, telnet_tail)`:

- **Base kind from `player_state.position`** (the affordance the original lacked):
  `fighting`/`resting`/`sitting`→resting/`sleeping`/`standing`→(refine below).
- **Refine `standing` by the last `ManagerLog` command** (`tool`/`sent` of the newest
  manager record for this session): a movement dir → `exploring`; `list/buy/sell/value`
  → `shopping`; `read/examine`/`look <arg>` → `reading`; a bare `look`/scan →
  `exploring`; else → `busy` (echo the command in `detail`).
- **combat:** when `position == "fighting"` **or** the last command ∈
  `{kill,hit,attack,bash,kick,backstab,cast}` and no death/flee line has appeared since,
  emit `combat = { foe: <arg or "enemy">, lines: <last ~25 non-blank telnet lines> }`.
- **dead:** most recent telnet line matches `You are dead!` → `kind:"dead"`,
  `detail:"died — corpse run ahead"`.
- **feed** = last ~40 non-blank `TelnetLog` `text` lines (inbound), the raw game output
  that drives the terminal drawer.
- **quiet_seconds** = `now - max(newest manager/telnet/knowledge write)`, quantized
  `//5*5`.
- **thinking overlay:** if `quiet_seconds > 15` and not dead/resting → override to
  `kind:"thinking"`, detail `"quiet for Ns — deciding the next move"`. If the session
  log grew in the last ~20 s, refine to `"thinking — reasoning in its head"`. The agent
  working in its own head is not the agent stuck.

Manager/telnet tails are read via the existing parsers over today's daily file,
filtered to the live `session`. Both logs are optional (off by default); their absence
just means activity leans on `position` alone.

### 3.6 plan — deliberately null

`plan: null` until task management exists in this stack. The field stays in the
contract so the cockpit renders a "no active plan" affordance and so that, when tasks
land, only §3 changes — never the UI shape.

### 3.7 hashing / conditional GET (`ObservatoryController`)

`json.dumps(sort_keys: true)` → sha1 → first 16 hex. If `params[:hash]` equals it,
render `{"unchanged": true}`; else attach `hash` and render the frame. **Every
per-second-jittering value (`thought_age_s`, `quiet_seconds`, any `updated_at` delta)
is quantized *before* it reaches the hash** so the client re-renders on real change
only — the same discipline the original leaned on, and the same reason Knowledge
quantizes freshness. The `envelope` reuses `Knowledge::Reader#envelope` verbatim.

No SSE. Like Knowledge, this is a snapshot that changes underneath the reader (an
`UPDATE` to `visit_count` is not an event with a cursor), so it **polls** and never
consumes one of the 8 `StreamGate` slots.

---

## 4. Picking the live session

Belief and logs must agree on *which run* we're watching:

1. `player_state.session_id` names the boukensha run that last wrote belief — the
   authoritative link from map to transcript. Resolve it through `SessionLog::Store#path_for`.
2. If that session file is missing or `session_id` is null, fall back to the newest
   session (`Store#paths.first`).
3. `Mode`: `waiting` when knowledge is unattached / no rooms; `live` when
   `envelope.live` (knowledge written within `live_window`); `idle` otherwise. The
   header badge reuses the existing `live-badge` component and `envelope` exactly as
   the Knowledge page does.

Manager/telnet tails filter their daily files to this `session` value (both records
carry a `session` field).

---

## 5. Frontend: tab shell + poller (`pages/observatory/`)

### `state.ts` — types + poller

`useObservatory()`: 1 Hz `fetchObservatory(lastHash)`. On `{"unchanged":true}` do
nothing (no re-render); else store hash and `setState({...EMPTY_STATE, ...payload})`.
Model this on the existing `usePolling` (visibility-gated, replace-don't-blank) but
carry the `?hash=` cursor so an unchanged tick is a no-op. Expose `ready` (flips true
on first real payload) so toasts don't replay history on load — **prime on the first
ready tick** (record current events as already-seen). `lastChange` drives the "stale"
dimming of the heartbeat dot (>5 s).

### `Observatory.tsx` — layout

Two-pane: the **map** fills the main area; the **cockpit** is a right rail
(~20rem, scrollable). Combat panel and toasts are overlays. Header reuses the
monitor's `live-badge` + `envelope` footer (`last write … · schema v…`), so freshness
reads identically to the Knowledge tab.

---

## 6. The map (`map/layout.ts`, `map/MapView.tsx`)

### `layout.ts` — deterministic grid BFS

MUD space is non-Euclidean; the goal is *stable and legible*, not planar-correct.

- `DIR_VEC`: 8 compass dirs → unit grid vectors (north `[0,-1]`, northeast `[1,-1]`,
  …); `up`/`down` have no vector and render as `▲`/`▼` glyphs on the box. The keys are
  the **long-form** direction names — which is exactly what `room_exits.direction`
  stores, so no normalization layer is needed.
- BFS from `position` (or `rooms[0]` if position is null) at `(0,0)`. Each neighbor at
  `parent + DIR_VEC[dir]`; on collision **spiral-probe** the nearest free cell.
- Rooms unreachable through any link → **floating clusters** placed to the right.
- A link whose endpoints aren't exactly one vector apart is **bent** (a bezier bow);
  return `bent: Set<linkIndex>`.
- **Determinism:** same `(rooms, links)` → same positions. `useMemo` on `[rooms, links]`
  so the map is stable while it grows — it must not reshuffle.

### `MapView.tsx` — SVG scene, Z-ordered

Constants `CELL_W 148, CELL_H 108, BOX_W 104, BOX_H 62`. Draw order:

1. **Links** under everything (`var(--border)`, width 2; bent = quadratic bezier;
   ghost = dashed, faded). Non-ghost links draw-on via a `stroke-dashoffset` CSS
   keyframe.
2. **Trail** — recent traversed edges as thick round-capped `var(--accent)` lines,
   opacity ramping `0.06→0.46` oldest→newest so the route fades behind the agent.
3. **Frontier stubs** — for each room `exit` with no link, a short dashed stub + dot
   poking out of the box, `breathe` keyframe. This is what makes the map read as
   "still exploring."
4. **Rooms** — one `<g>` per room; **materialize** via CSS transition
   (`opacity/scale` on mount; position transitions so boxes glide when layout shifts).
   Rounded rect whose stroke/fill encode flags: `current` = accent stroke + fill +
   pulsing agent dot + glow; `death` = danger; `provisional`/`unsurveyed` = muted/dashed;
   `ghost` = dashed, transparent, italic name. `▲`/`▼` glyphs for up/down exits; name
   wraps to ≤3 lines. (Animation is CSS, not framer-motion — matching the app.)
5. **AgentCallout** on the current room: an **activity badge** below it (icon+detail
   colored per kind) and a **thought bubble** above it, suppressed once the thought is
   >300 s old (history, not intention).

### Camera — d3-zoom

`zoom().scaleExtent([0.3, 2.5])` writing the transform onto the inner `<g>`. A user
pan/zoom flips `follow` off. When `follow` is on and `position` changes, glide to
center the agent's cell (`transition().duration(800).ease(easeCubicOut)`). Controls:
`+ / − / ⌖ follow` bottom-left; hover tooltip = name + exits + confidence. `d3-zoom`/
`d3-selection` are the only new frontend deps.

---

## 7. Cockpit & overlays

### `Cockpit.tsx` (right rail)

Header (current room name, heartbeat dot, mode badge) → **activity strip**
(icon+detail) → **thought line** (age-dimmed past 120 s) → **vitals**: an HP bar
(color-steps green→amber→red at 50%/25%), and mana/move/level/gold/exp as **plain
figures** (no bars — no maxes in the schema; be honest about it) → **stat tiles**
Level / Gold / Deaths (deaths red when >0) → **plan** block: when `plan == null`, a
quiet "no active plan (task tracking not wired yet)" line, not an empty checklist →
**event feed** (last 8, reversed, icon+color by regex: DIED ☠, Killed ⚔, LEVEL ★,
gold ◆) → footer "N rooms mapped · polling 1s". All colors reference the monitor's
existing `--accent`/`--danger`/`--muted` tokens; the palette is extended, not forked.

### `overlays.tsx`

- **CombatPanel** — bottom-right, slides up when `combat` present, auto-scrolls,
  colors lines (your hits accent, damage danger, foe death good). On clear, read the
  outcome off the final lines (🏆/☠/🏃) and hold ~3.5 s before hiding.
- **TerminalDrawer** — bottom pull-up showing the raw `feed` (telnet game text) in
  green monospace, collapsed by default. Reuse the existing `Ansi` component if the
  feed carries escapes.
- **Toasts** — `freshEvents(prev, now)` via suffix-overlap on the rotating `events`
  window. New LEVEL → gold banner; a `deaths` increment → red death-vignette flash.
  **Gate on `ready`; prime on first payload** so page load never replays history.

Voice/TTS and the ink theme are **not** built here — see §9.

---

## 8. The look

Reuse the monitor's token palette (`--bg/--panel/--border/--text/--muted/--accent/
--danger/--track`, light+dark). Add only what the map needs — a dotted-grid plane
background, the `pulse-dot`/`breathe`/`draw-in`/heartbeat keyframes — into `index.css`
alongside the existing keyframes. No Tailwind, no framer-motion, no second theme.
Components never hardcode a color; everything references a token so light/dark both
work for free.

---

## 9. Deferred (designed-for, not built)

- **`plan` / task management** — field is `null` today; when tasks land in the stack,
  only §3.6 fills it. UI already renders the null case.
- **Voice narration + neural TTS** — the original `/speak` proxy + `useVoice`. Add
  later behind a config flag if wanted; nothing in the contract needs to change (add
  `tts?: boolean`).
- **Ink & Parchment theme** — a second palette + turbulence filter. Cosmetic; not now.
- **`.wld` ground-truth overlay** — the repo ships world files at
  `week0_explore/preview/data/world` (`cfg.world_dir`). A future "believed vs true"
  map could diff the knowledge graph against them. Deliberately out of scope: this tab
  shows *belief*, and belief is the interesting thing to watch.

---

## 10. Phasing (each step independently verifiable)

- **P0 — Contract.** `types.ts`: `ObservatoryState`, `EMPTY_STATE`, `Mode`;
  `fetchObservatory` in `client.ts`. *Done when* it compiles and the poller imports it.
- **P1 — Composer + tests.** `Observatory::State` + `Observatory::Activity`,
  `ObservatoryController#show` with hashing/conditional-GET; Minitest seeded from a
  fixture `knowledge.sqlite3` (reuse `knowledge_fixtures.rb`) + fixture manager/telnet/
  session jsonl. *Done when* the composer test suite is green: room/ghost derivation,
  vitals merge, deaths count, trail ordering, activity from position, combat foe+feed,
  hash stability under quantization.
- **P2 — Tab shell + poller.** Route, nav link, `Observatory.tsx`, `useObservatory`.
  *Done when* the tab renders the waiting state live and re-renders only on real change
  (verify `{"unchanged":true}` short-circuits).
- **P3 — Cockpit.** Vitals/tiles/events/thought/activity strip + null-plan case.
  *Done when* every field renders against a live/seeded frame.
- **P4 — Map.** `layout.ts` (+ a unit check on BFS/collision/bent), then `MapView`:
  links, trail, frontier stubs, room materialization, glows, camera follow, tooltip,
  callout. *Done when* growth/collision/ghost-halo/floating-cluster all render from a
  real `knowledge.sqlite3`.
- **P5 — Overlays.** Combat panel, terminal drawer, toasts (`freshEvents`). *Done when*
  a combat sequence fires its overlays exactly once with no replay on load.
- **P6 — Ship.** `npm run build`, **commit `web/dist/`** (the monitor commits its
  build), update the monitor README's page list.

---

## 11. Testing

Mirror the repo's existing knowledge tests. `test/support/knowledge_fixtures.rb`
already builds a real `knowledge.sqlite3` from `seed.sql`; extend it (or add a sibling)
with fixture manager/telnet/session jsonl so the composer sees all four sources.

The composer is the correctness spine — assert its exact output for:
exit expansion is a no-op (dirs already long-form), ghost synthesis from
frontier exits, no duplicate links, `current`/`death`/`provisional`/`unsurveyed`
flags, vitals merge with the absent maxes as null, `deaths` count,
trail order by `last_seen_at`, activity from each `position` value, `standing`
refined by the last manager command, combat foe + feed assembly, the thinking
overlay past the quiet threshold, and **hash stability** (two builds seconds apart
with only sub-quantum drift produce the same hash → `{"unchanged":true}`). Keep these
green through every change; extend them when you extend the composer.

---

## 12. Invariants

1. **The UI reads only the contract.** New UI fact ⇒ new contract field ⇒ composer
   fills it. The Observatory front end never calls `/knowledge`, `/sessions`, etc.
   directly.
2. **Read-only observer.** No writes to game/agent state, ever. `Knowledge::Reader` is
   already `query_only`; the composer adds no writes.
3. **The composer tests are law.** Green across every change.
4. **Hash stability.** Any per-second-jittering value is quantized before it reaches
   the hash.
5. **Prime before reacting.** Toasts record the first ready payload as already-seen.
6. **Determinism in layout.** Same graph ⇒ same positions.
7. **Graceful degradation.** No knowledge → waiting; no session → empty thought; no
   manager/telnet → activity from `position` alone; no tasks → `plan:null`; unknown
   position → `null` position banner.
8. **One source of resolution.** `boukensha_dir`, `knowledge_db`, and the log dirs come
   from the existing initializer — the composer never re-guesses paths.

## 13. Not now

`exp` sparkline; a command box injecting into the daemon; replay/scrubbing a past
session; multi-session comparison; the `.wld` ground-truth overlay; voice/TTS; the ink
theme. The contract leaves room for these — they need new fields, not a new
architecture.
