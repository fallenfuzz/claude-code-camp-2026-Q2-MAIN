## Batch Session Testing

In order to understand how our agent is doing I need to create a test suite against sessions. 

.boukensha/tests
  plans/*.yml # contains files to detailed batching of scenarios
  reports/**/*.json # the results of a run
  scenarios/**/*.yml # indivual scenarios to run against
  states/*.yml # shareble initial states


This will contains indivual files describing a session test case.

## Technical Challenges
- I have a script that will seed a player eg. bin/seed_player this is good, but I need something similar that will load a scenario.

- We need to be able to name a session, maybe it we can make the first inserted jsonl defined how and who ran a session and be able to define a name for a session. we probaly want to add a /rename flag to rename the session when a player is driving the agent directly.

- I want to be able to run scenarios from boukensha command line:
  - boukensha -ts find_baker # run a single scenario
  - boukensha --test-scenario find_baker # run a single scenario
  - boukensha -ts find_baker -batch 20 # run the same scenario 20 times.
  - boukensha --test-scenario-plan banking
  - boukensha -tsp banking
- We need robust overrides I best defined this in examples files
- Map memory data is complex, we need a way to say, start with no map data, or copy an exiting players map memory
- We need to have a new screen in mud monitor to view reports, and they need to link to the respective session
- mud monitor needs to make clear in the list and inside a session view how it was loaded and who was running and show a session name if it has one.
- I dont know what the report should look like.

## Technical Solution

### 0. The shape of the thing

A **case** is one agent session run to completion against a known starting world.
A **run** is one invocation of the test CLI: N cases, one report file.

```
scenario  = goal + starting state + rubric        (one file, reusable)
plan      = a list of scenarios with overrides     (one file, a suite)
case      = one execution of a scenario           (one session .jsonl)
run       = one CLI invocation                    (one report .json)
```

The load-bearing idea is that **a case produces nothing new on disk except a
normal session log**. Everything the harness wants to know about a case is
already written by `Boukensha::Logger` — tool calls with `initiator`,
operation spans with their counters, usage, cost, `end_reason`. The report is a
*derivation* over session logs plus a judge verdict, not a second parallel
telemetry channel. That keeps one source of truth and means mud_monitor's
existing session views work unmodified on a test session.

Three things have to be built to make that true:

1. a session has to say **how and by whom it was started** (§1),
2. the world has to be **put into a known state** before the agent runs (§2–3),
3. the run has to be **driven and evaluated** without a human in the REPL (§4–6).

---

### 1. Session provenance and naming

#### 1.1 The `session_start` contract, extended

`Logger#initialize` already writes a `session_start` line as the first record of
every `.jsonl`, and already takes an arbitrary `snapshot:` hash that gets merged
into it (`week2_capable/boukensha/lib/boukensha/logger.rb:35`). That is the hook —
no new file, no header line, no format change. Today it carries limits and model;
it gains a `launch` object:

```json
{"phase":"session_start",
 "model":"claude-haiku-4-5","provider":"anthropic","max_iterations":25,
 "session_name":"find_bakery #3",
 "launch":{
   "mode":"test",
   "runner":"boukensha-test",
   "profile":"Derrano",
   "scenario":"find_bakery",
   "plan":"banking",
   "run_id":"20260728T143000Z-a1b2c3d4",
   "case_index":3,
   "batch_size":20,
   "state":"cleric",
   "map_memory":"none",
   "goal":"Find the bakery and list the menu.",
   "boukensha_version":"0.13.0",
   "git_sha":"710e23e",
   "settings_digest":"sha256:9f21…"
 }}
```

Field notes, because most of these earn their place by a failure they prevent:

- `mode` — `interactive` | `test`. An interactive session written by a human in
  the TUI gets `{"mode":"interactive","runner":"human","profile":"Dummy"}` and
  nothing else. **This is the field the monitor lists on**: today a hand-driven
  exploration and an automated case are indistinguishable in `Sessions.tsx`, and
  the moment batch runs exist the session list is 95% robot.
- `settings_digest` — SHA-256 over the resolved `settings.yaml` plus the
  `prompts/player/system.md` actually used. A batch of 20 is a measurement of one
  configuration; comparing runs across a prompt edit is the single easiest way to
  draw a wrong conclusion, and this is what lets the report refuse to aggregate
  two different digests into one number.
- `git_sha` — best-effort `git rev-parse --short HEAD`, nil outside a repo.
- `goal` — the scenario's goal text, recorded at start. `SessionSerializer`
  already surfaces `task` (the first user message), but that is only knowable
  after parsing the transcript; a case that dies before its first turn still has
  to say what it was trying to do.

Everything is additive and optional. A log written before this exists parses
exactly as it does now, with `launch` absent — which the monitor reads as
"legacy / unknown provenance", the same pattern `has_provenance?` and
`has_operations?` already use in `SessionSerializer`.

#### 1.2 Naming, and renaming

A name is mutable, and the log is append-only. So the name is not stored once —
it is the **last** `session_name` seen in the file:

```ruby
# Logger
def rename(name:, source: "user")
  write_log(phase: "session_rename", session_name: name.to_s, source: source)
end
```

`SessionLog::Parser` folds `session_start.session_name` and every later
`session_rename` into a single `name` attribute, last-one-wins, and exposes it on
the summary. A crashed rename cannot corrupt an earlier one, and the rename is
itself timestamped history — which is worth having, since "I renamed this after
I saw what happened" is a real annotation.

Three ways to set it:

| Source | Mechanism |
|---|---|
| Human, mid-session | `/rename find bakery — cold map` in the REPL |
| Human, at launch | `boukensha --session-name "cold map"` |
| Test harness | scenario's `session_name`, suffixed `#N` in a batch |

`/rename` goes into `Repl#handle_command` next to `/clear`
(`week2_capable/boukensha/lib/boukensha/repl.rb:90`), plus a line in `HELP` and
the banner:

```ruby
when %r{\A/rename\s+(.+)\z}
  name = Regexp.last_match(1).strip
  @logger.rename(name: name, source: "user")
  output("(session renamed to #{name.inspect})")
  :command
```

Bare `/rename` with no argument prints the current name rather than erroring.

---

### 2. Fixture files

Location is as specified: `<boukensha_dir>/tests/`. Note this is the **root**
config dir, not the profile dir — scenarios and states are shared across
profiles, and a scenario names the profile it wants. `Config` gains:

```ruby
def tests_dir = File.join(@root_dir, "tests")
```

#### 2.1 `states/*.yml` — a shareable initial world

The existing `states/cleric.yml` is the right idea with four typos and one
structural problem. Corrected schema:

```yaml
# .boukensha/tests/states/cleric.yml
#
# A complete character reset. The seeder DELETES and RECREATES the character
# (mud_manager/lib/mud_manager/character_seeder.rb), so this file is the whole
# truth about the player — there is no "leftover from the last run" to reason
# about. That is why there is no `purge` primitive: recreation is the reset.

description: "Level 10 cleric, banked, armed, standing in the Temple."

# Guardrail, not configuration. The seeder's own comment warns that a dagger is
# rejected by class restrictions; a cleric state applied to a warrior profile
# fails as a refusal deep inside a telnet exchange. Declared here, it fails at
# load time with a sentence instead.
requires_class: cleric

location: 3001          # room vnum. `at <vnum> transfer <player>` — see §3.2.

level: 10
money:
  gold: 5000
  bank: 10000
stats:
  align: 0

# MUD spellings, not YAML-ish ones. These strings are passed verbatim to
# `skillset` — "cure light" is two words in tbaMUD and `cure_light` is a typo
# that costs you a run. Quote them.
skills:
  "armor": 75
  "cure light": 75

inventory:
  - vnum: 3001
    keyword: bottle
    quantity: 2

equipment:
  - vnum: 3023
    keyword: club
    quantity: 1
    wear: wield
  - vnum: 3043
    keyword: jacket
    quantity: 1
    wear: wear
```

Changes from the file on disk: the `intital_state:` root key is dropped (the file
*is* the state); `keyboard:` → `keyword:`; `qauntity:` → `quantity:`; `amor` →
`"armor"`; `cure_light` → `"cure light"`; `location: 1` becomes a real room vnum.

Deliberately **not** here: `gender` and `class`. Those moved to `profile.yaml`
in `a68ecd2` and `Config#player_identity` is now their only reader. A state file
that sets them is a load-time error, not a silent second opinion.

#### 2.2 `scenarios/**/*.yml` — one test case

```yaml
# .boukensha/tests/scenarios/find_bakery.yml
session_name: find_bakery
player_profile: Derrano        # supplies name/password/gender/class
goal: "Find the bakery and list the menu."

