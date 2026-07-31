# Architecture

## Layered topology

The cluster is built in layers, each depending on the one below it:

| Layer | Components | Manifests |
|---|---|---|
| Foundation | Namespaces, RBAC baseline | `manifests/namespace/` |
| Ingress & DNS | ingress-nginx, cert-manager, external-dns | `manifests/ingress-nginx/`, `manifests/cert-manager/`, `manifests/external-dns/` |
| Autoscaling | metrics-server, HPA/VPA | `manifests/metrics-server/`, `manifests/autoscaling/` |
| Observability | Prometheus, Grafana, Loki, Tempo, Alertmanager | `manifests/prometheus/`, `manifests/grafana/`, `manifests/loki/`, `manifests/tempo/`, `manifests/alertmanager/` |
| GitOps | ArgoCD | `manifests/argocd/` |
| Security | Kyverno, NetworkPolicy, Pod Security Standards, Sealed Secrets | `manifests/kyverno/`, `manifests/network-policy/`, `manifests/pod-security/`, `manifests/sealed-secrets/` |
| Storage | StorageClasses, PVC templates | `manifests/storage/` |
| Backup/DR | Velero | `manifests/velero/`, `manifests/backup/` |
| Workloads | Sample applications | `applications/nginx/`, `applications/nodejs/`, `applications/python/`, `applications/springboot/`, `applications/flask/` |

## Request flow

External traffic hits the cloud load balancer provisioned by `ingress-nginx`'s `Service` (type `LoadBalancer`), which routes by `Ingress` host/path rules into cluster `Service`s and then to pod endpoints. `cert-manager` issues and rotates the TLS certificates that `ingress-nginx` terminates. `external-dns` watches `Ingress`/`Service` objects and keeps the cloud DNS zone in sync with hostnames, so a new `Ingress` gets a working DNS record without manual intervention.

## Control plane vs. data plane additions

- **Data plane**: everything under `applications/` and the workload-facing parts of `manifests/` (ingress, autoscaling, storage) run as regular pods on worker nodes.
- **Cluster add-ons**: Prometheus/Grafana/Loki/Tempo/Alertmanager, ArgoCD, Kyverno, and cert-manager are cluster-wide controllers/operators, typically installed via Helm into dedicated namespaces (`monitoring`, `argocd`, `kyverno`, `cert-manager`).

## GitOps overlay

Once the base stack is stable, ArgoCD (`manifests/argocd/`) takes over reconciliation: instead of `kubectl apply -f`, an `Application` resource points at this repo (or a fork of it) and continuously syncs cluster state to what's committed. See [`docs/gitops.md`](gitops.md).

## Multi-cloud abstraction

Manifests are cloud-agnostic where possible; provider differences (LoadBalancer annotations, StorageClass provisioners, IAM/Workload Identity bindings) live in `helm-values/` overrides and in the provider-specific guides under `examples/AKS/`, `examples/EKS/`, `examples/GKE/`, `examples/Minikube/`.

See [`architecture/README.md`](../architecture/README.md) for Mermaid diagrams of this topology.
