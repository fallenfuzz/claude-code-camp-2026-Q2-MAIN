# Boukensha OpenTelemetry observability plan

## Outcome

Make `week2_capable/boukensha` emit real OpenTelemetry traces over OTLP so a
session can be inspected in Jaeger, Grafana Tempo, Honeycomb, Datadog, New
Relic, or another OTLP-capable backend without replacing the existing JSONL
session log or `mud_monitor`.

The first implementation should treat OpenTelemetry as an optional second sink:

```text
agent / hooks / tools
        |
        v
  Boukensha::Telemetry
    |             |
    v             v
existing JSONL   OpenTelemetry SDK --OTLP--> local Collector --> backend(s)
```

This is intentionally a dual-write migration, not a JSONL-to-OTEL converter.
The in-process SDK has the actual span lifetime, nesting, errors, and context;
reconstructing those later from pairs of JSONL records would be less reliable.
JSONL remains the durable, detailed replay/audit format, while OTEL becomes the
portable operational view.

## Current state and gaps

The implementation already has most of the concepts needed for useful traces:

- `Logger#operation` emits nested `operation_start`/`operation_end` records.
- `Operation` maintains an ambient per-thread stack and parent IDs.
- `Agent` creates spans for turns, iterations, `llm.generate`, wrap-up,
  compaction, and model-selected tools.
- hooks create spans for bootstrap, refresh, polling, surveys, and other
  framework work.
- tool calls/results have a stable `call_id`, initiator, duration, and outcome.
- responses contain provider, model, token usage, and estimated cost.
- session, task, operation, and MCP metadata already provide correlation.

However, those records only resemble telemetry. Their IDs are not W3C
trace/span IDs, no OTLP exporter is configured, errors are not recorded as OTEL
exceptions/status, and the MCP child process receives Boukensha IDs rather than
standard trace context. Existing OTEL tools therefore cannot query or visualize
them directly.

## Design decisions

1. **Traces first.** OpenTelemetry Ruby traces are stable; Ruby metrics and logs
   are still under development as of July 2026. Ship useful traces first, derive
   span metrics in the Collector/backend, and keep JSONL as the log signal.
2. **One top-level turn is one trace; one session groups traces.** A Boukensha
   session can contain multiple top-level turns, so do not create a
   session-long root span. Start a new trace for each top-level `Agent#run` and
   attach the stable `session_id` to every span in that trace. Delegated agents
   remain child `invoke_agent` spans in the initiating turn's trace. The
   existing JSONL file can continue to cover the whole session.
3. **One existing operation is one OTEL span.** Reuse the current operation
   boundaries rather than adding a second set of wrappers around the agent.
4. **OTEL IDs become correlation fields, not replacements.** Continue emitting
   `session_id`, `operation_id`, and `call_id`, and add `trace_id` and `span_id`
   to JSONL. Existing readers continue to work.
5. **Content is opt-in.** Prompts, tool arguments/results, reasoning, room text,
   and credentials can be sensitive and high-cardinality. Default OTEL
   attributes contain metadata only; JSONL retains current detail. A separate
   explicit setting may add content after redaction and truncation.
6. **OTEL failure never breaks the agent.** Disabled or misconfigured telemetry
   falls back to a no-op implementation. Export is batched, bounded, and flushed
   at shutdown.
7. **Use standard semantic conventions where they fit.** Keep
   `boukensha.*` attributes for domain facts with no standard equivalent.
   Because GenAI conventions are still evolving, pin and document the
   convention version used by the implementation.
8. **Keep the portable model vendor-neutral.** Use the emerging OpenTelemetry
   GenAI operations and attributes (`invoke_agent`, `chat`, `execute_tool`,
   agent identity, model, tool-call, and usage data) as the primary contract.
   Backends such as Langfuse may add useful observation types, session fields,
   inputs/outputs, scores, and evaluation features; treat those as optional
   enrichment rather than the core trace model.

## Target trace model

