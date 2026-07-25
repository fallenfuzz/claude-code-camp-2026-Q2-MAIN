## Logs vs Spans Research
You absolutely can instrument essentially all of your agent logs—and for agent systems, that can be a very good architecture. The distinction is less “logs vs traces” and more about what questions you want the data to answer.

Logs answer: “What happened?”

Imagine your agent emits:

Received room description
Extracted 6 candidate objects
Calling tool: move(direction=north)
Tool returned: Market Square
Updating world memory
Calling tool: inspect_room

Logs are independent events. They are great for debugging because you can dump arbitrary context:

{
  "event": "candidate_extraction",
  "room": "Market Square",
  "candidates": ["statue", "temple", "road"],
  "model": "bert-medium",
  "duration_ms": 18
}

But you have to reconstruct the causal structure afterward.

Traces/spans answer: “How did this happen?”

The same agent turn could naturally be:

TRACE: agent_turn #281
│
├── SPAN: build_context
│
├── SPAN: call_llm
│   └── model: claude-haiku
│
├── SPAN: tool.move
│   └── direction: north
│
├── SPAN: parse_room
│   ├── SPAN: bert_candidates
│   └── SPAN: summarize_room
│
└── SPAN: update_memory

Now you automatically know:

which operation caused another operation
how long each operation took
which agent turn they belong to
where an error occurred
what percentage of latency came from the model vs tools
whether an LLM/tool call happened three times in one turn

For agents, that structure is extremely useful.

So why not make every log a span?

Because a span represents an operation with a lifecycle, not simply an event.

Suppose your agent does this:

logger.info("Moving north")
logger.info("Player entered Market Square")
logger.info("Found 4 objects")
logger.info("Memory contains room already")
logger.info("Skipping summarization")

Those are observations. Making each one a span:

span Moving north
span Player entered Market Square
span Found 4 objects
span Memory contains room already
span Skipping summarization

doesn't really add anything. In fact, it makes traces noisy.

Instead:

SPAN move
  direction=north
  destination="Market Square"

  EVENT "room_entered"
  EVENT "objects_detected" count=4
  EVENT "memory_hit"

This is usually the sweet spot.

Think:

Span = verb/work

Event/log = something observed during that work

For your agent architecture, I'd probably instrument very aggressively, though.

Something like:

TRACE player_journey
│
├── TRACE agent_turn
│   ├── context.build
│   ├── llm.generate
│   │
│   ├── tool.move
│   │   ├── event: command_sent
│   │   ├── event: mud_response_received
│   │   └── parse.room
│   │       ├── bert.extract_candidates
│   │       └── room.summarize
│   │
│   └── memory.update
│
├── TRACE agent_turn
│   └── ...

And then attach lots of attributes/events:

agent.turn=291
agent.goal="Find bakery and show menu"

room.id=3012
room.name="Market Square"
room.visited=true

tool.name="move"
tool.argument.direction="north"

llm.model="claude-haiku"
llm.input_tokens=1240
llm.output_tokens=83

memory.rooms_known=37

You can also attach the actual log messages to the active span.

So your application can still do:

logger.info("Room already known; skipping inspection")

but your logging infrastructure attaches:

trace_id = abc123
span_id = def456

Then when looking at the trace:

tool.move [42ms]
    08:43:11.142 Room already known; skipping inspection

That is probably what you're imagining when you say “why wouldn't I want all my logs instrumented?”

And yes: I'd do that.

Just don't make every log line its own span.

A good mental model is:

                OBSERVABILITY

         ┌────────── TRACE ──────────┐
         │                            │
         │      SPAN: agent_turn      │
         │                            │
         │  logs/events               │
         │  logs/events               │
         │                            │
         │    SPAN: tool.move         │
         │      logs/events           │
         │      logs/events           │
         │                            │
         └────────────────────────────┘

So rather than logs OR instrumentation, I'd make your logging trace-aware:

Everything gets correlation IDs; meaningful operations become spans; interesting things occurring inside those operations become events/logs.

For an agent harness, that gives you extremely powerful debugging without turning the trace waterfall into thousands of meaningless spans.

## Technical Solutions
Based on our exiting code what would our session information look like if we aggresively instrumented?

### 0. What already exists, and what the ceiling of it is

