# Blind Step Recovery

Diagnosis and proposed fix for run `20260731T151405Z-fa92ead3` (`explore_midgaard`,
session `20260731T151434Z-737a23cb`), the run in which the agent fell down a well
into an unlit sewer on its fifth leg and then spent seventeen model calls unable
to take a single step.

Status: proposed, nothing implemented. Sections 1 through 4 are read off the
recorded session, off the journal and claim ledger it wrote, off the world files
under `week0_explore/infrastructure/lib/world/`, and off a replay of
`ClaimPlanner#choose` against the map the run left behind; sections 5 through 7 are
the proposal and section 8 lists what it deliberately leaves alone.

This run is the first to have been graded by the two conduct ceilings
`fix_surveying.md` added, and both failed on it deterministically, so the failure
below was named by a number before anyone read a transcript:

| fact | recorded | gate |
|---|---|---|
| `no_progress_calls` | 17 of 18 | `max_no_progress_calls: 3` — failed |
| `max_destination_repeats` | 4 | `max_destination_repeats: 2` — failed |

There are two independent defects here and they need separating, because a fix for
either one alone leaves the run failing. The survey walked into a place it had no
reason to enter and had already judged not worth entering (§4), and once there it
had no legal action that could get it out (§3). The first is a policy defect in how
frontiers are chosen; the second is a dead end in the movement surface.

## 1. What the run actually did

The session issued twenty-four model tool calls, of which eighteen were `move_to`,
and made 101 MUD calls for $0.25 before ending on `max_tokens` after twenty-four
iterations with five rooms known and no recorded final position. Only the first of
those eighteen `move_to` calls moved the character at all.

That first call was a survey, and for four legs it worked as designed. The agent
walked The Temple Of Midgaard → The Temple Square → The Entrance To The Clerics'
Guild → The Bar Of Divination → The Clerics' Inner Sanctum, opening five claims,
confirming one of them and recording eleven pieces of evidence. On the fifth leg it
took the Inner Sanctum's `down` exit, whose target name the MUD had given as
`Too dark to tell.`, and from that point the run was over in every sense except
that it kept spending.

The remaining seventeen `move_to` calls each answered `position_unknown` and walked
nothing. The destinations asked for, in order, are not the behaviour of a model
that has stopped reasoning:

```
The Temple Of Midgaard · Temple Square · <the survey question again> · north ·
here · north · Temple Square · north · up · east · west · south · out · look ·
a nearby room · any direction · north
```

Interleaved with those it called `tbamud__examine(self)`, `tbamud__examine(me)`,
`tbamud__examine(room)`, `tbamud__shop(list)` and `tbamud__poll` twice. The agent
was searching its whole tool surface for anything that would either tell it where
it was or move it somewhere identifiable, working through the compass, `out`,
`look` and finally `any direction` in a plainly systematic order. Every one of
those requests was refused before a single MUD command was sent, for the reason in
§3.

## 2. The character did move, and the way back was shut by design

The dark-room machinery from `dark_rooms_and_stuck_walks.md` engaged exactly as
that document describes, which is worth establishing before anything is blamed on
it. The movement reply could not be parsed as a room, so `Hooks` spent one `look`
through `classify_position` (`hooks.rb:367`); that look came back unreadable too,
so the position was dropped, the exit was marked opaque and the frontier attempt
was recorded as having succeeded. `ExecuteRouteTool.back_out`
(`execute_route_tool.rb:123`) then walked the reverse of the direction just taken,
which costs one MUD round trip and no model call, and `up` was refused.

Three facts agree that the character really was one room below the sanctum rather
than standing where it started. The movement points settle it most directly: the
`examine guildmaster` immediately before the descent reports 93V, the pitch-black
reply to `down` reports 92V, and the `Alas, you cannot go that way...` reply to
`up` also reports 92V, so the descent spent a movement point and the refusal spent
nothing. The server's answer also changed between the two commands, which could not
happen if the character had never left. Finally, the sanctum's own `check exits`
listing names only `east` and `down`, so a refused `up` is what that room would
report in any case and the refusal carries no information about which room the
character was in.

