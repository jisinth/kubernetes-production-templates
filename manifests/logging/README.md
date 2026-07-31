# Logging Architecture

## What is this?

This folder is the **logging strategy documentation hub**, describing how
logs flow from a running container to a queryable interface, plus one
concrete manifest (`promtail-values.yaml`) for the log-shipping agent. The
Loki deployment itself (the log storage/query backend) lives in
[`../loki/`](../loki/README.md), and dashboards/exploration live in
[`../grafana/`](../grafana/README.md) — this document explains how the
three fit together.

The short version: **application stdout/stderr → node-level log agent
(Promtail) → Loki (storage + indexing) → Grafana (query + visualization)**.
Applications should never write logs to a file inside the container or ship
logs directly to a backend themselves — writing to stdout/stderr and
letting the platform handle collection is what makes logging infrastructure
swappable and keeps application code free of logging-backend concerns.

## Architecture

```
   Container process
        │ writes to stdout/stderr
        ▼
   Container runtime (containerd/CRI-O)
        │ writes to /var/log/pods/... on the node (CRI log format)
        ▼
   Promtail DaemonSet (one per node, promtail-values.yaml)
        │ tails node log files, attaches Kubernetes metadata as labels
        │ (namespace, pod, container, node, app) via pipelineStages
        ▼
   Loki (../loki/) — indexes labels, stores raw log lines as compressed
        │              chunks in object storage (not a full-text index —
        │              Loki is "index the metadata, grep the content")
        ▼
   Grafana (../grafana/) — LogQL queries, Explore view, log panels
        │                   correlated with Prometheus metrics via
        │                   shared labels (namespace/pod/app)
        ▼
   On-call engineer
```

Why this shape instead of each app shipping logs itself: a node-level
agent means zero logging code in the application, works uniformly across
every language/runtime, and survives a container crash (the agent reads
from the node's log files, not from an in-process log stream that dies
with the container).

## Prerequisites

- Loki deployed and reachable at a stable in-cluster address — see
  [`../loki/README.md`](../loki/README.md) for its own prerequisites
  (object storage backend, retention config).
- Grafana deployed with a Loki datasource configured — see
  [`../grafana/README.md`](../grafana/README.md).
- Nodes running containerd or CRI-O (the `cri` pipeline stage in
  `promtail-values.yaml` assumes CRI-formatted log lines — adjust if any
  node still runs dockershim-style logs).

## Installation

```bash
# 1. Deploy Loki first (see ../loki/README.md for its own install steps)

# 2. Deploy Promtail, pointed at Loki's gateway Service
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install promtail grafana/promtail \
  -n logging --create-namespace \
  -f manifests/logging/promtail-values.yaml

# 3. Add/verify the Loki datasource in Grafana (see ../grafana/datasources/)
```

## Verification

```bash
# Promtail running on every node
kubectl -n logging get pods -o wide

# Confirm Promtail is actually shipping (check its own logs for errors)
kubectl -n logging logs -l app.kubernetes.io/name=promtail --tail=50

# Query Loki directly for a known-recent log line
logcli query '{namespace="default"}' --limit=20 \
  --addr=http://loki-gateway.loki.svc.cluster.local

# In Grafana: Explore -> Loki datasource -> query
#   {namespace="default", app="web-app"} |= "error"
```

## Configuration

- **`promtail-values.yaml`** — Loki push endpoint, CRI log-format parsing,
  a noisy-log-line drop example, and Kubernetes-metadata relabeling so log
  labels (`namespace`, `app`, `node`) match the label names Prometheus
  already uses — this is what makes "jump from a metric to its logs"
  workflows in Grafana possible.
- Retention, storage backend, and multi-tenancy for the logs themselves are
  configured in [`../loki/`](../loki/README.md), not here.
- Dashboards and saved LogQL queries live in
  [`../grafana/dashboards/`](../grafana/dashboards/).

## Security

- **Logs frequently contain sensitive data** (tokens accidentally logged,
  PII in request bodies) — add `pipelineStages` drop/replace rules in
  `promtail-values.yaml` for known-sensitive patterns, and treat this as
  an ongoing hygiene task, not a one-time filter.
- **Scope Loki multi-tenancy (`tenant_id`) per team/namespace** if
  multiple teams share one Loki deployment, so one team can't query
  another's logs.
- **RBAC-gate the Grafana Loki datasource** the same way you would any
  other sensitive data source — log access is often broader than it needs
  to be by default.