The mechanism from `work_attribution.md` shipped and works. `Boukensha::Operation`
(`operation.rb:26`) is a thread-local frame stack; `Logger#operation`
(`logger.rb:62`) brackets a span, mints an id, records `parent_operation_id` from
the stack below it, and publishes a **counter delta** over the span's interval
from every registered meter (`logger.rb:345`). `Journal#write` (`journal.rb:150`)
and `Logger#tool_call`/`#tool_result` (`logger.rb:335`) stamp `operation_id` off
that same ambient stack, so no call site has to be handed one. The monitor reads
spans by id, not by proximity (`session_log/parser.rb:176-190`), and
`buildTranscriptTree` (`SessionDetail.tsx:299`) already nests recursively on
`parent_operation_id`.

So the plumbing is done. What is missing is **coverage**. Here is a real session
on disk — `.boukensha/profiles/Dummy/sessions/20260725T140507Z-dbf40d94.jsonl`,
one turn, 15 iterations, 296 events:

| span | count | total ms |
|---|---|---|
| `position_refresh` | 15 | 1143 |
| `state_render` | 15 | 0 |
| `async_poll` | 15 | 0 |
| `room_survey` | 3 | 1027 |
| `player_bootstrap` | 1 | 1943 |

Three facts about that table, all of them the same fact:

1. **`parent_operation_id` is null on 49 of 49 spans.** Every span is a root. The
   nesting machinery has never once nested, because the only things that open
   spans are `Mud::Hooks#during` (`mud/hooks.rb:655`) and `RoomSurvey#span`
   (`room_survey.rb:79`) — and hooks fire from the top of `Agent#run`'s loop,
   where nothing is open. `room_survey` inside `position_refresh` is the one real
   parent link the design anticipated, and it does not appear in this session
   because the survey ran from `before_model`'s refresh only on first visits.

2. **The session is 33.3s wall and 4.1s of span.** 88% of the session's elapsed
   time — 29.2s — happens outside every span. That is not idle: it is 16 model
   round-trips (64,060 input tokens, 1,370 output, $0.0709) and 868ms of the
   model's own tool calls. **The two most expensive things the agent does are the
   two things no span measures.**

3. **The model's own calls are attributed to nothing.** `tool_call` at
   `agent.rb:222` runs at top level, so `op=None`, and every store write and
   journal line that `after_tool` (`agent.rb:240`) produces downstream of it is
   unattributed too: 153 of 245 journal lines today carry no `operation_id`.

And one fact from outside the agent process: `correlation_id` is threaded through
`SessionPool#run_command` → `#log_exchange` → `ManagerLog#exchange`
(`session_pool.rb:66,125,141`, `manager_log.rb:32,49`), parsed
(`manager_log/parser.rb:40`), and *rendered* — `manager_record_serializer.rb:16`
emits `correlation: "exact" | "none"`. It is `null` in 105 of 105 records,
because `Dispatcher#call` never passes one (`dispatcher.rb:39,43,45`) and the MCP
wire has no slot for it. The consumer for the join exists; the join does not.

Aggressive instrumentation, then, is not new infrastructure. It is opening spans
in the four places `Agent` currently only writes markers, and carrying the ids
one process further.

---

### 1. The span tree

```
SESSION 20260725T140507Z-dbf40d94        ← trace id (exists: Logger#session_id)
│
├── SPAN turn                             ← NEW (Agent#run, agent.rb:32)
│   ├── SPAN compaction                   ← NEW, conditional (agent.rb:112)
│   ├── SPAN player_bootstrap             ← exists (before_turn)
│   │
│   ├── SPAN iteration  n=1               ← NEW (agent.rb:51)
│   │   ├── SPAN position_refresh         ← exists; re-parents for free
│   │   │   └── SPAN room_survey          ← exists
│   │   ├── SPAN state_render             ← exists
│   │   │   └── EVENT injected_context
│   │   ├── SPAN llm.generate             ← NEW (around agent.rb:68)
│   │   │   ├── EVENT request
│   │   │   ├── EVENT reasoning
│   │   │   └── EVENT response
│   │   ├── SPAN async_poll               ← exists (before_tools)
│   │   └── SPAN tool.move                ← NEW (agent.rb:213 loop body)
│   │       ├── EVENT tool_call / tool_result
│   │       ├── SPAN after_tool           ← NEW (agent.rb:240)
│   │       │   ├── EVENT context_transform
│   │       │   └── (journal CDC lines land here)
│   │       └── EVENT memory_conflict
│   │
│   ├── SPAN iteration  n=2 …
│   └── SPAN wrap_up                      ← NEW (agent.rb:125)
│       └── SPAN llm.generate
```

