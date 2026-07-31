# metrics-server

## What is this?

`metrics-server` is a cluster-wide aggregator of resource usage data. It scrapes CPU/memory metrics from each node's kubelet Summary API and exposes them through the Kubernetes `metrics.k8s.io` aggregated API. It is what makes `kubectl top nodes` / `kubectl top pods` work, and it's the data source the Horizontal Pod Autoscaler (HPA) and Vertical Pod Autoscaler (VPA) use to make scaling decisions.

It is not a monitoring system — it holds no history, has no alerting, and only exposes current usage. For dashboards, alerting, and long-term metrics, see `manifests/prometheus/` and `manifests/grafana/`. metrics-server exists specifically to serve the live autoscaling API.

## Architecture

```
kubelet (each node)  ──Summary API (10250/https)──▶  metrics-server pods (2 replicas)
                                                          │
                                                          ▼
                                                  metrics.k8s.io/v1beta1
                                                  (APIService, aggregated
                                                   into the main API server)
                                                          │
                                    ┌─────────────────────┼─────────────────────┐
                                    ▼                     ▼                     ▼
                              kubectl top          HorizontalPodAutoscaler   VerticalPodAutoscaler
```

metrics-server itself is stateless — a crash just means a gap in current metrics until it restarts; nothing else in the cluster is directly affected except HPA decisions pausing.

## Prerequisites

- Kubernetes 1.25+ (works well below that too, but this repo targets 1.25+).
- Kubelet's Summary API reachable from the metrics-server pods (usually the default; can be blocked by restrictive `NetworkPolicy` or firewall rules between the node network and pod network).
- Ideally, kubelet serving certificates that chain to a CA the cluster trusts, so metrics-server can verify TLS rather than skipping verification.

## Installation

Via Helm (recommended):

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm repo update
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  -f manifests/metrics-server/values.yaml \
  --wait
```

Via upstream manifest (provides the ServiceAccount, ClusterRole(s), Service, and APIService that [`deployment.yaml`](deployment.yaml) in this folder assumes exist) plus this repo's customized Deployment:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl apply -f manifests/metrics-server/deployment.yaml   # overrides the Deployment with our resource/security settings
```

### Upgrading

