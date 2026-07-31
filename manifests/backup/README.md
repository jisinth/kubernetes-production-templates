# Backup & Disaster Recovery Strategy

## What is this?

This folder is the **backup strategy documentation hub**, not a manifest
folder — it defines *why* we back things up, *how often*, and *for how
long*, before you look at the actual mechanism. The Kubernetes CRs that
implement this strategy (`Schedule`, `BackupStorageLocation`) live in
[`../velero/`](../velero/README.md); this document is the policy those
manifests are configured to satisfy. If you change the RPO/RTO targets or
retention windows below, update `../velero/backup-schedule.yaml` to match
— the two must stay in sync.

## Architecture

```
   This document (policy: RPO/RTO, cadence, retention)
                    │
                    ▼
   ../velero/backup-schedule.yaml (mechanism: Schedule CRs)
                    │
                    ▼
   ../velero/backupstoragelocation.yaml (mechanism: where backups land)
                    │
                    ▼
   S3-compatible object storage (cross-account/cross-region from the
   cluster it backs up)
```

See [`../velero/README.md`](../velero/README.md) for the full
architecture diagram of the backup mechanism itself (velero controller,
node-agent, storage/snapshot locations).

## Prerequisites

- Velero installed and configured per [`../velero/README.md`](../velero/README.md).
- Agreement from application owners on the RPO/RTO targets below — backup
  cadence is a product decision as much as an infrastructure one; don't
  set it unilaterally without checking it matches what the business
  actually needs.
- A tested restore target (a scratch namespace or cluster) for drills —
  see Verification below.

## Installation

