# Argo CD

## What is this?

[Argo CD](https://argo-cd.readthedocs.io/) is a declarative, GitOps continuous
delivery tool for Kubernetes. Instead of `kubectl apply`-ing manifests from a
CI pipeline, you point Argo CD at a Git repository and it continuously
reconciles the live cluster state to match what's committed. This folder
contains the Argo CD installation values plus the CRs that bootstrap a
"app of apps" pattern for this entire repository.

Why GitOps instead of push-based CI/CD:

- **Git is the single source of truth.** `kubectl diff` against a live
  cluster becomes unnecessary — `git diff` tells you exactly what changed.
- **Drift correction.** If someone `kubectl edit`s a Deployment by hand,
  `selfHeal: true` reverts it on the next reconciliation loop.
- **Audit trail for free.** Every change is a Git commit with an author,
  timestamp, and (ideally) a PR review — no separate deploy log to maintain.
- **No cluster-admin credentials in CI.** The pipeline only needs to push to
  Git; Argo CD (running in-cluster) does the actual applying with its own
  tightly scoped ServiceAccount.

## Architecture

```
 ┌─────────────┐   git push   ┌──────────────┐
 │  Developer   │ ───────────▶│  Git repo     │
 └─────────────┘              │ (this repo)   │
                               └───────┬──────┘
                                       │ poll / webhook
                                       ▼
                       ┌─────────────────────────────┐
                       │        Argo CD (argocd ns)   │
                       │ ┌────────────┐ ┌───────────┐ │
                       │ │repo-server │ │controller │ │
                       │ └────────────┘ └─────┬─────┘ │
                       │ ┌────────────┐       │       │
                       │ │  server    │◀──UI/CLI      │
                       │ └────────────┘       │       │
                       └───────────────────────┼───────┘
                                                ▼
                                 kube-apiserver (diff + apply)
                                                │
                     ┌──────────────────────────┼───────────────────┐
                     ▼                          ▼                   ▼
              manifests/argocd/*        manifests/velero/*   manifests/kyverno/*  ...
```

The root `Application` (`application.yaml`) watches `manifests/` recursively
(the app-of-apps pattern) — every subfolder under `manifests/` is a set of
plain Kubernetes YAML that Argo CD renders and applies as one Application.
As the repo grows, split this into one `Application` per subfolder (or an
`ApplicationSet` with a Git-directory generator) so each tool syncs and
reports health independently instead of as one monolithic blob.

Core components:

- **`argocd-server`** — API server + UI, also the gRPC/gRPC-Web endpoint the
  CLI talks to.
- **`argocd-repo-server`** — clones Git repos, renders Helm/Kustomize/plain
  YAML into a manifest list, and hands it to the controller.
- **`argocd-application-controller`** — the reconciliation loop; diffs
  desired (Git) vs. live (cluster) state and applies/prunes as needed. This
  is a StatefulSet — scale it via sharding, not replica count alone.
- **`argocd-applicationset-controller`** — generates `Application` objects
  from templates (Git directories, clusters, pull requests, etc.).
- **`redis`** — cache for repo-server and the controller; `redis-ha` in HA
  mode.
- **`dex`** (optional) — OIDC/SSO bridge for SAML, GitHub, Okta, etc.

## Prerequisites

- A running cluster with `kubectl` access and cluster-admin (for the initial
  install).
- Helm 3.x, or `kubectl apply -k` if using the upstream install manifests.
- A Git repository Argo CD can reach (public repos need nothing extra;
  private repos need `repo-secret.yaml` or `argocd repo add`).
- DNS/ingress already available if you want `server.ingress.enabled: true`
  (see `manifests/ingress-nginx/` and `manifests/cert-manager/`).

## Installation

```bash
# Add the repo and create the namespace
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install (or upgrade) with the values in this folder
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f manifests/argocd/values.yaml

# Wait for the server to come up
kubectl -n argocd rollout status deploy/argocd-server

# Apply the AppProject before the root Application (Application references it)
kubectl apply -f manifests/argocd/project.yaml
kubectl apply -f manifests/argocd/rbac.yaml

# (Private repos only) create the repo credential — prefer sealing this
# first, see the comment at the top of repo-secret.yaml
kubectl apply -f manifests/argocd/repo-secret.yaml

# Bootstrap the app-of-apps root Application
kubectl apply -f manifests/argocd/application.yaml
```

Retrieve the initial admin password (bootstrap only — rotate/delete it
immediately after logging in once, see Security below):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Verification

```bash
# All argocd-* pods Running/Ready
kubectl -n argocd get pods

# Root Application synced and healthy
argocd app get kubernetes-production-templates
kubectl -n argocd get application kubernetes-production-templates -o wide

# Confirm the controller actually applied child resources
kubectl -n argocd get application kubernetes-production-templates \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
# Expect: Synced Healthy

# Log in via CLI (port-forward if no ingress yet)
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --insecure
```

## Configuration

- **`values.yaml`** — Helm values: replica counts, resource requests/limits,
  ingress, RBAC policy, HA toggle (off by default, see the comment block at
  the top for how to enable it).
- **`application.yaml`** — the root `Application` CR. Edit `spec.source`
  (repoURL/targetRevision/path) if you fork this repo, and tune
  `syncPolicy`/`ignoreDifferences` per your drift-tolerance needs.
- **`project.yaml`** — `AppProject` scoping which repos/destinations/
  cluster-resource kinds Applications in this project may touch. Add new
  `sourceRepos` entries here before pointing an Application at another repo,
  or the sync will fail with a "repository is not permitted" error.
- **`repo-secret.yaml`** — template for private Git repo credentials.
- **`rbac.yaml`** — who can do what in the Argo CD UI/CLI/API, independent
  of Kubernetes RBAC.

## Security

- **Never expose `argocd-server` with `server.insecure: true` and no TLS in
  front of it.** This repo's `values.yaml` sets `--insecure` because TLS is
  terminated at the ingress (`cert-manager` + `nginx`) — if you don't have
  that, remove `--insecure` and let argocd-server terminate TLS itself.
- **Rotate the bootstrap admin password immediately**:
  `argocd account update-password`, then delete the
  `argocd-initial-admin-secret` Secret, or better, disable the local `admin`
  account entirely once SSO (Dex) is wired up
  (`configs.cm."admin.enabled": "false"`).
- **Scope RBAC tightly** (`rbac.yaml`) — default to `role:readonly` and grant
  `role:admin` only to a small platform-team group. Avoid `p, *, *, *, *,
  allow` outside of `role:admin`.
- **Never commit real repo credentials.** `repo-secret.yaml` is a template
  with obvious placeholders; seal it with `manifests/sealed-secrets/` or
  fetch credentials from Vault/External Secrets before applying.
- **Restrict `AppProject.clusterResourceWhitelist`.** A wide-open project
  lets a compromised or careless PR against the tracked repo create
  ClusterRoleBindings, webhooks, or new namespaces cluster-wide.
- **Disable `exec` unless you need it.** `p, role:developer, exec, create,
  applications/*, deny` in `rbac.yaml` blocks `argocd app exec`
  (an in-cluster shell) for non-admins.
- Enable audit logging (`server.extraArgs: ["--metrics"]` + scrape with
  Prometheus) so sync/login/RBAC-denial events are retained.

## Scaling

- **repo-server** is the most CPU/memory-intensive component under load
  (cloning + manifest rendering) — scale it horizontally first via
  `repoServer.replicas` or `repoServer.autoscaling.enabled: true`.
- **argocd-server** is stateless; scale replicas behind the Service/ingress
  for UI/API throughput.
- **application-controller** cannot be scaled by replica count alone past a
  point — it's a StatefulSet. Beyond a few hundred Applications, enable
  sharding: `controller.replicas: 3` with
  `ARGOCD_CONTROLLER_SHARDING_ALGORITHM=round-robin` so each shard owns a
  subset of clusters/Applications.
- **redis** becomes a bottleneck under heavy UI/API polling — switch to
  `redis-ha.enabled: true` (3 Sentinel-managed replicas) once you exceed a
  single-node redis's throughput, which is also required for `server`/
  `controller` HA (they share cache state through it).
- Increase `controller.env` `ARGOCD_APPLICATION_CONTROLLER_REPLICAS` and the
  `--status-processors`/`--operation-processors` flags to raise reconcile
  parallelism before adding shards.

## Common Problems

- **`ComparisonError: repository not permitted in project` on sync** — the
  Application's `spec.source.repoURL` isn't listed in the `AppProject`'s
  `sourceRepos`. Fix: add it to `project.yaml` and re-apply.
- **Sync stuck `Progressing` forever on a Deployment** — usually a pod stuck
  `Pending`/`CrashLoopBackOff` downstream (bad image, resource requests
  exceeding node capacity). `kubectl -n <ns> describe pod <pod>` and
  `argocd app get <app> --hard-refresh` to see the real resource health
  rather than assuming Argo CD itself is stuck.
- **`selfHeal` fights a HPA or another controller mutating `spec.replicas`**
  — Argo CD keeps reverting the field the HPA just changed, causing a sync
  loop. Fix: add the field to `ignoreDifferences` (already done for
  `Deployment.spec.replicas` in `application.yaml`).
- **`x509: certificate signed by unknown authority` cloning a private Git
  repo over HTTPS with a self-hosted GitLab/Gitea** — add the CA cert via
  `configs.tls.certificates` in `values.yaml`, or use
  `argocd cert add-tls --from ca.crt`.
- **Webhook not triggering an immediate sync** — Argo CD falls back to
  polling every 3 minutes by default. Configure a Git webhook
  (`/api/webhook`) pointed at `argocd-server` for near-instant syncs instead
  of waiting on the poll interval.
- **`too many open files` / repo-server OOMKilled on large repos** — bump
  `repoServer.resources.limits.memory` and enable
  `reposerver.parallelism.limit` to cap concurrent manifest generation.
- **Manifests under `manifests/argocd/` get rendered as Applications and
  cause a "self-managing" loop** — make sure `directory.exclude` in
  `application.yaml` covers README/values files, or split Argo CD's own
  manifests into a project Argo CD doesn't manage itself (bootstrap it
  imperatively once, then let GitOps take over everything else).

