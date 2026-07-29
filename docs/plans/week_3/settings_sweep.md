# settings_sweep

Per-run settings overrides, and a sweep built on top of them, so that measuring
one configuration against another stops requiring an edit to `settings.yaml`
between runs.

Note: code lives in `week2_capable/`. Every file and line reference below was
checked against the working tree; the numbers from a real run come from
`.boukensha/tests/baselines/find_bakery_cold.json` and the report it names.

---

## 1. Why

`move_to.md` §9 step 8 asks for the four numbers under
`tools.navigation.limits` to be swept against the batch harness, and §4.3 gives
the reason they are configuration rather than constants: "Is Haiku good enough
to pick a frontier" and "how far is too far" are questions the harness answers,
and it can only answer them if the numbers can be varied without a code change.
Making them settings was necessary but it was not sufficient, because nothing in
the harness can vary a setting.

The one override mechanism that exists reaches a different thing entirely.
`--set money.gold=0` is parsed by `Overrides.parse_sets`
(`overrides.rb:67-79`) and folded into a case's *initial world state* through
the four-layer merge `Overrides.resolve` performs (`overrides.rb:36-38`), so it
can put a character in a room with no money and cannot touch
`tools.navigation.limits.max_decisions`. Sweeping a limit today therefore means
editing `.boukensha/settings.yaml` by hand between batch runs and keeping track
of which report belongs to which edit, which is both tedious and the kind of
bookkeeping that produces a wrong conclusion rather than a slow one.

The first measured run makes the case concrete. `find_bakery_cold` passed with
`max_decisions: 6`, but it passed by spending all six decisions on the first
`move_to`, returning `stopped on budget`, and requiring the player to call
`move_to` a second time to finish the journey. Whether a higher ceiling would
have bought that second round trip back, or would merely have spent more
navigator tokens for the same result, is one command away from being answered
and is currently several manual edits away instead.

---

## 2. Design

A settings override is a nested hash merged over the parsed contents of
`settings.yaml`, resolved in the parent at case-resolution time and applied in
the child before anything reads configuration.

```
scenario / plan / --setting
        │
        ├─ Fixtures.resolve_scenario        merges the layers, validates the
        │                                   key paths, stores the result on
        │                                   Fixtures::Case#settings
        │
        ├─ Runner#payload_for               writes it into the case payload,
        │                                   which already travels as a file
        │
        └─ CaseRunner#run (child)           installs it before the first
                                            Boukensha.config read, so every
                                            cfg.dig and cfg.tasks reader sees
                                            the merged value with no change
```

Three properties of the existing code make this small rather than invasive.

`Boukensha.config` is memoized on the module (`boukensha.rb:12-14`) and is the
single object every consumer reads configuration through, whether by
`cfg.dig(:tools, "navigation", :limits)` or `cfg.tasks("navigator")`. A merge
applied to the settings hash before that memo is filled therefore reaches every
reader without any of them being modified, which matters because the readers are
spread across the loader, the hooks, the reasoners and the subsystem.

The child process has exactly one window in which to do it. `CaseRunner#run`
calls `BoukenshaLoader.apply_profile!` at `case_runner.rb:34`, which only sets
two environment variables, and reads `Boukensha.config` for the first time on
the very next line. Installing the overrides between those two lines is a
one-line change, although the plan should add a guard rather than rely on the
ordering staying that way — see §8.2.

`Overrides` already implements the merge semantics this needs, including deep
merge for mappings, replacement for sequences, the `key+` append form, and
`null` as deletion (`overrides.rb:40-58`). Reusing it means a settings override
behaves the way a state override already does, so there is one set of rules to
learn rather than two.

### 2.1 Precedence

Later layers win, and the ordering mirrors the state merge so that an author who
knows one knows the other:

| layer | where | why it exists |
|---|---|---|
| `settings.yaml` | `.boukensha/settings.yaml` | the deployment's own configuration, and the base for everything below |
| plan `defaults.settings` | a plan file | one configuration for a whole plan, which is the common case for an A/B |
| plan case `settings` | a plan case | the arm of a sweep |
| `--setting KEY=VALUE` | CLI | the one-off, and the form a shell loop uses |

