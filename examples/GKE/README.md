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

## Production hardening

- **Private cluster**: `--enable-private-nodes` (nodes have no public IPs) combined with `--enable-master-authorized-networks --master-authorized-networks <office-cidr>/32` restricts both node exposure and control-plane API access; use Cloud NAT for node egress to the internet (pulling images, etc.) since private nodes have no public IP of their own.
- **Node pool separation**: create a dedicated system node pool (`gcloud container node-pools create system-pool --node-taints=CriticalAddonsOnly=true:NoSchedule`) for platform add-ons, separate from application node pools — mirrors the AKS/EKS pattern above.
- **IAM + Workload Identity for human RBAC**: bind Google Groups to Kubernetes RBAC via [Google Groups for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/google-groups-rbac) so `manifests/security/rbac-baseline.yaml`-style RoleBindings can reference a Google Group principal rather than individual users.
- **Release channels and control-plane upgrades**: `--release-channel regular` (already set above) lets Google manage control-plane upgrade timing within a channel's cadence; for tighter control use `--release-channel stable` or pin explicit versions with `--no-enable-autoupgrade` on node pools and upgrade them deliberately (`gcloud container clusters upgrade`) after validating each control-plane version in staging.
- **Cost controls**: preemptible/Spot VM node pools for interruptible workloads (`--spot` on a node pool), and keep cluster autoscaler bounds tight; GKE Autopilot (noted above as not this repo's default target) removes node-level cost tuning entirely in exchange for per-pod billing, worth reconsidering at smaller scale.

## Multi-cluster & disaster recovery

- **Cross-region DR**: provision a second GKE cluster in a different region, point a second `BackupStorageLocation` at a GCS bucket with cross-region or dual-region storage class so backups survive a single-region outage — see [`../../manifests/velero/README.md`](../../manifests/velero/README.md) and [`../../manifests/backup/README.md`](../../manifests/backup/README.md) for restore mechanics and DR posture (backup-only vs. pilot-light vs. warm standby).
- **GitOps fan-out**: one Argo CD instance managing both clusters via an `ApplicationSet` cluster generator, or Argo CD per-cluster synced from the same repo — see [`docs/gitops.md`](../../docs/gitops.md#applicationsets-for-multi-environmentmulti-cluster-fan-out).
- **Workload Identity pool is per-project, not per-cluster**: a DR cluster in the same GCP project can reuse the same `iam.gke.io/gcp-service-account` bindings; a DR cluster in a *different* project needs its own Workload Identity Pool and IAM bindings recreated against the new cluster's identity namespace.
