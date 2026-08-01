# Dark Rooms and Stuck Walks

Diagnosis and proposed fix for run `20260730T201534Z-791c06b2`
(`explore_midgaard`, session `20260730T201603Z-ff25f010`), the run in which the
agent spent twenty consecutive model calls asking to walk north out of The Dump
and never moved.

Status: implemented, `week2_capable/boukensha` suite green at 739 runs.
Everything in §1 and §2 is read off the recorded session; §3 is the diagnosis
and §4 is what was built.

## 1. What the run actually did

The judge's summary is accurate as far as it goes — one survey call, one move to
the sewer, then twenty-odd identical failed retries of `move_to("The Common
Square")` from The Dump — but it describes the symptom rather than the cause,
and the cause is not that the model chose badly. The model was reasoning
correctly against a position the subsystem had recorded wrongly.

The whole session issued 23 model tool calls and 91 MUD calls for $0.28 and
ended on `max_tokens` rather than on any decision to stop. Of the 26 `tbamud__move`
calls, four succeeded, two succeeded but were recorded as failures, and twenty
were genuine refusals caused by those two mis-recorded successes. The complete
movement sequence is short enough to read in full:

| # | direction | MUD reply | prompt |
|---|-----------|-----------|--------|
| 1 | south | `The Temple Square` … | 21H 116M 95V |
| 2 | south | `Market Square` … | 21H 116M 94V |
| 3 | south | `The Common Square` … | 21H 116M 93V |
| 4 | south | `The Dump` … | 21H 116M 92V |
| 5 | down | `It is pitch black...` | 27H 132M 95V |
| 6 | down | `Alas, you cannot go that way...` | 27H 132M 95V |
| 7 | north | `It is pitch black...` | 27H 132M 94V |
| 8–26 | north | `Alas, you cannot go that way...` | 27H 132M 94V |

Moves 5 and 7 are arrivals in unlit rooms. The subsystem classified both as
rejected moves, which left `player_state.current_room_id` pointing at The Dump
while the character was two rooms into the sewer beneath it. From that moment
every plan the system produced was correct about a place the character was not
standing in.

## 2. Why moves 5 and 7 were arrivals

This matters enough to establish from the transcript rather than from
recollection of how CircleMUD-family servers behave, because the fix hangs on
it. Three independent facts in the recorded text agree.

The movement points settle it most directly. Each successful `south` in moves 1
through 4 costs exactly one movement point, taking the character from 95V to
92V. A refused move costs nothing, which is visible in moves 5 and 6: the reply
to move 5 is at 95V and the reply to move 6 is also at 95V, so whatever move 6
did, it did not move anyone. Move 7 reports 94V, one point lower than the
`Alas` that preceded it, so move 7 spent a movement point and therefore moved
the character. The pitch-black replies charge for movement and the `Alas`
replies do not.

The change in the server's answer confirms it a second way. Moves 5 and 6 both
requested `down`. If move 5 had been a refusal the character would still have
been in The Dump for move 6, and the server would have answered identically;
instead the answer changed from `It is pitch black...` to `Alas, you cannot go
that way...`, which is only possible if the character was somewhere else by
then. The same pattern repeats across moves 7 and 8 for `north`.

Finally, the surveyor's own ledger had already inferred the room's existence
from The Dump's description, opening the claim that "the sewer system is a
distinct sub-region of Midgaard accessible only via the down exit from The
Dump." The one thing the run needed in order to settle that claim was the step
it took and then failed to notice it had taken.

I have not read the tbaMUD source for `do_simple_move` and `look_at_room` to
confirm that the pitch-black message is emitted after the character has been
moved into the destination room, because the engine source is not in this repo.
That check turned out not to be load-bearing: the fix built in §4 never asks
what the message means, so it does not rest on the answer. The transcript
evidence above stands on its own for the purpose of explaining the run.

## 3. The failure chain

