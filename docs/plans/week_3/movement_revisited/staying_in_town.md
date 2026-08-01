# Staying In Town

Diagnosis and proposed fix for run `20260731T171650Z-09259cd5` (`explore_midgaard`,
session `20260731T171719Z-e39eb364`), the run that produced the first genuinely
usable Midgaard map — forty-one rooms, eight regions, both gates, the wall road and
the bridge — and failed anyway, because fifteen of those forty-one rooms are
countryside outside the city walls.

Status: implemented. Sections 1 through 8 are read off the recorded session log,
the journal for `20260731`, the retained knowledge database under
`.boukensha/tests/knowledge/sessions/Derrano/`, and the current source of
`ClaimPlanner`, `Predicates`, `SurveyGraph`, `RoutePlanner`, `RegionTools` and
`MoveTo`. Sections 9 through 13 are the proposal, and section 14 lists what it
deliberately leaves alone.

The implementation lands as schema V10 (`frontier_hints.egress`,
`region_boundaries.kind`), `Navigation::Egress` and its `Guard`, the survey-side
consumers in `SurveyGraph`, `ClaimPlanner` and `Predicates`, the navigator's
`leaves_region` veto and the post-step backstop in `MoveTo` and `Survey`, and
`rooms_outside_scope` in `SessionFacts` gated by `max_rooms_outside_scope`.
`test/test_staying_in_town.rb` carries one test per acceptance criterion in §12.

Two things were settled during implementation that §10 left open. The backstop is
wired into survey mode as well as travel, because §10.4 names "a hint that was
absent" among the cases it exists for and a hint is a survey concept; and
`Survey`'s `region_exhausted` did not in fact print the `scope: "world"` remedy
§10.2 assumed it already printed, so it does now. The `move_to` tool description
stands unchanged, per §10.6.

Revision note: the first draft of this document proposed detecting a departure by
comparing the region a room is assigned to against the region the call started in.
Section 8 is new and shows why that cannot work — the region tree this system builds
records the order in which regions were carved apart rather than which places
contain which — and sections 10 and 13 are rewritten to rest on recorded boundary
crossings instead. The diagnosis in sections 1 through 7 is unchanged.

This run is the first `explore_midgaard` to pass every mechanical gate and fail on
the judge alone, which is worth stating plainly because it changes what the failure
means:

| fact | recorded | gate |
|---|---|---|
| `tool_called` | `move_to` at `call_cce9d9604db2` | passed |
| `no_progress_calls` | 1 of 20 | `max_no_progress_calls: 3` — passed |
| `max_destination_repeats` | 2 | `max_destination_repeats: 2` — passed |
| `rooms_known_delta` | 41 | not gated |
| rooms outside the city walls | 15 of 41 | not gated, and not measurable today |

The two conduct ceilings `fix_surveying.md` added were built to catch a run that
spent its budget without covering ground, and they caught nothing here because this
run covered ground extremely well. It covered the wrong ground for fifteen rooms of
it, and the only thing in the whole harness that noticed was a Sonnet judge reading a
rubric line the agent could not see.

There are four independent defects, and a fix for any one alone still leaves the run
failing. The survey walked into the fields on three consecutive legs after its own
surveyor had written that the fields were out of scope (§3). Travel mode walked out
of both gates because the player asked for bearings rather than places and nothing
in the walking engine treats a bearing differently from a destination (§4). Once
outside, the agent could not express "go back", because the frontier branch only
offers unexplored exits and the navigator's correct answer was discarded by a
fallback (§5). And underneath all three, the rule the run was graded on was never
written anywhere the run could read it (§6).

## 1. What the run actually did

The session issued twenty model tool calls over twenty iterations, made 273 MUD
calls in 256 seconds for $0.45, and ended on `max_tokens` standing in On The
Concourse with forty-one rooms and eight regions known. Every one of the twenty
model calls was `move_to`.

The first call was a survey and it did most of the work: twenty-five rooms in
fourteen legs and eight surveyor calls, opening six claims, confirming three,
recording twenty-one pieces of evidence and settling four. It returned `surveyed`
with the honest completion condition — no open claim had a decisive test left within
the remaining budget. The other nineteen calls were travel to named destinations
chosen by the player between iterations.

The map it left behind divides cleanly along the city wall:

| rooms | where | how they were reached |
|---|---|---|
| 1–6, 12–18, 26–31, 35–41 | inside Midgaard | survey and travel |
| 7, 8, 9 | The Great Field Of Midgaard | survey, legs 6, 7 and 8 |
| 10, 11 | Newbie Zone entrance, The Dirt Path | survey, legs 9 and 10 |
| 19–25 | outside the East Gate, through The City Entrance, The Laneway, The Lane, The King's Road and two Overgrown Trail rooms | travel |
| 32, 33, 34 | outside the West Gate, A Road Through The Plains | travel |

Eight regions were created during the run, and two of them — `The Plains` and
`The East Gate` — are the system correctly recording that it had gone somewhere
else. The cartographer declared region boundaries at rooms 19 and 32, which are
precisely the two rooms immediately outside the two gates. The machinery that knows
where the town ends worked; it simply ran after the crossing and changed nothing
about it.

