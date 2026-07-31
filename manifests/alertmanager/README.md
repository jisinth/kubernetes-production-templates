# Alertmanager

## What is this?

Production-ready configuration for Prometheus Alertmanager: the component
that receives firing alerts from Prometheus (`manifests/prometheus/alert-
rules.yaml`), deduplicates and groups them, applies a routing tree, and
delivers notifications to Slack/PagerDuty/webhook receivers. This directory
covers both running Alertmanager standalone (`values.yaml`, via the
`prometheus-community/alertmanager` chart) and the routing/receiver config
(`config.yaml`, `routes.yaml`) that applies whether Alertmanager is
deployed standalone or as part of kube-prometheus-stack
(`manifests/prometheus/values.yaml`).

## Architecture

```
   Prometheus (PrometheusRule evaluation)
              |
              | fires alert (labels + annotations)
              v
   ┌──────────────────────────────────────────┐
   │         Alertmanager cluster (3x)          │
   │   gossip protocol for HA dedup/silences    │
   └───────────────────┬────────────────────────┘
                        |
              route tree (config.yaml / routes.yaml)
             matches on labels: severity, team, service
                        |
        ┌───────────────┼────────────────┐
        v                v                v
   Slack channel   PagerDuty (critical)  Team-specific
   (default/team)   on-call escalation    Slack channel

   inhibit_rules suppress known-noisy downstream alerts
   (e.g. NodeNotReady suppresses per-pod alerts on that node)
```

Alertmanager runs as a 3-replica gossip cluster: all replicas receive the
same alerts (Prometheus sends to all of them) and use gossip to
deduplicate and share silence/notification state, so losing one replica
doesn't cause duplicate or dropped notifications.

## Prerequisites

- Kubernetes 1.24+, Helm 3.8+ (if installing standalone)
- `manifests/prometheus/` installed — Alertmanager is only useful with a
  Prometheus (or other Alertmanager-API-compatible sender) pushing alerts
  to it.
- Real Slack webhook URL(s) and/or PagerDuty integration key(s) — this
  repo ships only placeholder values in `config.yaml`/`routes.yaml`.
- A `Secret` (not a plain values.yaml) to hold those credentials in any
  real deployment.

## Installation

If running as part of kube-prometheus-stack (recommended default — see
`manifests/prometheus/README.md`), Alertmanager is already installed;
apply just the routing config:

```bash
# Store the real config (with real webhook URLs) as a Secret, never as a
# plain ConfigMap or inline Helm value.
kubectl create secret generic alertmanager-config \
  --namespace monitoring \
  --from-file=alertmanager.yaml=manifests/alertmanager/config.yaml
```

Then reference it from the Prometheus Operator's `Alertmanager` object
(`alertmanagerSpec.configSecret` in kube-prometheus-stack) or, if using the
CRD-based approach, via `AlertmanagerConfig` resources instead of a single
monolithic Secret.

If running standalone instead:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install alertmanager prometheus-community/alertmanager \
  --namespace monitoring --create-namespace \
  -f manifests/alertmanager/values.yaml
```

## Verification

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager

kubectl port-forward -n monitoring svc/alertmanager-operated 9093:9093

# Confirm config loaded without errors
curl -s http://localhost:9093/api/v2/status | jq '.config.original' | head -20

# List currently active alerts and their routing
curl -s http://localhost:9093/api/v2/alerts | jq '.[] | {alertname: .labels.alertname, severity: .labels.severity}'

# Dry-run how a given label set would route (does NOT send a real notification)
amtool config routes test --config.file=manifests/alertmanager/config.yaml \
  severity=critical team=infra
```

Send a real test alert end-to-end with `amtool alert add` against a
non-production Alertmanager before trusting a new receiver in production.

## Configuration

- **Routing tree**: `route:` block in `config.yaml` — top-to-bottom,
  first-match-per-branch; use `continue: true` to also fall through to
  later sibling routes (e.g. critical alerts both page AND post to Slack).
  See `routes.yaml` for an alternative team-ownership-first routing tree.
- **Grouping**: `group_by`/`group_wait`/`group_interval`/`repeat_interval`
  — tune to balance "page fast" against "don't spam 50 notifications for
  one incident."
- **Receivers**: Slack (`slack_configs`), PagerDuty (`pagerduty_configs`),
  and generic `webhook_configs` are all supported — add new receiver
  blocks under `receivers:` and route to them by label matcher.
- **Inhibition**: `inhibit_rules` — suppress alerts that are a known
  downstream symptom of another alert already firing (see the
  `KubeNodeNotReady` example in `config.yaml`).
- **Silences**: managed at runtime via the Alertmanager UI/API, not via
  files in this repo — use `amtool silence add` for scripted/planned
  maintenance windows.

## Security

- **Never commit real webhook URLs or PagerDuty keys.** `config.yaml` and
  `routes.yaml` in this repo contain obvious `<REPLACE_ME_...>` placeholders
  — load the real values from a `Secret` (or your secrets manager: Sealed
  Secrets, External Secrets Operator, Vault) at deploy time.
- The Alertmanager UI/API has no built-in authentication — do not expose it
  via a public Ingress without an auth proxy in front (oauth2-proxy, or
  ingress-controller basic-auth/OIDC). It's sensitive because anyone with
  access can create silences that hide real incidents.
