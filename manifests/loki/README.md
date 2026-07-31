# Loki

## What is this?

Production-ready manifests and Helm values for Loki, Grafana Labs' log
aggregation system. Loki indexes only metadata (labels) rather than full
log text, making it far cheaper to run at scale than Elasticsearch-style
full-text indexing — you query it with LogQL from Grafana (wired up in
`manifests/grafana/datasources/datasources.yaml`), and correlate log lines
with traces via the `trace_id` derived field.

This directory does not include a log shipper (Promtail/Grafana Alloy) —
that runs as a separate DaemonSet, typically installed from the same
`grafana/loki-stack` or `grafana/alloy` chart family; add it alongside this
if you don't already have one.

## Architecture

```
   Application pods (stdout/stderr)
              |
              v
   ┌─────────────────────┐
   │ Promtail / Alloy      │  DaemonSet, tails container logs,
   │ (log shipper)         │  attaches k8s labels (namespace, pod, etc.)
   └──────────┬────────────┘
              | push (HTTP)
              v
   ┌─────────────────────┐
   │   Loki gateway        │  nginx-based router (read vs write path)
   └───┬───────────────┬───┘
       v               v
   ┌────────┐     ┌─────────┐      ┌───────────┐
   │ write  │     │  read   │<---->│  backend  │ (compactor, ruler,
   │ (3x)   │     │  (2x)   │      │   (2x)    │  index gateway)
   └───┬────┘     └────┬────┘      └───────────┘
       |               |
       v               v
   Object storage (filesystem PVC for small deployments, S3 for prod)
```

Deployed in **Simple Scalable** mode: `write` targets handle ingestion,
`read` targets handle queries, `backend` handles compaction/retention/
ruler. This scales further than single-binary mode (all-in-one) while
staying much simpler to operate than full microservices mode.

## Prerequisites

- Kubernetes 1.24+, Helm 3.8+
- A `StorageClass` supporting `ReadWriteOnce` (filesystem mode) — or an S3
  (or GCS/Azure Blob) bucket for production-grade durable storage.
- A log shipper DaemonSet (Promtail or Grafana Alloy) configured to push to
  the Loki gateway Service.
- `manifests/grafana/` installed if you want to query logs via the Grafana
  UI (recommended over the raw Loki API for humans).

## Installation

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace monitoring   # if not already created by Prometheus/Grafana

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  -f helm-values/loki.yaml

# Confirm the datasource is wired up (see manifests/grafana/datasources/)
kubectl apply -f manifests/grafana/datasources/datasources.yaml
```

## Verification

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# Loki ready check
kubectl exec -n monitoring deploy/loki-read -- wget -qO- http://localhost:3100/ready

# Push a test log line and query it back
kubectl port-forward -n monitoring svc/loki-gateway 3100:80 &
curl -s http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="monitoring"}' \
  --data-urlencode 'limit=5' | jq '.data.result | length'

# Canary check — lokiCanary writes+reads synthetic logs continuously
kubectl logs -n monitoring -l app.kubernetes.io/component=canary --tail=20
```

Expect no `response_hash mismatch` or `wrong entry count` errors from the
canary pods — those indicate log entries are being dropped or delayed
somewhere in the write path.

## Configuration

- **Deployment mode**: `deploymentMode: SimpleScalable` in `values.yaml`.
  Switch to `SingleBinary` for small/dev clusters, or `Distributed` (full
  microservices) only once you have a dedicated team operating Loki at
  very large scale.
- **Retention**: `loki.limits_config.retention_period` (also mirrored in
  `config.yaml`) — the compactor enforces this; `compactor.retention_enabled:
  true` must also be set or retention is computed but never actually
  deletes anything.
- **Storage backend**: `loki.storage.type` — `filesystem` (PVC-backed) out
  of the box; uncomment the `s3` block for production durability across
  more than one write replica.
- **Rate limits**: `limits_config.ingestion_rate_mb` /
  `per_stream_rate_limit` — raise if legitimate high-volume apps hit 429s;
  check `loki_discarded_samples_total{reason=...}` in Prometheus first to
  see which limit is actually being hit.
- **Replication factor**: `commonConfig.replication_factor: 3` — each log
  line is written to 3 ingesters; don't drop below 3 in production or a
  single node loss can lose unflushed data.

## Security

- `auth_enabled: false` means this Loki instance is **single-tenant** —
  anyone who can reach the gateway Service can read/write all logs. Do not
  expose the gateway outside the cluster without an authenticating proxy in
  front of it (oauth2-proxy, mTLS, or your ingress controller's auth
  annotations). For genuine multi-tenant isolation, set `auth_enabled: true`
  and require the `X-Scope-OrgID` header per tenant.
- Loki has no built-in awareness of what's *inside* the log lines it
  stores — make sure your log shipper (Promtail/Alloy) is configured with
  pipeline stages to redact secrets/PII (tokens, credit card numbers,
  emails) before they ever reach Loki; scrubbing after ingestion is far
  harder.
