# Pod Security Admission

## What is this?

Pod Security Admission (PSA) is the built-in Kubernetes admission
controller (stable since v1.25, replacing the removed PodSecurityPolicy)
that enforces the [Pod Security
Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) —
three predefined tiers (`privileged`, `baseline`, `restricted`) of pod
hardening rules. Unlike PodSecurityPolicy or Kyverno, PSA needs **no
controller to install and no CRDs** — it's configured entirely through
labels on the `Namespace` object itself, evaluated directly by the API
server at admission time.

This folder shows all three tiers side by side for comparison
(`namespace-labels.yaml`) and a fully `restricted`-compliant pod spec
(`restricted-example.yaml`) you can use as a template for real workloads.

## Architecture

```
                     kubectl apply -f pod.yaml
                              │
                              ▼
                    kube-apiserver admission chain
                              │
                              ▼
              Pod Security Admission (built-in, no webhook)
                              │
              reads labels on the Pod's target Namespace:
              pod-security.kubernetes.io/enforce: <level>
              pod-security.kubernetes.io/audit:   <level>
              pod-security.kubernetes.io/warn:    <level>
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
   enforce=privileged   enforce=baseline      enforce=restricted
   (no restrictions)    (blocks known priv    (blocks anything not
                         escalations: host     runAsNonRoot, no extra
                         namespaces, hostPath, capabilities, no
                         privileged:true, ...) privilege escalation, ...)
```

- **`enforce`** — actually rejects non-compliant pods at admission time.
- **`audit`** — allows the pod but adds a `PodSecurity` entry to the
  audit log for anything that would fail the given level.
- **`warn`** — allows the pod but returns a client-visible warning
  (`kubectl apply` prints it) for anything that would fail the given
  level.

Running `warn`/`audit` at a stricter level than `enforce` (as
`namespace-labels.yaml`'s `baseline` example does, warning at
`restricted`) is the standard way to surface "you're not compliant with
the next tier yet" without blocking anyone today.

## Prerequisites

- Kubernetes 1.23+ (beta) or 1.25+ (GA/stable) — PSA is built into the API
  server, no separate install.
- Namespace-level access to add labels (`kubectl label namespace`), or
  manage the namespace object itself via GitOps.
