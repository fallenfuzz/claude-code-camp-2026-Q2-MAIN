# Restore the linear transcript as the session view

Supersedes `session_story_tree.md` and the explorer design in `fix_transcripts.md`.

Traces and spans stay in the **exporter** (Grafana / Jaeger), where a trace UI is
someone else's solved problem. They come out of the **monitor**, where they
replaced a transcript that was doing a different job — telling the story of what
the agent said, did and got back — and did it better.

## What actually happened

Three commits, in order:

| Commit | What it did |
| --- | --- |
| `511dcfe` `add tracing` | Spans named `turn`, `iteration`, `llm.generate`, `tool.<name>`. Transcript understands all of them. |
| `4cce5e5` `rawwra` | Renamed spans to OTel GenAI semconv: `invoke_agent <agent>`, `chat <model>`, `execute_tool <tool>`. **Nothing on the read side was updated.** |
| `ccae837` `alternate view` | Built `SessionStory` + `TraceProjection` on top of the new names and demoted the transcript to a `!has_operations` fallback — i.e. unreachable for every session written since. |

So the transcript was not *replaced because it was worse*. It was renamed out
from under, silently degraded, and then routed around. `4cce5e5` is the
regression; `ccae837` is the workaround built on top of it.

### The breakage is mechanical and still present

Every one of these matches a span name that no longer exists. Verified against
`.boukensha/profiles/Dummy/sessions/20260726T171635Z-484352b5.jsonl`, whose only
operation names are `invoke_agent player`, `iteration`, `chat claude-haiku-4-5`,
`execute_tool {poll,move,look,check}`, `after_tool`, `state_render`,
`position_refresh`, `async_poll`, `room_survey`, `player_bootstrap`, `wrap_up`,
`compaction`:

| Site | Matches on | Consequence today |
| --- | --- | --- |
| `web/src/spans.ts:45` `FRAMEWORK_SPANS` | `turn`, `llm.generate`, `tool.*` | Every turn, model call and tool call draws its own `OperationGroup` box. The transcript becomes nested chrome instead of narrative. |
| `web/src/pages/SessionDetail.tsx:511` | `e.operation === "turn"` | `rollups.turnSpans` empty → turn strips lose their measured duration. |
| `web/src/pages/SessionDetail.tsx:512` | `e.operation === "llm.generate"` | `llmLatencyByAssistantSeq` empty → no per-assistant model latency. |
| `web/src/pages/SessionDetail.tsx:539` `toolSpanRollup` | `operation.startsWith("tool.")` | Returns null for every tool → ToolCards lose duration + MUD/db rollup footers. |
| `api/lib/session_log/timing.rb:65` | `e.operation == "llm.generate"` | `timing.model_ms` silently falls back to `assistant` `dt_ms`. The 🧠 inference tile has been wrong since `4cce5e5`. |
| `web/src/spans.ts:10` `OPERATION_LABELS` | old keys | `state_render` and friends render as raw slugs. |

**Why the tests did not catch it:** `web/src/pages/transcript.test.ts:251` asserts
`isFrameworkSpan` over the literal list `["turn", "iteration", "llm.generate",
"after_tool", "compaction", "wrap_up", "tool.move", "tool.attack"]`. The tests
describe the world before `4cce5e5` and pass happily against it. Fixing the
fixtures is part of this plan, not an afterthought.

## Target state

One session page, one view: the linear transcript, as a single scrolling
document. No tabs, no view toggle, no waterfall, no story tree, no trace
projection in the API payload.

`session.has_operations` goes back to meaning what it meant at `511dcfe` — "this
log has spans, so the transcript can nest and roll up" — not "route this session
to a different component".

### What is kept from the otel work

This is a targeted revert, **not** `git revert ccae837`. These changes from that
commit are real fixes and stay:

1. **`Logger#operation_stamp` applied generically in `write_log`**
   (`boukensha/lib/boukensha/logger.rb:390-437`). Before it, only `tool_call` and
   `tool_result` carried an `operation_id`; `prompt`, `request`,
   `injected_context`, `plan`, `response` carried none, and the transcript's
   nesting had to guess. Keep.
2. **Parser pairs operations by id, not by stack**
   (`api/lib/session_log/parser.rb:181-205`, `open_operations` as a Hash).
   A `Array#pop` mispairs the moment two spans close out of order. Keep.
3. **`operation_id` / `call_id` / `initiator` on every parsed entry**
   (`parser.rb:566-575`, `entry_serializer.rb:18-20`). This is what lets the
   transcript group correctly instead of falling back to adjacency. Keep.
4. **The widened `chat` span** (`agent.rb#perform_chat_exchange`). The span now
   brackets injected context → prompt → request → wire call → reasoning →
   response, and reports both its own duration and `boukensha.wire_ms`. The
   transcript wants exactly this: `chat` is transparent chrome whose *duration*
   annotates the assistant entry inside it. Keep.