The world files settle the rest, and they are in this repository even though the
engine source is not. Room 3002 in
`week0_explore/infrastructure/lib/world/wld/30.wld` is The Clerics' Inner Sanctum,
and its `down` exit reads:

```
D5
You can't see what is down there, it is too dark.  Looks like it would be
impossible to climb back up.
~
~
0 -1 7026
```

The destination is room 7026, `A Junction`, in `70.wld`, whose exits are `north` to
7025, `south` to 7028 and `west` to 7013, with no `up` at all. The drop is one-way
by design and the room is flagged dark, so the reverse step `ExecuteRouteTool`
tries first could not have worked and no `look` taken there could have succeeded.
Escape existed, one blind step north, south or west into further unlit sewer, and
nothing in the system was able to attempt it.

The exit prose above is not something the agent ever sees. `check exits` prints
destination *names*, which the agent stores in `room_exits.target_name`; the
warning that climbing back is impossible is never sent to the client. Nothing in §5
proposes reading it.

## 3. Why nothing afterwards could recover

Four pieces of the system, each defensible alone, compose into a state with no
legal action that can leave it.

**`move_to` will not move without a position, and it is the only movement tool the
player has.** `RoutePlanner::Planner#plan` returns `position_unknown` the moment
`current_room_id` is nil (`route_planner.rb:151`), and `MoveTo#run` treats that
status as one of the four answers that end the call, handing back `plan_route`'s
rendering of it without dispatching anything (`move_to.rb:216`). That is correct
for every other caller and catastrophic here, because `tbamud__move` lives in
`tools.navigation.allow` and is deliberately absent from `tasks.player.allow`, so
the walker is the only thing in the process that can send a movement command and
the walker refuses to send one until it knows where it is. Leaving an unlit room
requires moving, and moving requires already knowing where you are.

**The remedy names actions the player cannot take.** `render_position_unknown`
(`plan_route_tool.rb:96`) advises taking "one safe action (e.g. move) first", and
`MoveTo#remedy` (`move_to.rb:666`) advises "`look` once you can see, or use a light
source, before planning another route". The player's allowlist holds `move_to`,
`name_region`, `split_region`, `tbamud__consider`, `tbamud__examine`,
`tbamud__shop` and `tbamud__poll`. It does not hold `move`, it does not hold
`look`, and every item tool that could produce a light — `get_item`, `equip_item`,
`use_magic_item`, `consume_item`, `cast_spell` — is commented out. This is the same
defect the codebase already fixed once for `region_exhausted`, whose comment
records the principle: a remedy naming a tool the player does not have is a remedy
for nobody.

**The state block describes a cold start rather than a loss.** With no room
established, `StateBlock#location_line` (`state_block.rb:48`) renders
`[here] (unknown — no room established yet)`, and the agent received exactly that
on twenty-three consecutive iterations:

```
[here] (unknown — no room established yet)
you: 23/92hp 116mana 92mv · lvl 10 · 0 gold · standing
```

The wording is accurate about the database and misleading about the situation. A
position that has never been established is a cold start the next `before_model`
resolves for free, whereas a position that was established and then lost will not
resolve on its own, and "yet" tells the reader to expect the first. Nothing on the
line says the agent had been somewhere a moment ago, or which room, or by which
exit, although `note_position_lost` (`hooks.rb:437`) writes `prev_room_id` and
`last_direction` to `player_state` before clearing the room and `render_state`
already passes the whole player row into the block.

**The hook's own recovery cannot fire in the dark.** `before_model` re-establishes
position through `cold_look` (`hooks.rb:463`), which does run on every iteration
once the room id is nil, and it did: the session contains twenty-three further
automatic `look` calls, every one answered `It is pitch black...`.
`resolve_position` (`hooks.rb:477`) returns immediately unless the look is
complete, so a room that cannot be read cannot be resolved however many times it is
looked at. The loop was not missing a retry; it was retrying the one action that
could never work.