- S3 credentials (when `storage.type: s3`) should come from IRSA/Workload
  Identity, not static access keys; if static keys are unavoidable, source
  them from a `Secret`, never inline in `values.yaml`.
- `analytics.reporting_enabled: false` stops Loki phoning home usage stats.

## Scaling

- **Ingestion**: scale `write.replicas` — each write pod handles a share of
  incoming streams; `replication_factor: 3` means each stream is still
  durably written to 3 ingesters regardless of total replica count.
- **Query throughput**: scale `read.replicas` and raise
  `limits_config.max_query_parallelism` together — more read replicas alone
  won't help if parallelism per query is capped low.
- **Retention/compaction**: `backend.replicas` — the compactor is a
  singleton-per-shard process; more backend replicas mainly helps the
  ruler and index gateway, not compaction throughput itself.
- **Storage**: filesystem/PVC mode caps out once a single write pod's disk
  fills or I/O saturates — migrate to S3-backed storage before that point
  if ingestion volume is growing.

## Common Problems

- **`429 Too Many Requests` from log shippers** — a stream (unique label
  combination) or tenant is exceeding `per_stream_rate_limit` or
  `ingestion_rate_mb`. Check `loki_discarded_samples_total` by reason in
  Prometheus; fix the offending app's label cardinality (e.g. stop
  labeling by request ID) rather than just raising the limit.
- **Logs pushed but not queryable ("no logs found" in Grafana)** — check
  Loki's clock isn't skewed vs the shipper's, and that the query's label
  matchers actually match what's being sent (`{namespace="..."}` is case
  and value sensitive). Use `curl .../loki/api/v1/labels` and
  `.../label/<name>/values` to see what's actually indexed.
- **Compactor never deletes old chunks despite `retention_period` being
  set** — `compactor.retention_enabled: true` is required in addition to
  `limits_config.retention_period`; without it retention is computed but
  never enforced. Also confirm `delete_request_store` is configured (a
  common miss when moving from filesystem to S3).
- **High memory usage on `read` pods during large queries** — usually an
  unbounded LogQL query (e.g. `{namespace=~".+"}` over a 30-day range).
  Add tighter label selectors and a time range; consider lowering
  `max_query_series`/`max_entries_limit_per_query` to force smaller
  queries cluster-wide.
- **`context deadline exceeded` on ingestion during a traffic spike** —
  `write` replicas are saturated. Check CPU/memory on write pods and scale
  `write.replicas`, or raise `grpc_server_max_recv_msg_size` if it's a
  large-batch-size issue specifically.

## Best Practices

- Keep label cardinality low — label by `namespace`, `app`, `pod`, `level`;
  never by request ID, user ID, or raw timestamp. High-cardinality labels
  are Loki's single biggest performance killer (same failure mode as
  Prometheus).
- Use structured logging (JSON) in applications and parse fields at query
  time with LogQL (`| json`) rather than creating a label per field.
- Set retention deliberately per compliance/cost needs — don't leave the
  default forever; logs are usually the largest storage line item in an
  observability stack.
- Run the `lokiCanary` in every environment — it's the cheapest way to
  catch silent data loss in the write path before a real incident does.
- Prefer S3-compatible object storage over filesystem/PVC for anything
  beyond a single-node or dev deployment — durability and unbounded
  capacity outweigh the added setup cost.

## Useful Commands

```bash
# Tail logs from a given namespace/pod via LogQL (through the HTTP API)
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="default", pod=~"sample-app.*"}' \
  --data-urlencode 'limit=100' | jq -r '.data.result[].values[][1]'

# Count error-level log lines per service in the last hour (LogQL)
# {namespace="default"} |= "level=error" | json | __error__="" [1h]

# List currently indexed label names / values
curl -s http://localhost:3100/loki/api/v1/labels | jq
curl -s http://localhost:3100/loki/api/v1/label/namespace/values | jq

# Check ingester ring status (which ingesters are healthy)
kubectl exec -n monitoring deploy/loki-write -- wget -qO- http://localhost:3100/ring

# Force-run compaction manually (troubleshooting retention issues)
kubectl exec -n monitoring deploy/loki-backend -- \
  wget --post-data='' -qO- http://localhost:3100/compactor/ring

# Check discarded-sample reasons (rate-limit debugging) via Prometheus
# sum by (reason) (rate(loki_discarded_samples_total[5m]))
```

## References

- Loki documentation: https://grafana.com/docs/loki/latest/
- Loki Helm chart: https://github.com/grafana/loki/tree/main/production/helm/loki
- LogQL reference: https://grafana.com/docs/loki/latest/query/
- Loki storage/schema config reference: https://grafana.com/docs/loki/latest/configure/storage/
- Sizing and scaling Loki: https://grafana.com/docs/loki/latest/operations/storage/
- Best practices for labels: https://grafana.com/docs/loki/latest/get-started/labels/bp-labels/
