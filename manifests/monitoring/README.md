# Monitoring Strategy

## What is this?

This folder is the **monitoring strategy documentation hub**, not a
manifest folder — it defines what we measure (golden signals), what we
promise (SLOs), and how dashboards are managed (as code, in Git), before
you look at the actual Prometheus/Grafana/Alertmanager configuration. The
manifests that implement this strategy live in
[`../prometheus/`](../prometheus/README.md) (metrics collection + alerting
rules), [`../grafana/`](../grafana/README.md) (dashboards + datasources),
and [`../alertmanager/`](../alertmanager/README.md) (alert routing) — this
document is the policy those tools are configured to satisfy.

## Architecture

```
   This document (policy: golden signals, SLOs, dashboard ownership)
                    │
     ┌──────────────┼───────────────────┐
     ▼               ▼                   ▼
../prometheus/  ../grafana/       ../alertmanager/
(scrape, store,  (visualize,       (route, dedupe,
 evaluate rules)  dashboards-       silence, notify)
                   as-code)
```

See [`../prometheus/README.md`](../prometheus/README.md) for the metrics
collection architecture, [`../grafana/README.md`](../grafana/README.md)
for dashboard provisioning, and
[`../alertmanager/README.md`](../alertmanager/README.md) for alert routing
— this document only covers the *what and why* that those manifests
implement.

## Prerequisites

- Prometheus, Grafana, and Alertmanager deployed per their respective
  READMEs.
- Agreement from service owners on SLOs before encoding them as
  alerting rules — an SLO nobody agreed to is just an opinion with a
  Prometheus query attached.

## Installation

Nothing to install from this folder directly. This document records the
monitoring principles those manifests should implement:

**The four golden signals** (Google SRE Book), tracked for every
user-facing service:

| Signal | What it measures | Typical PromQL shape |
|--------|-------------------|------------------------|
| Latency | Time to serve a request (split success vs. error latency) | `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))` |
| Traffic | Demand on the system | `sum(rate(http_requests_total[5m]))` |
| Errors | Rate of failed requests | `sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` |
| Saturation | How "full" the service is (CPU, memory, queue depth, connection pool) | `sum(container_memory_working_set_bytes) / sum(kube_pod_container_resource_limits{resource="memory"})` |

**SLO discipline**: every user-facing service should have an availability
SLO (e.g., 99.9% successful requests over a rolling 30-day window) with an
explicit **error budget** — encode the SLO as a Prometheus recording rule
and alert on error-budget *burn rate*, not on raw instantaneous error rate
(burn-rate alerting catches both fast, severe outages and slow, sustained
degradation without paging on every transient blip).

**Dashboards as code**: every dashboard is a JSON file committed to
[`../grafana/dashboards/`](../grafana/dashboards/) and provisioned via
Grafana's sidecar/provisioning mechanism — never hand-edited in the UI and
left uncommitted. A dashboard that only exists in the UI disappears on the
next Grafana redeploy and can't be code-reviewed.

## Verification

```bash
# Confirm the golden-signal recording rules are evaluating
kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 'job:http_requests:rate5m'

# Confirm dashboards-as-code actually reflects what's committed
# (no drift between Git and the live Grafana instance)
diff <(curl -s http://grafana.monitoring.svc/api/dashboards/uid/<uid> | jq .dashboard) \
     <(cat manifests/grafana/dashboards/<name>.json | jq .)

# Confirm an SLO burn-rate alert fires under synthetic error injection
# (fault-inject in a non-prod namespace, watch Alertmanager)
```

## Configuration

The knobs that implement this policy live in the sibling folders:

- **Scrape targets, retention, recording/alerting rules** →
  [`../prometheus/`](../prometheus/README.md)
- **Dashboards, datasources** → [`../grafana/`](../grafana/README.md)
- **Alert routing, silences, notification channels** →
  [`../alertmanager/`](../alertmanager/README.md)
- **Distributed tracing** (to explain *why* latency/errors are high, once
  golden signals show a problem) → [`../tempo/`](../tempo/README.md)
- **Logs** (to explain the specifics of an individual failure) →
  [`../logging/README.md`](../logging/README.md) and
  [`../loki/`](../loki/README.md)

## Security

