## Knowledge Map

We want in our mud monitor a new tab under Knowledge called Map

http://localhost:5173/knowledge/map

Its suppose to show the map as known by the agent's memory.

- nodes should be organized based on their exits. If a node is suppose to be north of node please do that the best you can.
- We should see the name of the room. if no name fallback to truncated version of the room
- Its room number that we internally store should be on the node
- the amount of visit ons on the node
- list of entitires and look targets within the node
- the current node where the user is highlighted.
- it should have indiication of frontiers so we can see where the user has yet to go.

## Technical Solution

A seventh sub-view under Knowledge, at `/knowledge/map`. It is a **pure
frontend feature**: no new endpoint, no reader change, no new dependency. The
entire cost is one layout function and one renderer.

---

### 0. What already exists

`knowledge_tab.md` shipped the whole data path, and three of its decisions
settle most of this plan before it starts:

1. **The endpoint already returns a graph.** §4 of that plan deferred the map
   explicitly — *"`/knowledge/rooms` already returns nodes (`id`, `name`) and
   edges (`exits[]` with `target_room_id`), so the map is a renderer added later
   over an unchanged endpoint."* That is still true. `KnowledgeRoom`
   (`web/src/api/types.ts:464`) carries `id`, `name`, `description`,
   `visit_count`, `look_candidates`, `entities`, `confidence`, `surveyed_at`,
   and `exits[]` — every field the seven bullets above ask for.
2. **The player pin already has a source.** `GET /knowledge` returns
   `player.current_room` (`reader.rb:211`), a `RoomRef` of `{id, name}`.
3. **Profile scoping is free.** `knowledge_db` is resolved per-profile in
   `application_controller.rb:37`, so the map shows the selected profile's
   world with no work. The live DB used for the numbers below is
   `.boukensha/profiles/Dummy/knowledge.sqlite3`.

Also inherited and not re-litigated: `usePolling` (3s, visibility-gated),
`useReportEnvelope`, `KnowledgeEmpty`, the `knowledge_schema_mismatch` banner,
and the `.tag` / `.empty` / `.error` CSS idiom.

#### 0.1 What the real data looks like

Numbers from the live file, because two of them change the design:

| | |
|---|---|
| rooms | 26 |
| exits | 73 |
| frontier exits (`target_room_id IS NULL`) | **41 — more than half** |
| directions in use | south 21, north 17, west 16, east 16, **down 2**, **`(s)` 1** |
| planar extent after layout | 7 × 10 cells, **1 component, 0 collisions** |

Two of those are load-bearing:

- **`direction = "(s)"`** is in the table right now (room 26, no target, 0
  traversals). `room_parser.rb:360` normalises with `DIRECTIONS[tok] || tok`, so
  any autoexit token it doesn't recognise is stored verbatim — parenthesised
  tokens (closed doors, in the autoexit line) fall straight through. The map is
  not the place to fix that, but it **must not assume `direction` is one of ten
  known strings**. See §11.
- **Frontier is the majority of edges.** A frontier marker designed for "a few
  unexplored doors" will bury the map in 41 dangling arrows on a 26-room world.
  §6 is sized for that, not for the pretty case.

---

### 1. The central decision: no new endpoint, no new dependency

**No endpoint.** The map polls the two endpoints that already exist:

```ts
// web/src/api/client.ts
export function fetchKnowledgeMap(): Promise<KnowledgeMapPage> {
  return Promise.all([ fetchKnowledgeRooms({ limit: 1000 }), fetchKnowledge() ])
    .then(([ rooms, overview ]) => ({ ...rooms, player: overview.player }));
}
```

One `usePolling` tick, two requests, the rooms envelope published upward. The
alternative — a `knowledge#map` action returning a slimmer node/edge payload —
buys nothing at 26 rooms and costs a controller action, a reader method, a
serializer shape, and a test file that all restate `#rooms`.

The trigger to revisit is payload size, and it is worth naming so nobody
guesses: `/knowledge/rooms` ships full `description` text for every room. At
~1KB/room that is fine to 200 rooms and wasteful past ~500 polled every 3s. The
fix at that point is a `fields=map` param that drops `description` and
`entities[].descr` from the existing action — **not** a second action, and not
SSE (`knowledge_tab.md` §3.6 settles that: a snapshot has no cursor to tail).

**No dependency.** `mud_monitor.md` §8 named `@xyflow/react` + `dagre`. Both are
wrong for this, and §8 should be amended to point here:

| | Why it fights us |
|---|---|
| `dagre` | It is a *layered DAG* layout: it assigns ranks and minimises edge crossings. That is precisely the thing we do not want. The requirement is "if a node is supposed to be north of a node, put it there" — the data carries real geometry, and dagre's whole job is to discard geometry in favour of its own ranking. Using it means throwing away the only spatial information the agent has. |
| `@xyflow/react` | Buys pan/zoom, node rendering, and edge routing. We want HTML nodes (§5 — chips, links, wrapping text, existing `.tag` CSS), which in xyflow means custom node components anyway; and pan/zoom over a CSS transform is ~40 lines. `web/` has **three** runtime deps (react, react-dom, react-router). These two would be the largest in the bundle, to render 26 boxes. |

The layout we need is a hundred lines of BFS over a grid (§3), and it is
*better* than either library for this data because it is the only one that
honours north.

---

### 2. Files

```
web/src/pages/knowledge/
├── Map.tsx          # NEW — page: toolbar, viewport, pan/zoom, states
├── MapNode.tsx      # NEW — one room box
├── layout.ts        # NEW — pure: rooms[] -> placed nodes, edges, stubs
└── Knowledge.tsx    # + one TABS entry
web/src/api/
├── client.ts        # + fetchKnowledgeMap
└── types.ts         # + KnowledgeMapPage, and layout.ts's own types
web/src/App.tsx      # + <Route path="map" element={<Map />} />
web/src/index.css    # + .knowledge-map* under the existing Knowledge section
```

No Ruby changes at all.

`layout.ts` is deliberately a **pure module with no React import**. It is the
only genuinely algorithmic code in `web/`, and keeping it a `rooms[] → geometry`
function is what makes it testable (§9) and what keeps `Map.tsx` about
rendering.

---

### 3. Layout: BFS over an integer grid

```ts
export interface PlacedNode { room: KnowledgeRoom; cx: number; cy: number; component: number }
export interface PlacedEdge {
  from: number; to: number; direction: string;
  planar: boolean;      // false = up/down/unknown token: geometry can't show it
  displaced: boolean;   // true  = the target cell was taken; this edge lies
  traversals: number;
}
export interface FrontierStub { roomId: number; direction: string; label: string; free: boolean }
export function layoutRooms(rooms: KnowledgeRoom[]): MapLayout
```

**Direction vectors** — exactly the eight planar values in
`room_parser.rb:44`, which is the only writer of this column:

```ts
const V: Record<string, [number, number]> = {
  north: [0,-1], south: [0,1], east: [1,0], west: [-1,0],
  northeast: [1,-1], northwest: [-1,-1], southeast: [1,1], southwest: [-1,1],
};
```

Anything not in `V` — `up`, `down`, `"(s)"`, whatever the parser stores next —
is **non-planar**: it never displaces a cell and never throws.

**The walk.** Sort rooms by `id`. Anchor at the lowest id, place it at the
origin, BFS outward; for each exit with a known `target_room_id` not yet placed,
put the target one cell along its vector. Repeat from the lowest unplaced id
until every room is placed.

Three properties, each of which is a decision:

- **Determinism is a hard requirement, not a nicety.** The page repolls every
  3s and re-runs the layout on data that changes underneath it. If the anchor or
  the visit order can shift, nodes teleport between ticks and the map is
  unusable. So: anchor = lowest room id, queue ordered by `(room_id, direction)`
  with a fixed direction ordering, no `Object.keys` iteration, no `Set`
  ordering, no `Date.now()`. Given the same rooms array, `layoutRooms` returns
  the same coordinates, always.
- **The anchor is the first room the agent ever saw, not the player.** Room
  ids are assigned in discovery order, so id 1 is a stable landmark. Anchoring
  on the player would slide the entire world sideways every time the agent walks
  through a door. Keeping the player centred is a *viewport* concern (§4), and
  that is where it belongs.
- **Collisions resolve to the nearest free cell and say so.** MUD geometry is
  non-Euclidean: two exits will eventually land two different rooms on the same
  square. When the wanted cell is taken, spiral out to the nearest free one,
  place there, and mark the edge `displaced: true`. §7 renders those distinctly.
  The map is allowed to be approximate — the requirement says "the best you can"
  — but it is **not** allowed to be quietly wrong, and a displaced edge is the
  one place the picture stops matching the data.

**Disconnected components** get laid out independently and packed left-to-right
by bounding box with a visible gutter, ordered by anchor id. Islands are not a
rendering failure; they are what fingerprint mis-resolution *looks like*, and
the room the resolver split in two should be visibly floating.

**Non-planar targets.** An `up`/`down` exit to an already-placed room just draws
a non-planar edge. To an *unplaced* room, place it at the nearest free cell to
its source and mark the edge non-planar — a vertical neighbour drawn adjacent
with an explicit "this is a stairwell, not a step west" style beats leaving it
in a separate island.