## 2. The three departures

The survey left town at leg 6, when it walked north out of Behind The Temple Altar
into The Great Field Of Midgaard, and then kept going north for two more legs and
west and east for two more after that. Rooms 7 through 11 were all discovered
between 17:19:05 and 17:19:31.

Travel left town eastward on `call_5309c2625088`, whose destination was
`"The Grunting Boar bar and beyond to the east"`. The recorded legs read as a
straight line:

```
leg 1: east → The Grunting Boar
leg 2: west → west → south → east → Main Street
leg 3: east → Main Street
leg 4: east → Inside The East Gate Of Midgaard
leg 5: east → Outside The East Gate Of Midgaard
leg 6: east → The City Entrance
stopped on budget: max_decisions (6) reached
```

Travel left town westward on `call_3604a4fca617`, destination
`"Main Street heading west"`, in the same shape:

```
leg 1: west → west → west → Main Street
leg 2: west → Main Street
leg 3: west → Inside The West Gate Of Midgaard
leg 4: west → Outside The West Gate Of Midgaard
leg 5: east → A Road Through The Plains
leg 6: east → ...
stopped on budget: max_decisions (6) reached
```

Both walks ran to the full `max_decisions` of six and stopped only because the
budget ran out, which means the budget is the only thing in the system that ended
either of them. Neither walk was ever going to stop at the gate, because nothing in
the walking engine knows a gate is different from a street corner.

## 3. Why the survey walked into the fields

### 3.1 The surveyor saw it coming and wrote it down where nothing could read it

The `frontier_hints` table retained from the run contains the surveyor's own
annotations, and on the exits that led into the countryside they say exactly what
the judge later said:

| room | direction | `expected_class` | `assessability` | `hazard` | note |
|---|---|---|---|---|---|
| 6 | north | civic | assessable | none | "The Great Field Of Midgaard — open countryside north of the temple, likely a field or parkland **beyond the town boundary**; low relevance to street/river mapping" |
| 7 | north | civic | assessable | none | "almost certainly a multi-room expanse of field with no street-network or river content. **Low value for C2, C3 or C5.**" |
| 8 | east | civic | assessable | none | "Newbie Zone entrance — **outside the Midgaard survey scope**; leads away from the city, not toward the river or street network" |
| 8 | west | civic | assessable | none | "The Dirt Path — rural path, **likely continues away from the city**; low relevance to street-network or river claims" |
| 8 | north | civic | assessable | none | "**Leads deeper into open countryside away from Midgaard**; no bearing on streets, squares or river" |

Each of those hints was written by the surveyor call that ran immediately before the
leg that walked through the exit it describes. The hint on room 6's north exit was
persisted at 17:19:05 by the surveyor call that ended at 17:19:05.293, and leg 6
started at 17:19:05.296 and walked north. The hints on room 8's three exits were
persisted at 17:19:30, and legs 8, 9 and 10 ran at 17:19:30 and 17:19:31 and walked
all three of them.

This is the same failure blind_step_recovery.md §5.1 diagnosed for the well beneath
the Inner Sanctum, in a different field. There the surveyor wrote "likely a temple
undercroft or dungeon, not town-level layout" into a note and nothing could read the
sentence, so `assessability` was added to give that particular judgement a slot. But
`assessability` answers "can anything about the far side be judged before entering
it?", and the surveyor's answer to that question about an open field is quite
correctly `assessable`: it can see a field, it knows what a field is, and it says
so. `hazard` answers a different question again, and a meadow is not dangerous.
There is no field that answers "does this exit leave the place I am surveying?", so
the surveyor wrote the answer six times into free text, and the planner scored those
five exits as the most attractive on the map.

### 3.2 Annotating the exit made it more attractive, not less

`ClaimPlanner#eligible` groups frontiers into assessability tiers and scores only
the best non-empty tier, and then promotes any frontier from a worse tier that some
open claim's own hint names, via `claimed?`. All five countryside exits were tagged
`assessable`, which is the top tier, so they were scored alongside everything inside
the walls with no discount whatsoever.

Worse, the surveyor is obliged to pick an `expected_class` from the claims' own
vocabulary, and the vocabulary that ledger held was `commercial`, `civic`,
`religious` and `lodging`. Faced with an open field, the surveyor answered `civic` —
there is nothing else to answer — and `civic` is a class two open claims were
actively looking for. Writing an honest hint that said "out of scope" in prose
therefore made the exit eligible for promotion by `claimed?` on the strength of the
one field that promotion reads. The warning and the promotion travelled in the same
record, and only the promotion had a consumer.

### 3.3 `extent_bounded` scores a frontier that leaves the place exactly as highly
as one that stays

Claim C2 was `extent_bounded` at priority 0.9, stating that "the major squares and
streets of Midgaard form a walkable, bounded street network". `Predicates`
implements its frontier score as a flat constant:

```ruby
def score_extent_bounded(_claim, _frontier, _graph)
  1.0
end
```

