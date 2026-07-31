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

### Upgrading

1. Check `config.yaml`'s storage backend block against the target version's schema — Tempo's block/storage format has evolved across major versions (e.g. vParquet format revisions for the block encoding); an in-place version bump generally reads old blocks fine (backward-compatible readers), but confirm in the release notes before assuming both directions are supported if you ever need to roll back.
2. Since this repo uses the single-binary chart, an upgrade is a standard rolling Deployment update — but the ingester briefly loses its in-memory (not-yet-flushed) spans if it's killed before flushing on shutdown. Confirm `terminationGracePeriodSeconds` gives the ingester enough time to flush its current WAL segment before the rolling update proceeds to the next pod.
3. If using the metrics-generator, verify `remoteWriteUrl` and Prometheus's remote-write-receiver compatibility haven't drifted after upgrading either component independently — a Tempo upgrade and a Prometheus upgrade are two separate change windows that can each break this integration point.

### Migrating from single-binary to tempo-distributed

Referenced under Scaling below as the standard scale-out path — the concrete steps:

1. Point the new `tempo-distributed` release at the **same** storage backend (S3 bucket/path) as the existing single-binary deployment — traces already written remain queryable since both chart flavors read the same block format.
2. Cut over OTLP ingestion (the app-facing endpoint) to the new distributor's Service only once its own ingesters report healthy — running both single-binary and distributed simultaneously against the same storage backend is safe for reads, but don't dual-write new spans to both, which fragments the trace ID space across two ingestion paths unpredictably.
3. Decommission the single-binary release once the distributed deployment has handled a full retention window's worth of traffic and dashboards/alerts relying on Tempo have been confirmed against it.

### Migrating from Jaeger/Zipkin

Tempo accepts both protocols natively — enable the relevant receiver in `tempo.receivers` (`jaeger` or `zipkin`) alongside OTLP, point existing instrumentation at Tempo's receiver port instead of the old backend, and migrate services to OpenTelemetry SDKs/OTLP export incrementally rather than all at once; there's no requirement to migrate protocol and backend in the same step.

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

### High Availability considerations

- **Single-binary mode has a real HA ceiling**: with one set of pods handling distributor+ingester+compactor+querier together, a single-binary replica loss drops both ingestion *and* query capability for the traces it was holding in memory/WAL, not just one or the other. Running 2+ replicas of the single-binary Deployment behind a Service spreads this risk but doesn't eliminate it the way a proper distributed ingester ring does.
- **`tempo-distributed` is the actual HA answer**, not a scaling-only concern — splitting distributor/ingester/querier/compactor into independent Deployments means an ingester loss only affects the traces that specific ingester was holding (with replication configured), while distributors keep routing to healthy ingesters and queriers keep serving already-flushed data unaffected.
- **In-flight (unflushed) spans are the actual data-loss window**: regardless of single-binary or distributed mode, any spans received but not yet flushed to durable storage (S3/PVC) are lost if the holding ingester pod is killed ungracefully (not via a clean rolling update). This is inherent to how trace ingestion buffers before flush — keep `terminationGracePeriodSeconds` generous and avoid `kubectl delete pod --force` on ingesters in production.
- **The metrics-generator's dependency on Prometheus is a soft one**: if Prometheus is briefly unavailable, Tempo continues ingesting and storing traces normally — only the service-graph/RED-metrics derived data pauses, trace search/retrieval is unaffected.

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
- **Traces vanish immediately after an ungraceful pod restart (node eviction, OOM kill)** — the ingester holding those spans in its WAL was killed before flushing. Check `terminationGracePeriodSeconds` and whether the restart was a clean rolling update vs. an eviction/OOM; if OOM kills are frequent, that's a separate resource-sizing problem (raise `resources.limits.memory`) masquerading as a data-loss bug.
- **After migrating to `tempo-distributed`, some old traces become unqueryable** — usually a storage backend path/prefix mismatch between the single-binary and distributed chart's default config (they can default to slightly different S3 key prefixes). Explicitly set matching `storage.trace.s3` path configuration in both during the migration window rather than relying on each chart's defaults to happen to agree.

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
