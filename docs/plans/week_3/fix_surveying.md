# Fix Surveying

Implementation plan for the defects diagnosed in
[movement_revisited/unreachable_destinations.md](movement_revisited/unreachable_destinations.md),
which explains why run `20260731T140528Z-34c846bf` spent fifteen of its
twenty-one model calls producing no coverage and asked to go to The South Gate
nine times while standing next to it. That document is the evidence; this one is
the work, and it does not repeat the diagnosis except where a number is needed to
state a gate.

The organising claim is that one change carries the run and the other three are
insurance. Step 1 is therefore built and measured on its own before anything else
is written, and if it does not do what §2 of the diagnosis says it will, the rest
of this plan is built on a wrong reading and should be stopped rather than
continued.

## 1. Baseline

Everything below is measured against the recorded run, whose facts block reports
twenty-one model tool calls (all of them `move_to`), seventeen rooms known, and
`end_reason: max_tokens` at $0.366. Three further numbers come from replaying the
shipped `DestinationSearch` and `RoutePlanner` against the map the run wrote:

- Twelve of the twenty-one calls answered `unreachable` and walked nothing; three
  more walked nothing useful, for fifteen calls without coverage.
- BFS from room #17 reaches three of seventeen rooms, so most of the map is
  unroutable from where the agent finished.
- The planner held four unexplored exits at distances zero to two — one of them
  the destination being asked for — and discarded them on the `unreachable` path.

## 2. Delivery order

0. **Instrument the answer.** Add a `move_to.answered` journal event carrying the
   status and the number of rooms walked, and derive a `no_progress_calls` fact in
   the scenario report from it. This is a few lines and it is what turns every gate
   below into a number rather than a reading of the transcript. Nothing else in this
   plan depends on it, so it can land first and alone.

1. **Content-token discipline** (§3.1, §3.2). Three comparisons and one new tier.
   No schema, no new tool, no MUD I/O. **Gate:** the deterministic fixture assertion
   in §5 must pass, and a re-run of `explore_midgaard` must show no destination
   string answered `unreachable` more than twice and `rooms_known` above seventeen.
   If the fixture assertion fails, the diagnosis is wrong; if it passes and the live
   run does not improve, the resolver was not what was holding the agent back and
   steps 2–4 should be reconsidered before being built.

2. **Refusals that name somewhere to go** (§3.3). Rendering only, no planner logic
   beyond calling a function that already exists on a path that currently skips it.
   **Gate:** an `unreachable` answer prints at least one unexplored exit whenever one
   is reachable.

3. **Exit names resolve against candidates** (§3.4). Schema-free; extends
   `ExitResolution` and its one caller. **Gate:** on the recorded map fixture, BFS
   from room #17 reaches all seventeen rooms rather than three.

4. **Two questions, not one ranked list** (§3.5). The design correction. Build it
   last, because with step 1 in place it changes no outcome in the recorded run and
   its value is entirely in the runs that have not happened yet.

5. **Measure.** Batch `explore_midgaard` against the table in §5.

## 3. The changes

### 3.1 One rule for comparing a query against a name

Three call sites currently let partial evidence about a name stand as
identification of a place, and all three move in the same direction: the query
must be fully accounted for, not partially echoed.

`DestinationSearch#token_overlap?` (`destination_search.rb:118`) requires every
content token of the query to appear in the field rather than at least one:

```ruby
def token_overlap?(q_tokens, field_tokens)
  return false if q_tokens.empty? || field_tokens.empty?

  content = q_tokens - STOPWORDS
  content.any? && (content - field_tokens).empty?
end
```

Because `text_matches?` delegates here, this one change covers tiers 3 and 5 and,
through `matching_entity`, tier 4. It is what stops "The South Gate" identifying
"Inside The West Gate Of Midgaard" on the shared word `gate`, and what stops "Wall
Road" identifying The Temple through a cash machine "installed in the wall here".

The phrase tier (`destination_search.rb:95`) compares against token windows rather
than as a raw substring, so that "west" stops matching "The Northwest End Of The
Concourse" while "the levee" keeps matching "The Dark Alley At The Levee":

```ruby
return { room_id: room[:id], tier: TIER_NAME_PHRASE, evidence: room[:name] } if
  phrase_match?(tokens(room[:name]), q_tokens)

def phrase_match?(name_tokens, q_tokens)
  q_tokens.any? && q_tokens.size <= name_tokens.size &&
    name_tokens.each_cons(q_tokens.size).any? { |window| window == q_tokens }
end
```

`RoutePlanner#target_name_clue?` (`route_planner.rb:410`) subtracts `STOPWORDS`
before testing overlap, which is the correction `DestinationSearch` already carries
and this function was written without:

```ruby
norm = DestinationSearch.normalize(frontier[:target_name])
norm == q ||
  ((DestinationSearch.tokens(frontier[:target_name]) & DestinationSearch.tokens(q)) -
    DestinationSearch::STOPWORDS).any?
```

The substring arm of the old condition goes with it, for the same reason the phrase
tier loses its. This third edit is not optional and it is the one most likely to be
dropped as cosmetic: with the first two edits but not this one, "The South Gate"
does reach the frontier branch and is then ranked **east**, because three of the four
nearby exits tie at the top on the word "the" and east precedes west in canonical
direction order. The stall survives all the way to the ranking function.

### 3.2 Partial name evidence keeps its place

Tightening tier 3 means a query that recalls a room imprecisely — "bakery shop" for
a room named "The Bakery" — stops identifying it. That is the intended effect and it
has a cost, so the evidence should be demoted rather than discarded: add
`TIER_NAME_PARTIAL` below `TIER_ENTITY`, returned where the old single-token overlap
fired, so such a match still appears in `alternatives` and still informs frontier
ranking while no longer being decisive.

No change is needed at `route_planner.rb:174`, which already cuts the decisive set at
`TIER_ENTITY`. The tier boundary was never the problem; what was wrong is which
comparisons could reach it.

### 3.3 A refusal that names somewhere to go

`known_branch`'s unreachable path (`route_planner.rb:263`) returns `unexplored: []`
and `unexplored_total: 0` despite the planner having computed BFS distances from the
current room and holding the whole frontier set. Call `unexplored_view` there and on
the `exhausted` path, and print the result in `render_unreachable` and
`render_exhausted` (`plan_route_tool.rb:203`) under the soft cap the explore branch
already uses.

This is the change that makes a repeated dead end impossible rather than merely
unlikely, because the second answer to a stalled query stops being byte-identical to
the first. Against the recorded session the ninth call would have listed four doors
at distances zero to two, one of which was the destination being asked for.

### 3.4 Exit names resolve against candidates, not a global index

`ExitResolution.resolve` (`exit_resolution.rb:30`) asks whether a name identifies
exactly one known room, and gives up when it does not. That is why the three rooms
named "Wall Road" poisoned the name, why every northward return edge along the
western wall stayed unlinked, and why BFS from room #17 reaches three rooms. The
rooms are not actually indistinguishable — all three carry distinct weak *and*
strong fingerprints — so the question being asked is weaker than the evidence on
hand.

The narrow version, which is what step 3 builds: `resolve` takes an `arrivals:`
argument carrying `rooms.arrived_from_room_id` and `arrived_direction`, and an
unlinked exit may be presumed to lead to the arrived-from room when its direction is
the exact reverse of the arrival direction **and** its `target_name` normalizes to
that room's name. Both conditions are required, because the direction alone would
assume every passage is two-way and the name alone is what the existing guards
correctly refuse. Together they say the agent walked in from that specific room by
that specific direction one move earlier and the exit facing back the way it came
carries that room's name.

The three existing guards are untouched for every other exit. What this adds is a
case where the evidence is local rather than a global name lookup, which is why the
within-room collision on room #13 — north and south both named "Wall Road" — stops
being fatal.

One adjustment travels with it: `Store#refute_presumed_target!` (`store.rb:472`)
poisons the target name as well as clearing the edge, which is right when the
presumption was made *from* that name and wrong here, since a reverse-arrival link
that proves wrong says something about the passage rather than about the name. The
call needs to know which kind of presumption it is refuting and skip the poisoning
for this one.

Applying the rule to the recorded map adds five links — `#10 east → #9`,
`#11 east → #10`, `#13 north → #12`, `#14 north → #13`, `#15 north → #14` — and
takes reachability from room #17 from three rooms to all seventeen, with The Temple
eleven hops away.

### 3.5 Two questions, not one ranked list

The structural correction, and the reason the other three read as patches. The
system asks "where is the place the agent named" as a single ranked list of rooms,
but two different questions are hiding inside it:

- **Which room that I have stood in is this?** Answered from content — name,
  description, entities — which is the same kind of evidence `Memory::Fingerprint`
  already uses to answer "have I been here before".
- **Which door leads to the place named?** Answered from exit labels, and the answer
  is a frontier rather than a destination, because the place has never been entered
  and nothing is known about it except where it is.

Collapsing both into one list is what let a tier-3 room match bury an exact tier-6
exit label. The concrete change is a check in `Planner#plan` before the known branch
is taken: when no room matches at `TIER_EXACT_NAME` or `TIER_NAME_PHRASE`, and some
reachable unwalked exit's normalized `target_name` equals the query, take the
frontier branch. Exact room matches still win, so "Wall Road" from the concourse
routes to a Wall Road the agent has stood in rather than exploring toward the label
on #15's north exit.

