# OBSERVER — build spec for the MUD Observatory

## What this builds

A local web dashboard for **watching an agent play a MUD**: the map growing room
by room, the agent's position, vitals, plan, live activity (fighting / resting /
shopping / thinking), the real combat text, and the agent's own running
commentary — optionally spoken aloud. It is a pure **observer** — zero model
involvement, zero tokens — that renders what a play session already leaves on
disk. It never talks to the game server, never writes to the agent's memory, and
the playing agent doesn't know it exists.

This document is a complete, self-contained specification: exact JSON shapes,
magic numbers, easing curves, the localizer algorithm, the layout math, and a
build order in which every step is independently verifiable. It is written to be
precise enough that a mid-tier executor can build the tool to the intended
quality without inventing any of the details — the polish lives entirely in the
specifics named here.

Target location: `week0_explore/visualizer/`, self-contained; nothing else in
the repo depends on it.

## The one idea everything hangs on

There is exactly **one contract** — the JSON returned by `GET /state`. The UI
knows *only* that contract. The server-side adapter absorbs *all* knowledge of
the play-mud skill's file formats. This single seam is what makes the tool
buildable in isolation and portable to a future loop: swap the readers in
`serve.py`, or write contract-shaped JSON directly, and the front end never
changes.

Two consequences the executor must respect at all times:

1. **The front end never reads a skill file.** If a UI component needs a fact,
   that fact must first exist as a field in the contract.
2. **The observer never writes.** It only reads files the play session already
   produces. It never talks to the game server, never mutates the agent's
   memory. The playing agent does not know it exists.

## Runtime shape

```
serve.py   stdlib HTTP server (no pip deps), port 8790
 ├─ GET /state   the adapter — merges all sources into the contract,
 │               sha1-hashed; ?hash=<h> → {"unchanged": true} when nothing moved
 ├─ GET /speak   OpenAI TTS proxy, on-disk cache (.tts_cache/)
 └─ GET *        serves dist/ (the built React app; SPA fallback to index.html)

world.py   the "omniscient observer" layer (imported by serve.py when enabled)
 ├─ parse_wld_dir  tbaMUD .wld files → {vnum: {title, exits{dir: vnum}}}
 └─ Localizer      replays the transcript, narrowing a belief-set of candidate
                   vnums, to pin the agent to an exact room

src/       React 18 + TS + Tailwind v4 + d3-zoom + framer-motion (Vite build)
```

Runtime is **Python-only**: `dist/` is committed, so `python3 serve.py` is the
whole run story. Node is a dev-time dependency for rebuilding the UI only.

Exact dependency versions (from `package.json`): react `^18.3.1`,
framer-motion `^11.18.0`, d3-zoom/d3-selection/d3-transition/d3-ease `^3`,
tailwindcss `^4.1` (via `@tailwindcss/vite`), vite `^6`, typescript `^5.6`.

---

## 1. The contract (`src/state.ts`)

This is the spine. Define it first; nothing else is meaningful without it.

```ts
interface RoomC   { title: string; exits: string[]; flags: string[]; hazards: string[]; }
                  // exits: full dir names ("north", "up"…). flags ⊂ {hazard, death, dark, ghost}.
interface LinkC   { from: string; dir: string; to: string; ghost?: boolean; }
                  // ghost: known from an `exits` peek, never actually walked.
interface PlanStep{ text: string; check?: string | null; done: boolean; }
interface Vitals  { hp,max_hp,mana,max_mana,moves,max_moves,gold,xp,xp_to_next,level: number|null; }
type ActivityKind = "fighting"|"resting"|"shopping"|"reading"|"exploring"
                  | "thinking"|"dead"|"busy"|"idle";
interface Activity{ kind: ActivityKind; detail: string; }

interface StateC {
  rooms: Record<string, RoomC>;      // key = room identity (title, or vnum in world mode)
  links: LinkC[];
  trail: LinkC[];                    // recent moves, oldest first (for the fading route line)
  position: string | null;          // null = agent's location is unknown (darkness)
  vitals: Vitals;
  deaths: number;
  events: string[];                  // rotating window, capped server-side
  plan: { goal: string; steps: PlanStep[] } | null;
  thought: string;
  conditions: string[];             // hungry/thirsty/drunk, from last `score`
  thought_age_s?: number | null;
  activity: Activity | null;
  combat: { foe: string; lines: string[] } | null;
  feed: string[];                   // last raw game lines (terminal drawer)
  quiet_seconds: number | null;
  tts?: boolean;                    // server-side OpenAI TTS is configured
  hash?: string;
}
```

