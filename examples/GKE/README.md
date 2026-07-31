# GKE (Google Kubernetes Engine)

## Prerequisites

- [`gcloud` CLI](https://cloud.google.com/sdk/docs/install), authenticated (`gcloud auth login`) with a project set (`gcloud config set project <PROJECT_ID>`)
- `kubectl` and `helm` installed (`gcloud components install kubectl` works too)
- Required APIs enabled: `container.googleapis.com`, `dns.googleapis.com` (if using Cloud DNS)

## Create the cluster

```bash
gcloud container clusters create <CLUSTER_NAME> \
  --project <PROJECT_ID> \
  --zone us-central1-a \
  --node-locations us-central1-a,us-central1-b,us-central1-c \
  --machine-type e2-standard-4 \
  --num-nodes 1 \
  --enable-autoscaling --min-nodes 1 --max-nodes 2 \
  --workload-pool=<PROJECT_ID>.svc.id.goog \
  --release-channel regular

gcloud container clusters get-credentials <CLUSTER_NAME> --zone us-central1-a --project <PROJECT_ID>
```

`--num-nodes 1` with autoscaling `1`-`2` per zone across 3 zones gives 3-6 nodes total; adjust to your workload.

## Provider-specific notes

- **Workload Identity**: `--workload-pool` above enables it at the cluster level. For external-dns and cert-manager, create a Google Service Account (GSA) with `roles/dns.admin` scoped to the specific Cloud DNS zone (use a custom role for tighter scoping), then bind it to the Kubernetes `ServiceAccount` via `gcloud iam service-accounts add-iam-policy-binding` and the `iam.gke.io/gcp-service-account` annotation — no static JSON key files needed.
- **LoadBalancer**: GKE provisions a Network Load Balancer for `Service` type `LoadBalancer` automatically; use `cloud.google.com/load-balancer-type: "Internal"` annotation for an internal LB.
- **Storage**: default `StorageClass` uses `pd.csi.storage.gke.io`. Use `pd-ssd` for production Prometheus/Loki PVCs; GKE's default `standard` class maps to `pd-balanced` on newer clusters — pin explicitly rather than relying on the default.
- **DNS**: Cloud DNS integrates cleanly with external-dns; if your zone is managed elsewhere (e.g. a registrar), use that provider's external-dns webhook instead.
- **Autopilot**: this repo assumes Standard GKE (node pools you manage). Autopilot works but removes control over node sizing/DaemonSets some components here expect (e.g. log-shipping DaemonSets) — adapt accordingly.

## Install the stack

```bash
./scripts/install.sh
```

Update `helm-values/external-dns/values.yaml` and `helm-values/cert-manager/values.yaml` with the GSA email and Workload Identity annotations before installing those phases.

## Verification

```bash
kubectl get nodes -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller
gcloud container clusters describe <CLUSTER_NAME> --zone us-central1-a --format='value(workloadIdentityConfig)'
```

Confirm Workload Identity is enabled and the LoadBalancer `EXTERNAL-IP` is reachable before proceeding.