```text
session_id=<stable Boukensha session>
├── trace: top-level turn 1
│   └── invoke_agent player                (one top-level Agent#run)
│       ├── boukensha.compaction
│       ├── boukensha.iteration
│       │   ├── hook operations / room survey
│       │   │   └── execute_tool <tool>
│       │   ├── chat <model>               (provider request)
│       │   └── execute_tool <tool>        (model-selected tool)
│       ├── invoke_agent <delegated task>  (same trace)
│       └── boukensha.wrap_up
│           └── chat <model>
└── trace: top-level turn 2
    └── invoke_agent player
        └── ...
```

Top-level turns are correlated by `session_id`, not by OTEL parentage. A later
turn must start a new root context rather than becoming a child of the previous
turn. This keeps traces bounded and makes each turn independently queryable and
evaluable while preserving session replay.

Mapping from existing data:

| Current concept | OTEL representation |
| --- | --- |
| session | stable `session.id`/`boukensha.session_id` grouping multiple traces |
| top-level turn | one trace rooted at an `invoke_agent` span |
| `Logger#operation` | nested internal span |
| `llm.generate` | GenAI client span, operation `chat` or provider-equivalent |
| `tool.<name>` | GenAI `execute_tool` span |
| `task_start` / `task_end` | `invoke_agent` span when it represents a delegated agent; otherwise span events |
| turn/iteration/limit/compaction | spans or events on the nearest owning span |
| prompt/request/response/reasoning | span events; content excluded by default |
| `local_inference` | internal span/event with model, availability, duration |
| counters on `operation_end` | numeric attributes on the completed span |
| exception / `ok: false` | recorded exception, error status, `error.type` |
| `session_id`, task/depth, trigger | `boukensha.*` span attributes |
| token usage | GenAI usage attributes on the model span |
| estimated cost | `boukensha.cost.usd` on the model span |

Do not put `operation_id`, tool arguments, results, prompt text, room names, or
raw model payloads into resource attributes: they are per-operation or
high-cardinality data. Resource attributes should be limited to stable process
identity such as:

- `service.name=boukensha`
- `service.version`
- `deployment.environment.name`
- `telemetry.sdk.*` (provided by the SDK)
- optional low-cardinality `boukensha.profile` only if profile names are safe

## Implementation plan

### Phase 0 — lock the contract with a fixture

Before changing runtime code:

- Select one deterministic test session containing at least two top-level
  turns, a successful model call, a failed tool, a hook-initiated tool, a
  model-initiated tool, a delegated task, and a limit-triggered wrap-up.
- Document the expected trace boundary for each turn, span trees, shared
  session attributes, required attributes, error state, and JSONL correlation
  fields.
- Pin the OpenTelemetry semantic-convention version in a short compatibility
  note. Do not silently change attribute names on gem upgrades.

This fixture becomes the acceptance contract for both JSONL and OTLP.

### Phase 1 — add an optional telemetry boundary

Add:

- `lib/boukensha/telemetry.rb`: small framework-owned interface.
- `lib/boukensha/telemetry/noop.rb`: zero-dependency/no-op behavior.
- `lib/boukensha/telemetry/open_telemetry.rb`: SDK adapter and OTLP setup.

The interface should own:

- session identity and top-level turn trace start/end;
- `in_span(name, kind:, attributes:) { |span| ... }`;
- event emission;
- exception/status recording;
- current `trace_id`, `span_id`, and propagation carrier;
- `force_flush` and shutdown.

Keep OpenTelemetry classes out of `Agent`, hooks, tasks, and MUD code. This
gives tests a recording adapter and prevents vendor or SDK details from leaking
through the codebase.

Add the trace packages to the gemspec, preferably behind an install extra if
the gem's packaging permits it:

- `opentelemetry-api`
- `opentelemetry-sdk`
- `opentelemetry-exporter-otlp`