- Rotate Slack/PagerDuty credentials periodically and immediately if a
  config file containing them is ever accidentally committed in plaintext.
- Restrict who can edit `AlertmanagerConfig`/the config Secret via RBAC —
  a malicious or accidental edit to the routing tree can silently
  blackhole all alerts (e.g. routing everything to `receiver: "null"`).

## Scaling

- Run an odd number of replicas (3 or 5) for gossip-protocol quorum;
  Alertmanager's HA model is peer-to-peer, not leader-election-based, so
  there's no strict upper bound, but 3-5 is sufficient for nearly all
  deployments — Alertmanager's job is lightweight relative to Prometheus.
- Alertmanager itself rarely needs vertical scaling; if `resources` limits
  are being hit, it's almost always due to a very high volume of distinct
  active alerts/silences rather than needing more CPU per notification.
- Multiple independent Prometheus instances (e.g. per-cluster) can share
  one Alertmanager cluster by all sending to the same Alertmanager
  Service/Ingress — useful for centralizing routing/on-call across
  multiple clusters.

## Common Problems

- **Alert fires in Prometheus but no notification arrives** — check
  `/api/v2/alerts` on Alertmanager to confirm it was received at all; if
  not, check Prometheus's own `alertmanagers` config
  (`kubectl exec ... -- wget -qO- localhost:9090/api/v1/alertmanagers`). If
  received but not notified, check routing: a `matchers` typo or an
  unintended `continue: false` on an earlier route can silently swallow it.
- **Same alert notified 5 times in a row** — `repeat_interval` too short
  for the alert's actual duration, or multiple routes matching the same
  alert without `continue` set deliberately (each matching route sends its
  own notification).
- **Slack messages never arrive despite Alertmanager showing the
  notification as sent** — usually an expired/revoked webhook URL or the
  Slack app losing channel access. Check Alertmanager logs
  (`kubectl logs -n monitoring alertmanager-...`) for `context deadline
  exceeded` or `404`/`410` from Slack's API.
- **Gossip cluster split-brain (`kubectl exec ... amtool cluster show`
  reports fewer peers than replicas)** — usually a `NetworkPolicy` blocking
  the mesh port (9094 by default) between Alertmanager pods. Confirm
  `--cluster.listen-address` port is open pod-to-pod.
- **A silence meant to be temporary is still suppressing real alerts weeks
  later** — silences don't expire automatically unless created with an
  `endsAt`; audit active silences regularly (`amtool silence query`) and
  remove stale ones.

## Best Practices

- Every alert (`PrometheusRule` in `manifests/prometheus/alert-rules.yaml`)
  should carry a `severity` and a `team` label — routing in this directory
  depends on both being set consistently; an unlabeled alert falls through
  to `fallback-unrouted`/`default-slack` and gets missed by team-specific
  on-call.
- Keep `group_by` narrow enough that a notification is actually actionable
  (grouping by `alertname` + `namespace`/`service` is usually right;
  grouping only by `alertname` across the whole cluster produces vague,
  hard-to-act-on notifications).
- Use `inhibit_rules` aggressively to cut noise from cascading failures —
  a node going down will otherwise fire dozens of pod-level alerts
  simultaneously.
- Store the real config as a `Secret`, and keep a redacted/placeholder
  version (like this repo's `config.yaml`) in version control so the
  routing logic itself is still reviewable in PRs.
- Test routing changes with `amtool config routes test` before applying —
  it's cheap insurance against silently blackholing alerts.
- Set `send_resolved: true` on every receiver — knowing when an alert
  *stopped* firing is as operationally important as knowing it started.

## Useful Commands

```bash
# Check current alerts and their state
curl -s http://localhost:9093/api/v2/alerts | jq '.[] | {name: .labels.alertname, state: .status.state}'

# Validate a config file before applying
amtool check-config manifests/alertmanager/config.yaml

# Test how a label set routes without sending a real notification
amtool config routes test --config.file=manifests/alertmanager/config.yaml \
  severity=critical team=payments service=payments-api

# Create a silence (e.g. planned maintenance)
amtool silence add alertname=HighPodMemory namespace=default \
  --duration=2h --comment="planned maintenance window"

# List active silences
amtool silence query

# View gossip cluster peer status
kubectl exec -n monitoring alertmanager-alertmanager-0 -- amtool cluster show

# Send a synthetic test alert end-to-end
amtool alert add alertname=TestAlert severity=warning team=platform \
  --annotation=summary="test notification"
```

## References

- Alertmanager documentation: https://prometheus.io/docs/alerting/latest/alertmanager/
- Alertmanager configuration reference: https://prometheus.io/docs/alerting/latest/configuration/
- amtool documentation: https://github.com/prometheus/alertmanager/blob/main/docs/cli/amtool.md
- Notification template reference: https://prometheus.io/docs/alerting/latest/notifications/
- prometheus-community/alertmanager Helm chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/alertmanager
- AlertmanagerConfig CRD (Prometheus Operator): https://prometheus-operator.dev/docs/user-guides/alerting/#alertmanagerconfig-resources
