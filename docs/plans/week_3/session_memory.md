# Session memory

The agent's map is the single biggest determinant of its behaviour, and it is
the one artifact a finished session does not leave behind. This plan gives every
session's world memory a name, a home, a retention policy, and a way to be
loaded back — by a later test case, or by the monitor, or by a developer asking
what the agent actually knew when it made a decision.

---

## 1. The problem

The `boundaries_gate` run of 2026-07-29 produced sixteen sessions and fifteen
knowledge databases, and nothing joins the two sets. The databases are named by
wall-clock time in `profiles/Derrano/knowledge.archive/`, and the reason they
cannot be named anything better is a matter of ordering rather than oversight:
`CaseRunner#prepare_map_memory` (`case_runner.rb:131`) runs before the agent
starts, so at the moment a map is archived the session that produced it has
already ended and the session that is about to begin does not yet have an id.
Each archive therefore holds the *previous* case's final map, filed under the
timestamp at which the *next* case happened to start.

The consequences are worth stating separately, because they are three different
problems that happen to share a cause.

The first is diagnostic. When `find_bakery_cold #3` walked north out of town and
ended in a passage two zones away, the question worth asking is what its map
looked like at the moment it chose north, and the answer is in a file whose
name gives no indication that it belongs to that run. The session log, by
contrast, is richly identified: `session_start` carries `session_id`,
`run_id`, `scenario`, `plan`, `case_index` and `map_memory`, so every other
artifact the run produced — telnet, manager, journal — already joins on one key.
Memory is the only one that does not.

The second is reproducibility. A scenario can start from `snapshot:<name>`, but
the only way to *produce* a snapshot today is `--snapshot-map`, which pins
whatever a live profile currently holds. There is no way to say "the map as it
stood at the end of that run", which is precisely what a fixture wants to be.
The `boundaries` plan is blocked on exactly this: it needs a mapped Midgaard,
and the natural source is a good exploration run that has already happened and
whose map has since been overwritten by the next case.

The third is retention. `knowledge.archive` grows without bound and is never
read, so it is simultaneously the wrong thing to keep forever and the only copy
of something worth keeping at all.

---

## 2. The design in brief

**A session's memory is named after the session.** The identifier
`20260729T183933Z-4caca6d5` is already unique, already sorts chronologically,
and is already the join key for every other per-session artifact, so reusing it
verbatim means the monitor's existing session views can reach memory without a
new correlation scheme and without a lookup table:

```text
tests/knowledge/sessions/Derrano/20260729T183933Z-4caca6d5.sqlite3
```

**It is written when the session closes, not when the next one opens.** This is
the whole of the ordering fix. `CaseRunner#run` already reads
`Operation.session_id` immediately after `BoukenshaLoader.run_case` returns
(`case_runner.rb:74`), which is the first moment at which both the finished map
and the id that names it are in hand. Retention hangs off that line. The
start-of-case archive in `MapMemory#reset!` stays exactly as it is, because it
guards a different hazard — a developer's real accumulated map, destroyed
because they typed a test command — and that hazard does not go away just
because tests now keep their own copies.

**Retention is by count, and snapshots are exempt.** The thirty most recent
session databases per profile are kept and older ones are deleted, with thirty
chosen because a plan run is ten to fifteen cases and two consecutive runs is
the comparison a developer actually makes. At roughly 127 KB each — the size
every database in the 2026-07-29 archive happens to be — thirty comes to about
3.8 MB per profile, so the policy exists to keep the directory legible rather
than to reclaim meaningful disk.

**Promotion is how something survives.** A retained session map is a candidate
fixture, and promoting one is the missing half of the snapshot workflow:

| | |
|---|---|
| `--snapshot-map <name>` | pins the profile's CURRENT map, as today |
| `--snapshot-map <name> --from-session <id>` | pins a retained session's map |

Snapshots keep their own directory, are never pruned, and are the only memory
artifact that belongs in git.

**Loading one back is a fourth `map_memory` mode.** `MapMemory#apply!`
(`map_memory.rb:50`) already dispatches on a small set of string modes, and
`session:<id>` joins them by reusing `install`, which copies with `VACUUM INTO`
and then migrates the copy. Because the copy is migrated rather than the
source, restoring a retained map from an older schema brings the working file
forward and leaves the retained original at the version it was written at,
which is what makes a retained map a record rather than something that quietly
changes when it is read.

