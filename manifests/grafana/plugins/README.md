# Recommended Grafana plugins

Plugins are installed at pod startup via the `plugins:` list in
`manifests/grafana/values.yaml` (mirrored at `helm-values/grafana.yaml`).
The Grafana Helm chart's init container runs `grafana-cli plugins install
<name>` for each entry before the main container starts — no image rebuild
required, but pods do need to restart to pick up new/changed plugin lists.

```yaml
# manifests/grafana/values.yaml
plugins:
  - grafana-piechart-panel
  - grafana-clock-panel
  - grafana-polystat-panel
```

## Currently enabled

| Plugin | Why |
|---|---|
| `grafana-piechart-panel` | Simple pie/donut visualizations for breakdowns (e.g. pods by phase, requests by status code) that the built-in Pie Chart panel (core in Grafana 8+) doesn't always cover for older dashboard JSON imported from the community. |
| `grafana-clock-panel` | Timezone clocks on NOC/status-page style dashboards — useful when on-call spans multiple timezones. |
| `grafana-polystat-panel` | Dense grid-of-tiles view for large fleets (e.g. one tile per node/pod colored by health) — scales better than single stat panels once you have 50+ entities to watch at once. |

## Other plugins worth considering

- `grafana-worldmap-panel` — geographic visualization, useful if you have
  region/edge-location-tagged metrics (CDN, multi-region deployments).
- `redis-datasource` / `mysql`/`postgres` (core, no install needed) — if you
  need to dashboard application-database metrics directly alongside
  Prometheus data.
- `grafana-github-datasource` — surfacing deploy/PR activity next to
  incident dashboards for correlation.

Only add plugins you actually use — each one is additional attack surface
and an additional thing to keep updated. Check
https://grafana.com/grafana/plugins/ for the current signature/verification
status before adding a community plugin to a production values file.

## Installing a new plugin

1. Add the plugin ID to the `plugins:` list in `manifests/grafana/values.yaml`
   **and** `helm-values/grafana.yaml` (keep them in sync).
2. `helm upgrade --install grafana grafana/grafana -n monitoring -f helm-values/grafana.yaml`
3. Verify: `kubectl exec -n monitoring deploy/grafana -- grafana-cli plugins ls`
4. Restart isn't automatic on a values-only change to a list Helm doesn't
   template into a checksum annotation by default — force a rollout if the
   plugin doesn't appear:
   `kubectl rollout restart deployment/grafana -n monitoring`

## Unsigned/private plugins

If you need a plugin not in the official catalog, set
`GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS` (via `env:` in values.yaml) to
that plugin's ID explicitly — never set it to allow *all* unsigned plugins
in production.
