# ERROR LOG — durable exception diagnostics for Boukensha

> **Status: implemented (2026-07-26).**
>
> Add a durable, profile-scoped error log to Boukensha and a top-level
> **Errors** page to Mud Monitor. The immediate failure motivating this plan is
> representative:
>
> ```text
> [mud_hooks] ArgumentError: wrong number of arguments (given 1, expected 0)
> ```
>
> That line identifies the symptom but discards the call site and backtrace
> needed to diagnose it. Session JSONL currently records `error_type` for some
> failed operations, while several best-effort rescue paths print only
> `class: message` to stderr. OpenTelemetry may retain a backtrace when enabled,
> but local diagnostics must not depend on an optional collector.

## Goal

Whenever Boukensha rescues or reports an exception, preserve enough information
to answer:

- what failed;
- where it was rescued;
- which session, operation, task, and profile were active;
- when it happened;
- the exception class and complete message;
- the Ruby backtrace.

The canonical file is:

```text
.boukensha/profiles/<profile-id>/error.log
```

In the active `Dummy` profile, for example:

```text
.boukensha/profiles/Dummy/error.log
```

This is the profile-aware interpretation of `.boukensha/error.log`. The
read-only `legacy` profile may read an existing root-level
`.boukensha/error.log`, but new runs always write inside their selected profile.
That keeps errors aligned with the same profile selection used by sessions,
manager, telnet, journal, and knowledge data.

Mud Monitor adds a top-level **Errors** tab that reads and live-tails this file.

## Non-goals

- Capturing arbitrary stderr/stdout output.
- Capturing local variables, heap state, environment variables, API keys, or
  complete tool/model payloads.
- Replacing session logs, OpenTelemetry exceptions, or normal user-facing error
  messages.
- Automatically uploading errors to an external service.
- Recovering backtraces for historical errors that were already reduced to a
  terminal message.
- Turning best-effort telemetry failures into fatal agent failures.

## Design decisions

### JSON Lines inside `error.log`

Despite the `.log` extension, the file is JSONL: one complete JSON object per
line. A multiline human-oriented format is pleasant in a terminal but awkward
to tail reliably and ambiguous to parse. JSONL preserves the backtrace as an
array while remaining directly greppable.

Example:

```json
{"id":"err_8f32c1c7","at":"2026-07-26T12:15:43.341-04:00","mono_ms":3578778,"severity":"error","component":"mud_hooks","boundary":"before_tools","exception_class":"ArgumentError","message":"wrong number of arguments (given 1, expected 0)","backtrace":[".../mud/hooks.rb:639:in 'Proc#call'",".../mud/hooks.rb:152:in 'block (2 levels) in before_tools'"],"session_id":"20260726T161513Z-7f24ba6c","task":"player","operation_id":"op_3a9020","operation":"async_poll","trace_id":"d37f270c7811fd7d1ec8e3876cfee4f0","span_id":"8aa8563ef4d860d7","pid":12345,"thread_id":456}
```

Required fields:

| Field | Meaning |
|---|---|
| `id` | Unique `err_<hex>` identifier; never a per-process sequence |
| `at` | ISO-8601 wall-clock timestamp with milliseconds and offset |
| `mono_ms` | Process monotonic timestamp for local ordering |
| `severity` | Initially `error` or `warning` |
| `component` | Stable subsystem name such as `mud_hooks`, `journal`, `agent`, `otel` |
| `boundary` | Rescue/reporting boundary, preferably a method or lifecycle hook |
| `exception_class` | Fully qualified Ruby exception class |
| `message` | Complete exception message |
| `backtrace` | Array from `exception.backtrace`; empty only when unavailable |
| `pid`, `thread_id` | Identify concurrent writers/execution contexts |

Optional correlation fields are copied from ambient state when present:
`profile_id`, `session_id`, `task`, `operation_id`, `operation`, `trace_id`, and
`span_id`. Callers may add a small `context` object containing safe identifiers
such as a tool name or journal path. Context must never contain credentials,
model prompts/responses, raw MUD output, environment variables, or arbitrary
argument inspection.

