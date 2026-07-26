# Session trace explorer: waterfall-first transcript redesign

## Outcome

Replace the session page's separate Transcript and Waterfall modes with one
waterfall-first trace explorer.

The page should answer these questions without switching views:

1. What did the agent do, and in what order?
2. Where did the elapsed time go?
3. What prompt/context did the model receive?
4. What did it reason, say, and ask tools to do?
5. Which work was initiated by the model, hooks, or a delegated agent?
6. What failed, stopped, or remained open?

The waterfall becomes the navigation spine. Selecting a span opens its complete
transcript context in a detail pane. Transcript events are not discarded; they
become the content attached to the span that caused them.

This is a monitor/API change. It does not require sending prompt or tool content
to the OTLP backend. The durable Boukensha JSONL log remains the source of
detailed content, while trace/span IDs and operation IDs correlate that content
with OTel spans.

## Why the current page broke

The failure is a contract problem rather than a missing CSS treatment.

The existing UI classifies spans by their display name:

```text
old names                         new OTel-oriented names
turn                         ->   invoke_agent player
llm.generate                 ->   chat claude-haiku-4-5
tool.move                    ->   execute_tool move
player_bootstrap             ->   bootstrap player
position_refresh             ->   establish position
async_poll                   ->   poll
after_tool                   ->   record outcome
```

`web/src/spans.ts` still recognizes the left-hand names. The new logger emits
the right-hand names. Consequently:

- model, tool, container, and framework classification is wrong;
- the transcript's "transparent framework span" rule no longer matches most
  spans;
- useful records are swallowed into a small number of operation groups;
- unknown spans default to the memory category, which is semantically wrong;
- the transcript and waterfall each reconstruct a different view of the same
  flat event stream.

Changing the string tables would repair today's sample but preserve the
underlying fragility. Span names are labels intended for humans and backend
search. They are not a stable application discriminator.

There is also a parser correctness issue to fix while changing this contract:
`SessionLog::Parser` currently closes `open_operations` with `pop` for every
`operation_end`, even though the record includes an `operation_id`. A missing
or out-of-order end can therefore borrow the wrong start time. Pair starts and
ends by ID, and derive hierarchy only from `parent_operation_id`.

## Product design

### Default layout

Use a two-pane explorer below the existing session summary:

```text
┌ Session summary / limits / cost / live state ──────────────────────────────┐
├ Filters: search | task | kind | status | model/hook | collapse framework ─┤
│                                                                           │
│ Trace outline + waterfall (primary)       │ Selected span details          │
│ ▾ invoke agent player          33.6s      │ chat claude-haiku-4-5          │
│   ▾ iteration                   1.9s       │ 1.7s · 2,431 in · 188 out      │
│     establish position           89ms     │                               │
│     chat claude-haiku-4-5        1.7s     │ [Overview] [Input] [Output]    │
│     execute tool move             66ms    │ [Events] [Raw metadata]        │
│   ▾ iteration                   6.2s       │                               │
│     ...                                   │ prompt/context, reasoning,      │
│                                           │ tool args/result, errors, etc.  │
└───────────────────────────────────────────┴───────────────────────────────┘
```

On narrow screens, the detail pane becomes a drawer. On wide screens it is
sticky and independently scrollable. The timeline column remains aligned
across all visible rows, while nesting appears in a separate tree/label column;
indentation must not shift the time origin.

The default selection is the first root `invoke_agent` span, or the currently
open leaf for a live session. Persist selection in `?span=<operation_id>` so
links from the Manager, Errors page, and copied URLs land on the exact work
unit. Preserve `?op=` as a compatibility alias and redirect it to `?span=`.

### Rows and hierarchy

Every operation span has a row. Rows show:

- expand/collapse control when the span has children;
- status: success, error, running, or incomplete;
- semantic icon and readable label;
- task/agent chip when ownership changes;
- elapsed offset, total duration, and optionally self time;
- a bar positioned on the common session/trace time axis;
- compact badges for the most useful metadata, such as token usage, tool name,
  MUD calls, DB writes, or error type.

