# Storage

## StorageClasses

`manifests/storage/` defines `StorageClass` templates for each provider's default CSI driver:

- AKS: `disk.csi.azure.com` (Premium_LRS for production, Standard_LRS for dev)
- EKS: `ebs.csi.aws.com` (gp3 recommended over gp2 for cost/performance)
- GKE: `pd.csi.storage.gke.io` (pd-ssd for production workloads)
- Minikube: the built-in `standard` class (hostPath-backed, dev/test only — not durable)

Each `StorageClass` sets `reclaimPolicy: Retain` for anything holding stateful data you can't regenerate, and `volumeBindingMode: WaitForFirstConsumer` so volumes are provisioned in the same zone as the pod that claims them.

## Persistent volumes

Applications that need persistence (databases, Prometheus/Loki/Tempo local storage) request storage via a `PersistentVolumeClaim` referencing one of these `StorageClass`es rather than a hardcoded provisioner name — swap the `storageClassName` per environment through `helm-values/` overrides.

## Stateful components in this repo

- **Prometheus** (`manifests/prometheus/`) — local TSDB on a PVC; retention and size are tunable per environment, see `helm-values/prometheus/values.yaml`.
- **Loki** (`manifests/loki/`) — chunks/index on a PVC in single-binary mode, or object storage (S3/GCS/Azure Blob) in distributed mode for larger clusters.
- **Grafana** (`manifests/grafana/`) — a small PVC for dashboards/plugins if not using a database-backed config.
- **Velero** (`manifests/velero/`) — does *not* use a PVC itself; it writes backups to an object storage bucket you configure per provider.

## Backup of stateful data

Volume snapshots are handled by Velero's CSI plugin (`manifests/velero/`), which snapshots PVCs alongside the Kubernetes object backup. See [`docs/production-checklist.md`](production-checklist.md) and `scripts/backup.sh` / `scripts/restore.sh`.

## Sizing guidance

- Start Prometheus and Loki PVCs small (10–20Gi) in non-prod, and size for real retention (`storage.tsdb.retention.time`, Loki retention config) in production — under-provisioning here is the most common cause of silently-dropped metrics/logs.
- Use `ReadWriteOnce` unless a component explicitly needs `ReadWriteMany` (rare in this repo); `ReadWriteMany` usually requires an extra CSI driver (EFS/Azure Files/Filestore) not covered by the default StorageClasses above.

## Common problems

- Pods stuck `Pending` with `waiting for first consumer` — expected with `WaitForFirstConsumer`, resolves once a pod is scheduled.
- Cross-zone scheduling failures — the PV was provisioned in a different zone than where the pod was scheduled; check node affinity/topology.
- Full disks on Prometheus/Loki — check retention settings before scaling PVC size; retention misconfiguration is more common than genuine under-provisioning.