Also export `EMPTY_STATE` (all-empty instance) and `type Mode = "live"|"demo"|"waiting"`.
The UI always spreads `{...EMPTY_STATE, ...payload}` so a partial/legacy payload
never yields `undefined` fields.

**Identity rule:** a room's key *is* its identity. In fallback mode the key is
the title (so duplicate titles merge — accepted). In world mode the key is the
vnum (so five same-titled "Main Street" segments stay five nodes). The UI does
not care which; it only ever compares keys.

---

## 2. The poller (`src/state.ts`, `useGameState`)

- 1 Hz `fetch('./state?hash=<lastHash>')`. On `{"unchanged": true}`, do nothing
  (no re-render). Otherwise store the new hash and `setState({...EMPTY_STATE, ...j})`.
- `mode`: `"live"` if `rooms` non-empty, else `"waiting"`; `"demo"` when the URL
  has `?demo=1`.
- Expose `ready: boolean` — flips true on the *first* real payload. Toasts and
  voice must not fire against the empty initial state; they gate on `ready` and
  "prime" (record current-as-seen) on the first ready tick so history is not
  replayed as if it just happened.
- `lastChange` timestamp drives the "stale" indicator (>5 s → heartbeat dims).
- In demo mode, ignore the network entirely: advance `demoFrame(tick)` every
  1100 ms, `tick = (tick+1) % DEMO_TICKS`.

---

## 3. The adapter: `serve.py` → `read_state(data_dir)`

Reads these, all optional; **any missing source degrades silently**:

| File | Shape read | Feeds |
|---|---|---|
| `<data>/.mud_memory.json` | `rooms{}`, `char{}`, `trail[]`, `events[]`, `current_room`, `deaths`, `thought`, `thought_at`, `conditions` | most of the contract |
| `<data>/player.md` | one line matching `HP (\d+) · Mana (\d+) · Moves (\d+)` | live hp/mana/moves |
| `<data>/plan.json` | `goal`, `subtasks[{text,check,done}]` | plan panel |

### Room / link / ghost derivation

Each store room has an `exits` *string* like `"n e (s)"` and a `links` map
`{dir: dest}`. Expand exit tokens through the direction table
(`n→north … ne→northeast`), stripping `()` (a parenthesized exit is a door).
Build a `RoomC` keyed by title; push a `LinkC` per walked link.

- `flags`: add `"hazard"` if the room has any `hazards` note; add `"death"` if
  any note contains `"death"`.
- **Ghost rooms** come from `peeks` (`{dir: dest}` learned from an `exits`
  command but never entered). For each peek whose dir isn't already a walked
  link: if `dest` isn't a real room, synthesize a room `{flags:["ghost"], exits:[]}`,
  and add a `ghost:true` link. Do **not** duplicate a link the agent walked.

### Trail

`store.trail` is lines like `"north: A Room → B Room"`. Parse with
`^(\w+): (.*) → (.*)$`; **drop** any whose destination contains `(darkness)`.

### Vitals

Integers come from `char{}` (level, gold, xp, xp_to_next, max_hp/mana/moves) via
a tolerant `_int` (bad/absent → `null`). Live hp/mana/moves come from the
`player.md` regex and *override* the maxes' companions.