base_initial_state: cleric     # states/cleric.yml
initial_state_overrides:
  money:
    gold: 0

map_memory: none               # none | keep | copy:<profile> | snapshot:<name>

limits:                        # per-case ceilings; override settings.yaml
  max_iterations: 15
  max_turn_tokens: 40000
  wall_timeout_s: 180

# ── Deterministic gate ────────────────────────────────────────────────
# Cheap, non-flaky, and evaluated BEFORE the judge. Everything here is a
# projection of the session .jsonl; nothing calls a model.
expect:
  tool_called:     [plan_route, execute_route, "tbamud__shop(action: list)"]
  tool_not_called: ["tbamud__examine(target: menu)"]
  final_room:      "The Bakery"      # from knowledge.sqlite3 player_state
  max_model_tool_calls: 6
  max_cost_usd: 0.02

# ── Judge ─────────────────────────────────────────────────────────────
# Everything `expect` cannot express: sequencing, intent, and whether the
# reasoning was sane rather than merely lucky.
evaluation:
  desired_behaviour: |
    The agent should plan a route:
    plan_route(destination: "bakery")
    The agent should execute the route:
    execute_route(steps: ["south","south","west","north"])
    When the agent arrives they should call list and see the menu:
    tbamud__shop(action: "list", args: "")
  undesired_behaviour: |
    The agent should not reason to call examine on the menu:
    tbamud__examine(target: "menu")
    The agent should not reason to call examine on the baker to see the menu:
    tbamud__examine(target: "baker")
