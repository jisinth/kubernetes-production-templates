# Storage

## What is this?

Kubernetes decouples "what storage a pod needs" (`PersistentVolumeClaim`)
from "how that storage is actually provisioned" (`StorageClass` +
a CSI driver), which is what lets the same Deployment manifest request
"20Gi of storage" on EKS, AKS, or GKE without knowing it'll end up backed
by EBS, Azure Disk, or a GCE Persistent Disk respectively. This folder has
one `StorageClass` per major cloud block-storage provisioner and a
`PersistentVolumeClaim` example that consumes one of them.

## Architecture

```
   Pod (spec.volumes[].persistentVolumeClaim)
        │
        ▼
   PersistentVolumeClaim (pvc-example.yaml)
     storageClassName: gp3
     accessModes: [ReadWriteOnce]
     resources.requests.storage: 20Gi
        │
        ▼
   StorageClass "gp3" (storageclass-examples.yaml)
     provisioner: ebs.csi.aws.com
     volumeBindingMode: WaitForFirstConsumer   ◀── binds only once a pod
        │                                          is scheduled, so the
        ▼                                          volume lands in the
   CSI driver (ebs-csi-controller)                  pod's zone
        │
        ▼
   Cloud block storage (EBS volume / Azure Disk / GCE PD)
        │
        ▼
   PersistentVolume (auto-created, bound 1:1 to the PVC)
```

`WaitForFirstConsumer` (used by all three examples) defers volume creation
until a pod claiming it is scheduled, so the CSI driver provisions the
volume in the *same zone* the scheduler picked for the pod — critical for
zonal block storage, where a volume created in `us-east-1a` cannot attach
to a node in `us-east-1b`.

## Prerequisites

- The relevant CSI driver installed for your cloud:
  - AWS: [aws-ebs-csi-driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
    (an EKS add-on, or self-managed via Helm)
  - Azure: `disk.csi.azure.com` (built into AKS by default)
  - GCP: `pd.csi.storage.gke.io` (built into GKE by default on 1.21+)
- IAM/role permissions for the CSI controller to create/attach/delete
  volumes (IRSA on EKS, a managed identity on AKS, Workload Identity on
  GKE).
- Cluster nodes spread across the same zones your `StorageClass` and
  workloads expect, if you rely on zonal (non-regional) disks.

## Installation

```bash
# Pick ONE StorageClass matching your cloud (or all three if the cluster
# somehow spans providers) and apply it
kubectl apply -f manifests/storage/storageclass-examples.yaml

# Confirm it registered
kubectl get storageclass

# Apply the example PVC (edit storageClassName if you're not on AWS/gp3)
kubectl apply -f manifests/storage/pvc-example.yaml
```

## Verification

```bash
# StorageClasses present and which one is the cluster default
kubectl get storageclass

# PVC status — Pending is expected until a consuming pod is scheduled
# (WaitForFirstConsumer), Bound once that happens
kubectl get pvc app-data -n default -w

# Schedule a pod that mounts it to trigger binding, then confirm the
# underlying PV and its zone
kubectl run pvc-test --image=busybox -n default --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"pvc-test","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"app-data"}}]}}'
kubectl get pvc app-data -o jsonpath='{.spec.volumeName}'
kubectl get pv <volume-name> -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'
```

## Configuration

- **`storageclass-examples.yaml`** — `gp3` (AWS EBS), `premium-ssd` (Azure
  Disk), `pd-ssd` (GCE PD), each with `reclaimPolicy: Delete`,
  `allowVolumeExpansion: true`, and `volumeBindingMode:
  WaitForFirstConsumer`. Adjust `parameters.iops`/`throughput` (AWS),
  `skuName` (Azure), or `replication-type` (GCP, `regional-pd` for
  cross-zone redundancy) per workload needs.
- **`pvc-example.yaml`** — `ReadWriteOnce`, 20Gi, referencing `gp3`. Swap
  `storageClassName` to match whichever class you kept, and switch
  `accessModes` to `ReadWriteMany` only if you also switch to a
  filesystem-backed class (EFS/Azure Files/Filestore) — block storage
  classes here don't support it.
- Set `reclaimPolicy: Retain` instead of `Delete` for any StorageClass
  backing data you cannot regenerate (databases, uploaded user content) —
  `Delete` destroys the underlying cloud volume the moment the PVC is
  deleted.

## Security

- **Encrypt every StorageClass at rest** — all three examples set an
  encryption parameter (`encrypted: "true"` for EBS,
  `diskEncryptionSetID` for Azure, `disk-encryption-kms-key` for GCE).
  Leaving these unset typically still encrypts with a platform-managed key
  on modern clouds, but a customer-managed key (CMK) gives you rotation
  and revocation control.
- **`reclaimPolicy: Delete` is a data-loss switch** — for anything holding
  data you can't regenerate, use `Retain` (or snapshot via Velero/CSI
  VolumeSnapshot before allowing deletion) so an accidental
  `kubectl delete pvc` doesn't also destroy the underlying volume.
- **Restrict who can create PVCs against expensive/high-IOPS
  StorageClasses** — a `ResourceQuota` scoped by `storageClassName` (via
  `requests.storage` per class) prevents one namespace from consuming an
  entire team's storage budget.
- **CSI controller ServiceAccounts hold cloud credentials capable of
  creating/deleting volumes** — scope their IAM roles to the minimum
  `ec2:CreateVolume`/`DeleteVolume`/`AttachVolume` (or provider
  equivalent) actions, not broad storage-account-wide access.
