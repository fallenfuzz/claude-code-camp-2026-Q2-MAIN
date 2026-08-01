# Unreachable Destinations

Diagnosis and proposed fix for run `20260731T140528Z-34c846bf` (`explore_midgaard`,
session `20260731T140557Z-10b73c64`), the run the judge failed for coverage because
the agent asked to go to "The South Gate" nine times in a row and never moved.

Status: proposed, nothing implemented. Sections 1 through 4 are read off the recorded
session and off the map the run wrote; section 5 is the proposal and section 8 lists
what it deliberately leaves alone.

Everything below was reproduced by running the shipped `DestinationSearch` and
`RoutePlanner` against `.boukensha/profiles/Derrano/knowledge.sqlite3`, which holds
this run's final map — the scenario ran with `map_memory: none`, archiving the
previous database and starting from zero rooms, so the file is exactly what the
session built and nothing else.

## 1. What the run actually did

The judge's account is accurate and understates the size of the problem. The session
issued twenty-one model tool calls, and every single one of them was `move_to`; the
137 MUD calls and the room surveys underneath them were all automatic. Of those
twenty-one calls, **twelve returned `unreachable` and walked nothing**, one returned
`arrived` without moving, and two more walked one room north and then one room back
south, so fifteen of twenty-one model calls produced no coverage at all. The run
ended on `max_tokens` after $0.37 with seventeen rooms known.

The twelve dead calls fall into two groups, and the first group explains the second:

| calls | destination asked for | answer |
|---|---|---|
| `call_1c77c7a1cd94`, `call_0fc33ecda2d5` | "south on Wall Road", "Wall Road" | unreachable — routed to **The Temple Of Midgaard (#1)** |
| `call_9893156f149f`, then nine more through `call_da7fd650a53c` | "The South Gate" | unreachable — routed to **Inside The West Gate Of Midgaard (#11)** |

Neither of those is the room the agent named. The Temple is not on Wall Road and has
nothing to do with it, and Inside The West Gate is a different gate on the opposite
side of the city from the South Gate. In both cases the destination resolver
identified a room the agent had stood in, reported it with confidence, and then
reported that no route reached it.

The coverage failure the judge describes is downstream of this. After being told
twice that Wall Road was unreachable, the agent stopped naming places and called
`move_to(destination: "south")`, which walked six rooms straight down the western
wall and stopped on `max_decisions`. Following one corridor to its end is precisely
the behaviour the scenario marks as undesired, and it is what the agent fell back to
once naming a destination had twice produced nothing. The nine repeats at the end are
the same fallback failing: standing at the southwest corner with the words "The South
Gate" printed on the exit directly to the west, the agent asked for it by name nine
times and was told nine times that it was somewhere else and could not be reached.

## 2. Why the resolver named the wrong room

`DestinationSearch` ranks a room against a query in six tiers, and `RoutePlanner`
treats anything at tier 4 or better as a decisive identification — the room *is* the
destination, route to it or report it unreachable (`route_planner.rb:174`). Four
separate comparisons in that path can reach tier 4 or better on evidence that does
not identify a room, and this run tripped three of them.

**A single shared content word is enough for tier 3.** `token_overlap?`
(`destination_search.rb:118`) returns true when the query and the room name share one
token that is not a function word. The query "The South Gate" and the room name
"Inside The West Gate Of Midgaard" share `gate`, so room #11 matched at
`TIER_NAME_TOKEN` and became the destination. Nothing else in the map matched at any
tier better than 5:

```
query "The South Gate":
   tier=3 room=11 evidence=Inside The West Gate Of Midgaard
   tier=5 room=1  evidence=You are in the southern end of the temple hall...
```

Meanwhile the exact string "The South Gate" is sitting in the map, on room #17's own
west exit, unwalked:

```
room_id  direction  target_name         target_room_id  presumed_target_id
17       west       The South Gate      (null)          (null)
```

That row is `TIER_EXIT_TARGET_NAME`, tier 6, which is below the cut and therefore
cannot produce an answer while any tier-3 match exists. The agent was one move from
the place it kept asking for, the map recorded that fact verbatim, and the tier
ordering guaranteed the recorded fact would never be consulted.

**An entity description counts as a room identification.** `matching_entity`
(`destination_search.rb:143`) reaches `text_matches?`, which is the same
one-shared-token rule applied to the mob or object description. The Temple's automatic
teller machine is described as "An automatic teller machine has been installed in the
wall here", and the query "Wall Road" shares `wall` with it, so The Temple matched at
`TIER_ENTITY`. Because that is tier 4 it is decisive, and because rooms #12–#14 (the
actual Wall Road) did not exist yet when the query was made, it was also the only
candidate. That is how a request for Wall Road became a route to The Temple.

**Substring matching at tier 2 ignores word boundaries.** `name_norm.include?(q)`
(`destination_search.rb:95`) is a raw substring test, so the query "west" matches "The
Northwest End Of The Concourse" as a phrase. At `call_71277bc55909` the agent asked to
move west and the planner answered `known`, one step **north**, because room #16
matched at tier 2 and was one hop away while room #11 matched at the same tier and was
unreachable:

```
"west" -> status=known dest=16 steps=["north"]
```

The next call walked back south, which is the pair of wasted calls counted in §1.

**The frontier ranker has the stopword bug the search already fixed.**
`target_name_clue?` (`route_planner.rb:410`) tests
`(tokens(target_name) & tokens(q)).any?` without subtracting `STOPWORDS`, so for the
query "The South Gate" three of the four unexplored exits reachable from room #17 tie
at the top rank on the word "the" alone:

| exit | raw overlap | content overlap |
|---|---|---|
| `#17 east → On The Concourse` | yes (`the`) | no |
| `#17 west → The South Gate` | yes | yes, and an exact match |
| `#16 east → The Promenade` | yes (`the`) | no |
| `#15 north → Wall Road` | no | no |

Ties are broken by canonical direction order, and east precedes west, so even if the
tier-3 mismatch in the known branch were removed the ranker would have sent the agent
east. `STOPWORDS` was introduced in `DestinationSearch` for exactly this failure — its
comment records a session that spent twelve iterations being told it had arrived,
because "the" overlapped the name of whatever room the agent was standing in — and
`target_name_clue?` was written against the same data with the same bug and never
picked up the correction.

## 3. Why nothing was reachable either

The mismatch explains which room the planner aimed at. It does not explain
`unreachable`, and that has an independent cause worth fixing on its own terms: from
room #17 the known map graph reaches three rooms out of seventeen.

```
distances from 17: {17 => 0, 16 => 1, 15 => 2}
```

BFS walks an exit only when it carries an earned `target_room_id` or a presumed
`presumed_target_id` (`route_planner.rb:103`). Earned links are written by walking,
and a walk in one direction earns one directed edge, so the return edge exists only if
`ExitResolution` can presume it from the destination name the MUD prints beside the
exit. Three of the guards in `ExitResolution.resolve` (`exit_resolution.rb:30`)
prevent that here, and each guard is individually correct:

- The name "Wall Road" appears on three distinct rooms (#12, #13, #14), so it is
  poisoned as globally ambiguous and identifies none of them. The run recorded this
  itself, in `exit_name_ambiguity`.
- Room #13 has both a north exit and a south exit named "Wall Road", which is the
  within-room collision guard, and linking either would risk fusing two ends of a
  street into one room.
- A name that resolves to nothing leaves `presumed_target_id` null, which is the
  honest record.

The result is that the chain #11 → #12 → #13 → #14 → #15 is walkable southward and
has no northward links at all, and an agent that walks a corridor of same-named rooms
can never route back up it. Every destination behind the agent is `unreachable`, which
is a coverage failure in its own right regardless of what the resolver names.

The evidence needed to link those edges is already stored. Migration V5 added
`rooms.arrived_from_room_id` and `rooms.arrived_direction` (`schema.rb:293`) for the
region inheritance rule, and for this map they are complete:

| room | name | arrived from | by |
|---|---|---|---|
| 13 | Wall Road | 12 | south |
| 14 | Wall Road | 13 | south |
| 15 | On The Bridge | 14 | south |

Room #15's north exit is named "Wall Road" and the agent walked into #15 from #14
heading south one move earlier, and #14 is named "Wall Road". The name alone is
ambiguous between three rooms; the name *plus* the arrival is not ambiguous at all.

## 4. Why the answer invited nine retries

`render_unreachable` (`plan_route_tool.rb:203`) prints three lines and, when the
planner supplies them, an alternatives line:

```
[move_to] The South Gate — unreachable
walked 0 rooms in 0 legs
here: On The Concourse (#17)
[route] The South Gate — unreachable
to: Inside The West Gate Of Midgaard (#11)
reason: destination is remembered, but no known path connects room #17 to room #11
```

There were no alternatives to print, because the only tier-3 match was room #11
itself. The message therefore states a fact about a room the agent never asked for,
asserts that the destination "is remembered" — which reads as confirmation that the
place exists and is a reasonable thing to want — and names nothing the agent could do
instead. Identical text arrived nine times and there was no reason inside it to
expect the tenth call to differ.

This is not a case where the agent had the information and ignored it. The planner
computes BFS distances from the current room and holds the whole frontier set before
it takes the known branch, and on `unreachable` it discards both: the returned plan
carries `unexplored: []` and `unexplored_total: 0`. Suppressing the bogus tier-3 match
and asking the same planner the same question shows what was thrown away:

```
status=unknown  total=4
  d=0 #17 On The Concourse    [east → On The Concourse, west → The South Gate]
  d=1 #16 The Northwest End Of The Concourse [east → The Promenade]
  d=2 #15 On The Bridge       [north → Wall Road]
```

Four unexplored exits within two moves, one of them the destination that was asked for
nine times, all of it computed and then dropped on the floor.

## 5. Proposed fix

The organising decision is that the three defects are one defect at three call sites:
partial evidence about a *name* is being treated as identification of a *place*. The
fix is to make every name comparison in the navigation path apply the same content-word
rule, and to make the two answers that currently terminate a call carry what the
planner already knows.

### 5.1 One rule for comparing a query against a name

Three comparisons change, all in the direction of requiring the query to be fully
accounted for rather than partially echoed.

`token_overlap?` (`destination_search.rb:118`) requires that **every** content token of
the query appear in the field, rather than at least one. This is the rule that stops
"The South Gate" from matching "Inside The West Gate Of Midgaard", and because
`text_matches?` delegates to it, the same change stops the Temple's cash machine from
answering to "Wall Road". Genuine queries are unaffected: "Wall Road" still matches the
three Wall Road rooms at tier 1, "temple" still matches the two temple rooms at tier 2,
and "The Dump" still matches at tier 1.

Tier 2 (`destination_search.rb:95`) compares the query against token windows of the
name rather than as a raw substring, so "west" no longer matches "The Northwest End Of
The Concourse" while "the levee" still matches "The Dark Alley At The Levee".

`target_name_clue?` (`route_planner.rb:410`) subtracts `STOPWORDS` before testing
overlap, which is the correction `DestinationSearch` already carries. With that in
place the query "The South Gate" ranks room #17's west exit alone at the top instead
of tying it with two exits that share only the word "the".

The honest cost of the first change is that a query recalling a room imprecisely —
"bakery shop" for a room named "The Bakery" — no longer identifies it. That is a
demotion rather than a rejection, since the room still matches through its description
and still appears in the ranked results, but it does move such a query from the travel
branch to the exploration branch. To keep the evidence visible rather than silently
losing it, partial name overlap should become its own tier below `TIER_ENTITY` — call
it `TIER_NAME_PARTIAL` — so it continues to surface in `alternatives` and in frontier
ranking while no longer being decisive. This is the one part of the proposal with a
real trade-off in it, and the trade is deliberate: a partial match that is wrong costs
a stalled session, and a partial match that is right costs one extra move through the
frontier branch.

### 5.2 An exit the MUD has named is evidence about where a place is

Independently of the tier arithmetic, a query that exactly equals the `target_name` of
an unwalked exit from a reachable room is a strong statement about where that place
is, and it should not lose to a room match weaker than an exact or phrase name hit.
The proposal is a single check in `Planner#plan` before the known branch is taken:
when no room matches at `TIER_EXACT_NAME` or `TIER_NAME_PHRASE`, and some reachable
unwalked exit's normalized `target_name` equals the query, take the frontier branch.

Exact room matches still win, so asking for "Wall Road" from the concourse routes to
the Wall Road the agent has stood in rather than exploring toward the one printed on
#15's north exit. With §5.1 in place this check is redundant for the recorded run, and
it is proposed anyway because it states the guarantee directly instead of leaving it as
a consequence of where the tier boundaries happen to fall.

### 5.3 The arrival edge resolves the ambiguity the name cannot

`ExitResolution.resolve` gains an `arrivals:` argument carrying
`rooms.arrived_from_room_id` and `arrived_direction`, and one rule that runs before the
ambiguity guards: an unlinked exit may be presumed to lead to the arrived-from room
when its direction is the exact reverse of the arrival direction **and** its
`target_name` normalizes to that room's name. Both conditions are required. The
direction alone would assume every passage is two-way, and the name alone is what the
guards already correctly refuse; together they say the agent walked in from that
specific room by that specific direction and the exit facing back the way it came is
labelled with that room's name.

The three guards stay exactly as they are for every other exit. What this adds is a
narrow case in which the evidence is local and specific rather than a global name
lookup, which is why the within-room collision on room #13 — north and south both
named "Wall Road" — stops being fatal: the arrival names which of the two is the way
back, and the other is already earned.

The link is presumed rather than earned, so BFS continues to rank it behind every
walked edge, the mismatch check at `hooks.rb:629` still logs the conflict, and
`Store#refute_presumed_target!` still clears the edge if walking it lands somewhere
else. A genuinely one-way passage therefore costs one move and one corrected edge,
not a corrupted map. One detail of the refutation path needs adjusting alongside this:
`refute_presumed_target!` also poisons the target name, which is the right response
when the presumption was made *from* that name and the wrong one here, since a
reverse-arrival link that turns out to be wrong says something about the passage
rather than about the name. The call should skip the poisoning for links made on
arrival evidence.

Applying this rule to the recorded map adds five links and reconnects the graph:

```
link #10 east -> #9  (Main Street)
link #11 east -> #10 (Main Street)
link #13 north -> #12 (Wall Road)
link #14 north -> #13 (Wall Road)
link #15 north -> #14 (Wall Road)

distances from 17 now: all seventeen rooms, #1 at eleven hops
```

### 5.4 A refusal that names somewhere to go

`unreachable` and `exhausted` should carry the unexplored view that
`frontier_branch` already builds, because the planner has computed the BFS distances
and holds the frontier set by the time it decides to return either of them. That means
computing `unexplored_view` for those statuses and printing it in
`render_unreachable` and `render_exhausted` under the same soft cap the explore branch
uses.

Against the recorded session this is what changes the ninth call from a repeat into a
choice: the answer would have listed four unexplored exits at distances zero to two,
including the one the agent was asking for, instead of a bare assertion about a room on
the other side of the city.

## 6. What the fix does to the recorded run

The proposal engages at `call_1c77c7a1cd94`, the first request for Wall Road. Under
§5.1 the Temple's cash machine no longer answers to it, no room matches decisively, and
the frontier branch ranks room #11's own unwalked south exit — named "Wall Road" — at
the top, so the call walks south instead of returning nothing. The second Wall Road
call never happens, and neither does the fallback to `move_to("south")` that produced
the six-room single-corridor walk.

At the concourse, "The South Gate" matches no room at all and matches room #17's west
exit exactly, so the first request walks one move west into the South Gate and the
other nine have nothing to be about. `move_to("west")` walks west rather than north,
which removes the oscillating pair as well.

If the agent nevertheless reached a state where a named destination were unreachable,
§5.3 would have kept the whole map routable from the concourse and §5.4 would have
answered with four doors and their distances. Fifteen of the run's twenty-one wasted
or dead calls are addressed, and the budget they consumed — roughly 57% of the model
calls in the session — goes back to walking.

## 7. Tests

The existing suites cover each of these call sites and pass, which is how this reached
a live run: every one of the defects is a case the tests do not distinguish from the
behaviour they assert. What would need adding:

- `test_navigation_destination_search.rb` — a query sharing one content word with a
  room name does not identify it; a query whose content words are all present still
  does; "west" does not match "The Northwest End Of The Concourse"; an entity
  description sharing one word with the query does not identify its room.
- `test_navigation_route_planner.rb` — frontier ranking on a query whose only overlap
  with three candidate exits is a function word picks the exit that matches on
  content; an exact unwalked exit name beats a partial room-name match and loses to an
  exact one.
- `test_exit_name_resolution.rb` — the reverse-arrival link is made through a
  globally ambiguous name and through a within-room name collision, and is refused
  when the reverse exit's `target_name` names some other room or when the direction is
  not the reverse of the arrival.
- `test_plan_route_tool.rb` — `unreachable` and `exhausted` print the unexplored view.
- `test_move_to.rb` — the recorded failure in miniature: a request for a place named on
  an unwalked exit of the current room walks that exit rather than answering
  `unreachable` about a room elsewhere.

## 8. What is deliberately not proposed

**No cross-call repeat counter.** `dark_rooms_and_stuck_walks.md` §4.6 declined one on
the grounds that repairing the position removes the state a counter would guard, and
the same conclusion holds here for a different reason: the answer this run repeated was
correct given the map it was computed from, so there is no desync to detect. What made
it repeatable was that it carried no alternative, which §5.4 fixes at the source. A
counter would be machinery that notices the tenth identical answer without improving
any of the first nine.

**No widening of the region scope.** The whole run stayed inside one region and
`region_exhausted` never fired, so scope had no part in this failure and changing it
would be a change made on no evidence.

**No new vocabulary in the parser.** Nothing in the proposal reads a tbaMUD string.
The failure is in how two names are compared, not in which names the system has been
taught, and a fix that enumerated "gate" or "west" as special would leave the class of
failure exactly where it is.

**No reordering of the tier cut in `RoutePlanner`.** Treating tier 4 and better as
decisive is the right boundary; the problem is that three comparisons reach tier 4 on
evidence that should never have got there, and the fix belongs at those comparisons
rather than at the line that reads their output.
