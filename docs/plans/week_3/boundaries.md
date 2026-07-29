## Boundaries
NOTE: This doc is an outdated artifact and should not be used for implementation.

We tasked our agent to find the bakery and this session starts with no memory of the map.
http://localhost:5173/sessions/20260728T190719Z-d2fa7ec6

⚙ plan_route(destination: "bakery")
[route] bakery — unknown
reason: nearest unvisited exit; no remembered room matches "bakery"
frontier: north from The Temple Of Midgaard
then explore: north (destination beyond this exit is not mapped)

It starts going to the frontier, the only problem is that the player
is currently in a town, and so it would make sense for the boundary
of their search to stay within the town.

It seems for exploration defining boundaries to reason where to look
would be important.

So the bakery would want to search around the town, and you probably wouldn't
expect the bakery to within another building. Sometimes it does happen eg:
Inn > Tarvern/Pub
Guild > Guild Pub

Or there could be something like "to dark to tell" where that is clear indicator
you are entering an area with a huge lack of visibilty

Or if you are crossing outside of town. Clearly here they have now left town:
[here] The Great Field Of Midgaard
  You are walking on a wide dirt path through the lush, green, fresh Midgaard countryside. You can see to the horizon to the north, east, and west; the busy city of Midgaard lies to the south. All around you is healthy green grass and an occasional large oak tree. The sun feels wonderful on your face and a pleasant wind blows through your hair. Birds chirp quietly to themselves and you can smell the faint scent of flowers and freshly cut grass. You feel like you could lie down in the grass and stay here forever, surrounded by powerful beauty in all directions. The path you are on continues north through the field and south back to Midgaard.
exits: north→The Great Field Of Midgaard ? | south→Behind The Temple Altar ?
you: 16/84hp 100mana 80mv · lvl 10 · 0 gold · standing

How do we define a boundary?
- can we show boundaries defined by the agent show up on our mud monitor map
- should plan_route be responsible for setting where to reason to explore?
- how will the agent reason to define boundaies?

## Technical Solution

### 1. The principle

Nothing in this design decides what a place *is*, which rules out a table of
words that mean "town", a score that says an exit is outward-looking, and a
threshold that cuts the map into zones. Each of those would be a guess about
English dressed up as a fact about the world, so each would be wrong in exactly
the cases that matter — the ones nobody anticipated when the table was written.

What the agent lacks in the failing transcript is not a classifier but
**information and a place to put a conclusion**:

| Missing | Fix |
|---|---|
| `plan_route` returned *one* frontier and hid the other four | return the whole unexplored set, with the names the MUD printed |
| the agent's conclusion had nowhere to live | one new tool that records it |
| exploration ignored the conclusion | `plan_route` reads it back as a ranking term and a scope |

The design consists of those three changes and nothing else, because the
reasoning stays in the model, where it already works and where it can handle
Inn→Pub, Guild→Guild Bar, and every nested or ambiguous case a lexicon would
have had to enumerate.

#### 1.1 Why there is no ground truth to fall back on

The table below is drawn from `week0_explore/preview/data/world` and covers the moment in the transcript where the player has plainly left town:

