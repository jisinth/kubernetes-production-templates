# Security

## What is this?

This folder is the **security posture documentation hub** for the whole
repo, plus two baseline manifests
(`rbac-baseline.yaml`, `security-context-baseline.yaml`) that don't have a
more specific home. Kubernetes security is layered — no single control
covers everything — so this document explains how the individual, more
specific folders fit together into one defense-in-depth posture:

| Layer | What it controls | Where |
|-------|-------------------|-------|
| Network | Which pods can talk to which | [`../network-policy/`](../network-policy/README.md) |
| Admission-time policy | Reject non-compliant manifests before they're persisted | [`../kyverno/`](../kyverno/README.md) |
| Pod security tiers | Baseline pod hardening rules (privileged/baseline/restricted) | [`../pod-security/`](../pod-security/README.md) |
| Container security context | Per-container Linux capabilities, user, filesystem | This folder (`security-context-baseline.yaml`) |
| RBAC | Who/what can call the Kubernetes API, and for which verbs/resources | This folder (`rbac-baseline.yaml`) |
| Secrets management | Encrypting credentials at rest in Git | [`../sealed-secrets/`](../sealed-secrets/README.md) |
| GitOps supply chain | Who can merge changes that eventually reach the cluster | [`../argocd/`](../argocd/README.md) |
| Backup integrity | Backups isolated from the cluster they protect | [`../velero/`](../velero/README.md), [`../backup/`](../backup/README.md) |

No single layer is sufficient alone — NetworkPolicies don't stop a
compromised pod from reading Secrets it's RBAC-permitted to read; RBAC
doesn't stop a compromised pod from making outbound network connections;
Pod Security Admission doesn't inspect network traffic. Defense-in-depth
means a single control failing shouldn't be a full compromise.

## Architecture

```
                     External request / kubectl apply
                                  │
                                  ▼
                     ┌─────────────────────────┐
                     │      RBAC (this folder)  │  ← who can even make this request?
                     └────────────┬─────────────┘
                                  ▼
                     ┌─────────────────────────┐
                     │  Kyverno admission       │  ← is this manifest compliant?
                     │  (../kyverno/)           │
                     └────────────┬─────────────┘
                                  ▼
                     ┌─────────────────────────┐
                     │  Pod Security Admission  │  ← does the pod spec meet the
                     │  (../pod-security/)      │    namespace's PSS tier?
                     └────────────┬─────────────┘
                                  ▼
                            Pod scheduled
                                  │
              ┌───────────────────┼────────────────────┐
              ▼                   ▼                     ▼
   securityContext          NetworkPolicy         Secrets mounted
   (this folder)            (../network-policy/)  (from ../sealed-secrets/)
   drops capabilities,      restricts which pods    decrypted only
   non-root, read-only      this pod can reach       in-cluster
   root filesystem
```

## Prerequisites

- RBAC is always-on in any modern Kubernetes cluster — nothing to enable.
- The other layers referenced here each have their own prerequisites; see
  their respective READMEs (Kyverno needs its controller installed, PSA
  needs Kubernetes 1.25+, NetworkPolicy needs a policy-enforcing CNI,
  sealed-secrets needs its controller + a keypair).

## Installation

```bash
# RBAC baseline for a namespace-scoped developer role
kubectl apply -f manifests/security/rbac-baseline.yaml

# Container/pod securityContext baseline is a template to copy into your
# own workload manifests, not something you apply directly as-is:
cat manifests/security/security-context-baseline.yaml
# (copy the securityContext blocks into your Deployment/Pod spec)

# The other layers are installed from their own folders:
#   kubectl apply -f manifests/network-policy/
#   kubectl apply -f manifests/kyverno/policies/
#   kubectl apply -f manifests/pod-security/namespace-labels.yaml
```

### Evolving posture on a brownfield cluster (RBAC hardening)

Tightening RBAC on a cluster that's already running with loose permissions (the most common real-world starting point) needs the same audit-before-enforce discipline this repo uses for Kyverno and PSA — RBAC has no built-in audit mode, so you have to build one:

1. **Inventory current effective permissions before changing anything.** `kubectl get clusterrolebindings,rolebindings -A -o json | jq` (or a tool like `rbac-lookup`/`kubectl-who-can`) to see what every ServiceAccount/group/user can actually do today — you cannot safely tighten what you haven't measured.
2. **Enable audit logging** (Kubernetes API server audit logs, or a managed cluster's equivalent) before making RBAC changes, so a permission you remove but turns out to be needed shows up as a `Forbidden` in the audit log rather than a confusing application failure with no clear cause.
3. **Introduce `rbac-baseline.yaml`-style least-privilege roles alongside existing broad bindings**, don't delete the broad ones yet — have teams' CI/tooling start using the new narrow role explicitly (e.g. a dedicated ServiceAccount) while the old broad binding remains as a safety net.
4. **Remove the old broad binding only after a full deploy/operational cycle** running cleanly on the narrow role — a week is rarely enough; include at least one instance of every recurring process (deploys, batch jobs, DR drills) that might depend on a permission you haven't yet identified.
5. Repeat namespace-by-namespace or team-by-team, same as the NetworkPolicy default-deny rollout in [`../network-policy/`](../network-policy/README.md#migrating-a-brownfield-cluster-to-default-deny) — these two hardening efforts pair naturally since both follow "audit visibility first, narrow deliberately, verify before removing the fallback."

## Verification

```bash
# Confirm the RBAC baseline grants exactly what's expected, nothing more
kubectl auth can-i --list --as=system:serviceaccount:team-a:default -n team-a
kubectl auth can-i delete secrets --as-group=team-a-developers -n team-a
# Expect: no (only get/list on secrets, no delete)

# Confirm a pod using the security-context baseline passes PSA/Kyverno
kubectl apply -f manifests/security/security-context-baseline.yaml --dry-run=server

# Full-posture check: run a security scanner against the rendered manifests
# (see ../../CONTRIBUTING.md for the checkov/trivy/kubeconform pipeline)
checkov -d manifests/ --framework kubernetes
```

## Configuration

- **`rbac-baseline.yaml`** — a namespace-scoped `Role`/`RoleBinding` for a
  "developer" persona (full control over their own namespace's workloads,
  read-only on Secrets, no RBAC/quota/NetworkPolicy editing) plus a
  cluster-scoped read-only `ClusterRole`/`ClusterRoleBinding` for viewing
  nodes/namespaces/StorageClasses. Copy and rename per team/namespace.
- **`security-context-baseline.yaml`** — a reference Deployment
  documenting the recommended pod- and container-level `securityContext`
  fields (non-root, dropped capabilities, read-only root filesystem,
  seccomp). Copy the `securityContext` blocks into real workloads rather
  than deploying this file as-is.
- For the policy layers themselves (what's *enforced*, not just
  documented), configure [`../kyverno/policies/`](../kyverno/README.md)
  and [`../pod-security/namespace-labels.yaml`](../pod-security/README.md).

## Security

(This section is about securing the security tooling itself.)

- **RBAC is the root of trust for every other control** — if RBAC is
  over-permissive, a principal can often bypass Kyverno/PSA by directly
  editing objects those controls didn't block, or by editing the policies
  themselves. Audit `rbac-baseline.yaml`-derived roles at least as
  carefully as the workloads they govern.
- **Avoid `ClusterRole` wildcards** (`resources: ["*"]`,
  `verbs: ["*"]`) outside of a small, explicitly reviewed set of
  platform-admin bindings — `rbac-baseline.yaml` deliberately enumerates
  resources/verbs instead.
- **Read-only Secret access is still access** — `rbac-baseline.yaml` grants
  `get`/`list` on Secrets to developers because most teams need to inspect
  their own app's config; if that's too broad for a given team/namespace,
  drop it and require Secrets to be fetched through a narrower path (e.g.,
  only mounted into pods, never listable via `kubectl`).
- **`security-context-baseline.yaml`'s `capabilities.drop: [ALL]` is a
  starting point, not a guarantee** — some workloads (raw sockets,
  binding to privileged ports) legitimately need one capability added
  back; add it explicitly and narrowly rather than skipping the drop
  entirely.
- Review this folder's manifests and the four linked layers together in
  security reviews — a change to `rbac-baseline.yaml` and a change to
  `../network-policy/` are often two halves of the same actual security
  decision (e.g., "should team-a's pods be able to reach team-b's
  database" is both a NetworkPolicy question and, if it's actually about
  API access, an RBAC question).

## Scaling

- RBAC roles scale by **pattern**, not by hand-writing one per team —
  template `rbac-baseline.yaml` (Kustomize/Helm) so onboarding a new team
  namespace is "instantiate the template with a new namespace/group name,"
  not "write RBAC from scratch."
- As the number of layers/policies grows, keep this document (the
  cross-layer map at the top) current — it's the fastest way for a new
  engineer or an auditor to understand the full posture without reading
  eight separate folders cold.
- Push ownership of layer-specific tuning (which NetworkPolicy rules,
  which Kyverno exceptions) to the teams that own the workloads, while
  keeping the baseline/default posture (this folder, plus
  `../pod-security/`) centrally owned — this mirrors how RBAC itself
  should scale: centrally defined baseline, team-owned specifics within
  it.

## Common Problems

- **A team's pods can't do something the developer role should allow** —
  check `kubectl auth can-i <verb> <resource> --as-group=<group> -n
  <namespace>` before assuming a bug elsewhere; RBAC denials often look
  like generic `Forbidden` errors deep in application logs or CI output.
- **Overly broad RBAC discovered during an audit** — a common root cause is
  copy-pasting a `ClusterRole` with wildcard verbs "to get something
  working quickly" and never tightening it. Treat any wildcard grant found
  in review as a finding, not a style preference.
- **`security-context-baseline.yaml`'s pattern breaks an image that expects
  to run as root** (writes to `/var/log`, binds to port 80 without
  `NET_BIND_SERVICE`) — fix the image (multi-stage build running as a
  non-root user, listen on port >1024 behind a Service redirecting 80→8080)
  rather than loosening the baseline for that one workload.
- **Cross-layer contradictions** — e.g., a NetworkPolicy allows traffic
  RBAC would never let a human trigger directly, or Kyverno enforces
  `restricted`-equivalent rules while the namespace's actual PSA label is
  `baseline`. Resolve these deliberately (usually: tighten the looser
  layer) rather than leaving an inconsistent posture across tools.
- See the individual layer READMEs
  (`../network-policy/`, `../kyverno/`, `../pod-security/`) for
  mechanism-specific troubleshooting.

## Best Practices

- Default new namespaces to the tightest posture across every layer
  (restricted PSA, default-deny NetworkPolicy, least-privilege RBAC) and
  require an explicit, reviewed exception to loosen any one of them —
  never the reverse.
- Keep RBAC, NetworkPolicy, and Pod Security decisions for a given
  team/namespace reviewed together, since they're often answering related
  "what can this workload do" questions from different angles.
- Automate what you can (Kyverno, PSA) and reserve RBAC review for what
  automation can't fully cover (human judgment about whether a team
  actually needs a given permission).
- Run `kubectl auth can-i --list` and a policy/security scanner
  (checkov, trivy, kube-bench) as a standing part of CI, not just at
  initial rollout — posture drifts as manifests change over time.
- Document *why* an exception exists (a comment in the manifest, a linked
  ticket) whenever you must loosen a baseline — "why" is what lets a
  future reviewer decide if the exception is still needed.

## Useful Commands

```bash
# Check what a group/service account can actually do
kubectl auth can-i --list --as-group=team-a-developers -n team-a
kubectl auth can-i create secrets --as=system:serviceaccount:team-a:default -n team-a

# List all RoleBindings/ClusterRoleBindings for a given subject
kubectl get rolebindings,clusterrolebindings -A \
  -o json | jq '.items[] | select(.subjects[]?.name=="team-a-developers")'

# Find any ClusterRole granting wildcard verbs or resources (audit)
kubectl get clusterrole -o json | \
  jq -r '.items[] | select(.rules[]?.verbs[]? == "*" or .rules[]?.resources[]? == "*") | .metadata.name'

# Verify a pod's actual runtime securityContext post-admission
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.securityContext}{"\n"}{.spec.containers[0].securityContext}'

# Run a cluster-wide security posture scan (kube-bench, CIS benchmark)
kube-bench run --targets node,policies
```

## References

- [Kubernetes RBAC documentation](https://kubernetes.io/docs/reference/access-control/rbac/)
- [Kubernetes Security Checklist](https://kubernetes.io/docs/concepts/security/security-checklist/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) — see [`../pod-security/`](../pod-security/README.md)
- [Kyverno policy engine](https://kyverno.io/docs/) — see [`../kyverno/`](../kyverno/README.md)
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/) — see [`../network-policy/`](../network-policy/README.md)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [kube-bench](https://github.com/aquasecurity/kube-bench)
