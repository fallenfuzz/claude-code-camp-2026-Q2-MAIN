# Mocking Messages and Test Stops

Asking ChatGPT if our regions system works:
  What it does today:
  - scope: "region" searches only frontiers belonging to the current region and its children.
  - scope: "world" searches all reachable frontiers.
  - Known destinations can be routed to across region boundaries.
  - Frontier ranking prefers fewer region crossings.
  - The navigator sees the current region’s label and shape.
  What it does not do:
  - It does not ask, “Which region is the bakery likely in?”
  - It does not rank Midgaard above Countryside because bakeries belong in towns.
  - It does not show the navigator each candidate frontier’s region.
  - It does not route to Midgaard first and then explore Midgaard’s remaining frontiers.
  - It has no region-level descriptions, remembered categories, or semantic search over region labels.

But before we can even solve this problem we have not observed our agent actually
spit regions because it honestly hasn't left the boundary which was a problem before
but solved with our updated move_to code. 

Its costly for us to setup such a scenario, and might be hard to guide the agent
that way so two things:
- We want to be able to in the scenario directly write in the messages passed to the agent
  - This will set up our agent to be on the verge of a boundary or crossed a boundary and to observe is reason to rename and/or split a region
- We want to stop the agent to keep the test costs low. I suppose this is an assert simply failing and stopping, but the idea is to prevent the agent from just running on and on pass our point of what we want to see work or fail. The question is will a single assert fail should stop it or we ahve more robust stop conditions so agent has room to think and attempt.

## Technical Solution

Note: code lives in `week2_capable/boukensha/`. Every file and line reference
below was checked against the working tree.

---

### 1. The proposal, in short

Stage the model calls we are not measuring, and leave exactly one live. Every
agent in the system — player, navigator, cartographer, judge — is a model call
that can be answered from a script instead of from the network, and choosing
*which one stays live* is what turns "we have never seen a region split" into a
run that costs cents and takes a minute.

The region pipeline has three consumers of a model, and they fail to be
observable for different reasons. The player has to walk far enough to build a
sprawling region, which is slow and unreliable. The navigator has to volunteer
`scope_suspect: true`, which it has never done in a measured run. The
cartographer only runs *after* the navigator volunteers, so it has never
executed against a real model at all — every line of evidence we have for it
comes from `ScriptedReasoner` in `test_move_to.rb:505-601`.

So the ladder is:

| Run | player | navigator | cartographer | What it observes | Cost |
| --- | --- | --- | --- | --- | --- |
| **A** | staged | staged, `scope_suspect: true` | **live** | Whether a real cartographer places a defensible boundary on a real Midgaard graph. The first time this call has ever run. | one model call |
| **B** | staged | **live** | staged | Whether a real navigator raises scope on a genuinely sprawling region, which is the judgement §5 of `boundaries_revised.md` rests on. | one call per leg |
| **C** | staged | live | live | The two halves composed: detection feeding placement. | a few calls |
| **D** | live | live | live | The whole thing unmocked, as the gate that decides whether any of it survives contact with the player. | a full case |

Run A first. It is the cheapest, it exercises code that has never run live, and
if a real cartographer cannot place a sane boundary given a good graph then B
through D are measuring a downstream of something broken.

Both halves the plan above asks for are in service of this. Staging is §3 and
§4; the map memory the staged calls are authored against is §5; the stop
conditions that keep runs C and D from overrunning are §8.

---

### 2. Every model call in the system already passes through one object

There is a single chokepoint, and it is `Client#call` (`client.rb:25-89`).
Three construction sites feed it — `Boukensha.run` for the player
(`boukensha.rb:125-126`), `Boukensha.repl` for the interactive session
(`boukensha.rb:196-197`), and `Boukensha.run_task` for every subagent
(`boukensha.rb:278-279`) — and `Reasoners` builds the navigator and the
cartographer as lambdas over `run_task` (`reasoners.rb:43-49`), so they arrive
here too. Nothing else in the codebase opens an HTTP connection to a model.

