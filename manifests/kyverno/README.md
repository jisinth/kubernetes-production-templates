# Kyverno

## What is this?

[Kyverno](https://kyverno.io/) is a policy engine built specifically for
Kubernetes — policies are written as Kubernetes CRs (`ClusterPolicy`,
`Policy`) instead of a separate DSL like Rego (OPA/Gatekeeper). It runs as a
dynamic admission controller: every create/update to a matching resource is
validated, mutated, or generated against your policies before it's
persisted. This folder contains the Kyverno installation values and three
production policies covering resource governance, image supply-chain
hygiene, and pod security.

Why policy-as-code instead of tribal knowledge/code review:

- **Enforced, not just documented.** "Always set resource limits" in a wiki
  page is advice; a Kyverno `ClusterPolicy` with `validationFailureAction:
  Enforce` is a hard gate the API server itself respects.
- **Auditable before it's blocking.** `validationFailureAction: Audit`
  reports violations (via `PolicyReport` objects) without rejecting
  requests — the safe way to roll out a new rule against an existing fleet.
- **No new query language.** Policies match/validate/mutate using the same
  YAML and JMESPath-like syntax you already use for Kubernetes manifests.

## Architecture

```
                 kubectl apply / CI pipeline
                              │
                              ▼
                    kube-apiserver (admission chain)
                              │
                 ┌────────────┴─────────────┐
                 ▼                            ▼
     ValidatingWebhookConfiguration   MutatingWebhookConfiguration
                 │                            │
                 ▼                            ▼
        kyverno-admission-controller (validate / mutate / generate)
                 │
                 ├──▶ Enforce  → request rejected, client sees the message
                 ├──▶ Audit    → request allowed, PolicyReport recorded
                 └──▶ background-controller → re-scans existing resources
                                               on a schedule (background: true)
```

- **admission-controller** — the webhook server; makes the allow/deny
  decision synchronously on every matching API request.
- **background-controller** — periodically re-evaluates policies with
  `background: true` against resources already in the cluster (so audit
  reports stay current even for objects created before the policy existed).
- **reports-controller** — aggregates `PolicyReport`/`ClusterPolicyReport`
  objects.
- **cleanup-controller** — handles `CleanupPolicy` CRs (not used in this
  folder, but available for scheduled resource GC).

## Prerequisites

- Cluster-admin access to install CRDs and webhook configurations.
- Helm 3.x.
- Enough control-plane headroom for an admission webhook on the hot path of
  every `create`/`update` — Kyverno itself is lightweight, but a
  misconfigured `failurePolicy: Fail` combined with a Kyverno outage will
  block *all* matching API requests (see Security below).

## Installation

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno \
  -n kyverno --create-namespace \
  -f manifests/kyverno/values.yaml

kubectl -n kyverno rollout status deploy/kyverno-admission-controller

# Apply policies in Audit mode first (all three ship with Audit/Enforce
# already set appropriately below — review before applying to prod)
kubectl apply -f manifests/kyverno/policies/
```

Recommended audit → enforce rollout for any new policy:

```bash
# 1. Apply with validationFailureAction: Audit (the default in this folder
#    except disallow-latest-tag, which is safe to enforce immediately)
kubectl apply -f manifests/kyverno/policies/require-resource-limits.yaml

# 2. Let it run for a few days, then check for violations
kubectl get policyreport -A
kubectl get clusterpolicyreport -o wide

# 3. Once existing workloads are compliant, flip to Enforce
kubectl patch clusterpolicy require-resource-limits \
  --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
```

## Verification

```bash
# Controller pods healthy
kubectl -n kyverno get pods

# Policies loaded and their current mode
kubectl get clusterpolicy -o custom-columns=\
NAME:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.ready

# Try creating a violating pod and confirm it's rejected (Enforce policies)
kubectl run bad-pod --image=nginx:latest --dry-run=server
# Expect: Error from server: admission webhook "validate.kyverno.svc-fail"
# denied the request: ... disallow-latest-tag ...

# Inspect audit findings for Audit-mode policies
kubectl get policyreport -A -o wide
```

## Configuration

- **`values.yaml`** — replica counts (HA by default: 3 admission-controller
  replicas), resource requests/limits, pod anti-affinity, webhook
  `failurePolicy` (Ignore/fail-open by default), and the Prometheus
  ServiceMonitor toggle.
- **`policies/require-resource-limits.yaml`** — `Audit` mode; denies (in
  Enforce) pods missing CPU/memory requests or limits on any
  container/initContainer.
- **`policies/disallow-latest-tag.yaml`** — `Enforce` mode; rejects images
  tagged `:latest` or with no tag at all.
- **`policies/require-non-root.yaml`** — `Audit` mode; requires
  `runAsNonRoot: true` and disallows `runAsUser: 0`.
- Each policy excludes `kube-system`/`kyverno` namespaces via
  `spec.rules[].exclude` — extend that list for other platform namespaces
  that run trusted, non-negotiable workloads (e.g., CNI, CSI driver pods).

## Security

- **`failurePolicy: Ignore` is a deliberate tradeoff.** It means a Kyverno
  outage doesn't block the API server (fail-open), but it also means
  policies are *not enforced* during that outage. Flip specific,
  high-value webhooks to `Fail` (fail-closed) only after Kyverno HA and
  alerting are proven, and never fail-closed on the *only* replica set.
- **Run `admission-controller` with `replicaCount >= 3` and pod
  anti-affinity** (both set in `values.yaml`) — a single-replica Kyverno
  with `failurePolicy: Fail` turns a routine node drain into a
  cluster-wide outage of `kubectl apply`.
- **Scope `exclude` blocks tightly.** Every namespace/kind excluded from a
  security policy is a hole in that policy — review exclusions in PRs the
  same way you'd review an RBAC grant.
- **Prefer `Enforce` for anything you'd call a security control**
  (`disallow-latest-tag`, and eventually `require-non-root` once audited
  clean) — `Audit`-only policies document violations but don't stop them.
- **Kyverno itself needs broad RBAC** (it watches/patches most resource
  types) — keep the Kyverno namespace and its ServiceAccounts locked down
  from other tenants; don't grant arbitrary users `exec` into
  `kyverno-admission-controller` pods.
- Combine with `manifests/network-policy/` and `manifests/pod-security/` —
  Kyverno is one layer of a defense-in-depth posture, not a replacement for
  NetworkPolicies or Pod Security Admission.

## Scaling

- `admission-controller` is on the synchronous request path for every
  matching admission review — scale replicas (already 3 by default) before
  API server request latency becomes visible under load.
- `background-controller` workload scales with total *existing* resource
  count subject to `background: true` policies, not request rate — bump its
  replicas/resources if `PolicyReport` generation lags behind actual
  cluster state.
- Use `webhooks[].objectSelector`/`namespaceSelector` (via
  `config.webhooks` in `values.yaml`) to scope which requests even reach
  Kyverno — narrowing the webhook's `rules` reduces load more effectively
  than scaling replicas.
- Enable `admissionController.serviceMonitor` (on by default here) and
  watch `kyverno_admission_review_duration_seconds` — rising p99 latency is
  the leading indicator you need more replicas or narrower webhook scope.

## Common Problems

- **All `kubectl apply` commands suddenly fail cluster-wide** — Kyverno is
  down/unreachable and a webhook has `failurePolicy: Fail`. Emergency fix:
  `kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg`
  (or patch `failurePolicy` to `Ignore`) to restore API server availability,
  then investigate why Kyverno itself was unavailable.
- **A policy update doesn't seem to take effect** — Kyverno webhooks
  configuration is generated by the controller and can lag a few seconds
  after a `ClusterPolicy` change; check `kubectl get clusterpolicy <name>
  -o jsonpath='{.status}'` for `ready: true` before assuming the policy
  didn't load.
- **Pods created before a policy existed aren't flagged** — only
  `background: true` policies (all three here have it) get retroactively
  scanned; check `kubectl get policyreport -A` after the
  background-controller's next scan interval rather than expecting instant
  results.
- **`disallow-latest-tag` blocks a Helm chart's default image** — many
  upstream charts default to `:latest` or omit a tag; pin
  `image.tag`/`image.digest` in that chart's values rather than exempting
  the whole policy for that namespace.
- **False positive on `require-resource-limits` for init containers doing a
  trivial `chmod`** — either add real (small) requests/limits, which is
  usually harmless, or scope an explicit `exclude` for that specific
  container name/image rather than the whole namespace.
- **Policy exceptions needed for a specific workload** — use
  `PolicyException` CRs (Kyverno 1.11+) scoped to a specific
  resource/namespace instead of broadening a `ClusterPolicy`'s `exclude`.

## Best Practices

- Land every new policy in `Audit` mode first; only promote to `Enforce`
  after checking `PolicyReport` output against real workloads.
- Keep policies narrowly scoped and composable — one concern per
  `ClusterPolicy` (as done here: limits, tags, non-root are three separate
  files) rather than one giant policy with many unrelated rules.
- Write clear, actionable `message` fields — the message is what a
  developer sees in their `kubectl apply` error; "denied" with no
  explanation just generates support tickets.
- Version policies in Git (this folder) and roll them out via the same
  GitOps pipeline (`manifests/argocd/`) as everything else — a policy that
  only exists as a live cluster object with no Git history is a policy
  nobody can review.
- Alert on `ClusterPolicyReport` summary counts trending upward — a spike
  usually means a new deploy pipeline or team started violating an existing
  rule.

## Useful Commands

```bash
# List all policies and their enforcement mode
kubectl get clusterpolicy

# See a policy's live status (ready, autogen rules, etc.)
kubectl describe clusterpolicy require-resource-limits

# View all violations across the cluster
kubectl get clusterpolicyreport -o wide
kubectl get policyreport -A

# Test a manifest against policies without applying it (Kyverno CLI)
kyverno apply manifests/kyverno/policies/ --resource my-deployment.yaml

# Dry-run admission to see what would be rejected
kubectl apply -f my-deployment.yaml --dry-run=server

# Tail admission-controller logs for webhook errors
kubectl -n kyverno logs deploy/kyverno-admission-controller -f

# Delete a policy (stops enforcement immediately)
kubectl delete clusterpolicy require-resource-limits
```

## References

- [Kyverno documentation](https://kyverno.io/docs/)
- [Kyverno policy library](https://kyverno.io/policies/)
- [Kyverno Helm chart](https://github.com/kyverno/kyverno/tree/main/charts/kyverno)
- [Kyverno CLI](https://kyverno.io/docs/kyverno-cli/)
- [PolicyReport CRDs](https://kyverno.io/docs/policy-reports/)
- [Kyverno high availability](https://kyverno.io/docs/installation/scaling/)