Five separate pieces of the system each behaved reasonably in isolation and
compounded into a session that could not recover.

**Unreadable output had nowhere to go but "refused".**
`Hooks#reconcile_move!` (`hooks.rb:243`) returned `{ ok: false }` for any reply
that failed `RoomParser::Look#complete?`, and called
`record_frontier_attempt!(outcome: "failed")` on the room it believed it was
standing in, leaving that belief untouched. That is the correct handling of a
refused move and the wrong handling of everything else that can produce
unreadable text, and the two were indistinguishable because the return shape had
only two values for a world that has three. A move either arrives somewhere we
can identify, or is refused, or — the case with no representation — moves the
character somewhere we cannot identify. The single-move path in
`#movement_outcome` (`hooks.rb:648`) had the identical gap, so this was never
confined to batched walks.

It is worth being precise about what the defect is not. The parser's
`complete?` test is right to be a whitelist on the success shape, and widening
it to recognise one more sentence would have fixed this run and left the class
of failure in place: a blindness effect, a fog room, a description bug, a
reskinned server or any output this project has not seen yet all fail the same
silent way, because the silence comes from the missing third state and not from
the missing vocabulary. No amount of reasoning by the model closes that gap
either — the model was never told anything was wrong. It was told, with
confidence, `here: The Dump (#5)`.

**Nothing afterwards could discover the desync.** `before_model` re-establishes
position only through `cold_look`, which returns `nil` whenever
`@current_room_id` is already set. Because the desync left a room id in place,
the system never looked again: after move 4 the session issued no further
`tbamud__look` at all. A position that is wrong in this way is permanently
wrong for the life of the process.

**A refused step ends the entire tool call.** Both `MoveTo#leg`
(`navigation/move_to.rb:548`) and `Survey#leg` (`navigation/survey.rb:389`)
treat any non-nil `stopped` field from `ExecuteRouteTool.walk` as an
interruption, set `@status = "interrupted"`, and return. `ExecuteRouteTool.walk`
already distinguishes death from refusal internally but collapses the two into
one prose sentence on the way out (`execute_route_tool.rb:67`), so the callers
have nothing to branch on. The consequence for the survey is severe: it aborted
on leg 5 of a fourteen-leg, thirty-room budget having walked four rooms, with
four claims still open and three surveyor calls still unspent. The consequence
for travel is that each `move_to` call performed exactly one MUD move, failed,
and returned — one full model call and roughly 6,000 input tokens per refused
step.

**The known branch never consults the failure record.** The twenty refusals were
faithfully written to `frontier_attempts`, and `PlanRouteTool` does read
`store.frontier_attempt_counts` — but only to rank *unexplored* frontiers. The
path north out of The Dump was a walked edge, so `plan_route` answered `known`,
and `MoveTo#walk_known` executes a known path without a navigator call and
without any reference to how many times that edge has recently refused. This is
why `move_to.decision` appears once in the whole session's journal: nineteen of
the twenty stuck calls made no decision at all, they replayed a remembered edge.

**The rendered result invited the retry.** The text the model received twenty
times was:

```
[move_to] The Common Square — interrupted
leg 1:
  stopped: move failed (north)
walked 0 rooms in 1 leg
here: The Dump (#5)
```

"Interrupted" describes a transient event, so retrying is the reasonable
response to it, and the last line asserted a position the system had twenty
consecutive pieces of evidence against. Nothing in the message told the model
that the map and the world disagreed, and nothing carried across calls to notice
that this was the twentieth identical one.


## 4. What was built

The organising decision is that nothing in the fix reads the MUD's wording.
Recognising "It is pitch black..." would have repaired this run and left every
other cause of unreadable output failing the same way, so the subsystem instead
gained the state it was missing and a cheap way to resolve it. Where judgement
is genuinely required, it is handed to the model with an honest description of
the situation rather than resolved by a table of strings.

### 4.1 Unreadable output means the position is unknown, not unchanged

