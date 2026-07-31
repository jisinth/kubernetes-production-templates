# Grafana

## What is this?

Production-ready manifests and Helm values for running Grafana on
Kubernetes, pre-wired to the Prometheus, Loki, and Tempo stacks in this
repo. Includes dashboard/datasource sidecar provisioning (no manual
"Import Dashboard" clicks needed), a Grafana unified-alerting example, and
a recommended plugin list.

## Architecture

```
   ┌───────────────────────────────────────────┐
   │                Grafana (2 replicas)        │
   │  ┌───────────────┐  ┌───────────────────┐  │
   │  │ dashboard      │  │ datasource         │  │
   │  │ sidecar        │  │ sidecar            │  │
   │  │ (k8s-sidecar)  │  │ (k8s-sidecar)      │  │
   │  └───────┬────────┘  └─────────┬─────────┘  │
   │          │ watches ConfigMaps  │             │
   │          │ grafana_dashboard=1 │ grafana_    │
   │          │                     │ datasource=1│
   └──────────┼─────────────────────┼─────────────┘
              v                     v
   Any namespace's dashboard   datasources/datasources.yaml
   ConfigMaps (self-service)   (Prometheus, Loki, Tempo)
              |
              v
   ┌────────────────────────────────────────────┐
   │  Datasources queried at render/alert time   │
   │  Prometheus  |  Loki  |  Tempo              │
   └────────────────────────────────────────────┘
```

Grafana itself is stateless aside from its SQLite/Postgres metadata DB
(users, orgs, alert state, starred dashboards) — persisted via the PVC in
`values.yaml`. Dashboards and datasources are provisioned declaratively via
ConfigMaps rather than living only in that DB, so a PVC loss doesn't lose
your dashboards.

## Prerequisites

- Kubernetes 1.24+, Helm 3.8+
- `manifests/prometheus/` already installed and reachable at
  `kube-prometheus-stack-prometheus.monitoring.svc:9090` (or update the URL
  in `datasources/datasources.yaml`).
