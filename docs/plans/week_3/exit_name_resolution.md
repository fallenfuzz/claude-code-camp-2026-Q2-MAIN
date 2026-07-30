# Exit Name Resolution

## The problem is not reverse edges

`docs/architecture/move_to.md` describes the absence of inferred reverse edges
as "a known defect under investigation." That characterisation is wrong, and
correcting it changes what needs to be built.

Not inferring reverse edges is a deliberate decision recorded in
`docs/plans/week_2/plan_route.md`:

> Do not infer a reverse edge. If the database has `A --east--> B` but has not
> earned `B --west--> A`, only the first direction exists for planning. MUD
> exits may be one-way, gated, or non-Euclidean.

The decision is enforced by `test_one_way_exits_are_not_reversed` in
`week2_capable/boukensha/test/test_navigation_route_planner.rb:49`, and the
invariant is stated in the store itself, where `link_exit!` is documented at
`memory/store.rb:365` as "the only place `target_room_id` is ever set." The
rationale holds: a MUD may connect rooms asymmetrically, and manufacturing a
return edge from a geometric assumption would produce routes the agent cannot
walk.

The actual defect is that the system discards authoritative data it has already
paid for. `room_parser.rb:113` parses the MUD's `exits` output, which prints
`"direction - Destination"` per line, so `room_exits.target_name` holds the
name of the room behind an unwalked exit as reported by the game. Nothing ever
compares that name against the rooms already in memory, which means an exit
leading to a thoroughly mapped room is stored and treated exactly like an exit
leading somewhere entirely unknown.

## What this costs today

Querying the recorded Midgaard map in
`.boukensha/profiles/Derrano/knowledge.sqlite3` for unlinked exits whose target
name exactly matches a known room:

| Source room | Direction | Target name | Resolves to |
|---:|---|---|---:|
| 1 | down | The Temple Square | 2 |
| 2 | north | The Temple Of Midgaard | 1 |
| 7 | north | The Temple Square | 2 |
| 8 | north | Market Square | 7 |
| 9 | north | The Common Square | 8 |

Five of the fifteen unlinked exits in that map point at rooms already in
memory, so a third of what the planner treats as exploration frontier is
phantom. This produces two of the symptoms listed in `move_to.md` section 14
from a single cause: the frontier set is inflated with rooms that need no
exploring, and backtracking fails because the return path exists in the data
but not in the graph.