The survey pays for this twice, because `position_lost` is terminal for it.
`Survey#handle_stop` (`survey.rb:423`) re-plans around `:refused` and `:unreadable`
under `survey_max_setbacks`, which is the repair `dark_rooms_and_stuck_walks.md`
§4.4 built, but a lost position leaves nothing to plan from and ends the call. The
survey stopped having walked four rooms of a thirty-room budget across five legs of
fourteen, with five of eight surveyor calls spent and four claims still open —
very nearly the accounting that document's §1 records as the failure it was fixing.

## 4. The surveyor judged the well correctly and the arithmetic overruled it

The recovery failure above is the second half of the problem. The first half is why
a survey descended a well it had no reason to enter, and the answer is not that the
model reasoned badly or that the system lacked the evidence. The model reasoned
correctly, wrote its conclusion down, and the scoring function ignored it.

`ClaimPlanner#choose` (`claim_planner.rb:83`) is deterministic, so the choice can
be replayed. Restoring the run's own knowledge database, clearing the `opaque` flag
that the descent itself set on `#5 down`, and scoring the frontier set from room #5
reproduces the decision exactly:

| d | exit | target name | total | score |
|---|---|---|---|---|
| 0 | `#5 down` | `Too dark to tell.` | 1.0800 | **1.0800** |
| 3 | `#2 south` | `Market Square` | 1.1550 | 0.2888 |
| 4 | `#1 down` | `The Temple Square` | 1.2600 | 0.2520 |
| 4 | `#1 east` | `The Midgaard Donation Room` | 1.2600 | 0.2520 |
| 3 | `#2 east` | `The Entrance Hall Of The Grunting Boar Inn` | 0.4050 | 0.1012 |
| 4 | `#1 north` | `By The Temple Altar` | 0.3600 | 0.0720 |
| 4 | `#1 west` | `The Reading Room` | 0.3600 | 0.0720 |

The well wins by a factor of nearly four over the runner-up, and it does so on the
lowest raw score of the three leading candidates. Two mechanisms produce that
inversion and a third let it stand.

**Nearness is counted twice.** `score_extent_bounded` (`predicates.rb:164`) is
`1.0 / (1 + frontier[:distance])` and nothing else, so the coverage claim's entire
contribution is a nearness term; `ClaimPlanner#choose` then divides the summed
score by `1 + distance` a second time. At distance zero both factors are at
maximum, and claim 1 alone contributes 0.9 of the well's 1.08 at its full priority.
Any frontier in the room the agent is standing in is squared-favoured over every
other, which makes this descent the default rather than an unlucky draw.

**The claim that justified it is the one claim that can justify anything.** Claim
1's decisive test, in the surveyor's own words, is "every exit frontier has been
walked and loops back into already-visited rooms, or a room is reached with no
onward exits leading to new rooms". Coverage-as-justification applies to every
frontier equally and therefore discriminates between none of them, so a predicate
whose score is pure nearness hands the decision entirely to the divisor. Meanwhile
claim 5's decisive test named a specific frontier — "Room reached via south exit
from #2 is classified as commercial" — and that frontier, `#2 south → Market
Square`, is the one the surveyor had hinted `commercial` with the note "confirmed
commercial hub, directly settles C5". It scored 0.2888.

**The surveyor's assessment of the well was recorded and then read by nothing.**
`frontier_hints` for `#5 down` holds:

```
expected_class: religious
note: Well leading into darkness beneath the sanctum — likely a temple undercroft
      or dungeon, not town-level layout; low priority for surface mapping
```

