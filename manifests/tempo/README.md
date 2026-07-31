# Tempo

## What is this?

Production-ready manifests and Helm values for Grafana Tempo, a
distributed tracing backend. Like Loki, Tempo only indexes trace IDs (not
full span content), making it cheap to store at scale compared to
Elasticsearch-backed tracing systems. Wired into Grafana
(`manifests/grafana/datasources/datasources.yaml`) for trace search,
trace-to-logs, and service-graph visualization.

Applications send spans directly to Tempo over OTLP (gRPC or HTTP) — there
is no separate collector required for a basic setup, though a
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) in
front is recommended once you need sampling, batching, or multi-backend
fan-out.

## Architecture

```
   Instrumented app (OpenTelemetry SDK)
              |
              | OTLP gRPC (4317) / HTTP (4318)
              v
   ┌───────────────────────────────────────┐
   │                Tempo                    │
   │  distributor -> ingester -> compactor   │
   │  (single-binary chart; split into       │
   │   microservices via tempo-distributed   │
   │   once volume requires it)              │
   └───────┬─────────────────────┬───────────┘
           |                     |
           v                     v
   Object storage           metrics-generator
   (filesystem PVC or S3)   (RED metrics + service graph)
                                   |
                                   v
                        Prometheus (remote_write)
                                   |
                                   v
                        Grafana (trace search, service map,
                        trace<->logs<->metrics correlation)
```

## Prerequisites

- Kubernetes 1.24+, Helm 3.8+
- A `StorageClass` supporting `ReadWriteOnce` (local/filesystem mode), or
  an S3-compatible bucket for production durability.
- `manifests/prometheus/` installed and reachable, if using the metrics
  generator's `remote_write` (recommended — powers the service graph).
- Applications instrumented with an OpenTelemetry SDK (or Jaeger/Zipkin
  client, both also supported) configured to export to the Tempo Service.

## Installation

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace monitoring   # if not already created

helm upgrade --install tempo grafana/tempo \
  --namespace monitoring \
  -f manifests/tempo/values.yaml

kubectl apply -f manifests/grafana/datasources/datasources.yaml
```

Point your application's OTLP exporter at:
`http://tempo.monitoring.svc:4317` (gRPC) or `:4318` (HTTP).

## Verification

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo

# Readiness
kubectl exec -n monitoring deploy/tempo -- wget -qO- http://localhost:3100/ready

# Send a test span (requires a local OTLP-capable tool, e.g. telemetrygen)
# telemetrygen traces --otlp-endpoint tempo.monitoring.svc:4317 --otlp-insecure --traces 1

# Query a trace by ID via the API
kubectl port-forward -n monitoring svc/tempo 3100:3100 &
curl -s http://localhost:3100/api/traces/<trace_id> | jq '.batches | length'

# Confirm the metrics-generator is producing service-graph metrics
curl -sG http://localhost:9090/api/v1/query --data-urlencode \
  'query=traces_service_graph_request_total' | jq '.data.result | length'