Avoid `opentelemetry-instrumentation-all` initially. Boukensha needs precise
agent/tool boundaries, and enabling every matching library risks noisy or
duplicate HTTP spans. Add a specific HTTP instrumentation later only if its
child network spans add value beneath `llm.generate`.

### Phase 2 — configuration and bootstrap

Support standard environment configuration rather than inventing equivalents:

- `OTEL_SERVICE_NAME` (default `boukensha`)
- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_EXPORTER_OTLP_HEADERS`
- `OTEL_EXPORTER_OTLP_PROTOCOL`
- `OTEL_TRACES_EXPORTER`
- `OTEL_RESOURCE_ATTRIBUTES`
- `OTEL_PROPAGATORS`

Add only Boukensha-specific switches:

```yaml
observability:
  otel:
    enabled: false
    capture_content: false
    content_max_bytes: 4096
```

Environment variables should override YAML for deployability:

- `BOUKENSHA_OTEL_ENABLED`
- `BOUKENSHA_OTEL_CAPTURE_CONTENT`
- `BOUKENSHA_OTEL_CONTENT_MAX_BYTES`

`enabled: false` must load no SDK and behave exactly as today. If enabled,
configure the SDK once at process startup, before creating `Logger`. Reject
invalid booleans/config clearly, but degrade exporter/network failures to a
single warning rather than failing an agent turn.

### Phase 3 — make `Logger#operation` the bridge

Instrument `Logger#operation`, since it is already the single authoritative
span boundary:

1. Open an OTEL span before `Operation.open`.
2. Store OTEL trace/span IDs on `Operation::Frame`.
3. Emit the existing `operation_start` JSONL record with those IDs.
4. Run the block in the OTEL context so nested operations parent correctly.
5. On success, add final frame attributes/counter deltas.
6. On failure, record the exception, set error status and `error.type`, then
   preserve the existing re-raise behavior.
7. End the OTEL span and emit the existing `operation_end`.

Extend `Operation::Frame` rather than maintaining another unrelated ambient
stack. Move from `Thread.current` to fiber-aware context, or explicitly bridge
the OpenTelemetry context, before introducing concurrent/fiber-based agent
execution. Add a regression test proving two concurrent runs do not cross-link.

Update `write_log` so every record written inside a span gets:

```json
{
  "trace_id": "<32 lowercase hex>",
  "span_id": "<16 lowercase hex>"
}
```

Records written during a top-level turn should carry that turn's current
trace/span IDs. Session-level records emitted between turns should keep
`session_id` but omit `trace_id` and `span_id`; do not keep a session-long span
open solely to give those records trace IDs. This gives `mud_monitor` and shell
tooling a direct link to the appropriate turn trace without breaking any
existing JSONL parser.

### Phase 4 — semantic spans for agent, LLM, and tools

Refine existing span names and attributes:

- `Agent#run`: `invoke_agent <task>` with
  `gen_ai.operation.name=invoke_agent`, task, limits, and final reason.
- `call_model`: `chat <model>` (or the matching well-known provider operation)
  with `gen_ai.operation.name`, `gen_ai.provider.name`,
  `gen_ai.request.model`, response model/id when available, finish reasons, and
  input/output token usage.
- `dispatch_tool_call`: `execute_tool <name>` with
  `gen_ai.operation.name=execute_tool`, tool name/type, initiator, call ID, and
  error metadata.
- delegated `run_task`: a child `invoke_agent <task>` span, not only task
  start/end events.
- local classifier: `boukensha.local_inference <model>` with backend,
  availability, pool/kept counts, and `cost_usd=0`.

Set attributes known before the operation at span creation so head samplers can
use them. Set response-derived attributes before ending the span. Normalize
provider names to the current convention's enumerated values and preserve the
raw backend name under `boukensha.backend`.

Give agent spans stable agent identity attributes such as
`gen_ai.agent.name`, and optionally `gen_ai.agent.id` and
`gen_ai.agent.version`; keep the particular task, turn, and delegation IDs in
separate attributes. Apply the same `session.id`/`boukensha.session_id` to every
span in a turn trace so observation-oriented backends can filter and aggregate
correctly.