The model looked at the well, understood what it was, and said in writing that it
was low priority for the objective. Two of the four predicates in play read hints
at all — `score_composition` (`predicates.rb:95`) and `score_exists`
(`predicates.rb:127`) — and both read only `expected_class`, as an equality test
against a class the claim is looking for. The `note` is read by nothing anywhere.
`score_extent_bounded`, which supplied 83% of the winning score, does not look at
hints at all. The system asked the right question, got the right answer, persisted
it, and then chose against it.

This is what makes the policy the user requires implementable rather than
speculative. The judgement "this exit leads somewhere I cannot assess and my
objective does not justify the risk" is not a new capability that has to be
invented; it is a judgement the surveyor already made, in a field the store already
has, at a moment the code already reaches. What is missing is that the judgement
has no effect.

A smaller finding sits in the same neighbourhood. `SurveyGraph#lexical_clue?`
(`survey_graph.rb:153`) tests `(tokens(text) & wanted).any?` without subtracting
`STOPWORDS`, the identical defect `fix_surveying.md` §3.1 has just corrected in
`DestinationSearch#token_overlap?` and `RoutePlanner#target_name_clue?`. It did not
contribute here, because the classes in play shared no token with any candidate,
but it means the tokens of `Too dark to tell.` — including `to` — can act as a clue
for any claim class containing a function word.

## 5. Proposed fix

Three requirements, in the order they matter. A frontier whose destination cannot be
assessed must not be entered without a reason, and a frontier nobody has assessed
counts as one of those (§5.1–§5.3); a lost position must be recoverable by a bounded
procedure that terminates in one of four stated outcomes, two of which are the
difference between having proved something and having run out of budget (§5.4–§5.5);
and the answers the player reads must name actions the player can take (§5.6). As in
`dark_rooms_and_stuck_walks.md`, nothing here reads the MUD's wording.

### 5.1 Assessability is a property the surveyor reports, not a string the code recognises

The distinction that matters is between a destination the MUD has named and a
destination the MUD has declined to name, and it cannot be drawn by code from the
string alone without either enumerating server sentences or guessing at typography,
both of which §8 refuses. It can be drawn by the surveyor, which reads the room's
prose and the exit listing together and demonstrably drew it correctly in this run.

`frontier_hints` gains two answers alongside `expected_class`, and they are two
fields rather than three values of one because a destination can be perfectly
legible and still dangerous. Conflating them is what would turn a rule meant to keep
the agent out of wells into a rule that keeps it out of half of Midgaard.

**`assessability`** — can anything about the far side be weighed before entering it?

| value | meaning |
|---|---|
| `assessable` | the exit names a destination, and the name is a place |
| `unassessable` | the exit names nothing that can be evaluated before entering it |
| `unknown` | nobody has been asked, or the surveyor did not answer |

**`hazard`** — is there a reason to expect trouble beyond it?

| value | meaning |
|---|---|
| `none` | nothing in the name or the room's prose suggests danger |
| `suspected` | the name or the prose reads as risky |
| `known` | something already observed there was dangerous |

`Too dark to tell.` is `assessability: unassessable`, with nothing to say about
hazard, because entering is a bet rather than a choice and the bet is not
specifically about danger. "The Dark Alley" is `assessability: assessable` with
`hazard: suspected`: the name is readable, it is genuinely a clue about what is
there, a claim about a town's rougher quarters can be about it, and a survey with a
reason to go should go. Readable darkness in a name and an unreadable destination
are different facts about different things.

Silence is `unknown` rather than `assessable`, and `unknown` defers exactly as
`unassessable` does under §5.3. Defaulting to `assessable` would be fail-open, and
"must not be entered without a reason" cannot be satisfied by a field whose absence
means permission. The two values stay distinct despite deferring alike because they
behave differently over time: `unassessable` is a finding, recorded once and not
asked again, whereas `unknown` is the absence of one and is re-asked the next time a
surveyor is shown that frontier.

