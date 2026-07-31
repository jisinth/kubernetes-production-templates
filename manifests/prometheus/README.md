# Prometheus

## What is this?

Production-ready manifests and Helm values for running Prometheus on
Kubernetes via the community-maintained `kube-prometheus-stack` chart. This
bundles the Prometheus Operator, Prometheus itself, Alertmanager, node
exporter, and kube-state-metrics, plus this repo's own `ServiceMonitor`,
`PrometheusRule` (alerting), and `PrometheusRule` (recording) resources for
scraping applications and generating alerts.

Use this when you need cluster and application metrics, alerting rules that
fire into Alertmanager (see `manifests/alertmanager/`), and a metrics source
for Grafana dashboards (see `manifests/grafana/`).

## Architecture

```
        ServiceMonitor/PodMonitor (per-app, self-service)
                    |
                    v
   ┌─────────────────────────────────┐
   │      Prometheus Operator        │  watches CRDs, renders Prometheus
   │                                  │  StatefulSet config
   └─────────────────────────────────┘
                    |
                    v
   ┌─────────────────────────────────┐        ┌──────────────┐
   │   Prometheus (StatefulSet, 2x)  │──scrape─│ node-exporter │ (DaemonSet)
   │   local TSDB, 15d retention     │──scrape─│ kube-state-   │
   │   PVC-backed (50Gi gp3)         │         │ metrics       │
   └─────────────────────────────────┘         └──────────────┘
          |                     |
          | remote_write        | alerts (PrometheusRule)
          v (optional)          v
   Thanos/Mimir/Cortex   ┌──────────────┐
   (long-term storage)   │ Alertmanager │──> Slack / PagerDuty / webhook
                         │  (3 replicas) │
                         └──────────────┘
                                |
                                v
                            Grafana (reads Prometheus as a datasource)
```

Prometheus runs as a 2-replica StatefulSet for HA (both replicas scrape
independently and hold identical data — there is no clustering/dedup at the
Prometheus layer itself). Alertmanager runs as a 3-replica gossip cluster so
a single node loss doesn't drop alert delivery or dedup state.

## Prerequisites

- Kubernetes 1.24+
- Helm 3.8+
- A default `StorageClass` that supports `ReadWriteOnce` PVCs (EBS/gp3, PD,
  Azure Disk, etc.) — Prometheus and Alertmanager both need persistent
  storage in this configuration.
- `kubectl` access with permission to create CRDs and cluster-scoped RBAC
  (ClusterRole/ClusterRoleBinding) — the Operator needs to watch nodes/pods
  cluster-wide.
- At least 2 vCPU / 4Gi memory of spare node capacity per Prometheus replica.

## Installation