**Verification.** This algorithm was prototyped against the live 26-room file
before writing this section: **1 component, 0 collisions, extent 7×10**. Today's
world lays out exactly, with no lies in it. That is a good result and a
misleading one — it means the collision and multi-component paths have **no
real-data coverage** and must be tested synthetically (§9).

---

### 4. Rendering: SVG edges under absolutely-positioned HTML nodes

One transformed wrapper holds both layers, so pan/zoom is a single
`transform: translate(x,y) scale(k)` and the two layers can never drift:

```tsx
<div className="knowledge-map-viewport" onPointerDown={...} onWheel={...}>
  <div className="knowledge-map-world" style={{ transform: `translate(${x}px,${y}px) scale(${k})` }}>
    <svg className="knowledge-map-edges" width={w} height={h}>…</svg>
    {nodes.map(n => <MapNode key={n.room.id} … />)}
  </div>
</div>
```

Edges in SVG because they want dashes, markers and arrowheads. Nodes in HTML
because they are wrapping text, `<Link>`s and `.tag` chips — the same markup
`Rooms.tsx` already renders, which in SVG would mean `foreignObject` or manual
text measurement.

**Viewport controls:** drag to pan (pointer events, captured), wheel to zoom
about the cursor, scale clamped `0.3–2`. Toolbar: `Fit`, `Center on player`,
`Show frontier` toggle, `Detail` toggle.

**Follow-the-player is sticky-off.** On first load, centre on the player's
room. Keep re-centring as it moves — until the user pans or zooms once, after
which follow stays off until they press `Center on player`. Yanking the viewport
out from under someone who is reading it is the worst thing this page could do.

**Level of detail.** Below `scale 0.6`, nodes drop description, entity chips and
look-target chips and keep only `#id` and name. 26 rooms never needs this; 300
rooms zoomed out is unreadable soup without it, and the threshold is one
comparison.

---

### 5. The node

Each bullet in the brief, and where it comes from:

| Shown | Source | Notes |
|---|---|---|
| Room name | `room.name` | **Fallback:** `name.trim() \|\| truncate(description, 40) \|\| "#" + id`. `truncate` already exists (`format.ts:18`). |
| Internal room number | `room.id` | Always visible, never hidden by LOD — it is the id you paste into chat and the key for `/knowledge/rooms/:id`. |
| Visit count | `room.visit_count` | A `×N` chip. Doubles as a heat signal: `visit_count` drives a subtle background ramp so the agent's well-trodden path is visible at a glance. |
| Entities | `room.entities[]` | Chips keyed by `id`, `title={descr}`, styled by `kind` (mob vs object). Capped at 3 with `+N` — the same `MAX_VISIBLE_ENTITIES` treatment as `Rooms.tsx:118`. |
| Look targets | `room.look_candidates[]` | `.tag` chips, same cap. |
| Current room | `player.current_room.id` | `.map-node-current` — ring + accent, and the one node that stays full-detail below the LOD threshold. |
| Provisional / unsurveyed | `confidence`, `surveyed_at` | Same badges as `Rooms.tsx:96`. `knowledge_tab.md` §7: the tab must never present a provisional room the way it presents a confirmed one, and that rule does not stop applying because the view got prettier. |

The whole node is a `<Link to={/knowledge/rooms/${id}}>` wrapper, so the map is
a navigation surface into the detail pages rather than a dead picture. (Drag is
distinguished from click by a small movement threshold, or the map is
unclickable/undraggable — pick pointer-move > 4px = drag, not click.)

Node cells are fixed-size (`--map-cell`, ~190×120px with a ~40px gutter) so the
grid stays a grid. Content that overflows clips with `title` fallback, matching
the `manager-sent` treatment already used in `Manager.tsx:213`.

---

### 6. Frontier — sized for 41 of 73 edges