- **Promtail runs privileged enough to read every node's log files** —
  it's a DaemonSet with hostPath access to `/var/log`; treat its
  ServiceAccount/PSA exemption the same way you'd treat any other
  node-level agent (see `../pod-security/namespace-labels.yaml`'s
  `privileged` tier guidance for what namespace it should run in).
- Encrypt log data in transit (TLS to Loki's gateway) and at rest (the
  object-storage backend Loki uses).

## Scaling

- Promtail's resource needs scale with per-node log volume, not cluster
  size directly — nodes running high-log-volume workloads may need higher
  `resources.limits` than the default in `promtail-values.yaml`.
- Loki's read/write path scaling (ingesters, queriers, compactors) is
  covered in [`../loki/README.md`](../loki/README.md) — this folder only
  covers the shipping side.
- Use `pipelineStages` drop rules aggressively for high-volume, low-value
  logs (health-check noise, debug-level logs in production) — the cheapest
  log to store and query is the one you never ship.
- Consider sampling or drop rules per-namespace if one noisy namespace
  threatens to dominate ingestion capacity/cost for everyone else sharing
  the Loki deployment.

## Common Problems

- **Logs missing entirely in Grafana for a specific pod** — check
  Promtail is actually running on that pod's node
  (`kubectl -n logging get pods -o wide | grep <node>`); a node without a
  Promtail pod produces zero logs regardless of how healthy the
  application is.
- **Logs delayed by minutes** — usually a Loki-side ingestion backlog, not
  a Promtail problem; check `../loki/README.md#common-problems` for
  ingester/distributor troubleshooting.
- **Labels don't match between Prometheus metrics and Loki logs for the
  same pod** — the `extraRelabelConfigs` in `promtail-values.yaml` must
  produce the same label *names* your Prometheus ServiceMonitors use
  (`app`, not `app_kubernetes_io_name`) or Grafana's "logs for this panel"
  correlation feature won't find matching log streams.
- **Promtail pod `CrashLoopBackOff` after a Loki URL change** — Promtail
  fails closed if it can't reach its configured `clients[].url`; verify
  the Loki gateway Service name/namespace after any Loki redeploy.
- **Multi-line stack traces split into separate log lines** — add a
  `multiline` pipeline stage (with a regex matching the start of a new
  log entry) to `promtail-values.yaml`'s `pipelineStages`, or stack traces
  will show up as dozens of disconnected single-line entries in Loki.

## Best Practices

- Log structured (JSON) from applications where possible — Loki's LogQL
  can parse JSON fields (`| json`) for filtering without needing regex
  against unstructured text.
- Keep label cardinality low in Promtail's relabeling — Loki indexes
  labels, not log content; a high-cardinality label (like a raw request
  ID) turns Loki's index into something closer to (much slower than) a
  full-text search engine.
- Never log secrets/credentials — treat this as a code-review checklist
  item, not something to catch after the fact with Promtail drop rules
  alone.
- Correlate logs and metrics via shared labels (namespace/app/pod) so
  on-call can pivot from a Prometheus alert straight to the relevant log
  stream in Grafana without hand-writing a LogQL query from scratch.
- Route logging alerts (Promtail down, Loki ingestion errors) through the
  same Alertmanager pipeline as metric alerts — a broken logging pipeline
  during an incident is itself an incident.

## Useful Commands

```bash
# Check Promtail pod status across all nodes
kubectl -n logging get pods -o wide

# Tail Promtail's own logs for shipping errors
kubectl -n logging logs -l app.kubernetes.io/name=promtail -f

# Query Loki directly via logcli (bypassing Grafana)
logcli query '{namespace="default",app="web-app"}' --since=1h \
  --addr=http://loki-gateway.loki.svc.cluster.local

# Check what labels Promtail is currently producing
logcli labels --addr=http://loki-gateway.loki.svc.cluster.local

# Reload Promtail config without restarting (if --config.expand-env and
# reload endpoint are enabled)
kubectl -n logging exec ds/promtail -- kill -HUP 1
```

## References

- [Promtail documentation](https://grafana.com/docs/loki/latest/send-data/promtail/)
- [Loki documentation](../loki/README.md) (this repo) and
  [upstream Loki docs](https://grafana.com/docs/loki/latest/)
- [LogQL query language](https://grafana.com/docs/loki/latest/query/)
- [Grafana Explore](https://grafana.com/docs/grafana/latest/explore/)
- [Grafana Agent (Promtail alternative)](https://grafana.com/docs/agent/latest/)
