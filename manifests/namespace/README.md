# Namespaces

## What is this?

Baseline `Namespace`, `ResourceQuota`, and `LimitRange` manifests for the three environments this repo assumes: `production`, `staging`, and `development`. Every other manifest folder in this repo (ingress-nginx, cert-manager, observability stack, sample applications, etc.) is deployed into one of these namespaces, so they exist first, before anything else in the cluster.

Namespaces are the cheapest isolation boundary Kubernetes gives you: a scope for RBAC, NetworkPolicies, ResourceQuotas, and Pod Security Admission (PSA) labels. This folder defines that boundary consistently across environments so quota and security posture aren't reinvented ad hoc every time a team creates a namespace.

## Architecture

```
Cluster
├── production/    (PSA: restricted)  — customer-facing workloads, strict quota
├── staging/        (PSA: baseline)   — pre-prod validation, mirrors prod topology
├── development/    (PSA: baseline)   — developer sandbox, loosest quota
├── kube-system/                      — cluster add-ons (ingress-nginx, cert-manager, etc. live here or in their own namespace)
└── monitoring/, argocd/, etc.        — platform namespaces defined in their own manifest folders
```

Each environment namespace bundles three objects in one file, applied as three YAML documents separated by `---`:

1. **Namespace** — carries `environment` and `pod-security.kubernetes.io/*` labels.
2. **ResourceQuota** — caps aggregate CPU/memory/storage/object counts for everything in the namespace.
3. **LimitRange** — sets default requests/limits per container so pods that omit them don't silently consume unbounded resources or get rejected by the quota.

## Prerequisites

- A running Kubernetes cluster (1.25+ recommended; PSA labels are stable from 1.25 on) and `kubectl` configured against it.
- Cluster-admin (or equivalent) RBAC to create namespaces and cluster-scoped quota objects.
- Decide your environment names up front — renaming a namespace later means recreating every object in it.

## Installation

```bash
# Apply all three environments
kubectl apply -f manifests/namespace/production.yaml
kubectl apply -f manifests/namespace/staging.yaml
kubectl apply -f manifests/namespace/development.yaml

# Or apply the whole folder at once
kubectl apply -f manifests/namespace/
```

There is no Helm chart for this folder — namespaces are simple enough that a templated chart adds more indirection than value. If you use ArgoCD (see `manifests/argocd/`), point an `Application` at this directory with `syncPolicy.syncOptions: [CreateNamespace=false]` since the namespaces are managed here explicitly, not auto-created by other apps.

### Upgrading an Existing Namespace's Quota or PSA Level

Namespace-level changes are live edits, not rollouts — there's no "version" to upgrade, but tightening posture on a namespace with running workloads needs a staged approach:

1. **Raising a ResourceQuota** is always safe to apply directly — it can only unblock previously-rejected pods, never evict running ones.
2. **Lowering a ResourceQuota** below current usage does *not* evict existing pods (quota is enforced at admission, not continuously), but blocks new pods/scale-ups until usage drops below the new cap. Check current usage first: `kubectl describe resourcequota -n <ns>`.
3. **Tightening PSA from `baseline` to `restricted`** on a namespace with running workloads: PSA `enforce` only blocks *new* pod creations and updates that change the pod spec — existing non-compliant pods keep running untouched. Before flipping `enforce`, set `pod-security.kubernetes.io/audit: restricted` and `pod-security.kubernetes.io/warn: restricted` (leaving `enforce: baseline`) for a full deploy cycle, then check `kubectl get events -n <ns> --field-selector reason=PodSecurity` and API server audit logs for what would have been rejected. Fix flagged workloads, then flip `enforce: restricted`.
4. **Renaming a namespace** isn't supported by Kubernetes — there is no atomic rename. Create the new namespace, migrate objects (`kubectl get <resource> -n old -o yaml`, strip `resourceVersion`/`uid`/`namespace`, reapply with `-n new`), cut over Services/DNS/Ingress references, then delete the old namespace once nothing points at it.

## Verification