See `manifests/prometheus/install.md` for the full step-by-step walkthrough.
Quick version:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f helm-values/prometheus.yaml
kubectl apply -f manifests/prometheus/service-monitor.yaml
kubectl apply -f manifests/prometheus/alert-rules.yaml
kubectl apply -f manifests/prometheus/recording-rules.yaml
```

### Upgrading

1. **CRDs before the chart.** `kube-prometheus-stack` bundles the Prometheus Operator CRDs (`ServiceMonitor`, `PrometheusRule`, `Alertmanager`, etc.); a `helm upgrade` normally updates them, but if `crds.enabled: false` (CRDs managed out-of-band, common in GitOps setups), apply the new CRD manifests from the chart's `crds/` directory *before* upgrading the release — an Operator running against stale CRDs can fail to reconcile new fields silently rather than erroring loudly.
2. **Check for a Prometheus major-version bump alongside the chart bump.** The chart's `appVersion` tracks the underlying Prometheus binary; Prometheus 3.x changed several long-standing defaults (UI, some flag names, remote-write-receiver behavior) versus 2.x — read the [Prometheus 3.0 migration guide](https://prometheus.io/docs/prometheus/latest/migration/) if crossing that boundary, don't assume it's a drop-in replacement.
3. **Validate rules against the new version before rolling to production**: `promtool check rules` against the target Prometheus version's promtool binary (rule syntax has occasionally gained new functions/behavior between versions) — run this in CI, not as a post-upgrade discovery.
4. Because Prometheus runs as a StatefulSet, a `helm upgrade` triggers an ordered rolling update (pod 1, then pod 0) — with `replicas: 2` this means one replica is always serving during the upgrade, but confirm `podManagementPolicy` and readiness probes are tuned tightly enough that traffic (Grafana queries, Alertmanager's view of `/api/v1/alerts`) doesn't briefly hit a not-yet-ready replica.

### Migrating from a different monitoring stack

Moving off Datadog/New Relic/a hand-rolled Prometheus (non-Operator) setup:

1. Install `kube-prometheus-stack` alongside the existing system — they don't conflict, both can scrape the same targets simultaneously.
2. Port dashboards and alert thresholds incrementally: recreate the highest-value alerts first as `PrometheusRule` objects (see `alert-rules.yaml`), and validate they fire correctly (compare against the old system's alert history) before treating them as authoritative.
3. Keep both systems paging on-call in parallel for at least one full on-call rotation — silent gaps in alert coverage are far worse than temporary duplicate paging, and the overlap period is what surfaces them.
4. Decommission the old system only once dashboards, alerts, and any downstream integrations (ticketing, status pages) are fully re-pointed at the new stack.

## Verification

```bash
# Pods running and ready
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus

# Confirm the Operator picked up our rules
kubectl get prometheusrules -n monitoring
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://localhost:9090/api/v1/rules | grep -o '"name":"[A-Za-z]*"' | sort -u