`Hooks#settle_unreadable_move` is the new centre of this. When a movement reply
cannot be read as a room, it spends one `look` — a MUD round trip and no model
call — and lets the answer decide between three outcomes:

| the look says | conclusion | what is recorded |
|---|---|---|
| a room, and not the one we were in | we moved | resolve position normally, link the arrival edge, attempt `succeeded` |
| the room we were already in | the move was refused | attempt `failed`, nothing else changes |
| still unreadable | we are somewhere unreadable | attempt `succeeded`, exit marked opaque, position dropped |

The third row leans on the second, and that inference is the whole mechanism: a
moment ago we read the room we were standing in, so a `look` that now reads
nothing is evidence we are no longer standing there. It is the same reasoning
§2 does from the transcript, and it needs no vocabulary to reach.

Identity is decided by the weak fingerprint `resolve_position` already uses, so
"is this the same room" is asked the same way everywhere rather than drifting
onto a name comparison. Two rooms in a maze can share that fingerprint, and for
those this answers "same room" when we have in fact moved one step — the old
behaviour, in the one case the old behaviour was defensible, and it costs a
stopped walk rather than a corrupted map because that branch deliberately writes
nothing.

A refusal does **not** demote the edge it was refused on. A closed door, a
guard, an exhausted character and a genuinely wrong edge all produce the same
refusal, and only the last would deserve it; the failed attempt is recorded and
the existing frontier ranking already reads those counts.

The frontier attempt is written by whichever branch above turns out to be true,
and never before. That is a change of timing as well as of value: the row used
to be written the moment the reply failed to parse, which is how twenty-two
false `failed` rows reached the recorded session's ledger, each one telling the
frontier ranker to avoid an exit that works.

The single-move path cannot spend a `look`, because `after_tool` is documented
as cheap and free of MUD I/O and a round trip there would land in the hot path
of every tool call. It therefore records the doubt in `@position_suspect`, and
`before_model` — the one body allowed to block — settles it through the same
`classify_position`, attempt row included. A readable arrival landing in between
cancels the pending `look` entirely and only discards its arrival edge, since
the edge is built from the belief that is in doubt while the position is not.

### 4.2 Both copies of the position are dropped

`Store#clear_player_room!` is new because `update_player!` compacts its
arguments, so a nil there means "no reading" rather than "the reading is
nothing". This matters more than it looks: `move_to`, `plan_route` and the
survey all take their starting room from `player_state.current_room_id`, so
clearing only the hook's ivar would have left the walker knowing it was lost
while the planner went on routing out of the room it used to be in. `note_death`
had the same latent gap and now clears both as well.

### 4.3 An exit that pays no information stops being a frontier

Migration V8 adds `room_exits.opaque`. An exit is a frontier only when nobody
knows what is behind it *and* walking it stands to tell us, and an exit already
walked for no information fails the second half. `RoutePlanner.frontier?` now
excludes them, which reaches the survey's own frontier set through
`SurveyGraph#build_frontiers` without a second change.

The column is deliberately not called `dark`. What was observed is that the
destination could not be read; darkness is only the most common cause, and
naming the column after one cause invites every later reader to test for that
cause specifically.

### 4.4 The walker distinguishes its stops, and backs out of the dark

`ExecuteRouteTool.walk` returns `stopped_kind` alongside the sentence it already
returned: `:refused`, `:unreadable`, `:interrupted`, `:died`, `:position_lost`.
On a lost position it first walks the reverse of the direction it just took,
which costs one MUD round trip and no model call and normally lands back
somewhere nameable, since the agent walked in from there a moment ago. This is
the one place the module assumes exits are symmetric, and it is safe here for a
reason it would not be in map building: nothing is recorded from the attempt, so
a one-way passage costs one move and reports itself rather than writing a wrong
edge.