5. **The extracted `components/transcript/*` components.** Verified faithful to
   the inline originals (`EntryCard` ≡ old `TranscriptEntry`, etc.). They are a
   clean move, not a rewrite. Keep — do not re-inline.

---

## Phase 1 — Teach the read side the current span names

Do this first and alone. It repairs the transcript against real logs *before*
anything is deleted, so Phase 2 is provably a deletion and not a rewrite.

### 1.1 `web/src/spans.ts`

- `FRAMEWORK_SPANS` → predicate, not a Set of literals. A span is framework
  chrome when it is `iteration`, `after_tool`, `compaction`, `wrap_up`,
  `state_render`, or starts with `invoke_agent `, `chat `, or `execute_tool `.
- Keep the legacy names (`turn`, `llm.generate`, `tool.*`) matching too. Sessions
  written between `511dcfe` and `4cce5e5` are on disk and must still read
  correctly — same reason the parser keeps its pre-span adjacency fold.
- `operationLabel`: keep the prefix-stripping added in `ccae837`
  (`execute_tool move` → `move`), add `state_render` → `render state`, drop the
  `semanticKind` parameter (nothing will pass it after Phase 2).
- Delete the stale header comment about the story tree and the waterfall.

### 1.2 `web/src/pages/SessionDetail.tsx` — `buildRollupIndex`

Replace the three literal comparisons with helpers exported from `spans.ts`, so
there is exactly one place that knows span naming:

- `isTurnSpan(op)` — `op === "turn" || op.startsWith("invoke_agent ")`
- `isModelSpan(op)` — `op === "llm.generate" || op.startsWith("chat ")`
- `isToolSpan(op)` — `op.startsWith("tool.") || op.startsWith("execute_tool ")`

`toolSpanRollup` uses `isToolSpan`. The `after_tool` child lookup is unchanged —
that name never moved.

### 1.3 `api/lib/session_log/timing.rb:65`

`model_durations` selects on the same rule as `isModelSpan`. Put the predicate
next to the other span-name knowledge in the parser (`SessionLog::Parser.model_span?`
or similar) rather than inlining a second regex here — `message_timeline.rb:80`
and `parser.rb:101` also match on `"turn"`, and those are the log's `phase`
field, not an operation name; keeping the two concepts textually apart matters.

### 1.4 Tests

- `web/src/pages/transcript.test.ts:249-257`: parametrize the `isFrameworkSpan`
  case over **both** naming eras. Old names and new names must both classify.
- Add a `buildRollupIndex` case using `invoke_agent player` / `chat
  claude-haiku-4-5` / `execute_tool move` asserting `turnSpans`,
  `llmLatencyByAssistantSeq` and `toolSpanRollup` are populated. This is the
  test whose absence let `4cce5e5` land.
- `api/test/lib/session_log/timing_test.rb`: add a `chat <model>` fixture case
  for `model_ms`.
- Reuse `api/test/fixtures/session_logs/story_tree.jsonl` — it is a real
  post-rename session and is exactly the right fixture. Rename it to
  `spans_semconv.jsonl` since the story tree is going away.

**Checkpoint:** load a real session in the monitor with `?tab` forced to the
legacy path. Turn strips show durations, tool cards show rollup footers, the 🧠
tile is non-zero, and turns/model calls/tool calls do *not* each draw a box.

---

## Phase 2 — Make the transcript the only view

### 2.1 `web/src/pages/SessionDetail.tsx`

- Delete the `sessionTab` state, the `session-tabs` tablist, and the
  `waterfall-active` class on `.session-detail-page`.
- Delete the `<SessionStory>` branch and its import. Summary chrome (meta line,
  statstrip, `AutomaticWorkTable`, `CostTable`, sparkline) renders unconditionally
  above the transcript, as at `5a179ee`.
- The transcript renders unconditionally — remove the `!session.has_operations`
  gate on both the render branch and the follow-scroll effect
  (`SessionDetail.tsx:84-90`).
- Restore `?op=<operation_id>` resolution from `5a179ee:107-134`: find the
  `operation_start` entry with that id, `scrollIntoView({ block: "center" })` on
  its seq, then clear the param. Do **not** rewrite it to `?span=` — nothing will
  consume that.
- Keep the compact `.session-page-head` / `.session-back` header from `ccae837`.
  It is a genuine improvement and independent of the story tree.

### 2.2 Delete

- `web/src/components/SessionStory.tsx`
- `web/src/components/SessionStory.test.ts`
- `api/lib/session_log/trace_projection.rb`
- `api/test/lib/session_log/trace_projection_test.rb`
- `api/test/fixtures/session_logs/story_pre_stamping.jsonl` (its only consumer is
  the projection test)
- `api/app/serializers/session_serializer.rb:75` — the `trace:` key
- `web/src/api/types.ts` — the `Trace`/`Span`/`SemanticKind` types and the
  `trace` field on `SessionDetail`