# Confirm targets are UP (no 0 scraped targets for sample-app)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="sample-app") | .health'
```

Expect `"up"` for every target and no `"firing"` alerts other than the
built-in `Watchdog` (a deliberately always-firing alert used to confirm the
alerting pipeline itself is alive).

## Configuration

- **Retention**: `prometheus.prometheusSpec.retention` (time-based) and
  `retentionSize` (disk-based) in `values.yaml` — whichever limit is hit
  first triggers compaction/deletion of old blocks.
- **Storage size**: `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate`
  — size for `retention × ingestion rate × bytes/sample`; roughly 1-2 bytes
  per sample per active series is a reasonable starting estimate.
- **Scrape targets**: add a `ServiceMonitor`/`PodMonitor` next to your app
  (see `service-monitor.yaml` for a template) rather than editing Prometheus
  config directly — the Operator discovers them via label selectors set to
  `{}` (all namespaces) in `values.yaml`.
- **Alerting rules**: add groups to `alert-rules.yaml` or ship your own
  `PrometheusRule` object per-team; label it to match `ruleSelector`.
- **Remote write**: uncomment `prometheus.prometheusSpec.remoteWrite` in
  `values.yaml` to ship samples to Thanos/Mimir/Grafana Cloud for long-term
  retention beyond local disk.

## Security

- Prometheus and Alertmanager run as non-root (`runAsUser: 65534`, i.e.
  `nobody`) with `fsGroup` set so they can write to their PVCs.
- The Prometheus UI/API has no built-in authentication — do **not** expose
  it via a public Ingress without an auth proxy (oauth2-proxy, or your
  ingress controller's basic-auth/OIDC annotations) in front of it. Default
  in this repo is `ingress.enabled: false`; prefer `kubectl port-forward` or
  an internal-only Ingress.
- The Prometheus Operator's ServiceAccount needs broad read (list/watch)
  RBAC across the cluster (pods, services, endpoints, nodes) to do service
  discovery — this is inherent to how Prometheus operates and is scoped
  read-only by the chart's default ClusterRole.
- Remote-write credentials (`remoteWrite[].basicAuth`) must reference a
  Kubernetes `Secret`, never be inlined in `values.yaml`.
- Rotate the Alertmanager webhook/Slack/PagerDuty secrets referenced in
  `manifests/alertmanager/config.yaml` via your secrets manager (Sealed
  Secrets, External Secrets Operator, Vault) — this repo only ships
  placeholder URLs.

## Scaling

- **Vertical**: bump `prometheus.prometheusSpec.resources` — memory scales
  roughly with the number of active time series held in the head block, not
  request volume.
- **Horizontal (sharding)**: set `prometheus.prometheusSpec.shards > 1` to
  split scrape targets across multiple StatefulSet replicas (hashed by
  target). Only reach for this once a single Prometheus instance's head
  series count exceeds a few million and vertical scaling is no longer
  practical.
- **Long-term storage**: once local retention alone can't satisfy your
  query/compliance window, add Thanos sidecar/receive or Mimir via
  `remoteWrite` instead of growing local disk indefinitely.
- **Alertmanager**: scale replica count (odd numbers preferred, e.g. 3 or 5)
  for gossip-protocol quorum; all replicas should share the same config so
  any of them can dedupe/route identically.

### High Availability considerations

- **No dedup between Prometheus replicas by default**: both replicas of a 2-replica Prometheus StatefulSet scrape and store the *same* data independently — this buys availability (either can answer a query) but not deduplication or a unified global view. Grafana/Alertmanager querying one replica vs. the other can show micro-differences in scrape timing. For a genuinely deduplicated, globally-queryable view across replicas (and across clusters), add Thanos Query or Mimir in front rather than querying either replica directly.
- **The Prometheus Operator itself is typically single-replica** — `prometheusOperator.replicas` defaults to 1 in most chart configurations because the Operator only reconciles CRDs into config (it's not on the metrics read/write path). A brief Operator outage delays picking up *new* ServiceMonitor/PrometheusRule changes but does not stop already-running Prometheus/Alertmanager pods from scraping or alerting. Raise to 2 only if CRD-reconciliation latency during an Operator restart is itself unacceptable for your change velocity.
- **Zone-aware scheduling matters more for Alertmanager than Prometheus**: losing all 3 Alertmanager replicas to a single zone outage stops all notification delivery cluster-wide even if Prometheus is still evaluating rules correctly; set `alertmanager.alertmanagerSpec.affinity` with zone anti-affinity, mirroring the `topologySpreadConstraints` pattern used for ingress-nginx.
- **PVC-bound StatefulSet pods don't fail over across zones** — a Prometheus replica's PVC is typically zone-local (most cloud block storage), so if that zone goes down, the pod cannot simply reschedule elsewhere with its existing data; the *other* Prometheus replica (in a different zone, if spread correctly) keeps serving, but the failed replica effectively needs to be recreated from scratch once its zone recovers, or scraping resumes from data loss in that replica's window.

## Common Problems

- **`prometheus-operator` OOMKilled during startup on large clusters** —
  the Operator caches all Service/Endpoints/Pod objects it watches. Fix:
  raise `prometheusOperator.resources.limits.memory`, or scope
  `serviceMonitorNamespaceSelector`/`podMonitorNamespaceSelector` to fewer
  namespaces instead of watching the whole cluster.
- **ServiceMonitor exists but target never shows up in `/targets`** —
  usually a label mismatch. Check `kubectl get servicemonitor sample-app -o yaml`
  against the target Service's labels (`spec.selector.matchLabels` on the
  ServiceMonitor must match `metadata.labels` on the Service, not the Pod),
  and confirm the ServiceMonitor's namespace is covered by
  `serviceMonitorNamespaceSelector` (this repo sets it to `{}` = all
  namespaces).
- **PVC stuck `Pending`** — no default StorageClass, or the requested
  `storageClassName` (`gp3` here) doesn't exist in-cluster. Fix:
  `kubectl get storageclass` and update `storageSpec.volumeClaimTemplate.spec.storageClassName`
  to match what's actually available.
- **`too many active series` / high cardinality blowing up memory** —
  usually an app exporting a label with unbounded values (user IDs, request
  IDs, raw URLs). Fix: add a `metricRelabelings` drop rule on the offending
  ServiceMonitor (see the example in `service-monitor.yaml`) and fix the
  exporter at the source.
- **Alerts defined in `alert-rules.yaml` never fire even when the condition
  is clearly true** — check `for:` duration hasn't elapsed yet, and confirm
  the rule was actually loaded: `kubectl get prometheusrule -n monitoring
  general-alert-rules -o yaml` and cross-check against `/rules` in the
  Prometheus UI — a syntax error in one group can silently fail to load the
  whole file depending on chart version.
- **Prometheus pod stuck in `CrashLoopBackOff` after a config change** —
  almost always a bad PromQL expression in a `PrometheusRule`. Validate
  locally first: `promtool check rules manifests/prometheus/alert-rules.yaml`.
- **The two Prometheus replicas disagree on whether an alert is firing** — since each replica scrapes and evaluates independently, a brief scrape failure or timing skew on one replica can cause it to lag the other by one evaluation cycle right at a threshold boundary. This is expected with unclustered replicas, not a bug; Alertmanager's own dedup (both replicas send the same alert, Alertmanager collapses it) papers over this in normal operation — if it doesn't, check both replicas' `/api/v1/rules` output for evaluation errors rather than assuming the rule itself is broken.
- **Upgrade completes but `kube-state-metrics` stops reporting a resource type** — a k8s API version bump (e.g. a removed/renamed field) between cluster upgrades can silently drop metrics for that resource if `kube-state-metrics`'s own version predates support for the new API shape. Check `kube_state_metrics_build_info` and cross-reference its supported Kubernetes version range against your cluster version before assuming a dashboard gap is a Prometheus scraping issue.

## Best Practices

- Validate rule files with `promtool check rules` and `promtool test rules`
  in CI before applying — a bad PromQL expression should fail a pipeline,
  not a live cluster.
- Keep alert `for:` durations long enough to avoid flapping (5-15m for most
  infra alerts) but short enough to page before customer impact.
- Every alert should have a `summary`, a `description`, and ideally a
  `runbook_url` — an alert nobody knows how to act on is noise, not signal.
- Prefer recording rules for any PromQL expression reused across multiple
  dashboards/alerts — computing `rate()` aggregations once at scrape-adjacent
  cadence is far cheaper than recomputing on every dashboard refresh.
- Namespace-scope `serviceMonitorSelector`/rule ownership per team where
  possible so one team's bad ServiceMonitor can't silently break scraping
  for another.
- Never point production alerting at `remoteWrite` only — always keep local
  Prometheus alerting rules independent of any downstream long-term-storage
  system so alerting still works if that system is down.

## Useful Commands

```bash
# Check Prometheus config was reloaded successfully
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://localhost:9090/-/healthy

# Reload config without restarting (Operator normally handles this via SIGHUP)
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget --post-data='' -qO- http://localhost:9090/-/reload

# Validate rules before applying
promtool check rules manifests/prometheus/alert-rules.yaml
promtool check rules manifests/prometheus/recording-rules.yaml

# List currently firing alerts
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | select(.state=="firing")'

# Top 10 highest-cardinality metrics (cardinality troubleshooting)
curl -s localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:10]'

# PromQL: current error ratio per service (uses recording-rules.yaml output)
curl -sG localhost:9090/api/v1/query --data-urlencode \
  'query=namespace_service:http_error_ratio:rate5m' | jq .

# Watch Prometheus Operator logs while debugging a ServiceMonitor
kubectl logs -n monitoring -l app=kube-prometheus-stack-operator -f
```

## References

- kube-prometheus-stack chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Prometheus Operator API docs: https://prometheus-operator.dev/docs/api-reference/api/
- Prometheus documentation: https://prometheus.io/docs/introduction/overview/
- PromQL reference: https://prometheus.io/docs/prometheus/latest/querying/basics/
- Awesome Prometheus alerts (community rule library): https://samber.github.io/awesome-prometheus-alerts/
- Alerting best practices: https://prometheus.io/docs/practices/alerting/