```

`tool_called` entries use the same `name(arg: value|value)` grammar that
`tasks.player.allow` already uses in `settings.yaml`, parsed by the existing
`Permissions` rule parser. One grammar for "which calls do I mean", not two.

#### 2.3 `plans/*.yml` — a batched suite

The file on disk is a YAML sequence with a syntax error (`override_intial_state`
has no `:`). Corrected, and given a header so a plan can carry defaults:

```yaml
# .boukensha/tests/plans/banking.yml
name: banking
description: "Everything the agent has to get right around money."

defaults:                    # applied to every case below
  player_profile: Derrano
  map_memory: none

cases:
  - scenario: withdraw_money
    batch: 5
    session_name: withdraw_money

  - scenario: withdraw_money
    batch: 5
    session_name: withdraw_money (rich, cold map)
    base_initial_state: wealthy        # REPLACES the scenario's state file
    initial_state_overrides:           # deep-merged on top of it
      money: { gold: 0 }

  - scenario: find_bakery
    batch: 1
    player_profile: Dummy              # overrides the plan default
```

#### 2.4 Override precedence — the actually hard part

Four layers, later wins:

```
1. states/<base_initial_state>.yml          the file
2. scenario.initial_state_overrides         deep merge
3. plan case (base_initial_state replaces the file;
              initial_state_overrides deep-merges last)
4. CLI  --set money.gold=0                  deep merge, scalars only
```

Merge rules, stated once so nobody has to guess:

- **Mappings deep-merge.** `money: {gold: 0}` over `money: {gold: 5000, bank: 10000}`
  yields `{gold: 0, bank: 10000}`.
- **Sequences replace.** `inventory:` in an override wipes the base list. This is
  the only rule that is a judgement call, and it goes this way because
  "replace" is the one you can always express in terms of the other and it has no
  ordering ambiguity.
- **Append forms exist for when you meant append**: `inventory+:` and
  `equipment+:` concatenate onto the base instead of replacing it.
- **`null` deletes a key** (`bank: ~` removes the bank field entirely — different
  from `bank: 0`, which sets it to zero).
- **`base_initial_state` is not merged, it is chosen.** Naming a different state
  file at any layer discards the previous file wholesale; only
  `initial_state_overrides` accumulate.

The merged state is resolved once, before anything touches the MUD, and the
**fully-resolved state is written into the report** (§6). A batch whose report
does not contain the exact state each case ran against is not evidence.

---

### 3. Loading a state (the `seed_player` sibling)

#### 3.1 Extract the script into a library

`week2_capable/bin/seed_player` is a good mechanism trapped in a bad container:
`HOST`, `PORT`, `PLAYER_NAME`, `PLAYER_CLASS` and the whole `UPLIFT` hash are
frozen top-level constants you edit by hand. `MudManager::CharacterSeeder`
underneath it is already fully config-driven and needs no changes.

So: everything above `MudManager::CharacterSeeder.new(config).run` becomes
`Boukensha::Testing::StateLoader`, which builds the same config hash from
(state file + profile + settings) instead of from constants:

```ruby
Boukensha::Testing::StateLoader.new(
  state:   resolved_state_hash,     # §2.4 output
  profile: cfg.profile,             # name, password_env, gender, class
  mud:     cfg.mcp_servers["mud"][:env]   # host/port — one source of truth
).apply!
```

`bin/seed_player` stays, reduced to a thin shim that loads a named state file, so
the existing developer workflow (`bin/seed_player --emit-fixtures`) keeps working:

```
bin/seed_player --state cleric --profile Derrano [--emit-fixtures]
```

Host and port stop being duplicated constants and come from the `mud:` MCP server
block in `settings.yaml`, which is already the only place they are configured for
the agent itself.

#### 3.2 `location:` needs one more seeder step

`CharacterSeeder#apply_uplift` handles level, money, stats, skills, inventory and
equipment, but nothing places the character. `MudManager::Primitives` already has
what is needed, so this is one line in the uplift sequence, at the end:

```ruby
place_player(admin, uplift[:location]) if uplift[:location]
```

`validate_uplift!` gains `location` as an optional positive integer.

> **RESOLVED — it is `teleport`, not `transfer`.** The MUD's own help file
> settles it (`week0_explore/infrastructure/lib/text/help/help.hlp`, entry
> "GOTO TRANSFER TRANSPORT TELEPORT"):
>
> ```
> trans [target]                 pulls target to the room YOU are in
> teleport [target] <location>   sends target to a room vnum
> ```
>
> `trans` takes **no destination at all**, so `transfer <player> <vnum>` would
> have been parsed as something else entirely. Worse, this step runs after
> `goto <player>` has already moved the immortal to the player, so a bare
> `trans` would have "succeeded" by leaving the character exactly where it
> already was — a silent no-op that looks like placement. The shipped call is
> `Primitives.teleport(player_name, vnum)`.

Every case ends with a **placement assertion**: after seeding, read the player's
room back off the MUD. Silent placement failure means every case in the batch
starts somewhere unintended and the whole run is garbage that looks like data.

The assertion is `at <vnum> look` issued by the admin (help.hlp, "WIZAT AT" —
runs a command in another room without moving the immortal), checking the
player's own name appears among the characters listed there. That is a direct
assertion of "is standing in this room" with no vnum→name table to keep in sync.

---

### 4. Map memory

The agent's world knowledge is `<profile_dir>/knowledge.sqlite3`
(`Mud::Memory::Store::FILENAME`). It is the single biggest determinant of
behaviour — `find_bakery` is a different task against a cold map than a warm one —
and it is exactly the thing you cannot express in a YAML state file.

So it is a mode, not a document. `map_memory:` accepts:

| Value | Behaviour |
|---|---|
| `none` | Archive the current DB aside, start from an empty schema. **Default for tests.** |
| `keep` | Leave it alone. For "does it get better the second time" scenarios. |
| `copy:<profile>` | Snapshot another profile's DB into this one. The "start from what Dummy knows" case. |
| `snapshot:<name>` | Restore from `tests/states/maps/<name>.sqlite3`, a committed fixture. |

Implementation notes that matter more than the mode list:

- **Copy with `VACUUM INTO`, never `cp`.** The repo currently has
  `knowledge.sqlite3-wal` and `knowledge.sqlite3-shm` sitting untracked next to
  the DB — a file copy of a WAL-mode database mid-session copies a torn state,
  and it will do it silently. `VACUUM INTO '<dest>'` produces one consistent
  file with no sidecars.
- **`none` archives, it does not delete.** Move the existing DB to
  `<profile_dir>/knowledge.archive/<timestamp>.sqlite3` and let a fresh
  `Store.for_dir` run `Schema.migrate!` into a new one. Deleting a developer's
  accumulated map because they typed a test command is not recoverable, and this
  command *will* get run against `Dummy` by accident.
- **The snapshot fixture is created by the harness, not by hand**:
  `boukensha --snapshot-map bakery_known` does the `VACUUM INTO` into
  `tests/states/maps/`. These are binary files in git; they are small (tens of
  KB) and they are the only honest way to pin "the map as of the run that
  produced this result".
- The resolved map mode and the **row counts at start** (`rooms`, `room_exits`,
  `entities`) go into the report. "Cold map" is a claim; `rooms: 0` is a fact.

---

### 5. The runner

#### 5.1 CLI surface

Argument parsing lives in `BoukenshaLoader`, which already owns
`--profile`/`--list-profiles`/`--no-tui` before anything is required
(`lib/boukensha_loader.rb`). It gains a test branch:

```
boukensha -ts find_bakery                  # one case
boukensha --test-scenario find_bakery
boukensha -ts find_bakery --batch 20       # same scenario, 20 times
boukensha -tsp banking                     # a plan
boukensha --test-scenario-plan banking

  --batch N              repeat count (also accepted as -batch, as written in the brief)
  --profile NAME         override the scenario's player_profile
  --set KEY=VALUE        state override, repeatable (money.gold=0)
  --map-memory MODE      override map_memory
  --no-judge             deterministic `expect` gate only, zero judge cost
  --dry-run              resolve + print the plan, seed nothing, call nothing
  --quiet                write the run log, echo nothing (§5.4)
  --verbose              fold the seeder's telnet transcript into the run log
  --report PATH          write elsewhere than tests/reports/
  --list-scenarios       mirrors --list-profiles
  --list-plans
```

`--profile` stops being mandatory in test mode: the scenario names its own, and a
plan can name a different one per case. `--dry-run` is not a nicety — resolving a
20-case override chain wrong costs 20 real MUD seeds and 20 real model runs, and
this prints the merged state for every case for free.

#### 5.2 One process per case

Each case runs in its **own child process** (`Process.spawn` of the same binary
in an internal `--test-case <json>` mode), serially. Three reasons, all learned
from what is in this codebase:

1. `Mud::Memory::Store` is opened once per process and torn down by `at_exit`;
   the MCP `mud` server is a spawned daemon holding one telnet login. Resetting
   both in-process is a pile of lifecycle code that exists to save a fork.
2. A case that raises, hangs, or takes the MUD connection down with it must cost
   one case, not the remaining nineteen. The parent enforces `wall_timeout_s`
   and records `error`/`timeout` as a *result*, not as a crash.
3. Serial is not a performance compromise, it is a correctness requirement:
   **one player profile is one telnet login**, and two cases logged in as
   `Derrano` at once is the "already in use / Reconnecting" path
   `CharacterSeeder` has to work around. Parallelism is available only across
   distinct profiles, which a plan can express by assigning `player_profile` per
   case — noted as future work, not built now.

Per case the child: resolves state → seeds (§3) → prepares map memory (§4) →
runs the agent → exits. The parent collects `{session_id, path, exit_status}`.

#### 5.3 Running the agent headless

`Boukensha.run(task:)` already does exactly what a case needs — one goal, run to
completion, no REPL. The obstacle is that all the MUD wiring (the `plan_route`
and `execute_route` tools, `Mud::Hooks`, the store, the journal, the ONNX
extractor) lives inline in the block passed to `Boukensha.repl` in
`boukensha_loader.rb`, so `Boukensha.run` today would produce an agent with no
hooks and no navigation tools.

Both `.run` and `.repl` already accept `&block`. So the fix is a pure extraction,
no behaviour change:

```ruby
# BoukenshaLoader
def self.mud_agent_setup           # returns the proc currently inline
  proc do
    parent = logger
    cfg    = Boukensha.config
    # …exactly the body that is inline in load_and_start_repl today…
  end
end

def self.load_and_start_repl
  # …
  Boukensha.repl(tui: !no_tui, &mud_agent_setup)
end

def self.run_case(goal:, limits:)
  Boukensha.run(task: goal, max_output_tokens: limits[:max_output_tokens],
                &mud_agent_setup)
end
```

This is the one place the test harness reaches into production code, and it
reaches in by *sharing* the setup rather than reimplementing it — which is the
only version where a test session is genuinely the same agent as a real one.

`session_name` and `launch` reach the logger through the existing `snapshot:`
parameter of `Logger.new`, threaded from `Boukensha.run`/`.repl` as one new
optional `launch:` keyword.

#### 5.4 The run log — what is it doing right now

> Added after the first live run. `boukensha -ts find_bakery` printed nothing
> for 50 seconds and then one summary line. A single case deletes and recreates
> a character over telnet, archives a SQLite database, spawns an MCP daemon,
> logs into the MUD, and runs an agent for a dozen iterations — and every one of
> those can be the slow one. Silence makes them indistinguishable from a hang.

The session `.jsonl` is the record of what the **agent** did. It says nothing
about what the **harness** did, and it does not exist yet during the part of a
case that most often goes wrong — fixture resolution, seeding, map preparation.
So the harness gets its own log, and it is a different kind of artifact from
everything else here: the report is for reading afterwards, the run log is for
watching *now*.

```
tests/reports/<scenario-or-plan>/<run_id>.log     the run log
tests/reports/<scenario-or-plan>/<run_id>.json    the report
```

Same directory, same stem, so a run's evidence sits together and one `ls` shows
both. The log is written **line at a time, flushed, and simultaneously echoed to
stdout** — the file is for the run you already did, the echo is for the one you
are staring at.

##### What it emits

Milestones, not narration. One line per state change, each carrying the elapsed
time *since the run started* and the case it belongs to:

```
00:00.0  run    find_bakery — 1 case, profile Derrano, model claude-haiku-4-5
00:00.0  fixture  state cleric (level 10, room 3001, 2 items, 2 equipped)
00:00.1  [1/1] start   find_bakery — "Find the bakery and list the menu."
00:00.1  [1/1] map     none — archived 13 rooms, starting cold
00:00.3  [1/1] seed    Derrano ← cleric  (log: …/20260728T182102Z-d237fdcc-case-1-seed.log)
00:12.7  [1/1] seeded  level 10, 0 gold, placed in room 3001
00:12.7  [1/1] agent   starting (max_iterations 15, wall_timeout 180s)
00:19.4  [1/1] agent   iteration 3 · 5 tool calls · $0.0121
01:02.6  [1/1] done    max_tokens · 19 calls · 49.9s · $0.0745
01:02.8  [1/1] grade   fail — execute_route never called, final_room "A White Square"
01:03.1  run    1 case: 0 passed, 1 failed, 0 errored · $0.0745
```

Three decisions in that sample worth stating outright:

- **Elapsed time is on every line**, not wall-clock. The question the log
  answers is "what is taking so long", and `00:12.7 → 01:02.6` says *the agent*,
  not the seeder, without any arithmetic.
- **The seeder's telnet transcript does NOT go here.** It is hundreds of lines
  per case of MUD prose, and inlining it would bury the milestones under exactly
  the noise the run log exists to cut through. It keeps its own per-case file,
  and the run log prints that file's path — which is the useful half.
- **Heartbeats during the agent turn.** The longest single stretch is the agent
  running, and it is the one stretch that can legitimately take a minute. A line
  per iteration with a running cost turns "hung" into "on iteration 3 of 15".

##### Where it is written from

Both halves of §5.2 write to the same file. The parent opens it; each child is
handed its path in the case payload and appends. Appends are `O_APPEND` and
line-sized, so interleaving is safe, and a child that dies mid-case leaves its
last completed milestone on disk — which is precisely the line that says what it
died doing.

The child also **stops swallowing its own stdout**. Today a child's milestones
would sit in a block buffer and be lost on SIGKILL at the wall timeout; `sync =
true` on the child's handle is what makes a timeout diagnosable rather than
simply blank.

##### Flags

| Flag | |
|---|---|
| `--quiet` | write the log file, echo nothing — for CI, where the report is the artifact |
| `--verbose` | fold the seeder's telnet transcript into the run log inline |

Neither changes what lands in the file by default. `--verbose` is for the case
where seeding itself is what is broken, which is the one time the transcript is
the thing you want.

---

### 6. Evaluation and the report

> This section answers "I dont know what the report should look like."

#### 6.1 Two tiers, in this order

**Tier 1 — deterministic facts.** A pure function of the session `.jsonl` plus
the post-run `knowledge.sqlite3`. No model, no cost, no variance. This is where
`expect:` is evaluated, and it is why `expect:` exists at all: the interesting
regressions ("it called `examine` on the menu again", "it took 14 tool calls
instead of 6") are all mechanically detectable, and a model should never be asked
to judge something a `grep` can decide.

`Boukensha::Testing::SessionFacts` reads the log the harness just wrote and
projects:

```ruby
{ tool_calls: [{name:, args:, initiator:, ok:, duration_ms:}, …],
  model_tool_calls: 6, automatic_tool_calls: 12,
  iterations: 4, turns: 1, end_reason: "stop",
  input_tokens:, output_tokens:, cost_usd:,
  mud_calls:, mud_ms:, db_reads:, db_writes:,   # from operation_end counters
  final_room:, rooms_known_delta:,               # from knowledge.sqlite3
  errors: [...] }                                # from error.log, by session_id
```

Every one of these fields already exists in the log today — `mud_calls`,
`db_writes` and friends come straight off `operation_end`, and the
`initiator: "model" | "hook"` split is what makes `max_model_tool_calls` a
meaningful budget instead of a count of framework chatter. **No new
instrumentation is required for tier 1.** That is the payoff for
`work_attribution.md` and `observ_improvements.md` having already landed.

**Tier 2 — the judge.** A new `Boukensha::Tasks::Judge` (subclass of `Tasks::Base`,
task name `judge`, configured under `tasks.judge` in `settings.yaml` like every
other task, with `prompts/judge/system.md`). Run via the existing
`Boukensha.run_task(Tasks::Judge, input, log: <report_dir>/judge/<case>.jsonl)`,
so a judge call is itself a session log you can open in mud_monitor when you
distrust a verdict.

The judge is given a **trace digest, not the transcript**: the ordered
`initiator: "model"` tool calls with args and truncated results, the assistant's
text turns, and the final answer — a few hundred tokens, not the tens of
thousands the raw log holds. Hook traffic is excluded; the rubric is written
about what the agent *chose*, and the framework's bootstrap `score`/`look` is
noise that reliably confuses a judge into penalising the agent for calls it did
not make.

It is asked for strict JSON, no prose:

```json
{"verdict":"pass",
 "desired":  [{"behaviour":"plan_route(destination: \"bakery\")","met":true,"evidence":"call_3e9f40b9"}],
 "undesired":[{"behaviour":"examine(target: \"menu\")","occurred":false}],
 "reasoning":"Planned once, executed the route in a single call, listed on arrival.",
 "confidence":0.9}
```

Rules the harness enforces around it:

- **The judge cannot overturn tier 1.** A case failing a hard `expect` is
  `fail`, whatever the judge says. The judge can only downgrade a mechanical
  pass, never rescue a mechanical fail.
- **Cost is attributed.** Judge tokens are reported separately from agent tokens;
  a 20-case batch that spends more on judging than on playing is a design
  problem you should be able to see.
- `--no-judge` runs tier 1 alone. Fast, free, and enough for most regressions.

#### 6.2 Report format

One JSON file per **run**, at
`tests/reports/<scenario-or-plan>/<run_id>.json`, matching the specified
`reports/**/*.json` glob. `run_id` is `%Y%m%dT%H%M%SZ-<hex8>` — same shape as a
session id, so it sorts chronologically by filename exactly as `SessionLog::Store`
relies on.

```json
{
  "schema": 1,
  "run_id": "20260728T143000Z-a1b2c3d4",
  "kind": "plan",
  "name": "banking",
  "started_at": "2026-07-28T14:30:00.000Z",
  "ended_at":   "2026-07-28T14:52:11.000Z",
  "environment": {
    "profile": "Derrano",
    "provider": "anthropic",
    "model": "claude-haiku-4-5",
    "boukensha_version": "0.13.0",
    "git_sha": "710e23e",
    "settings_digest": "sha256:9f21…",
    "judge": {"provider": "anthropic", "model": "claude-sonnet-5"}
  },
  "summary": {
    "cases": 20, "passed": 17, "failed": 2, "errored": 1,
    "pass_rate": 0.85,
    "cost_usd": {"agent": 0.31, "judge": 0.08, "total": 0.39},
    "median": {"model_tool_calls": 6, "iterations": 4, "duration_ms": 11400, "cost_usd": 0.015},
    "p90":    {"model_tool_calls": 9, "iterations": 7, "duration_ms": 19200},
    "failure_modes": {"examined_the_menu": 2, "timeout": 1}
  },
  "cases": [
    {
      "index": 3,
      "scenario": "find_bakery",
      "session_id": "20260728T143241Z-fef86633",
      "session_name": "find_bakery #3",
      "profile": "Derrano",
      "status": "fail",
      "resolved_state": { "level": 10, "money": {"gold": 0, "bank": 10000}, "…": "…" },
      "map_memory": {"mode": "none", "rooms_at_start": 0, "rooms_at_end": 9},
      "facts": {
        "model_tool_calls": 8, "automatic_tool_calls": 14, "iterations": 6,
        "duration_ms": 14300, "input_tokens": 9204, "output_tokens": 412,
        "cost_usd": 0.0161, "mud_calls": 22, "mud_ms": 3100,
        "end_reason": "stop", "final_room": "Main Street"
      },
      "expectations": [
        {"kind": "tool_called", "rule": "plan_route", "ok": true},
        {"kind": "tool_not_called", "rule": "tbamud__examine(target: menu)", "ok": false,
         "detail": "called at call_9d30592e9a51"},
        {"kind": "final_room", "rule": "The Bakery", "ok": false, "detail": "Main Street"}
      ],
      "judge": {
        "verdict": "fail", "confidence": 0.9,
        "reasoning": "Planned the route but abandoned it after an interrupting event and examined the menu instead.",
        "session_id": "20260728T143255Z-11ff0a2c"
      }
    }
  ]
}
```

Design choices worth defending:

- **`cases[].session_id` is the join key.** The report links to sessions; it does
  not duplicate them. Everything the report shows per case is either a fact
  derived from that session or a judgement about it, and the monitor's report
  screen is one click from the full transcript.
- **`resolved_state` is embedded, not referenced.** State files change. A report
  that says `base_initial_state: cleric` is worthless six weeks later; one that
  says `gold: 0, level: 10` still means something.
- **Distributions, not just a mean.** The whole point of `--batch 20` is that the
  agent is stochastic. `median`/`p90` on tool calls and cost is what turns
  "it usually works" into a number, and `failure_modes` — clustered by which
  expectation failed — is what turns twenty logs into one sentence.
- **`status` is `pass` | `fail` | `error`.** `error` (seeding failed, timeout,
  crash) is not `fail`. Conflating a broken harness with a failing agent is how
  you spend an afternoon debugging a model that was never called.

---

### 7. mud_monitor

#### 7.1 Provenance in the session views

`SessionSerializer#summary` gains `name`, and `launch` (or `null`):

