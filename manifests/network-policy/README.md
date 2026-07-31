# Network Policy

## What is this?

Kubernetes `NetworkPolicy` objects control which pods can talk to which
other pods, namespaces, and external CIDRs at L3/L4 (IP + port). By default,
every pod in a cluster can reach every other pod — a flat network with no
segmentation. This folder implements a **default-deny** baseline plus the
minimum allow-rules every namespace needs (DNS, intra-namespace traffic),
so you start from zero trust and explicitly opt in to the traffic your
applications actually require.

NetworkPolicies are enforced by the CNI plugin, not the API server itself —
they're inert unless your CNI supports them (Calico, Cilium, or a cloud
CNI's policy add-on; the default `kubenet`/basic bridge CNIs on some
distros do not enforce them at all).

## Architecture

```
Namespace: default
┌───────────────────────────────────────────────────────────┐
│  default-deny-all.yaml                                     │
│  podSelector: {}  policyTypes: [Ingress, Egress]            │
│  → blocks everything not explicitly allowed below           │
│                                                              │
│  allow-dns.yaml         allow-same-namespace.yaml            │
│  → egress to kube-dns   → ingress/egress within namespace    │
│    UDP/TCP 53             (pod ↔ pod, same namespace only)   │
│                                                              │
│  [app-specific policies: allow ingress from ingress-nginx,   │
│   allow egress to RDS/managed DB CIDR, etc. — not included   │
│   here, add per-application]                                │
└───────────────────────────────────────────────────────────┘
```

NetworkPolicies are additive within a namespace: if any policy selecting a
pod allows a given ingress/egress path, it's allowed — there's no explicit
"deny" rule type, only "allow" rules layered on top of an implicit
deny-all *for the directions the policy declares* (`policyTypes`). This is
why `default-deny-all.yaml` must set `policyTypes: [Ingress, Egress]` with
no rules: it establishes the deny baseline that later "allow" policies
punch holes in.

## Prerequisites

- A CNI that enforces NetworkPolicy: Calico, Cilium, Weave Net, or a cloud
  provider's native support (EKS with the VPC CNI + Calico/Cilium add-on,
  AKS with Azure CNI + Calico/Cilium, GKE with Dataplane V2/Calico).
  Verify with `kubectl get pods -n kube-system` for a Calico/Cilium
  DaemonSet, or check your provider's docs — applying these manifests on a
  CNI without policy support is a silent no-op.
- `kubernetes.io/metadata.name` namespace label (auto-added since
  Kubernetes 1.21+) if you use namespace selectors keyed on it, as
  `allow-dns.yaml` does.

## Installation

```bash
# Apply to a specific namespace (edit metadata.namespace first, or use -n
# to override on namespaces that don't set it inline)
kubectl apply -f manifests/network-policy/default-deny.yaml -n my-app
kubectl apply -f manifests/network-policy/allow-dns.yaml -n my-app
kubectl apply -f manifests/network-policy/allow-same-namespace.yaml -n my-app

# Roll out to every namespace via a loop (dev/test convenience only —
# prefer a per-namespace Kustomize overlay or Argo CD ApplicationSet with a
# namespace-list generator in production)
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in kube-system|kube-node-lease|kube-public) continue;; esac
  kubectl apply -n "$ns" -f manifests/network-policy/default-deny.yaml
  kubectl apply -n "$ns" -f manifests/network-policy/allow-dns.yaml
  kubectl apply -n "$ns" -f manifests/network-policy/allow-same-namespace.yaml
done
```

## Verification

```bash
# Confirm the CNI actually enforces policy (Calico example)
kubectl get pods -n kube-system -l k8s-app=calico-node

# List policies in a namespace
kubectl get networkpolicy -n my-app

# Describe to see the exact selector/rule evaluation
kubectl describe networkpolicy default-deny-all -n my-app

# Functional test: exec into a pod and confirm DNS still works...
kubectl exec -n my-app deploy/my-app -- nslookup kubernetes.default

# ...but cross-namespace traffic is blocked
kubectl exec -n my-app deploy/my-app -- curl -m 3 http://other-app.other-ns.svc.cluster.local
# Expect: connection timeout (not "connection refused" — refused means a
# policy isn't taking effect, it means the app rejected the TCP handshake)
```

## Configuration

- **`default-deny.yaml`** — `NetworkPolicy` with an empty `podSelector` and
  both `policyTypes`; duplicate/template it into every namespace that holds
  workloads.
- **`allow-dns.yaml`** — egress-only rule scoping DNS lookups to
  `kube-system`'s `kube-dns`-labeled pods on UDP/TCP 53. Adjust the
  `podSelector` label if your cluster runs `NodeLocal DNSCache` or a
  different CoreDNS label.
- **`allow-same-namespace.yaml`** — ingress + egress within the same
  namespace only. This is a starting point; most real applications also
  need an explicit ingress rule from `ingress-nginx`'s namespace and egress
  to specific external services (databases, third-party APIs) that aren't
  included here since they're app-specific.
- Combine these three as the baseline, then add one focused `NetworkPolicy`
  per additional traffic pattern (e.g., "allow ingress from
  ingress-nginx-namespace on port 8080") rather than widening any of these
  three files.

## Security

- **Apply `default-deny-all` to every namespace that runs workloads**,
  including ostensibly "internal-only" namespaces — lateral movement after
  a single pod compromise is exactly what network segmentation is meant to
  stop.
- **Scope `allow-dns` to the DNS pods specifically**, not a blanket "allow
  UDP/TCP 53 to anywhere" — an open port-53 egress rule is a known
  DNS-tunneling exfiltration path.
- **Don't forget egress.** Teams often remember ingress policies (protect
  the service from being reached) but skip egress (stop a compromised pod
  from reaching out) — this folder treats both as first-class from the
  start.