Keep full prompt/request/response payloads out of span attributes. If content
capture is enabled, emit bounded span events after:

- redacting API keys, authorization headers, configured secret field names,
  and MUD passwords;
- truncating each field to the configured byte limit;
- recording `boukensha.content.truncated=true` when applicable;
- never exporting reasoning/chain-of-thought; export only a presence/count
  signal for reasoning blocks.

### Phase 5 — propagate context across MCP

Replace the private-only correlation in `Operation.wire_meta` with both:

- the existing `boukensha/session_id` and `boukensha/operation_id`; and
- a W3C Trace Context carrier (`traceparent`, and `tracestate`/`baggage` when
  present).

Because MCP `_meta` is already passed through the client, inject the carrier
there. Update `mud_manager` separately to extract the carrier and start server
or consumer child spans. Until that consumer change lands, the Boukensha-side
tool span is still complete and the old IDs continue to correlate manager logs.

Do not manually construct `traceparent`; use the configured OTEL propagator.
Add an integration test with a fake MCP server that extracts the context and
asserts its span is a descendant of the tool span.

### Phase 6 — local Collector and backend choices

Add a development Collector configuration under the week 2 environment:

```text
OTLP receiver -> memory limiter -> batch -> debug + chosen backend exporter
```

Provide one zero-account local path, for example Collector + Jaeger or
Collector + Grafana Tempo, and document how to point the same app at a hosted
OTLP endpoint. The app should know only the Collector endpoint; backend
credentials and fan-out belong in Collector configuration.

Langfuse is an optional agent-focused OTLP backend, not a separate
instrumentation architecture. If documented as a destination:

- use its OTLP/HTTP endpoint and configure authentication/version headers in
  the Collector exporter;
- verify the selected GenAI semantic-convention version maps model calls,
  agents, and tools to the expected `generation`, `agent`, and `tool`
  observation types;
- optionally add `langfuse.observation.type` and redacted
  `langfuse.observation.input`/`langfuse.observation.output` fields when its
  agent graph or evaluators are desired;
- keep scores, datasets, and evaluator APIs outside the portable telemetry
  interface unless Boukensha deliberately adopts those product features.

Useful first backend views:

- trace waterfall by session;
- slowest model and tool spans;
- errors grouped by `error.type` and tool;
- latency split by provider/model/initiator;
- token totals and estimated cost by session/model;
- hook work versus model-selected work;
- sessions ending through iteration/token limits.

Use span-to-metrics processing or backend-derived metrics first. Add native
Ruby metrics only after the Ruby metrics SDK/export path is stable enough and a
dashboard requirement cannot be met from spans.

### Phase 7 — tests and rollout

Unit tests:

- disabled telemetry is a true no-op and requires no collector;
- operation nesting produces the expected parent/child IDs;
- exceptions set error status, record exception type, and still close spans;
- frame attributes and counter deltas land on the correct span;
- JSONL gains valid trace/span IDs without losing existing fields;
- separate top-level turns produce different trace IDs with the same session
  ID and neither turn is parented to the other;
- content is absent by default and redacted/truncated when explicitly enabled;
- `close` flushes within a bounded timeout;
- exporter failure logs once and does not change agent output.

Integration tests:

- run against an in-memory/recording exporter and compare the span fixture;
- send OTLP to a disposable Collector and assert receipt;
- verify MCP `traceparent` extraction with a fake server;
- verify delegated tasks remain in the initiating turn's trace;
- run existing logger, hooks, delegation, and monitor tests unchanged.

Rollout:

1. Merge the no-op adapter and JSONL correlation tests.
2. Enable OTEL only in local development with a console/in-memory exporter.
3. Validate the trace fixture through a local Collector and UI.
4. Enable sampled OTLP export in one non-production profile.
5. Check agent latency, memory, dropped spans, payload sizes, and shutdown.
6. Enable broadly with metadata-only capture.
7. Consider content capture only for isolated debugging profiles.