Five new span sites, all in `agent.rb`, all of the form
`@logger.operation("iteration") { ... }`. That is the whole change on the
producer side, and it is worth being explicit about what it does *not* require:

- **Hooks, `RoomSurvey`, `Store`, `Journal`: untouched.** `Operation.open`
  (`operation.rb:51`) reads `current_id` for its parent. The moment `Agent`
  opens an `iteration` span, all 45 existing hook spans acquire a correct
  `parent_operation_id` with no edit to the code that opens them. This is the
  ambient stack paying for itself.
- **The 153 unattributed journal lines fix themselves.** They are written from
  `capture_player`/`after_tool`, which will now be inside a `tool.<name>` span,
  so `Journal#write`'s existing `Operation.current_id` lookup starts returning
  one.
- **The parser: untouched.** It matches by id and treats
  `SPAN_ENVELOPE`-surplus keys on `operation_end` as the span's counter rollup
  (`parser.rb:298`), so new span names and new counters flow through without a
  schema change.

---

### 2. `llm.generate`: measured, not inferred

Today model latency is `entry.duration_ms = entry.dt_ms` (`parser.rb:174`) — the
gap from the previous emitted entry to the `response`. The comment says that is
"exactly" model latency. It is not, and the error is systematic:

```ruby
@logger.prompt(...)                                  # serialize 15 messages
@logger.request(payload: @builder.to_api_payload)    # serialize 64k tokens of
                                                     #   messages + tool schemas
response = @client.call(**call_opts)                 # ← the only part that is latency
parsed   = @builder.parse_response(response)
record_usage(response); log_reasoning(...)
@logger.plan(...); @logger.response(...)             # ← dt_ms measured to here
```

Everything above and below the one line that matters is charged to the model.
With 64,060 input tokens per session round-tripped through `JSON.generate`
twice, that is not a rounding error, and it is the number the cost/latency
tables in `Timing#summary` are built on.

The span makes it a measurement:

```ruby
# agent.rb, replacing the bare @client.call
response = @logger.operation("llm.generate") do |frame|
  frame.set(provider: @builder.backend&.provider_name, model: @builder.backend&.model,
            iteration: @iteration, tools_advertised: @context.advertised_tools.size,
            context_tokens: @context.current_tokens)
  @client.call(**call_opts)
end
```

`frame.set` is the one addition to `Operation` that is not just a call site:
`Frame` is a 4-field `Struct` (`operation.rb:33`) with nowhere to hang a fact
discovered *during* the span. Give it an attribute bag that `Logger#operation`
merges into `operation_end` alongside the counter delta — same envelope, same
parser path, no new event type. That is what makes `room.id`, `room.visited`,
`memory.rooms_known` and the rest of §5 expressible at all.

Two things this immediately answers that the file cannot answer today: how much
of a turn is inference versus our own serialization overhead, and what
`wrap_up`'s terminal call cost — it runs outside the loop, emits no `iteration`
marker, and is currently indistinguishable from the last real iteration.

---

### 3. Carry the ids across the MCP boundary

The MUD round trip is logged twice on two sides of a process boundary that
nothing spans: `tool_result` with `duration_ms` in the session log, and a
`ManagerLog` record with `elapsed_ms`, `sent`, `received`, `bytes_in` in the
manager log — plus n `TelnetLog` records underneath it. Joining them today is a
timestamp heuristic in `diff/telnet_manager.rb`.

MCP has the slot for this: `_meta` on `tools/call` params. It is spec-legal,
additive, and ignored by any server that does not read it.

```ruby
# boukensha/mcp/client.rb:58
def call_tool(name, arguments = {}, meta: nil)
  params = { "name" => name.to_s, "arguments" => arguments }
  params["_meta"] = meta if meta && !meta.empty?
  res = request("tools/call", params)
  ...
end

# tools/mcp.rb:78 — the block that becomes the boukensha tool
client.call_tool(remote, kwargs.transform_keys(&:to_s), meta: Boukensha::Operation.wire_meta)
#   => { "boukensha/session_id" => "20260725T…", "boukensha/operation_id" => "op_52ac7e" }
```