`Waterfall.tsx` and `Waterfall.test.ts` are already gone (deleted in `ccae837`)
and stay gone. `isContainerSpan` / `categoryFor` went with them.

### 2.3 `web/src/index.css`

Remove the story-tree and waterfall blocks — roughly `.view-toggle`,
`.waterfall-*`, `.session-tabs`, `.session-detail-page.waterfall-active`,
`.session-story`, `.story-*`, `.trace-*`, `.kind-*`, `.span-details`,
`.span-story`, `.detail-tabs`, `.explorer-grid`, and the
`body:has(.session-detail-page.waterfall-active)` shell rule (`index.css`
~2593-2870). Keep `.session-page-head`, `.session-back`,
`.session-heading-label`, `.span-status`/`.status-*` if still referenced by
transcript chrome — grep before cutting each block.

---

## Phase 3 — Stop writing trace payload into the session log

Only `TraceProjection` consumed these, and it is gone.

### 3.1 `boukensha/lib/boukensha/logger.rb#operation`

Drop from both `operation_start` and `operation_end`:

- `otel_kind`, `semantic_kind` — and delete `semantic_kind_for` entirely
  (`logger.rb:120-135`). It is a second, hand-maintained taxonomy of span names
  that exists only to feed the story tree's row policy.
- `attributes:` — on `operation_end` this is a straight duplicate: `frame.attributes`
  are already merged flat into the same line. On a 300KB session log that is pure
  weight.

**Keep `trace_id` and `span_id`.** They are two short strings per span and they
are the join key from a monitor line to the Jaeger/Grafana trace for the same
work. Now that traces live over there, that correlation is worth more, not less.
The monitor does not have to render them.

### 3.2 `api/lib/session_log/parser.rb`

- Drop `:otel_kind`, `:semantic_kind`, `:attributes` from the `Entry` field list
  (`parser.rb:32-33`) and from `SPAN_ENVELOPE` (`parser.rb:311`). Keep
  `:trace_id`, `:span_id` in both — `SPAN_ENVELOPE` membership is what keeps them
  out of the `rollup` counter bag.
- Drop the same three from the `operation_start` / `operation_end` branches
  (`parser.rb:191-192`, `201-202`).

### 3.3 `api/app/serializers/entry_serializer.rb`

Drop `otel_kind`, `semantic_kind`, `attributes` from both operation branches
(`:87-102`). Keep `trace_id` / `span_id`.

### 3.4 `boukensha/test/test_chat_span.rb`

Added by `ccae837`. Its assertions about the widened `chat` span and
`boukensha.wire_ms` are keepers (Phase 0 item 4). Strip only the `semantic_kind`
/ `attributes` assertions.

---

## Verification

1. `cd week2_capable/boukensha && bundle exec rake test`
2. `cd week2_capable/mud_monitor/api && bin/rails test`
3. `cd week2_capable/mud_monitor/web && npm test && npx tsc --noEmit`
4. `grep -rn "SessionStory\|TraceProjection\|waterfall\|semantic_kind" week2_capable/` → no hits outside `docs/`.
5. Open `20260726T171635Z-484352b5` in the monitor and confirm, against the raw
   jsonl:
   - the page is one scrolling transcript, no tabs;
   - turn strips carry a measured duration;
   - each tool card shows its own duration and its `after_tool` rollup;
   - the 🧠 inference tile ≈ the sum of `chat` span `duration_ms` in the log;
   - `invoke_agent` / `chat` / `execute_tool` / `state_render` spans draw **no**
     `OperationGroup` box;
   - hook spans (`position_refresh`, `room_survey`, `async_poll`,
     `player_bootstrap`) still collapse into "Automatic context work".
6. Run a fresh session and confirm live SSE follow-scroll works (it has been
   dead on span-bearing sessions since `ccae837` gated it on `!has_operations`).
7. Open a pre-`4cce5e5` log (`20260726T164720Z-e190cb5d.jsonl`) and confirm the
   legacy names still classify.

## Risks

- **CSS deletion over-reaches.** The story tree and the transcript share
  `.session-page-head` and some status classes. Grep each selector before cutting
  it; do Phase 2.3 as its own commit so a bad cut is one `git revert`.
- **`state_render` is new noise.** It is a `before_model` hook span
  (`mud/hooks.rb:213`) that did not exist when the transcript's framework rules
  were written. Phase 1.1 makes it transparent. If it turns out to be worth
  seeing, it belongs in the automatic-work group, not inline.
- **Something in the story tree was genuinely better.** If a specific affordance
  is missed, add it *to the transcript* in a follow-up. Do not reopen the
  two-view split — that split is what produced this cleanup.

## Not doing

- Removing OTel export, `telemetry.rb`, or the collector. Traces are fine; they
  just belong in Jaeger/Grafana.
- Removing `trace_id` / `span_id` from the log.
- Reviving the waterfall in any form.