## Expected code changes

Primary files:

- `boukensha.gemspec` / `Gemfile.lock`
- `lib/boukensha/telemetry.rb`
- `lib/boukensha/telemetry/noop.rb`
- `lib/boukensha/telemetry/open_telemetry.rb`
- `lib/boukensha/logger.rb`
- `lib/boukensha/operation.rb`
- `lib/boukensha/config.rb`
- `lib/boukensha.rb`
- `lib/boukensha/agent.rb`
- `lib/boukensha/mcp/client.rb`
- logger/agent/MCP tests and a recording exporter fixture
- development Collector configuration and README instructions

Avoid initially touching every hook operation: bridging `Logger#operation`
automatically covers them. Only adjust a call site when it has semantic
attributes known there that the logger cannot infer.

## Definition of done

- With OTEL disabled, behavior, JSONL, tests, and agent output remain compatible.
- With OTEL enabled, each top-level turn appears as one correctly nested trace
  in a stock OTLP-compatible UI, and all turn traces retain the same session
  correlation ID.
- Model calls show provider/model, finish reason, token usage, latency, error,
  and estimated cost without prompt content by default.
- Tool spans distinguish model and hook initiators and show failures.
- Delegated agents and, after the companion manager change, MCP work are
  connected within the initiating turn by standard W3C trace context.
- Every JSONL event can link to its OTEL trace/span.
- Collector/backend downtime does not fail or materially stall a turn.
- Shutdown performs a bounded flush and reports dropped/export-failed telemetry.
- A documented local stack demonstrates the same OTLP stream in at least one
  open-source UI, while changing to another OTLP backend requires configuration
  only.

## References