```ruby
name:   p.name,        # last session_rename, else session_start.session_name
launch: p.launch,      # nil on legacy logs
```

- **`Sessions.tsx` list** — a new leading column showing mode. A `TaskChip`-style
  badge: `human` for interactive, `test` for a case (linking to its report),
  `—` for legacy. The session name renders as the primary label where the raw id
  is today, with the id demoted to a monospace subtitle; a list of
  `20260728T143241Z-fef86633` is unreadable at twenty rows, and this is the
  whole reason naming exists.
- Filters: `?mode=test|interactive`, `?profile=`, `?scenario=`. Client-side over
  the existing `/sessions` payload — no new endpoint.
- **`SessionDetail.tsx`** — a provenance strip under the header: who ran it, from
  what scenario, at which git sha and settings digest, with the state and map
  mode it started from, and a back-link to the report. Two sessions that
  disagree are usually two different configurations, and this is where you find
  that out.

#### 7.2 The reports screen

API (`api/config/routes.rb`, inside `namespace :api/:v1`):

```ruby
resources :reports, only: %i[index show]
```

- `ReportStore` — glob `tests/reports/**/*.json`, newest-first by filename,
  same `path_for` realpath containment check `SessionLog::Store` uses. Note the
  dir resolves off the boukensha **root**, not the profile dir, since fixtures
  and reports are shared; `index` accepts `?profile=` to filter.