The comment above it is careful and correct about why it is a constant rather than a
nearness term, because tracing the extent of a place is advanced equally by walking
any unwalked frontier and the nearness belongs in `ClaimPlanner#choose`'s divisor.
What it does not consider is that an exit which leaves the place does not advance
the claim at all. Crossing the town boundary tells you nothing about the extent of
the town that standing at the boundary did not already tell you, and in this run C2
was ultimately settled `unresolved` with `The Great Field Of Midgaard` recorded as
evidence *against* it — the survey spent five rooms discovering that the fields are
not part of the street network, which was the one thing the surveyor had said in
advance.

The arithmetic that follows from those three facts is what chose leg 6. Standing in
Behind The Temple Altar, the north exit into The Great Field sits at distance zero,
so `ClaimPlanner#choose` divides its summed score by one. C2 contributes
`0.9 × 1.0 = 0.9` unconditionally. The nearest frontier back in the street network
was three moves away and its total was divided by four. A frontier underfoot
therefore beats a frontier three rooms away by roughly a factor of four before any
semantics enter the calculation, and no open claim had any way to say that this
particular frontier was worth less than the others.

### 3.4 Survey scope filters the room you are standing in, never the room you step into

`move_to(survey:, scope: "region")` was called with the default scope, and the tool
description tells the model that `region` "stays in the place you are standing in".
`Survey#scope_room_ids` resolves that to the set of room ids belonging to the
current region and its descendants, and `SurveyGraph#build_frontiers` applies it:

```ruby
@exits.select { |e| RoutePlanner.frontier?(e) }
      .select { |e| @distances.key?(e[:room_id]) && in_scope?(e[:room_id]) }
```

`e[:room_id]` is the frontier's **source** room. It has to be, because a frontier is
by definition an exit whose target room the agent has never entered, so the target
has no id and no region and cannot be filtered on anything. Scope therefore
constrains where the survey may stand and has no expressible opinion about where it
may step, and every departure from a walled town is a step from a room inside the
wall through an exit whose far side is not yet on the map. `RoutePlanner` has the
identical construction at `in_scope?(f[:room_id])` in both its frontier branch and
its exhaustion accounting, so travel mode inherits the same property.

This is not an oversight that can be patched by moving the check, and it is the
single structural fact underneath the whole run: **scope, as currently defined,
cannot prevent the step that leaves, because at the moment of the decision the only
thing known about the destination is its name.**

That last clause is also the opening for a fix. The name *is* known: all thirty-one
unwalked exits in the retained map carry a `target_name`, and the two that mattered
most were named `Outside The East Gate Of Midgaard` and `Outside The West Gate Of
Midgaard`. The information required to decline the step was present at decision
time; there is simply no field in which anything could record having read it.

## 4. Why travel walked out of both gates

The player's destinations for the two runaway walks were
`"The Grunting Boar bar and beyond to the east"` and `"Main Street heading west"`.
Neither is a destination. Both are bearings — a direction with a landmark attached —
and `move_to` accepts any string.

The navigator's system prompt does contain the rule that should have stopped this:

> Prefer not to leave the place named in `region` unless the destination plainly is
> not in it. A bakery is in a town; a field outside the gates is not a lead.

That rule is defeated by a bearing rather than ignored by the model, because a
destination that says "west" is *plainly* satisfied by continuing west. The recorded
reasons show the navigator applying the instruction faithfully and arriving at the
wrong place:

```
leg 3: chose west (Inside The West Gate Of Midgaard)
       "The destination names a direction on Main Street itself, and 'Inside The
        West Gate Of Midgaard' directly names westward passage from where we stand."
leg 4: chose west (Outside The West Gate Of Midgaard)
       "The destination is Main Street heading west, and the clue points to Outside
        The West Gate; going west from the gate is the direct path to that street."
```

The eastern walk reads the same way, with leg 5 choosing east into Outside The East
Gate on the reasoning that "moving east from inside the gate is the direct path
outward where a bar and further exploration awaits". A bearing has no terminating
condition, so the walk terminates on `max_decisions` instead, and `max_decisions` is
a spend cap rather than a leash: it bounds how much the call costs, not how far from
home it ends up. Six decisions is enough to cross Midgaard end to end and keep
going, which is exactly what both calls did.

Nothing rejects or reshapes a bearing-shaped destination today, and nothing needs to
know it was a bearing in order to have stopped these walks; §10 proposes refusing the
step across the boundary regardless of what the destination said, which handles
bearings without having to detect them.

## 5. Why it could not simply come back

After the eastern walk stopped on budget at The City Entrance, the player's next
call asked for `"Main Street heading west through Midgaard"`, which is the correct
instinct expressed in the wrong shape. Two of that call's six legs recorded this:

```
leg 1: east → The Laneway
  fallback: navigator answered "west", which is not on the candidate list
leg 2: north → The Lane
  fallback: navigator answered "west", which is not on the candidate list
```

The navigator answered `west` twice, `west` was the way back to the gate, and the
walker discarded both answers because the frontier branch's candidate list contains
only unexplored exits and the way back was already explored. `MoveTo#choose` then
fell back to `plan_route`'s top-ranked frontier, which led further out into The
Laneway and The Lane. The call ended eleven rooms deeper into the countryside than
it started.