Server side, `Server#call_tool` (`mcp/server.rb:98`) reads `params["_meta"]` and
`Dispatcher#call` forwards `correlation_id:` into the `run_command`/`run_raw`/
`poll` calls that already accept it (`dispatcher.rb:39,43,45`). Stamp the same id
on the `TelnetLog` records written inside that exchange and the whole stack
joins.

Nothing downstream changes. `manager_record_serializer.rb:16` starts reporting
`correlation: "exact"` instead of `"none"`, which is what it was written to do.

The honest caveat: `operation_id` alone is not unique per *call* — a
`room_survey` span makes four MUD calls. Send `call_id` too where there is one
(`Logger#tool_call` mints it, `logger.rb:238`), and accept that hook-initiated
calls made inside a span but outside a `tool_call` correlate at span
granularity. Span-exact beats timestamp-adjacent either way.

---

### 4. The discipline: what stays an event

The research section's rule — *span = verb/work, event = something observed
during that work* — needs one amendment to survive contact with this codebase,
because the obvious reading of it is wrong here. `state_render` is 15 spans
totalling **0ms**, and `async_poll` is 15 more, also 0ms. By a latency
criterion, 30 of the 49 spans are events wearing span costume and should be
demoted.

Keep both. The criterion is not *is it slow*, it is **does it own resource
spend that something else would otherwise be charged for**. `async_poll` makes a
real MUD round trip (`mud_calls` delta); `state_render` reads memory
(`db_reads` delta). A 0ms span that owns two DB reads is doing exactly the job
spans exist for. This is also the criterion that keeps the tree from exploding:

**Events, not spans** — no lifecycle, no owned spend:

| observation | today | belongs as |
|---|---|---|
| iteration/turn markers | `phase: "iteration"` | keep the marker, add the span around it |
| `limit_reached` | event | event, on the `turn` span |
| memory hit / "room already known" | not logged | `EVENT memory_hit` on the enclosing span |
| `[ Exits: ]` uncoloured warning | `$stderr` only | `EVENT parse_degraded` on `room_survey` |
| turn policy computed | not logged | `EVENT turn_policy` (`mud/hooks.rb:compute_turn_policy`) |
| permission denial | not logged | `EVENT permission_denied` on the `tool.*` span |
| `RoomParser` string work | not logged | **stays unlogged** — `work_attribution.md` §5 |

At ~150 spans and ~450 events per turn the write cost is worth naming: every
`write_log` flushes (`logger.rb:371`). It is still negligible next to the two
`request` payloads per iteration, which are kilobytes each — this session is
296 events and the `request` events dominate the file by an order of magnitude.

---

### 5. Attributes worth stamping

`frame.set` from §2 makes these expressible. Most of the values are already
computed somewhere and thrown away:

| attribute | source | status |
|---|---|---|
| `agent.turn`, `agent.iteration` | `Agent#@iteration` | exists as a marker; not on spans |
| `agent.goal` | task prompt | available at `Tasks::Player` |
| `room.id`, `room.name` | `Hooks#@current_room_id` | held in memory, never logged |
| `room.visited` | `Store#room_seen?` | decides whether the survey runs; not recorded |
| `tool.name`, `tool.args.*` | `tool_call` event | exists |
| `llm.provider/model/tokens/cost` | `execution_metadata` (`logger.rb:415`) | on `response`; wants to be on the span |
| `memory.rooms_known` | `Store#counts` | queried for the knowledge tab only |
| `mud.bytes_in` | `ManagerLog` | other process — §3 unlocks it |
| `player.hp/level/gold` | journal `stat` stream | correct where it is; do **not** duplicate |

The last row is the one to hold the line on. One writer per fact: the journal
owns time-series player state, the session log owns spans and counts, and they
join on `operation_id`. Copying hp onto every span is how the two logs start
disagreeing.

---

### 6. What one iteration looks like, before and after

Today (real, elided to the shape):

```
operation_start  position_refresh  trig=before_model  id=op_e377e5  parent=None
operation_end    position_refresh  1ms
operation_start  state_render      trig=before_model  id=op_9b69fd  parent=None
operation_end    state_render      0ms
injected_context / prompt / request
response         model=claude-haiku-4-5 in=3474 out=83 cost=0.003889
operation_start  async_poll        trig=before_tools  id=op_41f34d  parent=None
operation_end    async_poll        0ms
tool_call        tbamud__move  init=model  op=None
tool_result      tbamud__move  init=model  op=None  dur=23
context_transform
```