- `ReportSerializer` — summary (id, kind, name, times, counts, pass rate, cost)
  for `index`; the full document for `show`.
- No SSE. A report is written once when the run finishes; there is no cursor to
  follow. This is the `knowledge` precedent, not the `journal` one — and the
  existing comment in `routes.rb` already draws that distinction, so it stays
  consistent.

Web (`App.tsx`):

```jsx
<Route path="reports" element={<Reports />} />
<Route path="reports/:id" element={<ReportDetail />} />
```

- **`Reports.tsx`** — run list: when, scenario/plan, profile, model, pass rate as
  a bar, cases, total cost. Runs with a differing `settings_digest` are visually
  separated, because a table that silently interleaves two configurations invites
  exactly the wrong comparison.
- **`ReportDetail.tsx`** — the header block (environment + summary + failure-mode
  breakdown), then a case table: index, status, session name → `/sessions/:id`,
  tool calls, duration, cost, and which expectations failed. Expanding a row
  shows the resolved state, the expectation list, and the judge's reasoning with
  a link to the judge's own session.
- A sparkline of per-case `model_tool_calls` across the batch, reusing
  `components/Sparkline.tsx`. Variance is the measurement; a single number hides it.

---

### 8. Code layout

```
week2_capable/boukensha/lib/boukensha/
  testing/
    cli.rb              # arg parsing, --list-*, --dry-run
    fixtures.rb         # load + validate states/scenarios/plans
    overrides.rb        # the §2.4 merge (deep merge, +, null-deletes)
    state_loader.rb     # resolved state -> MudManager::CharacterSeeder
    map_memory.rb       # none | keep | copy | snapshot; VACUUM INTO
    run_log.rb          # §5.4 milestones, tee'd to stdout and <run_id>.log
    runner.rb           # per-case child process, timeout, collection
    session_facts.rb    # .jsonl + knowledge.sqlite3 -> tier-1 facts
    expectations.rb     # `expect:` rules -> pass/fail with evidence
    judge.rb            # trace digest -> Tasks::Judge -> verdict
    report.rb           # assemble + write the run JSON
  tasks/judge.rb
  prompts/judge/system.md

week2_capable/boukensha/lib/boukensha/logger.rb   # +#rename, launch in snapshot
week2_capable/boukensha/lib/boukensha/repl.rb     # +/rename
week2_capable/boukensha/lib/boukensha_loader.rb   # +mud_agent_setup, test branch
week2_capable/boukensha/lib/boukensha.rb          # +launch: on .run/.repl
week2_capable/boukensha/lib/boukensha/config.rb   # +tests_dir

week2_capable/mud_manager/lib/mud_manager/character_seeder.rb  # +location
week2_capable/bin/seed_player                                  # -> thin shim

week2_capable/mud_monitor/api/lib/report/store.rb
week2_capable/mud_monitor/api/app/controllers/api/v1/reports_controller.rb
week2_capable/mud_monitor/api/app/serializers/report_serializer.rb
week2_capable/mud_monitor/api/lib/session_log/parser.rb         # +name, +launch
week2_capable/mud_monitor/api/app/serializers/session_serializer.rb
week2_capable/mud_monitor/web/src/pages/Reports.tsx
week2_capable/mud_monitor/web/src/pages/ReportDetail.tsx
week2_capable/mud_monitor/web/src/App.tsx
week2_capable/mud_monitor/web/src/pages/Sessions.tsx
week2_capable/mud_monitor/web/src/pages/SessionDetail.tsx
```

