# Session story tree: one readable transcript with structure and timing

Supersedes the explorer design in `fix_transcripts.md`. That plan's data-contract
work (semantic kinds, `TraceProjection`, ID-matched span pairing) stays. Its
*product* choice — a waterfall spine with a separate detail pane — is what
produced the current unusable page and is replaced here.

## What is wrong today

Open a session and the page shows a waterfall on the right and a detail pane on
the left. The default selection is the root `invoke_agent player` span. Clicking
it dumps every content event in the session into one pane. Clicking a `chat` row
shows nothing at all. Neither is a transcript.

Three separate causes, all of which have to be fixed:

### 1. The story was never attached to the spans

`Logger#operation_stamp` merges `operation_id` into exactly two events —
`tool_call` and `tool_result` (`logger.rb:297,316`). Every other content event
(`prompt`, `request`, `injected_context`, `reasoning`, `plan`, `response`,
`context_transform`, `iteration`, `turn`, `turn_end`, `compaction`,
`local_inference`) is written with **no operation id**.

The API compensates with `TraceProjection#narrowest_containing`, which assigns an
unowned entry to the narrowest span whose *sequence window* contains it. Trace
the real session `20260726T171635Z-484352b5.jsonl`, lines 19–25:

```text
19 injected_context           ← no operation_id
20 prompt                     ← no operation_id
21 request                    ← no operation_id
22 operation_start  chat claude-haiku-4-5   op_89ad02
23 operation_end    chat claude-haiku-4-5   1732ms
24 plan     "Good morning! I'll help you find the bakery…"
25 response "(tool use — 1 call)"
```

The `chat` span brackets only `@client.call` (`agent.rb:157`), so its start and
end are **adjacent** in sequence — its window contains nothing, so the span that
represents the model call owns none of the model's input or output. Everything at
19–21 and 24–25 falls through to the nearest enclosing window, which is
`iteration`. The one span a reader most wants to click is guaranteed empty.

### 2. Selecting a parent replays all of its descendants

`SessionExplorer.narrativeEntries()` walks the selected span *and every
descendant*, concatenating their entries. On the root that is the entire session
in a single scrolling pane — the exact behaviour reported. The structure the
projection computed is discarded at the moment of rendering.

### 3. The rich transcript renderers were replaced with thin ones

`SessionExplorer.StoryEntry` is a ~40-line re-implementation of what
`SessionDetail.tsx` already does in ~700 lines. Comparing them, the explorer path
silently drops:

| Preserved in `SessionDetail.tsx` (legacy path only) | Present in `SessionExplorer` |
|---|---|
| `ToolCard` — ANSI-rendered MUD output, model-vs-raw result toggle, `raw_chars` | `<pre>` of one string |
| `CtxChip` — tokens, context %, provider/model, cost, measured model latency | model name only |
| `InjectedContext` — collapsed `[here]` block, source, `changed` flag | not rendered |
| `StoreRollup` + `JournalDetail` — `⛁ wrote 11 · read 6`, expandable journal lines | not rendered |
| `ToolSpanRollup` — `⚙ 3 MUD calls · 240ms` folded with `after_tool` | not rendered |
| `LocalInferenceRow` — `◆ look_candidates · 23 scored → 3 kept`, unavailable state | not rendered |
| `IterationMarker` — per-iteration duration, MUD calls, cost | not rendered |
| `turn-strip` — turn N, iterations, tokens vs `max_turn_tokens` bar, limit reason | one line of text |
| `AutomaticGroup` / `AutomaticSummary` — `poll × 8, all empty`, auto-open on failure | not rendered |

The legacy renderers are still in the file but only reachable when
`!session.has_operations` — i.e. **instrumented sessions, the ones we care about,
get the poorer view.** This is the "all the information we had in transcript is
lost" complaint, literally.

## The design

**One document. The tree is the transcript.**

There is no navigation pane and no detail pane. Spans are collapsible section
headers rendered inline, and the rich transcript content renders *inside* the
span that produced it, in log order. Reading the page top to bottom is reading
the session. Collapsing a turn hides that turn's detail and nothing else. Timing
lives in a fixed right-hand gutter on every header row, so the waterfall's
answer ("where did 33.6s go") is available without leaving the story.

