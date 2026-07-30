# Batch session testing

Every command below is runnable **right now**, against the fixtures actually in
this directory. Design doc: `docs/plans/week_3/batch_sesssion_testing.md`.

```
scenario  = goal + starting state + rubric        one file, reusable
plan      = a list of scenarios with overrides    one file, a suite
case      = one execution of a scenario           one session .jsonl
run       = one CLI invocation                    one report .json
```

A case produces a **normal session log** and one copy of the map it ended with,
filed under that same session id (see "Retained session maps" below). A report
is a derivation over those logs plus a judge verdict — which is why
mud_monitor's existing session views work unmodified on a test session.

---

## Which binary

`~/.boukensharc` already points `boukensha_dir` at this repo's `.boukensha`, so
no environment variables are needed from any directory.

```bash
ruby week2_capable/boukensha/bin/boukensha --list-scenarios
```

⚠️ The `boukensha` on your PATH is the **installed gem (0.13.0), whose loader
predates the test flags** — `boukensha -ts …` there falls through to "select a
profile with --profile". Either use the repo path above, or reinstall:

```bash
cd week2_capable/boukensha && gem build boukensha.gemspec && gem install boukensha-0.13.0.gem
```

After that, `boukensha -ts find_bakery` works from anywhere. Everything below is
written with the repo path, which needs no reinstall. Shorthand for the rest of
this file:

```bash
alias bk='ruby ~/Sites/omenking/claude-code-camp-2026-Q2/week2_capable/boukensha/bin/boukensha'
```

---

## What is on disk

| Scenarios | Profile | State | Goal |
|---|---|---|---|
| `find_bakery` | Derrano | `cleric` | Find the bakery and list the menu |
| `withdraw_money` | Derrano | `cleric` | Go to the bank and withdraw 500 gold |
| `find_bakery_cold` | Derrano | `cleric` | Find the bakery, no map at all — Journal A′ |
| `find_hermit_mapped` | Derrano | `cleric` | Find the hermit, town already walked — Journal B′ |
| `find_mayor_split` | Derrano | `cleric` | Find the mayor's office — Journal C′ |

The last three are `boundaries_revised.md`'s three journals, and they are the
measurement §8 asks for. `find_bakery_cold` is the gate: it runs `map_memory:
none` and reproduces the reported failure, and step 1 (frontier visibility) is
supposed to fix it on its own — runnable today.

⚠️ `find_hermit_mapped` and `find_mayor_split` both begin with the town already
walked and so want `snapshot:midgaard`, **which is not on disk**. Capture it
after a real exploration run:

```bash
bk --snapshot-map midgaard --profile Derrano
```

They deliberately do not fall back to `copy:Derrano`: that profile's memory is
currently 13 rooms of the Great Chessboard, which is not a town, and a case that
quietly measures the wrong world is worse than one that refuses to start.

| Plans | Cases |
|---|---|
| `banking` | 11 — `withdraw_money` ×5, `withdraw_money` on `wealthy` ×5, `find_bakery` ×1 as Dummy |

| States | Class | Notes |
|---|---|---|
| `cleric` | cleric | L10, 5000 gold / 10000 bank, club + jacket, Temple (3001) |
| `warrior` | warrior | L10, same money, dagger + jacket, Temple |
| `wealthy` | cleric | L10, 25000 gold / **0 bank** |

Profiles: `Derrano` (cleric), `Dummy` (warrior), `Admin` (warrior).

A state declares `requires_class`, and it is enforced at load time — `cleric`
against `Dummy` fails with a sentence rather than as a telnet refusal twenty
minutes into a batch.

---

## Costs nothing — no MUD, no model, no API key

These are the ones to start with.

```bash
# What exists
bk --list-scenarios
bk --list-plans

# Resolve the full override chain and print it. Seeds nothing, calls nothing.
bk -ts find_bakery --dry-run
bk -tsp banking --dry-run

# Resolving a 20-case override chain wrong otherwise costs 20 real MUD seeds
# and 20 real model runs. This costs zero.
bk -ts find_bakery --batch 20 --dry-run

# Prove the merge does what you think: state file 5000 -> scenario 0 -> CLI 42,
# with `bank` untouched at 10000 because mappings deep-merge.
bk -ts find_bakery --set money.gold=42 --dry-run | grep -A4 '"money"'

# Repeatable; later wins.
bk -ts find_bakery --set money.gold=0 --set level=15 --dry-run

# Watch the guardrail fire — Dummy is a warrior, `cleric` requires a cleric.
bk -ts find_bakery --profile Dummy --dry-run
```