That makes staging a wrapper around one method rather than a feature threaded
through four call paths, and it means no task needs to know it can be staged.
The navigator does not gain a test mode; it gains nothing at all, and is
answered by something other than the network.

`Agent#wrap_up` (`agent.rb:248-273`) calls the same client for its wind-down
turn, so a staged run must have an answer ready for it or a case that trips a
ceiling will punch through to the network on its last breath. This is the one
easy thing to forget and §12 tests it.

Recording needs its own seam rather than reuse of the session log, and the
reason is specific: `Logger#raw` is gated behind `Boukensha.debug?`
(`logger.rb:359-363`), so response bodies are not normally written, and
`Logger#tool_call` mints its own `call_#{hex}` identifier (`logger.rb:284`)
instead of recording the API's `tool_use` id. A cassette rebuilt from a session
log would therefore have tool-use blocks whose ids match nothing, which the
Anthropic backend's `tool_result` serialisation (`backends/anthropic.rb:43-52`)
requires. Recording the exact response body at the client is a few lines and is
faithful by construction.

---

### 3. Staging is addressed by task and ordinal

#### 3.1 Surface

```yaml
# .boukensha/tests/scenarios/split_the_bridge_quarter.yml
session_name: split_the_bridge_quarter
player_profile: Derrano
goal: "Find the mayor's office."

base_initial_state: cleric
map_memory: snapshot:midgaard
initial_state_overrides:
  location: 3014

stage:
  # Required, and prose. A staged run is a claim about what the other agents
  # would have said, and the claim needs an author.
  because: |
    Run A of mocking_messages.md §1. The cartographer has never executed
    against a live model; this puts a real one in front of the real Midgaard
    graph and leaves everything upstream of it scripted.

  # Anything not named here stays live. The default is the real thing.
  player:
    # A staged assistant turn may carry tool calls, and the tools really run.
    - tools:
        - name: move_to
          args: { destination: "the mayor's office" }
    # Whatever it says once move_to returns is the end of the turn.
    - text: "I've reached the far bank; the office should be off the square."

  navigator:
    - direction: "north"
      reason: "The promenade is the only civic-sounding exit on the list."
      place: "Midgaard"
      scope_suspect: true
      scope_reason: |
        Sixteen unexplored exits at a median of six moves, half of them across
        the bridge. This has stopped meaning "here".

  # cartographer: not listed, therefore live. This is the whole point of the run.
```

A task's entry is a list of answers, consumed one per call in order. The
navigator and cartographer are answered with the field mapping their prompt
asks for, which the harness serialises to JSON and hands to
`Reasoners.parse` (`reasoners.rb:61-71`) exactly as if the model had returned
it — so the parser, its fence-stripping tolerance and its nil-on-garbage
behaviour all remain under test rather than being bypassed. The player's
entries are `text:` and `tools:` because a player answer is an agent turn
rather than a JSON document.

Running off the end of a task's list is an error that names the task and the
call number, never a silent fall-through to the network. A run that quietly
started paying for real calls halfway through would produce a report describing
a configuration nobody chose.

#### 3.2 Why `(task, ordinal)` and never a global sequence

The obvious addressing scheme is "the seventh model call of the run", and it is
the wrong one, because global ordering is precisely the thing that varies
between runs. One extra player iteration renumbers every navigator answer after
it, so a scenario that was correct on Monday stages the wrong answers on
Tuesday for a reason that has nothing to do with what changed.

Addressing by task is available for free. `Logger#task` pushes the task name
around every `run_task` body (`logger.rb:156-163`) and `Logger#current_task`
reads the top of that stack (`logger.rb:166-168`), which is already how the
`invoke_agent` span titles itself (`agent.rb:46`). The staging layer asks the
same question the logger does, so "the navigator's second answer" stays the
navigator's second answer however many turns the player took to get there.

#### 3.3 Three modes, per task

Each task is independently `live`, `staged`, or `record`. `live` is the default
and needs no declaration, which keeps an ordinary scenario file unchanged and
means staging is always opt-in and always visible in the YAML.