## Best Practices

- One Git repo (or clearly scoped monorepo folder, as here) per
  `AppProject` — don't let unrelated teams' Applications share a project's
  blast radius.
- Keep `prune: true` and `selfHeal: true` on for infra you fully own; use
  `manual` sync for anything with a human approval gate (e.g., a
  break-glass production namespace).
- Use `ignoreDifferences` deliberately and sparingly — every entry is a
  blind spot Argo CD won't alert you to.
- Store the AppProject and RBAC ConfigMap in Git too (as done here) so
  access control itself is reviewed via PR, not click-ops in the UI.
- Prefer ApplicationSets over hand-maintained lists of Applications once you
  have more than a handful of similar apps/clusters.
- Set `resource.exclusions` for high-churn resources you don't need Argo CD
  to track (e.g., `Endpoints`, `EndpointSlice`) to cut controller load.

## Useful Commands

```bash
# List all Applications and their sync/health status
argocd app list

# Show a detailed diff between Git and the live cluster
argocd app diff kubernetes-production-templates

# Force a sync (equivalent to selfHeal firing manually)
argocd app sync kubernetes-production-templates

# Sync a single resource within an Application
argocd app sync kubernetes-production-templates \
  --resource apps:Deployment:argocd/argocd-server

# Roll back to a previous sync revision
argocd app history kubernetes-production-templates
argocd app rollback kubernetes-production-templates <HISTORY_ID>

# Watch controller logs for reconciliation errors
kubectl -n argocd logs deploy/argocd-application-controller -f

# Dump the effective RBAC policy currently loaded
kubectl -n argocd get cm argocd-rbac-cm -o yaml

# Refresh (re-clone + re-diff) without waiting for the poll interval
argocd app get kubernetes-production-templates --hard-refresh
```

## References

- [Argo CD documentation](https://argo-cd.readthedocs.io/)
- [Argo CD Helm chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Argo CD RBAC](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [Argo CD high availability](https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/)
- [ApplicationSet controller](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
- [Best practices for repository structure](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