Nothing to install from this folder directly — apply the Velero
`Schedule`/`BackupStorageLocation` manifests as documented in
[`../velero/README.md`](../velero/README.md#installation). This README
exists to record the targets those manifests implement:

| Tier | RPO (max data loss) | RTO (max time to restore) | Cadence | Retention |
|------|---------------------|----------------------------|---------|-----------|
| Critical (stateful prod DBs, payment/order data) | 24h | 4h | Daily @ 02:00 UTC | 30 days |
| Standard (stateless services, config, most app namespaces) | 24h | 8h | Daily @ 02:00 UTC | 30 days |
| Long-term / compliance | 7d | best-effort | Weekly @ Sunday 03:00 UTC | 90 days |

These map directly to `daily-full-backup` (30-day TTL) and
`weekly-full-backup` (90-day TTL) in
[`../velero/backup-schedule.yaml`](../velero/backup-schedule.yaml).

## Verification

Backup *success* and restore *capability* are two separate things to
verify — a green "Backup completed" status tells you nothing about whether
the backup can actually be restored.

```bash
# Confirm the schedule actually produced a backup on cadence
velero backup get

# Quarterly restore drill: restore into an isolated namespace/cluster and
# smoke-test the application starts and serves traffic
velero restore create dr-drill-$(date +%Y%m%d) \
  --from-backup <latest-daily-backup> \
  --namespace-mappings prod:dr-drill \
  --include-namespaces prod

kubectl -n dr-drill get pods
kubectl -n dr-drill logs deploy/<app> --tail=50
```

Track drill results (pass/fail, time-to-restore observed vs. RTO target)
somewhere durable (a runbook, an incident-review doc) — this document
should be updated if drills consistently show the RTO target is
unrealistic.

### Full cluster-loss disaster recovery runbook

The scenario the RPO/RTO table above ultimately exists for: the cluster itself is gone (region outage, botched infrastructure change, account compromise) and you're rebuilding from scratch, not just restoring one namespace.

1. **Provision the replacement cluster** per the relevant `examples/<CLOUD>/README.md` — same region if the outage was cluster-specific, a different region if it was regional. This step's duration is usually the single largest component of actual RTO; a pre-provisioned warm-standby cluster (see Multi-region below) exists specifically to remove this step from the critical path.
2. **Install the base platform stack** (`scripts/install.sh` phases 1-2: namespaces, ingress-nginx, cert-manager, external-dns, metrics-server) — Velero needs a functioning cluster before it can restore anything into it.
3. **Install Velero pointed at the existing `BackupStorageLocation`** — same bucket/credentials the lost cluster used; see [`../velero/README.md#migratingrestoring-to-a-different-cluster-multi-cluster-dr--cluster-migration`](../velero/README.md) for the cross-cluster restore mechanics.
4. **Restore CRDs and their controllers before the CRs that depend on them** — restoring an `Application` CR (Argo CD) before Argo CD itself is installed, or a `Certificate` before cert-manager, leaves orphaned objects with no controller to reconcile them. Restore in dependency order: platform CRDs (cert-manager, Argo CD, Kyverno, Prometheus Operator) first, then application namespaces.
5. **Restore application namespaces from the most recent daily backup**, verify each against its own health checks (not just "pods Running" — actual `/healthz`/readiness against real traffic patterns) before moving to DNS cutover.
6. **Cut over DNS/traffic last, deliberately** — once `manifests/external-dns/` is running and workloads are verified healthy, let external-dns reconcile records to the new cluster's ingress, or manually update DNS/global load balancer if the new cluster is in a different region than before.
7. **Re-establish GitOps** (`manifests/argocd/`) pointed at the same Git repository once the cluster is stable — this is what prevents the rebuilt cluster from silently drifting from what Git declares going forward.

Time every step during drills, not just the restore command itself — cluster provisioning and platform-stack installation are usually a larger share of real RTO than the Velero restore operation people tend to focus on.

### Multi-region / multi-cluster DR strategy

Three common postures, in increasing order of RTO improvement and cost:

1. **Backup-only (this repo's default)**: one production cluster, backups replicated to a different region's bucket. RTO includes full cluster provisioning time (see runbook above) — cheapest, slowest to recover, appropriate for workloads whose RTO tolerance is measured in hours.
2. **Pilot light**: a minimal standby cluster already running in the DR region (base platform stack installed, no application workloads), kept in sync via the same GitOps repo pointed at a second `Application`/`ApplicationSet` target (see [`docs/gitops.md`](../../docs/gitops.md#applicationsets-for-multi-environmentmulti-cluster-fan-out)). On failover, restore application data via Velero into the already-running platform — this removes cluster provisioning and platform-stack installation from the critical path, cutting RTO substantially.
3. **Warm/active-active standby**: a fully running DR cluster continuously receiving a subset of production traffic (or ready to receive 100% instantly), with data replication handled at the application/database layer (not Velero, which is a point-in-time backup tool, not a continuous-replication one) — Velero still matters here for corruption/deletion recovery (a bad deploy or accidental `kubectl delete` replicates instantly to an active-active standby, but a Velero backup from before the incident doesn't), just not for infrastructure-loss RTO.

Match the posture to the RPO/RTO tier table above — don't build warm-standby infrastructure for workloads whose actual business RTO tolerance is measured in hours, and don't rely on backup-only for a tier whose RTO target is measured in minutes.

## Configuration

The knobs that implement this policy live in `../velero/`:

- **Cadence** → `spec.schedule` (cron) in
  [`../velero/backup-schedule.yaml`](../velero/backup-schedule.yaml).
- **Retention** → `spec.template.ttl` in the same file.
- **Scope** (which namespaces) → `includedNamespaces`/`excludedNamespaces`
  in the same file.
- **Storage target** → `../velero/backupstoragelocation.yaml`.

If a workload needs a different RPO/RTO than the tiers above (e.g., an
analytics namespace that's fine with weekly-only, or a payments namespace
needing hourly snapshots), give it its own `Schedule` with a
`labelSelector` scoping it to that namespace, rather than changing the
shared default schedule.

## Security

- Backups are a second copy of every Secret in the cluster — see
  [`../velero/README.md#security`](../velero/README.md#security) for
  bucket IAM scoping, encryption-at-rest, and object-lock/WORM
  recommendations.
- Store backups in a different account/project than the cluster they
  protect — a single compromised cluster credential should not also be
  able to delete its own backups (this is a DR-strategy requirement, not
  just a Velero config detail).
- Restrict who can trigger a `Restore` — a restore can overwrite live
  production data; scope this via RBAC the same way you'd scope
  `kubectl delete` on production namespaces.

## Scaling

- As cluster/namespace count grows, split the single daily schedule into
  per-tier schedules (see the RPO/RTO table) so critical workloads aren't
  waiting behind a monolithic full-cluster backup job.
- Revisit retention costs periodically — 30/90-day windows across many
  large PVs add up in object-storage spend; tier older backups to
  cheaper storage classes (S3 Glacier, Azure Archive, GCS Coldline) if
  your restore SLA for month-old backups is relaxed.

## Common Problems

- **"We have backups" turns out to mean "we've never tested a restore"**
  — the single most common DR failure mode. Schedule quarterly restore
  drills (see Verification) and treat a skipped drill as a policy
  violation, not an optional nice-to-have.
- **RPO/RTO targets exist only in someone's head, not in this document**
  — codify them here (or in `docs/production-checklist.md`) so an
  incident isn't the first time anyone asks "how much data can we afford
  to lose?"
- **Retention window doesn't match compliance requirements** — some
  regulatory regimes require longer retention than 30/90 days; check with
  compliance/legal before treating the defaults above as sufficient for a
  regulated workload.
- See [`../velero/README.md#common-problems`](../velero/README.md#common-problems)
  for mechanism-level failures (stuck backups, storage-location errors,
  restore ordering issues).

## Best Practices

- Treat this document as the source of truth for *why* the Velero
  schedules are configured the way they are — when a schedule looks wrong,
  check here first for the intended policy before assuming it's a bug.
- Review RPO/RTO targets at least annually, or whenever a new
  workload with materially different availability requirements is
  onboarded.
- Keep this table and `../velero/backup-schedule.yaml` in sync — a stale
  doc that no longer matches the actual cron schedule is worse than no
  doc.
- Run restore drills against the same object-storage bucket and IAM
  permissions production restores would use — a drill that uses
  elevated/break-glass credentials doesn't validate the real on-call
  restore path.

## Useful Commands

```bash
# See mechanism-level commands in ../velero/README.md#useful-commands
# Quick links most relevant to strategy verification:

# List all backups with their age and expiration (drives retention review)
velero backup get

# Kick off a manual restore drill
velero restore create dr-drill-$(date +%Y%m%d) --from-backup <name> \
  --namespace-mappings prod:dr-drill

# Check how close to the RTO target the last drill actually took
velero restore describe dr-drill-<date> --details | grep -i "started\|completed"
```

## References

- [Velero manifests and mechanism](../velero/README.md)
- [Velero disaster recovery guide](https://velero.io/docs/latest/disaster-case/)
- [Google SRE Book: Disaster Recovery](https://sre.google/sre-book/disaster-recovery/)
- [AWS Well-Architected: Reliability Pillar (backup/DR)](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html)