Root agent and iteration rows start expanded. Low-value plumbing such as
`record outcome`, zero-duration state renders, and empty polls may start
collapsed, but they remain discoverable under a summary row such as
`15 polls · 2ms`. This is presentation-only aggregation: selecting or expanding
the summary reveals every original span.

Do not use a fixed minimum bar width that implies a false duration. Give
sub-pixel spans a visible hit target/marker while retaining their actual
position and expose exact duration in text and the accessible label.

Offer three time scopes:

- **Session**: a common axis across all root traces/turns (default).
- **Trace/turn**: zoom to the selected root agent invocation.
- **Selection**: zoom to a selected subtree.

This makes a 33-second turn readable without losing the relationship between
multiple turns in a session.

### Detail pane: transcript context attached to work

The selected span detail pane is the replacement for the old linear transcript.
It contains:

- **Overview**: operation, task, initiator, trigger, parent, status, total/self
  duration, trace/span/operation/call IDs, timing and rollup counters.
- **Input**:
  - for `chat`, the request checkpoint with system prompt, tool schemas, message
    history, injected context, context transformations, and token composition;
  - for `execute_tool`, tool name and formatted arguments;
  - for `invoke_agent`, the delegated task request and limits.
- **Output**:
  - for `chat`, reasoning/plan, assistant response, stop reason, usage, model,
    provider, and cost;
  - for `execute_tool`, raw tool result, transformed model result, success/error,
    and duration;
  - for `invoke_agent`, final response and turn-end reason.
- **Events**: all JSONL entries directly owned by the span in sequence order,
  plus an optional "include descendants" toggle.
- **Raw metadata**: attributes, counters, and correlation fields for debugging.
- **Related data**: journal changes for the operation and links to correlated
  durable errors/telnet records when present.

Reuse `MessagesSidebar`'s request/checkpoint presentation, but move the reusable
content into a `ModelCallDetails` component. The explorer must not require a
second overlay to understand a selected model call.

For a structural span such as an iteration, show a concise composed narrative:
automatic context work, model request/response, model-selected tool calls, and
outcome recording in sequence. This retains the valuable reading flow of the
old transcript while making its containment explicit.

Add a **Session narrative** tab alongside the selected-span details. It renders
all content-bearing events in sequence with span breadcrumbs and timestamps.
This is the escape hatch for auditing exact conversational order, search, and
copying, not the primary navigation mode. It should use the same normalized
data as the waterfall rather than `buildTranscriptTree`.

## Stable data contract

### Do not infer semantics from `operation`

Keep `operation` as the display span name, but add structured fields to
`operation_start` and expose them on API entries:

```json
{
  "phase": "operation_start",
  "operation_id": "op-...",
  "parent_operation_id": "op-...",
  "trace_id": "...",
  "span_id": "...",
  "operation": "chat claude-haiku-4-5",
  "otel_kind": "client",
  "semantic_kind": "chat",
  "task": "player",
  "initiator": "model",
  "attributes": {
    "gen_ai.operation.name": "chat",
    "gen_ai.provider.name": "anthropic",
    "gen_ai.request.model": "claude-haiku-4-5"
  }
}
```

`semantic_kind` is a small monitor-owned vocabulary:

```text
invoke_agent
iteration
chat
execute_tool
hook
state
after_tool
compaction
wrap_up
internal
```

It controls row behavior and presentation. More specific facts stay in
attributes:

- `gen_ai.operation.name`
- `gen_ai.agent.name`
- `gen_ai.tool.name`
- `gen_ai.provider.name`
- `gen_ai.request.model`
- `boukensha.tool.initiator`
- `boukensha.trigger`

Prefer deriving `semantic_kind` in the writer, where the operation is created.
For already-written logs, the API normalizer supplies a compatibility mapping
for both old and new names. Unknown values become `internal` and are visibly
labelled "internal"; they must never silently become memory work.

Write the final span attributes needed by the monitor to `operation_end` as a
structured `attributes` object in addition to OTLP. At present many of those
facts are set only on the OTel span via `frame.set`, so the local monitor cannot
use them. Continue keeping sensitive prompt/tool content out of span
attributes; content already has purpose-built JSONL events.