A *scenario* is deliberately absent from that table. See §11.1.

---

## 3. Surface

### 3.1 The flag

```
boukensha -ts find_bakery_cold --setting tools.navigation.limits.max_decisions=10
boukensha -ts find_bakery_cold --setting tasks.navigator.model=claude-sonnet-4-6
```

`--setting` rather than an extension of `--set`, because the two address
different things and a single flag whose meaning depended on whether the key
path happened to match a settings key would be guessing at intent. It is
repeatable and coerces scalars through the existing `Overrides.coerce`
(`overrides.rb:84-95`), so `max_decisions=10` arrives as an integer and
`act_on_place=false` as a boolean rather than as the strings `"10"` and
`"false"` — which matters, because `act_on_place` is read as `!= false` and a
string would silently mean true.

### 3.2 In a plan

```yaml
name: navigation_limits
description: "move_to.md §9 step 8 — does a higher decision ceiling pay for itself?"

defaults:
  player_profile: Derrano
  map_memory: none
  settings:
    tools:
      navigation:
        limits:
          max_rooms: 12

cases:
  - scenario: find_bakery_cold
    batch: 5
    session_name: "decisions 4"
    settings: { tools: { navigation: { limits: { max_decisions: 4 } } } }

  - scenario: find_bakery_cold
    batch: 5
    session_name: "decisions 10"
    settings: { tools: { navigation: { limits: { max_decisions: 10 } } } }
```

That is the whole feature as far as an author is concerned, and it is enough to
answer §1's open question. It is also verbose for what it expresses, which is
why §3.3 exists.

### 3.3 A sweep, as sugar over §3.2

Writing one case per value is fine for two arms and unreasonable for the
four-way cross of two knobs, so a plan may instead declare the axes and let the
harness expand them:

```yaml
name: navigation_limits
sweep:
  tools.navigation.limits.max_decisions: [4, 6, 10]
  tasks.navigator.model: [claude-haiku-4-5, claude-sonnet-4-6]

cases:
  - scenario: find_bakery_cold
    batch: 5
```

The expansion is the Cartesian product of the axes applied to every case in the
plan, so the plan above resolves to six arms of five cases each. Dotted key
paths are used here rather than nested mappings because an axis is a single
key and nesting one mapping per axis would obscure that the interesting part is
the list.

Expansion happens in `Fixtures.resolve_plan` (`fixtures.rb:155-170`), which
already flattens a plan into cases and already merges `defaults:` underneath
each case, so a sweep is one more flat_map in a method whose job is exactly
this. Each expanded case carries an `arm` label derived from its axis values —
`max_decisions=10 model=claude-haiku-4-5` — because §5 needs something to group
by that is not a session name an author typed.

Multiplying case counts silently is the obvious way for this to go wrong, so the
run log's opening line and `--dry-run` both have to state the arm count and the
resulting total before anything is seeded. Thirty cases at roughly $0.03 and
ninety seconds each is fifteen minutes and a dollar, which is a reasonable thing
to ask for and an unreasonable thing to discover.

---

## 4. The digest is the sharp edge

`Launch.settings_digest` (`launch.rb:67-81`) hashes the *file contents* of
`settings.yaml` together with the system prompt in force, and its own comment
states what it is for: "A batch of 20 is a measurement of ONE configuration;
comparing runs across a prompt edit is the single easiest way to draw a wrong
conclusion, and this is what lets a report refuse to aggregate two different
digests into one number."

An override applied in memory does not change the file, so every arm of a sweep
would carry an identical digest. The field that exists to stop two
configurations being compared as one would then be actively asserting that six
different configurations were the same one, which is worse than the field not
existing, because a reader who has learned to trust it would be misled by it.

So `settings_digest` must hash the **resolved** settings rather than the file it
was loaded from. Concretely, `Config` gains a reader for the merged settings
hash and `settings_digest` serialises that deterministically — sorted keys —
instead of calling `File.read` on `settings.yaml`. Two consequences are worth
stating rather than discovering:

- The digest changes for every existing deployment on the day this lands, even
  though no configuration changed, because a canonical serialisation of a parsed
  YAML document does not hash to the same value as the document's bytes. Reports
  written before and after cannot be compared on digest equality. That is a
  one-time discontinuity and it is the correct trade, but it should be recorded
  in the report schema note so that a reader six months from now is not left
  guessing.
- Hashing the parse rather than the bytes is also strictly more honest, because a
  comment edit or a reflow currently changes the digest and changes nothing about
  the run.

---

## 5. A report describing more than one configuration

`Report#summary` (`report.rb:76-95`) computes one `pass_rate`, one `median` and
one `p90` over every case in the run, and `CLI#environment`
(`cli.rb:211-224`) writes one `environment` block carrying one
`settings_digest`, read from the parent's own un-overridden config. Both are
correct for the runs that exist today, where a batch of twenty is twenty samples
of one configuration, and both are wrong for a sweep: a median taken across
`max_decisions: 4` and `max_decisions: 10` is a number describing nothing, and
it is the number the run's final line would print.

The report therefore needs to group by arm. The change has three parts:

1. Each case row carries its resolved settings overrides and its own digest, so
   a case is self-describing and a reader who distrusts an aggregate can rebuild
   it from the rows.
2. `summary` gains an `arms` array, each entry holding one arm's label, its
   overrides, its digest, and the same statistics `summary` already computes,
   scoped to that arm's cases.
3. The run-level `summary` keeps its current shape for the single-arm case, and
   for a multi-arm run reports counts and cost — which do aggregate honestly —
   while omitting `median`, `p90` and `pass_rate`, which do not. Omitting a
   misleading number is better than qualifying it in a comment nobody reads.

The run-level `environment` block keeps provider, model, version and git sha,
and loses `settings_digest` to the arms whenever there is more than one. What
the parent's config digest describes in a sweep is the file on disk, which is
not what any case ran under.

---

## 6. What may be overridden, and what may not

Not every settings key is a safe thing for a test fixture to change, and the
distinction is not about how deeply nested the key is.

**Refused outright.** `mcp_servers` is the agent's only source of tools, and its
`mud` entry carries the host, the port and — through
`Config#apply_profile_mud_env!` (`config.rb:272-289`) — the character being
logged in as. A scenario that could rewrite that block could point a test at a
different MUD or play as a different character while the report went on naming
the profile it thought it was measuring. The safe rule is that a settings
override may not touch `mcp_servers` at all, and that the refusal is an error at
resolve time with a sentence, in the same posture as `Fixtures::PROFILE_OWNED`
(`fixtures.rb:34`) refusing a state file that sets the player's class.

**Allowed, and the point of the feature.** Everything under `tasks` and `tools`.
That covers the four `tools.navigation.limits` knobs §1 exists for,
`tools.navigation.act_on_place` (which is `move_to.md` §9 step 5's observation
switch, and therefore a thing worth A/B-ing rather than only toggling),
`tasks.navigator.model` and `tasks.cartographer.model` for the "is Haiku good
enough" question, and `tasks.player.allow` — which is how a future surface
change gets measured against the current one instead of replacing it.

**Allowed but worth a warning.** `memory.turn_policy` and the `agent:` block.
Both are legitimate sweep axes and both change the agent under test in ways a
reader skimming a report would not expect from a scenario name, which is an
argument for the arm label being visible in the run log rather than for
forbidding them.

### 6.1 Typos must fail before anything is seeded

A misspelt key path is the failure mode this feature will actually produce.
`--setting tools.navigation.limits.max_decision=10`, singular, would merge
cleanly into the settings hash, be read by nothing, and produce an arm that
looks like a measurement of a changed configuration and is a measurement of the
unchanged one. Nothing downstream can catch that, because
`Config#dig` (`config.rb:180-187`) answers `nil` for an absent key and every
reader has a default.

The available check is that **an override may only address a key path that
already exists in `settings.yaml`**. That is a real constraint rather than a
schema — settings are not a closed set — and it catches every typo of an
existing key, which is the whole population of likely mistakes. It costs the
ability to introduce a *new* key by override, which nothing needs: a knob that
does not exist in the deployment's own file is a knob no reader of that file
knows about.