```bash
# Confirm namespaces exist with the right labels
kubectl get namespace production staging development --show-labels

# Confirm quota and limit range landed
kubectl get resourcequota,limitrange -n production
kubectl describe resourcequota production-quota -n production

# Confirm PSA enforcement is active (should show pod-security.kubernetes.io/enforce)
kubectl get ns production -o jsonpath='{.metadata.labels}'
```

A quick functional test: try creating a privileged pod in `production` — it should be rejected by PSA:

```bash
kubectl run privileged-test --image=nginx --overrides='{"spec":{"containers":[{"name":"privileged-test","image":"nginx","securityContext":{"privileged":true}}]}}' -n production
# expected: Error creating: pods "privileged-test" is forbidden: violates PodSecurity "restricted:latest"
```

## Configuration

- **`environment` label** — used by NetworkPolicies, Kyverno policies, and Grafana dashboard variables elsewhere in this repo to select namespaces by tier. Keep it consistent (`production`/`staging`/`development`) if you add more namespaces.
- **PSA levels** — `restricted` in production blocks privilege escalation, host namespaces/paths, non-default capabilities, and requires running as non-root with a seccomp profile. `baseline` in staging/development blocks the clearly dangerous stuff (privileged containers, host networking) but allows more flexibility for debugging. Tune per-namespace by editing the three `pod-security.kubernetes.io/*` labels.
- **ResourceQuota sizing** — the numbers here (e.g. `requests.cpu: "40"` in production) are starting points for a mid-size cluster; resize to match actual node capacity. Use `count/deployments.apps` and `count/jobs.batch` to prevent runaway CI jobs or crash-looping controllers from exhausting the API object count.
- **LimitRange defaults** — every container that doesn't declare `resources.requests`/`limits` inherits `defaultRequest`/`default` here. This is what keeps a forgotten resources block from either starving neighbors or getting rejected outright by the quota's `limits.cpu`/`limits.memory`.
- **Adding a new environment** — copy one of the three files, rename, adjust the quota tier, and choose a PSA level. Don't skip the LimitRange; a namespace with a ResourceQuota but no LimitRange will reject any pod that omits explicit resource requests once the quota is in effect.

## Security

- PSA is enforced at the namespace level via labels — no admission webhook to install or maintain, it ships in-tree since Kubernetes 1.23 (stable 1.25).
- `production` uses `restricted`, the strictest built-in profile: no privilege escalation, must run as non-root, must drop `ALL` capabilities, must use `RuntimeDefault` or a custom seccomp profile, no hostPath/hostNetwork/hostPID/hostIPC.
- Combine these namespaces with the NetworkPolicies in `manifests/network-policy/` — namespace isolation alone does not stop pod-to-pod traffic across namespaces without an explicit default-deny policy.
- ResourceQuota is a security control too: it caps blast radius from a compromised or misbehaving workload (e.g. a crypto-miner spinning up hundreds of pods) at the namespace boundary rather than the cluster.
- Avoid granting `cluster-admin`-scoped RBAC to teams that only need one namespace; pair these namespaces with per-namespace RoleBindings.

## Scaling

- ResourceQuota and LimitRange values are static per namespace — as workload count grows, monitor `kubectl describe resourcequota` for objects nearing their hard cap and raise limits deliberately rather than reactively during an incident.
- If a single environment namespace becomes a scaling bottleneck (e.g. one team dominates the `production` quota), consider splitting by team/product into additional namespaces (`production-team-a`, `production-team-b`) each with its own quota, rather than inflating one shared quota indefinitely.
- For clusters with many namespaces, template these three manifests with Kustomize overlays or a small Helm chart to avoid drift as quota numbers are tuned per environment.

### High Availability & Multi-Cluster Considerations

Namespaces themselves have no HA dimension — they're API objects, not a workload with replicas — but the quota/PSA strategy they encode has real availability implications:

- **Quota headroom for failover**: if `production` runs across multiple clusters (active/passive or active/active DR), size the ResourceQuota in each cluster for the *failed-over* load, not steady-state load, or a regional failover will hit quota limits exactly when it needs to scale up.
- **Cross-cluster consistency**: keep `production.yaml`/`staging.yaml`/`development.yaml` byte-identical (modulo quota sizing) across every cluster running that environment tier — apply them from this same repo via ArgoCD (`manifests/argocd/`) to each cluster rather than hand-editing per cluster, so PSA level and label sets never silently drift between regions.
- **LimitRange defaults during multi-cluster migration**: when moving workloads between clusters, a mismatched `LimitRange.default` between source and destination can silently change a pod's effective resource limits with no error — diff `kubectl describe limitrange` output between clusters before a migration, not after.