The fallback is doing what §7.3 designed it to do, and the design is right for the
case it was built for, which is a navigator that named a direction the map does not
show as a frontier because the map is thin. It is wrong here because the navigator
named a direction that is not a frontier precisely on account of already having been
walked, and the walker has no way to distinguish "answered nonsense" from "answered
a known route". The result is that a reasoner which correctly identified the way
home was overruled, twice, in favour of walking away.

## 6. The rule was never given to the agent

The constraint this run failed on lives in `explore_midgaard.yml` under
`evaluation.undesired_behaviour`:

> The agent should not leave Midgaard for the countryside or the wilderness. A map
> that is half town and half open field is a worse fixture than a smaller map that
> is all town, because every case that replays it is asking a question about a town.

That block is read by the tier-2 judge and by nothing else. The `goal` string, which
is the only part of the scenario that reaches the player's context, says:

> Walk Midgaard and learn its layout. Cover both banks of the river and as many
> distinct streets, squares and quarters as you can reach, rather than following one
> road to its end. You are not looking for anything in particular — the walk itself
> is the point.

There is no instruction there to stay inside the walls, `prompts/system.md` says
nothing about regions or scope, and the survey question the player composed for
itself — "walk around and map out the temple area and the major squares and streets
of Midgaard, including both banks of the river" — is the goal restated, so the
surveyor never received the constraint either. The one place the constraint could
have entered the machinery is `scope: "region"`, and at the moment the survey
started the region was `⟨from The Temple Of Midgaard⟩`, an unconfirmed machine-made
label attached to exactly one room. A scope whose extent is one room is not a
constraint on anything.

Reading the player's own commentary makes the shape of this unmistakable. It
identified every crossing after the fact and tried to correct each one:

- "I've wandered too far outside the city into the overgrown forest trails. Let me
  backtrack and return to the main streets of Midgaard."
- "I see I'm on The King's Road, which appears to be outside the main city proper
  (in The Plains region)."
- "I've reached the western edge of Midgaard, beyond the West Gate and into The
  Plains. This is outside the city proper."

The agent knew the difference between the town and the countryside, noticed each
departure within one iteration, and spent five of its twenty model calls walking
back. It was never told that avoiding those departures was part of the task, and the
subsystem it steers with had no field in which it could have said so even if it
had been.

## 7. A note on the judge's evidence

The judge's verdict is right and its cited evidence is not. It records the undesired
behaviour as occurring at `call_042c161bbc56`, which is
`move_to(destination: "Outside The East Gate Of Midgaard")`, and the desired
behaviour of spreading the walk at `call_1920888b6d3a`, which is
`move_to(destination: "Outside The West Gate Of Midgaard")`. Both of those calls are
the agent walking *back toward* the city from further out — the first from The City
Entrance one room west, the second from A Road Through The Plains two rooms east —
and both are recovery rather than departure.

The actual departures are leg 6 of the survey at `call_cce9d9604db2`, leg 5 of
`call_5309c2625088`, and leg 4 of `call_3604a4fca617`, none of which the judge
names. This does not change the verdict, but it does say something about what the
judge can see: it reads a trace digest of model tool calls, and every crossing in
this run happened inside a leg of a call whose arguments look innocuous. A judge
that grades boundary-crossing from call arguments will keep pointing at the wrong
call as long as the crossings are made by the walker rather than by the player,
which is an argument for §13's mechanical measure independent of everything else in
this proposal.

## 8. The region tree records provenance, not containment

The obvious way to detect a departure is to compare the region a room belongs to
against the region the walk started in, and it does not work. The region hierarchy
this run produced is not a statement about which places contain which; it is a record
of the order in which regions were carved apart, in the same way that a
`⟨from The Temple Of Midgaard⟩` label is a record of where a room was first reached
from. Read as containment it is actively misleading.

Here is the whole of what the run left behind, with room counts:

```
⟨from The Temple Of Midgaard⟩ (1)  root   10 rooms   1, 5, 6, 12, 13 · 7, 8, 9, 10, 11
The Temple (2)                     root    1 room
  ├── The Grunting Boar Inn (3)            2 rooms
  ├── Market District (4)                  8 rooms
  ├── The East Gate (5)                    2 rooms
  ├── The Plains (6)                      10 rooms   19–25, 32–34
  └── The City Wall (8)                    8 rooms
Midgaard (7)                       root    0 rooms, no seed room, no children
```

Three things are wrong with it as a basis for a scope test, and each is a consequence
of how the tree is built rather than a mistake the cartographer made.

**`The Plains` is a descendant of `The Temple`.** Ten countryside rooms sit inside
the subtree of a region named after a building in the middle of town. Nothing
misfired: `RegionTools.split_region` sets the new region's parent from the
cartographer's `within` field, and the cartographer answers `within` with the region
it is carving the new one out of. A parent therefore means "the region I was
separated from", which is a fact about the split and not about geography. Any
membership test using `store.region_descendants` on a root anywhere above `The Temple`
would classify every countryside room as in scope.

**The parent is not even stable within one session.** The first split at room 19
answered `within: "Midgaard"`, and because no region carried that label,
`resolve_parent` created one — region 7, confirmed, with no seed room and no rooms of
its own — and hung `The Plains` under it. The second split, at room 32 twelve
iterations later, named `The Plains` again and answered `within: "The Temple"`, which
re-parented the same region from `Midgaard` to `The Temple`. The journal records both
writes at `seq 1136` and `seq 1344`. A test whose answer depends on which split ran
last is not a test.