A frontier exit is `target_room_id === null` (`types.ts:458` calls it out: *"null
IS the exploration frontier"*). It is the single most valuable thing on this
page — it is literally "where the user has yet to go" — and on live data it is
**the majority of all edges**, so the rendering has to survive density:

- **Planar frontier, target cell free** → a short dashed stub arrow from the
  node edge, half a cell long, pointing the right way, labelled with
  `target_name` (the door's name from the autoexit line) or the direction. This
  is the good case and the one that reads instantly.
- **Planar frontier, target cell occupied** → no stub (it would point at an
  existing room and imply a link that isn't there). Falls back to a chip.
- **Non-planar frontier** (`down`, `"(s)"`, anything unknown) → a chip on the
  node: `↓ target_name`. Both live `down` exits are frontier, so this path runs
  on day one.
- **Every node** gets a frontier count in its footer (`2 unwalked`), so the
  information survives the LOD threshold and the occupied-cell case.
- **`Show frontier` toggle**, on by default. 41 dashed stubs is legible on 26
  rooms; the toggle is there for when it isn't.

Stubs are drawn in the SVG layer beneath nodes, thin, dashed, muted — visually
subordinate to real edges. The distinction that matters is *walked vs not*, and
it should read pre-attentively without a legend, exactly as
`Rooms.tsx:33` made it link-vs-plain-text in the table.

---

### 7. Edge styles

Four states, and each one means something specific:

| State | Style |
|---|---|
| Walked both ways (`traversals > 0`, reciprocal exit exists) | solid, no arrowhead |
| Known one-way (`traversals > 0`, no reciprocal) | solid, single arrowhead — one-way exits are a real MUD feature and a real navigation hazard |
| Known but never walked (`target_room_id` set, `traversals === 0`) | solid, lighter |
| **Displaced** (§3) or non-planar (§3) | dashed + curved, with a `⇅`/`≠` marker and a `title` naming the direction |

Reciprocity is computed in `layout.ts` from the exits already in hand — no extra
request. On live data 12 of 32 known-target exits have a reciprocal exit
recorded, so the one-way styling is not hypothetical decoration; most of the
graph currently reads as one-directional simply because the agent has only
walked it one way.

---

### 8. States, routing, envelope

`Knowledge.tsx:19` gains `{ to: "/knowledge/map", end: true, label: "Map" }`
after Rooms; `App.tsx` gains `<Route path="map" element={<Map />} />` inside the
existing `knowledge` route. Nothing else in the shell changes — the header badge
and footer are already driven by whatever the child publishes.

- `attached: false` → `<KnowledgeEmpty />`, unchanged.
- `attached: true`, `rooms.length === 0` → `.empty`: "No rooms in memory yet."
- `knowledge_schema_mismatch` → the existing `.error` banner via the same
  `usePolling` error path.
- `player === null` or `current_room === null` → map renders, no highlight,
  `Center on player` disabled. An empty `player_state` row is a legitimate
  state (`knowledge_tab.md` §3.1).
- `useReportEnvelope(data)` with the rooms envelope, as every other sub-view.

---

### 9. Testing

**The open question in this plan.** `layout.ts` is a pure function with real
branches — determinism, collisions, components, non-planar directions — and
`web/` has no test harness at all; `knowledge_tab.md` §5 declined to add one and
was right to, because everything there was JSX. This is the first frontend code
in the repo where `tsc -b --noEmit` is not a meaningful bar.

Recommendation: **add `vitest` as a devDependency, scoped to `layout.ts` only**
(`layout.test.ts`, `npm test`). No jsdom, no React testing library, no component
tests — one runner for one pure module. If that trade isn't wanted, the fallback
is to keep the same cases as a `layout.fixtures.ts` exercised by hand, which is
worse but not nothing. **Flagging for your call before implementation.**

Cases, whichever way that lands:

- Determinism: layout a 30-room graph, shuffle the input array, assert identical
  coordinates. This is the one that protects the 3s poll.
- North is north: a 4-room cross yields the four expected offsets.
- Collision: a hand-built cycle that doesn't close (n, e, s, w back to a
  *different* room) places both rooms and marks exactly one edge `displaced`.
- Components: two disjoint graphs produce two components with non-overlapping
  bounding boxes.
- Non-planar: an `up` exit consumes no cell; `direction: "(s)"` produces a
  non-planar edge and **does not throw** — the regression test for real data
  that exists today.
- Frontier: `target_room_id: null` yields a stub with `free` correctly set when
  the cell is occupied by a real node.
- Name fallback: empty `name` falls back to truncated description, then `#id`.

Ruby: no changes, so no new tests. Note that `bin/rails test` still needs
`PARALLEL_WORKERS=1` on this machine (`knowledge_tab.md`, "Not amended, but
found") — unrelated, still unfixed.

---

### 10. Phasing

| # | Deliverable | Done when |
|---|---|---|
| 1 | `layout.ts` + tests | Determinism, collision, component and non-planar cases pass on synthetic graphs |
| 2 | `Map.tsx` + `MapNode.tsx` + route/nav, static (no pan/zoom) | The real 26-room world renders with correct north, names, ids, visit counts, entity and look chips |
| 3 | Player highlight, frontier stubs and chips, edge styles | The current room is obvious and the 41 unwalked exits are visible without swamping the picture |
| 4 | Pan, zoom, fit, follow, LOD, frontier toggle | A 300-room synthetic world is navigable |

Phase 1 is the whole risk and the only part that can be wrong in a way that
isn't obvious on screen. Phases 2–4 are rendering over geometry that already
works. Ship 1 before writing any of 2.

---

### 11. Risks and found-while-planning

- **The map presents belief as a floor plan.** This is the strongest version of
  `knowledge_tab.md` §7's warning: a grid of boxes looks like a surveyed map,
  and it is a guess assembled from autoexit lines. `provisional` badges,
  `displaced` edge styling and visible ids are the honesty mechanisms;
  none of them is optional.
- [Note] Just make it clear that its what the agent thinks is the map, not the actual map.
- **Collision handling is untested by real data.** 0 collisions today. The first
  world with a real cycle exercises code that only synthetic fixtures have run.
  Accepted, and the reason §9 exists.
- **Two requests per 3s tick instead of one.** Both already-cheap SELECT sets
  against a 4KB DB with `busy_timeout = 2000`. Revisit at the payload threshold
  named in §1, not before.
- **Bug found, not fixed here: `room_exits.direction = "(s)"`.**
  `room_parser.rb:360` passes any unrecognised autoexit token through verbatim,
  so a parenthesised direction — which is how a closed door appears in the
  autoexit line on some builds — is stored as a direction. The engine source
  isn't in this repo, so *why* the token is parenthesised is unverified; what is
  verified is that room 26 has an exit whose direction is the string `(s)`, with
  no target and no traversals. This map tolerates it (§3) and surfaces it, but
  the fix belongs in the parser: normalise `(x)` to `x` and record the door
  state separately. Worth its own ticket — a closed door recorded as an unknown
  direction is also a frontier the agent can never resolve.


---

### 12. Executed (2026-07-24)

Built as planned. Four things the plan got wrong or left open, recorded here
because the next reader will otherwise trust §0.1 and §3's verification numbers.

**§9's open question, answered: vitest.** Added as a devDependency scoped to
`layout.ts` alone — `layout.test.ts`, `npm test`, 12 cases. No jsdom, no React
Testing Library, no component tests. Every case §9 listed is covered, plus
"exits pointing at rooms outside the payload" and the empty world.

**§0.1's numbers are stale, and the stale one matters.** The live file has grown
from 26 rooms / 73 exits to **32 rooms / 85 exits**, and with it:

| | plan | actual |
|---|---|---|
| components | 1 | 1 |
| collisions / displaced edges | **0** | **6** |
| extent | 7 × 10 | 9 × 10 |
| known-target exits with a reciprocal | 12 of 32 | 18 of 41 |
| frontier exits | 41 | 44 (15 drawable as stubs, 29 as chips) |

So §3's "no real-data coverage for the collision path" and §11's "collision
handling is untested by real data" are both **no longer true** — six walked
exits (`#10→#11`, `#28→#29`, `#29↔#30`, `#31↔#32`) cannot be placed where their
direction says, and the dashed displaced styling runs on the live world on day
one. The synthetic fixtures were still worth writing; they are just no longer
the only coverage.

One design change followed from this: `displaced` is derived from the **final
coordinates**, not recorded at placement time as §3 implied. Placement-time
recording only catches a room that had to be spiralled to a free cell; the
geometric check also catches the second edge of a cycle that does not close,
where both rooms were already placed happily. All six live cases are the second
kind — a placement-time flag would have reported 0 displaced on a map with six
lies in it.

**Two bugs found only by driving the page, neither visible to `tsc`:**

1. *The wheel handler never bound.* §4 specifies wheel-zoom; React's `onWheel`
   is passive, so it is bound by hand in an effect — and the first render of
   this page is the loading state, so a mount-once effect reading
   `viewportRef.current` got `null` and silently bound nothing. The viewport
   element is now held in state as well as a ref, and the effect depends on it.
2. *Pointer capture ate every click on a room.* Taking `setPointerCapture` on
   `pointerdown` (the obvious reading of §4's "pointer events, captured")
   retargets the whole compatibility mouse sequence — including `click` — at
   the capture element, so the room `<Link>` under the cursor never received its
   own click and §5's "the map is a navigation surface, not a dead picture" was
   exactly false. Capture is now taken on crossing the 4px threshold, i.e. once
   the gesture is genuinely a pan.

**Not amended, but confirmed still true:** `room_exits.direction = "(s)"` is
still in the live table (room 26, no target, 0 traversals). The map tolerates it
and renders it as a frontier chip. The parser fix in §11 is still unwritten and
still deserves its own ticket.