`record` calls the model for real and appends the exact response body to a
cassette. It is how a staged answer stops being something a human invented: run
once with everything recording, then replay with one task promoted back to
live.

#### 3.4 Cassettes: record once, replay many

A hand-written `stage:` block is right for run A, where the whole point is to
assert a `scope_suspect: true` that no model has yet produced. It is wrong for
runs C and D, where the staged upstream should be a real player's real
behaviour rather than an author's idea of it.

So `stage.from: <cassette>` replays `.boukensha/tests/cassettes/<name>.jsonl`,
one line per model call carrying the task, the ordinal, a digest of the request
and the verbatim response body. A cassette is produced by
`bk -ts <scenario> --record <name>`, which is one paid run, and thereafter every
task it covers can be replayed for nothing while any single task is promoted to
live. Inline `stage:` entries layer over a cassette and win, which is how run A
becomes run B: same cassette, one navigator answer overridden.

This is the honest answer to the plan's premise that staging such a scenario is
costly. It is costly once.

#### 3.5 Request drift is a signal, not an error

A recorded response was produced for a particular request, and on replay the
request will usually differ — the map is different, the position is different,
that is the point of the exercise. So the digest is recorded and reported, and
by default a mismatch is a warning rather than a failure.

The warning still earns its place. A navigator answer staged as `direction:
"north"` is resolved against the live candidate list by `choose`
(`move_to.rb:363-380`), and when north is not on that list the code falls back
to `plan_route`'s own top-ranked frontier and journals a `fallback` reason
precisely so that "a decision made by arithmetic never appears in the log as a
decision made by judgement". A staged direction that no longer exists therefore
degrades quietly into a run measuring the fallback path, and the digest warning
plus the journalled fallback are the two places that shows.

`stage.on_drift: strict` is available for the case where a scenario is pinned
against a fixed cassette and any drift means the fixture rotted.

---

### 4. Staging the player is stronger than mocking its transcript

My earlier draft proposed prefilling the player's conversation with fabricated
messages, and staging supersedes it for a reason worth stating plainly: a
fabricated `tool_result` is fiction, whereas a staged assistant turn carrying a
`tool_use` block makes the real tool actually execute. `Agent#handle_tool_calls`
dispatches whatever blocks the response contains (`agent.rb:325-335`), so a
staged player answer naming `move_to` walks the real character through the real
subsystem, writes the real store, and produces a tool result the model then
genuinely receives. The reasoning under test is reached by real code paths
rather than by a description of them.

Prefilled messages survive only where the point is to make the agent *believe*
something that did not happen — that it already tried `scope: "region"` and was
told the region was exhausted, say — and that is a narrower need than the one
this plan opened with. It stays on the roadmap as `stage.prelude:` and is not
part of the delivery order below.

---

### 5. Map memory is the other half, and the staging is authored against it

The staged answers above are only meaningful if the world the live task reads
is the one they describe, and for the region machinery that world is the store,
not the transcript. `MoveTo#navigator_payload` (`move_to.rb:304-326`) and
`cartographer_payload` (`move_to.rb:452-486`) are both built entirely from the
store and the current position, so a live cartographer given a two-room map
will decline to split it no matter what the staged navigator claimed.

`find_mayor_split` already says this in its own header: it needs "the fullest
map of the three", because the argument under test is a median of six moves
over sixteen unexplored doors and a small map has no such median. It declares
`map_memory: snapshot:midgaard`, and that snapshot does not exist —
`.boukensha/tests/knowledge/snapshots/` has never been created — which is why
the case is unrunnable today.

The mechanism to fix that is already built. `bk --snapshot-map midgaard
--profile Derrano --from-session <id>` (`cli.rb:66-79`) pins the map a retained
session ended with, and every case already retains its ending map under
`.boukensha/tests/knowledge/sessions/<profile>/` (`case_runner.rb:182-195`),
where eight of them are sitting from the last two days of runs. One exploration
run, snapshotted once, is the fixture for every case that follows.