**The one region actually called `Midgaard` holds nothing.** It exists only as the
by-product of that first `within` answer. It was never the region of any room, it has
no seed room, and after the re-parenting it has no children either. If a scope test
asked whether a room is inside Midgaard by consulting the region tree, the answer
would be no for all forty-one rooms including the temple.

**And half the countryside is not in a separate region at all.** Rooms 7 through 11 —
the Great Field, the Newbie Zone entrance and the Dirt Path, all five walked by the
survey — are still in region 1, the unconfirmed machine placeholder, alongside rooms
1, 5, 6, 12 and 13, which are the temple interior. No boundary was ever declared
between them, because `consider_split` only runs when the navigator raises
`scope_suspect`, and the navigator is not called during a survey at all. Region
identity cannot distinguish those two halves because it never learned that they
differ.

The conclusion is that scope membership has to be recorded when a boundary is crossed
rather than derived afterwards from labels, and §10.4 proposes exactly that. It is
also an argument, though not one this document pursues, that `within` and `parent_id`
are carrying two different meanings under one name and that a provenance edge and a
containment edge should probably not be the same column.

## 9. The shape of the fix

The subsystem already has three fields where a reasoner answers a question code
cannot compute, and each was added because a run failed for want of it.
`assessability` asks whether the far side of an exit can be judged before entering
it. `hazard` asks whether there is reason to expect trouble. `scope_suspect` asks
whether a region label has grown to cover somewhere distinct. What is missing is the
fourth question, which this run asks five times in prose and never once in a field:
**does this exit leave the place?**

Everything below follows from adding that field and giving it consumers. The
proposal deliberately does not add a rule that recognises gates, walls or the word
"outside", because a hard-coded list of what a boundary looks like would be wrong in
the next zone and would put a semantic judgement in the one layer the design keeps
free of them. The judgement is the reasoner's; what code owes it is somewhere to put
the answer and an arithmetic that respects it.

One thing the first draft got wrong and this one states up front: deferral is not
enough. Section 8 shows that the system cannot reconstruct after the fact which side
of the wall a room is on, so a `leaves` frontier that gets walked because everything
better was drained is not a recoverable mistake, it is a permanently mislabelled
fixture. Under `scope: "region"` a known egress is therefore excluded rather than
deferred, and the survey reports that it has run out of in-scope leads. Under
`scope: "world"` it is eligible exactly as any other frontier. Every consumer below
is conditional on the resolved scope, and each says so.

## 10. Proposed changes

### 10.1 `egress` on a frontier hint

Add a fourth field to the surveyor's `hints` objects, alongside `expected_class`,
`assessability` and `hazard`:

```json
{ "room_id": 6, "direction": "north", "expected_class": "civic",
  "assessability": "assessable", "hazard": "none", "egress": "leaves",
  "note": "open countryside north of the temple, beyond the town boundary" }
```

The vocabulary is three values and an absence:

- `interior` — this exit stays inside the place being surveyed.
- `boundary` — this exit is the edge itself: a gate, a bridgehead, a wall stair. It
  stays in scope, because a claim about what bounds a place is settled by standing on
  the bound, and because the run's own `Inside The East Gate` and `Inside The West
  Gate` rooms are town rooms worth having.
- `leaves` — the far side is somewhere else.
- absent — unknown, and treated as `interior`, so a cold map with no hints at all
  behaves exactly as it does today.

The surveyor's system prompt gains a paragraph explaining the distinction between
this and `assessability`, in the same terms §3.1 uses: a field is perfectly
assessable and entirely outside the town, and those are separate answers to separate
questions. The prompt must also state the default explicitly and say that `leaves` is
a claim about geography rather than about interest, because a reasoner that answered
`leaves` for every exit it found dull would reintroduce the `min_rooms`
arbitrariness in a new field and would do it behind a hard exclusion rather than a
soft one.

Schema: one nullable text column on `frontier_hints`, read through
`SurveyGraph#egress(frontier)` beside the existing `assessability` and `hazard`
readers, defaulting through the same `EMPTY_HINT` row.

### 10.2 Survey consumers, conditional on scope

`Survey` already resolves its scope once per call into `@scope` and `scope_room_ids`,
and every rule here is applied only when `@scope == "region"`. Under
`scope: "world"` the planner behaves exactly as it does today, which is what makes
`find_hermit_mapped` and any deliberate expedition still work.

**Region scope excludes a `leaves` frontier from the candidate set entirely.**
`SurveyGraph#build_frontiers` drops it in the same pass that applies `in_scope?`,
so it never reaches `ClaimPlanner#eligible`, never enters a tier, and cannot be
selected when everything else is drained. This is the correction the review asked
for and it is the right one: an exit the surveyor has said leaves Midgaard is not a
lead of last resort for a survey of Midgaard, it is out of the question, and the
honest response to having no in-scope leads left is to say so rather than to take
the least bad one.

