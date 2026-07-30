# Planner

Before the bootcamp started I attempted to implement the outer layer which
had a planner, it failed because of how unoptimal it was running tasks and we
had no observability or test framework.

We have optimized traveling with plan_route and execute_route
We reduce the amount of tools being included.

There are other systems where we wil have savings:
- combat
- exploring (where you have to reason where to go) 
- composite tools eg. optimize_equip .eg you give it a new piece of equipment and it will consider if you should be using it and will equip

The problem is that we have generic `exmaine` and `move`
- examine being called in the bakery instead of just use list to see the menu
- move being called when a plan_route is avaliable

We have things that should make our knowledge better like defing reigons for a exploring but the agent just decides to never call them.

The exmaine problem we on paper defined an affordance of specific rooms by knowing of subactions you could perform.

I dont know if its about creating the prefect trap of hooks and context injection but would a planner make some of these "fixes" redundent?

## Technical Exploration

Note: the code under discussion lives in `week2_capable/`, because weeks 2 and 3
share a folder. Every number below comes from committed session logs and batch
reports in `.boukensha/`, and the file and line references were checked against
the working tree rather than recalled.

### 1. What the agent actually does, from the logs

The most recent batch run is `boundaries_gate` on 2026-07-29
(`.boukensha/tests/reports/boundaries_gate/20260729T182757Z-48647145.json`): ten
cases, zero passed, $0.65 of agent spend, a median of sixteen model tool calls
and sixteen iterations per case. Five of the ten ended on `max_tokens` rather
than on the agent deciding it was finished. That headline is bleak enough to
justify the feeling of running in circles, but the interesting information is one
level down, in what the agent did with the turns it spent.

Session `20260729T182950Z-c79e9b97` is the clearest single case, because it is
one of the runs that *succeeded* at the task and still failed the scenario. Its
complete sequence of model-initiated tool calls was:

```
 1  plan_route(destination: "bakery", scope: "region")   → status "unknown", 5 exits listed
 2  move(south)     7  move(north)
 3  move(south)     8  move(north)
 4  move(south)     9  move(east)
 5  move(west)     10  move(east)
 6  move(west)     11  move(north)
                   12  move(north)
13  shop(action: "list")                                 → the menu
```

Fourteen iterations, 49,819 input tokens, 1,179 output tokens, $0.0557, ending in
The Bakery with the menu listed. The agent understood the task, chose the right
opening move, reasoned its way across Midgaard, and finished. It failed the
scenario on `tool_called: execute_route`, on `max_model_tool_calls: 6`, and on
`max_cost_usd: 0.02`.

Eleven of those thirteen calls were a single `move`. That ratio is the whole
problem in one line, and it is worth being precise about what it costs, because
the per-call usage in that session is unusually legible:

| call | input tokens | output tokens |
|---:|---:|---:|
| 1 | 2,848 | 100 |
| 5 | 3,367 | 86 |
| 9 | 3,642 | 68 |
| 14 | 4,218 | 113 |

The fixed prefix — system prompt plus tool schemas plus the goal — is about
2,848 tokens, and the transcript adds roughly 105 tokens per call on top of it.
Output is 68 to 113 tokens throughout, because the output is almost always a
single tool call naming a single direction. Summed over the turn, 49,819 input
tokens against 1,179 output tokens means **97.6% of the turn's token spend is
re-sending context the model has already seen**, and at Haiku 4.5's $1/$5 per
million rate, 89% of the bill is input. Every additional iteration costs roughly
3,500 input tokens to produce about 85 tokens of decision.

`cache_read_input_tokens` is zero on all fourteen calls, and that is not a
misconfiguration to go fix: Haiku 4.5 will not cache a prefix shorter than 4,096
tokens, and the prefix here is 2,848. The tool-surface reduction that made the
agent cheaper per call is the same change that put the prefix below the cacheable
floor, so shrinking further moves away from caching rather than toward it. This
is the A-versus-B tension `tool_call_opitmize.md` §5.1 flagged, now confirmed
empirically rather than argued.

