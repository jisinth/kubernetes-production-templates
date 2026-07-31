# Velero

## What is this?

[Velero](https://velero.io/) backs up and restores Kubernetes cluster
resources and persistent volume data. It's the mechanism behind this repo's
disaster-recovery story: scheduled backups of object manifests (Deployments,
ConfigMaps, Secrets, CRDs, etc.) to S3-compatible object storage, plus PV
data snapshots via the cloud provider's snapshot API or CSI. This folder
holds the installation values and the CRs (`Schedule`,
`BackupStorageLocation`) that make backups happen automatically. See
[`../backup/README.md`](../backup/README.md) for the RPO/RTO targets and
retention policy this configuration is meant to satisfy.

## Architecture

```
                 ┌───────────────────────────────┐
                 │        velero (Deployment)     │
                 │  ┌───────────┐  ┌────────────┐ │
   cron ────────▶│  │ Scheduler │─▶│ Backup ctrl│ │
   (Schedule CR)  │  └───────────┘  └─────┬──────┘ │
                 └────────────────────────┼────────┘
                                            │
                     ┌──────────────────────┼───────────────────┐
                     ▼                      ▼                   ▼
             kube-apiserver          node-agent (DaemonSet)   VolumeSnapshotLocation
          (resource manifests)    (fs-backup via kopia/restic)  (cloud snapshot API)
                     │                      │                   │
                     ▼                      ▼                   ▼
              BackupStorageLocation (S3-compatible bucket) ◀────┘
```

- **`velero` Deployment** — runs the backup/restore/schedule controllers.
- **`node-agent` DaemonSet** (`deployNodeAgent: true`) — performs
  filesystem-level backup/restore (kopia or restic) for volumes that don't
  support CSI snapshots.
- **`BackupStorageLocation`** — where Backup *metadata and resource JSON*
  is written (an S3 bucket, or Azure Blob / GCS via their plugins).
- **`VolumeSnapshotLocation`** — where PV *data snapshots* are written
  (usually the cloud provider's native snapshot API, via a Velero plugin).
- **`Schedule`** — a cron-triggered template that spawns `Backup` objects.

## Prerequisites

- An object-storage bucket already created (S3, Azure Blob, or GCS) with a
  restrictive IAM policy scoped to that bucket only.
- The correct object-store plugin for your cloud (this folder ships an AWS
  example: `velero/velero-plugin-for-aws`; swap for
  `velero-plugin-for-microsoft-azure` or `velero-plugin-for-gcp`).
- CSI snapshot support in-cluster if you want crash-consistent PV snapshots
  (`snapshot.storage.k8s.io` CRDs + a `VolumeSnapshotClass` for your
  provisioner).
- Cloud credentials for the plugin — prefer IRSA (EKS) / Workload Identity
  (GKE) / AAD Pod Identity (AKS) over long-lived static keys.

## Installation

```bash
# Add the chart repo
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

# Create the credentials Secret referenced by values.yaml
# (replace with your real, non-committed credentials file)
kubectl create namespace velero
kubectl -n velero create secret generic velero-s3-credentials \
  --from-file=cloud=./credentials-velero

# Install Velero
helm upgrade --install velero vmware-tanzu/velero \
  -n velero -f manifests/velero/values.yaml

# Apply the storage location and schedules
kubectl apply -f manifests/velero/backupstoragelocation.yaml
kubectl apply -f manifests/velero/backup-schedule.yaml
```

### Upgrading

1. **Check the plugin version matrix, not just the Velero server version.** `velero-plugin-for-aws`/`-azure`/`-gcp` and `node-agent`'s kopia/restic version are versioned somewhat independently of the core server; the [compatibility matrix](https://github.com/vmware-tanzu/velero#velero-compatibility-matrix) in the Velero repo maps supported combinations — an untested combination can fail silently on restore rather than on backup, which is the worst time to discover it.
2. **The restic → kopia migration is the single biggest historical Velero upgrade concern.** Velero switched its default fs-backup uploader from restic to kopia; backups taken under the old uploader remain restorable, but new backups after upgrading use the new one. Confirm `uploaderType` in `values.yaml` matches your intent, and don't assume an in-place "just restore" test with an old backup validates the new uploader path — test both directions explicitly across an upgrade.
3. **CRD versions**: `Backup`/`Restore`/`Schedule`/`BackupStorageLocation` API versions have been stable for a long time, but always apply the new chart's CRDs before upgrading the server if CRDs are managed separately in your GitOps setup.
4. Run a full backup-and-restore smoke test (see Verification) immediately after any Velero upgrade, into a scratch namespace — before trusting the upgraded install for the next scheduled production backup window.

### Migrating/restoring to a different cluster (multi-cluster DR & cluster migration)

Velero's cross-cluster restore is the mechanism behind both disaster recovery (rebuilding a lost cluster) and planned cluster migration (moving workloads to a new cluster/region/cloud):

1. **Point the new cluster's Velero install at the *same* `BackupStorageLocation`** (same bucket, same credentials scope) as the source cluster — Velero doesn't care which cluster created a backup; any Velero install with read access to the bucket can restore from it.
2. **StorageClass names must exist on the destination cluster before restoring PVs.** A backup taken on an EKS cluster referencing `gp3` won't automatically work restoring into a GKE cluster — either recreate matching StorageClass names on the destination, or use `Restore.spec.namespaceMapping`/a `ConfigMap`-based [StorageClass mapping](https://velero.io/docs/latest/restore-reference/#changing-pv-provisioners-between-cloud-platforms) so PVCs bind to the destination's equivalent class.
3. **CSI driver differences across clouds are the most common cross-cloud migration failure** — an AWS EBS CSI snapshot cannot be restored as a GCP PD; cross-cloud migration only works cleanly for fs-backup (kopia/restic) volumes, not CSI-snapshot-backed ones, unless you convert the underlying data out-of-band first. Plan cross-cloud DR/migration around fs-backup, and treat CSI snapshots as same-cloud (same-region-or-not) restore only.
4. **Namespace and cluster-scoped resource remapping**: use `--namespace-mappings` for namespace renames during migration, and remember cluster-scoped resources (ClusterRoles, StorageClasses, the `IngressClass` itself) restore as-is — verify they don't collide with anything already present on the destination cluster before restoring.
5. **DNS/traffic cutover is the last step, never automated by Velero** — after confirming the restored workloads are healthy on the new cluster, cut over `external-dns`-managed records (or your load balancer/DNS failover) deliberately; don't restore into a "hot" cluster that's already receiving production traffic without a controlled cutover plan.

## Verification

```bash
# Velero server + node-agent pods Running
kubectl -n velero get pods

# BackupStorageLocation should report Phase: Available
velero backup-location get

# Confirm schedules are registered
velero schedule get

# Trigger an on-demand backup to test end-to-end before trusting the cron
velero backup create smoke-test-backup --include-namespaces default
velero backup describe smoke-test-backup --details
velero backup logs smoke-test-backup
```

## Configuration

- **`values.yaml`** — plugin image, credentials source, default
  `BackupStorageLocation`/`VolumeSnapshotLocation`, node-agent toggle,
  Prometheus ServiceMonitor.
- **`backupstoragelocation.yaml`** — standalone `BackupStorageLocation` CR
  (bucket, region, credential Secret reference). Set `default: true` on
  exactly one location.
- **`backup-schedule.yaml`** — daily (`ttl: 720h`) and weekly (`ttl: 2160h`)
  `Schedule` CRs. Adjust `schedule` (cron), `ttl` (retention), and
  `excludedNamespaces` per environment.
- To restore, create a `Restore` CR (or `velero restore create --from-backup
  <name>`) — restores are deliberately not automated by default; a
  human should confirm target namespace/cluster before restoring.

## Security

- **Bucket IAM should be write-mostly for the backup principal.** Velero's
  service account/IAM role needs `s3:PutObject`, `s3:GetObject`,
  `s3:DeleteObject`, `s3:ListBucket` on the backup bucket only — never
  account-wide S3 access.
- **Enable bucket versioning and object lock (WORM)** on the backup bucket
  if you need ransomware/accidental-deletion protection — Velero's own TTL
  garbage collection still needs delete permission, so object lock should
  use a retention window, not an outright deny.
- **Backups include Secrets in plaintext (base64) by default.** Encrypt the
  bucket at rest (SSE-S3/SSE-KMS) and restrict bucket access; consider
  `--default-volumes-to-fs-backup=false` plus excluding especially sensitive
  Secrets via `--exclude-resources` if they're re-derived from an external
  vault anyway.
- **Never commit `credentials-velero` or static cloud keys.** Use
  IRSA/Workload Identity/AAD Pod Identity so no long-lived key exists at
  all; if you must use a static key, seal it (see
  `manifests/sealed-secrets/`).
- **Restrict who can create `Restore` objects.** A restore can overwrite
  live resources — scope RBAC so only platform/on-call engineers can
  `create` `restores.velero.io`.
- **Test restores regularly.** An untested backup is a hope, not a DR plan
  — see the restore drill cadence in `../backup/README.md`.

## Scaling

- Velero's controller does not need horizontal scaling — backup throughput
  is bound by the object-store and node-agent, not the controller replica
  count (there's normally exactly one).
- **node-agent** (fs-backup) is the most resource-intensive piece for large
  PVs — bump `nodeAgent.resources` if backups of big volumes are slow or
  OOMKilled; it runs as a DaemonSet so scales with node count automatically.
- Prefer CSI snapshots (`features: EnableCSI`, a `VolumeSnapshotClass`) over
  fs-backup wherever the storage driver supports it — snapshots are
  near-instant and don't burden node CPU/network the way a Restic/Kopia
  filesystem copy does.
- Split large clusters into multiple `Schedule`s with different
  `labelSelector`/`namespace` scopes and staggered cron times to avoid one
  enormous backup job saturating node-agent bandwidth all at once.
- Use `--parallel-item-block-workers` on the server if diagnostics show the
  backup itself (not the volume snapshot) is the bottleneck.

### High Availability considerations

- **The Velero server is deliberately single-replica** — like sealed-secrets, this component's reliability story is about the durability of what it produces (backups in object storage), not about the uptime of the controller itself. A Velero server outage pauses new backups/restores but doesn't affect already-completed ones or the running workloads they protect.
- **`node-agent` HA is implicit via DaemonSet placement** — it runs on every node, so a single node's agent going down only affects fs-backup operations for pods currently scheduled on that node, not cluster-wide backup capability.
- **The real availability question is `BackupStorageLocation` durability, not Velero's own uptime** — an S3 bucket (or equivalent) with versioning and cross-region replication enabled is what actually determines whether backups survive a regional outage; Velero itself has no opinion on this, it's a bucket configuration decision made outside this folder.
- **Multi-cluster/multi-region DR readiness is a function of *how often* you've validated cross-cluster restore, not Velero's architecture** — see the restore-drill cadence in [`../backup/README.md`](../backup/README.md); an HA-configured Velero that's never been tested restoring into a *different* cluster provides false confidence about actual disaster recovery capability.

## Common Problems

- **`BackupStorageLocation` stuck `Unavailable`** — almost always
  credentials or network policy. Check
  `kubectl -n velero logs deploy/velero | grep -i "backup storage location"`
  and confirm the Secret referenced in `credential.name` exists and the
  bucket/region match.
- **Backup `PartiallyFailed` with `pod volume backup failed`** — the
  node-agent couldn't reach a pod's volume, often because the pod was
  evicted/rescheduled mid-backup. Re-run with `velero backup describe
  <name> --details` for the specific volume, and consider
  `defaultVolumesToFsBackup: false` if CSI snapshots already cover it.
- **Restore leaves pods `CrashLoopBackOff` referencing missing Secrets** —
  Secrets excluded from backup (`excludedResources`) or created via an
  external operator that wasn't restored/re-run. Restore order matters:
  CRDs and their controllers before the CRs that depend on them.
  `Restore.spec.restorePVs` and `--include-resources` can help sequence
  this.
- **`velero backup create` hangs in `New` phase** — the velero Deployment
  isn't running or can't reach the API server; check
  `kubectl -n velero get pods` and controller logs first.
  before wondering about the storage backend.
- **Schedule fires but produces empty backups** — an overly broad
  `excludedNamespaces` or a `labelSelector` that matches nothing. Run
  `velero backup describe <name>` and check `Resource List` in the output.
- **Snapshot quota errors on the cloud provider (`SnapshotLimitExceeded`)**
  — TTL/retention is too long relative to your snapshot quota; shorten
  `ttl` or request a quota increase from the cloud provider.
- **Cross-cluster restore fails with PVCs stuck `Pending`** — the destination cluster doesn't have a StorageClass matching the name referenced in the backed-up PVC spec (common when migrating between cloud providers). Create a matching StorageClass name on the destination, or use a `ConfigMap`-based StorageClass mapping at restore time (see Migrating above) rather than assuming Velero translates provisioner names automatically.
- **Restore into a new cluster succeeds for stateless resources but PV data is empty** — the backup relied on CSI snapshots, and CSI snapshots don't transfer across cloud providers/regions/accounts the way fs-backup (kopia/restic) data does. Confirm which mechanism protected each volume (`velero backup describe <name> --details` shows this) before assuming any successful backup is portable to any destination.

## Best Practices

- Keep at least one `BackupStorageLocation` in a different account/project
  than the cluster it backs up, so a compromised cluster credential can't
  also delete its own backups.
- Tier retention: frequent short-TTL backups (daily/30d) plus periodic
  long-TTL backups (weekly/90d, monthly/1y) as shown in
  `backup-schedule.yaml`.
- Exclude `kube-system`/`kube-node-lease`/`kube-public` from full-cluster
  backups — they're regenerated by the control plane and just add noise
  and restore-time conflicts.
- Tag/label backups by cluster and environment
  (`metadata.labels`) so a shared bucket across clusters stays queryable.
- Automate periodic restore drills into a scratch namespace/cluster —
  treat "backup succeeded" and "restore verified" as two separate,
  independently monitored SLOs.
- Alert on `BackupStorageLocation` phase != `Available` and on
  `Backup.status.phase` in `{Failed, PartiallyFailed}` via the
  `metrics.serviceMonitor` this folder enables.

## Useful Commands

```bash
# List backups and their phase/expiration
velero backup get

# Inspect a specific backup in detail
velero backup describe <backup-name> --details
velero backup logs <backup-name>

# Trigger an ad-hoc backup outside the schedule
velero backup create manual-$(date +%Y%m%d) --include-namespaces prod

# Restore a namespace from a specific backup
velero restore create --from-backup <backup-name> \
  --include-namespaces prod --restore-volumes=true

# Check restore status
velero restore describe <restore-name>
velero restore logs <restore-name>

# Delete an expired/bad backup (also removes it from object storage)
velero backup delete <backup-name>

# Check storage location health
velero backup-location get
```

## References

- [Velero documentation](https://velero.io/docs/latest/)
- [Velero Helm chart](https://github.com/vmware-tanzu/helm-charts/tree/main/charts/velero)
- [Velero AWS plugin](https://github.com/vmware-tanzu/velero-plugin-for-aws)
- [Velero backup/restore reference](https://velero.io/docs/latest/backup-reference/)
- [Velero CSI snapshot support](https://velero.io/docs/latest/csi/)
- [Disaster recovery best practices](https://velero.io/docs/latest/disaster-case/)