The deferral in §5.3 is written so that a map where nothing has been assessed does
not deadlock. On a cold map every frontier is `unknown`, the set of assessable
frontiers is empty, and an empty set is drained, so every frontier is immediately
eligible and scored normally. Deferral therefore costs nothing until an assessment
exists to defer against, which is also the answer for travel mode, where there is no
surveyor to ask and every frontier is `unknown` by construction.

Two supporting changes make an assessment durable rather than per-call. First, a
hint recorded for a frontier survives into later sessions, as hints already do, so
the judgement is made once per exit rather than once per survey. Second,
`Store#note_opaque_exit!` (`store.rb:529`) should write
`assessability: unassessable` for the exit it marks, leaving hazard alone, because a
walk that returned no information has established retrospectively exactly what the
surveyor is being asked to predict, and an exit that has proven unreadable should
not need predicting again.

### 5.2 Nearness is counted once, and coverage does not outrank a lead

Independently of any risk judgement, the scoring inversion in §4 is a defect on its
own terms and should be fixed on its own terms.

`score_extent_bounded` should stop being a nearness term. Its job is to say which
frontier best advances "the extent of this place has been traced", and every
unwalked frontier advances that equally, so the honest score is a constant and the
one nearness term belongs where it already is, in `ClaimPlanner#choose`'s
`1 + distance` divisor.

That change alone does not flip the recorded decision, and an earlier draft of this
document claimed it did on a mis-derived figure. Replaying the fix against the run's
own map: the well stays at 1.0800 while `#2 south → Market Square` rises from 0.2888
to 0.4575, because removing the double count lifts every distant frontier rather than
lowering the near one. The well's lead narrows from 3.7× to 2.4× and it still wins.
The remaining factor is the divisor, which is the single nearness term the design
intends and is steep on purpose — a frontier in the room the agent is standing in
costs one move and one three rooms away costs four — so nothing in the arithmetic is
now wrong. What follows from that is that §5.1 and §5.3 are load-bearing rather than
belt-and-braces: an assessment is what keeps the agent out of the well, and this
section only stops nearness being counted for it twice.

`score_extent_bounded` should also read `expected_class` the way `score_composition`
and `score_exists` do, so that coverage stops being the one predicate blind to
every hint the surveyor writes. A claim whose decisive test is "walk everything"
still justifies walking everything; what it must not do is decide the order while
ignoring the only evidence available about what each door leads to.

### 5.3 A frontier nothing is known about needs a reason, not a ban

With §5.1 supplying the two fields and §5.2 removing the double count, the policy is
a small rule at one site. `ClaimPlanner#choose` partitions the frontier set rather
than ranking it flat:

1. Frontiers whose `assessability` is `assessable` are scored as they are today.
2. A frontier whose `assessability` is `unassessable` or `unknown` is scored only
   against claims whose decisive test it can actually settle — which for a
   destination nothing is known about means a claim explicitly about what lies beyond
   that exit, and in practice means a surveyor hint naming it.
3. If no such claim exists, the frontier is deferred rather than dropped: it stays in
   the set, it is reported in the listing with its label, and it becomes eligible
   once every `assessable` frontier in scope has been drained.

The third clause is what keeps this a threshold rather than a prohibition, and it is
also what keeps clause 2 from stalling a map nobody has assessed yet, since an empty
assessable set is a drained one (§5.1). A survey whose remaining leads are all behind
unreadable doors should take one and report what happened, because that is the honest
end of a coverage claim; a survey with Market Square three moves away should not.

`hazard` does not partition anything. A `suspected` or `known` hazard scores normally
and its label travels into the listing and into the surveyor's next payload, because
a warning the model wrote should inform the model rather than bind it. The one place
it earns arithmetic is as a tie-break behind everything else, so that two frontiers
alike in every other respect are separated by the one where nothing has gone wrong.

The same partition belongs in `RoutePlanner#frontier_rank_key` for travel mode,
where the label is available from the store and there is no surveyor to consult.
Travel already has a stronger reason to avoid these exits than a survey does: a
`move_to` toward a named destination gains nothing from a door that pays no
information.