- Golden-signal dashboards and SLO burn-rate data are often shared broadly
  (status pages, exec reporting) — make sure any Grafana dashboard with a
  public/wide-audience link doesn't leak infrastructure details (internal
  hostnames, error messages with stack traces) alongside the metrics.
- Recording/alerting rules should not embed credentials or internal
  secrets in their labels/annotations — alert payloads often get forwarded
  to third-party notification channels (Slack, PagerDuty).
- See [`../prometheus/README.md#security`](../prometheus/README.md) and
  [`../grafana/README.md`](../grafana/README.md) for RBAC/auth on the
  tools themselves.

## Scaling

- As service count grows, standardize golden-signal instrumentation via a
  shared library/middleware (so every service emits
  `http_requests_total`/`http_request_duration_seconds` with consistent
  label names) rather than each team inventing its own metric names —
  this is what makes shared, reusable dashboards possible instead of one
  bespoke dashboard per service.
- Push SLO ownership to individual service teams once the org outgrows a
  single platform team hand-writing every alerting rule — provide a
  templated "SLO starter kit" (recording rules + burn-rate alert + starter
  dashboard) teams instantiate for their own service rather than a
  fully centralized monitoring team as a bottleneck.
- See [`../prometheus/README.md#scaling`](../prometheus/README.md) for the
  actual metrics-pipeline scaling (sharding, remote-write, retention).

## Common Problems

- **Alert fatigue from raw threshold alerts** (e.g., "CPU > 80%") instead
  of SLO burn-rate alerts — raw thresholds page on transient blips and get
  silenced/ignored over time. Migrate to multi-window, multi-burn-rate
  alerting tied to an actual SLO.
- **Dashboards drift from Git** because someone edited one live in the
  Grafana UI "just this once" — enforce dashboards-as-code by making the
  Grafana UI read-only for dashboards outside of an explicit "scratch/dev"
  folder, and always commit the JSON export back.
- **Golden signals measured inconsistently across services** — one
  service's "error rate" excludes 4xx, another's includes them; agree on
  and document a shared definition per signal (see the table above) rather
  than letting each dashboard define errors differently.
- **SLOs defined but never revisited** — an SLO set once and forgotten
  drifts from what the business actually needs; review SLO targets and
  actual attainment quarterly.
- See [`../prometheus/README.md#common-problems`](../prometheus/README.md)
  and [`../alertmanager/README.md`](../alertmanager/README.md) for
  mechanism-level issues (scrape failures, routing misconfiguration).

## Best Practices

- Instrument for the four golden signals on every user-facing service
  before adding bespoke, service-specific metrics — the golden signals
  answer "is this service healthy" for any service, generically.
- Alert on symptoms (SLO burn rate, user-visible error rate) rather than
  causes (a specific pod restarted) — causes are for dashboards/runbooks
  to investigate once a symptom-based alert has already fired.
- Keep every dashboard's JSON in Git under `../grafana/dashboards/`
  with a clear owner (a label or a comment in the PR) so a stale/broken
  dashboard has someone to page.
- Treat error budgets as a real product/engineering tradeoff lever — a
  service burning its error budget fast is a legitimate reason to pause
  feature work for reliability work, not just a monitoring curiosity.
- Cross-link golden-signal dashboards to their corresponding logs
  (`../logging/`) and traces (`../tempo/`) so on-call has a single-click
  path from "metric looks bad" to "here's the specific failing request."

## Useful Commands

```bash
# See ../prometheus/README.md#useful-commands and
# ../grafana/README.md#useful-commands for tool-level commands. Quick
# links most relevant to strategy verification:

# Check current error-budget burn rate for a service (adjust query/labels)
kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  'slo:error_budget:burn_rate5m{service="web-app"}'

# Export a dashboard's current live JSON to diff against Git
curl -s -H "Authorization: Bearer $GRAFANA_TOKEN" \
  http://grafana.monitoring.svc/api/dashboards/uid/<uid> | jq .dashboard
```

## References

- [Google SRE Book: Monitoring Distributed Systems (golden signals)](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Google SRE Book: Service Level Objectives](https://sre.google/sre-book/service-level-objectives/)
- [Multi-window, multi-burn-rate alerting](https://sre.google/workbook/alerting-on-slos/)
- [Prometheus manifests (this repo)](../prometheus/README.md)
- [Grafana manifests (this repo)](../grafana/README.md)
- [Grafana dashboards-as-code / provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards)