## Common Problems

1. **Pods stuck in `Pending` with `forbidden: exceeded quota`** — the namespace's ResourceQuota is exhausted. Run `kubectl describe resourcequota -n <ns>` to see used vs. hard limits, then either free up capacity or raise the quota.
2. **New pods rejected with `must specify memory/cpu limits`** — happens when a ResourceQuota with `limits.cpu`/`limits.memory` exists but the pod's containers don't declare resources, and (unusually) the LimitRange default wasn't applied — most often because the LimitRange was deleted or never applied in that namespace. Reapply `limitrange.yaml`/the namespace manifest.
3. **Pod rejected with `violates PodSecurity "restricted:latest"`** — the workload needs privilege it can't have in `production` (e.g. `runAsUser: 0`, missing `seccompProfile`). Fix the pod's `securityContext` rather than lowering the namespace's PSA level; if the workload genuinely needs an exception, deploy it into a dedicated namespace with a documented, reviewed exemption instead of weakening `production`.
4. **`count/deployments.apps` quota exceeded during a rollout** — some quota configurations count old and new ReplicaSets during a rolling update. Check `maxSurge`/`maxUnavailable` on the Deployment and raise `count/deployments.apps` or `pods` headroom if legitimate rollouts are being blocked.
5. **Workload passes `audit`/`warn` cleanly but is rejected once `enforce` flips to `restricted`** — audit/warn use the same PSA admission logic but the pod's actual runtime `securityContext` at apply-time is what's checked; a workload whose manifest looks compliant but relies on a mutating webhook (e.g. a sidecar injector) to add the missing fields can pass a manual review yet fail at admission if that webhook runs after PSA in the chain. Check `kubectl get mutatingwebhookconfigurations` ordering and confirm PSA sees the *final* pod spec, not the pre-mutation one.
6. **Two teams' workloads in the same namespace fight over ResourceQuota** — a shared `production` namespace with one aggregate quota gives no per-team fairness; one team's traffic spike can starve another's ability to scale. Split into per-team namespaces (`production-team-a`) each with its own quota, rather than trying to sub-allocate a single namespace's quota via convention alone.

## Best Practices

- One namespace per environment per team/product, not one giant namespace per environment — smaller blast radius, clearer ownership, easier per-team quota.
- Always pair a ResourceQuota with a LimitRange; a quota without a limit range makes "no resources specified" pods unschedulable in confusing ways.
- Set PSA to `restricted` everywhere you can; start new namespaces there and only relax to `baseline`/`privileged` with a documented reason.
- Label namespaces consistently (`environment`, `owner`, `team`) so tooling (dashboards, policies, cost allocation) can select on them reliably.
- Version-control every quota/limit change through this repo and code review — silent `kubectl edit resourcequota` changes in a live cluster are a common source of "why did this suddenly start failing" incidents.
- Never delete and recreate a namespace to "reset" it in production — that cascades to delete every object inside, including PVCs and Secrets, unless they're explicitly backed up elsewhere.

## Useful Commands

```bash
# List all namespaces with their PSA enforcement level
kubectl get ns -o custom-columns=NAME:.metadata.name,PSA:.metadata.labels."pod-security\.kubernetes\.io/enforce"

# Show quota usage vs hard limits for a namespace
kubectl describe resourcequota -n production

# Show effective LimitRange defaults
kubectl describe limitrange -n production

# Find pods without explicit resource requests (candidates relying on LimitRange defaults)
kubectl get pods -n production -o json | jq '.items[] | select(.spec.containers[].resources.requests == null) | .metadata.name'

# Dry-run a PSA check against a manifest before applying
kubectl apply -f my-pod.yaml --dry-run=server -n production

# Delete a namespace (irreversible — cascades to all objects inside)
kubectl delete namespace development
```

## References

- [Kubernetes Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Kubernetes API Reference — Namespace](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/namespace-v1/)