```text
none              archive the current DB aside, start from empty schema
keep              leave it alone
copy:<profile>    another profile's current DB
snapshot:<name>   a committed fixture
session:<id>      the map a previous session ended with          ← new
```

The override the agent needs in order to read any of this already exists.
`Store.for_dir` resolves `ENV["MUD_KNOWLEDGE_DB"]` before falling back to the
profile directory (`store.rb:116`), and the monitor's initializer honours the
same variable (`config/initializers/mud_monitor.rb:60`). Nothing in this plan
adds a path-resolution mechanism; it adds names worth pointing that mechanism
at, and a mode that does the pointing without an environment variable.

---

## 3. Layout

```text
.boukensha/
  profiles/<profile>/
    sessions/       20260729T183933Z-4caca6d5.jsonl      (exists)
    telnet/         20260729.jsonl                        (exists)
    journal/        20260729.jsonl                        (exists)
    knowledge.sqlite3                                     (exists — live)
    knowledge.archive/                                    (exists — see below)
  tests/
    reports/<scenario>/<run_id>.json                      (exists)
    knowledge/
      sessions/<profile>/20260729T183933Z-4caca6d5.sqlite3   NEW, pruned to 30
      snapshots/midgaard.sqlite3                             NEW, committed, never pruned
```

Both directories sit under `tests/` because retention is a test-harness feature
in the strict sense: the write happens in `CaseRunner#run`, and a REPL session
does not go through `CaseRunner` at all, so no path outside a test run ever
produces a retained map. Scoping the directory to the profile would have been
describing a hazard that the delivery order excludes by construction.

The stronger reason is that `tests/reports/` already establishes the shape.
A report is a per-run artifact of a run that certainly had a profile, and it is
nonetheless filed under the boukensha root and joined by run id rather than by
profile, on the reasoning `application_controller.rb:41` gives: a report exists
to compare runs that may not have used the same profile. A retained map is the
same kind of artifact and joins on the same kind of key, so it belongs in the
same place. The monitor also already resolves `tests_dir` off the root and
reads reports from it, which means serving a retained map costs no new path
configuration.

The profile appears as a subdirectory rather than in the filename because
retention is counted per profile and a per-directory count is the cheapest way
to express that, in the same way `tests/reports/` subdivides by scenario.
Session ids are globally unique, so the subdirectory is for pruning and
legibility rather than for avoiding collisions.

Snapshots move from `tests/states/maps/` to `tests/knowledge/snapshots/`, which
is a rename of a directory currently holding no files and therefore costs a
one-line change to `Fixtures#resolve_plan`'s `maps_dir` and an update to
`tests/README.md`.

`profiles/<profile>/knowledge.archive/` stays where it is and keeps its
wall-clock names. It is not part of this scheme and is not read by anything;
it exists so that `map_memory: none` run against a real profile does not
destroy a developer's accumulated map, and that hazard is unaffected by tests
keeping their own copies. Its fifteen existing files remain as they are, since
nothing can retroactively determine which session produced which.

One consequence of scoping retention to tests is worth stating plainly, because
it touches the workflow that motivated the plan: an exploratory REPL run — the
natural way to build a good Midgaard map by hand — is not retained, so the way
to keep one is still `--snapshot-map <name> --profile <p>` against the live
profile immediately afterwards. Step 4 adds promotion from a retained session,
which covers maps built by test runs; it does not remove the need for the
existing command.

---

## 4. What the monitor gains

`SessionDetail` currently ends at the transcript, and the map the session built
is one click away in a tab that shows a different thing entirely — whatever the
profile holds right now, which for any session but the most recent is a
different world.

The Reader is already built for this. `Knowledge::Reader.open` takes `path:`
and opens a connection per request rather than memoizing one, absence is a
state it reports rather than an error (`attached?`), and an older schema is
served rather than rejected because every read is gated on the version the file
itself reports. Serving a past session's memory is therefore a matter of
choosing a different path in `KnowledgeController#with_reader`
(`knowledge_controller.rb:103`), not of teaching the reader anything new.

