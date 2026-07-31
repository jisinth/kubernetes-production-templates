# external-dns

## What is this?

`external-dns` watches Kubernetes `Service` and `Ingress` objects and synchronizes DNS records in an external DNS provider (Route53, Cloud DNS, Azure DNS, Cloudflare, and many more) to match. Instead of manually creating a DNS record every time you expose a new hostname through `ingress-nginx`, you set `spec.rules[].host` on the `Ingress` and external-dns creates (and later removes) the matching record automatically.

This repo's `external-dns` config is provider-agnostic in structure — `provider.name` and the corresponding credentials/IAM block are the only pieces that change between AWS, GCP, Azure, or others.

## Architecture

```
Ingress (host: app.example.com)  ──watched by──▶  external-dns
Service (type: LoadBalancer)     ──watched by──▶       │
                                                        ▼
                                          Cloud DNS provider API
                                          (Route53 / Cloud DNS / Azure DNS / ...)
                                                        │
                                                        ▼
                                          A/CNAME record: app.example.com
                                          TXT record: external-dns-app.example.com
                                          (ownership marker — see "registry: txt")
```

The TXT registry record lets multiple external-dns instances (or the same instance across restarts) know which DNS records it owns, so it never deletes records it didn't create — this is what makes `policy: sync` safe to run against a shared/production hosted zone.

## Prerequisites

- A DNS zone already delegated to your provider (e.g. a Route53 hosted zone for `example.com`).
- Cloud IAM configured for workload identity — **do not use long-lived static credentials** if avoidable:
  - AWS: IRSA (IAM Roles for Service Accounts) — annotate the ServiceAccount with `eks.amazonaws.com/role-arn`.
  - GCP: Workload Identity — annotate with `iam.gke.io/gcp-service-account`.
  - Azure: Workload Identity — annotate with `azure.workload.identity/client-id`.
- The IAM role/policy needs least-privilege DNS record read/write on the specific zone only (e.g. AWS: `route53:ChangeResourceRecordSets` scoped to the hosted zone ARN, plus `route53:ListHostedZones`/`ListResourceRecordSets`).
- `ingress-nginx` (or another source of `host`-bearing Ingress/Service objects) already running if you want DNS driven off Ingress.

## Installation

```bash
kubectl create namespace external-dns
kubectl apply -f manifests/external-dns/rbac.yaml

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns
helm repo update
helm upgrade --install external-dns external-dns/external-dns \
  --namespace external-dns \
  -f manifests/external-dns/values.yaml \
  --wait
```

Standalone (non-Helm):

```bash
kubectl apply -f manifests/external-dns/rbac.yaml
kubectl apply -f manifests/external-dns/deployment.yaml
```

**Before running against a real/shared zone**: add `--dry-run` to `args`/`extraArgs`, install, and check the logs to see exactly what records external-dns *would* create/delete, without it touching anything. Remove `--dry-run` once you've confirmed the plan looks correct.

## Verification

```bash
kubectl get pods -n external-dns
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns -f
```

Look for log lines like `CREATE: app.example.com A [...]` after applying an Ingress with a new `host`. Confirm in your DNS provider's console/CLI:

```bash
# AWS example
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> --query "ResourceRecordSets[?Name=='app.example.com.']"

dig +short app.example.com
```

## Configuration