Eleven lines, four unrelated roots, one 3.5s hole where the model call was, and
a `move` belonging to nothing. After:

```
operation_start  iteration          id=op_a1  parent=op_turn      n=2
  operation_start  position_refresh id=op_a2  parent=op_a1
  operation_end    position_refresh 1ms   db_reads=3 journal_lines=0
  operation_start  state_render     id=op_a3  parent=op_a1
  operation_end    state_render     0ms   db_reads=4
  operation_start  llm.generate     id=op_a4  parent=op_a1
    request / reasoning / response
  operation_end    llm.generate     3412ms  model=claude-haiku-4-5
                                    input_tokens=3474 output_tokens=83
                                    cost_usd=0.003889 stop_reason=tool_use
  operation_start  async_poll       id=op_a5  parent=op_a1
  operation_end    async_poll       0ms   mud_calls=1 mud_ms=0
  operation_start  tool.move        id=op_a6  parent=op_a1  direction=west
    tool_call / tool_result  dur=23
    operation_start  after_tool     id=op_a7  parent=op_a6
      context_transform
    operation_end    after_tool     4ms  db_writes=3 journal_lines=5 room_id=3014
  operation_end    tool.move        29ms  mud_calls=1 mud_ms=23
operation_end    iteration          3448ms  mud_calls=2 mud_ms=23 db_reads=7
                                    db_writes=3 journal_lines=5 inference_calls=0
                                    input_tokens=3474 cost_usd=0.003889
```

The iteration now closes with a line that says what the iteration cost, in every
currency, and the 3.4s is on the operation that actually spent it. Roll the same
delta up one level and `turn` reports the session: 33.3s, $0.0709, 43 MUD calls,
245 journal lines — derived from spans rather than summed by the reader.

---

### 7. Consumer changes

Mostly free, with three real edits:

1. **`Timing#summary`** (`timing.rb`) — `model_ms` reads the `llm.generate` span
   duration instead of `dt_ms`; keep the `dt_ms` path as the fallback for logs
   already on disk, exactly as the parser keeps its adjacency fold. Add
   `self_ms` (duration minus children) so a `turn` span's 33s does not read as
   33s of its own work.
2. **`isAutomatic`** (`SessionDetail.tsx:284`) — currently `initiator === "hook"`.
   It must not start swallowing the new spans: `tool.move` at `initiator: "model"`
   and `iteration` are first-class narrative, not `AutomaticWorkTable` rows.
   Worth a test, because the failure is silent — the model's own actions quietly
   vanish into a collapsed group.
3. **`OPERATION_LABELS`** (`SessionDetail.tsx:553`) — add `turn`, `iteration`,
   `llm.generate` ("model call"), `after_tool` ("record outcome"), `wrap_up`.
   The `?? operation.replace(/_/g, " ")` fallback means missing entries degrade
   rather than break.

`unclosed_operations` (`parser.rb:481`) gets more sensitive with an outer `turn`
span — a killed process now leaves 3-4 unclosed spans instead of 0-1. That is
more accurate, not noisier, but the badge copy ("N incomplete") should probably
report the deepest unclosed span's name.

---

### 8. What this deliberately does not do

- **No OpenTelemetry.** The span model here is OTel-shaped on purpose — ids,
  parents, attributes, events, duration — so an exporter is a later mapping
  exercise, not a rewrite. But adding an SDK, a collector and a wire protocol
  buys nothing that `.boukensha/*.jsonl` + `mud_monitor` does not already do,
  and it costs the property that every layer of this system is readable with
  `jq` and diffable in git.
- **No sampling.** One agent, one player, ~300 events a turn. Sampling is a
  solution to a volume problem nobody has, and it makes the one trace you want
  to read the one that got dropped.
- **No player-journey trace above `session`.** The `session_id` is the trace id.
  Stitching sessions into a cross-restart journey needs a durable id in
  `profile.yaml` and a story for what a journey even is; it is a separate plan.
- **No duplication of journal content into spans.** §5's last row.
- **No spans in `mud_manager`.** It gets the *ids* (§3) and keeps its flat
  `ManagerLog`/`TelnetLog` shape. Two log formats agreeing on a correlation key
  is the cheap version of a distributed trace and it is enough here.

---

### Implementation order

Each step is independently observable in the raw JSONL before the next lands.

1. **`Frame#set` + attribute merge into `operation_end`** — unblocks everything
   in §2 and §5; no behaviour change on its own.