Position and map have to be authored together. `state.location` seeds the
character into a room vnum and `Mud::Hooks#before_model` (`hooks.rb:203-219`)
resolves that against the store by fingerprint on the first iteration, so a
`location:` inside the snapshot gives a consistent starting point while one
outside it resolves as a newly discovered room — a silently different test. The
child can check this before the agent's first model call and warn, which costs
a seed rather than a run.

---

### 6. Plumbing

The staging block travels the road the settings override already travels, and
lands on the one object §2 identified:

```
scenario `stage:`
      │
      ├─ Fixtures#scenario          validates shape, resolves `from:` cassette
      │
      ├─ Fixtures::Case#stage       a new struct member (fixtures.rb:31-36)
      │
      ├─ Runner#payload_for         one more key in the payload file
      │                             (runner.rb:104-135)
      │
      ├─ CaseRunner#run             builds a Testing::Stage and installs it
      │                             beside the settings overrides
      │
      └─ Client#call                answers from the stage when the current
                                    task is staged; otherwise the network
```

`Testing::Stage` holds the per-task queues, the cassette, the ordinals and the
drift digests, and it is reached from the client through one module-level
accessor set by the child. That is a global, and it is the right shape here for
the same reason `Boukensha.config` is one: the alternative threads a test-only
argument through `.run`, `.repl`, `.run_task`, `Reasoners` and `MoveTo` so that
a wrapper around one method can be installed. It defaults to nil, and nil is
exactly today's behaviour.

`mud_agent_setup` is not touched, which matters. Its own comment
(`boukensha_loader.rb:285-288`) makes the case that the harness sharing
production setup verbatim is "the only version where a test session is genuinely
the same agent as a real one", and staging at the client preserves that: the
navigator lambda, the `MoveTo` loop, the limits, the journalling and the region
writes are all the production ones.

---

### 7. A staged run is not a real run, and the report has to say so

`settings_sweep.md` §4 and §5 established that a report must refuse to average
rows produced under different configurations, and staging is a larger difference
than any setting because it changes which agent was doing the thinking.

`stage:` is legal only in a scenario, which inverts the rule for `settings:` and
for the same underlying reason. `Fixtures#scenario` refuses `settings:`
(`fixtures.rb:121-125`) because a scenario that changed its own configuration
would make two runs of one name incomparable; a stage changes what is being
measured, so it *is* part of the scenario's identity and a plan or a CLI flag
that could attach one to an existing scenario name would produce two
incomparable populations under one name.

The `launch` record grows a `stage` field naming which tasks were staged, which
were live, and the cassette and digest if any. `SessionFacts` exposes `launch`
verbatim, so the report row and `mud_monitor`'s session view both get it, and
`Report`'s arm grouping treats the staged-task set as part of the arm key
alongside `settings_digest`. Nothing staged is written to
`.boukensha/tests/baselines/`, because a baseline is a number later runs are
compared against and a staged run's cost and call count describe a journey that
was partly asserted.

The most valuable line in the report for runs A through C is not the pass rate.
It is which task was live, because that is the only column that says what the
run actually measured.

---

### 8. Stop conditions

#### 8.1 An assertion and a stop condition are different things

The plan above asks whether a single failing assert should stop the run, and it
should not, because the two answer different questions and merging them corrupts
the report. An `expect:` rule is a verdict on a finished run, evaluated by
`Expectations.evaluate` as a pure function of the session log after the child
exits. A stop condition is a decision about whether to keep spending, taken
while the run is live.

Three concrete reasons the grader must not also be the brake. Most current
expectation kinds are budget ceilings (`expectations.rb:26-27`), and a ceiling
that terminated the run on breach would make every report's `end_reason` a
function of its own grading. `final_room` cannot be evaluated before the end at
all, since it is read from `player_state.current_room_id` afterwards
(`session_facts.rb:151-158`). And a run stopped by its own failing assertion
can no longer distinguish "the agent failed" from "we stopped it before it
recovered" — which is the distinction the `find_bakery_cold` baseline was read
for, since it passed by spending six decisions, returning `stopped on budget`,
and finishing on a second `move_to`.