`MoveTo#handle_stop` and `Survey#handle_stop` then respond per kind. An
interruption and a death still belong to the player and are handed back
unchanged. A refusal or an unreadable step is a disagreement the hook has
already settled, so the loop re-plans against the corrected map inside the same
call, bounded by `max_setbacks` (2 for travel) and `survey_max_setbacks` (4 for
surveys, which walk at the edge of the map on purpose and meet more of them).
Both are settings rather than constants, as the rest of the limits are.

### 4.5 The answer says what happened

`position_lost` renders as "stopped — where you are is no longer known", prints
`here: position unknown` rather than a room, and carries the one remedy the
player cannot infer from the rest of the message. "Interrupted" reads as
transient, which is why it was retried twenty times; a stop that states a
problem without stating what would resolve it invites the same call again.

### 4.6 What was left alone, and why

Two items from the failure chain in §3 were deliberately not addressed.

`walk_known` still does not consult `frontier_attempt_counts`, and a walked edge
that starts refusing is still planned through. Position repair is what actually
breaks the loop — once the believed position is corrected or dropped, the stale
plan stops being produced at all — so the edge-level repair is redundant for
this failure and carries a real risk of its own: demoting an edge on the
strength of a refusal discards a correct edge every time the cause was a closed
door, a guard, or an exhausted character. It is worth revisiting if a run shows
a genuinely wrong walked edge surviving, which this one does not.

There is also no cross-call counter watching for repeated no-progress calls from
the same room. With position now either corrected or honestly unknown, the
twentieth identical call has no way to arise: `plan_route` answers
`position_unknown` rather than handing back a confident route out of a room the
character has left. A counter would be machinery guarding a state the fix
removes, and it would be the third place in the system holding an opinion about
where the character is.

## 5. What this costs

One `look` per unreadable movement reply. About one move in twenty is refused in
ordinary play, so a thirty-room survey buys roughly one or two extra MUD round
trips and no extra model calls. Set against the recorded run — twenty model
calls and roughly 6,000 input tokens each, achieving nothing — this is not a
close trade.

Against the recorded sequence specifically, the fix engages at move 5: the
`down` into the sewer is followed by a `look` that also comes back unreadable,
so position is dropped, the exit is marked opaque, and the walker steps back
`up` into The Dump. The survey resumes with twenty-six rooms and nine legs still
in budget, and the frontier it just proved uninformative is no longer on the
list. Moves 6 through 26 have no way to happen.

## 6. Tests

The existing suites covered the refusal case and nothing else, which is how this
reached a live run. What was added:

- `test_mud_hooks.rb` — the three outcomes of an unreadable move, in both the
  batched and single-move paths, asserting position, the opaque mark, and that
  an exit that moved us is never recorded as a failed attempt.
- `test_execute_route.rb` — `stopped_kind` per case; the reverse walk out of an
  unidentifiable room; a one-way passage reporting the position as lost.
- `test_move_to.rb` — a refused step re-planned inside the call; the setback
  ceiling enforced; a lost position rendered with its remedy and no room.
- `test_survey.rb` — a refused leg not ending the survey; the setback ceiling;
  and the recorded failure in miniature, a survey walking into a room it cannot
  identify, stepping back out, and spending the rest of its budget.
- `test_navigation_route_planner.rb` — an opaque exit is not a frontier, and is
  `exhausted` when it is the only one left.

None of these hands the parser a sentence to recognise. The tbaMUD dark-room
string appears only as a test fixture, which is the correct place for it: it is
one instance of the input class, and production code that named it would be
back to enumerating causes.

## 7. What was not broken

The claim ledger did its job and is worth saying so, because the run's headline
failure could easily be read as an indictment of the surveyor. Five surveyor
calls over four rooms confirmed three claims about Midgaard's structure and left
five well-formed open claims, each carrying a decisive test that a later session
could resume against, including the sewer claim that the failed step was about
to settle. The investigation model worked; the walking engine beneath it lost
track of where the character was standing.