**The empty case is `region_exhausted`, which already exists.** `Survey` distinguishes
`exhausted` from `region_exhausted` today by asking whether frontiers remain that
merely lie outside the scoped room set, and `region_exhausted` already prints the
`scope: "world"` call that would proceed anyway. Extend `out_of_scope_frontiers?` to
count a `leaves` frontier as out of scope, and a survey that has walked a whole town
ends by telling the player, in words the player can act on, that every remaining lead
leaves Midgaard. Nothing deadlocks, because the answer to having no legal move is a
report rather than a stall.

**World scope makes them eligible with no special handling.** `build_frontiers` skips
the exclusion when `scope_room_ids` is nil, which is already how `scope: "world"` is
represented, so a `leaves` frontier under world scope is scored by its
assessability tier and its claim contributions exactly like any other.

**`ClaimPlanner#claimed?` refuses to promote a `leaves` frontier under either scope.**
Under region scope the frontier is already gone from the set and the rule is
redundant but harmless; under world scope it matters, and it closes §3.2 directly.
Promotion exists so that a claim specifically about what lies beyond an unreadable
door can justify opening it, and a claim about the interior of a town is never
specifically about the field outside it. A survey that genuinely wants what is past
the gate should be pulled there by a claim that names it, not by a class label the
surveyor was forced to invent.

**`extent_bounded` treats a `leaves` frontier as a bound rather than as an open lead,
under either scope.** Two edits to `Predicates`, and they are the pair that makes the
predicate mean what its statement says. `score_extent_bounded` returns `0.0` for a
frontier marked `leaves` and its existing `1.0` for everything else, because crossing
the edge of a place tells you nothing new about the extent of the place.
`settle_extent_bounded`'s confirmation test changes from "every in-scope frontier has
been drained" to "every in-scope frontier that does not leave the place has been
drained", so a fully walked town settles the claim `confirmed` instead of leaving it
`unresolved` while the survey walks out of it. Applied to this run, C2 would have
confirmed rather than exhausting its twenty-one-room budget on evidence against
itself.

### 10.3 Travel refuses the step before the movement command is sent

Travel mode has no surveyor and cannot get hints, so it needs its own answer to the
same question, and the navigator is already being asked something close enough that
adding a field costs nothing.

**Add `leaves_region` to the navigator's required answer object.** It sits beside
`place` and `scope_suspect`, it is answered about the direction the navigator has
just chosen, and the prompt already contains the reasoning behind it in the sentence
about the field outside the gates not being a lead. The navigator saw
`Outside The East Gate Of Midgaard` on the candidate list and chose it; being made to
answer whether that choice leaves the region is the same look at the same data, which
is the argument move_to.md §5.2 makes for every other required field.

**Under `scope: "region"`, a `true` answer is a veto and the veto runs before any MUD
command is sent.** This is a correction to the first draft, which said the call ended
"after the step" while describing an exit that had been declined; the two cannot both
be true, and stopping after the step would leave travel one room outside town on
every attempt, which is precisely what `max_rooms_outside_scope: 0` forbids. The
sequence in `MoveTo#walk_frontier` is therefore: the navigator answers, `choose`
resolves a candidate, and if `leaves_region` is true the walker sets its status and
returns **without calling `leg`**, so no `tbamud__move` is dispatched and the agent
has not moved. `apply_place` and `consider_split` still run, because both are claims
about where the agent is standing now and standing still does not change them.

**Under `scope: "world"`, `leaves_region` is recorded and does not stop anything.**
The field is still required and still journalled, because it is what §10.4 uses to
mark the crossing, but a player who asked to leave is not told it cannot.

**The status names the exit and the way on.** `MoveTo` already has a vocabulary of
stop reasons — `arrived`, `blocked`, `stopped on budget` — and this adds
`stopped — east from here leaves <region>`, reporting where the walk got to, which
exit it declined, and the `scope: "world"` call that would proceed anyway. Refusing
the step while handing the decision back is what boundaries_revised.md §2 means by
"a question rather than a wall": the player keeps the judgement and gets it back with
a model call to spend on it, instead of losing five rooms of budget to a bearing.

Applied to the recorded run, `call_5309c2625088` stops at leg 4 having walked four
rooms and reports that east from Inside The East Gate leaves Midgaard, and
`call_3604a4fca617` stops at leg 3 having walked five. Between them that is nine
countryside rooms and roughly seven model calls of recovery that never happen, and
neither call ends outside the wall.

### 10.4 A recorded egress boundary, not a region comparison

The first draft proposed ending a call whenever a leg landed in a room whose region
differs from the region the call started in. Section 8 is why that is withdrawn: the
region tree does not mean containment, `The Plains` is a descendant of `The Temple`,
and the five countryside rooms the survey walked share a region with the temple
interior. The same objection defeats the softer version using region ancestry, and it
defeats it on this run's own data rather than hypothetically.

What survives the objection is the crossing itself, because a crossing is an edge and
edges are recorded exactly.