- Snapshot sensitive volumes via `VolumeSnapshotClass` + Velero
  (`manifests/velero/`) rather than relying on the cloud disk alone as
  your only copy of the data.

## Scaling

- `allowVolumeExpansion: true` (set on all three examples) lets you grow a
  PVC's `resources.requests.storage` in place
  (`kubectl edit pvc/patch`) without recreating the pod, though the
  filesystem resize itself only completes after the consuming pod restarts
  on most CSI drivers.
- Zonal block storage (the default in all three examples) doesn't survive
  a zone outage — for workloads with a real availability SLO, use
  cross-zone replication (`regional-pd` on GCP, or an application-level
  replication strategy like a StatefulSet with per-replica volumes spread
  across zones) instead of relying on the disk layer alone.
- High-IOPS workloads (databases) should tune `iops`/`throughput`
  (gp3) or a higher `skuName` tier (Azure) directly rather than
  over-provisioning volume *size* to indirectly get more IOPS (gp3
  decouples the two; gp2 and some Azure/GCP tiers do not).
- For very large fan-out (many pods needing the same read-only dataset),
  prefer a `ReadOnlyMany`-capable class or an object-store-backed approach
  over trying to share one block-storage PVC.

## Common Problems

- **PVC stuck `Pending` forever** — if `volumeBindingMode:
  WaitForFirstConsumer` is set, this is expected until a pod referencing it
  is scheduled; if a pod *is* scheduled and it's still Pending, check
  `kubectl describe pvc` for the actual provisioner error (commonly IAM
  permissions or a zone with no available capacity for that disk type).
- **Pod stuck `Pending` with `node(s) had volume node affinity conflict`**
  — the PV was provisioned in a different zone than the node the scheduler
  picked, usually because `volumeBindingMode: Immediate` was used instead
  of `WaitForFirstConsumer`, or a node pool was resized/rebalanced across
  zones after the PV existed. Fix going forward by using
  `WaitForFirstConsumer` (already default here); for an existing stuck PV,
  the volume typically has to be recreated in the correct zone.
- **`kubectl delete pvc` doesn't remove the cloud disk** —
  `reclaimPolicy: Retain` is working as intended; the PV moves to
  `Released` and the underlying volume must be cleaned up manually (or
  intentionally kept) since Kubernetes won't auto-delete Retain-policy
  volumes.
- **Volume expansion request accepted but the filesystem doesn't grow** —
  most CSI drivers require the consuming pod to restart to trigger the
  filesystem resize even after `allowVolumeExpansion` grows the underlying
  block device; `kubectl rollout restart` the workload after resizing.
- **`ProvisioningFailed` quota errors** — cloud-side quota (EBS volume
  count/size per region, Azure Disk quota per subscription) exhausted, not
  a Kubernetes-side limit; request a quota increase from the provider.
- **StatefulSet pods can't reschedule after a node failure** — zonal block
  storage only reattaches within the same zone; if the StatefulSet's pod
  anti-affinity or the cluster's node pool doesn't guarantee capacity in
  that same zone, the pod stays Pending until capacity returns there.

## Best Practices

- Pick exactly one default `StorageClass` per cluster
  (`storageclass.kubernetes.io/is-default-class: "true"` on only one) —
  multiple defaults produce ambiguous, provider-arbitrary binding for PVCs
  that don't specify `storageClassName`.
- Always set `volumeBindingMode: WaitForFirstConsumer` for zonal block
  storage classes — `Immediate` binding is the most common cause of the
  "volume node affinity conflict" scheduling failure.
- Default to `reclaimPolicy: Delete` for ephemeral/cache-like storage and
  `Retain` for anything holding data of record; don't apply one policy
  blindly cluster-wide.
- Tag/label StorageClasses and PVCs consistently
  (`app.kubernetes.io/name`) so cost allocation and cleanup tooling can
  attribute storage spend correctly.
- Combine with `manifests/velero/` for anything that needs backup/restore
  beyond what the disk's own snapshot capability provides — a PV snapshot
  alone doesn't capture the Kubernetes-object side (PVC/PV bindings,
  StatefulSet identity) of a full restore.
- Right-size `resources.requests.storage` per workload rather than
  copy-pasting one PVC size everywhere — most CSI drivers bill/allocate on
  requested size regardless of actual usage.

## Useful Commands

```bash
# List StorageClasses and see which is default
kubectl get storageclass

# List PVCs and their bound PV/capacity/StorageClass
kubectl get pvc -A -o wide

# Inspect a PV's zone/topology and reclaim policy
kubectl get pv <pv-name> -o yaml | grep -A 5 nodeAffinity
kubectl get pv <pv-name> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'

# Expand a PVC in place (only if allowVolumeExpansion: true)
kubectl patch pvc app-data -n default \
  -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'

# Force a filesystem resize after expanding (restart the consuming pod)
kubectl rollout restart deployment/web-app -n default

# Check CSI driver controller health
kubectl -n kube-system get pods -l app=ebs-csi-controller
```

## References

- [Kubernetes StorageClass documentation](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Persistent Volumes documentation](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [AWS EBS CSI driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [Azure Disk CSI driver](https://github.com/kubernetes-sigs/azuredisk-csi-driver)
- [GCE PD CSI driver](https://github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver)
- [Volume expansion](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims)
- [CSI Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