### Thought + age

`thought` from the store; `thought_age_s = (now - thought_at) // 15 * 15` —
**quantized to 15 s** so the content hash doesn't churn every second. Same
quantization idea applies to `quiet_seconds` (`//5*5`) and narration age.

### Hashing / conditional GET

Serialize the state with `json.dumps(sort_keys=True)`, `sha1`, take the first 16
hex chars. If the request's `?hash=` equals it, return `{"unchanged": true}`;
else attach `hash` and return the full payload. **All the `//15`, `//5`
quantizations exist to keep this hash stable while values are "basically the
same," so the client re-renders on real change only.**

### `--selftest` is the correctness spine

`serve.py --selftest` builds a fixture store in a temp dir and asserts the exact
adapter output (exit expansion, hazard/death flags, ghost synthesis, no-dup
links, trail darkness-drop, vitals merge, plan check passthrough) *and* activity
derivation (fighting→resting transition, combat foe, feed). **The executor
should port these asserts first and keep them green through every change.** They
are the machine-checkable definition of "the adapter is correct."

---

## 4. Activity derivation (`serve.py` → `derive_activity`)

No skill cooperation: tail `~/.play_mud/<host>_<port>/transcript.log` (last
~20 KB) and *infer* what the agent is doing. The transcript interleaves
`[SENT] <command>` lines with the game's replies.

- Find the **last `[SENT]`** and collect every game line *since* it. `word` =
  its first token, `arg` = the rest.
- **fighting** if `word ∈ {kill,hit,attack,bash,kick,backstab,cast}` and no
  `is dead!/You are dead!/You flee` has appeared since — *or* any of the last 4
  lines matches `COMBAT_LINE_RE` (hits/misses/slash/pierce/parry/dodge/death
  cry…). Emits `combat = {foe: arg||"enemy", lines: <last 25 non-blank>}`.
- **dead** if a recent line has `"You are dead!"` → `"died — corpse run ahead"`.
- **resting** (`rest/sleep/sit`), **shopping** (`list/buy/sell/value`),
  **reading** (`read/examine`, or `look <arg>`), **exploring** (a direction or
  bare `look`), else **busy** (echo the raw command), else **idle**.
- `quiet_seconds` = `now - transcript_mtime`, quantized `//5*5`.
- **thinking overlay:** if quiet > 15 s and not dead/resting → override with
  `"quiet for Ns — deciding the next move"`. If `plan.json`/`player.md` was
  touched in the last 20 s, refine to `"off-game: updating its plan"` /
  `"writing notes/goals"` — the agent is working in its memory, not stuck.
- `feed` = last 40 non-blank transcript lines (drives the terminal drawer).

---

## 5. World mode & the Localizer (`world.py`)

This is the layer that makes the map *truthful*. Optional (`--world off`
disables it and falls back to the title-keyed map from §3).

### `.wld` parsing (`parse_wld_file`)

tbaMUD room files are records: `#<vnum>`, then a `~`-terminated title, then a
`~`-terminated description, a flags line, then `D0..D5` door blocks (each: two
`~`-terminated blocks, then a numeric line whose **3rd int is the destination
vnum**, `<0` meaning none), terminated by `S`. Door index → direction via
`DIR_NAMES = [north, east, south, west, up, down]` (this order is the tbaMUD
convention — do not reorder). Read files as `latin-1`. Output:
`{vnum: {title, exits: {dir: to_vnum}}}`.

### Localization by belief-set narrowing (`Localizer`)

The observer knows the true graph but must still figure out *which* room the
agent is in from the transcript alone (it can't see the agent's coords).