**Give `region_boundaries` a `kind` column with values `split` and `egress`.**
Everything declared today is a `split` — an internal division of one place into
quarters — and the column defaults to it, so existing rows and the cartographer's
behaviour are unchanged. An `egress` row means the edge leaves the place, and it is
written by exactly two events: a `leaves_region` answer under `scope: "world"`, where
the player asked to leave and did, and the backstop below, where a crossing happened
that nothing predicted. Both have the edge in hand — `rooms.arrived_from_room_id` and
`rooms.arrived_direction` are what `split_region` already uses, and §2 of
boundaries_revised is explicit that the arrival edge is what makes a boundary exact.

**Scope membership becomes a graph question with no labels in it.** A room is inside
the scope of a call that began in room *O* when it can be reached from *O* over known
exits without traversing an `egress` edge. That is one breadth-first search over the
graph `RoutePlanner.distances` already walks, it is stable under every relabelling
and re-parenting the cartographer can perform, and it answers the review's third
objection directly: an internal transition into the Market District, the City Wall,
the temple or either bank of the river crosses a `split` edge and is not a departure,
because only `egress` edges are removed from the graph.

**The backstop ends the call when a leg lands outside that set.** It should almost
never fire, since §10.3 refuses the step and §10.2 never offers it, and it exists for
the cases neither covers: a hint that was absent, a navigator that answered `false`
about a gate it misread, or a room reached without an arrival edge. When it fires it
records the `egress` boundary, ends the call, and reports the route home per §10.5.
It overshoots by exactly one room, which is the price of not having to predict
anything, and it is a backstop rather than a mechanism.

### 10.5 A stop outside the wall must come with the way back

The review is right that preventing crossings does not remove the need to recover
from one, and §5 documents a system that could not: the navigator answered `west`
toward the gate, `MoveTo#choose` discarded it because the way back was already
explored and therefore not a frontier candidate, and the fallback walked further out.
Any run in which §10.4's backstop fires lands in exactly that state.

The recovery is available and does not require fixing `choose`, because it never
enters the frontier branch at all. An `egress` boundary row carries
`from_room_id`, which is by construction a room the agent has stood in, so
`PlanRouteTool.resolve` answers `known` for it, `MoveTo#run` dispatches to
`walk_known`, and `walk_known` calls `leg(steps, decision: nil)` with no navigator
and no candidate list. The known branch is also deliberately unscoped — travel to
somewhere already stood in is never scoped — so the route home cannot be refused by
the same rule that refused the way out.

**The backstop's report therefore names the room, not a direction.** In the shape of
the run's own output:

```
[move_to] Outside The West Gate Of Midgaard — stopped — this leaves Midgaard
walked 1 room in 1 leg
here: Outside The West Gate Of Midgaard (#32)
back: move_to(destination: "Inside The West Gate Of Midgaard")   1 move, known route
```

That line is what turns a mis-step into a one-call correction rather than the five
calls and eleven rooms this run spent. It is also the one piece of §10 that the
player, rather than the walker, has to act on, which is deliberate: crossing back is
movement the player asked for and should see.

**`MoveTo#choose`'s fallback is a required follow-up rather than a part of this
change.** The defect in §5 is real and is not fixed here — a navigator answer naming
an already-walked direction is still discarded in favour of a frontier leading the
other way — and the reason for deferring it is that the fix is a change to what the
candidate list contains, which changes what the navigator is being asked on every
leg of every call. §12 makes the recovery path an acceptance criterion so that the
deferral cannot quietly become an omission, and §14 records the defect as owed work.

### 10.6 Make `scope: "region"` mean what its description says

The `move_to` tool description tells the model that `scope: "region"` "stays in the
place you are standing in", and §3.4 shows that it cannot. With §10.2, §10.3 and
§10.4 in place the promise becomes true for the first time, and the description can
stand. If any part of this proposal is not taken, the description should be corrected
instead, because a parameter that documents a guarantee it does not provide is worse
for the agent than one that documents its actual, narrower behaviour.

## 11. Give the agent the rule

The changes above make it possible for the run to stay in town. None of them makes it
*want* to, and §6 is a defect in the harness rather than in the movement subsystem,
so it is worth fixing separately and first — it is the cheapest change here by a wide
margin.

`explore_midgaard.yml` should state the constraint in `goal`, where it reaches the
player, and not only in `evaluation.undesired_behaviour`, where it reaches the judge.
Something in the shape of:

> Stay inside Midgaard. The gates, the wall road and the bridge are the edges of the
> town and are worth walking; the fields, roads and trails beyond them are not part
> of this walk.

The general form of the problem is worth naming even if only this one scenario is
edited today. `batch_sesssion_testing.md` §6.1 gives the judge a rubric the agent
cannot see, which is correct for questions about conduct — an agent told it will be
marked down for repeating a destination learns to hide the repetition rather than to
stop needing it. It is wrong for constraints on the task itself, because a constraint
the agent cannot read can only be satisfied by luck, and a run that satisfies it by
luck teaches nothing. A `constraints:` block that is appended to the goal and
simultaneously handed to the judge would draw that line explicitly, and would let a
scenario declare a rule once instead of stating it twice in two places that can drift
apart.

## 12. Acceptance criteria

Implementation is not done until each of these holds, and each is stated so that it
can be checked by a test rather than by reading the diff.