### Build a session trace projection in the API

Add `SessionLog::TraceProjection`, built once from parsed entries. The API
should return the current `entries` for compatibility plus:

```ts
interface SessionTrace {
  roots: string[];
  spans: Record<string, SessionSpan>;
  orphan_entry_seqs: number[];
}

interface SessionSpan {
  id: string;
  parent_id: string | null;
  child_ids: string[];
  trace_id: string | null;
  span_id: string | null;
  name: string;
  semantic_kind: SemanticKind;
  task: string | null;
  initiator: Initiator | null;
  trigger: string | null;
  start_at: string | null;
  start_mono_ms: number | null;
  end_at: string | null;
  duration_ms: number | null;
  self_ms: number | null;
  status: "ok" | "error" | "running" | "incomplete";
  attributes: Record<string, JsonValue>;
  rollup: Record<string, number>;
  direct_entry_seqs: number[];
}
```

Projection rules:

1. Match start/end records by `operation_id`, never stack position.
2. Link hierarchy from `parent_operation_id`; detect cycles and promote broken
   links to roots with a diagnostic flag.
3. Assign each content event to its recorded `operation_id`.
4. If an older event lacks an operation ID, assign it to the narrowest span
   whose time/sequence interval contains it and mark the assignment inferred.
5. Keep unmatched content in `orphan_entry_seqs`; render it in the session
   narrative instead of dropping it.
6. Compute self time from the union of direct-child time intervals, not the sum
   of child durations. Summing can produce negative/incorrect self time if
   siblings overlap.
7. A missing end is `running` only while the session is live; after the session
   ends it is `incomplete`.
8. Preserve recorded sequence order for events. Wall-clock/monotonic time drives
   bars, never conversational ordering.

Returning a normalized projection prevents `SessionDetail.tsx`,
`Waterfall.tsx`, and future consumers from independently rebuilding subtly
different trees. It also gives the API a single place to support historical
logs.

### Model-call correlation

Associate each `chat` span with its request and response using
`operation_id`. The request checkpoint ordinal remains a compatibility
fallback, not the primary join key. Extend the message-timeline endpoint to
accept `operation_id`, or include a `request_seq` reference on `SessionSpan`.

This removes the current fragile flow where selecting a span jumps back to an
invisible `operation_start` and then searches for the nearest rendered
transcript entry.

## Front-end architecture

Replace the two independent render paths with:

```text
SessionDetail
└── SessionExplorer
    ├── ExplorerToolbar
    ├── TraceWaterfall
    │   ├── TraceTreeRows
    │   └── TimeAxis
    └── SpanDetails
        ├── SpanOverview
        ├── ModelCallDetails
        ├── ToolCallDetails
        ├── SpanEventList
        └── RelatedOperationData
```

Use a reducer for explorer state (`selectedSpanId`, expanded IDs, filters,
scope, zoom) and encode only shareable state in the URL. Derive visible rows
with memoized pure selectors.

Keep `spans.ts`, but change it from string-pattern classification to helpers
over `semantic_kind` and attributes. `operationLabel` should only format a
fallback label. Delete `isFrameworkSpan` once the old transcript tree is
retired.

The chart should use CSS Grid for the label, aligned time track, and duration.
Render bars with HTML buttons so keyboard focus, tooltips, and screen-reader
labels work. Add:

- Up/Down: previous/next visible row;
- Left/Right: collapse/expand or parent/first child;
- Enter: select/open details;
- `/`: focus search;
- `f`: show failures;
- `0`: reset time scope.

For ordinary sessions, plain React rows are sufficient. Add windowing only
after profiling; if sessions regularly exceed roughly 500 visible spans,
virtualize the row list while keeping the time axis outside the virtualized
region.

### Live sessions

Continue consuming SSE entries, but update the projection incrementally:

- an operation start inserts a running span;
- events append to the owning span;
- an operation end closes and measures it;
- the active leaf remains selected only when the user has not manually chosen
  another span;
- bars use the current clock for running width;
- follow-live scroll is opt-in and pauses after manual navigation.

Do not rebuild expansion choices when a new SSE entry arrives.

## Implementation sequence