---

## Needs the MUD up + an admin password

`MUD_PASSWORD_ADMIN` and `MUD_PASSWORD_DERRANO` are already in `.boukensha/.env`.
Seeding **deletes and recreates** the character — that is the reset.

```bash
# Seed one character into a named state. No agent, no model.
week2_capable/bin/seed_player --state cleric  --profile Derrano
week2_capable/bin/seed_player --state warrior --profile Dummy
week2_capable/bin/seed_player --state wealthy --profile Derrano

# Re-record the parser fixtures under boukensha/test/fixtures/player.
week2_capable/bin/seed_player --state cleric --profile Derrano --emit-fixtures
```

Placement is asserted, not assumed: after seeding, the admin runs
`at 3001 look` and checks the character is actually listed there.

---

## Map memory — no model, needs sqlite only

The single biggest determinant of behaviour: `find_bakery` against a cold map is
a different task from `find_bakery` against a warm one.

```bash
# Pin a profile's current map as a committed fixture (VACUUM INTO — safe against
# a live WAL-mode DB, even mid-session).
bk --snapshot-map bakery_known --profile Dummy
# -> .boukensha/tests/knowledge/snapshots/bakery_known.sqlite3

# Then run against it.
bk -ts find_bakery --map-memory snapshot:bakery_known --dry-run
```

`--map-memory` accepts:

| Mode | Behaviour |
|---|---|
| `none` | Archive the current DB aside, start empty. **Default for tests.** |
| `keep` | Leave it alone — for "does it get better the second time" |
| `copy:Dummy` | Snapshot another profile's DB into this one |
| `snapshot:bakery_known` | Restore a committed fixture |
| `session:20260729T183933Z-4caca6d5` | Restore the map a previous case ENDED with |

`none` **archives, it does not delete** — the old DB lands in
`profiles/<name>/knowledge.archive/<timestamp>.sqlite3`. Losing a developer's
accumulated map to a mistyped test command is not recoverable.

### Retained session maps

Every case writes the map it ended with to

```
tests/knowledge/sessions/<profile>/<session_id>.sqlite3
```

named after the session that built it, which is the key the session log, the
telnet log, the journal and the report already join on. The **thirty most recent
per profile** are kept and older ones are deleted; that is enough for two
consecutive plan runs, which is the comparison worth making.

A retained map is a candidate fixture, and promotion is how one survives
pruning:

```bash
# The map as it stood at the END of that case, not whatever the profile holds now.
bk --snapshot-map midgaard --profile Derrano --from-session 20260729T183933Z-4caca6d5

# Or start a case from it directly, without promoting anything.
bk -ts find_hermit_mapped --map-memory session:20260729T183933Z-4caca6d5
```

Snapshots live in `tests/knowledge/snapshots/`, are never pruned, and are the
only memory artifact that belongs in git.

Two limits worth knowing before you rely on this. Only **test runs** retain a
map — a REPL session does not go through the case runner, so an exploratory run
by hand still has to be pinned with `--snapshot-map` before the next case
overwrites the profile. And a retained map is the map at session **end**: a case
that died halfway retains a half-built map, which is correct and can still
mislead anyone reading it as the map the agent had at the moment it made the
decision they are investigating. The session log timestamps every discovery, so
that ordering is recoverable — but not from the database alone.

---

## Real runs — MUD up + `ANTHROPIC_API_KEY` + spends money

```bash
# One case, deterministic gate only. No judge, so zero judge cost.
bk -ts find_bakery --no-judge

# The measurement the whole thing exists for: 20 runs of one scenario.
# The agent is stochastic; one run tells you almost nothing.
bk -ts find_bakery --batch 20 --no-judge

# Add the judge (Sonnet judging Haiku, per tasks.judge in settings.yaml).
bk -ts find_bakery --batch 20

# A whole suite. 11 cases as written — check the dry-run first.
bk -tsp banking --no-judge

# Same scenario against a warm map, to see whether memory actually helps.
bk -ts find_bakery --batch 5 --map-memory keep --no-judge

# Broke, on purpose.
bk -ts find_bakery --batch 5 --set money.gold=0 --no-judge

# Write the report somewhere other than tests/reports/.
bk -ts find_bakery --no-judge --report /tmp/one-off.json
```

Exit status is **0 only when every case passed**, so a batch can gate CI without
anyone parsing JSON.

### Full flag list