```text
┌──────────────────────────────────────────────────────┬─────────────────┬────────┐
│ ▾ ◆ Turn 1 · player task            [player] 9 iter  │ ███████████████ │ 33.6s  │
│   ▸ ⚙ Automatic context work · bootstrap  check × 1  │ █▏              │  1.9s  │
│   ▾ ↻ Iteration 1                          $0.0021   │  ██             │  1.9s  │
│     ▸ ⚙ Automatic context work · establish position  │  ▏              │   89ms │
│       ▾ ● Model call · claude-haiku-4-5              │  ▕██▏           │  1.7s  │
│         ┆ Context injected  world  [here] The Dark…▸ │                 │        │
│         ┆ 🧠 view request            12 msgs         │                 │        │
│         ┆ Plan   Good morning! I'll help you find…   │                 │        │
│         ┆ Assistant  (tool use — 1 call)             │                 │        │
│         ┆   3,360 in · 84 out · 1.7% ctx · $0.0021   │                 │        │
│     ▾ ⚙ move(west)                                   │    ▕▏           │   66ms │
│         ┆ ⚙ tbamud__move(direction: west)            │                 │        │
│         ┆ moved west → The Dark Alley                │                 │        │
│         ┆   ▸ raw MUD response          412 chars    │                 │        │
│         ┆ ⚙ 1 MUD call · 61ms   ⛁ wrote 4 · read 2 (7 journal lines)   │        │
│   ▾ ↻ Iteration 2                          $0.0038   │    ████         │  6.2s  │
│     …                                                                           │
│ ✓ Turn 1 · 9 iterations · 24,102 tok ████████░░ 40% of 60,000                    │
└──────────────────────────────────────────────────────┴─────────────────┴────────┘
```

Every row is on one shared time axis, so the 6.2s iteration is visibly wider than
the 1.9s one while you read them in order.

### Row policy per semantic kind

Not every span deserves the same weight. `semantic_kind` (already in the
contract) decides:

| kind | header | default state | body |
|---|---|---|---|
| `invoke_agent` | `Turn N · <task> task` + task chip, iteration count, cost | expanded | children |
| `iteration` | `Iteration N` + duration, MUD calls, cost (today's `IterationMarker`) | expanded | children + entries |
| `chat` | `Model call · <model>` + tokens/cost badges | expanded | injected context, request button, reasoning, plan, assistant, `CtxChip` |
| `execute_tool`, `initiator: model` | `<tool>(<args>)` | expanded | `ToolCard` + `ToolSpanRollup` |
| `execute_tool`, `initiator: hook` | folded into the parent hook's summary row | — | — |
| `hook` (`player_bootstrap`, `position_refresh`, `async_poll`, `room_survey`) | `Automatic context work · <label>` + `tallyTools` summary (`poll × 8, all empty`) | **collapsed** | children |
| `state`, `after_tool` | one summary line; `after_tool`'s rollup folds into the tool card above it | collapsed | children |
| `compaction`, `wrap_up` | labelled divider row | expanded | children |
| `internal` | visibly labelled `internal · <name>` | collapsed | children |

Two overrides on the collapsed defaults, carried over from the legacy
`isNotable` rule: **a failed call and a poll that actually returned something
force themselves and every ancestor open.** Being nested must never make a
problem harder to notice than being flat did.

Presets in a small toolbar: **Story** (default, table above) · **Timing** (every
span expanded, content collapsed — the pure waterfall) · **Everything**. Plus
`collapse all to turns`, which is the "I want to see the shape of the session"
view the current page cannot produce.

### Where the raw data goes

Each span body ends with a `▸ Technical details` disclosure: attributes, rollup,
trace/span/operation IDs, and the raw JSONL of its own events. That is everything
the current detail pane shows — demoted from *primary content* to *one click
away, in place*.

### What stays out of the story

The Summary tab (metrics, cost table, sparkline, automatic-work table) is
unchanged. The sticky session chrome and the "story pane owns its own scrolling"
rules from `fix_transcripts.md` amendments are unchanged and carry forward.

## Implementation

### Phase 1 — attach the story to the spans (writer)

This is the change without which no UI can work.

1. **Stamp every event.** Move `operation_stamp` from the two tool call sites
   into `write_log`, so `operation_id` / `operation` / `trigger` land on every
   event written inside a span. Explicitly excluded: `operation_start` and
   `operation_end`, which carry their own identity fields.
2. **Widen the `chat` span to the whole exchange.** Today it wraps only
   `@client.call` (`agent.rb:157`), which is why it owns nothing. Open it before
   `log_injected_context` and close it after `@logger.response(...)`, so the
   request payload, injected context, reasoning, plan and response are all inside
   it. This is also what `gen_ai` semconv means by a `chat` span.

   `work_attribution.md §2` deliberately excluded our own serialization from the
   measured model time, and that must not regress: measure `@client.call`
   separately inside the block and publish it as
   `gen_ai.client.operation.duration` / `boukensha.wire_ms` on the frame. The
   span then reports *both* "the exchange took 1.9s" and "1.73s of that was on
   the wire", instead of reporting one and losing the other.

   *Alternative if the widening proves invasive:* keep the narrow span and pass
   an explicit `operation_id:` on the surrounding log calls. Cheaper, but leaves
   the span's timing and its content describing different intervals — not
   recommended.
3. **Turn and iteration numbers on the spans.** `@logger.turn(...)` fires before
   the `invoke_agent` span opens, so the root row cannot title itself "Turn 1".
   Set `boukensha.turn.n` on the turn frame at open (it already gets
   `boukensha.turn.reason/iterations/tokens` at close), and confirm the
   `iteration` event's `n` is stamped onto its span.
4. **Fixture.** Freeze a sanitized copy of `20260726T171635Z-484352b5.jsonl`
   (33.6s, 9 iterations, bootstrap, room survey, wrap_up) as the API and web test
   fixture, plus a pre-stamping copy of the same shape for the legacy path.

### Phase 2 — make the projection serve reading order

`TraceProjection` gives a span its children and its entries as two unordered
lists. Reading order needs to know that the injected context came *before* the
chat child and the tool card came *after* it. Add:

```ruby
# ordered by log sequence; a child span is keyed by its operation_start seq
timeline: [ { kind: "entry", seq: 19 },
            { kind: "span",  id: "op_89ad02" },
            { kind: "entry", seq: 37 } ]
```

Also:

- `turn` and `iteration` numbers on `SessionSpan`, read from stamped events or
  span attributes, so the UI labels rows without walking entries.
- A synthetic **session root** owning pre-span events (`session_start`, the first
  `turn` marker, the opening user prompt) and anything in
  `orphan_entry_seqs`. Nothing in the log may be unreachable from the tree.
- Keep `narrowest_containing` strictly as the legacy path for unstamped logs, and
  fix its cost — it currently scans every span for every entry (O(n·m)). A single
  ordered sweep over `[start_seq, end_seq]` intervals replaces it.
- Verify `EntrySerializer` passes `operation_id` through for *every* entry type,
  not just the ones that have it today.

### Phase 3 — extract the rich renderers (no behaviour change)

Move out of `pages/SessionDetail.tsx` into `components/transcript/`, unchanged:
`ToolCard`, `ToolSpanRollup`, `InjectedContext`, `StoreRollup`, `JournalDetail`,
`LocalInferenceRow`, `IterationMarker`, `TurnStrip`, `AutomaticSummary`,
`shortToolName`, `tallyTools`, plus the `msg-*` cases of `TranscriptEntry` as
`EntryCard`. Existing CSS classes come along untouched — the visual language
already exists in `index.css` and is worth keeping.

`SessionDetail.tsx` drops from ~1500 lines to the page shell plus Summary.

### Phase 4 — build the story tree

`components/SessionStory.tsx`, replacing `SessionExplorer.tsx`:

```text
SessionStory
├── StoryToolbar            presets, collapse-to-turns, time scope
├── TimeAxis                shared origin/extent, session | turn | selection
└── SpanSection (recursive)
    ├── SpanHeader          caret · icon · status · title · chips · badges · bar · duration
    └── SpanBody            span.timeline.map → EntryCard | SpanSection
        └── TechnicalDetails
```

- **Expansion** is a `Set<string>` seeded by the row policy, held in a reducer,
  never rebuilt when SSE delivers an entry.
- **Selection** is highlight-and-scroll, not "what the detail pane shows".
  `?span=<operation_id>` expands ancestors, scrolls to the node, highlights it;
  `?op=` keeps redirecting to it. Manager/Errors deep links keep working.
- **Bars** share one origin across the whole session; a sub-pixel span still gets
  a visible marker at its true position, never a fake minimum width.
- **Keyboard**: ↑/↓ move between visible headers, ←/→ collapse/expand, `Enter`
  toggles, `0` resets time scope.
- **Live**: an `operation_start` inserts a running section, entries append to
  their owning span, `operation_end` closes and measures it. New content expands
  its ancestors; follow-scroll is inside the story container and pauses on manual
  navigation.
- Delete `narrativeEntries` — the descendant flattening is the bug, not a
  feature.

### Phase 5 — retire the old paths

- Make the story tree the only view for `has_operations` sessions.
- Legacy transcript stays for `!has_operations` sessions, now sharing the
  extracted renderers rather than owning them.
- `Waterfall.tsx` / `Waterfall.test.ts` are already dead code (nothing imports
  them since the explorer landed). Either delete, or revive as the **Timing**
  preset's implementation — decide during Phase 4, do not leave both.
- `spans.ts`: drop `isFrameworkSpan` (the transparent-span rule is replaced by
  explicit per-kind row policy — every span now gets a row), and drop
  `categoryFor`'s "unknown defaults to memory" in favour of `semantic_kind`.

## Tests

**Writer** — every content phase carries `operation_id`; the `chat` span's window
contains its own request and response; `boukensha.wire_ms` ≤ span duration; turn
number present on the `invoke_agent` span.

**Projection** — `timeline` interleaves entries and child spans in log order; a
`chat` span owns its injected context, request, plan and response; the session
root owns `session_start` and pre-span events; unstamped legacy logs still
resolve by window; out-of-order and missing ends behave as in `fix_transcripts.md`
(that section's contract tests stand).

**Component** — on the real fixture:
- The page opens on the story with Turn 1 expanded and iterations visible.
- Reading the DOM in order reproduces the session's event order.
- An `execute_tool move` node renders `ToolCard` with the model result, the raw
  MUD toggle, and the merged `⚙`/`⛁` rollup footer.
- A `chat` node renders injected context, the request button, plan/assistant, and
  a `CtxChip` carrying tokens, cost and measured model latency.
- Hook spans start collapsed showing `poll × 8, all empty`; a failed call inside
  one forces it and its ancestors open.
- `collapse all to turns` leaves exactly the root rows visible.
- Collapsing a branch never hides a selected node without expanding it back.
- An SSE `operation_end` closes a running section without resetting expansion.

## Acceptance

A reviewer opening `20260726T171635Z-484352b5` must be able to, without switching
views:

1. See `Turn 1 · player task` as one collapsible unit, and collapse the session
   down to its turns.
2. Read the session top to bottom in the order it happened.
3. See the 6.2s iteration is wider than the 1.9s one, on a shared axis.
4. Read exactly what the model was sent and what it answered, on the `chat` node
   itself.
5. See each tool call's arguments, the result the model received, the raw MUD
   bytes, and its MUD/DB cost.
6. Tell hook work from model-chosen work at a glance, with hook work folded away
   by default and unfolding itself when it failed.
7. Reach every attribute, rollup and ID from the node it belongs to.

Done when nothing in the old transcript is unreachable from the new one, and the
first click a reader makes is a caret rather than a search for where the story
went.

## Non-goals

- A separate navigation pane. The tree is the navigation.
- Sending prompt or tool content to OTLP. JSONL remains the content store.
- A charting library. CSS Grid and HTML buttons until measured otherwise.
- Virtualization before profiling; revisit past ~500 visible rows.
