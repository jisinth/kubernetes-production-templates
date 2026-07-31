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