The saving is on the other side. Expensive runs are the ones that keep going
after the thing we came to see has happened, so the tripwire that earns its
keep ends the turn on success.

#### 8.2 What exists

`max_iterations` and `max_turn_tokens` are checked at the top of the agent loop
(`agent.rb:63-70`) and both route through `wrap_up`, which spends a further
400-token call so the agent ends in character (`agent.rb:248-273`).
`wall_timeout_s` is enforced by the parent with SIGTERM and a ten-second grace
(`runner.rb:159-185`), and is a crash guard rather than a budget: a case it
catches has already spent everything.

#### 8.3 `stop_when:`

```yaml
stop_when:
  # The observation. Everything after a placed boundary is spend we did not
  # come for, so the case ends here and passes.
  split_declared:
    on: journal(move_to, region_split)
    then: pass

  # Runs A and B: the live task has answered, and there is nothing further to
  # learn from this case.
  cartographer_answered:
    on: task_answered(cartographer)
    then: pass

  # The wandering detector, as a count rather than a boolean. Three separate
  # move_to calls means the subsystem is not carrying the walk; two is what
  # find_bakery_cold already does and passes with.
  replanning:
    on: tool_called(move_to)
    count: 3
    then: fail
```

`on:` reuses the `name(arg: value)` grammar that `Expectations` and
`tasks.player.allow` already share through `Permissions.parse_rule`
(`expectations.rb:86-93`), extended with `journal(<stream>, <op>)` for the
navigation journal's events, `task_answered(<name>)` for the staging layer, and
the region predicates of §9. One grammar for "which occurrence do I mean",
because a second dialect is a second thing to get subtly wrong. `then:` takes
`pass`, `fail`, or `stop`, the last being the honest option for a tripwire
meaning "we have seen enough to read the log by hand".

`task_answered` is what makes runs A and B nearly free: with one live task and a
tripwire on its first answer, the case ends the moment the measurement exists.

#### 8.4 The check goes between iterations, not inside them

Evaluation happens in the child, in-process, in a `Testing::Tripwires`
subscribed to the session logger (`logger.rb:365-367`) and — after a matching
`subscribe` seam is added — to the journal, since `region_split` and
`region_named` are journal events rather than session events
(`journal.rb:84-89`). Watching the same streams the grader reads afterwards is
what keeps a tripwire and an assertion from disagreeing about one occurrence.

A trip sets a flag and `Agent#run` checks it at the top of the loop beside the
two ceilings already there. Firing at that point rather than when the event
arrives is a correctness requirement: a `region_split` line is written *during*
a `move_to` call that is still walking, and interrupting it would leave the
character in a room the store has not reconciled, the walk half-recorded and the
region write's follow-up unwritten. Between iterations `move_to` has returned,
the store is consistent, and the tool result is in the transcript where the
judge can read it.

Unlike the two existing ceilings, a tripwire skips `wrap_up`, since we know why
we stopped and no operator is waiting for a summary. The turn ends through
`@logger.turn_end(reason: "stopped:split_declared")`, which
`SessionFacts#end_reason` (`session_facts.rb:104`) already surfaces, so
`end_reason` becomes a new deterministic expectation kind at no instrumentation
cost.

#### 8.5 Room to think

The plan worries that a hair-trigger stop leaves no room to reason or recover,
and `count:` answers that better than a grace window does, because a count says
what the failure actually is — three `move_to` calls is re-planning, one is the
design working — whereas a window only says we were unsure. `grace_iterations:
N` exists as the secondary knob for the case where the point is to watch what
happens next, such as letting the one `move_to` after a placed boundary show
whether the new region scopes sensibly. It should be rare and small.

#### 8.6 A stopped run's ceilings were not reached

