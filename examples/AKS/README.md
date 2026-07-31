# AKS (Azure Kubernetes Service)

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`), logged in (`az login`) with a subscription set (`az account set --subscription <id>`)
- `kubectl` and `helm` installed
- An Azure Resource Group to deploy into

## Create the cluster

```bash
az group create --name <RESOURCE_GROUP> --location eastus

az aks create \
  --resource-group <RESOURCE_GROUP> \
  --name <CLUSTER_NAME> \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --zones 1 2 3 \
  --enable-managed-identity \
  --enable-cluster-autoscaler \
  --min-count 3 \
  --max-count 6 \
  --network-plugin azure \
  --generate-ssh-keys

az aks get-credentials --resource-group <RESOURCE_GROUP> --name <CLUSTER_NAME>
```

## Provider-specific notes

- **LoadBalancer annotations**: ingress-nginx's `Service` should set `service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz` and, for an internal LB, `service.beta.kubernetes.io/azure-load-balancer-internal: "true"`. Configure these in `helm-values/ingress-nginx/values.yaml`.
- **DNS**: use Azure DNS with external-dns. Grant external-dns a Managed Identity with the `DNS Zone Contributor` role scoped to the specific zone, referenced via Azure Workload Identity (federated credential) rather than a static Service Principal secret.
- **TLS**: cert-manager can use HTTP-01 out of the box; for wildcard certs use DNS-01 against Azure DNS with the same Workload Identity setup as external-dns.
- **Storage**: default `StorageClass` uses `disk.csi.azure.com`. Use `Premium_LRS` for production stateful workloads (Prometheus/Loki PVCs); zone-redundant storage (`ZRS`) if you need cross-zone resilience.
- **Node pools**: consider a separate system node pool (`--nodepool-name system` via `az aks nodepool add`) from user workloads for stability.

## Install the stack

```bash
./scripts/install.sh
```

Review and adjust `helm-values/ingress-nginx/`, `helm-values/external-dns/`, and `helm-values/storage` (via `manifests/storage/`) overrides for AKS-specific annotations and StorageClass provisioner names before running install, or re-run the relevant phase after editing values with `helm upgrade --install`.

## Verification

```bash
kubectl get nodes -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

Confirm the `EXTERNAL-IP` is assigned and reachable, then proceed through the rest of [`docs/introduction.md`](../../docs/introduction.md).

## Production hardening

- **Private API server**: add `--enable-private-cluster` at creation time (irreversible after the fact — cannot be toggled on an existing cluster) so the Kubernetes API is only reachable from within the VNet/peered networks; pair with `--api-server-authorized-ip-ranges` if you need a public endpoint restricted to specific CIDRs instead of fully private.
- **Node pool separation**: run a dedicated system node pool (`az aks nodepool add --mode System`) tainted against application workloads, plus one or more user node pools for actual application scheduling — this keeps control-plane-adjacent add-ons (CoreDNS, metrics-server) from being evicted by application pod churn/autoscaling.
- **Azure AD integration for cluster RBAC**: `--enable-aad --enable-azure-rbac` maps Azure AD groups to Kubernetes RBAC roles, so `manifests/security/rbac-baseline.yaml`-style bindings can reference AD group object IDs instead of managing a separate cluster-local identity system.
- **Managed control-plane upgrades**: AKS upgrades the control plane independently of node pools; use `az aks upgrade --control-plane-only` first, validate, then upgrade node pools with `az aks nodepool upgrade` using surge settings (`--max-surge 33%`) so capacity doesn't drop during the rolling upgrade. Never let node pool version skew exceed two minor versions behind the control plane (Kubernetes' supported skew policy).
- **Cost controls**: use a mix of `--priority Spot` node pools (with taints) for interruptible/batch workloads alongside the on-demand system/user pools, and keep `--min-count`/`--max-count` on the cluster autoscaler tight enough to avoid idle spend during low-traffic periods.

## Multi-cluster & disaster recovery

- **Cross-region DR**: provision a second AKS cluster in a paired Azure region (e.g. East US ↔ West US), point Velero's `BackupStorageLocation` at a geo-redundant storage account (`--sku Standard_RAGRS`) so backups survive a single-region outage — see [`../../manifests/velero/README.md`](../../manifests/velero/README.md) and [`../../manifests/backup/README.md`](../../manifests/backup/README.md) for the restore mechanics and DR posture options (backup-only vs. pilot-light vs. warm standby).
- **GitOps fan-out**: register both clusters with one Argo CD instance (typically in the primary region) using an `ApplicationSet` cluster generator, or run independent Argo CD instances per cluster synced from the same repo — see [`docs/gitops.md`](../../docs/gitops.md#applicationsets-for-multi-environmentmulti-cluster-fan-out).
- **StorageClass parity**: if DR restores land on a cluster provisioned identically (same `disk.csi.azure.com` StorageClass names), Velero's PV restore works without remapping; keep StorageClass names consistent across regions deliberately rather than letting them drift.