2. **`iteration` and `turn` spans** (`agent.rb`) — this alone re-parents all 45
   existing hook spans and is the largest single readability win. Verify
   `parent_operation_id` stops being null.
3. **`llm.generate`** — the 88%. Land it before touching `Timing`, so the
   before/after on `model_ms` is measurable against the same session.
4. **`tool.<name>` + `after_tool` spans** — attributes the model's own calls and
   drives the unattributed journal lines toward zero.
5. **MCP `_meta` correlation** (§3) — crosses a process boundary, so it is the
   one step with a compatibility question (an older server ignoring `_meta`
   must keep working); land it after the intra-process tree is trusted.
6. **`Timing`, `isAutomatic`, labels** — renderers over all of the above.

### Acceptance criteria

- `parent_operation_id` is non-null on every span except `turn`.
- Sum of root-span durations is within a few percent of session wall time; the
  29.2s unspanned gap is gone.
- `model_ms` from `llm.generate` is *lower* than today's `dt_ms`-derived figure
  (the difference is our own serialization, and it should be visible).
- Journal lines with no `operation_id`: 153 → 0 for lines written during a turn.
  Lines written outside any turn (a bare `check` at the REPL) legitimately stay
  unattributed.
- `ManagerLog` records report `correlation: "exact"` for every exchange
  originating in a spanned tool call.
- A session log written before this change still renders — the parser's
  adjacency fold and `Timing`'s `dt_ms` fallback both stay in place.

## Web User Experience
right now we have our own custom session view driven mostly by logs.
How will the UX change this page.

### 9. The trap: spans are data, not automatically UI

`SessionDetail.tsx` today has a spine and a periphery, and that is why it reads.
The spine is the model's narrative at zero indent — `plan`, `assistant`,
`ToolCard`, `InjectedContext`. The periphery is framework work, folded into
`AutomaticGroup` (collapsed by default, `SessionDetail.tsx:589`) and summarised
one line per operation. A human scrolls the spine and opens the periphery when
something looks wrong.

Now look at what §1 does to that if nothing else changes. `TranscriptNodes`
(`:456`) dispatches `kind === "op"` → `OperationGroup` **unconditionally**, and
`OperationGroup` defaults `open` to `false` (`:678`). Add `turn` → `iteration`
→ `llm.generate` / `tool.move` → `after_tool` and every line in the transcript
acquires three to five span ancestors, each a collapsed caret. The page becomes
one collapsed row labelled "turn". Expand it: fifteen rows labelled "iteration".
The narrative a human reads is now four indents down, behind carets, and the
`AutomaticGroup` that exists to keep framework work out of the way is nested
*inside* the thing it was hiding from.

That is not a rendering bug to fix afterwards — it is the default behaviour of
the tree builder we already shipped, and it is why the instrumentation work and
the UX work cannot ship in that order.

**The rule: a span becomes a UI group only when it is work the reader would
otherwise mistake for something else.** That was always the actual justification
for `OperationGroup` — a hook's 1.9s `score` reading as model latency. It is true
of `room_survey` and false of `iteration`: nobody mistakes an iteration for
anything, because the transcript is already ordered by it. Every other new span
**enriches chrome that already exists** and renders no box of its own.

### 10. Where each span lands

| span | UI treatment | existing component |
|---|---|---|
| `turn` | `turn-strip` gains measured duration + spend split | `:966` |
| `iteration` | `iteration-marker` becomes a summary line: duration, cost, MUD calls | `:472` |
| `llm.generate` | **measured** latency on the chip that already shows model/tokens/cost | `CtxChip` |
| `tool.<name>` | the `StoreRollup` footer that today only spans get | `ToolCard` `:1099` |
| `after_tool` | merged into its parent tool card's rollup — never its own box | — |
| `compaction`, `wrap_up` | existing `divider-compaction` / `turn-strip` | `:932`, `:966` |
| the 5 hook spans | unchanged `OperationGroup` inside `AutomaticGroup` | `:677` |

Zero new indent levels. Zero new collapsibles. Four pieces of chrome learn to
display a rollup they are handed, and the most important number in the whole plan
— the 88%, the model latency nobody was measuring — arrives as **one figure on a
chip that is already on screen**.