- If migrating off PodSecurityPolicy (removed in 1.25) or replacing/pairing
  with Kyverno (`manifests/kyverno/policies/require-non-root.yaml`
  overlaps with the `restricted` tier's `runAsNonRoot` requirement),
  decide which tool is authoritative to avoid confusing, duplicate
  rejections.

## Installation

Nothing to install — apply the namespace labels directly:

```bash
# Create/label a namespace at the restricted tier
kubectl apply -f manifests/pod-security/namespace-labels.yaml

# Or label an existing namespace imperatively
kubectl label namespace my-app \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite

# Deploy the compliant example workload
kubectl apply -f manifests/pod-security/restricted-example.yaml
```

## Verification

```bash
# Confirm the labels landed
kubectl get ns apps-restricted --show-labels

# Try applying a deliberately non-compliant pod to confirm enforcement
kubectl run privileged-test --image=nginx --privileged=true \
  -n apps-restricted --dry-run=server
# Expect: Error from server (Forbidden): pods "privileged-test" is
# forbidden: violates PodSecurity "restricted:latest": privileged (...)

# Confirm the compliant example is admitted cleanly
kubectl apply -f manifests/pod-security/restricted-example.yaml --dry-run=server

# Check for warn/audit-only violations without blocking anything
kubectl apply -f some-legacy-deployment.yaml -n apps-baseline
# Any "restricted" gaps print inline as Warning: lines
```

## Configuration

- **`namespace-labels.yaml`** — three separate `Namespace` documents
  (`apps-restricted`, `apps-baseline`, `kube-system-example`) showing the
  full label set for each PSS tier side by side. Copy the block matching
  your target tier into your real namespace manifest.
- **`restricted-example.yaml`** — a `Deployment` satisfying every
  `restricted`-tier requirement: non-root user/group, no privilege
  escalation, all capabilities dropped, `seccompProfile: RuntimeDefault`,
  plus `readOnlyRootFilesystem: true` as an additional hardening step
  PSA doesn't itself require but that pairs naturally with it.
- Pin `*-version` labels (e.g. `v1.29`) instead of `latest` in namespaces
  where you want the enforced rule set to stay fixed across cluster
  upgrades until you explicitly re-test and bump it.

## Security

- **Default every new application namespace to `restricted`.** Treat
  `baseline` as a temporary migration aid, not a long-term home — track
  namespaces still on `baseline` and drive them to zero.
- **Never label a namespace `privileged` without an explicit, reviewed
  justification** (usually only CNI/CSI/node-agent namespaces need it) —
  it disables PSA entirely for that namespace.
- **PSA only governs pod *specs* at admission time** — it doesn't restrict
  what a container does at runtime (that's seccomp/AppArmor profile
  *content*, not just "is one set") or provide network-level isolation
  (that's `manifests/network-policy/`). Layer it with NetworkPolicies,
  Kyverno policies, and runtime security tooling (Falco) for full
  defense-in-depth.
- **`restricted` does not by itself require `readOnlyRootFilesystem` or a
  resource `limits`/`requests`** — those are good practice (shown in
  `restricted-example.yaml`) but come from Kyverno
  (`require-resource-limits.yaml`) or your own conventions, not PSA.
- **`automountServiceAccountToken: false`** (set in the example) is not a
  PSA requirement either, but prevents every pod from carrying an
  API-server credential by default — pair with least-privilege RBAC
  (`manifests/security/rbac-baseline.yaml`) for pods that do need one.
- Watch the audit log / warnings during rollout — a sudden burst of
  `PodSecurity` audit annotations after a cluster upgrade usually means the
  Pod Security Standard definition itself changed between versions.

## Scaling

- PSA has effectively zero performance cost at any cluster size — it's a
  synchronous, in-process check in the API server, not a separate
  webhook call over the network (unlike Kyverno/OPA Gatekeeper).
- Because enforcement is per-namespace via labels, scaling PSA adoption
  across hundreds of namespaces is a labeling/GitOps problem, not an
  infrastructure one — template the labels via Kustomize/Helm so every new
  namespace is born with the right tier rather than needing a follow-up
  `kubectl label`.
- Use `warn`/`audit` at a stricter tier fleet-wide first, then flip
  `enforce` namespace-by-namespace once each team confirms `kubectl get
  events` / audit logs show no violations — this scales the migration
  itself without a big-bang cutover.

## Common Problems

- **A previously-working Deployment is suddenly rejected after labeling a
  namespace `restricted`** — almost always a missing
  `securityContext.runAsNonRoot`, a container still requesting an added
  Linux capability, or no `seccompProfile` set. Run `kubectl apply
  --dry-run=server` and read the `violates PodSecurity` message — it names
  the exact failing field.
- **Sidecar injected by a service mesh (Istio/Linkerd) fails
  `restricted`** — many mesh sidecars historically needed
  `NET_ADMIN`/`NET_RAW` capabilities for traffic interception. Use the
  mesh's CNI-plugin mode (which moves iptables setup to an init container
  outside the pod's runtime capabilities) instead of the classic init
  container approach, or place the mesh's own namespace at `baseline`.
- **A Helm chart's default values fail `restricted`** — most upstream
  charts default to permissive `securityContext` (or none at all). Override
  `securityContext`/`podSecurityContext` values explicitly rather than
  lowering the namespace's PSA tier to accommodate the chart.
- **`warn` labels print noisy warnings on every `kubectl apply` but nothing
  is actually blocked** — that's `warn`/`audit` working as designed
  (non-blocking); if you want it blocked, that namespace's `enforce` label
  needs updating too, not just `warn`.
- **`kube-system` pods fail after accidentally applying `restricted`
  cluster-wide** — never set PSA labels on `kube-system`; it holds
  CNI/CSI/control-plane pods that legitimately need host access. Use
  `namespace-labels.yaml`'s `privileged` example as the template for that
  namespace instead.
- **PodSecurityPolicy (PSP) migration confusion** — PSP was removed in
  1.25. If you're migrating from PSP, there's no direct one-to-one label
  mapping for custom PSPs; use the [Pod Security Standards
  migration guide](https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/)
  and expect to also lean on Kyverno for anything PSP did that PSA's fixed
  three tiers don't cover (e.g., enforcing specific allowed volume types
  beyond what "restricted" already blocks).

## Best Practices

- Apply `restricted` by default to all new namespaces; require an explicit,
  documented exception (and ideally a compensating Kyverno/NetworkPolicy
  control) to use anything looser.
- Set `warn` and `audit` one tier stricter than `enforce` during any
  migration window so you get visibility into what breaks before you flip
  the switch.
- Keep PSA and Kyverno's pod-security-adjacent policies
  (`require-non-root.yaml`) aligned in intent — don't let them silently
  contradict each other (e.g., PSA at `baseline` while Kyverno enforces
  `restricted`-equivalent rules is fine and complementary; the reverse,
  where Kyverno is looser than the namespace's PSA tier, just means PSA is
  the binding constraint).
- Bake the compliant `securityContext` block from `restricted-example.yaml`
  into your Helm chart's default `values.yaml` for new services, so
  "secure by default" doesn't depend on every author remembering it.
- Pin `*-version` in namespaces where a cluster upgrade changing the
  standard's rule set unexpectedly could break workloads; float `latest`
  where you want to always track the newest, strictest definition.

## Useful Commands

```bash
# Show PSA labels on every namespace
kubectl get ns -o custom-columns=\
NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\\.kubernetes\\.io/enforce

# Label a namespace at a given tier
kubectl label namespace my-app pod-security.kubernetes.io/enforce=restricted --overwrite

# Dry-run a manifest to preview PSA admission without applying
kubectl apply -f deployment.yaml --dry-run=server

# Check whether an already-running pod would pass a stricter tier
# (temporarily label the namespace with warn/audit, don't flip enforce)
kubectl label namespace my-app pod-security.kubernetes.io/warn=restricted --overwrite
kubectl get pods -n my-app -o name | xargs -I{} kubectl get {} -n my-app -o yaml | kubectl apply --dry-run=server -f -

# View recent PodSecurity audit log entries (requires audit logging enabled)
kubectl get events -n my-app --field-selector reason=FailedCreate
```

## References

- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Enforcing Pod Security Standards (labels reference)](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)
- [Migrate from PodSecurityPolicy to Pod Security Admission](https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/)
- [seccomp profiles in Kubernetes](https://kubernetes.io/docs/tutorials/security/seccomp/)