### 2. Three failure modes, and only one of them is about planning

The ten cases in the batch report separate cleanly into three groups, and
conflating them is what makes the situation look worse than it is.

**The scenario is partly mis-specified.** `find_bakery.yml` sets
`map_memory: none`, so the agent starts with an empty knowledgebase and
`plan_route` can only ever return `unknown` — there is no remembered room to
route to, so there are no steps for `execute_route` to walk. The scenario
nevertheless asserts `tool_called: execute_route` and quotes a concrete path
(`["south","south","west","north"]`) in its rubric, which the agent has no way to
know. Three of the five `find_bakery` cases reached The Bakery and listed the
menu, and all three were marked failed. Separately, one `find_bakery_cold` case
did everything the rubric asked — the judge passed it with the note that
`name_region` was optional — and failed only on the `max_cost_usd: 0.03` gate at
$0.0506. So a meaningful share of the red in that report is the harness, not the
agent, and no planner would change it.

**The agent ignores plans it is given.** In the runs where `plan_route` returned
a usable frontier list, the agent read it, picked a direction, and then walked one
`move` at a time without re-planning. In session `c79e9b97` it never called
`plan_route` again after call 1. In the older `20260728T190719Z-d2fa7ec6` it went
the other way — four `plan_route` calls interleaved with fifteen `move` calls,
re-planning every few steps and getting the same one-line `unknown` answer each
time, before running out of tokens on a chessboard two zones outside Midgaard.
Neither behaviour is a planning failure. In both cases the agent's stated
high-level plan, in its own preamble on iteration 1, was correct and unchanging:
plan a route, walk it, list the menu.

**Exploration has no batching.** This is where the budget actually goes. The
`plan_route`/`execute_route` pair collapses N moves into one iteration *only for
the known case*, when there is a remembered destination and a computed path.
Frontier-following — the case every cold scenario exercises, and the case week
3's remaining goals mostly involve — still costs one full model call per step.

### 3. Four different things get called "a planner"

The word is doing too much work, and the answer to your question depends
entirely on which one is meant.

| Sense | What it is | Status here |
|---|---|---|
| Goal decomposition | An LLM turns "find the bakery" into an ordered list of sub-goals | This is what the pre-bootcamp outer layer was |
| Deterministic search | A solver over a state graph returning a concrete sequence | `RoutePlanner` already is this |
| Durable intent | A persisted object recording the goal, the current step, and what remains | Does not exist |
| Bounded autonomous run | A subsystem that executes until a stop condition and returns control | `execute_route` is this, for one case |

Against the evidence in §1, goal decomposition is the sense that helps least. The
agent's decomposition is already correct in every session examined; adding a model
call that produces the decomposition the agent was going to produce anyway spends
tokens to buy nothing. Deterministic search is built and works. The two that are
not built are the two that would actually change the numbers, and neither of them
is an LLM.

That leads to the sentence this whole exploration turns on:

> **A planner only helps to the degree that its plan is executed by something
> other than the model.** A plan the model reads is a suggestion, and this agent
> has demonstrated across ten cases that it treats suggestions as optional. A plan
> the harness executes is a program, and the model only re-enters at the points
> the program cannot decide.

`execute_route` is exactly that, in miniature, which is why it works when the
agent condescends to call it: `ExecuteRouteTool.call` walks the steps itself,
reconciles each one through `Mud::Hooks#reconcile_move!`, polls between steps, and
returns structured interruption state when `EventClassifier` sees something worth
stopping for. One model call, four MUD round trips. **The planner you want already
exists and works. Its defect is that it is optional.**

### 4. Which of your listed problems a planner makes redundant

Taking the four complaints from the top of this document in turn.