---

### 9. Tests

The harness is itself testable without a MUD or a model, which is the point of
the tier-1 split.

**Overrides** (`test/test_overrides.rb`) — deep merge of mappings; sequence
replace; `inventory+` append; `null` deletes; `base_initial_state` at a later
layer discards the earlier file; precedence across all four layers.

**Fixtures** — a state setting `class`/`gender` is rejected; `requires_class`
mismatched against the profile is rejected with the profile named; an unknown
`base_initial_state` names the directory it searched; a plan referencing a
missing scenario fails before anything is seeded.

**SessionFacts** — against committed `.jsonl` fixtures (the repo already has real
ones under `profiles/Dummy/sessions/`): the model/hook tool-call split, iteration
count, cost, `end_reason`. Plus a **legacy log with no `launch` and no
`initiator`** parses with `launch: nil` and does not report a bogus split — the
same legacy path `has_provenance?` already guards.

**Expectations** — each rule kind passes and fails against a known log, and the
failure carries the `call_id` as evidence.

**MapMemory** — `none` archives rather than deletes and leaves a migrated empty
DB; `copy:` produces a readable DB with the source's room count; a WAL-dirty
source copies consistently (this is the regression the `VACUUM INTO` choice
exists to prevent).

**StateLoader** — builds the same config hash `bin/seed_player` builds today from
its constants, verified against the existing
`boukensha/test/fixtures/player` fixtures so the extraction is provably
behaviour-preserving.