The one piece of real new tree logic is an inline-span set in
`buildTranscriptTree`: a span not in `GROUPED_SPANS` is **transparent** — its
children hoist into its parent's child list and its rollup is attached to a named
render target (the iteration marker, the tool card) rather than drawing a group.
Keeping the allowlist in the web layer, not the producer, is deliberate: the log
should record the true tree, and which parts of a true tree are worth a box is a
question about reading, which changes far more often than the instrumentation
does.

Two specific hazards while doing it:

- **`isAutomatic` (`:284`) must not widen.** It is
  `initiator === "hook" || type === "local_inference"`. A `tool.move` span at
  `initiator: "model"` must stay on the spine; if it ever falls into
  `AutomaticGroup`, the model's own actions silently vanish into a collapsed
  group labelled "Automatic context work". Silent, so it needs a test.
- **`iterationMarkerSeqs` (`:384`) anchors by seq.** It already skips span
  brackets when picking an anchor (`:395`), which is right. But an `iteration`
  span's rollup has to reach the marker it belongs to, and the marker is anchored
  to a *different* entry. Join on iteration number, not adjacency — the same
  mistake, at the UI layer, that spans were introduced to stop making.

### 11. The view that earns it: the turn waterfall

Everything above makes the existing page honest. None of it answers the question
§0 raised — *where did the 33 seconds go* — because a transcript is ordered by
sequence, not by duration, and 88% of the time was in gaps between lines. That
needs a second view over the same tree.

**Form, chosen before anything else.** The job is magnitude *plus* causal
structure over time: which work contained which, in what order, for how long. A
pie or a stacked bar loses the sequence and the nesting, which are the content.
So: a horizontal span timeline — one row per span, x = elapsed ms since turn
start, bar width ∝ duration, row indent = span depth. The headline magnitudes are
*not* a chart at all: three hero stat tiles above it (`28.4s inference · 3.9s MUD
· 0.9s memory`) answer the question in one glance, and the timeline answers "and
in what shape".

**One axis.** x is milliseconds. Tokens and cost do not get a second y-scale —
they live in the tooltip and the table. (A dual-axis "latency vs cost per
iteration" chart is the obvious temptation here and it is the single most common
chart mistake; if we want cost-per-iteration it is its own small multiple against
the same x.)

**Colour, assigned by job — categorical, fixed slots, never generated.** The
identity being encoded is *what kind of work*, and the app already owns a glyph
vocabulary for exactly these four things, which gives us secondary encoding free:

| category | glyph | light | dark |
|---|---|---|---|
| model inference (`llm.generate`) | 🧠 | `#2a78d6` | `#3987e5` |
| MUD round trip (`tool.*`, hook calls) | ⚙ | `#eb6834` | `#d95926` |
| memory / store (`state_render`, `after_tool`) | ⛁ | `#1baf7a` | `#199e70` |
| local inference (ONNX) | ◆ | neutral + texture | neutral + texture |

Three hues, and the cap is **computed, not preferred**. Validated against this
app's own chart surface (`--panel`: `#ffffff` light, `#1c1f24` dark), all pairs,
both modes:

```
light  CVD worst  ΔE 9.2 (deutan)  ·  normal-vision worst ΔE 24.0   → PASS
dark   CVD worst  ΔE 9.4 (deutan)  ·  normal-vision worst ΔE 20.9   → PASS
```

A fourth hue for local inference fails outright in both modes — yellow against
orange gives normal-vision ΔE 13.7 light (floor 15) and CVD ΔE 4.8 dark (floor
6). Hence local inference gets the neutral-plus-glyph treatment rather than a
colour: it is 13ms across 3 calls in the sample session, so it is the right
category to demote. Light mode carries one contrast WARN — aqua at 2.82:1 on
white — which obliges relief: every row is directly labelled with its span name
and the table view below is mandatory, not optional. Both are in the design
already, so the warning is discharged rather than dismissed.

**Do not reuse `taskHue` for this** (`TaskChip.tsx:7`). It hashes a string to a
hue, which is fine for its actual job — an unknown task getting a stable
arbitrary colour beats getting none — and wrong for a fixed four-category
encoding, where generated hues can land adjacent by accident and change meaning
when a category is renamed. Categorical slots are assigned in fixed order or they
are not categorical.

**Marks.** 2px surface gap between adjacent bars so abutting spans stay
countable. A span bar is *not* baseline-anchored — both ends carry data — so
round both ends at 4px rather than only the far end. Self-time versus child-time
reads as a lighter inset within the same hue, never as a second colour: it is the
same category of work, and the 88% finding is exactly a self-time story. Grid and
axis recessive (`--border`, `--muted`).