### 5.4 A lost position is walkable

`position_unknown` should stop being an answer that ends a `move_to` call and become
a state the call can act in, bounded exactly as every other walk is.

When the planner answers `position_unknown` and the destination the player named is
a bare direction, `MoveTo` walks that one step and lets `Hooks#reconcile_move!` try
to identify where it lands, rather than refusing before any command is sent. The
agent asked for `north`, `up`, `east`, `west`, `south` and `out` in this run, and
each request was a correct reading of its situation. One step is enough to be worth
sending, because the answer is either a room the rest of the subsystem can plan
from or a second unreadable reply, and the second case is still information: it
distinguishes a direction that is a wall, where the refusal costs no movement point
and the position is unchanged, from a direction that moved the character into
somewhere else unreadable.

### 5.5 A bounded sweep, ending in one of four stated outcomes

Naming a direction per model call is better than being refused, but it is not a
recovery procedure, and the earlier draft of this document was wrong to leave the
automatic version as an open question. Seventeen model calls at roughly 6,000 input
tokens each is the price of not having one, and the argument against walking
without the model's say-so is answered by a bound rather than by refusing to walk.

On `position_lost`, `ExecuteRouteTool` continues to try the reverse of the direction
just taken, which is one round trip and normally succeeds. When that fails, it
sweeps: canonical direction order, skipping the reverse it has already tried, one
MUD move per step and no model calls, until one of four things is true.

- **`recovered`** — a step lands somewhere `resolve_position` can identify. The
  position is re-established, the loop resumes against the corrected map, and the
  rooms walked through count against the call's ordinary room budget.
- **`aborted`** — the sweep is interrupted by a fight or a death. This is handed back
  exactly as an interruption is today, because both belong to the player, and it says
  which directions remain untried.
- **`stuck`** — every direction has been refused from where the character now stands
  and none of them moved it. This is a proof rather than a guess: the room is sealed,
  no further walking can help, and saying so lets the session end on a conclusion
  instead of on `max_tokens`.
- **`recovery_exhausted`** — the step budget ran out with directions still untried,
  or with the character somewhere new whose exits have not all been tested. Nothing
  has been proved; the sweep simply stopped. This is the outcome that invites one
  more attempt, and the distinction from `stuck` is the whole reason it is a separate
  status: after `stuck` another blind step is pointless, and after
  `recovery_exhausted` it is the obvious next move.

The two exhaustion cases were one in an earlier draft, which made §6 contradict this
section. Separating them is not bookkeeping: they carry opposite instructions to
whatever reads them, and a maze will produce `recovery_exhausted` almost every time
while `stuck` requires a room with no working exit at all.

The bound is a new `tools.navigation.limits` knob rather than a constant, as every
other limit in this subsystem is, and it counts MUD moves rather than rooms because a
refused direction costs a round trip and no movement. A refusal and an unreadable
arrival are recorded distinctly during the sweep, since a refusal means the character
has not moved and the untried directions are still untried, whereas an unreadable
arrival means the character is somewhere new and every direction is untried again.
That distinction is also what makes `stuck` provable: it can only be reached when
every canonical direction has been refused with no successful move since the last
reset, so the tried-set describes one room rather than a path through several.

The sweep writes nothing to the map. Rooms it cannot identify are not created,
edges are not linked, and no arrival edge is recorded for a step whose origin is
unknown, which is the same discipline `back_out` already keeps and the reason a
one-way passage costs one move rather than a corrupted graph.

### 5.6 The answers and the state block stop naming actions the player cannot take

`render_position_unknown` and `MoveTo#remedy` should each name a call the player can
actually make, and after §5.4 there is one. The `look` and the light source should
go: the first because the hook already looks on every iteration and the model cannot
call it, the second because no tool on the allowlist can equip or cast one.

