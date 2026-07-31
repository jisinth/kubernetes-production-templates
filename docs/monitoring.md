# Monitoring

## Stack overview

The observability stack is the "LGTM-ish" combination: Prometheus for metrics, Grafana for dashboards, Loki for logs, Tempo for traces, Alertmanager for alert routing. All five live in the `monitoring` namespace by convention.

| Component | Role | Manifests | Values |
|---|---|---|---|
| Prometheus | Metrics scrape + TSDB + alert rules | `manifests/prometheus/` | `helm-values/prometheus/` |
| Grafana | Dashboards, data source UI | `manifests/grafana/` (`dashboards/`, `datasources/`, `alerts/`, `plugins/`) | `helm-values/grafana/` |
| Loki | Log aggregation | `manifests/loki/` | `helm-values/loki/` |
| Tempo | Distributed tracing backend | `manifests/tempo/` | `helm-values/tempo/` |
| Alertmanager | Alert dedup, grouping, routing | `manifests/alertmanager/` | `helm-values/alertmanager/` |

Cross-cutting dashboards and alert rules that don't belong to a single component live in `manifests/monitoring/`; component-specific dashboards live under `manifests/grafana/dashboards/`.

## Data flow

Prometheus scrapes `/metrics` endpoints (application pods via annotations/ServiceMonitors, plus cluster components like kube-state-metrics and metrics-server). Applications ship logs to stdout/stderr, collected by a log-shipping agent (e.g. Promtail/Grafana Agent) and pushed into Loki. Traces are emitted by instrumented applications via OTLP into Tempo. Grafana queries all three as data sources so metrics, logs, and traces for the same request can be correlated in one place. Prometheus alert rules fire into Alertmanager, which groups/dedupes and routes to receivers (Slack, PagerDuty, email, etc.).

See the sequence diagram in [`architecture/README.md`](../architecture/README.md#monitoring-data-flow).

## Alerting

Alert rules live alongside Prometheus (`manifests/prometheus/`) as `PrometheusRule` CRDs when using the kube-prometheus-stack Helm chart. Alertmanager routing (`manifests/alertmanager/`) defines receivers and routes — split at minimum into `critical` (pages on-call) and `warning` (Slack channel, no page).

## Dashboards

Provision dashboards as code under `manifests/grafana/dashboards/` (JSON or `GrafanaDashboard` CRDs if using the Grafana Operator) rather than clicking them together in the UI — anything not committed here will be lost on a Grafana redeploy.

## Verification

After install, confirm:

```bash
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/grafana 3000:80
kubectl -n monitoring port-forward svc/prometheus-server 9090:80
```

Check the "Targets" page in Prometheus to confirm scrape targets are `UP`, and the Explore tab in Grafana to confirm Loki/Tempo data sources return results.

## Common problems

- Prometheus pod `CrashLoopBackOff` from OOM — bump memory limits or reduce retention/cardinality; see `helm-values/prometheus/values.yaml`.
- No logs in Loki — confirm the log-shipping agent's `DaemonSet` is running on every node and its RBAC allows reading pod logs.
- Alerts not firing — check `PrometheusRule` is picked up (`kubectl -n monitoring get prometheusrule`) and that Alertmanager config matches the rule's labels for routing.