| Room | `zone_number` | `sector_type` |
|---|---|---|
| Market Square (#3014) | 30 — "Northern Midgaard" | CITY |
| Behind The Temple Altar (#3059) | 30 | CITY |
| The Great Field Of Midgaard (#3060) | 30 | CITY |
| The Great Field Of Midgaard (#3065) | 30 | **FIELD** |

The step from `#3059` to `#3060` is CITY→CITY inside a single zone, so the
engine's own metadata places the field in town and the terrain flip arrives two
rooms after the player has actually left. Because there is no correct answer to
recover even by reading the world files directly, "in town" is a judgement and
always was, and the only participant capable of making it is the one that knows
what a town is for.

---

### 2. Regions are flags, not clusters

The agent plants a flag in the room it is standing in — *this room is Midgaard* —
and later, somewhere else, plants another: *this room is The Great Field*. Every
other known room is then assigned to **whichever flag is fewest moves away**, by
multi-source BFS over the known graph, and a **crossing** is any known edge whose
two rooms ended up under different flags. That is the entire algorithm.

```text
  Reading Room ──┐
                 ├── The Temple Of Midgaard ── By The Temple Altar ── Behind The Temple Altar
  Temple Square ─┘                                                            │
        │                                                                     │  ← crossing
   ⚑ Market Square  (flag: Midgaard)                          ⚑ The Great Field Of Midgaard
                                                                    (flag: The Great Field)
```

Properties that matter:

- **No semantics.** The computation is a BFS with a tie-break on room id, so it
  cannot be wrong about English because it never reads English.
- **The agent controls precision directly.** A boundary lands at the midpoint
  between two flags, so when it lands in the wrong place the fix requires no new
  concept — *plant another flag closer to the edge*, which is what the agent does
  in §5.
- **It is cheap to be wrong.** Membership is derived, rewritten wholesale on
  every recompute, and never feeds a decision that cannot be reversed by walking.
- **Nesting is free.** A flag may name a parent (`within:`), so The Grunting Boar
  Inn can be a region inside Midgaard. `scope: "region"` means the current region
  *and everything within it* — which is what makes Inn→Pub reachable without the
  bakery search wandering into every building.

The honest weakness is that the midpoint rule will misplace a boundary whenever
the flags are lopsided, which is why §5 demonstrates that failure rather than
hiding it: the misplacement is visible on the monitor and correctable in a single
tool call.

---

### 3. Tool surface

#### 3.1 `note_region` — new

This is the only new tool, and it writes one row while performing no MUD I/O at
all.

```json
{
  "region": { "type": "string", "description": "What you call this place, e.g. 'Midgaard'." },
  "kind":   { "type": "string", "description": "Free text, your words, e.g. 'walled town'. Optional." },
  "within": { "type": "string", "description": "Enclosing region, if this is inside one. Optional." },
  "note":   { "type": "string", "description": "Why you think so. Recorded as the evidence. Optional." }
}
```

`kind` is deliberately **free text, not an enum**. An enum is a lexicon with
better manners: it forces the agent to round its judgement to the nearest value
someone guessed at design time. Nothing branches on `kind` — it is displayed and
searched, never switched on.

It always applies to the room the agent is standing in. There is no `room_id`
argument, because a claim about a room the agent has not seen is a prediction,
and a prediction stored beside earned knowledge is the exact class of lie the
knowledge base is built to avoid. Re-flagging a room replaces the previous flag
and logs the replacement.

```text
[region] Midgaard — flag planted
here: Market Square (#3)
kind: walled town
7 known rooms now in Midgaard, 0 in other regions, 0 crossings
```

#### 3.2 `plan_route` — changed

One optional argument:

```json
{ "scope": { "type": "string", "enum": ["region", "world"], "default": "region" } }
```

Three rules:

- **Scope constrains exploration, never travel.** A destination that resolves to
  a known room is routed to by the shortest known path, across any number of
  crossings.
- **The tool never leaves a region silently.** If every remaining frontier is
  outside the current region, it returns `region_exhausted` — a new status
  distinct from `exhausted` (no frontiers at all) — and says what widening costs.
- **With no flags planted, scope does nothing.** There is one implicit region
  containing everything, so a fresh agent is never blocked by a mechanism it has
  not used yet.

The ranking gains one earned term, `region_hops`, computed over the agent's own
flags — inserted **ahead of** raw distance in `frontier_rank_key`
(`route_planner.rb:197`), so "three moves without leaving town" beats "one move
out of the gate". No other term changes.

#### 3.3 The output change that does the real work

`plan_route` currently answers with a single frontier, which in the failing
transcript was north, so the four alternatives — including the two that lead into
the city — were never shown. The agent could not have chosen better than it did,
because it was never told there was a choice to make.

Every `explore`/`unknown` result now carries the full unexplored set with the
names the MUD printed, and says plainly that the ordering is arithmetic:

```text
reason: ranked by distance only — the names above are the MUD's, judge them yourself
```

---

### 4. Journal A — cold start, find the bakery

> **Superseded by §14.** This journal is written against the flags + BFS design
> that A1 withdraws. Kept for the argument it makes about frontier visibility;
> for the journey as it would actually run, read §14.

Same task and same starting room as the transcript at the top of this document.
Empty map memory. Geography, room names and exits are the real ones from
`wld/30.json`, so this is checkable against a real run rather than an
illustration.

This is a **design sketch of expected behaviour**, not a recording. The model's
lines are what the design intends to make available and worth reasoning about;
the tool output is exactly what the contracts above specify.

```text
── iteration 0 ──────────────────────────────────────────────────────────
injected [here]
  [here] The Temple Of Midgaard
    You are in the southern end of the temple hall in the Temple of Midgaard...
  exits: north→By The Temple Altar ? | east→The Midgaard Donation Room ? |
         south→The Temple Square ? | west→The Reading Room ? | down→The Temple Square ?
  you: 84/84hp 100mana 82mv · lvl 10 · 0 gold · standing

model
  I have no map at all. Ask the router what it knows before guessing.

⚙ plan_route(destination: "bakery")
  [route] bakery — unknown
  region: none — you have not named any place yet
  here: The Temple Of Midgaard (#1)
  unexplored from here:
    north → By The Temple Altar
    east  → The Midgaard Donation Room
    south → The Temple Square
    west  → The Reading Room
    down  → The Temple Square
  nearest: north (all are 0 moves away; ties broken by direction order)
  reason: no remembered room matches "bakery"; ranked by distance only — the
          names above are the MUD's, judge them yourself

model
  Four of those five names are parts of this temple — the altar, the donation
  room, the reading room. "The Temple Square" is the only one that sounds like
  it opens onto a city, and two exits lead to it, which is what a building's
  front door looks like. A bakery is a shop and shops are on streets, not in
  temples. Taking south rather than the nearest.

⚙ move(direction: "south")
  The Temple Square
  You are standing on the temple square...
  [ Exits: n e s w ]

── iteration 1 ──────────────────────────────────────────────────────────
injected [here]
  [here] The Temple Square
  exits: north→The Temple Of Midgaard ✓ | east→The Entrance Hall Of The Grunting Boar Inn ? |
         south→Market Square ? | west→The Entrance To The Clerics' Guild ?
  you: 84/84hp 100mana 81mv · lvl 10 · 0 gold · standing

model
  Outdoors now, and the names change character: an inn, a guild, a market. This
  is a town and the temple was a building inside it. Market Square is where I'd
  expect food sold.

⚙ move(direction: "south")
  Market Square
  ...

── iteration 2 ──────────────────────────────────────────────────────────
injected [here]
  [here] Market Square
  exits: north→The Temple Square ✓ | east→Main Street ? |
         south→The Common Square ? | west→Main Street ?
  you: 84/84hp 100mana 80mv · lvl 10 · 0 gold · standing

model
  Squares, streets, an inn, guilds, and every name so far carrying "Midgaard".
  This is one town and I should record that before I explore further, so that
  routing keeps me inside it and so I don't re-derive this every turn.

⚙ note_region(region: "Midgaard", kind: "walled town",
              note: "Temple, temple square, market square and two Main Streets, all
                     named Midgaard; the temple rooms are interiors within it")
  [region] Midgaard — flag planted
  here: Market Square (#3)
  kind: walled town
  3 known rooms now in Midgaard, 0 in other regions, 0 crossings

model
  Two Main Streets, nothing to choose between them. East.

⚙ move(direction: "east")
  Main Street
  ...

── iteration 3 ──────────────────────────────────────────────────────────
injected [here]
  [here] Main Street
  exits: north→The General Store ? | east→Main Street ? |
         south→The Pet Shop ? | west→Market Square ✓
  you: 84/84hp 100mana 79mv · lvl 10 · 0 gold · standing

model
  Shops line this street, which confirms the approach, but a general store and a
  pet shop are named for what they are and neither is a bakery. No reason to
  spend a move entering either. Keep walking the street.

⚙ move(direction: "east")
  Main Street
  ...

── iteration 4 ──────────────────────────────────────────────────────────
injected [here]
  [here] Main Street
  exits: north→The Weapon Shop ? | east→Inside The East Gate Of Midgaard ? |
         south→The Entrance Hall To The Guild Of Swordsmen ? | west→Main Street ✓
  you: 84/84hp 100mana 78mv · lvl 10 · 0 gold · standing

model
  A weapon shop and a swordsmen's guild — this is the martial quarter, wrong
  place for bread. And "Inside The East Gate" tells me the town wall is one room
  east, so this street is ending. The other Main Street, west of Market Square,
  is still unexplored. Check what else is open before backtracking three rooms.

⚙ plan_route(destination: "bakery")
  [route] bakery — unknown
  region: Midgaard (walled town · 5 rooms · flag at Market Square)
  unexplored, in Midgaard:
    north → The Weapon Shop                            (0 moves)
    east  → Inside The East Gate Of Midgaard           (0 moves)
    south → The Entrance Hall To The Guild Of Swordsmen (0 moves)
    west  → Main Street          from Market Square    (2 moves)
    south → The Common Square    from Market Square    (2 moves)
    east  → The Grunting Boar Inn from The Temple Square (3 moves)
    north → By The Temple Altar  from The Temple Of Midgaard (4 moves)
    ...
  nearest: north → The Weapon Shop
  reason: no remembered room matches "bakery"; ranked by distance only — the
          names above are the MUD's, judge them yourself

model
  Nearest is the weapon shop, which I have already ruled out. The unexplored
  Main Street west of Market Square is two moves away and is the same street
  this row of shops sits on. Going there.

⚙ move(direction: "west")     → Main Street
⚙ move(direction: "west")     → Market Square
⚙ move(direction: "west")

── iteration 7 ──────────────────────────────────────────────────────────
injected [here]
  [here] Main Street
  exits: north→The Bakery ? | east→Market Square ✓ |
         south→The Armory ? | west→Main Street ?
  you: 84/84hp 100mana 75mv · lvl 10 · 0 gold · standing

model
  North is named The Bakery. That is the goal, one move away, and the state
  block already tells me — no need to route.

⚙ move(direction: "north")
  The Bakery
  You are in the bakery of Midgaard...

── iteration 8 ──────────────────────────────────────────────────────────
injected [here]
  [here] The Bakery
  exits: south→Main Street ✓
  here: the baker (mob — "you could take him")
  you: 84/84hp 100mana 74mv · lvl 10 · 0 gold · standing

model
  Found it. Recording the building so a later search for the baker or for bread
  starts here rather than in the street.

⚙ note_region(region: "The Bakery", kind: "shop", within: "Midgaard",
              note: "shopfront off Main Street, the baker is here")
  [region] The Bakery — flag planted
  here: The Bakery (#9), within Midgaard
  1 room in The Bakery, 8 in Midgaard, 1 crossing (south → Main Street)
```

**Nine iterations, eight moves, and the agent never left town**, even though
nothing in the tool chain knew what a bakery was. The tool contributed the room
names, the distances and the memory, whereas every decision that mattered — south
instead of the nearest exit, skipping the general store, abandoning the martial
quarter — came from the model reading names it was finally allowed to see.

Note what the flag did *not* do here, which is block anything. It was planted at
iteration 2, and its only effects in this session were to make the iteration-4
frontier list say "in Midgaard" and to persist a conclusion across compaction, so
its payoff comes in the next session, which is what §5 shows.

---

### 5. Journal B — the boundary, and getting it wrong

> **Superseded by §14.** The repair scene below only exists because membership
> was interpolated between distant flags. Under inheritance it cannot happen;
> §14.3 is the same walk without it.

Excerpt from a later session. Midgaard is mapped, the Midgaard flag is still in
Market Square, the goal is a hermit the agent has heard of and never found.

```text
── iteration 12 ─────────────────────────────────────────────────────────
injected [here]
  [here] Market Square
  exits: north→The Temple Square ✓ | east→Main Street ✓ |
         south→The Common Square ✓ | west→Main Street ✓
  you: 84/84hp 100mana 80mv · lvl 10 · 0 gold · standing

⚙ plan_route(destination: "hermit")
  [route] hermit — region_exhausted
  region: Midgaard (walled town · 31 rooms)
  reason: every remaining unexplored exit leaves Midgaard
  exits from the region:
    north → The Great Field Of Midgaard  from Behind The Temple Altar  (4 moves)
    west  → (unnamed)                    from Outside The West Gate    (6 moves)
    east  → (unnamed)                    from Outside The East Gate    (7 moves)
    south → (unnamed)                    from On The Bridge            (8 moves)
  next: if what you want may lie outside Midgaard, call
        plan_route(destination: "hermit", scope: "world")

model
  A hermit is by definition someone living away from people, so the town being
  exhausted is not a dead end here — it is the answer. Widening.

⚙ plan_route(destination: "hermit", scope: "world")
  [route] hermit — unknown
  region: Midgaard (walled town · 31 rooms)
  frontier: north from Behind The Temple Altar — leaves Midgaard
  path: north → north → north
  then explore: north (destination beyond this exit is not mapped)
  reason: no remembered room matches "hermit"; nearest unexplored exit at any
          scope; the names above are the MUD's, judge them yourself

⚙ move(direction: "north") ×3   → The Temple Square, By The Temple Altar,
                                   Behind The Temple Altar
⚙ move(direction: "north")

── iteration 17 ─────────────────────────────────────────────────────────
injected [here]
  [here] The Great Field Of Midgaard
    You are walking on a wide dirt path through the lush, green, fresh Midgaard
    countryside. You can see to the horizon to the north, east, and west; the
    busy city of Midgaard lies to the south...
  exits: north→The Great Field Of Midgaard ? | south→Behind The Temple Altar ✓
  you: 84/84hp 100mana 76mv · lvl 10 · 0 gold · standing

model
  The room says it outright — the city lies to the south, and I am on a path
  through countryside. I am outside Midgaard now. Recording that, so the next
  in-town search does not walk out here again.

⚙ note_region(region: "The Great Field", kind: "open countryside north of Midgaard",
              note: "description says the city of Midgaard lies to the south; open
                     ground to the horizon north, east and west")
  [region] The Great Field — flag planted
  here: The Great Field Of Midgaard (#44)
  2 known rooms now in The Great Field, 30 in Midgaard, 1 crossing:
    Behind The Temple Altar —north→ The Great Field Of Midgaard
  note: Behind The Temple Altar (#42) moved from Midgaard to The Great Field —
        it is 1 move from this flag and 4 from the Midgaard flag

model
  That last line is wrong and I should fix it now rather than let it settle.
  Behind The Temple Altar is inside the temple grounds, behind the altar; I
  walked from it into open countryside, and the countryside began when I left
  it. The assignment only happened because my Midgaard flag is way over in
  Market Square. Planting one on the town side of the actual edge.

⚙ move(direction: "south")
  Behind The Temple Altar
  ...

── iteration 18 ─────────────────────────────────────────────────────────
⚙ note_region(region: "Midgaard",
              note: "temple grounds, still inside the town; the countryside starts
                     one room north of here")
  [region] Midgaard — flag planted
  here: Behind The Temple Altar (#42)
  31 known rooms now in Midgaard, 1 in The Great Field, 1 crossing:
    Behind The Temple Altar —north→ The Great Field Of Midgaard
  note: Behind The Temple Altar moved from The Great Field back to Midgaard

model
  Boundary is where it belongs. Carrying on north.
```

Three things this excerpt is meant to expose for review:

1. **`region_exhausted` is a question, not a wall.** For a bakery the right
   answer is "search harder in town", whereas for a hermit it is "yes, leave",
   and because only the model can tell those apart the tool asks rather than
   deciding.
2. **The midpoint rule misfired, visibly, and the agent repaired it in one
   call.** That failure mode is inherent to flags-and-BFS, and I would rather it
   surfaced in a line of tool output the agent can act on than be smoothed over
   by a heuristic nobody can audit.
3. **The evidence the agent actually used was the prose** — "the busy city of
   Midgaard lies to the south". The movement cost did *not* change across this
   crossing, since both rooms are CITY (§1.1), so any terrain-based detector
   would have missed it entirely. That is the strongest single argument for
   leaving the judgement in the model, because the room said it in plain English
   and nothing else said it at all.

---

### 6. Schema (V5)

The schema is small because most of what the design needs is derived rather than
stored.

```sql
-- EARNED: what the agent decided, in its own words. Survives recompute.
CREATE TABLE regions (
  id            INTEGER PRIMARY KEY,
  label         TEXT NOT NULL UNIQUE,
  kind          TEXT,                          -- free text, the agent's words
  parent_id     INTEGER REFERENCES regions(id),
  first_seen_at TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

-- EARNED: one row per flag the agent planted. This is the input to everything
-- below and the only thing a human or a monitor can point at and say "the agent
-- claimed this".
CREATE TABLE region_flags (
  room_id     INTEGER PRIMARY KEY REFERENCES rooms(id) ON DELETE CASCADE,
  region_id   INTEGER NOT NULL REFERENCES regions(id) ON DELETE CASCADE,
  note        TEXT,                            -- the agent's stated reason
  planted_at  TEXT NOT NULL,
  session_id  TEXT
);

-- DERIVED: multi-source BFS output, rewritten wholesale on every recompute.
-- Same overwrite semantics as player_items, for the same reason — a stale
-- membership is a lie, not a history.
CREATE TABLE room_regions (
  room_id     INTEGER PRIMARY KEY REFERENCES rooms(id) ON DELETE CASCADE,
  region_id   INTEGER NOT NULL REFERENCES regions(id) ON DELETE CASCADE,
  hops        INTEGER NOT NULL,                -- moves to the flag that claimed it
  computed_at TEXT NOT NULL
);
CREATE INDEX idx_room_regions_region ON room_regions(region_id);
```

Crossings are not stored but `SELECT`ed as any known edge whose endpoints sit in
different regions, because they are a pure function of `room_regions` and storing
them would create a second thing to keep in sync.

Recompute is a full multi-source BFS over a few hundred rooms, which costs
microseconds, so it can afford to be exhaustive. `Hooks` marks the derivation
dirty when `discover` or `link_arrival` changes the graph or when a flag is
planted, and the recompute then runs lazily on the next read rather than inside a
MUD round trip.

The determinism obligations are the same as `RoutePlanner`'s: canonical direction
order, room id as the final tie-break for equidistant flags, and no reliance on
SQL row order without an `ORDER BY`.

---

### 7. Monitor

The answer to the first question in the notes is yes, and the monitor is where
the design gets audited rather than trusted.

**API.** `GET /api/knowledge/regions` sits beside the existing `knowledge/*`
routes (`api/config/routes.rb:44`) and returns regions with their `parent_id`,
their flags (room, note, when, which session), member room ids with `hops`, and
the derived crossings, while `knowledge#rooms` gains `region_id`.

**Map.tsx.** Region tint is drawn behind member cells, and **flags are drawn as
flags** so that they read as distinct from ordinary membership, because a flag is
a claim the agent made whereas a tinted cell is arithmetic. Crossing edges get
their own stroke and reveal both regions and both flag notes on hover, and a
`showRegions` toggle sits beside the existing `showFrontier`.

That distinction between a flag and a tinted cell is the whole point of the page.
`Map.tsx` already commits to showing where the picture stops matching the data
(`Map.tsx:43`), and region tint is simultaneously the most authoritative-looking
thing that page would ever draw and the least earned, so the flags that generated
it have to remain visible on top of it.

**A `Regions` page** beside `Frontier.tsx` carries one row per region — label,
the agent's own `kind` text, parent, room count, flag count, unexplored exits,
and each flag with the note the agent wrote when it planted it — so that a
misplaced boundary is diagnosable in one click by reading the agent's stated
reasons.

---

### 8. Prompt contract

```text
# Places
Rooms you have visited can be grouped into places you name yourself — a town, a
wilderness, a building. Nothing groups them automatically.

- `note_region(region:, kind:, within:, note:)` marks the room you are standing
  in. Every other known room joins whichever marked room is fewest moves away,
  so mark a room near an edge when you want the edge in the right place, and
  mark a new one if a boundary ends up wrong.
- Mark a place when you first recognise it, not later — it is what keeps a
  search inside a town instead of wandering out of the gate.
- `plan_route` searches your current place first, including anything within it.
  A known destination is routed to directly, however far outside it lies.
- `region_exhausted` means every unexplored exit leaves the place. It is a
  question, not a dead end: decide whether what you want plausibly lies outside,
  then call again with `scope: "world"`.
- Frontier lists give you the destination names the MUD printed. They are
  ordered by distance, which knows nothing about what those names mean. You do.
  Take the door you think is right.
```

The last bullet is both the one that matters most and the one the current prompt
is missing. Keeping `kind` and `note` as free text is the same commitment
expressed in the schema, since it means the agent's own words go into the store
unmodified.

---

### 9. Deliberately absent

- **A word list of any kind**, which rules out settlement/wilderness classes,
  portal words and a `kind` enum. The first version of this plan had one, and it
  is the thing being removed.
- **Automatic clustering.** No thresholds, no scores, no conductance. If the
  agent has planted no flags there is one region containing everything, and
  routing behaves exactly as it does today.
- **A destination-word prior** ("bakery ⇒ settlement"). Journal A gets that
  behaviour from the model at no cost and with no invented table.
- **Terrain classification from movement cost**, because §5 showed that the
  crossing which matters most in this world does not change movement cost at all.
- **A hard in-region filter**, since what the design offers instead is one
  overridable status rather than a wall.
- **Predicted boundaries for unvisited rooms.** A flag is only ever planted where
  the agent is standing. The cold-start case is handled by showing the agent the
  names and letting it choose, not by storing a guess as knowledge.

---

### 10. Separate bug found while reading the code

This is not boundaries work, but it surfaced while reading the code for that work
and it corrupts position tracking, so it should be filed and fixed on its own.

`reconcile_move!` (`hooks.rb:242`) gates everything on `look.complete?`, which
requires both a room name and an exits line. A room the character cannot see
supplies neither, so a move into an unlit room takes the rejection branch: it
records `record_frontier_attempt!(outcome: "failed")` and returns `{ ok: false }`
— while the character has in fact moved. `@current_room_id` then points at the
room the agent has left, and every subsequent state block, memory write and
route is anchored to a position the player is not in.

Relatedly, `check(exits)` prints a sentinel instead of a room name for a target
the character cannot see. `parse_exits` (`room_parser.rb:117`) cannot tell, so
that sentinel is stored as `room_exits.target_name` and becomes a searchable
"room name" — matchable by `DestinationSearch` and by `target_name_clue?`
(`route_planner.rb:208`), and rendered on the map as a labelled destination.

**Both need a captured fixture before either is fixed.** I have not read this
build's source and will not write a regex from remembered CircleMUD behaviour,
which is the same rule `parse_score` documents at `room_parser.rb:154`. Capture
the bytes for a dark `move` and a dark `check(exits)` first, then anchor the
parsing on them.

For boundaries specifically this needs no special handling, because an unlit area
is a place like any other: the agent names it if it wants to, and a room it
cannot describe simply never gets a flag.

---

### 11. Tests and evaluation

**Unit — region assignment.** Multi-source BFS determinism under shuffled row
order; equidistant flags resolved by room id; a re-planted flag moving a
boundary; crossings derived correctly from membership; `within:` nesting and
`scope: "region"` including descendants; one-way exits still never reversed for
routing; zero flags ⇒ one implicit region ⇒ ranking identical to today's.

**Unit — `note_region`.** Applies to the current room only; refuses when position
is unknown; re-flagging replaces and logs; free-text `kind` and `note` stored
verbatim; performs zero MCP calls.

**Planner.** `region_hops` outranks raw distance; `region_exhausted` fires only
when every frontier crosses; `scope: "world"` widens; a known destination routes
across a crossing under the default scope; the frontier list is complete and
carries `target_name` as the MUD printed it.

**Integration.** Recompute never runs inside a MUD round trip; a guard test
asserting no file under `lib/` references `data/world`.

**Scenario evaluation** — the harness from `54ce732`. Journals A and B become
scenarios (`find_bakery_cold`, `find_hermit_mapped`), run batched before and
after:

| Metric | Why |
|---|---|
| moves to first arrival | the headline |
| share of moves outside the starting region | the specific failure in the transcript |
| `note_region` calls, and how many were repairs | is the flag mechanism usable or fiddly |
| `region_exhausted` results the model correctly widened vs. wrongly accepted | is the refusal a question or a wall |
| crossings the agent declared vs. crossings it walked through | did the boundary track reality |
| `plan_route` calls per goal | regression guard from `plan_route.md` §10.7 |

The third and fourth rows are the ones to watch, because they are the design's
own failure modes — flags too fiddly to plant, or a refusal the model treats as a
stop sign — and neither of those is visible in a move count.

---

### 12. Delivery order

1. **Frontier visibility.** `plan_route` returns the full unexplored set with
   MUD-printed names and says the ordering is arithmetic. No schema, no new
   tool. Run `find_bakery_cold` here and record the number — §4 claims this
   alone fixes the reported transcript, and that claim should be measured
   before anything else is built.
2. **`note_region` + V5 + multi-source BFS.** Flags, derived membership, derived
   crossings.
3. **Scope.** `region_hops` in the ranking, `region_exhausted`, the renderer
   lines, the prompt section.
4. **Monitor.** `knowledge/regions`, tint, flags, crossing strokes, Regions page.
5. **Measure.** Batch both scenarios against §11's table.
6. **The dark-room bug**, on its own branch, after the fixtures exist.

Step 1 is independently shippable and is the test of the whole premise, since if
showing the agent the names does not change its behaviour then steps 2–4 rest on
a false assumption and should not be built at all.

---

### 13. The three questions, answered

**Can agent-defined boundaries show up on the monitor map?** Yes, as §7 sets out:
regions appear as tint, the agent's flags are drawn on top of that tint as flags,
crossings are marked edges, and a Regions page lists every claim alongside the
reason the agent gave for it.

**Should `plan_route` set where to reason to explore?** It owns **scope**, which
is a per-call constraint, and it reads regions that it does not create. It also
stops pretending there is one obvious frontier, and that is the change which
actually fixes the transcript.

**How will the agent reason to define boundaries?** By reading what the MUD
printed and saying what it concluded, since the code's entire contribution is to
show it the names it was previously hiding, give it one tool to record the
conclusion, and do arithmetic on the result.

## Human's Questions
- why are we planting flags with text, why wouldn't we simply associated them with a new region/boundary created. What does the text serve? In your example you plan a note about the bakery being in town, but wouldn't it make more sense to just keep adding to a boundary and then questioning when to review and split or defined boundaries? 
- It seems when as you increase the boundary size so does the frontier candidates returned back by plan_route, would this be an indicator to split boundaries
- so let say we do have a region note, which honestly could be directly on the region table, would it simply serve a description of what the region is
- and if we do need to split boundaries/regions to manage frontiers you could see Midgarrd being split East Town, West Town, North Town etc....
- are you stuffing the system prompt? I noticed our plan_route information is stuffed in there. Do we even need that much information and if we do is their a strategy to deal with a bloated system prompt?
- why are we waiting to name a region? If we are standing in an unknown region, why wouldn't we simply give it a temporary name, have a boolean on the record that it's unknown, feed that back in eg. "Midgaard Area (Not Confident)", and have the agent reason to update the name?

## Answers

Q1 and Q3 are straight concessions, and taken together they collapse §2, §3.1 and
§6 into something smaller. Q2 and Q4 identify the right problem, although I want
to argue with the mechanism they imply. Q5 is right, and rather than guess at the
size of the effect I measured it.

### A1 — the flags were cleverness; inheritance is better

There are two separate mistakes here, and one question found both of them.

**The note was decoration**, because nothing reads `region_flags.note`. I wrote
it as "evidence" and then never gave it a consumer, so it should be deleted (see
A3).

**The sparse-flag and BFS interpolation was the worse mistake**, because it
manufactured a failure mode that does not need to exist. The whole repair scene
in Journal B §5, where the agent walks back one room to fix a boundary, exists
*only* because I chose to interpolate membership between distant flags, so
removing the interpolation removes the bug that scene repairs.

What you are describing — just keep adding to a region — is the better
primitive:

> **A room inherits the region of the room you walked in from. The agent calls a
> tool only to say a different place starts here.**

| | flags + BFS (§2 as written) | inheritance + declared break |
|---|---|---|
| membership | interpolated, approximate | explicit, exact |
| tool calls | one per flag | **zero**, except at a boundary |
| boundary position | midpoint between flags, often wrong | exactly the edge the agent declared |
| repair needed | yes (Journal B) | no |
| what the agent declares | "this room is X" | "a different place starts here" — which *is* the boundary |

The second column is also more honest about what the agent knows, because the
agent never has to make a claim about a room it has not stood in and the
declaration happens at the moment the evidence arrives — standing in the Great
Field reading *"the busy city of Midgaard lies to the south"* — rather than being
back-derived later.

The tool therefore changes shape, from "plant a flag" to "a new place begins
here":

```text
⚙ note_region(region: "The Great Field", within: null,
              description: "open countryside north of Midgaard")
  [region] The Great Field — new place
  boundary: Behind The Temple Altar —north→ The Great Field Of Midgaard
  Midgaard: 31 rooms · The Great Field: 1 room · 1 boundary
```

The boundary is now literally a row — the arrival edge the agent was standing on
when it declared — and since `hooks.rb` already tracks that edge as
`@pending_arrival_edge` (`hooks.rb:255`), there is nothing new to compute.

This needs three rules, all of which the old design hid:

1. **A room that already has a region keeps it.** Inheritance only fills
   unassigned rooms; it never overwrites earned assignment.
2. **No arrival edge, no inheritance.** `flee`, a teleport, or a cold session
   start resolves position without a traversed edge. Those rooms stay
   unassigned until the agent says otherwise, rather than inheriting from
   wherever it happened to be last.
3. **Unassigned is a legitimate state.** Before the agent names anything, every
   room is in no region and `scope` degrades to exactly today's behaviour.

> Rules 2 and 3 are withdrawn by **A6**. There is no unassigned state: a room
> reached without an arrival edge seeds a provisional region instead. Rule 1
> stands.

### A2 — the list growing is real; the count is the wrong trigger

Two problems are tangled together in this question, and they want different
fixes.

**The rendering problem is real and independent of regions.** A tool result is
permanent in context, so a 40-line frontier list is paid for again on every
subsequent request for the rest of the session, which needs fixing whether or not
regions exist: return the nearest N grouped by source room, together with a count
of what was withheld.

```text
unexplored, in Midgaard — showing 6 of 18:
  north → The Weapon Shop                    (0 moves)
  ...
  12 more, 4–11 moves away
```

**On splitting, count alone is a bad signal**, because a real city has many doors
and is still one place. What tells you a region has stopped being a useful search
unit is not how many frontiers it has but **how far away they are**: "18
unexplored exits, nearest 11 moves" means that scoping to Midgaard no longer
narrows anything and the scope has stopped doing its job, whereas "18 unexplored
exits, nearest 1 move" describes a healthy dense town. The count is what you
notice first, but the distance is what carries the information.

The design therefore surfaces the shape and lets the agent draw the conclusion.

```text
region: Midgaard (31 rooms · 18 unexplored exits · nearest 11 moves, median 14)
```

This is the one place in the whole design where a threshold is genuinely
tempting — `if frontier_count > 20 then suggest split` — and I am declining it
for the same reason as the lexicon, since a number chosen now would be wrong for
the first region that is legitimately large. The agent reading two numbers can
tell "big and dense" from "big and stretched" without anyone having to decide in
advance where the line falls.

### A3 — yes, description belongs on the region

This is a full concession. The description becomes `regions.description`, written
by the agent, revisable, and held one row per place rather than one per flag,
which serves exactly what you described: what this place is, in the agent's own
words, for the monitor and for prose search.

The only per-location text worth keeping is an optional `reason` on the boundary
row — *"description says the city lies to the south"* — because that is the one
claim a human reviewing a wrong boundary needs to see, and because it is a
property of the edge rather than of the place. It stays optional and is never
required.

### A4 — yes, and it must be nesting rather than a flat split

I agree about the quarters, subject to one constraint on the mechanism and one
honest cost.

**Nest, do not partition.** If Midgaard is replaced by three peers — East Town,
West Town, North Town — the question "is this in town at all?" becomes
unanswerable, and that question is the original bug. `within:` keeps both:
`scope: "region"` means the current place *and everything within it*, so
standing in East Town scopes to East Town, and a search that starts from the
gate still scopes to all of Midgaard.

```text
Midgaard (walled town)
├── North Town        ← quarters, for narrowing a search
├── East Town
├── The Grunting Boar Inn   ← buildings, same mechanism
│   └── The Grunting Boar (the bar)
└── The Bakery
```

Your Inn→Pub and Guild→Guild Bar cases run on the same mechanism as the quarters,
which is a point in its favour.

**The honest cost is that retroactive splitting is awkward.** Under inheritance a
room keeps the region it already has, so carving East Town out of an
already-mapped Midgaard means either re-walking the quarter to declare its
internal boundary edges or having something *guess* which rooms belong, and that
guess is the midpoint rule returning through the side door.

The design therefore offers the exact operation and refuses the guess:

- **rename/re-parent the whole current region** in one call — "Midgaard is now
  North Town, within Midgaard" — which is exact and needs no semantics;
- **new quarters are declared going forward**, as the agent walks into them.

Splits therefore happen forward in time: retroactive partition without re-walking
is not offered, and the reason for that belongs in the document rather than being
discovered later.

### A5 — yes, and it is 43%

I measured this rather than guessing at it. The default `prompts/system.md` is
116 words, but `settings.yaml:100` sets `prompt_override.system: true`, so the
prompt actually in use is `.boukensha/prompts/player/system.md`:

| Section | Words | Share |
|---|---|---|
| preamble | 25 | 4% |
| `# Exploring` | 150 | 22% |
| **`# Navigation`** | **290** | **43%** |
| `# MUD Session` | 73 | 11% |
| `## Strategy` | 123 | 18% |
| **total** | **670 ≈ 930 tokens** | |

Nearly half the player's standing instructions are `plan_route` mechanics, and
most of that half is an enumeration of the tool's six return statuses, which
restates what the tool's own output already says at the moment it says it.

Four strategies follow, ordered most valuable first:

**1. Stop paying twice for the tool schema.** Tool descriptions are already sent
on every request (`prompt_builder.rb:15`), so anything in `# Navigation` that
describes what `plan_route` *is* belongs in its schema description instead, and
the prompt should say only when to prefer it.

**2. Teach at the point of use.** The six statuses do not need explaining in
advance if the result explains itself:

```text
[route] bakery — region_exhausted
next: if what you want may lie outside Midgaard, call
      plan_route(destination: "bakery", scope: "world")
```

That line teaches the widening move at the only moment it matters and costs
nothing on the turns where it does not, which makes it the largest lever
available. It applies directly to this plan, in that **guidance for boundaries
should go into `note_region`'s description and `plan_route`'s output rather than
into a new prompt section.**

**3. Keep policy, delete mechanics.** `# Navigation` should survive as roughly 40
words — prefer `plan_route` over eyeballing exits one at a time, re-plan after a
failure, and remember that frontier ordering is arithmetic and knows nothing
about meaning — while the status catalogue goes.

**4. "It's cached" is not a defence.** The system prompt is the stable prefix, so
with prompt caching the token cost is small after the first request of a session,
which means the cost that remains is attention rather than tokens: 290 words of
routing mechanics compete with the strategy section during a fight, and being
cheap does not stop them being a distraction.

**And measure it.** `54ce732` shipped the harness, and
`.boukensha/tests/scenarios/find_bakery.yml` already exists with a deterministic
gate (`max_model_tool_calls: 6`, `final_room: The Bakery`), so cutting
`# Navigation` to policy-only amounts to a one-line prompt edit and a batch run.
That is the only honest way to size a prompt section, and it can be done today,
before any of this plan is built.

**This applies to my own §8.** The `# Places` section I proposed runs to roughly
150 words, which would take the prompt to about 820 and Navigation plus Places to
54%. Under my own rule it should be about 40 words, with the rest moved into the
tool description and the tool output, so §8 needs rewriting before it ships.

### A6 — there is no reason to wait, and "unassigned" was a leftover

This is conceded, and it removes a state rather than adding one, because **every
room the agent has stood in is in a region from the first turn** and the region
simply does not have a confirmed name yet.

The unassigned state was inherited from the flags design, where a room with no
flag genuinely had nothing to belong to. Under inheritance that stopped being
true and I did not notice: the rooms were already grouped — by the edges the
agent walked — and calling that grouping "unassigned" was throwing away a fact
the store already had. A6 keeps it and admits what is missing, which is only
the name.

**One correction to the proposal, and it is the whole reason this is safe.** The
label `"Midgaard Area"` cannot be generated, because producing it would mean
parsing "Midgaard" out of "The Temple Of Midgaard" and appending a noun, which is
a lexicon and a confident-sounding one at that — exactly what §9 rules out. It
would also be wrong in this particular case, since the temple is *in* Midgaard
and a placeholder built from the seed room's name would have led the agent to
bless the placeholder rather than think about it. The placeholder is therefore
the seed room's name verbatim, bracketed to mark it as machine-made:

```text
region: ⟨from The Temple Of Midgaard⟩ — unconfirmed
```

That label reads as "the place that started at this room, and nobody has said
what it is", so it cannot be mistaken for a claim and it is useless enough to be
worth replacing, which is precisely the behaviour the design wants.

What this buys, beyond tidiness:

- **The unconfirmed tag is a standing question in the state block.** It asks for
  a name on every turn, at the moment evidence arrives, and disappears when
  answered. Compare A5: this is guidance at the point of use, costing four words
  instead of a prompt section, and costing nothing once the place is named.
- **`scope` works from turn zero.** No "with no regions, scope does nothing"
  special case — the current place is always a real, if unnamed, set of rooms.
- **The founding/back-fill case disappears**, and its over-claim failure mode
  with it (§14.5 previously listed it). Naming a place you are already in
  touches no membership at all.
- **Naming and A4's rename become one operation.** `name_region` renames the
  place you are standing in, whether it was called `⟨from …⟩` or "Midgaard".

The cost, stated plainly, is that the agent must now distinguish *"this place is
called X"* from *"a different place starts here"*, because the first of those
renames everything it is standing in. Those are two tools — `name_region` and
`split_region` — and confusing them is the new sharp edge, recorded in §14.5. The
old design had no such confusion because it had only one verb, but it paid for
that simplicity with a state that could not answer "where am I?".

### Design deltas

If you accept A1–A4, these sections are wrong as written:

| Section | Change |
|---|---|
| §2 | Replace flags + multi-source BFS with inheritance + declared break |
| §3.1 | `note_region` declares a *new place starting here*; drop per-room `note`, add `description` |
| §3.2 | `region_exhausted` gains the region shape line (rooms · exits · nearest/median distance) |
| §3.3 | Cap the frontier list, group by source room, report the withheld count |
| §5 | Journal B's repair scene is deleted — the failure it repairs no longer exists |
| §6 | `region_flags` → `region_boundaries` (edge + optional reason); `room_regions.hops` → `basis: inherited\|declared`; `regions.description` |
| §8 | Cut to ~40 words; move the rest into tool descriptions and tool output |
| §12 | Add step 0: ablate `# Navigation` against `find_bakery` before building anything |
| §3.1, §6 (A6) | `note_region` splits into `name_region` and `split_region`; `regions` gains `confirmed BOOLEAN` and a bracketed seed-room placeholder label; `room_regions` has no null case — every walked room is a member of something |

**§14 is those deltas written out as the journey they produce** — three journals
against the real map, replacing §4 and §5, so the design can be judged on what
it looks like to run rather than on what it claims.
---

## 14. The journey, under the revised design

§4 and §5 show the journey under a design that no longer exists, so this section
replaces them under the same rule as before: room names, exits and geography are
the real ones from `week0_explore/preview/data/world/wld/{30,31}.json`, and
**every count and distance in the tool output below was computed over that
data** rather than invented, which means any of it can be checked against a real
run. The model's lines are a sketch of the intended reasoning, whereas the tool
output is exactly what the contracts specify.

Three journeys, because they exercise three different parts:

| | Shows |
|---|---|
| **A′** cold start, find the bakery | frontier visibility; a provisional region asking for its name; what it costs to answer |
| **B′** find the hermit | the *split* — a boundary declared at the exact edge, no repair; inheritance running with zero calls |
| **C′** the mayor | Q2 and Q4 — a region that stopped narrowing anything, split into quarters going forward |

### 14.1 What the tools do, after A1–A6

**Every room the agent has stood in is in a region, always** (A6). There is no
unassigned state. A room the agent arrives in with no region and no arrival edge
to inherit one from opens a **provisional region** — named after the room that
seeded it, marked unconfirmed, and shown that way in every state block until the
agent says otherwise:

```text
region: ⟨from The Temple Of Midgaard⟩ — unconfirmed
```

The label is provenance rather than a claim, since it is the seed room's name
**verbatim** inside brackets that mark it as machine-generated. Nothing derives
"Midgaard Area" from "The Temple Of Midgaard", because that would be a lexicon
parsing English, which is what §9 rules out. The code names nothing at all: it
points at where the place started and admits it does not know what the place is.

Membership derives from the declarations plus the edge each room was first
entered by:

1. **A room takes the region of the room it was first entered from.** Free, no
   tool call, happens on every arrival.
2. **A declaration is a root** and overrides inheritance for that room.
   Everything downstream re-derives, so declaring late still fixes the rooms
   reached *through* the room being declared in.
3. **No arrival edge** — `flee`, a teleport, a cold start. If the room is already
   known it keeps the region it has; only a room that is new *and* unreached by
   an edge seeds a new provisional region.

Declarations are earned and never overwritten. Membership is derived and
rewritten wholesale on every recompute — the same overwrite semantics as
`player_items`, for the same reason: a stale membership is a lie, not a history.
That is what `basis: inherited|declared` in the §6 delta is recording.

Two operations, and the agent has to mean one or the other:

| | |
|---|---|
| `name_region(region:, within:, description:)` | **This place is called X.** Renames the region you are standing in — usually a provisional one — and clears the unconfirmed mark. No boundary is created, because no boundary moved. Naming it something that already exists **merges** the two. |
| `split_region(region:, within:, description:, reason:)` | **A different place starts in this room.** The boundary is the edge this room was first entered by, exactly; the room behind you keeps its region; everything you reached through this room comes with it. |

Splitting against the *arrival edge* is the whole mechanism, and it is why the §5
repair scene cannot happen. The rename is the operation A4 asked for, and it
turns out to be the same operation as naming a place for the first time.

`plan_route` changes in three ways, gaining a region shape line, a capped
frontier list grouped by source room, and `scope: region|world`.

**On the cap:** it shows **complete distance bands**, listing every unexplored
exit at the nearest distance, then every exit at the next distance, until about
half a dozen are on screen, followed by a count of the rest and its range. It
never cuts a band or a room in half, because a truncated list the agent cannot
reason about is worse than a short one: "the nearest ones are all here" has to be
true for the ordering to mean anything.

### 14.2 Journal A′ — cold start, find the bakery

Empty map memory, same starting room as the failing transcript at the top.

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

**Eight moves, two `plan_route` calls, one `name_region`, and the agent never
left town.**

Three things are worth weighing here, because together they are the honest
reading of this journal:

- **The naming call did nothing for this task**, since its only effect in this
  session was the "in Midgaard" header on the iteration-4 list. Everything that
  mattered — south instead of the nearest exit, skipping the named shops,
  abandoning the martial quarter — came from the model reading names it was
  finally allowed to see, which is the §12 step-1 claim and the reason step 1
  ships and gets measured before any of the region machinery is built.
- **The `— unconfirmed` tag is what asks for the name**, and it asks in the state
  block, on the turn the evidence arrives, at a cost of four words. No prompt
  section tells the agent to name places (A5: teach at the point of use), and the
  request stops appearing the moment it is answered, which is what A6 buys: an
  open question the agent can see rather than a silence it has to remember to
  break.
- **Compare the old §4 ending**, which planted a second flag on The Bakery. That
  call is gone, because under inheritance the bakery is in Midgaard for free and
  the agent only speaks up when it disagrees with what it inherited.

### 14.3 Journal B′ — find the hermit, and the declared break

Later session. Midgaard's streets are mapped (66 known rooms), the agent is in
Market Square, the goal is a hermit it has heard of and never found.

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

Compare against §5, which is the same walk under the old design:

- **The repair scene is gone.** In §5 the agent had to walk back one room and
  plant a second flag because BFS had swallowed Behind The Temple Altar into the
  countryside, whereas here the boundary *is* the edge it walked, so there is
  nothing to repair. The whole crossing costs one tool call, and there is no
  session in which the boundary sits silently in the wrong place.
- **Iteration 18 costs nothing.** The second field room joins The Great Field
  with no call at all, and the part worth noticing is that the agent's *default*
  scope followed it out of town automatically, so it never has to remember to
  change scope back.
- **`region_exhausted` did not fire, and should not have**, because Midgaard
  still had twelve unexplored doors. The status exists only for the case where
  every remaining exit crosses out, so here the model widened on meaning rather
  than on a status, which is the behaviour the design is actually betting on. The
  status is a convenience for when the arithmetic happens to agree, never the
  mechanism itself.

### 14.4 Journal C′ — the region stopped narrowing anything (Q2, Q4)

This is the journey the frontier-count question is really about. Both banks of
the river have been partly walked, the agent is standing on the south bank, and
the goal is the mayor, whose office it has never found.

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

model
  Sixteen doors at median six became eight at median three, nothing withheld,
  and every one on this side of the river. A mayor's office is civic and
  central — Emerald Avenue and the Promenade before the park.
```

Three things this exercises, in the order the questions were asked:

**Q2 — is a growing frontier list the signal to split?** The list is what the
agent notices, but the distances are what tell it anything, and both numbers sit
on one line with nothing branching on either. Journal A′ iteration 4 read *12
unexplored exits, nearest 0, median 2*, which describes a dense little town where
scope is working perfectly, whereas here it read *16, nearest 1, median 6* —
barely more doors, and yet the scope has stopped narrowing. A count threshold
would have fired on A′ and been wrong, while the pair of numbers separates the
two cases without anyone having to choose a line.

**Q4 — quarters.** `within:` gives both readings at once, so that standing on the
concourse "here" means 13 rooms, while a search that starts at the west gate
still scopes to all 66, because `scope: "region"` means the current place *and
everything within it*. Had the design partitioned Midgaard into peers instead,
"is this in town at all?" would have become unanswerable, and that question is
the original bug in the transcript at the top of this document.

**The retroactive split, and what it refuses.** Splitting the south bank worked
because the agent was standing at its entrance and everything in it had been
reached *through* that entrance. Carving "The Temple Quarter" out of the
already-mapped north bank has no such edge, since those rooms were reached by a
dozen different routes, so the design offers the exact operation and declines the
guess. That exact operation is one the agent has already used, being the same
`name_region` that turned `⟨from The Temple Of Midgaard⟩` into Midgaard in
Journal A′.

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

Renaming and re-parenting a whole region is exact, because it needs no semantics
and touches no membership, whereas subdividing an already-walked region does need
semantics and is therefore not offered at all: quarters are declared going
forward. That cost is real, and it belongs in the document rather than being
discovered later.

### 14.5 What this journey costs, and what stays wrong

The failure modes that survive, stated plainly so they can be judged now rather
than found in a transcript:

| | |
|---|---|
| **A late split only fixes what is downstream of it.** | If a room was reached by a route that does not pass through the room being split at, it keeps the region it inherited. Repair: split there too. Visible on the monitor as a room of the wrong tint on the wrong side of a boundary. |
| **`name_region` used where `split_region` was meant.** | This is the sharp edge A6 introduces. Walk town → gate → field without naming anything, then call `name_region("The Great Field")` in the field, and the whole town is renamed The Great Field, because the town is the place you are standing in. Mitigations: the unconfirmed tag pushes naming to the moment of recognition rather than fifty rooms later, and the tool prints the room count it renamed — `53 rooms carry the new name` is a loud line when the agent expected one. Repair: rename back, then split. |
| **A split made deep inside a place puts the boundary on an interior edge.** | The tool prints the edge it used, every time, so the mistake is legible in the same turn it is made. Prompt guidance: split in the first room of the new place. |
| **Provisional regions accumulate.** | Every teleport into unknown territory seeds one. Rule 3 keeps this bounded — an arrival in a *known* room never mints a new region — and two provisional regions that turn out to be one place merge by giving them the same name. Untidied, the cost is cosmetic: several unconfirmed places on the monitor, each correctly containing the rooms walked from it. |

None of these can put the agent somewhere it did not walk, and none of them
survives a declaration made in the affected room. That is the property being
traded for, because the old design's failure mode was a boundary in a place
*nobody declared*, which is the one kind of error whose cause the agent cannot
see.

**What the journals do not prove.** They remain a design sketch: the claim that
A′ takes eight moves rests on the model reading five room names correctly at
iteration 0, and the claim that C′ splits in the right place rests on it noticing
a median. Both of those are exactly what `54ce732`'s harness measures, so both
should be run — §12 step 0 and step 1 — before the schema in §6 is written.