- [OpenTelemetry Ruby status and documentation](https://opentelemetry.io/docs/languages/ruby/)
- [Ruby manual instrumentation](https://opentelemetry.io/docs/languages/ruby/instrumentation/)
- [Ruby instrumentation and OTLP packages](https://opentelemetry.io/docs/languages/ruby/libraries/)
- [OTLP exporter configuration](https://opentelemetry.io/docs/specs/otel/protocol/exporter/)
- [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/)
- [GenAI semantic attributes and operations](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/)
- [Collector agent deployment pattern](https://opentelemetry.io/docs/collector/deploy/agent/)
- [Langfuse OpenTelemetry integration](https://langfuse.com/integrations/native/opentelemetry)
- [Langfuse trace and session best practices](https://langfuse.com/docs/observability/best-practices)

## Amendment A — selectable local trace backends (proposed for review)

### Decision

Keep the OpenTelemetry Collector as Boukensha's single OTLP destination and
offer selectable open-source backends through Docker Compose profiles:

| Profile | Components | Purpose | Local UI |
| --- | --- | --- | --- |
| `debug` | Collector debug exporter + zPages | Fast transport and span-shape smoke test | `http://localhost:55679/debug/tracez` |
| `jaeger` | Collector + Jaeger all-in-one | Default, smallest useful trace UI | `http://localhost:16686` |
| `tempo` | Collector + Tempo + Grafana | Test attribute search, TraceQL, and a production-shaped Grafana workflow | `http://localhost:3001` |
| `compare` | Collector fan-out + Jaeger + Tempo + Grafana | Send one Boukensha run to both UIs and compare interpretation | both UIs above |

Jaeger should remain the default recommendation. It accepts OTLP, has a
single-node/all-in-one deployment intended for light local workloads, and gives
the shortest path from “did Boukensha export?” to a trace waterfall. Its local
storage may be ephemeral; that is desirable for the default test profile.

Tempo + Grafana should be the second supported path. It exercises a materially
different backend: searching Boukensha's GenAI and session attributes with
TraceQL, deriving span metrics later, and validating the same data in the UI
many operators already use. The first implementation pins stable Tempo 2.10.5
in monolithic development mode. This avoids making the local trace test depend
on the still-evolving Tempo 3 write architecture and keeps the profile smaller;
revisit Tempo 3 after its stable Docker guidance settles.

Do not embed SigNoz in this Compose file initially. It is a strong later
full-observability test because it handles traces, metrics, and logs, but its
current supported self-host flow is Foundry-generated Compose rather than a
small hand-maintained service block, and the documented minimum is 4 GB of
Docker memory. Document it as an external OTLP destination after the two
trace-focused profiles work.

### Compose structure

Docker Compose profiles can conditionally start services, but Collector YAML
cannot conditionally add exporters based on the active Compose profile.
Therefore each mode gets one profile-specific Collector service and config:

```text
observability/
├── docker-compose.yml
├── collector/
│   ├── debug.yaml
│   ├── jaeger.yaml
│   ├── tempo.yaml
│   └── compare.yaml
├── tempo/
│   └── tempo.yaml
└── grafana/
    └── provisioning/datasources/tempo.yaml
```

Only the selected Collector binds host ports `4317` and `4318`. This makes
`debug`, `jaeger`, and `tempo` mutually exclusive without changing Boukensha's
environment. The `compare` Collector has both exporters in one traces pipeline,
so a single accepted batch is fanned out to both backends. Backend services use
profiles as follows:

```yaml
collector-debug:   { profiles: [debug] }
collector-jaeger:  { profiles: [jaeger] }
collector-tempo:   { profiles: [tempo] }
collector-compare: { profiles: [compare] }
jaeger:            { profiles: [jaeger, compare] }
tempo:             { profiles: [tempo, compare] }
grafana:           { profiles: [tempo, compare] }
```

Pinned image versions are required; no `latest` tags. The initial pins are
Collector `0.157.0`, Jaeger `2.18.0`, Tempo `2.10.5`, and Grafana `13.1.0`.
Grafana uses `${BOUKENSHA_GRAFANA_PORT:-3001}` because the week 2 environment
may already occupy port 3000. Bind OTLP and UI ports to
`127.0.0.1` because these are unauthenticated development services. Add health
checks and named volumes, with ephemeral storage as the documented default and
an opt-in persistence override if retaining traces across restarts becomes
useful.

### Commands and invariant app configuration

```sh
docker compose -f week2_capable/observability/docker-compose.yml --profile debug up
docker compose -f week2_capable/observability/docker-compose.yml --profile jaeger up
docker compose -f week2_capable/observability/docker-compose.yml --profile tempo up
docker compose -f week2_capable/observability/docker-compose.yml --profile compare up
```

Every mode keeps the same Boukensha settings:

```sh
BOUKENSHA_OTEL_ENABLED=true
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

Changing the UI must never require changing application instrumentation,
semantic attributes, or the OTLP endpoint.

### Acceptance checks

1. `debug`: Collector output and zPages show an `invoke_agent player` root with
   nested model/tool spans and no exported prompt or tool content by default.
2. `jaeger`: two turns appear as two root traces with different trace IDs; both
   are discoverable by the same `session.id`.
3. `tempo`: TraceQL can find the fixture using
   `resource.service.name = "boukensha"` and span/session/GenAI attributes.
4. `compare`: a JSONL `trace_id` opens the same span tree in Jaeger and Grafana,
   with matching parentage, status, duration, and attributes.
5. Stop either backend during a run: Boukensha still completes, the Collector
   applies bounded batching/retry behavior, and shutdown remains bounded.

### Sources reviewed for this amendment

- [Jaeger deployment and OTLP configuration](https://www.jaegertracing.io/docs/2.20/deployment/configuration/)
- [Grafana Tempo Docker quick start](https://grafana.com/docs/tempo/latest/docker-example/)
- [OpenTelemetry Collector Docker and debug configuration](https://opentelemetry.io/docs/collector/install/docker/)
- [SigNoz self-hosted Docker requirements and supported installation](https://signoz.io/docs/install/docker/)
