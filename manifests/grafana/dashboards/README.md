# Dashboard sidecar convention

Grafana in this repo is configured with the [k8s-sidecar](https://github.com/kiwigrid/k8s-sidecar)
dashboard sidecar (`sidecar.dashboards.enabled: true` in
`manifests/grafana/values.yaml`). The sidecar watches every namespace in the
cluster for `ConfigMap`s carrying the label `grafana_dashboard: "1"`, copies
their JSON payload into Grafana's provisioning directory, and Grafana
hot-reloads it — no restart, no manual "Import Dashboard" click, no chart
upgrade required.

## How to ship a new dashboard

1. Build/export the dashboard JSON from the Grafana UI (Dashboard settings →
   JSON Model), or hand-write it.
2. Wrap it in a `ConfigMap` labeled `grafana_dashboard: "1"`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: kubernetes-cluster-overview
     namespace: monitoring
     labels:
       grafana_dashboard: "1"
   data:
     kubernetes-cluster-overview.json: |
       { ... dashboard JSON ... }
   ```

3. `kubectl apply -f` it. Within `sidecar.dashboards` polling interval
   (default a few seconds) it appears in Grafana under the "General" folder
   (or the folder implied by `foldersFromFilesStructure` if you nest the
   ConfigMap under a directory-style key).

`kubernetes-cluster-overview.json` in this directory is the raw dashboard
JSON — wrap it in the ConfigMap shown above before applying it; it is kept
unwrapped here so it's easy to diff, lint, and edit directly.

## Why the sidecar instead of `dashboardProviders` + baked-in files

- Dashboards can be owned by the teams that write the queries (per-namespace
  ConfigMaps) instead of requiring a Helm chart change + release.
  `searchNamespace: ALL` in `values.yaml` means any namespace can ship one.
- No Grafana pod restart needed to add/update a dashboard.
- Dashboard JSON is still just a Kubernetes manifest, so it's diffable,
  reviewable, and GitOps-friendly like everything else in this repo.

## Conventions

- One dashboard per ConfigMap, one JSON key per ConfigMap (`data.<name>.json`).
- Name the ConfigMap after the dashboard for easy lookup:
  `kubectl get configmap -n monitoring -l grafana_dashboard=1`.
- Prefer datasource **variables** (`${DS_PROMETHEUS}`) over hardcoded
  datasource UIDs so dashboards are portable across environments — see the
  `templating` block in `kubernetes-cluster-overview.json`.
- Keep dashboard UIDs stable once published — changing a UID breaks any
  saved links/bookmarks to that dashboard.
