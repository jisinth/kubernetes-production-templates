# Grafana unified alerting vs Alertmanager (Prometheus)

This repo uses **two** alerting paths and it's important to know which one
owns which alerts:

## Prometheus Alertmanager (`manifests/alertmanager/`, `manifests/prometheus/alert-rules.yaml`)

- Alert **conditions** are `PrometheusRule` objects evaluated by Prometheus
  itself, on Prometheus's own scrape/evaluation cadence.
- Alert **routing/notification** (Slack, PagerDuty, inhibition, silences,
  grouping) is handled by the standalone Alertmanager deployed by
  kube-prometheus-stack.
- This is the primary path for **infrastructure and SLO alerts**
  (HighPodMemory, PodCrashLooping, NodeDiskPressure, HighErrorRate,
  CertificateExpiringSoon — see `manifests/prometheus/alert-rules.yaml`).
- Use this path when: the alert condition is a PromQL expression over
  metrics already in Prometheus, and you want it to survive independently
  of whether Grafana itself is up.

## Grafana Unified Alerting (this directory)

- Grafana 9+ ships its own alerting engine ("unified alerting", enabled via
  `unified_alerting.enabled: true` in `manifests/grafana/values.yaml`) that
  can alert on **any** datasource Grafana can query — not just Prometheus,
  but also Loki (LogQL), Tempo, and mixed multi-datasource queries/
  expressions.
- Alert rules are provisioned as YAML (see `high-cpu-alert.yaml`) mounted
  via the same ConfigMap-provisioning pattern used for dashboards/
  datasources, or created/edited directly in the Grafana UI.
- Grafana's own alerting has its own notification policies, contact points,
  and silences, **separate** from Prometheus Alertmanager — although
  Grafana *can* be pointed at the same external Alertmanager as its
  notification backend if you want a single pane of glass for routing
  (`unified_alerting.alertmanager` config), which is the recommended setup
  here to avoid double-paging.
- Use this path when: the alert needs to query Loki/Tempo, needs a
  Grafana-native visual query builder for on-call engineers who don't write
  PromQL by hand, or needs to combine data from multiple datasources in one
  rule.

## Recommendation used in this repo

- Infra/SLO alerts that only need Prometheus metrics -> Prometheus
  `PrometheusRule` + Alertmanager (`manifests/prometheus/alert-rules.yaml`).
- Log-pattern-based alerts (e.g. "N occurrences of a specific error string
  in the last 5 minutes") and anything needing Loki/Tempo -> Grafana
  unified alerting, provisioned via files in this directory.
- Both notify through the **same** Alertmanager receivers where possible
  (see `manifests/alertmanager/config.yaml`) so on-call doesn't need to
  watch two separate notification systems.

## Example

`high-cpu-alert.yaml` provisions a Grafana-managed alert rule that fires
when a node's CPU utilisation (queried directly against the Prometheus
datasource, from Grafana) exceeds 85% for 10 minutes — functionally similar
to a `PrometheusRule`, included here to show the provisioning file format
for teams that prefer managing certain alerts from the Grafana UI/API
instead of raw PrometheusRule CRDs.

Apply it the same way as datasources — wrap in a ConfigMap labeled for the
provisioning sidecar, or mount as a file under
`/etc/grafana/provisioning/alerting/`.