**Judge** — verdict JSON parses; a malformed response is an `error`, not a
silent pass; a tier-1 failure is never overturned by a judge `pass`.

**Runner** — a case exceeding `wall_timeout_s` is recorded `error` and the batch
continues; a child crash costs one case.

**RunLog** — every line carries elapsed time and its case; `--quiet` writes the
file and echoes nothing; a parent and a child appending concurrently produce
whole lines, never a spliced one; the file survives a child killed at the wall
timeout with its last milestone intact — the line that says what it died doing.

**mud_monitor** — `Report::Store` path containment (`../../etc/passwd` as an id);
`reports#index`/`#show` shapes; the parser's last-rename-wins name folding.

---

### 10. Delivery order

Each step is independently useful and independently shippable.

1. **Naming and provenance.** `Logger#rename`, `launch` in `session_start`,
   `/rename`, `--session-name`; parser + serializer + `Sessions.tsx` badge and
   name column. *Immediately valuable to hand-driven sessions, before any test
   harness exists.*
2. **`mud_agent_setup` extraction.** Pure refactor, no behaviour change, verified
   by an unchanged interactive session. Everything downstream depends on it.
3. **Fixtures + overrides + `--dry-run`.** Loading and merging with no MUD and no
   model. Corrects the four typos and the plan YAML syntax error currently on disk.