### One writer abstraction

Add:

```text
week2_capable/boukensha/lib/boukensha/error_log.rb
```

`Boukensha::ErrorLog` owns serialization, redaction, append safety, correlation,
and failure handling:

```ruby
error_log.record(
  exception,
  component: "mud_hooks",
  boundary: "before_tools",
  context: { hook: "async_poll" }
)
```

The implementation:

1. resolves its default path from `Boukensha.config.profile_dir`;
2. creates the parent directory if necessary;
3. builds a single record and serializes it before locking;
4. opens with append mode, takes an exclusive `flock`, performs one write plus
   newline, flushes, and releases the lock;
5. never raises into gameplay;
6. falls back to one concise stderr warning if the error log itself cannot be
   written, guarded against recursive logging.

Do not route errors through `Boukensha::Logger`: session logging has a different
lifecycle and an error can occur before a session logger exists. `ErrorLog` is a
small independent sink. It may read `Operation.current` and the telemetry
adapter's current IDs when available, but neither is required.

Inject an `error_log:` dependency where practical so tests use temporary files.
A process-level `Boukensha.error_log` accessor is acceptable for startup and
other early boundaries. Reset the memoized writer when configuration/profile
selection is reset.

### Record at the boundary that intentionally absorbs the exception

The primary rule is:

> The rescue boundary that prevents an exception from propagating owns the
> durable error record.

Do not log and re-log at every frame. An exception that propagates through
instrumented operations may still appear as an OpenTelemetry exception event,
but it gets one `error.log` entry at the boundary that converts it into a
fallback, an error result, or a user-facing message.

First implementation coverage:

| Current boundary | Required change |
|---|---|
| `Mud::Hooks#guard` | Record full exception as `component: "mud_hooks"` before returning `nil` |
| Journal best-effort write rescue | Record as `component: "journal"` before warning |
| Agent tool-dispatch rescue | Record as `component: "agent"`, with safe tool name and call ID |
| Hook/room-survey construction rescue in the loader | Record as `component: "mud_hooks_setup"` |
| REPL/TUI turn rescue | Record as `component: "repl"` or `"tui"` before rendering the short message |
| OpenTelemetry build/export rescue | Record as `component: "otel"` without attempting to use OTel correlation |
| Extractor degradation rescues | Record once when the extractor becomes unavailable, not on every subsequent call |
| Hook dispatcher rescue | Record safe tool name and initiator before returning/re-raising |

Audit all `rescue StandardError`, bare `rescue`, and `rescue LoadError` clauses
under `week2_capable/boukensha/lib`. Each must be explicitly classified:

- **record here** — it consumes/transforms the exception;
- **record above** — it re-raises unchanged to an identified owning boundary;
- **intentionally ignored** — only for cleanup such as `at_exit { close rescue
  nil }`, with a code comment explaining why.

Avoid catching `Exception`; interrupts and process-exit exceptions retain Ruby's
normal semantics. If `Interrupt` is already deliberately caught by the REPL, it
is not an application error and should not create a record.

### Relationship to existing observability

The sinks remain complementary:

| Sink | Purpose |
|---|---|
| `sessions/*.jsonl` | Agent execution narrative and operation timing |
| `error.log` | Durable exception class, message, and Ruby backtrace |
| OpenTelemetry/Jaeger | Distributed span context and exception visualization |
| stderr/TUI | Immediate concise operator feedback |

Where a session logger exists, keep its current failed `operation_end` and
`tool_result` events. Add `error_id` to those events when the rescue boundary
has recorded an error, enabling direct cross-navigation later. Do not copy full
backtraces into session JSONL; `error.log` is their single local source of truth.

## Mud Monitor API

Mirror the existing append-only log readers without ingesting errors into
Rails' SQLite database:

```text
week2_capable/mud_monitor/api/lib/error_log/
  parser.rb
  follower.rb
  store.rb
week2_capable/mud_monitor/api/app/controllers/api/v1/errors_controller.rb
```

Configuration:

- default path: selected profile's `error.log`;
- optional override: `MUD_MONITOR_ERROR_LOG`;
- legacy profile: root `.boukensha/error.log`, read-only;
- a missing file is valid and means no errors have been captured.

Routes:

```text
GET /api/v1/errors
GET /api/v1/errors/stream
```

`GET /api/v1/errors` accepts:

| Query | Behaviour |
|---|---|
| `after` | Return records after an opaque cursor |
| `before` | Pagination cursor for older records |
| `limit` | Bounded page size; default 100, maximum 500 |
| `component` | Exact component filter |
| `exception_class` | Exact exception-class filter |
| `session_id` | Exact session filter |
| `operation_id` | Exact operation filter |
| `q` | Case-insensitive search over class, message, component, and backtrace |

Return newest-first for initial/paginated HTTP reads. SSE emits appended records
in file order. Use a byte-offset cursor rather than a writer-generated sequence:
multiple processes may append to the same file, and a byte offset is unique and
stable for a single non-rotating file. The parser must:

- ignore a final incomplete line until its newline arrives;
- return a visible `malformed` diagnostic record for a complete invalid line
  instead of failing the whole page;
- cap accepted line size and backtrace depth defensively;
- tolerate the file appearing after the monitor starts;
- detect truncation/replacement and reset the follower cursor safely.

The stream uses the existing `StreamGate` and idle timeout. Profile selection
and `409 profile_selection_required` behaviour match every other profile-backed
endpoint.

## Mud Monitor web UI

Add a top-level route and navigation item:

```text
/errors    Errors
```

Files:

```text
web/src/pages/Errors.tsx
web/src/api/client.ts       + fetchErrors
web/src/api/types.ts        + ErrorRecord/ErrorPage
web/src/App.tsx             + route
web/src/components/Layout.tsx + top-level Errors link
```

The page provides:

- a live/paused indicator using the shared `useEventStream`;
- newest-first error cards or rows;
- timestamp, exception class, message, component, boundary, and profile/session
  correlation at a glance;
- expandable full backtrace, preserving frames as separate lines;
- filters for component, exception class, session, and free-text search;
- a link to `/sessions/:session_id?op=:operation_id` when both correlation
  values exist, otherwise the session link when only `session_id` exists;
- copy buttons for the error ID and a plain-text diagnostic containing class,
  message, backtrace, and safe correlation IDs;
- explicit empty state: “No errors captured for this profile”;
- explicit unavailable/malformed states rather than silently showing an empty
  page.

Never render backtrace or message content with `dangerouslySetInnerHTML`.
Treat log contents as untrusted text. Reuse the monitor's existing table/card,
filter, stream-status, and profile-selection styles; add no UI dependency.

The top navigation order should keep execution layers together:

```text
Dashboard · Sessions · Manager · Telnet · Errors · Knowledge · Change Log
```

## Retention and size

The requested first implementation uses one `error.log` per profile. Errors
should be rare, so automatic rotation is deferred until measured volume proves
it necessary. Document that deleting or truncating the file removes local error
history.

Before production use, support an operator-configurable maximum backtrace depth
(default 200 frames) and message length (default 16 KiB) to prevent pathological
exceptions from creating unbounded single records. Truncation must be explicit
through `message_truncated`, `backtrace_truncated`, and original counts/sizes.

Future rotation must preserve the Errors API's opaque cursor contract; clients
must not assume cursors are numeric sequences.

## Security and privacy

- Record exception messages and backtraces because they are the purpose of this
  log, but assume either can accidentally contain sensitive values.
- Never add environment dumps, request headers, API keys, model content, tool
  results, or inspected argument hashes.
- Apply the existing project redaction rules to message text before writing.
- Restrict `error.log` permissions to the owning user (`0600` where supported);
  parent directories retain the profile directory's existing permissions.