With §3.1 in place this changes nothing in the recorded run, which is exactly why it
is step 4 and not step 1. It is worth building anyway because it states the rule
directly — content identifies places you have been, position identifies places you
have not — instead of leaving it as a consequence of where tier boundaries happen to
fall.

## 4. Tests

The existing suites pass against every one of these defects, which is how the run
happened, so each step needs coverage that distinguishes the new behaviour from the
old rather than merely exercising the path.

For §3.1 and §3.2, in `test_navigation_destination_search.rb`: a query sharing one
content word with a room name does not identify it, while a query whose content words
are all present still does; "west" does not match "The Northwest End Of The
Concourse" and "the levee" still matches "The Dark Alley At The Levee"; an entity
description sharing one word with the query does not identify its room; a demoted
partial match still appears in the results at `TIER_NAME_PARTIAL`. In
`test_navigation_route_planner.rb`: frontier ranking on a query whose only overlap
with three candidate exits is a function word picks the fourth exit, the one matching
on content.

For §3.3, in `test_plan_route_tool.rb`: `unreachable` and `exhausted` print the
unexplored view, and print nothing extra when no frontier is reachable.

For §3.4, in `test_exit_name_resolution.rb`: the reverse-arrival link is made through
a globally ambiguous name and through a within-room name collision; it is refused
when the reverse exit's `target_name` names some other room, and when the direction
is not the reverse of the arrival; refuting it clears the edge without poisoning the
name; and `test_one_way_exits_are_not_reversed` continues to pass unchanged, since it
is the regression guard for the week 2 decision this rule sits closest to.

For §3.5 and as the end-to-end statement, in `test_move_to.rb`: a request for a place
named on an unwalked exit of the current room walks that exit rather than answering
`unreachable` about a room elsewhere.

## 5. How we know it worked

**Deterministic gate.** Build the recorded seventeen-room Midgaard map as a fixture —
`exit_name_resolution.md` already recommends this and `test/fixtures/rooms.json`
carries the world-file rooms and their `exit_targets` to build it from — and assert
against it directly. These are the three assertions that carry the plan, and each is
a measured fact from the replay rather than an expectation:

| after step | assertion |
|---|---|
| 1 | `plan(query: "The South Gate", current_room_id: 17)` returns `explore` with frontier `{ room_id: 17, direction: "west" }` |
| 1 | `plan(query: "west", current_room_id: 17)` does not return a route whose first step is `north` |
| 3 | `RoutePlanner.distances(from: 17)` covers all seventeen rooms |

**Live gate.** Re-run the scenario with `boukensha -ts explore_midgaard`, batching
once steps 1–3 are in. Compare against the recorded baseline:

| fact | recorded | expected |
|---|---|---|
| `no_progress_calls` (new, step 0) | 15 of 21 | at most 3 |
| repeats of any one destination string | 9 | at most 2 |
| `rooms_known` | 17 | above 17 |
| `end_reason` | `max_tokens` | unchanged or better |

The judge verdict is deliberately not a gate. Coverage also depends on the model's
own choice of destinations, and a plan that promised a pass would be claiming credit
for something these changes do not control. What they control is that a named
destination resolves to the right place, that the map stays routable behind the
agent, and that no answer can be repeated nine times without changing — and those are
the four numbers above.

## 6. What stays wrong

**No repeat counter.** `dark_rooms_and_stuck_walks.md` §4.6 declined one because
repairing the position removed the state it would guard, and the same conclusion
holds here for a different reason: the answer this run repeated was correct given the
map it was computed from, so there is nothing to detect. What made it repeatable was
that it carried no alternative, which §3.3 fixes at the source.

**No embeddings, and no FTS5.** The escalation comment at `destination_search.rb:12`
gates them on a logged failure, and this run is a logged failure of *precision* — a
match was made that should not have been — rather than of recall. A method that finds
more would make this class of failure more likely, not less, and the two cases that
broke this run are the ones semantic matching handles worst, since "The South Gate"
and "Inside The West Gate Of Midgaard" are near-identical in meaning and differ only
by a compass direction. There is a real case for semantic matching in frontier
ranking, where a wrong answer costs one move and is corrected by walking, and none in
destination identification, where a wrong answer costs a session.

**The maze case.** Two rooms identical in name, prose and exit directions still share
a weak fingerprint, and §3.4's rule will link a reverse edge to whichever the arrival
recorded. That is correct by construction here, because the arrival is a fact about
which room was actually left, but it is worth naming as the place where content-based
identity runs out.

**Partial recall costs a move.** Under §3.1 a half-remembered room name routes through
the frontier branch instead of travelling directly. `TIER_NAME_PARTIAL` keeps the
evidence visible, but the agent that says "bakery shop" for "The Bakery" now explores
toward it rather than walking to it. This is the one place the plan trades a small
regular cost for the removal of a large occasional one, and it should be revisited if
a run shows it mattering.