| Flag | |
|---|---|
| `-ts NAME`, `--test-scenario NAME` | run one scenario |
| `-tsp NAME`, `--test-scenario-plan NAME` | run a plan |
| `--batch N`, `-batch N` | repeat count |
| `--profile NAME` | override the scenario's `player_profile` |
| `--set KEY=VALUE` | state override, repeatable, scalars only |
| `--map-memory MODE` | override `map_memory` |
| `--no-judge` | deterministic gate only, zero judge cost |
| `--dry-run` | resolve and print; seed nothing, call nothing |
| `--report PATH` | write elsewhere than `tests/reports/` |
| `--list-scenarios`, `--list-plans` | |
| `--snapshot-map NAME --profile P` | pin a map as a fixture |
| `--from-session ID` | with `--snapshot-map`: pin a retained session's map instead of the profile's current one |
| `--quiet` | write the run log, echo nothing (CI) |
| `--verbose`, `-v` | fold the seeder's telnet transcript into the run log |

`--profile` is **not** required in test mode: a scenario names its own, and a
plan can name a different one per case.

---

## Watching a run happen

A run is not quiet. Every state change prints as it happens, with the elapsed
time since the run started, and the same lines go to a log file beside the
report:

```
tests/reports/<scenario-or-plan>/<run_id>.log     watch this
tests/reports/<scenario-or-plan>/<run_id>.json    read this afterwards
```

A real `boukensha -ts find_bakery --no-judge`:

```
00:00.0  run    find_bakery — 1 case, profile Derrano, model claude-haiku-4-5
00:00.0  fixture  state cleric, level 10, room 3001, 0 gold, 1 items, 2 equipped
00:00.0  [1/1] start    find_bakery — "Find the bakery and list the menu."
00:00.1  [1/1] map      none — archived 20260728T184144Z.sqlite3 — 0 rooms known — starting cold
00:00.1  [1/1] seed     Derrano ← cleric  (log: …/.work/…/case-1-seed.log)
00:27.8  [1/1] seeded   level 10, 0 gold, placed in room 3001
00:27.8  [1/1] agent    starting (max_iterations 15, wall_timeout 180s)
00:30.7  [1/1] agent    iteration 1 · 0 tool calls
00:32.9  [1/1] agent    iteration 2 · 1 tool call · $0.0028
   …
01:02.3  [1/1] agent    iteration 19 · 18 tool calls · $0.0647
01:24.9  [1/1] done     agent turn finished in 57.1s — closing MUD session and memory
01:25.8  [1/1] exit     child exited cleanly — grading
01:26.1  [1/1] grade    ✗ fail — execute_route (never called); The Bakery (The Great Field Of Midgaard)
01:26.1  run    1 case: 0 passed, 1 failed, 0 errored (0.0%)  agent $0.0734 / judge $0.0000
```

The elapsed column is the point: `00:00.1 → 00:27.8` says **seeding** took 28
seconds, not the model. That is a MUD delete/recreate/uplift over telnet and it
is the floor on how fast a case can go.

The seeder's own telnet transcript is *not* inlined — hundreds of lines of MUD
prose per case would bury the milestones. It goes to its own file, whose path
the `seed` line prints. Use `--verbose` when seeding itself is what's broken.

`--quiet` still writes the log file; it only stops the echo.

---

## Reading the results

Reports land at `tests/reports/<scenario-or-plan>/<run_id>.json`, with the run
log beside them as `<run_id>.log`. `run_id` has the same shape as a session id,
so a directory listing sorts chronologically.

```bash
ls -t .boukensha/tests/reports/**/*.json | head
# Re-read a run you already did
cat .boukensha/tests/reports/find_bakery/<run_id>.log
jq '.summary' .boukensha/tests/reports/find_bakery/*.json | tail -20

# Which expectation actually broke, and how often — twenty logs in one line.
jq '.summary.failure_modes' .boukensha/tests/reports/find_bakery/*.json

# Variance, which is the thing --batch 20 was run to see.
jq '[.cases[].facts.model_tool_calls]' .boukensha/tests/reports/find_bakery/*.json
```

In mud_monitor: **Reports** in the nav. Each case links to its session; each test
session's `test` badge links back to its report. Sessions now filter by
`?mode=test|interactive` and show a name instead of a raw id.

`status` is `pass` | `fail` | **`error`**. An `error` is a broken harness — a
seeding failure, a timeout, a crash — never a failing agent. Conflating the two
is how you spend an afternoon debugging a model that was never called.

---

## Naming a hand-driven session

Not part of the harness, but the same field:

```bash
bk --profile Derrano --session-name "poking at the bakery"
```

and inside the REPL, `/rename find bakery — cold map` at any point (bare
`/rename` prints the current name).

---