- **belief** = set of candidate vnums. Index rooms `by_title`.
- Strip prompts (`\d+H \d+M \d+V…> `) to newlines. On `[SENT] <dir>`, record a
  `_pending_move`. On an `[ Exits: … ]` line, a room was displayed → recover its
  **title** (walk back to the line after the last blank/`[SENT]` boundary; reject
  if >60 chars or ends in punctuation — that's prose, not a title).
- Filter belief by title; if there was a pending move, first advance the belief
  along that edge in the graph, then intersect with the title's candidates. If
  the graph disagrees (empty intersection), treat as a teleport (drop the move).
- **Collapse:** when belief narrows to exactly one vnum, position is *exact* →
  add to `visited`; if we arrived by a known move from a known room, record the
  walked `edge` and push to `trail` (keep last 15).
- **Backfill:** if we were ambiguous for several steps and then collapse, walk
  the ambiguous move-chain *backwards* through the graph — where each step has a
  unique predecessor — to recover the visited rooms and edges we passed through
  blind.
- **Hazards:** `"It is pitch black"` after a move → record
  `"darkness through <dir>"` on the current room and blank the belief (position
  unknown until the next room display). `"You are dead!"` → `"a death occurred
  here"`.

### `world_map()` — what world mode puts in the contract

- `rooms`: every `visited` vnum (keyed by `str(vnum)`), plus a **one-ring ghost
  halo** — for each exit of a visited room leading somewhere not yet visited,
  synthesize a `ghost` room and a `ghost:true` link (a truthful preview of
  unexplored neighbors).
- `links`/`trail`/`position` from the localizer's exact edges.

`WorldTracker.update()` tails the transcript incrementally (seek from last
offset; reset the Localizer if the file shrank or vanished). `read_state` calls
it and, when world mode is on, **replaces** rooms/links/trail/position with the
localized versions before deriving activity.

---

## 6. Narration harvest (`serve.py` → `latest_narration`)

The agent narrates richly in its Claude Code responses but rarely double-reports
into a side channel. So harvest it: glob `~/.claude/projects/*02*agent*skills*`,
take the freshest dir, tail the newest `*.jsonl` (~150 KB), find the **last
`type:"assistant"` message**, join its `text` blocks, truncate to 220 chars
(…), compute age from its timestamp (quantized `//15`). In `read_state`, if this
narration is *fresher* than the store's voiced thought, it wins the `thought`
field. Principle: **harvest what the agent already produces; never ask it to
remember to report.**

---

## 7. The map (`src/map/`)

### Layout (`layout.ts`) — deterministic grid BFS

MUD space is non-Euclidean, so a clean planar layout is impossible; the goal is
*stable and legible*, not correct.

- `DIR_VEC`: 8 compass dirs → unit grid vectors (north `[0,-1]`, etc.; up/down
  have no vector — rendered as glyphs on the box).
- BFS from `keys[0]` placed at `(0,0)`. Each neighbor goes at `parent + dirVec`;
  on collision, **spiral-probe** the nearest free cell (rings out to r<40).
- Rooms not reachable through any link become **floating clusters** placed to
  the right (`maxX + 3`).
- A link is **bent** when its endpoints don't sit exactly one direction-vector
  apart (a collision displaced one end). Return `bent: Set<linkIndex>`.
- **Determinism matters:** same `(rooms, links)` → same positions, so the map is
  stable while it grows. `useMemo` on `[rooms, links]`.

### MapView (`MapView.tsx`) — the SVG scene, drawn in Z-order

Constants: `CELL_W 148, CELL_H 108, BOX_W 104, BOX_H 62`. `px/py` map grid→pixels.

1. **Links** under everything. `stroke var(--link-stroke)`, width 2. Bent links
   are a quadratic bezier bowed along the direction vector (`Q` control at
   `±0.9·CELL`); straight links a line. Ghost links: dashed `4 5`, opacity .65.
   Non-ghost links get the `link-draw` class (stroke-dashoffset draw-on, §9).
2. **Trail** — recent moves as thick (`4`) round-capped `var(--accent)` lines,
   opacity ramping `0.06 → 0.46` oldest→newest so the route fades behind the
   agent. In the ink theme it dashes (`--trail-dash`).
3. **Frontier stubs** — for each room exit with no corresponding link, a short
   dashed stub + dot poking out of the box edge, wrapped in `.frontier-stub`
   (breathing animation). This is what makes the map read as "still exploring."
4. **Rooms** — `motion.g` per room; **materialize** with
   `initial {opacity:0, scale:0.4} → animate {opacity:1, scale:1, x, y}`,
   `spring stiffness 260 damping 24` (position is animated too, so rooms glide
   if the layout shifts). A rounded rect (`rx 8`) whose stroke/fill encode state:
   current = accent stroke + filled + pulsing `agent-dot` + `room-glow`; death =
   critical; hazard = warning; ghost = dashed, transparent, italic title; dark =
   a big `?` instead of the title. Title text wraps to ≤3 lines (17-char width).
   `⚠` badge on hazard/death; `▲`/`▼` glyphs for up/down exits.
5. **AgentCallout** follows the current room: an **activity badge** below it
   (icon+detail, colored per `ACTIVITY_META`) and a **thought bubble** above it
   (spring `300/22`), suppressed once the thought is >300 s old (history, not
   intention).

### Camera — d3-zoom owns the transform

- `zoom().scaleExtent([0.3, 2.5])`; the `zoom` handler writes `e.transform` onto
  the inner `<g>`. A user pan/zoom (`e.sourceEvent` present) flips `follow` off.
- When `follow` is on and the position changes, glide: `zoomIdentity` translate
  so the agent's cell is centered, keep current scale (min 0.6),
  `transition().duration(800).ease(easeCubicOut)`. This slow camera glide after
  the pulsing marker is a big part of the "watchable" feel.
- Controls: `+ / − / ⌖ follow` buttons bottom-left; hover tooltip with title +
  exits + hazard notes.

---

## 8. The cockpit & overlays

### Cockpit (`cockpit/Cockpit.tsx`) — right rail, 20rem, scrollable

Header (title `MUD OBSERVATORY`, current room, theme 🗺️/🌑 toggle, voice
🔊/🔇 toggle, **heartbeat dot** that pulses live / dims when stale, mode badge)
→ activity strip → thought line (blinking caret while <45 s old, "(Nm ago)"
past that, dimmed past 120 s) → **vitals bars** (hp color-steps green→amber→red
at 50%/25%; mana; moves; condition chips) → **stat tiles** (Level / Gold /
Deaths, deaths red when >0) → **XP bar** → **plan checklist** (current step =
accent left-border + tint; done = struck-through; `✓` pops via a `scale:1.6→1`
spring) → **event feed** (last 8, reversed, each slides in `x:24→0`, older ones
fade, icon+color by regex: DIED☠red, Killed⚔green, LEVEL★amber, gold◆) → footer
"N rooms mapped · polling 1s".

### Overlays (`overlays.tsx`)

- **CombatPanel** — bottom-right docked panel, slides up when `combat` present,
  auto-scrolls, colors lines (your hits accent, taking damage red, foe death
  green). When combat clears, read the outcome off the final lines
  (`🏆 victory / ☠ defeated / 🏃 fled`) and hold 3.5 s before hiding.
- **TerminalDrawer** — bottom-center pull-up showing the raw `feed` in green
  monospace on near-black. Collapsed by default.
- **Toasts** — `freshEvents(prev, now)` finds new events by **suffix overlap**
  (the feed is a rotating capped window, so "what's new" = the part of `now` not
  matching a tail of `prev`). New `LEVEL UP` → gold banner top-center (3 s). A
  `deaths` increment → full-screen red **death vignette** flash
  (`inset boxShadow rgba(208,59,59,.55)`, 1.3 s). Gate on `ready`; prime on
  first payload so load doesn't replay history.
- **useVoice** — optional narration. Speaks the newest thought; **deaths and
  level-ups outrank** commentary ("We died." at low pitch; the level line at
  high pitch). Never queues (new line cancels current); never repeats a line
  within 30 s. Prefers server-side neural TTS (`./speak`, §10) and falls back to
  browser `speechSynthesis`, picking the least-robotic installed voice
  (Premium/Enhanced/Google/named voices before compact defaults).

---

## 9. The look — tokens, themes, animations

The screenshots look "designed" because the visual system is explicit and small.
Reproduce it exactly.

**Dark theme tokens** (`:root`, the validated dataviz dark palette, by role):
`--plane #0d0d0d, --surface #1a1a19, --surface-2 #222220, --ink #fff,
--ink-2 #c3c2b7, --ink-3 #898781, --grid #2c2c2a, --hairline rgba(255,255,255,.1),
--accent #3987e5 (agent/current/mana), --aqua #199e70 (moves), --gold #c98500,
--good #0ca30c, --warning #fab219, --serious #ec835a, --critical #d03b3b`.
The map plane is a dotted grid (`radial-gradient` dots, 26px). Everything else
references tokens — components never hardcode a color.

**Named keyframes** (all in `index.css`):
- `pulse-dot` 1.6s — agent marker scales 1→1.6, fades (`.agent-dot`).
- `breathe` 2.6s — frontier stubs opacity .25↔.8 (`.frontier-stub`).
- `draw-in` .55s — links draw on via `stroke-dashoffset: var(--len)→0`
  (`.link-draw`; `--len` is set per-link from its pixel length).
- `hb` 1s — heartbeat dot expanding box-shadow ring (`.heartbeat-live`).
- `caret-blink` 1.1s step-end — the thought caret.
- `.bar-fill` — width transition `.7s cubic-bezier(.22,1,.36,1)` so bars ease.
- Glows via `drop-shadow`: `room-glow` blue 7px, `hazard-glow` amber 5px,
  `death-glow` red 6px.

**Framer springs** (don't substitute tweens): rooms `stiffness 260 damping 24`;
thought bubble & `✓` pops `~300/22`; feed/badge slide-ins short duration tweens.

**Ink & Parchment theme** (`html.theme-ink`, toggled by 🗺️, persisted in
`localStorage`, or `?theme=ink`): re-skins the *same* markup as a cartographer's
chart — aged-paper plane (layered radial vignettes + an inline SVG
`feTurbulence` grain data-URI), an `#ink-rough` `feDisplacementMap` filter
applied to every `.ink-stroke` (rooms + links wobble like hand-drawn ink), serif
lettering, heraldic-red route/agent/current-step, a dashed red expedition trail,
wax-red hazards. It's a full second palette + the turbulence filter — the same
components, no structural change.

---

## 10. TTS proxy (`serve.py` → `/speak`, `tts_synthesize`)

Config from git-ignored `.env`/`.env.local` (`.local` wins):
`OPENAI_API_KEY`, optional `TTS_VOICE` (default `nova`), `TTS_MODEL`
(default `tts-1`). `GET /speak?text=` → POST OpenAI `/v1/audio/speech`, return
mp3. **On-disk cache** keyed by `sha1(text)` so repeats are free. No key → 503,
and the client silently uses browser TTS. `state.tts` tells the UI which path is
live.

---

## 11. Demo mode — build this *early*, it is the leverage

`?demo=1` runs `demoFrame(tick)` — a scripted ~40-step session with **zero game
and zero server** that exercises every visual: rooms materializing, a collision
with a bent connector, an up-stub, a floating cluster (recall scroll), darkness
(`position:null`), a two-round combat with falling HP → kill → loot, a death +
vignette + hazard mark, a level-up banner, plan steps completing, thoughts, a
condition chip. `DEMO_TICKS = SCRIPT.length + 4` (holds the final frame).

Why early: it is the **only way to see and verify the entire UI without a running
MUD**, and it is the natural way to capture screenshots. Once the poller and demo
exist, every subsequent front-end phase is visually
testable by opening `?demo=1`. Treat the demo script as a *second contract*: it
must emit legal `StateC` frames, so it doubles as living documentation of the
contract's shape.

---

## 12. Build order (each step independently verifiable)

Ordered so correctness is checkable at every stop and the UI is always runnable.

- **P0 — Contract.** `state.ts`: types, `EMPTY_STATE`, `Mode`. *Done when* it
  compiles and the demo/poller can import it.
- **P1 — Adapter + selftest.** `serve.py` static serving + `read_state` reading
  `.mud_memory.json`/`player.md`/`plan.json`, hashing, conditional GET; port the
  full `--selftest`. *Done when* `python3 serve.py --selftest` prints `OK`.
- **P2 — Shell + poller + demo.** Vite/React/Tailwind scaffold, `useGameState`,
  and `demo.ts`. *Done when* `?demo=1` cycles frames and a live server shows the
  waiting state. **Build the demo here so P3–P5 are all visually verifiable.**
- **P3 — Cockpit.** Vitals bars, tiles, XP, plan, events, header/heartbeat,
  thought line. *Done when* every field animates correctly under `?demo=1`.
- **P4 — Map.** `layout.ts` (+ a tiny unit check on BFS/collision/bent), then
  `MapView`: links, trail, frontier stubs, room materialization, glows, camera
  follow, tooltips, callout. *Done when* the demo's growth/collision/darkness/
  floating-cluster all render as described.
- **P5 — Overlays.** Combat panel, terminal drawer, toasts (`freshEvents`),
  voice (browser only for now). *Done when* the demo's combat/kill/level-up/
  death all fire their overlays exactly once (no replay on load).
- **P6 — Activity derivation.** `derive_activity` + its selftest asserts.
  *Done when* a fixture transcript drives fighting→resting and combat/feed.
- **P7 — World mode.** `world.py` (`.wld` parse + Localizer + WorldTracker),
  wired into `read_state`. *Done when* a replayed transcript keeps same-titled
  rooms distinct and shows the ghost halo; `--world off` still works.
- **P8 — Narration harvest.** `latest_narration`, freshest-wins in `read_state`.
- **P9 — Ink theme + neural TTS.** Second palette + `#ink-rough` filter; `/speak`
  proxy + cache; upgrade voice to prefer server TTS.
- **P10 — Ship.** `npm run build`, **commit `dist/`** (runtime stays Node-free),
  update the README's run/flags/sources tables.

CLI flags to preserve: `--data`, `--transcript`, `--world <dir>|off`,
`--cc <dir>|auto|off`, `--port` (8790), `--selftest`.

---

## 13. Invariants the executor must not break

1. **The UI reads only the contract.** New UI fact ⇒ new contract field ⇒
   adapter fills it. Never `fetch` a skill file from the browser.
2. **Read-only observer.** No writes to game/agent state, ever.
3. **The selftest is law.** It stays green across every change; extend it when
   you extend the adapter.
4. **Hash stability.** Any per-second-jittering value must be quantized before it
   reaches the hash, or the client re-renders every tick.
5. **Prime before reacting.** Toasts/voice record the first ready payload as
   "already seen" so page load never replays history as new events.
6. **Determinism in layout.** Same graph ⇒ same positions; the map may not
   reshuffle as it grows.
7. **Graceful degradation.** Every missing source has a defined fallback
   (no store → waiting; `--world off` → title map; no key → browser TTS;
   darkness → `position:null` banner).
8. **Runtime is Python-only.** `dist/` is committed; changing `src/` requires a
   rebuild + recommit.

## 14. Not now

XP sparkline; a command box injecting into the daemon's control socket;
replay/scrubbing a past session; multi-session comparison. The contract already
leaves room for these — they need new fields, not a new architecture.