- **NetworkPolicies do not encrypt traffic** — they're L3/L4 allow-lists,
  not mTLS. Pair with a service mesh (Linkerd/Istio) or Cilium's
  transparent encryption if you need traffic confidentiality between pods.
- **Label selectors are the entire trust boundary.** A pod that
  accidentally picks up a label matching an `allow` policy's selector
  inherits that policy's access — treat security-relevant labels
  (`app`, `role`) as carefully as RBAC subjects.
- Verify policy behavior with `kubectl exec ... curl/nc` tests after every
  change; a typo in a `matchLabels` value fails silently (the rule just
  matches nothing) rather than erroring.

## Scaling

- NetworkPolicy enforcement cost scales with the CNI's dataplane, not with
  the number of policy objects directly — but very large numbers of
  fine-grained policies (thousands of rules) can slow down Calico's
  Felix/iptables (or Cilium's eBPF map) reconciliation on large clusters.
  Prefer broader selectors with fewer, well-labeled policies over one
  policy per pod.
- Cilium (eBPF dataplane) generally scales policy enforcement better than
  iptables-based CNIs at very high pod/policy counts — consider it for
  clusters with thousands of nodes/namespaces and heavy policy churn.
  Cilium's implementation of the standard `networking.k8s.io/v1` API used
  here is fully compatible in either case.
- Use consistent, minimal label sets across the fleet (e.g., always label
  `app.kubernetes.io/name`) so allow-policies can be written once per
  pattern and reused via Kustomize/Helm templating rather than hand-copied
  per namespace.

## Common Problems

- **Applying `default-deny-all` immediately breaks DNS for every pod in the
  namespace** — this is expected; you must apply `allow-dns.yaml` in the
  same change, not as a follow-up. Consider applying both in a single
  `kubectl apply -f` invocation against a directory.
- **NetworkPolicy applied but traffic still flows (or still blocked) as
  before** — the CNI doesn't enforce NetworkPolicy at all (e.g., plain
  `kubenet`/bridge CNI on some managed offerings without the policy add-on
  enabled). Check `kubectl get pods -n kube-system` for a policy-enforcing
  CNI component.
- **Ingress from an ingress controller stops working after default-deny**
  — no policy allows traffic from `ingress-nginx`'s namespace/pods. Add a
  dedicated ingress-allow policy selecting the ingress controller's
  namespace label and the target Service's port.
- **A Service's health checks/readiness probes start failing** — kubelet
  probes originate from the node's IP, not a pod, and are typically exempt
  from NetworkPolicy enforcement by most CNIs — but some strict CNI
  configurations block them. If probes fail right after applying policies,
  confirm your CNI's node-to-pod probe handling.
- **`allow-same-namespace.yaml` seems to have no effect on cross-namespace
  calls** — that's correct; it deliberately doesn't cover
  cross-namespace traffic. Add a separate policy with a
  `namespaceSelector` for the specific source namespace instead of
  widening this file.
- **StatefulSet/DaemonSet pods can't join a cluster (e.g., etcd, Kafka)
  because they need node-to-node traffic outside the namespace** — add an
  explicit `podSelector`-based allow rule for that specific quorum port
  rather than disabling default-deny for the whole namespace.

## Best Practices

- Treat `default-deny-all` as the mandatory baseline for every namespace
  before anything else — cluster infra namespaces (kube-system) are
  managed by the platform team's own policies, application namespaces get
  this file.
- Layer policies by concern: one file for DNS, one for intra-namespace,
  one per external dependency — easier to review, audit, and roll back
  than one giant NetworkPolicy per namespace.
- Use `namespaceSelector` + `podSelector` combined (AND semantics within one
  `from`/`to` entry) to scope cross-namespace allows precisely, e.g., "only
  the ingress-nginx pods in the ingress-nginx namespace," not "the entire
  ingress-nginx namespace."
- Name policies descriptively (`allow-dns-egress`, not `policy1`) — the
  name is what shows up in `kubectl get networkpolicy` and incident
  response.
- Test policy changes in a non-prod namespace with the same CNI before
  rolling out cluster-wide; a syntactically valid but semantically wrong
  selector fails silently.
- Roll these out via GitOps (`manifests/argocd/`) so policy drift is
  self-healed the same way as any other manifest.

## Useful Commands

```bash
# List all NetworkPolicies across the cluster
kubectl get networkpolicy -A

# Show the full spec/rules for a policy
kubectl get networkpolicy default-deny-all -n my-app -o yaml

# Test connectivity from inside a pod (exec + curl/nc)
kubectl exec -n my-app <pod> -- nc -zv -w 3 <target-ip> <port>

# Calico-specific: view the calculated iptables/eBPF rules for a pod
calicoctl get workloadendpoint -n my-app -o yaml

# Cilium-specific: check policy verdicts live
cilium monitor --type policy-verdict

# Delete a policy to temporarily fully open a namespace for debugging
# (re-apply immediately after — never leave a namespace without deny-all)
kubectl delete networkpolicy default-deny-all -n my-app
```

## References

- [Kubernetes NetworkPolicy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Network Policy Editor / recipes](https://github.com/ahmetb/kubernetes-network-policy-recipes)
- [Calico NetworkPolicy documentation](https://docs.tigera.io/calico/latest/network-policy/)
- [Cilium NetworkPolicy documentation](https://docs.cilium.io/en/stable/security/policy/)
- [CNCF: Kubernetes Network Policy recipes](https://github.com/cilium/cilium/tree/main/examples/policies)