- Mud Monitor remains bound to localhost by default. The Errors endpoint
  receives the same profile and deployment security posture as other logs.
- The UI copy action copies only the selected error, never the full file.

## Test plan

### Boukensha unit tests

Add `test/test_error_log.rb`:

- writes one valid JSON object per exception;
- preserves class, full message, and ordered backtrace frames;
- includes ambient session/operation/trace correlation when available;
- works without a session logger or OpenTelemetry;
- uses the active profile path by default;
- accepts an injected temporary path/writer;
- concurrent threads produce complete, non-interleaved lines;
- write failure warns once and never raises or recurses;
- message/backtrace caps mark truncation;
- redaction removes configured secret values;
- unique IDs do not collide across writer instances.

Add boundary tests that deliberately raise inside:

- `Mud::Hooks#guard`;
- agent tool dispatch;
- journal writes;
- loader hook setup;
- an OpenTelemetry initialization failure.

Each test asserts one durable entry—not merely terminal output—and verifies
that gameplay retains its existing fallback behaviour.

### Mud Monitor API tests

- parses valid records and preserves backtrace arrays;
- missing `error.log` returns an empty, available response;
- profile selection resolves the correct file and cannot escape the profile
  root;
- filtering and bounded pagination work;
- byte-offset cursors neither duplicate nor skip appended complete lines;
- incomplete final lines wait for completion;
- malformed and oversized lines do not take down the endpoint;
- SSE replays after a cursor, emits new records, respects `StreamGate`, and
  handles truncation/replacement.

### Web tests

- Errors appears in top-level navigation and `/errors` renders;
- empty, loading, API-error, malformed-record, and live states render;
- expanding a record shows every backtrace frame;
- filters affect API requests and live entries consistently;
- session/operation links are correct;
- message/backtrace text is escaped;
- duplicate SSE records are deduplicated by error ID/cursor.

### End-to-end acceptance

1. Select the `Dummy` profile and start Mud Monitor.
2. Trigger a deterministic `ArgumentError` inside a test-only hook boundary.
3. Confirm the REPL still prints a concise error and continues running.
4. Confirm `.boukensha/profiles/Dummy/error.log` contains class, message, and
   backtrace with the originating source line.
5. Confirm the Errors tab receives it live without a refresh.
6. Follow its session/operation link to the corresponding session span.
7. Repeat with OpenTelemetry disabled and confirm local diagnostics are
   unchanged.

## Implementation phases

1. **Error record and writer**
   - Add `Boukensha::ErrorLog`, profile-aware path resolution, safe append,
     correlation, limits, redaction, and unit tests.
2. **Capture-boundary audit**
   - Classify every rescue, wire the owning boundaries, preserve existing
     fallback behaviour, and attach `error_id` to correlated session events.
3. **Monitor reader and API**
   - Add parser/store/follower, configuration, profile resolution, filters,
     pagination, routes, SSE, and request tests.
4. **Errors page**
   - Add types/client, route/navigation, live list, filters, expandable
     backtraces, correlation links, copy action, and UI tests.
5. **Acceptance and documentation**
   - Run the deterministic exception flow with OTel both enabled and disabled;
     update Boukensha and Mud Monitor READMEs with path, privacy, retention, and
     troubleshooting instructions.

## Definition of done

- Every intentionally swallowed runtime exception in the audited Boukensha
  paths is either durably recorded once or explicitly documented as an
  intentional cleanup exception.
- A missing-parameter/argument error records its complete Ruby backtrace in the
  active profile's `error.log`.
- Error logging cannot terminate or materially delay an agent turn.
- The Errors tab displays existing records and newly appended records for the
  selected profile.
- Operators can filter, expand, copy, and correlate an error to its session and
  operation.
- Error capture works without Jaeger, a collector, or network access.
- Tests cover serialization, concurrency, failure isolation, profile scoping,
  parsing, SSE, UI escaping, and the motivating `ArgumentError`.