A case stopped at iteration three trivially satisfies `max_model_tool_calls: 6`,
and reporting that as a pass manufactures a green row from a run that never had
the chance to breach it. So when `end_reason` is a stop, `Expectations.evaluate`
reports every `max_*` rule as `not_reached` rather than `ok`, in the posture it
already takes for an unmeasurable ceiling (`expectations.rb:74-79`: "a ceiling
that cannot be checked is reported as a failure, not quietly passed"). The
verdict comes from the tripwire's `then:`, and the rules that could not be
judged say so.

#### 8.7 The judge has to be told

The rubrics are written about finished runs — `find_bakery_cold` asks that "the
run ends with a named, confirmed region", and `find_mayor_split` reads the whole
navigation journal. A truncated transcript handed to that rubric unannotated
invites the judge to mark down unfinished business the harness caused, so the
judge payload carries the stop label, the tripwire that fired, and which tasks
were staged, with an instruction that behaviour after the stop point is out of
scope. Without it every stopped case reads as a partial failure.

---

### 9. Region facts, because a tripwire has to name the thing

Neither `expect:` nor the tripwires can currently say "a boundary was placed",
which makes §8.3's headline example unwritable. `SessionFacts` already opens the
post-run `knowledge.sqlite3` for `final_room` and `rooms_known`
(`session_facts.rb:151-168`), so most of this is projection of a database it has
open, plus the journal file it does not yet read:

- `regions_known` and `regions_delta` against the start.
- `region_labels`, for `region_named(<label>)` and for asserting that no
  machine-made `⟨from …⟩` label survived the run (`regions.rb:36-40`).
- `region_split_at` — the boundary's room and the edge it used — so a case can
  assert *placement*, which is what `find_mayor_split`'s `undesired_behaviour`
  is actually about.
- `journal_events`, the `move_to` stream by op, joined to the session by
  `session_id`. This gives `region_split_declined` and `region_split_rejected`
  as first-class facts, and a declined split is a correct outcome for a
  large-but-coherent region that there is currently no way to assert.

This is a prerequisite for §8 rather than a companion to it, and all of it reads
data the system already writes.

---

### 10. Alternatives considered

**Stage at `run_task` rather than at `Client#call`.** Simpler to write, and it
would cover the navigator, the cartographer and the judge, which is most of what
we want. Rejected because it cannot stage the player, and run D's value depends
on the player being stageable in runs A through C; a seam that covers three of
four agents guarantees a second seam later.

**Stage at the backend** (`Backends::Anthropic`) rather than the client.
Equivalent in reach and worse in placement, since it would need doing once per
provider and the request digest of §3.5 is most naturally taken from
`to_api_payload`, which the client already holds.

**Reconstruct cassettes from existing session logs**, avoiding a record mode
entirely. Rejected on the evidence in §2: `raw` is debug-gated and the logged
`call_id` is not the API's `tool_use` id, so replayed tool-use blocks would
reference nothing.

**Synthesise the store fixture** from a YAML room graph instead of snapshotting
a real exploration. Deferred rather than rejected. It would let us author region
shapes tbaMUD does not contain and sweep the *shape* itself to find where the
scope judgement's threshold sits, which is a real future question; the snapshot
path costs one run and produces a real map, which is more honest for the cases
we have now.

**Let a failing assert stop the run**, the plan's own opening guess. Answered in
§8.1.

---

### 11. Risks

The largest is that a staged run is only as good as the staging, and it fails
quietly rather than loudly. A staged navigator direction that has fallen off the
candidate list degrades into the arithmetic fallback of `move_to.rb:363-380`
while the case goes on passing; §3.5's digest warning and the journalled
fallback reason are the two places that surfaces, and §12 asserts both.

Staging makes it easy to build a suite that measures its own fixtures. Runs A
through C are diagnostics, not gates, and the plan should keep run D and
`boundaries_gate`'s cold-start cases as the only things a green report is
allowed to mean anything about. §7's report treatment exists to keep that
visible rather than as bookkeeping.

A cassette rots when the prompts change, and the prompts are under active
edit — `settings_digest` exists because a batch of twenty is a measurement of
one configuration and comparing across a prompt edit is the easiest way to draw
a wrong conclusion (`launch.rb:60-89`). A cassette should record the digest that
produced it and warn when replayed under a different one.

`stop_when` interacting with `map_memory: keep` deserves a warning: a case
stopped mid-exploration retains a partial map, and region declarations are
earned and never overwritten, so a stopped arm can hand the next arm a
half-drawn boundary. `warn_about_arms!` (`fixtures.rb:396-406`) is where that
belongs.

---

### 12. Tests

Unit, no model and no MUD:

- A staged task is answered from its queue and never opens a socket; an unstaged
  one is untouched. `Agent#wrap_up` is covered by the staged queue, and a run
  that trips a ceiling with an empty queue fails by name rather than calling out.
- Answers are addressed by `(task, ordinal)`: inserting an extra player
  iteration does not renumber the navigator's answers.
- A staged navigator answer goes through `Reasoners.parse` rather than around
  it, so fenced JSON and unparseable answers behave as they do live.
- A staged player answer carrying a `tool_use` block really dispatches the tool
  (§4), observed through the registry rather than through the transcript.
- `--record` writes one cassette line per model call with the task, the ordinal,
  the request digest and the verbatim body; replaying it reproduces the run's
  tool calls exactly.
- Drift: a changed request warns by default, fails under `on_drift: strict`, and
  a staged direction absent from the candidate list produces the journalled
  fallback.
- Tripwires: `on:` parses through the same `Permissions.parse_rule` path an
  `expect: tool_called` rule does; `count: 3` trips on the third occurrence and
  not the second; a recorded stop makes `max_*` rules report `not_reached`.

Free integration: `--dry-run` prints the resolved stage — which tasks are
staged, which are live, how many answers each holds, and the cassette digest —
so the whole of §3 is reviewable before anything is seeded.

Paid, and the point of the exercise: run A, five times. The number to write down
is not the pass rate but how many of the five produced a boundary the graph
justifies, because that is the observation this plan exists to obtain.

---

### 13. Delivery order

1. **Capture `snapshot:midgaard`** (§5) from one exploration run. Independent of
   every line of code below it, and it makes `find_mayor_split` runnable — which
   may on its own tell us more than expected.
2. **Region facts** (§9). A prerequisite for both the tripwires and any
   deterministic gate on a region case, and useful immediately.
3. **The staging layer** (§2, §3.1–3.3, §6), hand-written answers only, with the
   provenance of §7 in the same change. This is what makes run A possible, and
   run A is the first live cartographer call this system has ever made.
4. **Run A**, then run B. Both are one-call cases; both answer a question no
   amount of further building will.
5. **Cassettes** (§3.4–3.5), once there is something worth replaying. Runs C and
   D are what need them, and neither is worth reaching before A and B report.
6. **`stop_when`** (§8) with `not_reached` in the same change, before run D,
   which is the first case long enough to need it.
7. **The judge annotation** (§8.7), small, and only meaningful once stopped runs
   exist.

Steps 3 and 4 are the short path to the desired result. Everything before them
is a prerequisite that already half exists, and everything after them is
scaffolding for runs we should only pay for once A and B have said something.

---

### 14. Open questions

Should a staged task be allowed to run out and fall back to live, rather than
erroring? Erroring is proposed because a run that silently started paying for
real calls describes a configuration nobody chose, but a `stage.then: live`
per-task escape is conceivable for the case where only the first N calls matter.

Does `--batch N` mean anything against a fully staged run? With one live task it
does — five samples of the cartographer's judgement is exactly what we want —
but with none it is five identical runs, and the harness should probably refuse
that rather than produce a pass rate of 5/5 that describes no variance at all.

Should the cassette live per scenario or per run id? Per scenario reads better
and collides when two people record the same case; per run id never collides and
requires the scenario to name a specific run, which rots differently. Leaning
per scenario, with `--record` refusing to overwrite without `--force`.
