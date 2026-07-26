# Boukensha local traces

Boukensha emits metadata-only traces and keeps its existing JSONL session log.
The instrumentation contract is pinned to **OpenTelemetry GenAI semantic
conventions 1.37.0**. Attribute changes require an explicit compatibility
review even when SDK dependencies are upgraded.

## Choose a profile

Only one profile should run at a time. Every profile exposes the same OTLP
ports, so Boukensha configuration never changes.

| Profile | What starts | UI |
| --- | --- | --- |
| `debug` | Collector debug exporter and zPages | <http://localhost:55679/debug/tracez> |
| `jaeger` | Collector and Jaeger | <http://localhost:16686> |
| `tempo` | Collector, Tempo, and Grafana | <http://localhost:3001/explore> |
| `compare` | Collector fan-out, Jaeger, Tempo, and Grafana | both UIs |

From the repository root:

```sh
docker compose -f week2_capable/observability/docker-compose.yml --profile debug up
docker compose -f week2_capable/observability/docker-compose.yml --profile jaeger up
docker compose -f week2_capable/observability/docker-compose.yml --profile tempo up
docker compose -f week2_capable/observability/docker-compose.yml --profile compare up
```

Stop the selected profile and remove its containers:

```sh
docker compose -f week2_capable/observability/docker-compose.yml --profile jaeger down
```

Add `--volumes` to also erase saved Tempo and Grafana development data.

Jaeger is the recommended first visual test. The `debug` profile is the
smallest transport smoke test. The `compare` profile sends each accepted batch
to both backends so the same JSONL `trace_id` can be checked in both UIs.

## Configure Boukensha once

Add this to `~/.boukensha/settings.yaml`:

```yaml
observability:
  otel:
    enabled: true
    capture_content: false
    env:
      OTEL_SERVICE_NAME: boukensha
      OTEL_EXPORTER_OTLP_ENDPOINT: http://localhost:4318
      OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
      OTEL_TRACES_EXPORTER: otlp
```

Then start a profile and run Boukensha normally—no shell exports are required.
Each top-level turn is a separate trace. Search
using `session.id` or `boukensha.session_id` to find all turns in one session.
In Grafana Explore, select the provisioned Tempo data source and use TraceQL:

```traceql
{ resource.service.name = "boukensha" }
```

The YAML equivalent is disabled by default:

```yaml
observability:
  otel:
    enabled: false
    capture_content: false
    content_max_bytes: 4096
```

Only uppercase `OTEL_*` keys are accepted in the YAML `env` mapping. Existing
process environment variables take precedence over YAML, so deployments can
override endpoint, protocol, resource attributes, sampling, and propagators.
`BOUKENSHA_OTEL_ENABLED`, `BOUKENSHA_OTEL_CAPTURE_CONTENT`, and
`BOUKENSHA_OTEL_CONTENT_MAX_BYTES` likewise override their YAML settings.

Keep authentication headers such as `OTEL_EXPORTER_OTLP_HEADERS` in the real
process environment rather than committing credentials to `settings.yaml`.

All exposed ports bind to `127.0.0.1`; these development services do not provide
authentication and should not be exposed publicly.

Grafana defaults to port `3001` because the week 2 development environment may
already use `3000`. Override it when launching with
`BOUKENSHA_GRAFANA_PORT=3010`.