### Phase 1 — repair and lock the contract

1. Add `semantic_kind`, OTel kind, structured attributes, trace ID, and span ID
   to operation start/end JSONL records.
2. Preserve monitor-useful final `frame` attributes in JSONL.
3. Fix parser start/end matching by operation ID.
4. Add compatibility classification for legacy and current OTel names.
5. Add a fixture based on the reported session shape:
   `invoke_agent`, bootstrap, repeated iterations, chat, poll, tool calls,
   state render, record outcome, and an error/open span.

This phase can ship independently and should immediately restore correct
classification in the existing waterfall.

### Phase 2 — normalized trace projection

1. Implement `SessionLog::TraceProjection`.
2. Add the projection to session detail JSON without removing `entries`.
3. Join model checkpoints and journal/error references by operation ID.
4. Add API tests for nesting, missing/out-of-order ends, overlap-safe self time,
   orphan events, multi-root sessions, legacy names, and new OTel names.

### Phase 3 — waterfall-first explorer

1. Build `SessionExplorer`, tree rows, aligned timeline, filtering, selection,
   URL state, zoom scopes, and span details.
2. Make it the default and remove the top-level Transcript/Waterfall toggle.
3. Extract the message sidebar content into `ModelCallDetails`.
4. Add Session narrative as a secondary detail tab.
5. Retain the old transcript behind a temporary development feature flag for
   one release, then delete `buildTranscriptTree` and its CSS.

### Phase 4 — density, live behavior, and accessibility

1. Add presentation-only collapsing/summaries for repeated polls and plumbing.
2. Implement incremental live updates and follow-live behavior.
3. Add keyboard navigation, focus management, narrow-screen drawer behavior,
   reduced-motion support, and non-colour status/category indicators.
4. Profile large sessions and add virtualization only if measurements require
   it.

## Test and acceptance plan

### Contract and parser tests

- Both `llm.generate` and `chat <model>` normalize to `chat`.
- Both `tool.move` and `execute_tool move` normalize to `execute_tool`.
- A missing inner end cannot change the outer span's duration.
- Out-of-order ends match their own starts.
- Multiple root agent invocations remain separate roots in one session.
- Events correlate to the recorded operation ID even when adjacent spans differ.
- Unknown span kinds remain visible as `internal`.
- Open live spans say `running`; unclosed ended spans say `incomplete`.
- Overlapping children do not make self time negative.

### Component tests

- The page opens in the waterfall explorer with the root selected.
- Selecting a chat row shows request, injected context, reasoning, response,
  tokens, provider/model, and cost.
- Selecting a tool row shows arguments, raw result, model-transformed result,
  initiator, and error.
- Selecting a structural row shows a sequence-ordered composed narrative.
- Collapse/filter/search never loses the selected span silently.
- `?span=` opens and focuses the correct row; legacy `?op=` still works.
- Repeated polls may collapse visually but expand to every underlying span.
- A new SSE end changes a running span to completed without resetting selection
  or expansion.

### Visual and end-to-end acceptance

Using the reported session (or its sanitized fixture), a reviewer must be able
to:

1. See the 33.6-second agent invocation and every iteration on one aligned time
   axis.
2. Identify the slow model calls immediately.
3. Select any `chat` and inspect exactly what the model saw and returned.
4. Select any `execute_tool` and inspect arguments, result, initiator, and
   outcome.
5. Distinguish automatic hook work from model-chosen actions.
6. Follow delegation boundaries and task ownership.
7. Find failures, open/incomplete work, context transformations, and journal
   effects without returning to a separate transcript mode.
8. Read/copy the full conversational sequence from Session narrative.

The redesign is complete when the waterfall supplies causal and timing
navigation, while every piece of context previously available in the transcript
is reachable from the selected work unit in one click.

## Non-goals

- Replacing JSONL with OTLP or storing sensitive transcript content in OTel.
- Building a general-purpose Jaeger/Tempo frontend.
- Reconstructing the session solely from exported spans.
- Hiding automatic calls or zero-duration spans from the underlying data.
- Introducing a charting library before the plain HTML/CSS implementation has
  demonstrated a limitation.
