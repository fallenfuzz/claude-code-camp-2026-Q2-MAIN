# The TUI Slowdown — a ~0.42s-per-event floor from the render loop

> **Summary of a performance finding.** After we removed the LLM from
> `inspect_room`, the survey was *still* slow — and the cost turned out to have
> nothing to do with the model, the logger, the MCP transport, or the MUD. It was
> our own **TUI render loop starving the agent's worker thread under Ruby's GVL**.
> This note consolidates the investigation, which was previously split across
> three docs that disagreed with each other.
>
> Fuller record: [`look_candidates_runtime.md`](look_candidates_runtime.md) §8.1
> and §12.6, the original (now-superseded) diagnosis in
> [`scripted_room_survey.md`](scripted_room_survey.md) §6, and the confirmation in
> the [Week 2 journal](../../journal/2_capable.md) (Step 10).

---

## TL;DR

- **Symptom:** a **uniform ~0.42s gap between *every* consecutive session-log
  event** — including transitions that do no I/O and no inference at all. A room
  survey writes ~10–16 events, so this floor alone was **~4–7 seconds** of pure
  overhead per `inspect_room`.
- **It is not the work.** Measured: the log write is **0.003 ms**, an MCP round
  trip **0.1–0.2 ms**, the MUD itself **62 ms**. None of them explain a 0.42s
  floor. The original guess — "it's a flush/fsync per log line" — did not survive
  measurement.
- **Root cause:** Ruby's **Global VM Lock (GVL)**. The TUI renders on a **60ms
  tick on the main thread** while the agent turn runs in a separate
  `@turn_thread`. When a full re-render holds the GVL, the worker thread is
  starved *between* events — producing exactly a fixed floor that is independent
  of what the worker is actually doing.
- **Confirmed:** running with **`--no-tui`** made the survey "incredibly fast."
  The floor is the render loop, not any real work.
- **Status:** root cause **confirmed by the `--no-tui` run**; the fix (throttle
  or coalesce renders) is **not yet landed**. `TICK_MS` is still 60 and the
  render still runs on the main thread.
- **Why it matters beyond `inspect_room`:** this floor sits under the **entire
  agent loop**, not just room surveys. Fixing it speeds up the player loop too.

---

## 1. The symptom

`inspect_room` started as an LLM subagent at **33.8s per room**. Deleting the
three LLM calls dropped it to ~5–10s — a big win, but the remaining time didn't
add up. The session log showed a suspicious pattern: a **flat ~0.42s gap between
consecutive events**, no matter what the event was:

```
+0.42s  iteration        ← pure in-process bookkeeping, no I/O
+0.42s  prompt
+0.43s  response → tool_call
+0.43s  turn_end → task_end
```

A survey emits ~10–16 log events, so this was the **dominant remaining cost** —
larger than the actual MUD round trips.

## 2. What it was *not* (ruled out by measurement)

The first diagnosis (`scripted_room_survey.md` §6) blamed the session logger — a
flush or fsync per line. **Measurement killed that theory**, along with every
other obvious suspect:

| Suspect | Measured cost | Verdict |
|---|---|---|
| `Logger#write_log` (JSON + `puts` + `flush`) | **0.003 ms/event** | not it — off by 5 orders of magnitude |
| MCP stdio round trip → daemon → MUD | **0.1–0.2 ms/call** | not it |
| The MUD itself (19 real commands) | **62 ms median** | not it |
| MCP spawn + handshake | 62 ms, once per session | not it |

A survey's *real* work is about **0.3s** (5 commands × ~62ms) **plus ~15ms of
model**. Everything above half a second per event was unexplained — a fixed cost
that no event's work accounted for.

## 3. Root cause — GVL contention with the render loop

Ruby has a **Global VM Lock**: only one thread executes Ruby at a time. Our TUI
runs two threads that both want it:

- the **main thread** renders on a **60ms tick** (`TICK_MS = 60`,
  [`tui.rb`](../../../week2_capable/boukensha/lib/boukensha/tui.rb)), redrawing
  the viewport, progress spinner, input, and status bar each tick;
- the **agent turn** runs in a separate `@turn_thread` (`tui.rb:272`), producing
  the log events.

If a full re-render holds the GVL long enough on each tick, the worker thread
can't run *between* producing one event and the next — so the time between events
is governed by the **render cadence**, not by the work. That is precisely the
shape we saw: a floor proportional to render cost, independent of what the worker
is doing.

## 4. Confirmation — the `--no-tui` run

The clean test is to run the identical session with the TUI off and recompute the
deltas. We did:

> "I performed without the TUI and it performed incredibly fast."
> — Week 2 journal, Step 10

The floor disappears without the render loop. That confirms the hypothesis: **the
TUI render tick is the cause.**

> **Loose end worth closing:** the mud monitor doesn't yet report total
> session duration, so the with-vs-without comparison is qualitative, not yet a
> hard before/after number. Adding a session-duration readout would let us quote
> the exact speedup and guard against regressions.

## 5. The fix (proposed, not yet landed)

The mechanism points straight at the remedy: **stop the render loop from holding
the GVL between the worker's events.** Options, cheapest first:

- **Throttle or coalesce renders** — the render tick doesn't need to fire at 60ms
  while a turn is streaming events; a lower cadence (or rendering only when state
  actually changed) hands the GVL back to the worker. `fps` is already capped at
  30; `TICK_MS` and the "always re-render on tick" behaviour are the next levers.
- **Only re-render on a real change** — `view` already tracks `@dirty` for the
  viewport; extending "dirty means draw, clean means skip" to the whole frame
  avoids repainting an unchanged screen 16 times a second.

Either way this is a **render-scheduling change, not a logging change** — do not
"fix the logging," which measurement already exonerated.

## 6. Why this is worth fixing

This floor is not an `inspect_room` problem — it sits under **every agent turn**,
because every turn produces log events through the same TUI. Removing it:

- takes `inspect_room` from ~5–10s toward its ~0.5s floor of real work;
- speeds up the **player loop** by the same mechanism;
- and matters more than any remaining NLP or MUD optimization, because at the
  current operating point the model is **7ms** and a MUD command is **62ms** —
  the render floor is larger than both combined, multiplied by every event.

## 7. Lesson

The first three writeups of this bug each blamed something plausible — the
logger, then "just retrain," then the model — and each was wrong. The floor only
gave up its cause once we **measured every suspect and ran the one clean
experiment (`--no-tui`)**. A uniform, work-independent delay is a scheduling
signature, not a workload one: when the gap is the *same size everywhere*, stop
looking at what each step does and start looking at what's holding the lock.
