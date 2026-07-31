# Production checklist

Work through this before calling a cluster built from this repo "production-ready." Each section links to the relevant manifests.

## Cluster readiness

- [ ] Cluster is on a supported, non-EOL Kubernetes version for the target provider
- [ ] Node pools have at least 3 nodes across 2+ availability zones
- [ ] `manifests/namespace/` applied with consistent labeling (`environment`, `team`, `pod-security.kubernetes.io/enforce`)
- [ ] `manifests/metrics-server/` installed and `kubectl top nodes` returns data
- [ ] Cluster autoscaler (or equivalent, e.g. Karpenter on EKS) is configured
- [ ] `manifests/ingress-nginx/` controller has 2+ replicas with a `PodDisruptionBudget`
- [ ] `manifests/cert-manager/` `ClusterIssuer` points at the **production** ACME endpoint, not staging
- [ ] `manifests/external-dns/` credentials are scoped to only the intended DNS zone

## Security

- [ ] `manifests/network-policy/` default-deny applied to every namespace, with verified allow rules (see [`docs/networking.md`](networking.md))
- [ ] `manifests/pod-security/` `restricted` PSS enforced on all application namespaces
- [ ] `manifests/kyverno/policies/` running in `enforce` mode (not `audit`) for at least the baseline policy set
- [ ] `manifests/sealed-secrets/` (or a cloud secret manager) in use — no plaintext `Secret` YAML committed anywhere
- [ ] No `ServiceAccount` outside break-glass tooling is bound to `cluster-admin`
- [ ] `security.yml` CI workflow is green with no unexplained Trivy/Checkov findings
- [ ] Container images are pinned by tag (or digest) and scanned before deploy

## Observability

- [ ] `manifests/prometheus/` scraping all application and infra targets (`Targets` page all `UP`)
- [ ] `manifests/grafana/` dashboards provisioned as code (`manifests/grafana/dashboards/`), not click-ops
- [ ] `manifests/loki/` receiving logs from every namespace via the log-shipping `DaemonSet`
- [ ] `manifests/tempo/` receiving traces from at least the critical-path services
- [ ] `manifests/alertmanager/` routes configured for at least `critical` (pages) and `warning` (chat) severities
- [ ] Alert rules exist for: node not ready, pod crash-looping, PVC nearly full, certificate expiring soon, HPA maxed out
- [ ] On-call has actually received a test page end-to-end

## Backup & disaster recovery

- [ ] `manifests/velero/` installed with object storage credentials scoped to a dedicated bucket
- [ ] A scheduled backup exists (not just ad hoc `scripts/backup.sh` runs) covering all stateful namespaces
- [ ] CSI volume snapshots are enabled so PVC data is actually captured, not just Kubernetes objects
- [ ] A restore has been **tested** into a separate namespace/cluster within the last quarter
- [ ] Backup retention matches your actual RPO requirement
- [ ] Runbook exists for full cluster loss (rebuild via `scripts/install.sh` + `scripts/restore.sh`)

## Scaling

- [ ] `manifests/autoscaling/` HPA configured for every user-facing `Deployment`, with sane min/max replicas
- [ ] Resource `requests`/`limits` are based on real load-test or production usage data, not guesses
- [ ] `manifests/storage/` StorageClasses set `volumeBindingMode: WaitForFirstConsumer` where relevant
- [ ] Load tested at expected peak + headroom, with autoscaling and node scaling both verified to react in time

## Sign-off

- [ ] `scripts/validate.sh` run clean against the final manifest set
- [ ] `docs/architecture.md` and `architecture/README.md` diagrams reflect the actual deployed topology
- [ ] Someone other than the author has reviewed this checklist