```

## Configuration

- **Retention**: `tempo.retention` in `values.yaml` (mirrored as
  `compactor.compaction.block_retention` in `config.yaml`) — traces are
  typically retained far shorter than logs/metrics (days, not weeks) since
  they're mainly used for near-term debugging.
- **Receivers**: enable/disable OTLP/Jaeger/Zipkin protocols under
  `tempo.receivers` — disable any you don't use to reduce attack surface.
- **Storage backend**: `tempo.storage.trace.backend` — `local` (PVC) by
  default; switch to `s3` for production multi-replica durability.
- **Metrics generator**: `tempo.metricsGenerator.enabled` +
  `remoteWriteUrl` — turns spans into RED metrics and a service graph in
  Prometheus; disable if you don't want Tempo writing into your Prometheus
  TSDB.
- **Guard rails**: `overrides.defaults.ingestion.rate_limit_bytes` and
  `global.max_bytes_per_trace` in `config.yaml` — prevent one runaway trace
  (e.g. an infinite loop generating spans) from consuming disproportionate
  storage/query resources.

## Security

- Tempo has no built-in authentication on its OTLP/query endpoints in this
  single-tenant configuration — restrict access via `NetworkPolicy` to only
  the namespaces that need to send spans or query traces, and never expose
  the OTLP ports outside the cluster without a gateway/auth proxy.
- Trace data can contain sensitive information if applications put PII/
  secrets into span attributes (e.g. full request bodies, auth headers) —
  configure OpenTelemetry SDK/Collector-side attribute scrubbing before
  spans reach Tempo; Tempo itself does not redact anything.
- S3 credentials (when `storage.trace.backend: s3`) should come from IRSA/
  Workload Identity, not static keys inlined in values files.
- `overrides.defaults.global.max_bytes_per_trace` and rate limits double as
  a basic defense against a misbehaving or malicious client trying to
  exhaust storage via oversized/high-volume trace submission.

## Scaling

- The `grafana/tempo` chart used here is **single-binary** — good up to a
  moderate span-ingestion rate on a single set of pods. Once you outgrow
  it (sustained high cardinality/volume, or need independent scaling of
  ingest vs. query), migrate to the `grafana/tempo-distributed` chart,
  which splits distributor/ingester/querier/compactor into separate
  Deployments.
- Vertically scale `resources` first — ingesters are the most
  memory-sensitive component (they hold recent spans in memory before
  flushing to storage).
- For S3-backed storage, query performance scales roughly with how well
  you can narrow a search (time range + service name); encourage teams to
  always search with a tight time window rather than "last 7 days" as a
  default.

## Common Problems

- **Spans sent but trace not found when queried by ID** — check the
  ingester actually flushed the block (`max_block_duration`/
  `trace_idle_period` in `config.yaml` control this); a trace is not
  queryable until its block is cut and (for local/S3 async) written to
  storage. Also verify the app sent the trace ID in the exact format Tempo
  expects (hex, no dashes).
- **`rpc error: code = ResourceExhausted` when sending spans** — hitting
  `overrides.defaults.ingestion.rate_limit_bytes`/`burst_size_bytes`. Either
  the app is sending abnormally high span volume (check for a span-per-loop-
  iteration bug) or the limit genuinely needs raising for legitimate load.
- **Service graph panel empty in Grafana** — `metricsGenerator.enabled` is
  false, or `remoteWriteUrl` points at the wrong Prometheus Service, or
  Prometheus's `remote-write-receiver` feature flag isn't enabled
  (`--web.enable-remote-write-receiver`, already implied by using the
  `remote_write` ingestion path in kube-prometheus-stack's default flags —
  verify with `kubectl logs` on the Prometheus pod if metrics never show
  up).
- **Traces missing spans from one service ("broken" trace)** — that
  service isn't propagating the W3C traceparent header (or is using a
  different propagation format, e.g. B3, without a compatible propagator
  configured) — the spans exist as separate, unlinked traces instead of one.
- **PVC fills up / traces disappearing earlier than `retention` implies**
  — filesystem storage capacity is smaller than `retention` × ingest volume
  requires; either shrink retention, raise PVC size, or migrate to S3.

## Best Practices

- Standardize on OpenTelemetry SDKs and OTLP export across services —
  Jaeger/Zipkin receivers exist mainly for migrating legacy instrumentation,
  not as a long-term target.
- Put an OpenTelemetry Collector between apps and Tempo once you have more
  than a handful of services — enables tail sampling (keep only
  interesting/error traces), batching, and protecting Tempo from
  thundering-herd span bursts.
- Keep trace retention short (days) relative to logs/metrics — traces are
  for active debugging, not long-term analysis; use the metrics-generator's
  RED metrics (which land in Prometheus with its own longer retention) for
  historical trend analysis instead.
- Set `max_bytes_per_trace` deliberately — an unbounded trace (e.g. from a
  retry-storm bug) can otherwise consume enormous storage and slow down
  queries for everyone.
- Always propagate trace context (W3C traceparent) through async
  boundaries (queues, background jobs) — traces that stop at the queue
  boundary lose most of their debugging value.

## Useful Commands

```bash
# Readiness / health
kubectl exec -n monitoring deploy/tempo -- wget -qO- http://localhost:3100/ready

# Fetch a trace by ID
curl -s http://localhost:3100/api/traces/<trace_id> | jq

# Search traces by service/tag (TraceQL, Tempo's query language)
curl -sG http://localhost:3100/api/search --data-urlencode \
  'q={ .service.name = "sample-app" && duration > 500ms }' | jq '.traces | length'

# Generate synthetic test traces (telemetrygen from opentelemetry-collector-contrib)
telemetrygen traces --otlp-endpoint tempo.monitoring.svc:4317 --otlp-insecure --traces 10

# Check ingester/compactor logs for flush or storage errors
kubectl logs -n monitoring deploy/tempo -f | grep -i error

# Verify service-graph metrics are landing in Prometheus
curl -sG http://localhost:9090/api/v1/query --data-urlencode \
  'query=sum(rate(traces_service_graph_request_total[5m])) by (client, server)'
```

## References

- Tempo documentation: https://grafana.com/docs/tempo/latest/
- Tempo Helm chart: https://github.com/grafana/helm-charts/tree/main/charts/tempo
- TraceQL reference: https://grafana.com/docs/tempo/latest/traceql/
- Tempo metrics-generator: https://grafana.com/docs/tempo/latest/metrics-generator/
- OpenTelemetry Collector: https://opentelemetry.io/docs/collector/
- Migrating to tempo-distributed for scale: https://grafana.com/docs/tempo/latest/setup/helm-chart/