**Hover ships by default.** Per-bar tooltip: span name, duration, self-time,
counter rollup, and for `llm.generate` the model, tokens and cost. Click scrolls
the transcript to the span's first entry — `entry.seq` is already the anchor the
live-stream code keys on, so the two views cross-link with no new identifier.

**Dark mode selected, not flipped.** `index.css:22` already has a
`prefers-color-scheme` block; the dark column above is stepped for `#1c1f24`, not
derived from the light values.

**Legend always present** (four categories), and identity is never colour-alone
because each carries its glyph.

**A table view exists** — required by the contrast relief, and useful on its own:
span, depth, duration, self-time, category, counters; sortable by duration. It is
the copyable form, the accessible form, and the honest answer to "what did this
turn cost".

**No charting library.** `Sparkline.tsx` is 50 lines of hand-rolled inline SVG;
the waterfall follows it. A dependency here would buy layout we can write and
cost us the property that the whole monitor builds from nothing.

### 12. What the new data makes wrong, and must be fixed with it

- **The `statstrip` Work row (`:219`) gets worse before it gets better.**
  `session.operations` goes 49 → ~150, and "150 operations" is a less meaningful
  number than "49" was. The count was always a proxy for *did we instrument
  anything*, which `has_operations` already answers. Replace it with the three
  magnitudes from §11's hero tiles.
- **The duration pill has no dark mode.** `format.ts:107` ramps to
  `.duration-slow`, which hardcodes `#a15c00` on `#fff4e5` (`index.css:855`) with
  no override in the dark block. Today that lands on a handful of rows; with span
  durations on the iteration marker, every tool card and every chip it will be
  all over a dark session. Fix it while touching the ramp.
- **`AutomaticWorkTable`'s caption becomes true.** It already prints
  `{automatic} automatic vs {model_ms} inference` (`:1170`) — with `model_ms`
  sourced from the `llm.generate` span instead of `dt_ms`, the comparison it was
  written to make is finally the comparison it makes.
- **The Manager page can finally join.** `types.ts:379` already declares
  `correlation: "exact" | "inferred" | "none"` and **nothing renders it** — dead
  because it is always `"none"`. Once §3 lands, add the column, and make an
  `"exact"` value a link back to `sessions/:id` anchored on the span. That is
  cross-log navigation the three logs have never had: from a raw telnet byte
  count to the operation that caused it.

### 13. Live sessions

A span is two events with the work in between, so a live session always has
open spans — and `OperationGroup` renders a missing `operation_end` as
`incomplete` (`:699`, "the run ended mid-operation"), which during a live session
is simply false. With one hook span at a time that was rare enough to ignore;
with a `turn` span open for the entire session it is permanent and wrong.

Gate the label on `session.live`: open span → "running", with an open-ended bar
in the waterfall and no duration figure. The same applies to the `statstrip`'s
`unclosed_operations` badge (`:228`). This is a real behaviour change in the
copy, not a cosmetic one — it is the difference between a page that says the
process crashed and a page that says it is working.

### 14. UX non-goals

- **No flamegraph or icicle.** Same data, wrong question: those aggregate hot
  paths across many traces. There is one trace per turn here, and the sequence
  is the content.
- **No new route.** The waterfall is a toggle on `SessionDetail`
  (`Transcript | Waterfall`), not a nav item. It is a view of one session, and
  `Layout.tsx`'s nav implies a section.
- **No spans in the waterfall for events.** Events are tooltip and transcript
  content. A timeline row is a thing with a duration.
- **No per-span colour by task.** Category, not task — `taskHue` stays where it
  is.
- **No second full transcript inside the waterfall.** Click-to-scroll, one
  narrative.

### UX acceptance criteria

- The transcript's indent depth is unchanged from today for the model's
  narrative: `plan`, `assistant` and model `ToolCard`s still render at the same
  level they do now.
- Measured model latency is visible on an assistant row without opening anything.
- The three-hue palette passes `validate_palette.js --pairs all` in both modes
  against `--panel`, and the light-mode contrast WARN is discharged by visible
  row labels plus the table view.
- Every waterfall category is distinguishable with colour removed (glyph +
  label + table).
- A live session never shows the word "incomplete" for a span that is merely
  still running.
- `Manager` shows `correlation: exact` and it links to the originating span.