Both answers should also say what is known rather than only what is not.
`player_state.prev_room_id` and `last_direction` survive the position being cleared,
so "your location has not been established yet" can become "you walked `down` out of
The Clerics' Inner Sanctum (#5) and where you are now could not be identified; `up`
did not lead back".

`StateBlock#location_line` should distinguish a position never established from one
lost, using `prev_room_id` to tell them apart, and carry the same remedy on the lost
variant. This is the cheapest of the changes and probably the most valuable, since it
is the line the model reads on every iteration and the only one it read on all
twenty-three of the wasted ones.

The two exhaustion outcomes of §5.5 need different lines for the same reason they
need different statuses. After `recovery_exhausted` the line should say that walking
has not been ruled out and the budget simply ran out, because one more `move_to` with
a direction is then the reasonable next call. After `stuck` it should say that every
direction has been refused and walking cannot help, because at that point the
reasonable next call is none: an agent that knows it is sealed in can end the session
on that conclusion, and an agent told "not established yet" spends the rest of its
context finding out.

## 6. What the fix does to the recorded run

**The descent does not happen, and the assessment is what stops it.** Replayed
against the run's own map with the well labelled as the surveyor's note already
described it, the deferral in §5.3 puts `#5 down` in a worse tier than everything
else, the scored pool is the seven-frontier set minus the well, and
`#2 south → Market Square` wins it at 0.4575 — the frontier claim 5's decisive test
names and the surveyor had already annotated `commercial`, "confirmed commercial hub,
directly settles C5". Its written judgement about the well, "low priority for surface
mapping", has effect for the first time.

§5.2 on its own does not achieve this, as that section now records: the well keeps
its 1.0800 and still wins. Both replays are worth stating together, because they say
which change is doing the work:

| | `#5 down` | `#2 south` | chosen |
|---|---|---|---|
| as recorded | 1.0800 | 0.2888 | the well |
| §5.2 only | 1.0800 | 0.4575 | the well |
| §5.1 + §5.3 | deferred | 0.4575 | Market Square |

The survey continues into Market Square with twenty-six rooms and nine legs still in
budget, which is the outcome `dark_rooms_and_stuck_walks.md` §5 predicted for the
previous run's equivalent trap and did not get.

**If the descent happened anyway, the run ends on a conclusion.** Suppose the extent
claim were the only one open and the well were the last frontier, which is the case
§5.3 deliberately still permits. The character lands in room 7026, the reverse step
fails as it must, and the sweep tries `north` into 7025 — also unlit, so it moves
without identifying — then continues under its budget. The sewers are a dark maze of
lit-nowhere junctions, so the honest expectation is that the budget runs out rather
than that lit ground is found, and the call returns **`recovery_exhausted`** rather
than `stuck`: nothing has proved the character is sealed in, and room 7026 in fact has
three working exits, so `stuck` would be a false claim. The player then has a real
choice — spend another call on another sweep, or stop — where the recorded run had
neither. Either way it costs a handful of MUD round trips and one or two model calls
instead of seventeen, and the session ends on a decision rather than on a full
context window.

The gates to measure it against are the ones in `fix_surveying.md` §5, and
`no_progress_calls` is the one that carries this run: seventeen of eighteen today,
and at most three if any of the above works.

## 7. Tests

- `test_navigation_predicates.rb` — `score_extent_bounded` is constant across
  distances, and reads `expected_class` when one is recorded.
- `test_claims.rb` — the recorded frontier set from room #5 scores `#2 south` above
  `#5 down`, which is the §4 replay as a fixture; an `unassessable` frontier is
  deferred while an assessable one remains and is chosen once the assessable set is
  drained; an `unknown` frontier defers on the same terms, so silence is not
  permission; a map on which nothing has been assessed defers nothing, which is the
  cold-start case §5.1 relies on; a `hazard` frontier is never deferred and separates
  an otherwise exact tie.
