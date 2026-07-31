# Minikube

Local single-node cluster for development and testing the manifests in this repo before touching a real cloud cluster.

## Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/) installed
- A container/VM driver (Docker Desktop, or `hyperkit`/`kvm2`/`hyperv` depending on OS)
- `kubectl` and `helm` installed

## Create the cluster

```bash
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=8192 \
  --kubernetes-version=stable \
  --addons=metrics-server

minikube addons enable ingress
minikube addons enable ingress-dns   # optional, for *.test domain resolution without /etc/hosts edits
```

## Provider-specific notes

- **Ingress**: Minikube ships its own ingress-nginx via the `ingress` addon, already configured for the cluster's driver networking. If you prefer the repo's own `manifests/ingress-nginx/` install instead, disable the addon first (`minikube addons disable ingress`) to avoid two controllers competing for port 80/443.
- **LoadBalancer**: `Service` type `LoadBalancer` never gets a real external IP on Minikube — run `minikube tunnel` in a separate terminal to simulate one, or just use the addon's ingress and `minikube ip`.
- **DNS**: external-dns has nothing real to manage locally; skip that phase (`./scripts/install.sh --skip-external-dns`) and resolve hostnames via `/etc/hosts` pointing at `minikube ip`, or use the `ingress-dns` addon.
- **TLS**: cert-manager's HTTP-01/DNS-01 challenges can't reach a local cluster from the public internet — use the `selfsigned` `ClusterIssuer` variant for local testing rather than Let's Encrypt.
- **Storage**: the built-in `standard` `StorageClass` (hostPath-backed) is fine for local testing but is **not durable** — data is lost if the Minikube VM/container is deleted. Don't use this as a stand-in for real PVC behavior testing.
- **Resources**: the full observability stack (Prometheus + Grafana + Loki + Tempo + Alertmanager) is heavy for a laptop; consider `./scripts/install.sh --skip-argocd --skip-security` first and add phases incrementally, or reduce replica counts in `helm-values/*/values.yaml`.

## Install the stack

```bash
./scripts/install.sh --skip-external-dns
```

## Verification

```bash
kubectl get nodes
minikube service list
curl --resolve myapp.test:80:$(minikube ip) http://myapp.test
```

Once comfortable locally, move to [`examples/AKS`](../AKS/README.md), [`examples/EKS`](../EKS/README.md), or [`examples/GKE`](../GKE/README.md) for a real cloud cluster.