- **`provider.name`** — set to `aws`, `google`, `azure`, `cloudflare`, `digitalocean`, `rfc2136`, `coredns`, etc. Each provider has its own auth block; see the [provider list](https://github.com/kubernetes-sigs/external-dns#status-of-providers) for the exact env vars/flags it expects.
- **`domainFilters`** — restrict external-dns to zones it's allowed to touch. Always set this in shared accounts; without it, external-dns will attempt to manage every zone visible to its IAM credentials.
- **`policy`** — `sync` (default here) creates and deletes records to match cluster state; `upsert-only` only ever creates/updates, never deletes, which is safer for a first rollout onto a zone with pre-existing manually-managed records.
- **`sources`** — `service` and `ingress` are the common two; add `istio-gateway`, `crd`, or others if you use those routing mechanisms.
- **`txtOwnerId` / `txtPrefix` / `registry: txt`** — the ownership tracking that makes `sync` safe. Use a distinct `txtOwnerId` per cluster if multiple clusters share a zone, so each cluster only manages its own records.
- **Per-resource control** — annotate an individual `Ingress`/`Service` with `external-dns.alpha.kubernetes.io/hostname: custom.example.com` to override the record it creates, or `external-dns.alpha.kubernetes.io/exclude: "true"` to have external-dns ignore it entirely.

## Security

- Use workload identity (IRSA / Workload Identity / Azure Workload Identity) instead of mounting static cloud credentials as a Secret — this repo's [`values.yaml`](values.yaml) and [`rbac.yaml`](rbac.yaml) annotate the ServiceAccount for exactly this.
- Scope the IAM policy to the specific hosted zone(s) in `domainFilters`, never `route53:*`/equivalent wildcard DNS permissions.
- The Kubernetes RBAC in [`rbac.yaml`](rbac.yaml) is read-only against the Kubernetes API (`get`/`watch`/`list` on Services/Ingresses/Nodes) — external-dns never needs write access to cluster objects, only to the external DNS provider.
- Run as non-root with a read-only root filesystem and all Linux capabilities dropped (already set in both [`values.yaml`](values.yaml) and [`deployment.yaml`](deployment.yaml)).
- Use `policy: upsert-only` in any zone shared with manually-managed records you don't want external-dns able to delete.

## Scaling

- external-dns does not support active-active multi-replica operation against the same zone — two replicas racing to reconcile the same records causes flapping. Run `replicaCount: 1` (the Deployment uses `strategy: Recreate` for the same reason) and rely on Kubernetes rescheduling on node failure, not replica count, for availability.
- `--interval` controls reconciliation frequency, not throughput — lower it (e.g. `30s`) for faster DNS propagation after an Ingress change, at the cost of more frequent provider API calls (watch cloud API rate limits at very short intervals).
- Very large clusters (many hundreds of Ingress/Service objects) may want `--interval` raised slightly and `resources.limits.memory` increased, since external-dns holds the full desired-state record set in memory per reconciliation.

## Common Problems

1. **Records never appear, no errors in logs** — check `domainFilters` includes the zone, and that `sources` includes the object type you're using (`ingress` vs `service`). Also confirm the Ingress actually has a `host` set — external-dns has nothing to create a record for otherwise.
2. **`AccessDenied` / `403` from the cloud provider API** — IAM role/policy doesn't have write access to the target zone, or the ServiceAccount annotation (`eks.amazonaws.com/role-arn` etc.) doesn't match what's configured in IAM/the identity provider trust policy. Verify the ServiceAccount's projected token is being exchanged correctly (`kubectl describe pod` for IRSA env vars, or `aws sts get-caller-identity` from inside the pod).
3. **external-dns deletes records it doesn't own** — `txtOwnerId` collision between two external-dns instances pointed at the same zone, or `registry` wasn't set to `txt` on an earlier install so ownership was never tracked. Fix by giving each instance a unique `txtOwnerId` and ensuring `registry: txt` was enabled from the start.
4. **DNS record created but points at the wrong IP after a LoadBalancer Service is replaced** — normal eventual consistency; check `--interval` and confirm the reconciliation actually ran (`kubectl logs`). If the record is stuck stale, check for a second controller (e.g. a cloud-provider's own DNS integration) fighting for ownership of the same record outside the TXT registry.

## Best Practices

- Always set `domainFilters` — never let external-dns have implicit access to every zone in the account.
- Start every new domain/cluster pairing with `--dry-run`, review the plan, then remove it.
- Use `upsert-only` policy when onboarding external-dns onto a zone with pre-existing records you haven't audited yet; switch to `sync` once you trust it fully owns the zone's dynamic records.
- Give each cluster a unique `txtOwnerId` if multiple clusters share the same hosted zone.
- Prefer workload identity over static cloud credentials, full stop — this is the single most impactful security choice for this component.

## Useful Commands

```bash
# Watch reconciliation logs live
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns -f

# Confirm the ServiceAccount's cloud identity annotation is set correctly
kubectl get sa external-dns -n external-dns -o yaml

# See which Ingress/Service objects external-dns currently sees as sources
kubectl get ingress,svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.spec.rules[*].host}{.status.loadBalancer}{"\n"}{end}'

# Force an immediate reconciliation (restart triggers one on startup)
kubectl rollout restart deployment/external-dns -n external-dns

# Check current record state directly against the provider (AWS example)
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID>
```

## References

- [external-dns GitHub](https://github.com/kubernetes-sigs/external-dns)
- [external-dns Helm chart](https://github.com/kubernetes-sigs/external-dns/tree/master/charts/external-dns)
- [Supported providers](https://github.com/kubernetes-sigs/external-dns#status-of-providers)
- [IRSA (AWS)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [GKE Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [Azure AD Workload Identity](https://azure.github.io/azure-workload-identity/docs/)
- [external-dns annotations reference](https://kubernetes-sigs.github.io/external-dns/latest/docs/annotations/annotations/)