The check belongs in `Fixtures`, because that is where everything else fails at
load time with a sentence, and its own comment gives the reason: "discovering
that a cleric state was applied to a warrior twenty minutes into a batch"
(`fixtures.rb:17-19`) is the experience being avoided.

---

## 7. Alternatives considered

**Write a merged `settings.yaml` into the case's work directory and point the
child's `BOUKENSHA_DIR` at it.** Attractive because it needs no new injection
seam and the digest keeps hashing a real file. Rejected because `BOUKENSHA_DIR`
roots far more than settings: `Config#resolve_dir` (`config.rb:220-223`) makes
it the parent of `profiles/`, `tests/`, `.env`, `models/` and
`knowledge.sqlite3`, and `Runner#spawn_case` (`runner.rb:149`) passes the real
root to the child precisely so those resolve. An overlay directory would have to
symlink all of them correctly for every case, and a run whose map memory
silently landed in a temporary directory would be a genuinely confusing failure.

**Extend `--set` to detect settings key paths.** Rejected in §3.1: one flag
whose target depends on whether the key happens to match is a flag that guesses.

**Sweep by shell loop, with only `--setting` and no plan support.** This is
worth naming because it is the minimum viable version and it is a legitimate
place to stop. What it cannot do is put the arms in one report, so comparing
them means opening N report files and doing the arithmetic by hand — which is
the bookkeeping §1 is complaining about, moved rather than removed. The
`--setting` flag alone is still the first thing to build, because everything
else is built on it.

**Make the sweep a first-class command rather than plan syntax.** Rejected
because a plan already is the harness's construct for "this set of cases,
batched, with overrides", and a sweep is that with one more dimension. A second
construct would need its own resolution, its own validation and its own report
shape.

---

## 8. Risks

1. **Silent no-op overrides.** The one that will actually happen. §6.1 is the
   mitigation and it has to land with the feature, not after it, because an arm
   that measured nothing is indistinguishable from an arm that measured no
   difference.
2. **The injection window closing.** Applying overrides depends on nothing
   reading `Boukensha.config` before `case_runner.rb:35`. That is true today and
   is not enforced by anything. `Config` should refuse to accept overrides after
   its settings have been read at least once, and raise rather than warn: an
   override that arrived too late produces a case that ran under the wrong
   configuration and reported the right one, which is the worst available
   outcome.
3. **Digest discontinuity.** §4. Every report predating this change becomes
   incomparable-by-digest with every report after it. Cheap to live with, and
   expensive to be confused by, so it goes in the schema note.
4. **A sweep multiplying cost.** Three values of one knob crossed with two
   models is six arms, and at `batch: 5` that is thirty live runs. §3.3 requires
   the count and the estimate up front in both `--dry-run` and the run log.
5. **Arms that are not comparable for a reason the harness cannot see.** Region
   declarations are earned and never overwritten (`move_to.md` §7.6), so an arm
   that runs with `map_memory: keep` inherits whatever the previous arm wrote.
   Every sweep arm should start from the same map, which for a comparison means
   `none` or a pinned `snapshot:`, and a sweep declaring `keep` is probably an
   error rather than an intent. Worth a warning at resolve time.
6. **Overriding `tasks.player.allow` changes what the report's own expectations
   mean.** `Expectations::KINDS` includes `tool_called`
   (`expectations.rb:26-27`), and an arm that removes a tool from the surface
   will fail an expectation naming it — correctly, but for a reason that reads
   as an agent failure. This is a real limit on §6's most interesting allowance
   and it is not worth solving until something needs it.

---

## 9. Tests

**Merging**
- A settings override deep-merges into the parsed settings and leaves sibling
  keys alone.
- Precedence runs `settings.yaml` < plan defaults < plan case < `--setting`.
- `--setting` coerces scalars, so `max_decisions=10` is an integer and
  `act_on_place=false` is `false` rather than `"false"`.