- `test_survey.rb` — a surveyor answering `unassessable` for the nearest frontier
  sends the walk elsewhere; a surveyor answering nothing at all for it does too; the
  assessment survives into a second survey without being asked again, while `unknown`
  is asked again.
- `test_move_to.rb` — with the position unknown, a bare direction walks one step
  rather than answering `position_unknown`; a step landing somewhere readable
  resumes the ordinary loop; a destination that is not a direction still answers
  `position_unknown`, now naming the room the agent left.
- `test_execute_route.rb` — the sweep's four outcomes, and in particular the two that
  must not be confused: `stuck` only when every canonical direction has been refused
  with no successful move since the last reset, and `recovery_exhausted` when the step
  budget runs out with anything still untried. Also recovery on the second direction
  tried, `aborted` on an interruption mid-sweep, a refusal leaving the remaining
  directions untried while an unreadable arrival resets them, and nothing written to
  the map by any path through it. `test_one_way_exits_are_not_reversed` and the
  existing one-way-passage case remain the regression guards for the reverse step
  keeping its current behaviour.
- `test_state_block.rb` — never established, lost, `recovery_exhausted` and `stuck`
  render as four different lines; the three latter name the previous room and the
  direction taken; `recovery_exhausted` names a call the player can make and `stuck`
  says that none will help.
- `test_exit_name_resolution.rb` — marking an exit opaque records
  `assessability: unassessable` and leaves its `hazard` value alone.
- `test_navigation_route_planner.rb` and `test_survey.rb` — `lexical_clue?`
  subtracts `STOPWORDS`.

No test hands production code a MUD sentence to recognise. `Too dark to tell.`
belongs in fixtures, as `It is pitch black...` already does.

## 8. What is deliberately not proposed

**No recognition of the sentence.** A test for `Too dark to tell.`, or for any list
of strings a server prints when it will not name a destination, would have prevented
this run and left the class of failure exactly where it is: a fog room, a blindness
effect, a reskinned server or a translation would each fail the same silent way.
This is the argument `dark_rooms_and_stuck_walks.md` §4 makes about
`It is pitch black...` and the one `unreachable_destinations.md` §8 makes about the
parser's vocabulary. §5.1 puts the judgement where the vocabulary lives, which is in
the model.

**No structural test on what a room name looks like.** Every room name in the
recorded map is a title-cased phrase with no terminal punctuation and
`Too dark to tell.` is a sentence, so a predicate derived from the agent's own
recorded names would separate the two without naming any server string. It is
rejected because it is a heuristic on prose that would misfire in both directions on
a world this project has not seen, and because a wrong answer from it would be
invisible: an exit silently reclassified by typography gives nobody anything to read.
The surveyor's answer, by contrast, arrives with a note attached.

**No learned poisoning of the target name.** An earlier draft of this document
proposed that `note_opaque_exit!` poison the exit's target name through
`note_ambiguous_exit_name!`, so that every other exit in the map carrying the same
string would be demoted. It is dropped because the mechanism is wrong for the fact:
`exit_name_ambiguity` means "this name does not identify a room", and the conclusion
being drawn here is "the destination beyond this exit cannot be assessed", which is a
property of exits and not of names. §5.1 records it on the exit instead. The
name-level effect is not needed either, since `assessability` is asked of every
frontier and defaults to deferral when unanswered, so an exit no accident has yet
happened at is already covered.

**No light source, and no opinion about the allowlist.** A level-ten cleric knows
`light`, and with `cast_spell` or `use_magic_item` on the player's surface this room
would be readable and none of the above would be needed. That is a settings question
about what the player may do rather than a defect in the walking engine, and it
should be decided on its own terms rather than as a side effect of a movement fix.

**No repair of the map below the drop.** The agent knows it walked `down` out of
room #5 and cannot identify where it landed, and a placeholder room for the far side
would record that something is there. Nothing could name it, route through it or
fingerprint it, so the row would be a permanent unknown, and `note_opaque_exit!`
already records the same fact where it can be read.