## Writing a new scenario

Copy `scenarios/find_bakery.yml`. The two blocks that matter:

**`expect:`** — the deterministic gate. Cheap, non-flaky, evaluated *before* the
judge and free. Everything here is a projection of the session `.jsonl`; nothing
calls a model.

```yaml
expect:
  tool_called:     [plan_route, execute_route, "tbamud__shop(action: list)"]
  tool_not_called: ["tbamud__examine(target: menu)"]
  final_room:      "The Bakery"
  max_model_tool_calls: 6
  max_cost_usd: 0.02
```

Rules use the same `name(arg: value|value)` grammar as `tasks.player.allow` in
`settings.yaml` — a bare name matches through the MCP prefix, so `shop` matches
`tbamud__shop`. Only calls the **model chose** are matchable; hook traffic
cannot satisfy or violate a rule the agent had nothing to do with.

Other keys: `max_automatic_tool_calls`, `max_iterations`, `max_duration_ms`. An
unknown key is a load error, not a silent no-op.

The region keys are projections of the post-run `knowledge.sqlite3` and of the
navigation journal, so they can assert things the judge previously had to read
as prose:

```yaml
expect:
  region_named:  ["Bridge Quarter"]     # the label exists, case-insensitively
  region_split:  true                   # a boundary was declared THIS session
  region_split_at_room: 3014            # and on that room's arrival edge
  no_provisional_regions: true          # no ⟨from …⟩ label survived the run
  journal_op:     [move_to.region_split_declined]
  journal_op_not: [move_to.region_split_rejected]
```

`region_split: false` is as useful as `true`: a large-but-coherent region the
cartographer declined to split is a **correct** outcome, and there was no way to
say so before. `region_split` counts only boundaries this session declared, so a
case running against a `snapshot:` fixture does not report the fixture's
boundaries as its own work.

**`evaluation:`** — everything `expect` cannot express: sequencing, intent, and
whether the reasoning was sane rather than merely lucky. The judge **cannot
overturn tier 1** — it can downgrade a mechanical pass, never rescue a
mechanical fail.

---

## Staging: leaving one model call live

`stage:` answers named tasks from the scenario file instead of from the network,
so a run can leave exactly **one** agent live and measure only that one. It is
what makes an otherwise expensive observation — a region split needs a player
that walked far enough, then a navigator that raised scope, then a cartographer
— cost a single model call.

```yaml
stage:
  because: |                 # required, and prose: a staged run is a claim about
    Run A — the cartographer  # what the other agents would have said, and the
    has never run live.       # claim needs an author.

  player:                    # an agent turn: `text:` and/or `tools:`
    - tools:
        - name: move_to
          args: { destination: "the mayor's office" }
    - text: "That is as far as the walk got."

  navigator:                 # a reasoner: the JSON document its prompt asks for
    - direction: "north"
      reason: "The promenade is the only civic-sounding exit."
      scope_suspect: true

  # cartographer: not listed, therefore LIVE. Anything not named stays live.
```

Answers are consumed **one per call, in order, per task** — never by a global
call sequence, so one extra player iteration does not renumber the navigator's
answers. Running off the end is an error naming the task and the call number,
never a silent fall-through to the network. Size a reasoner's queue to
`tools.navigation.limits.max_decisions`, and remember that a run tripping
`max_iterations` spends one more player answer on `wrap_up`.

A staged `tools:` block really **dispatches the tool** — the character walks,
the store is written, and the model receives a genuine result. That is why this
supersedes prefilling the transcript with fabricated results.

`stage:` is legal only in a **scenario**, never in a plan or a flag — the exact
inverse of the `settings:` rule, and for the same reason: staging changes which
agent was doing the thinking, so it is part of the scenario's identity, and two
incomparable populations must not share one name. It is part of the report's arm
key for the same reason, and a staged run's numbers are **not** baseline
material: `tests/baselines/` is for runs whose cost and call count describe a
journey that was actually taken.

```bash
bk -ts split_the_bridge_quarter --dry-run   # free: prints the resolved stage
```

---

## Known gap

`tbamud__bank` **does not exist**. `MudManager::Primitives#bank` is implemented,
but `mud_manager/lib/mud_manager/mcp/tool_spec.rb` exposes no `bank` entry, so
the tool cannot appear in `tasks.player.allow` and the agent has no way to
withdraw anything.

`withdraw_money` therefore measures only whether the agent gets *itself* to the
bank; its rubric's withdrawal half will fail until the tool is added (~8 lines
in `tool_spec.rb`). Run it with `--no-judge` until then.