**Reaching the agent**
- `tools.navigation.limits.max_decisions` set by override is the value
  `MoveTo#limit` returns, asserted through the real `mud_agent_setup` path
  rather than by constructing `MoveTo` directly, since the point is the plumbing.
- `tasks.navigator.model` set by override is the model the navigator's task
  settings report.
- Overrides installed after configuration has been read raise (§8.2).

**Validation**
- An override naming a key path absent from `settings.yaml` is an error at
  resolve time, with the misspelt path in the message.
- An override touching `mcp_servers` is refused.
- Both failures happen under `--dry-run`, before any MUD is seeded.

**The digest**
- Two arms with different overrides produce different `settings_digest` values.
- Two runs with the same overrides produce the same digest.
- The digest is stable across a comment-only edit to `settings.yaml`, which the
  current byte-hashing implementation is not.

**Sweep expansion**
- Two axes of three and two values expand to six arms, each carrying every case
  in the plan.
- Every expanded case has a distinct arm label, and the label names the axis
  values.
- `--dry-run` prints the arm count and the total case count.

**Reporting**
- A multi-arm report carries one `arms` entry per arm, each with its own digest
  and its own statistics.
- A multi-arm report omits run-level `median`, `p90` and `pass_rate` rather than
  computing them across arms.
- A single-arm run's report keeps exactly its current shape, so nothing reading
  today's reports breaks.

---

## 10. Delivery order

1. **`--setting` end to end.** The flag, `Fixtures::Case#settings`, the payload
   field, the child-side install, and the §8.2 guard. At this point a sweep is a
   shell loop producing N reports, which is already better than editing
   `settings.yaml`, and it is the foundation for everything below.
2. **Validation (§6.1 and §6).** Before the flag gets used in anger, because the
   failure it prevents is an arm that quietly measured nothing.
3. **The digest (§4).** Before any multi-arm run exists, so that no report is
   ever written claiming two configurations were one.
4. **Plan-level `settings:`** on `defaults:` and on a case. One configuration per
   arm, arms written out by hand. Enough to answer §1's `max_decisions` question.
5. **Arms in the report (§5).** The point at which comparing arms stops being
   manual arithmetic across files.
6. **`sweep:` expansion (§3.3).** Sugar over step 4, worth having once there is
   more than one axis to cross.
7. **Answer step 8.** Run the sweep `move_to.md` §9 asked for, and settle
   `max_decisions`, the navigator's model, and the provisional
   `max_model_tool_calls` ceilings currently marked as guesses in all five
   scenario files.

Steps 1 through 3 are the useful minimum and are independent of 4 through 6.

---

## 11. Open questions

- **Should a scenario be able to override settings?** §2.1 leaves it out
  deliberately. A scenario is the thing being measured, and one that changed the
  agent's configuration underneath itself would make two runs of the same
  scenario name incomparable without anything saying so. Against that,
  `find_mayor_split` only means anything with a cartographer configured, and
  today that is an unstated prerequisite of the file rather than a declared one.
  A middle position worth considering is that a scenario may *require* a
  setting — failing at resolve time when the deployment disagrees — without
  being able to *change* one, which turns a silent prerequisite into a checked
  one and keeps comparability.
- **Does an arm need its own map snapshot?** §8.5 says every arm should start
  from the same map and that `keep` is probably an error in a sweep. Whether the
  harness should refuse it, warn about it, or leave it to the author is not
  obvious, and the answer probably depends on whether anyone finds a legitimate
  use for a sweep that accumulates.
- **How should an arm's cases be interleaved?** Running all five cases of arm A
  before arm B is simplest and confounds the comparison with anything that
  drifts over the run, such as the MUD's own state or a rate limit. Interleaving
  by arm costs nothing in code and makes each arm's five samples span the same
  wall-clock window. Probably worth doing, but it wants a moment's thought about
  map memory first, since interleaving and `keep` together would be incoherent.
- **Is the Cartesian product the right expansion?** It is the obvious one and it
  grows multiplicatively. A sweep of three knobs at three values each is
  twenty-seven arms, which nobody will run. Whether the harness should support
  one-axis-at-a-time expansion as well is a question for after the first real
  sweep, not before it.