4. **StateLoader + seeder `location:`.** `bin/seed_player --state cleric` works;
   the placement assertion is in.
5. **MapMemory.** `none` / `keep` / `copy:` / `snapshot:`, plus `--snapshot-map`.
6. **Runner + tier-1 report.** `boukensha -ts find_bakery --batch 20 --no-judge`
   produces a real report with real numbers and zero judge cost. *This is the
   first point the original goal — "understand how our agent is doing" — is
   actually met.*
7. **Judge.** `tasks.judge`, prompt, trace digest, verdict merge.
8. **Plans.** `-tsp banking`, plan defaults, per-case overrides.
9. **mud_monitor reports screen.** List, detail, links both directions.

---

### 11. Open questions

- **Judge model.** A judge weaker than the player is not credible; a judge as
  strong as the player is most of the run's cost. Starting position: Sonnet
  judging Haiku, revisited once §6.1's cost attribution says what it actually
  costs.
- ~~**`transfer <player> <vnum>` argument order**~~ — **resolved** against the
  MUD's own help file: it is `teleport <victim> <location>`, and `trans` takes
  no destination. See §3.2.

- **`tbamud__bank` does not exist.** `MudManager::Primitives#bank` is
  implemented, but `mud_manager/lib/mud_manager/mcp/tool_spec.rb` exposes no
  `bank` entry, so the tool cannot be named in `tasks.player.allow` and the
  agent has no way to withdraw anything. The `withdraw_money` scenario ships
  and measures only the navigation half; the rubric's withdrawal half will fail
  until the tool is added. Adding it is ~8 lines in `tool_spec.rb`.
- **Flaky-case policy.** A case that passes 17/20 is neither pass nor fail. The
  report states the rate and refuses to collapse it; whether CI gates on a
  threshold is a decision for when there is CI.
- **Parallelism** across distinct profiles is designed for (§5.2) and not built.
  It needs one MUD account per concurrent case and a per-profile knowledge DB,
  both of which already exist structurally.
- **Scenario chaining** — "run `find_bakery`, then `buy_bread` against the map it
  left behind" — is expressible today only as `map_memory: keep` plus ordering
  inside a plan. Whether that deserves first-class syntax is deferred until a
  second scenario actually wants it.