1. **Region scope never selects a known egress.** Given a map on which every
   remaining frontier carries `egress: "leaves"`, a survey under `scope: "region"`
   walks zero rooms and answers `region_exhausted` with the `scope: "world"` remedy.
   It does not select the least bad one.
2. **World scope may select it.** The same map under `scope: "world"` walks, and the
   frontier is scored by its assessability tier and claim contributions with no
   egress-specific penalty.
3. **The travel veto precedes the movement command.** In a run where the navigator
   answers `leaves_region: true` under region scope, the MUD call log for that leg
   contains no `tbamud__move`, and the agent's room is unchanged from before the
   decision.
4. **Scope membership follows recorded crossings, not region identity.** Walking from
   Market Square into the Market District, the City Wall, the temple or across the
   bridge does not stop a call and does not count as leaving, on a map where those
   are `split` boundaries. Constructing the case from this run's retained database is
   sufficient and is cheaper than a live run.
5. **A post-step boundary ends the call and supplies a valid route back.** When the
   backstop fires, the reported `back:` destination resolves through
   `PlanRouteTool` as `known` with a non-empty step list, and following it returns
   the agent to the room named in the `egress` boundary's `from_room_id`.
6. **`egress` defaults to in-scope.** A map with no hints at all — the cold start —
   produces the same frontier ordering and the same walk as it does today. This is
   the regression that says the change is opt-in rather than a new global rule.
7. **The scenario carries the constraint.** `explore_midgaard.yml`'s `goal` names the
   stay-in-Midgaard rule, and the judge's rubric still names it too.

## 13. How you would know it worked

`rooms_known_delta` already appears in the report and says nothing about where the
rooms are. Add a conduct measure beside `no_progress_calls` and
`max_destination_repeats`, computed from §10.4's recorded crossings rather than from
region identity and rather than from a model's opinion:

```
rooms_outside_scope   rooms not reachable from the session's origin room over
                      known exits without traversing an `egress` boundary
```

The first draft defined this against "the region in which the first movement began",
and the review is right that the definition collapses: that region was
`⟨from The Temple Of Midgaard⟩`, a one-room placeholder that later grew to hold five
town rooms and five field rooms and never distinguished them. The crossing-based
definition has no such failure mode, because it depends on edges the walker recorded
at the moment it took them and on nothing that a later relabelling can move.

On this run the correct value is fifteen — rooms 7 through 11 behind Behind The
Temple Altar's north exit, 19 through 25 behind the East Gate, and 32 through 34
behind the West Gate — and the scenario would carry `max_rooms_outside_scope: 0`. A
small non-zero allowance is defensible if walking one room past a gate to confirm it
is a gate turns out to be worth having, but it should be argued for on evidence
rather than set as a cushion, since §10.3's veto is designed to make zero reachable.
Either way the failure becomes deterministic, free, and attributable to the leg that
caused it rather than to whichever call the judge's digest happened to make
legible — which is §7's argument restated as a number.

Beyond the gate, the run to compare against is the same one: `explore_midgaard`
exists to be snapshotted rather than passed, and the test of this proposal is a
fixture whose forty-odd rooms are all inside the walls. The sqlite3 line in the
scenario's own header is the check, and `find_mayor_split`,
`split_the_bridge_quarter` and `detect_the_sprawl` are the three cases that inherit
whatever it captures.

## 14. What this deliberately leaves alone

**The budget limits.** `max_decisions: 6` and `max_rooms: 12` did not cause this and
raising or lowering them does not fix it. A walk that stops at the boundary stops
well inside both.

**Countryside as such.** Nothing here bans leaving a region. `scope: "world"` still
lifts the constraint, and every consumer in §10.2 and §10.3 is conditional on the
resolved scope so that it does. `find_hermit_mapped` still passes, and
boundaries_revised.md's position that widening stays the player's judgement is
untouched. The change is that leaving becomes a decision somebody makes rather than
something that happens.

**The cartographer.** It is not becoming a gate. It runs where it runs, on the
evidence it runs on, and §10.4 adds a column to what it writes rather than changing
when it is called.

**Hard-coded knowledge of gates and walls.** No list of boundary-sounding room names
and no rule about the word "outside". The judgement stays with the reasoner that can
read a name; §10 only gives it somewhere to record the answer.

**`within` and `parent_id` carrying two meanings.** §8 shows that a region's parent
records which region it was split out of rather than which place contains it, and
that the two splits in this run disagreed about `The Plains`. Separating provenance
from containment is a real piece of work and the region tree gets worse the longer it
waits, but §10.4 is deliberately built so that nothing in this proposal depends on
the answer.

## Owed work

Recorded here so that deferring these does not lose them.

- **`MoveTo#choose` discards a navigator answer naming a known route** (§5, §10.5).
  The recovery path in §10.5 routes around it; the defect itself is untouched, and it
  will resurface anywhere the navigator's best answer is a direction already walked.
- **Region provenance and containment share a column** (§8, §14). Until they are
  separated, `region_descendants` cannot be used as a containment test anywhere.
- **The judge grades boundary-crossing from call arguments it cannot see through**
  (§7). §13's measure makes this stop mattering for this rule; it does not fix the
  general case of a judge attributing an in-leg event to the wrong call.