| Problem | Actual cause | Does a planner fix it? |
|---|---|---|
| `examine` in the bakery instead of `list` | The model does not know the room affords `list` | **No.** A planner has the same ignorance. This is affordance data — the `room_affordances` idea in `context_commands.md` — or a situationally advertised tool. |
| `move` when `plan_route` is available | `move` is always advertised, and emitting one direction is cheaper than composing a tool result into a second call | **Only if the plan is executed by the harness.** A planner that produces steps the model may still ignore changes nothing. |
| Region tools never called | Nothing triggers them and nothing costs the agent anything for skipping them | **No.** A planner would have to be told to include a naming step, which is the same prompt engineering wearing a different hat. |
| Exploration burns the budget | One model call per move | **Yes — but only the batching half.** That is `execute_route` generalised to frontier-following, not goal decomposition. |

Three of the four are unaffected by a planner in the goal-decomposition sense,
and the fourth is fixed by something you have already built once. On the specific
question you asked — whether a planner makes the hooks-and-context-injection work
redundant — the answer from the logs is no. The affordance problem and the
region-tool problem are both cases of the model not knowing something, and a
planner does not know it either.

### 5. What a planner does buy that traps cannot

The argument above is not that planning is worthless, only that it is worthless
in the sense you are most likely to reach for first. Three things are genuinely
unavailable today and cannot be hooked or trapped into existence.

**There is nowhere to record "step 3 of 5."** The only representation of intent
in the system is the goal string in the first user message, and `Context` has no
concept of a goal at all — `grep -rn "goal" week2_capable/boukensha/lib/` returns
hits only in the test harness and the launch metadata, never in `Context`,
`Agent`, or `StateBlock`. For a single errand this is fine because the transcript
carries the intent implicitly. For "get strong enough to beat the minotaur",
which is the week's stated end goal, it is not: that task is travel plus fight
plus rest plus re-evaluate, repeated, and there is no object that can hold where
in the loop the agent is. Worth noting as a latent rather than observed problem —
`Context#compact_messages!` drops the oldest 40% of messages, which is where the
goal lives, but with `max_turn_tokens: 60_000` against a 200,000-token window and
a 0.85 compaction threshold, no MUD session has ever reached compaction. It would
bite a long REPL session, not a scenario run.

**Interruption has nowhere to return to.** `execute_route` already returns
`remaining: north → north` when the classifier stops it mid-route, which is the
right shape, but the caller is the model and the remainder survives only as text
in a tool result. A plan object would let a fight interrupt a journey and the
journey resume afterwards without a re-plan.

**A plan is an artifact you can assert against.** This is the quiet one, and it
speaks directly to the mis-specified scenario in §2. Today `find_bakery.yml`
asserts on tool names because tool calls are the only thing the harness can see,
which is why it demands `execute_route` in a world where no route can be known.
If the agent held a plan, the scenario could assert on the plan — that a route
was formed, that it was followed, that it was abandoned for a stated reason —
which is both more robust and closer to what you actually care about.

### 6. Why the pre-bootcamp attempt failed, and what has changed

Your note says the outer layer failed because it ran tasks unoptimally and there
was no observability or test framework. Both of those conditions have changed:
there is now a Jaeger-backed span tree, per-call token and cost attribution in
the session log, and a batch scenario runner with a deterministic gate and an LLM
judge. You would find out within one batch run whether a planner helped, which
you could not before.

The thing that has *not* changed is the economics that made it unoptimal. A
planner that adds a model call per re-plan adds roughly 3,500 input tokens each
time, against a 60,000-token turn budget that five of ten cases already exhaust.
If the planner is an LLM, it needs to remove more iterations than it adds, and
nothing in the current traces suggests goal decomposition would remove any — the
decomposition is already right. The pre-bootcamp failure is likely to reproduce
unless the plan is cheap to make and is executed by code.

### 7. Where the money actually is

If exploration batched at the same granularity `execute_route` already achieves
for known routes, session `c79e9b97`'s eleven single-move calls would collapse to
roughly five — the path it walked was five direction-runs
(`south×3`, `west×3`, `north×2`, `east×2`, `north×1`), so one decision per
frontier chosen rather than one per step. That would make it about eight model
calls instead of fourteen. At the observed prefix and growth rate that is on the
order of 25,000 input tokens rather than 49,819, and roughly $0.028 rather than
$0.056. This is arithmetic on a real trace under an assumed batching policy, not
a measured result, so treat the magnitude as indicative and the direction as
solid: **halving the number of decisions roughly halves the bill, because the bill
is almost entirely the cost of re-sending context to make each decision.**