The changes are: `knowledge#show` and its siblings accept an optional
`session=<id>` parameter and resolve it against
`tests_dir/knowledge/sessions/<profile>/`, which the controller already has
configured, refusing anything that does not match the session-id grammar
exactly, since a parameter that becomes a filesystem path is the one place in
this application where a traversal is possible; the sessions index carries a
`memory_retained` boolean
per row, which is one `File.file?` per row and cheap at a page size of thirty;
`SessionDetail` grows a link to `/knowledge?session=<id>` that is rendered as
disabled text, not a dead link, when the memory has been pruned; and every
knowledge view shows a banner naming the session whenever it is displaying a
retained file rather than the live one, because a page that looks exactly like
the live map while showing a two-day-old one is worse than no page.

Pruned memory should read as an expected outcome rather than as an error. A
session older than thirty runs having no map is the retention policy working,
and the phrasing in the UI should say which policy removed it.

---

## 5. Delivery order

1. **Retain on close.** `CaseRunner` writes the map to
   `tests/knowledge/sessions/<profile>/<session_id>.sqlite3` after `run_case`
   returns, using `MapMemory#snapshot!`'s existing `VACUUM INTO` path. Nothing
   reads it yet. This is the step that makes the 2026-07-29 problem stop
   recurring, and it is worth landing alone so that the next plan run produces
   joinable artifacts whether or not the rest of this is built.
2. **Prune.** Keep thirty per profile directory, oldest first by name, which
   sorts correctly because the ids are ISO timestamps. Pruning is scoped to one
   profile's directory, so it cannot reach `snapshots/` by construction rather
   than by a check, and a test asserts that a snapshot sharing a name with a
   session id survives.
3. **Load.** `map_memory: session:<id>`, and `--map-memory session:<id>` on the
   CLI.
4. **Promote.** `--snapshot-map <name> --from-session <id>`, and the directory
   move from `states/maps` to `knowledge/snapshots`.
5. **Monitor.** The `session=` parameter, the `memory_retained` flag, the link,
   and the banner.

Steps 1 and 2 are worth having on their own even if nothing else is built,
because they cost little and they are what turns a directory of anonymous
databases into a record. Step 4 is what unblocks the `boundaries` plan, which
needs a `midgaard` snapshot and currently has no way to make one except by
hand-running an exploration and pinning the profile before the next case
overwrites it.

**Tests.** A session id that does not match the grammar is refused by both the
loader and the monitor parameter; pruning keeps exactly thirty and removes the
oldest; pruning never removes a snapshot; a retained map from an older schema is
migrated on restore while the retained file itself is left at its original
`user_version`; `session:<id>` for a pruned or never-retained id fails with a
sentence naming the file it wanted, in the same shape as
`snapshot:<name>`'s existing error; a case that fails mid-run still retains
whatever map it had built; and the monitor serves a retained file with the
correct room count while the live map holds a different one.

---

## 6. What stays wrong

| | |
|---|---|
| **A retained map is the map at session END.** | A case that died halfway retains a half-built map, which is correct and can still mislead someone who reads it as the map the agent had when it made the decision they are investigating. The session log timestamps every discovery, so the ordering is recoverable, but not from the database alone. |
| **Pruning is by count, not by value.** | The most interesting run in a batch ages out on the same schedule as fourteen dull ones. Promotion to a snapshot is the answer and it is manual, which means it depends on someone noticing in time. |
| **Retention multiplies by profile.** | Thirty per profile directory, and profiles are cheap to create. Three profiles is about 11 MB, which is fine; a habit of one profile per experiment would not be. |
| **Only test runs are retained.** | A REPL session builds no retained map, so the map from an exploratory run by hand survives only if someone pins it with `--snapshot-map` before the next run overwrites it. This is the scope the plan chose deliberately, and the cost lands on exactly the workflow that produces good fixtures. |
| **A retained map cannot be compared to another one.** | Two databases and no diff. "What did this run learn that that one did not" is a real question this plan does not answer, and answering it later means a reader that opens two files at once rather than one. |

The deeper limitation is that none of this measures anything. It makes the
agent's memory inspectable and reloadable, which is a precondition for the
region metrics `boundaries_revised.md` §8 asks for and cannot currently compute
— the share of moves spent outside the starting region needs room membership
joined against the move log, and until the memory for a given session can be
opened by that session's id, there is nothing to join to.