- `manifests/loki/` and `manifests/tempo/` installed if you want log/trace
  correlation (Grafana works fine with just Prometheus if those aren't
  deployed yet — just don't provision those datasources).
- A pre-created `Secret` with admin credentials (see Installation).

## Installation

```bash
# 1. Admin credentials — never put these in values.yaml directly
kubectl create secret generic grafana-admin-credentials \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"

# 2. Install
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --create-namespace \
  -f helm-values/grafana.yaml

# 3. Provision datasources and a starter dashboard
kubectl apply -f manifests/grafana/datasources/datasources.yaml
kubectl apply -f manifests/grafana/dashboards/   # if wrapped as a ConfigMap, see dashboards/README.md

# 4. (Optional) Grafana-managed alert rule example
kubectl apply -f manifests/grafana/alerts/high-cpu-alert.yaml   # after wrapping per alerts/README.md
```

### Upgrading

1. **Dashboard schema version**: dashboard JSON carries a `schemaVersion` field; Grafana auto-migrates older dashboards to the running version's schema on load, but a very old exported dashboard (schema version from several majors back) can occasionally lose panel settings during that auto-migration. Open and re-save (re-export) any dashboard sourced from an old export after a major Grafana upgrade, and diff the committed ConfigMap JSON against what Grafana now renders.
2. **Plugin compatibility**: check each installed plugin's own compatibility range against the target Grafana version before upgrading — a plugin built against an older Grafana API can fail to load post-upgrade with an unhelpful console error rather than a clear version-mismatch message. Test in a non-prod Grafana instance with the same `plugins:` list first.
3. **Unified alerting schema changes**: Grafana's alerting engine has changed its internal storage format across major versions (legacy alerting → unified alerting was the biggest one). If any Grafana-managed alert rules exist (`manifests/grafana/alerts/`), confirm they still evaluate correctly post-upgrade — `grafana-cli` or the Alerting UI's rule list is the fastest way to spot a rule that silently stopped evaluating.
4. If running with SQLite (single replica, no `database:` override), take a PVC snapshot or `sqlite3 .dump` backup immediately before any major version upgrade — SQLite schema migrations are one-way, and a failed upgrade generally can't be rolled back by simply reverting the image tag.

### Migrating existing dashboards into this repo

1. Export the dashboard's JSON from an existing Grafana instance (dashboard settings → JSON Model, or `GET /api/dashboards/uid/<uid>`).
2. Strip instance-specific IDs (`id`, top-level `uid` if you want Grafana to assign a fresh one) and replace hardcoded datasource UIDs with the `${DS_PROMETHEUS}`-style template variables this repo's dashboards use, so the dashboard is portable across environments.
3. Wrap the JSON in a ConfigMap labeled `grafana_dashboard: "1"` per `dashboards/README.md`, commit it under `manifests/grafana/dashboards/`, and apply — the sidecar picks it up without a Grafana restart.
4. Delete the manually-created dashboard from the old instance (or mark it read-only) once the ConfigMap-provisioned copy is confirmed identical, to avoid two divergent copies of the same dashboard going out of sync.

## Verification

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
kubectl port-forward -n monitoring svc/grafana 3000:80

# Retrieve the admin password if you lost it
kubectl get secret grafana-admin-credentials -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Confirm datasources loaded
curl -s -u admin:$(kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d) \
  http://localhost:3000/api/datasources | jq '.[].name'
# Expect: Prometheus, Loki, Tempo

# Confirm the sidecar-provisioned dashboard shows up
curl -s -u admin:<password> http://localhost:3000/api/search?query=Kubernetes | jq '.[].title'
```

Log into `http://localhost:3000` (or your Ingress host) and confirm the
"Kubernetes Cluster Overview" dashboard renders live data.

## Configuration

- **Persistence**: `persistence.size` in `values.yaml` — only needs to hold
  the Grafana SQLite DB (users, alert state, dashboard version history) if
  you're not using an external Postgres/MySQL backend; 10Gi is generous
  headroom for most teams.
- **Dashboards**: add new ones by dropping a labeled ConfigMap — see
  `dashboards/README.md`. Do not hand-edit dashboards in the UI on a
  production instance long-term; export the JSON back into a ConfigMap so
  changes survive a redeploy.
- **Datasources**: edit `datasources/datasources.yaml` and re-apply; the
  sidecar picks up changes without a Grafana restart.
- **Plugins**: `plugins:` list in `values.yaml` — see `plugins/README.md`.
- **Ingress/TLS**: `ingress.enabled`, hostnames, and cert-manager annotation
  in `values.yaml`.
- **Auth**: `grafana.ini` block — OAuth/OIDC/LDAP integration goes here if
  you don't want to manage local users; disable `auth.anonymous` in
  production (it is disabled by default in this repo's values).

## Security

- Admin credentials are sourced from `admin.existingSecret`, never inlined
  in `values.yaml` — create the `Secret` out-of-band (see Installation) and
  manage rotation through your secrets tooling.
- `grafana.ini.security.cookie_secure: true` requires Grafana be served over
  HTTPS — don't flip this on until TLS termination (ingress or otherwise)
  is in place, or logins will silently break.
- `auth.anonymous.enabled: false` and `users.allow_sign_up: false` by
  default — Grafana should never be open to self-service signup in a
  production cluster.
- `analytics.reporting_enabled: false` and `check_for_updates: false` stop
  Grafana from phoning home to grafana.com, useful in locked-down/air-gapped
  environments.
- The dashboard/datasource sidecars use `searchNamespace: ALL`, meaning any
  namespace can inject a dashboard or datasource into Grafana. If you don't
  trust every namespace equally, scope `searchNamespace` to a list of
  trusted namespaces instead, or gate ConfigMap creation with an
  admission policy (Kyverno/OPA).
- Only install plugins from the official catalog unless you've reviewed the
  source — plugins run with the same privileges as the Grafana server
  process. See `plugins/README.md`.

## Scaling

- Grafana is stateless per-request; scale `replicas` in `values.yaml`
  horizontally behind the Service — no session affinity needed for
  read-only dashboard viewing (alerting state and dashboard writes go
  through the shared DB/PVC, not in-memory state, once you move to an
  external Postgres backend for true multi-writer HA).
- With `persistence.enabled: true` and `replicas > 1` on a `ReadWriteOnce`
  PVC, only one pod can mount it — for genuine multi-replica HA, back
  Grafana with an external Postgres/MySQL database instead
  (`database:` block in values.yaml) rather than the bundled SQLite+PVC.
- `podDisruptionBudget.minAvailable: 1` keeps at least one replica up during
  node drains/upgrades.

### High Availability considerations

- **SQLite is the real HA blocker, not replica count**: raising `replicas` without also setting an external `database:` backend just means N pods contending for one `ReadWriteOnce` PVC — Kubernetes will only let one of them actually mount it, and the rest crash-loop on startup. True multi-replica HA requires an external Postgres/MySQL database in `values.yaml`'s `database:` block; treat `replicas > 1` with SQLite as a misconfiguration, not a degraded-but-working state.
- **Unified alerting state lives in the database too**: once you move to external Postgres for HA, alert rule evaluation state, silences, and notification history all become shared across replicas correctly — with SQLite+single-replica, a pod restart mid-evaluation can cause a brief alerting gap (state is local to that pod's SQLite file).
- **Sidecar provisioning is inherently HA-safe**: because dashboards/datasources are sourced from ConfigMaps (not the database), every replica independently provisions the identical set on startup — you don't need to worry about dashboard drift between replicas the way you would with UI-created dashboards.
- **Session handling behind a LoadBalancer/Ingress**: Grafana's own session cookie is validated against the shared database once external Postgres is in place, so no sticky-session Ingress annotation is required for multi-replica — request routing can be pure round-robin.

## Common Problems

- **Dashboard ConfigMap applied but doesn't show up in Grafana** — check
  the label is exactly `grafana_dashboard: "1"` (string, not boolean `1`)
  and that the ConfigMap's namespace is covered by `searchNamespace: ALL`.
  Check sidecar logs: `kubectl logs -n monitoring deploy/grafana -c
  grafana-sc-dashboard`.
- **Datasource shows "unauthorized"/"bad gateway" when querying Prometheus**
  — usually a Service DNS name mismatch after a Helm release rename. Verify
  with `kubectl get svc -n monitoring | grep prometheus` and update the
  `url:` in `datasources/datasources.yaml` to match the actual Service name.
- **Login fails after enabling `cookie_secure: true`** — Grafana is being
  accessed over plain HTTP (e.g. via `kubectl port-forward` without TLS, or
  an Ingress not actually terminating TLS). Either access it over HTTPS or
  temporarily unset `cookie_secure` for local debugging only.
- **Admin password "doesn't work" after a fresh install** — the chart only
  sets the password from `existingSecret` on the *first* boot when the SQLite
  DB is created; changing the Secret afterward does not change the already-
  provisioned admin user. Reset via `grafana-cli admin reset-admin-password`
  inside the pod instead.
- **Grafana pod `CrashLoopBackOff` after adding a plugin** — the plugin ID is
  misspelled or requires `GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS`. Check
  `kubectl logs -n monitoring deploy/grafana -c grafana` for the exact
  `grafana-cli` install error.
- **Dashboard panel shows "No data" but the PromQL works fine in Prometheus'
  own UI** — the dashboard is likely pointed at a stale/renamed datasource
  UID. Re-select the datasource on the panel, or fix the `templating`
  variable default in the dashboard JSON.
- **Two replicas show different dashboard lists right after deploying a new ConfigMap** — the dashboard sidecar polls for ConfigMap changes rather than reacting instantly; each replica's sidecar polls independently, so there's a brief window (seconds, per `k8s-sidecar`'s `FOLDER_ANNOTATION`/resync interval) where replicas can disagree. This resolves itself within one poll cycle — don't treat it as data loss.
- **Grafana upgrade succeeds but a previously-working panel now renders an error** — usually a panel type deprecation (old Grafana ships "Graph (old)" panels that get removed in later majors, replaced by the unified "Time series" panel). Check the release notes for panel deprecations before a major upgrade, and re-save affected dashboards using the new panel type ahead of time in a staging Grafana instance.

## Best Practices

- Provision dashboards and datasources as code (ConfigMaps in Git), not
  through the UI, so a cluster rebuild reproduces the exact same Grafana
  state.
- Use dashboard template variables (`${DS_PROMETHEUS}`, `$node`, `$namespace`)
  instead of hardcoding instance names — makes dashboards portable across
  clusters/environments.
- Keep one Grafana per environment (or use folders + org-level permissions)
  rather than pointing a single Grafana at multiple clusters' Prometheus
  instances behind a variable — it gets confusing fast during incidents.
- Route both Prometheus-native and Grafana-managed alerts through the same
  Alertmanager receivers (see `manifests/grafana/alerts/README.md`) so
  on-call has one place to look.
- Pin the Grafana image tag explicitly (`image.tag` in `values.yaml`) —
  don't float on `latest` in a production values file.
- Disable anonymous access and self-service signup by default; require an
  explicit decision (and likely SSO) to turn either on.

## Useful Commands

```bash
# Get the admin password
kubectl get secret grafana-admin-credentials -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Tail dashboard sidecar logs while debugging provisioning
kubectl logs -n monitoring deploy/grafana -c grafana-sc-dashboard -f

# List installed plugins inside the running pod
kubectl exec -n monitoring deploy/grafana -- grafana-cli plugins ls

# Force Grafana to pick up a values.yaml change that isn't reflected via a checksum annotation
kubectl rollout restart deployment/grafana -n monitoring

# Query the Grafana HTTP API directly (e.g. list datasources)
curl -s -u admin:<password> http://localhost:3000/api/datasources | jq

# Export a dashboard's current JSON model (for committing back to Git)
curl -s -u admin:<password> http://localhost:3000/api/dashboards/uid/k8s-cluster-overview | jq '.dashboard'

# Reset the admin password directly (bypasses existingSecret, first-boot-only issue)
kubectl exec -it -n monitoring deploy/grafana -- grafana-cli admin reset-admin-password '<newpassword>'
```

## References

- Grafana Helm chart: https://github.com/grafana/helm-charts/tree/main/charts/grafana
- Grafana provisioning docs (dashboards/datasources): https://grafana.com/docs/grafana/latest/administration/provisioning/
- k8s-sidecar (dashboard/datasource sidecar): https://github.com/kiwigrid/k8s-sidecar
- Grafana unified alerting: https://grafana.com/docs/grafana/latest/alerting/
- Grafana dashboard JSON model reference: https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/view-dashboard-json-model/
- Grafana plugin catalog: https://grafana.com/grafana/plugins/