Note what that projection does *not* need: no goal decomposition, no planner
model, no new memory tables. It needs one subsystem that walks toward a frontier
until something interesting happens, built to the same contract `execute_route`
already satisfies — per-step reconciliation through the hook, event classification
between steps, and structured interruption on the way out.

### 8. Recommendation

Do not build a planner in the goal-decomposition sense. Build the two pieces a
planner would need anyway, in an order where each one pays for itself and is
measurable against the batch harness before the next one starts.

1. **Make exploration a bounded run.** Generalise `execute_route` to frontier
   following, so that choosing a direction to explore and walking it are one
   iteration rather than N. This is the largest measurable win, it reuses the
   contract and the classifier you have already built and tested, and §7 gives it
   a falsifiable target: `find_bakery_cold` under twelve model tool calls and
   under $0.03, which is the gate one case already came within $0.02 of passing.

2. **Add a durable goal, as one line of state.** A `goal:` field on `Context`,
   rendered into the state block, set from the turn's input and carried until it
   changes. It costs about ten tokens per iteration. It is the smallest possible
   plan — a plan of one step — and it gives you the anchor that resumption, fact
   retrieval, and plan-shaped scenario assertions all need later. This is the same
   conclusion `tool_call_opitmize.md` §HN4 reached from a different direction,
   which is mild evidence it is right.

3. **Only then ask whether decomposition is needed**, and ask it against the
   minotaur goal specifically rather than against the bakery. If travel, combat
   and rest each become bounded runs with stop conditions, the outer loop may turn
   out to be three tool calls and a condition check, in which case a planner is a
   `while` loop and not a model.

Two things worth fixing regardless of which way you go, because they are cheap
and they are currently distorting your read of the situation. First, correct
`find_bakery.yml` so its expectations are reachable under `map_memory: none` —
either drop the `execute_route` assertion and the quoted path, or give the case a
snapshot map so a known route exists. Second, decide the caching question from
`tool_call_opitmize.md` §5.1 now that §1 has confirmed the prefix sits at 2,848
tokens against Haiku 4.5's 4,096-token floor; it gates the affordance work, the
situational-tool work, and any per-iteration fact injection, and it will keep
accumulating dependents until it is settled.

### 9. The honest uncertainties

- The §7 projection assumes a batching policy that does not exist yet. The real
  saving depends on how often the classifier interrupts a frontier walk, and there
  is no data on that because nothing has ever walked one.
- The claim that goal decomposition adds nothing rests on sessions that were all
  single-errand navigation tasks. No session has ever been given a goal that
  genuinely needs decomposing, so the evidence is about the tasks run, not about
  decomposition in general. The minotaur goal is the case that would test it.
- Whether hiding `move` during a held route is safe is untested. The machinery
  exists — `compute_turn_policy` builds a policy and `Context#advertised_tools`
  filters on it — but `memory.turn_policy` is `false` in `settings.yaml`, and the
  policy as written only pins directions rather than withholding the tool.


## Moving Challenge
Problem:

user: find the bakery
player: I need to find the bakery, call plan_route('bakery')
plan_route: I didn't find it, here are list of frontiers
player: Ah a bunch of frontiers, I'll just randomly move()
player: Now I'll just move() this way.
player: I'm off path I'll just move()

Propsal:
user: find the bakery
player: move_to('bakery')



Instead of plan_route just returning back possible frontiers, why can't it simply have a
LLM single turn reason step to choose the frontier. This is forcing reasoning to happen,
because it can't just simply reach for move. And that execute_route need a planned_route
first, that way the agent can't just ask to move a single space.  maybe it should just be
move_to("The bakery") an internall it forces plan_route() -> exuecute_plan() or
plan_route() > reason_direction single turn -> exuecute plan. in the latter I guess you could just have it loop until it finds it but you having it reason more deelpy about its movement and could have a task(agent) with its own prompt. 