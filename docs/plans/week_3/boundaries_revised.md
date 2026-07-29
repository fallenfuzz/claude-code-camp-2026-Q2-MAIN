# Boundaries

Distilled from `boundaries.md`. The flags-and-BFS design in that document is
withdrawn; everything below is the design as it stands after the review
questions, written as one plan rather than as a plan plus its corrections.

---

## 1. The problem

The agent was told to find the bakery, with no memory of the map, and it walked
out of town:

```text
⚙ plan_route(destination: "bakery")
[route] bakery — unknown
reason: nearest unvisited exit; no remembered room matches "bakery"
frontier: north from The Temple Of Midgaard
then explore: north (destination beyond this exit is not mapped)
```

Two things went wrong. `plan_route` returned one frontier and hid the other
four, so the agent was never shown that there was a choice to make, and even had
it chosen well there was nowhere to record the conclusion "this is a town and
the bakery is in it", so the reasoning would have been re-derived every turn and
lost at compaction.

There is no ground truth to recover instead. In `week0_explore/preview/data/world`,
the step from Behind The Temple Altar (#3059) to The Great Field Of Midgaard
(#3060) is CITY→CITY inside zone 30, so the engine's own metadata places open
countryside in town, and the terrain flip does not arrive until two rooms later
at #3065. Because reading the world files directly does not answer the question,
"in town" is a judgement, and the only participant capable of making it is the
model, which is also the only one that knows Inn→Pub and Guild→Guild Bar are
buildings within a place rather than places beside it.

The design therefore adds no classifier. It gives the agent the information it
was missing, one place to put a conclusion, and a way for routing to read that
conclusion back.

---

## 2. The design in brief

**Every room the agent has stood in belongs to a region, from the first turn.**
There is no unassigned state. Membership derives from three rules:

1. **A room takes the region of the room it was first entered from.** This is
   free, requires no tool call, and happens on every arrival.
2. **A declaration is a root** that overrides inheritance for that room, and
   everything downstream re-derives, so declaring late still fixes the rooms
   reached *through* the declared room.
3. **A room reached with no arrival edge** — after `flee`, a teleport, or a cold
   session start — keeps its region if it is already known, and otherwise seeds a
   new **provisional region** named after the seed room verbatim and marked
   unconfirmed:

   ```text
   region: ⟨from The Temple Of Midgaard⟩ — unconfirmed
   ```

   The brackets mark the label as machine-made and the label is provenance
   rather than a claim. Nothing derives "Midgaard Area" from "The Temple Of
   Midgaard", because parsing a place name out of a room name is a lexicon, and
   it would be wrong here in particular since the temple is *in* Midgaard.

The unconfirmed tag is the whole prompt for naming: it sits in the state block
asking a question at a cost of four words, and it disappears once answered.

Two tools write regions, and the agent has to mean one or the other:

| | |
|---|---|
| `name_region(region:, within:, description:)` | **This place is called X.** Renames the region you are standing in, usually a provisional one, and clears the unconfirmed mark. No boundary is created because no boundary moved. Naming it something that already exists merges the two, and passing `within:` re-parents the whole region. |
| `split_region(region:, within:, description:, reason:)` | **A different place starts in this room.** The boundary is the edge this room was first entered by, exactly; the room behind you keeps its region, and everything you reached through this room comes with it. |

Splitting against the arrival edge is what makes the boundary exact rather than
interpolated, and `hooks.rb` already tracks that edge as `@pending_arrival_edge`
(`hooks.rb:255`), so there is nothing new to compute. Declarations are earned and
never overwritten; membership is derived and rewritten wholesale on recompute,
the same overwrite semantics as `player_items`, because a stale membership is a
lie rather than a history.

`plan_route` changes in three ways:

- **It returns the full unexplored set**, with the names the MUD printed, in
  complete distance bands: every unexplored exit at the nearest distance, then
  every exit at the next distance, until roughly half a dozen are on screen,
  followed by a count of the rest and its range. It never cuts a band or a room
  in half, since "the nearest ones are all here" has to be true for the ordering
  to mean anything, and it says plainly that the ordering is arithmetic.
- **It reports the shape of the current region** on one line — room count,
  unexplored exit count, nearest and median distance to those exits — and
  nothing branches on any of those numbers.
- **It takes `scope: region|world`, defaulting to `region`.** Scope constrains
  exploration and never travel, so a destination that resolves to a known room is
  routed to by the shortest known path across any number of boundaries. Scoping
  to a region means that region *and everything within it*, which is what makes
  Inn→Pub reachable without a bakery search wandering into every building. When
  every remaining frontier leaves the region, the result is `region_exhausted`,
  which carries the widening call as text rather than being a wall.

Ranking gains one term, `region_hops`, inserted ahead of raw distance in
`frontier_rank_key` (`route_planner.rb:197`), so that three moves without leaving
town beats one move out of the gate. No other term changes.

---

## 3. Journal A′ — cold start, find the bakery

The journals are design sketches of intended behaviour rather than recordings.
Room names, exits, geography, and every count and distance below are the real
ones from `week0_explore/preview/data/world/wld/{30,31}.json`, so all of it is
checkable against a real run. The model's lines are what the design intends to
make available and worth reasoning about; the tool output is exactly what §2
specifies.

Empty map memory, same starting room as the failing transcript.

```text
── iteration 0 ──────────────────────────────────────────────────────────
injected [here]
  [here] The Temple Of Midgaard
    You are in the southern end of the temple hall in the Temple of Midgaard...
  exits: north→By The Temple Altar ? | east→The Midgaard Donation Room ? |
         south→The Temple Square ? | west→The Reading Room ? | down→The Temple Square ?
  region: ⟨from The Temple Of Midgaard⟩ — unconfirmed
  you: 84/84hp 100mana 82mv · lvl 10 · 0 gold · standing

model
  No map at all. Ask what the router knows before guessing.

⚙ plan_route(destination: "bakery")
  [route] bakery — unknown
  region: ⟨from The Temple Of Midgaard⟩ — unconfirmed
          (1 room · 5 unexplored exits · nearest 0 moves, median 0)
  unexplored, in this region — all 5, 0 moves:
    north → By The Temple Altar
    east  → The Midgaard Donation Room
    south → The Temple Square
    west  → The Reading Room
    down  → The Temple Square
  reason: no remembered room matches "bakery"; ordered by distance, which knows
          nothing about what these names mean — you do

model
  Four of those five are parts of this temple — altar, donation room, reading
  room. "The Temple Square" is the only one that opens onto a city, and two exits
  lead to it, which is what a building's front door looks like. A bakery is a
  shop and shops are on streets. South, not the nearest.

⚙ move(direction: "south")     → The Temple Square

── iteration 1 ──────────────────────────────────────────────────────────
  [here] The Temple Square
  exits: north→The Temple Of Midgaard ✓ | east→The Entrance Hall Of The Grunting Boar Inn ? |
         south→Market Square ? | west→The Entrance To The Clerics' Guild ?
  region: ⟨from The Temple Of Midgaard⟩ — unconfirmed (inherited)

model
  Outdoors, and the names change character: an inn, a guild, a market. Market
  Square is where food is sold. The place I am in still has no name; one more
  room and I will know whether the temple was the place or a building in it.

⚙ move(direction: "south")     → Market Square

── iteration 2 ──────────────────────────────────────────────────────────
  [here] Market Square
  exits: north→The Temple Square ✓ | east→Main Street ? |
         south→The Common Square ? | west→Main Street ?
  region: ⟨from The Temple Of Midgaard⟩ — unconfirmed (inherited)

model
  Squares, streets, an inn, guilds, everything named Midgaard. This is one town
  and the temple was a building inside it — so the place I have been walking
  since iteration 0 is the town, and it is still carrying a placeholder. Naming
  it, so routing keeps me in it and so I don't re-derive this after compaction.

⚙ name_region(region: "Midgaard", description: "walled town — temple, temple square,
              market square and two Main Streets, all named Midgaard")
  [region] ⟨from The Temple Of Midgaard⟩ → Midgaard, confirmed
  3 rooms carry the name: The Temple Of Midgaard, The Temple Square, Market Square
  no boundary moved — this renamed the place you were already in
  Midgaard: 3 rooms · 8 unexplored exits · nearest 0 moves, median 1

model
  Two Main Streets and nothing to choose between them. East.

⚙ move(direction: "east")      → Main Street

── iteration 3 ──────────────────────────────────────────────────────────
  [here] Main Street
  exits: north→The General Store ? | east→Main Street ? |
         south→The Pet Shop ? | west→Market Square ✓
  region: Midgaard (inherited)          ← no tool call; it came in with the move

model
  Shops line this street, which confirms the approach, but a general store and a
  pet shop are named for what they are and neither is a bakery. Walk the street.

⚙ move(direction: "east")      → Main Street

── iteration 4 ──────────────────────────────────────────────────────────
  [here] Main Street
  exits: north→The Weapon Shop ? | east→Inside The East Gate Of Midgaard ? |
         south→The Entrance Hall To The Guild Of Swordsmen ? | west→Main Street ✓
  region: Midgaard (inherited)

model
  A weapon shop and a swordsmen's guild — martial quarter, wrong place for bread.
  "Inside The East Gate" says the wall is one room east, so this street ends.
  Check what else is open before backtracking blind.

⚙ plan_route(destination: "bakery")
  [route] bakery — unknown
  region: Midgaard (5 rooms · 12 unexplored exits · nearest 0 moves, median 2)
  unexplored, in Midgaard — 7 of 12, nearest first:
    here — Main Street
      north → The Weapon Shop
      east  → Inside The East Gate Of Midgaard
      south → The Entrance Hall To The Guild Of Swordsmen
    1 move — Main Street
      north → The General Store
      south → The Pet Shop
    2 moves — Market Square
      south → The Common Square
      west  → Main Street
    5 more from 2 rooms, 3–4 moves away
  reason: no remembered room matches "bakery"; ordered by distance, which knows
          nothing about what these names mean — you do

model
  Nearest is the weapon shop, already ruled out. The unexplored Main Street west
  of Market Square is two moves away and is the same street this row of shops
  sits on. Going there.

⚙ move(direction: "west") ×2   → Main Street, Market Square
⚙ move(direction: "west")

── iteration 7 ──────────────────────────────────────────────────────────
  [here] Main Street
  exits: north→The Bakery ? | east→Market Square ✓ |
         south→The Armory ? | west→Main Street ?
  region: Midgaard (inherited)

⚙ move(direction: "north")     → The Bakery

── iteration 8 ──────────────────────────────────────────────────────────
  [here] The Bakery
  exits: south→Main Street ✓
  region: Midgaard (inherited)
  here: the baker (mob — "you could take him")

model
  Found it. Nothing to declare — this room is already in Midgaard, which is
  true, and a one-room shop is not a place I need to scope a search to.
```

Eight moves, two `plan_route` calls, one `name_region`, and the agent never left
town. The naming call did nothing for *this* task, since its only effect in this
session was the "in Midgaard" header on the iteration-4 list, and everything that
mattered came from the model reading names it was finally allowed to see. That is
precisely why frontier visibility ships and gets measured before any of the
region machinery is built (§8).

---

## 4. Journal B′ — find the hermit, and the declared break

A later session. Midgaard's streets are mapped at 66 known rooms, the agent is in
Market Square, and the goal is a hermit it has heard of and never found.

```text
── iteration 12 ─────────────────────────────────────────────────────────
  [here] Market Square
  region: Midgaard (inherited)

⚙ plan_route(destination: "hermit")
  [route] hermit — unknown
  region: Midgaard (66 rooms · 16 unexplored exits · nearest 2 moves, median 8)
  unexplored, in Midgaard — 6 of 16, nearest first:
    2 moves — The Dump
      down  → (unnamed)
    4 moves — The Clerics' Inner Sanctum
      down  → (unnamed)
    4 moves — The Levee
      south → (unnamed)
    4 moves — Outside The West Gate Of Midgaard
      west  → (unnamed)
    4 moves — Outside The East Gate Of Midgaard
      east  → (unnamed)
    4 moves — Behind The Temple Altar
      north → The Great Field Of Midgaard
    10 more from 6 rooms, 5–11 moves away
  reason: no remembered room matches "hermit"; ordered by distance, which knows
          nothing about what these names mean — you do

model
  A hermit is by definition someone who lives away from people, so no door in a
  town is the answer, however near it is. Four of these leave — both gates, the
  levee, and north into a field — and the field is the only one that names
  somewhere empty. Widening rather than pretending the town still constrains
  this.

⚙ plan_route(destination: "hermit", scope: "world")
  [route] hermit — unknown
  frontier: north from Behind The Temple Altar — leaves Midgaard
  path: north → north → north → north
  then explore: north (nothing mapped beyond this exit)

⚙ move(direction: "north") ×4  → The Temple Square, The Temple Of Midgaard,
                                  By The Temple Altar, Behind The Temple Altar
⚙ move(direction: "north")

── iteration 17 ─────────────────────────────────────────────────────────
  [here] The Great Field Of Midgaard
    You are walking on a wide dirt path through the lush, green, fresh Midgaard
    countryside. You can see to the horizon to the north, east, and west; the
    busy city of Midgaard lies to the south...
  exits: north→The Great Field Of Midgaard ? | south→Behind The Temple Altar ✓
  region: Midgaard (inherited)          ← inherited, and wrong; I am outside it

model
  The room says it outright — the city lies to the south and I am on a path
  through countryside. This is where Midgaard stops.

⚙ split_region(region: "The Great Field",
               description: "open countryside north of Midgaard",
               reason: "description says the busy city of Midgaard lies to the
                        south; open ground to the horizon north, east and west")
  [region] The Great Field — starts here
  boundary: Behind The Temple Altar —north→ The Great Field Of Midgaard
            (the edge you walked in on; Behind The Temple Altar stays in Midgaard)
  Midgaard: 66 rooms · The Great Field: 1 room · 1 boundary

⚙ move(direction: "north")

── iteration 18 ─────────────────────────────────────────────────────────
  [here] The Great Field Of Midgaard
  exits: north→The Great Field Of Midgaard ? | east→? | south→✓ | west→The Dirt Path ?
  region: The Great Field (inherited)   ← no call; the declaration flows forward

⚙ plan_route(destination: "hermit")
  [route] hermit — unknown
  region: The Great Field (2 rooms · 3 unexplored exits · nearest 0 moves, median 0)
  unexplored, in The Great Field — 3 exits from the 1 nearest room:
    here — The Great Field Of Midgaard
      north → The Great Field Of Midgaard
      east  → (unnamed)
      west  → The Dirt Path

model
  Default scope now means the countryside, not the town, and it started meaning
  that the moment I said so. Carrying on north.
```

Two properties are worth naming here. The crossing costs exactly one tool call
and there is no session in which the boundary sits silently in the wrong place,
because the boundary *is* the edge the agent walked rather than a midpoint
between two claims. The evidence the agent used was the prose — "the busy city of
Midgaard lies to the south" — and since both rooms are CITY (§1) the movement
cost did not change across the crossing at all, so any terrain-based detector
would have missed it entirely.

Note also that `region_exhausted` did not fire, and should not have, because
Midgaard still had twelve unexplored doors. The model widened on meaning rather
than on a status, which is the behaviour the design is actually betting on; the
status is a convenience for when the arithmetic happens to agree, never the
mechanism itself.

---

## 5. Journal C′ — the region that stopped narrowing anything

Both banks of the river have been partly walked, the agent is standing on the
south bank, and the goal is the mayor, whose office it has never found.

```text
── iteration 40 ─────────────────────────────────────────────────────────
  [here] The Northwest End Of The Concourse
  exits: north→On The Bridge ✓ | east→The Promenade ✓ | south→On The Concourse ✓
  region: Midgaard (inherited)

⚙ plan_route(destination: "mayor")
  [route] mayor — unknown
  region: Midgaard (66 rooms · 16 unexplored exits · nearest 1 move, median 6)
  unexplored, in Midgaard — 8 of 16, nearest first:
    1 move  — On The Concourse
      west  → (unnamed)
    2 moves — The Promenade
      south → The Park Entrance
    2 moves — Park Road
      south → Park Road
    3 moves — Emerald Avenue
      north → Emerald Avenue
    3 moves — On The Concourse
      south → A Gravel Road In The Graveyard
    4 moves — Park Road
      north → Park Road
    4 moves — Emerald Avenue
      east  → Penny Lane
      south → Emerald Avenue
    8 more from 8 rooms, 6–12 moves away
  reason: no remembered room matches "mayor"; ordered by distance, which knows
          nothing about what these names mean — you do

model
  Sixteen open doors with a median of six moves, and half of them withheld
  because they are six to twelve moves off. That tail is cellar hatches and
  gates on the far side of the river and none of it has anything to do with a
  mayor — scoping to "Midgaard" is barely narrowing this search any more. This
  side is a different kind of place anyway: avenues, a promenade, a park, laid
  out wide, and I entered all of it over one bridge. Naming it, so "here" means
  these thirteen rooms and not the whole city.

⚙ split_region(region: "The South Bank", within: "Midgaard",
               description: "avenues, promenade and park south of the river",
               reason: "reached over the bridge; wide planned streets, nothing
                        like the north town's alleys")
  [region] The South Bank — starts here, within Midgaard
  boundary: On The Bridge —south→ The Northwest End Of The Concourse
            (the edge this room was first entered by)
  13 rooms move from Midgaard into The South Bank — every room you first
  reached through this one
  Midgaard: 53 rooms directly, 66 including within · The South Bank: 13 rooms

⚙ plan_route(destination: "mayor")
  [route] mayor — unknown
  region: The South Bank (13 rooms · 8 unexplored exits · nearest 1 move,
          median 3) — within Midgaard
  unexplored, in The South Bank — all 8:
    ...

model
  Sixteen doors at median six became eight at median three, nothing withheld,
  and every one on this side of the river. A mayor's office is civic and
  central — Emerald Avenue and the Promenade before the park.
```

**A frontier list that grows is what the agent notices, but the distances are
what tell it anything.** Journal A′ at iteration 4 read *12 unexplored exits,
nearest 0, median 2*, which describes a dense little town where scope is working
perfectly, whereas this reads *16, nearest 1, median 6* — barely more doors, and
yet the scope has stopped narrowing. A count threshold would have fired on A′ and
been wrong, so both numbers are printed on one line and nothing branches on
either.

**Quarters nest rather than partition.** Had Midgaard been replaced by three
peers, the question "is this in town at all?" would have become unanswerable, and
that question is the original bug. Because `scope: "region"` means the current
place and everything within it, standing on the concourse makes "here" mean 13
rooms while a search starting at the west gate still scopes to all 66. The same
mechanism carries buildings, which is where Inn→Pub and Guild→Guild Bar live.

**Retroactive subdivision is refused, and that cost is real.** Splitting the
south bank worked because the agent stood at its entrance and everything in it
had been reached through that entrance, whereas carving "The Temple Quarter" out
of the already-mapped north bank has no such edge, since those rooms were reached
by a dozen different routes. What the design offers instead is renaming and
re-parenting a whole region, which is exact and needs no semantics:

```text
⚙ name_region(region: "North Midgaard", within: "Midgaard")   ← standing in Market Square
  [region] Midgaard → North Midgaard, within a new parent Midgaard
  53 rooms carry the new name; The South Bank is now its sibling
  Midgaard (66)
  ├── North Midgaard (53)
  └── The South Bank (13)
  note: this renamed the whole place you are standing in. To carve a quarter out
        of North Midgaard, split it from the room it is entered by, as you walk in.
```

Quarters are therefore declared going forward, as the agent walks into them.

---

## 6. Schema (V5)

```sql
-- EARNED: the places the agent named, in its own words.
CREATE TABLE regions (
  id            INTEGER PRIMARY KEY,
  label         TEXT NOT NULL UNIQUE,     -- '⟨from The Temple Of Midgaard⟩' until named
  confirmed     BOOLEAN NOT NULL DEFAULT 0,
  description   TEXT,                     -- free text, the agent's words
  parent_id     INTEGER REFERENCES regions(id),
  seed_room_id  INTEGER REFERENCES rooms(id),
  first_seen_at TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

-- EARNED: one row per split. The edge is the boundary, exactly.
CREATE TABLE region_boundaries (
  id          INTEGER PRIMARY KEY,
  from_room_id INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  to_room_id   INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  direction    TEXT NOT NULL,
  region_id    INTEGER NOT NULL REFERENCES regions(id) ON DELETE CASCADE, -- the region that starts at to_room
  reason       TEXT,                      -- optional; why the agent said so
  declared_at  TEXT NOT NULL,
  session_id   TEXT
);

-- DERIVED: rewritten wholesale on recompute. No null case — every walked room
-- is a member of something.
CREATE TABLE room_regions (
  room_id     INTEGER PRIMARY KEY REFERENCES rooms(id) ON DELETE CASCADE,
  region_id   INTEGER NOT NULL REFERENCES regions(id) ON DELETE CASCADE,
  basis       TEXT NOT NULL,              -- 'inherited' | 'declared'
  computed_at TEXT NOT NULL
);
CREATE INDEX idx_room_regions_region ON room_regions(region_id);
```

`description` lives on the region rather than on each declaration, because it
describes the place rather than the moment; the only per-location text kept is
the optional `reason` on the boundary row, since that is the one claim a human
reviewing a wrong boundary needs to see and it is a property of the edge rather
than of the place.

Recompute walks first-arrival edges from the declared roots over a few hundred
rooms, which costs microseconds, so it can afford to be exhaustive. `Hooks` marks
the derivation dirty when `discover` or `link_arrival` changes the graph or when
a declaration lands, and the recompute runs lazily on the next read rather than
inside a MUD round trip. The determinism obligations match `RoutePlanner`'s:
canonical direction order, room id as the final tie-break, and no reliance on SQL
row order without an `ORDER BY`.

---

## 7. Monitor, prompt, and what stays out

**Monitor.** `GET /api/knowledge/regions` sits beside the existing `knowledge/*`
routes (`api/config/routes.rb:44`) and returns regions with `parent_id`,
`confirmed`, their declared boundary edges with reasons, and member room ids with
`basis`, while `knowledge#rooms` gains `region_id`. `Map.tsx` draws region tint
behind member cells, draws boundary edges with their own stroke revealing both
regions and the declared reason on hover, and gains a `showRegions` toggle beside
`showFrontier`. A `Regions` page beside `Frontier.tsx` carries one row per region
— label, confirmed state, description, parent, room count, unexplored exits, and
each declared boundary with its reason — so a misplaced boundary is diagnosable
in one click. The distinction between a declared edge and a tinted cell is the
point of the page, because tint is simultaneously the most authoritative-looking
thing the map will ever draw and the least earned, so the declarations that
generated it stay visible on top of it.

**Prompt.** `settings.yaml:100` sets `prompt_override.system: true`, so the
prompt in use is `.boukensha/prompts/player/system.md`, of which `# Navigation`
is 290 words out of 670 — 43%, most of it an enumeration of `plan_route`'s six
return statuses that restates what the tool's own output says at the moment it
says it. Guidance for regions therefore goes into the tool descriptions and the
tool output rather than into a new prompt section, and `# Navigation` is cut to
policy only, roughly forty words: prefer `plan_route` over eyeballing exits,
re-plan after a failure, and remember that frontier ordering is arithmetic and
knows nothing about meaning. Prompt caching is not a defence for leaving it
long, because the cost that remains after the first request is attention rather
than tokens.

**Deliberately absent.** No word list of any kind, which rules out
settlement/wilderness classes, portal words, and an enum on `description`, since
an enum is a lexicon with better manners. No automatic clustering, no thresholds,
no scores. No destination-word prior such as "bakery ⇒ settlement", which
Journal A′ gets from the model at no cost. No terrain classification from
movement cost, which §1 and Journal B′ show would miss the crossing that matters
most in this world. No hard in-region filter, since what the design offers
instead is one overridable status. No claim about a room the agent has not stood
in.

---

## 8. Delivery order

0. **Ablate `# Navigation`.** Cut it to policy-only and run
   `.boukensha/tests/scenarios/find_bakery.yml`, which already has a
   deterministic gate (`max_model_tool_calls: 6`, `final_room: The Bakery`). One
   prompt edit and a batch run, and it can be done before anything here is built.
1. **Frontier visibility.** `plan_route` returns the full unexplored set in
   complete distance bands with MUD-printed names, capped with a withheld count,
   and states that the ordering is arithmetic. No schema, no new tool. Run
   `find_bakery_cold` here and record the number, because §3 claims this alone
   fixes the reported transcript and that claim should be measured before
   anything else is built. **If showing the agent the names does not change its
   behaviour, steps 2–4 rest on a false assumption and should not be built.**
2. **Regions.** V5 schema, inheritance recompute, `name_region`, `split_region`,
   provisional regions and the unconfirmed tag in the state block.
3. **Scope.** `region_hops` in the ranking, `region_exhausted`, the region shape
   line, the tool-description guidance.
4. **Monitor.** `knowledge/regions`, tint, boundary strokes, Regions page.
5. **Measure.** Batch all three journals as scenarios against the table below.

**Tests.** Inheritance determinism under shuffled row order; a late declaration
re-deriving everything downstream of it and nothing upstream; `within:` nesting
with `scope: "region"` including descendants; one-way exits never reversed for
routing; a room arriving with no edge seeding exactly one provisional region and
a known room never seeding one; `name_region` renaming in place and merging on
collision; `split_region` using the first-arrival edge and leaving the previous
room alone; both tools performing zero MCP calls and refusing when position is
unknown; `region_hops` outranking raw distance; `region_exhausted` firing only
when every frontier crosses; a known destination routing across a boundary under
the default scope; the frontier list never cutting a band in half; recompute
never running inside a MUD round trip; and a guard test asserting no file under
`lib/` references `data/world`.

**Metrics**, using the harness from `54ce732`, with Journals A′, B′ and C′ as
`find_bakery_cold`, `find_hermit_mapped` and `find_mayor_split`:

| Metric | Why |
|---|---|
| moves to first arrival | the headline |
| share of moves outside the starting region | the specific failure in the transcript |
| `name_region` / `split_region` calls, and how many were repairs | is the mechanism usable or fiddly |
| `name_region` used where `split_region` was meant | the sharp edge this design introduces (§9) |
| `region_exhausted` correctly widened vs. wrongly accepted | is the refusal a question or a wall |
| boundaries declared vs. boundaries walked through | did the boundary track reality |
| `plan_route` calls per goal | regression guard from `plan_route.md` §10.7 |

Rows three through five are the ones to watch, because they are the design's own
failure modes and none of them is visible in a move count.

---

## 9. What stays wrong

| | |
|---|---|
| **A late split only fixes what is downstream of it.** | A room reached by a route that does not pass through the split room keeps the region it inherited. Repair: split there too. Visible on the monitor as a room of the wrong tint on the wrong side of a boundary. |
| **`name_region` used where `split_region` was meant.** | Walk town → gate → field naming nothing, then call `name_region("The Great Field")` in the field, and the whole town is renamed, because the town is the place you are standing in. Mitigations: the unconfirmed tag pushes naming to the moment of recognition rather than fifty rooms later, and the tool prints the room count it renamed, so `53 rooms carry the new name` is loud when the agent expected one. Repair: rename back, then split. |
| **A split made deep inside a place puts the boundary on an interior edge.** | The tool prints the edge it used every time, so the mistake is legible in the same turn it is made. Guidance in the tool description: split in the first room of the new place. |
| **Provisional regions accumulate.** | Every teleport into unknown territory seeds one, bounded by the rule that an arrival in a known room never mints a new region. Two provisional regions that turn out to be one place merge by being given the same name, and untidied the cost is cosmetic. |

None of these can put the agent somewhere it did not walk, and none survives a
declaration made in the affected room.

**What the journals do not prove.** They remain design sketches: the claim that
A′ takes eight moves rests on the model reading five room names correctly at
iteration 0, and the claim that C′ splits in the right place rests on it noticing
a median. Both are exactly what the harness measures, which is why steps 0 and 1
run before the schema is written.

---

## 10. Separate bug, not boundaries work

`reconcile_move!` (`hooks.rb:242`) gates everything on `look.complete?`, which
requires both a room name and an exits line. A room the character cannot see
supplies neither, so a move into an unlit room takes the rejection branch,
records `record_frontier_attempt!(outcome: "failed")` and returns `{ ok: false }`
while the character has in fact moved, after which `@current_room_id` points at
the room the agent has left and every subsequent state block, memory write and
route is anchored to a position the player is not in. Relatedly, `check(exits)`
prints a sentinel instead of a room name for a target the character cannot see,
and since `parse_exits` (`room_parser.rb:117`) cannot tell, that sentinel is
stored as `room_exits.target_name` and becomes a searchable room name, matchable
by `DestinationSearch` and `target_name_clue?` (`route_planner.rb:208`) and
rendered on the map as a labelled destination.

Both need a captured fixture before either is fixed, following the rule
`parse_score` documents at `room_parser.rb:154`: capture the bytes for a dark
`move` and a dark `check(exits)` first, then anchor the parsing on them. For
boundaries this needs no special handling, because an unlit area is a place like
any other.