The concrete failure is measurable. The recorded session ended at The Dump
(#9), whose only other exit is described as "Too dark to tell." From that
position the set of rooms reachable by breadth-first search over linked edges
is **empty**, so the agent cannot plan a route out of the room it is standing
in. Resolving the five rows above restores the chain 9 → 8 → 7 → 2 → 1, and
because room 2's eastward edge to the inn is already earned, the reachable set
becomes **all eight** other rooms.

The first row deserves attention because it demonstrates that this is not
reverse-edge inference wearing a different hat. Room 1 has both a `south` and a
`down` exit to The Temple Square, and only `south` was walked. Reverse
inference could never produce the `down` edge, since no walked traversal
implies it; the MUD simply said where that exit goes. Name resolution recovers
genuine one-way and duplicate-route structure that symmetry assumptions cannot.

## Why this does not contradict the week 2 decision

Name resolution asserts nothing about symmetry. It reads a destination the game
reported and matches it to a room the agent has stood in, so an exit that the
MUD does not list is never created, and a one-way passage remains one-way
because no return exit exists to resolve. Gated exits behave the same way,
since a door the agent cannot pass is still a door the game named.

The existing test continues to pass without modification. Its fixture gives
room 1 an eastward edge to room 2 and gives room 2 no exit rows at all, so
there is nothing for a resolution pass to act on and the plan remains
`unreachable`.

## Design

### Do not write to `target_room_id`

The `target_room_id` column carries earned semantics that other components
depend on. `schema.rb:50` documents the NULL as being the exploration frontier
itself, and `state_block.rb:78` renders `✓` against a linked target and `?`
against a NULL so that the model can distinguish a mapped exit from an unknown
one. Writing presumed links into that column would make a name match
indistinguishable from a walked traversal in both the frontier calculation and
the model's view of the world.

Resolution therefore writes to a new nullable column:

```sql
ALTER TABLE room_exits ADD COLUMN presumed_target_id INTEGER REFERENCES rooms(id);
```

An exit may hold a presumed target, an earned target, or neither, and an earned
target always supersedes a presumed one.

### The resolution rule and its guards

A presumed link is written when an exit has a NULL `target_room_id` and its
`target_name`, normalised through `DestinationSearch.normalize`, satisfies all
three guards.

The first guard requires the normalised name to match **exactly one** room in
memory, because a name matching several rooms identifies none of them.

The second guard suppresses resolution when **two or more exits from the same
source room share a target name**. This is not hypothetical: room 7 in the
recorded map has `east → Main Street` and `west → Main Street`, and the moment
any room named "Main Street" is discovered, a rule checking only global
uniqueness would link both exits to it and fuse the two ends of a street into
one room. That outcome is worse than the defect being fixed, since it corrupts
the graph rather than merely leaving it sparse.

The third guard maintains an ambiguity set of normalised names observed on two
or more distinct rooms and refuses to resolve any name in that set, even if
only one such room is currently known. Generic MUD room names recur heavily,
and once a name has proven ambiguous anywhere it cannot be trusted as an
identifier.

### Planning over presumed edges

`route_planner.rb:100` currently partitions exits into linked edges and
frontiers on the presence of `target_room_id`. That partition gains a third
category, and breadth-first search may traverse presumed edges while ranking
them strictly after earned ones, so that a route composed entirely of walked
edges is always preferred to a shorter route relying on a presumption.

An exit holding a presumed target is no longer counted as a frontier, which is
what removes the phantom third of the frontier set.

Plan output marks presumed steps, and the resulting route carries a flag
indicating that it depends on at least one unverified edge, so that callers can
decide how much to trust it.

### Self-healing on traversal

The first walk across a presumed edge settles it, using machinery that already
exists. Arriving in the expected room promotes the presumption through
`link_exit!`, which sets the earned target and increments traversals. Arriving
somewhere else means the presumption was wrong, and `demote_exit!` already
implements the correct resolution, documented at `store.rb:392` as the rule
that a conflict between the edge walked and the room actually entered is
resolved in the room's favour. The presumed target is cleared at the same time
and the name is added to the ambiguity set.

This gives the mechanism a useful property: a wrong presumption costs one move
and then corrects itself permanently, whereas the current behaviour costs every
future route that needed the edge.

### When resolution runs

Resolution is cheap enough to run whenever the data it depends on changes,
which is when a room is newly recorded and when `record_exits!` learns a target
name. A newly discovered room can satisfy pending exits elsewhere in the map,
so the pass on room creation must consider exits whose target name matches the
new room rather than only the new room's own exits.

## Implementation outline

1. Add the `presumed_target_id` column and a migration for existing profile
   databases.
2. Add a resolution function to the store, covering the three guards, plus the
   ambiguity set as either a derived query or a small persisted table.
3. Call resolution from room creation and from `record_exits!`.
4. Extend `RoutePlanner` to build a third edge category, traverse presumed
   edges at lower priority, and exclude presumed-target exits from the frontier
   set.
5. Mark presumed steps in plan output and flag routes that depend on them.
6. Promote or demote on traversal in `Mud::Hooks#reconcile_move!`.
7. Render presumed exits distinctly in the state block, since `✓` and `?`
   currently exhaust the vocabulary and a presumption is neither.

## Tests

The existing `test_one_way_exits_are_not_reversed` must continue to pass
unchanged, since it is the regression guard for the week 2 decision.

New coverage should establish that a uniquely named target resolves and becomes
traversable; that two exits from one room sharing a target name both stay
unresolved; that a name matching two known rooms stays unresolved; that a name
in the ambiguity set stays unresolved even when only one candidate room is
known; that earned routes are preferred over presumed routes of equal or
shorter length; that walking a correct presumption promotes it; and that
walking an incorrect presumption demotes it and poisons the name.

A fixture reproducing the recorded Midgaard map is worth building directly,
because the assertion that the reachable set from The Dump goes from zero rooms
to eight is the clearest statement of what this change accomplishes.

## Relationship to surveying

Claim-driven surveying, described in
[movement_revisited/claims.md](movement_revisited/claims.md), depends on this
work more heavily than destination seeking does. A survey deliberately walks to
the end of branches and then returns, so the leg described in
[movement_revisited/session_story.md](movement_revisited/session_story.md) that
routes from The Dump back to Market Square is exactly the pattern that fails
today.

Two follow-on consequences matter for that design. Frontier scoring becomes
meaningful only once phantom frontiers are removed, since a survey that scores
a mapped room as unexplored will waste legs confirming what it already knows.
And a survey routing over presumed edges needs the leg executor to treat a
presumed-edge mismatch as a trigger to replan rather than as an interruption,
because unlike combat or death it is an ordinary map correction that the survey
should absorb and continue past.