metrics-server tracks the `metrics.k8s.io` aggregated API contract closely with Kubernetes releases — check the [compatibility matrix](https://github.com/kubernetes-sigs/metrics-server#compatibility-matrix) before bumping across a Kubernetes minor version boundary, not just a metrics-server version boundary.

1. Because metrics-server is stateless and HPA/VPA degrade gracefully (they just pause scaling decisions, they don't crash) during a brief gap, upgrades are low-risk — a standard rolling `helm upgrade` is sufficient, no special draining needed.
2. After upgrading, immediately re-check `kubectl top nodes` and `kubectl describe hpa` on a couple of autoscaled workloads — a version bump that changes a default flag (e.g. `--metric-resolution`) can silently change HPA responsiveness without any error being surfaced.
3. If migrating off a very old release (pre-`v0.6`) that used `--kubelet-preferred-address-types=InternalDNS,InternalIP,ExternalDNS,ExternalIP,Hostname`, review whether the flag defaults changed — some historical upgrades altered the default address-type preference order, which can break kubelet reachability on clusters relying on non-default node addressing.

## Verification

```bash
kubectl get deployment metrics-server -n kube-system
kubectl get apiservice v1beta1.metrics.k8s.io          # AVAILABLE: True

kubectl top nodes
kubectl top pods -A
```

If `kubectl top` returns `error: metrics not available yet`, wait ~60 seconds after install — the first scrape cycle needs to complete.

## Configuration

- `--kubelet-preferred-address-types` — controls which node address type metrics-server uses to reach kubelets; `InternalIP` first works for nearly all cloud and on-prem clusters.
- `--metric-resolution=15s` — how often metrics-server refreshes from kubelets; HPA polls metrics-server roughly every 15s by default, so resolutions much longer than that add lag to scaling decisions.
- `--kubelet-insecure-tls` — **avoid by default**. It's shown commented out in both [`values.yaml`](values.yaml) and [`deployment.yaml`](deployment.yaml). Only enable it if kubelet serving certs genuinely aren't verifiable in your cluster (common on some older/self-managed clusters); the correct long-term fix is enabling proper kubelet serving certificate rotation (`--rotate-server-certificates` on kubelets, or your managed cluster's equivalent) rather than skipping TLS verification cluster-wide.
- `serviceMonitor.enabled` — scrapes metrics-server's own `/metrics` endpoint (about itself, not node/pod usage) into Prometheus for observability of the aggregator itself; requires the Prometheus Operator CRDs.

## Security

- Runs as non-root, read-only root filesystem, all capabilities dropped ([`values.yaml`](values.yaml) `containerSecurityContext`) — it needs no elevated privileges to scrape kubelet APIs over HTTPS.
- Prefer verified TLS to kubelets over `--kubelet-insecure-tls`; the insecure flag disables certificate validation for every kubelet in the cluster, which is a meaningful trust reduction for a component with cluster-wide read access to usage data.
- The `system:metrics-server` ClusterRole (installed via the upstream manifest/chart) grants read access to `nodes/stats`, `nodes/metrics`, and `pods` — don't broaden it; nothing else needs those permissions.
- RBAC-gate who can query the `metrics.k8s.io` API in multi-tenant clusters if per-pod resource usage is considered sensitive (it can reveal traffic/load patterns).

## Scaling

- `replicas: 2` with pod anti-affinity is enough for HA in nearly all cluster sizes — metrics-server's own resource needs scale with node/pod *count*, not cluster complexity, and its default requests handle clusters up to several hundred nodes comfortably.
- Very large clusters (1000+ nodes): raise `resources.requests`/`limits` and consider `--metric-resolution` slightly higher than 15s to reduce kubelet scrape load, since HPA responsiveness is usually not the bottleneck at that scale.
- metrics-server does not shard — every replica independently scrapes every kubelet; replicas provide availability, not horizontal capacity.

### High Availability considerations

- **No leader election, no shared state** — unlike cert-manager or external-dns, every metrics-server replica independently scrapes and serves; there's no split-brain risk from running N replicas, and the aggregated API layer (`kube-apiserver`) load-balances requests across whichever replicas are ready.
- **Pod anti-affinity, not just replica count, is what buys you availability** — 2 replicas scheduled onto the same node defeats the purpose; set `podAntiAffinity` (already in [`values.yaml`](values.yaml)) so a single node failure can't take down every replica simultaneously.
- **PDB matters less here than for stateful/ingress-facing components** — a brief total outage degrades to "HPA decisions pause, `kubectl top` errors" rather than a user-facing incident, so a `minAvailable: 1` PDB is normally sufficient rather than the stricter budgets used for ingress-nginx.
- **The real availability risk is upstream, not metrics-server itself**: if the `kube-apiserver`'s aggregation layer or the `metrics.k8s.io` `APIService` registration breaks (e.g. a botched cluster upgrade), metrics-server pods can be perfectly healthy while `kubectl top` and HPA both fail — always check `kubectl get apiservice v1beta1.metrics.k8s.io` alongside pod health when diagnosing an outage.

## Common Problems

1. **`kubectl top nodes` → `error: metrics not available yet`** — either just installed (wait ~1 minute) or the APIService isn't registered/available. Check `kubectl get apiservice v1beta1.metrics.k8s.io -o yaml` for `status.conditions`.
2. **`x509: cannot validate certificate` in metrics-server logs** — kubelet serving certs aren't trusted by metrics-server's CA bundle. Either fix kubelet certificate rotation/signing, or as a stopgap uncomment `--kubelet-insecure-tls` (understand the tradeoff above before doing so).
3. **HPA shows `<unknown>` for current CPU/memory** — metrics-server itself is up, but the target Deployment's pods don't have `resources.requests` set (HPA needs a request baseline to compute utilization percentage), or the pod is too new for a metrics sample yet. Set explicit `resources.requests` on the target workload.
4. **metrics-server pod `CrashLoopBackOff` with `dial tcp ... connect: no route to host`** — a `NetworkPolicy` or firewall is blocking metrics-server pods from reaching kubelets on port 10250. Add an explicit allow rule from the `kube-system` (or wherever metrics-server runs) namespace to the node network on that port.
5. **Metrics go stale/flat during a large rolling restart or node pool upgrade** — a mass pod churn event can transiently outpace metrics-server's 15s scrape interval, showing the same CPU/memory value across several samples. This is a real staleness gap, not a bug; HPA's own stabilization windows (`behavior.scaleUp/scaleDown.stabilizationWindowSeconds`) are designed to tolerate exactly this kind of short-lived noise — don't shorten `--metric-resolution` reactively during an incident as a fix.
6. **A service mesh sidecar breaks kubelet scraping unexpectedly** — if metrics-server itself is enrolled into a mesh with strict mTLS (e.g. its egress traffic gets intercepted), scrapes to kubelet's HTTPS port can fail cert validation even though direct connectivity works. Exclude metrics-server's pod from mesh sidecar injection (it needs direct node-network reachability, not mesh-internal service-to-service semantics) rather than debugging it as a kubelet TLS issue.

## Best Practices

- Always set `resources.requests` on every workload you intend to autoscale — without it, HPA has no baseline to compute utilization against, regardless of metrics-server working correctly.
- Avoid `--kubelet-insecure-tls` in production; treat it as a temporary workaround with a tracked follow-up to fix kubelet certificate trust.
- Run 2+ replicas with anti-affinity; metrics-server going fully down pauses all HPA scaling decisions cluster-wide until it recovers.
- Don't rely on metrics-server for historical data, dashboards, or alerting — it only holds the most recent sample. Use Prometheus (`manifests/prometheus/`) for anything beyond "what's the current usage."
- Keep the metrics-server version reasonably current — it tracks Kubernetes API changes and kubelet Summary API behavior across releases.

## Useful Commands

```bash
# Current usage
kubectl top nodes
kubectl top pods -A --sort-by=cpu
kubectl top pods -A --sort-by=memory

# Confirm the aggregated API is healthy
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml

# Raw metrics API query (useful for debugging HPA)
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/nodes" | jq .
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/production/pods" | jq .

# Logs (TLS/connectivity errors show here)
kubectl logs -n kube-system -l app.kubernetes.io/name=metrics-server -f

# Check an HPA's view of current metrics
kubectl describe hpa <hpa-name> -n production
```

## References

- [metrics-server GitHub](https://github.com/kubernetes-sigs/metrics-server)
- [metrics-server Helm chart](https://github.com/kubernetes-sigs/metrics-server/tree/master/charts/metrics-server)
- [Kubernetes Metrics API concept docs](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/)
- [Horizontal Pod Autoscaler docs](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [metrics-server requirements & known issues](https://github.com/kubernetes-sigs/metrics-server#requirements)
