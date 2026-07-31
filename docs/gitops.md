# GitOps

## Why ArgoCD

Once the base stack (ingress, observability) is stable, this repo switches from imperative `kubectl apply -f` to ArgoCD-driven reconciliation. `manifests/argocd/` installs ArgoCD itself; from that point on, cluster state is declared by `Application` resources pointing back at this repo (or your fork), and ArgoCD continuously syncs the two.

## Application-of-applications pattern

Rather than one `Application` per component, define a single root `Application` that points at a directory of `Application` manifests — one per `manifests/<component>/` folder you want ArgoCD to manage. ArgoCD then creates and syncs every child `Application` automatically. This keeps onboarding a new component to two steps:

1. Add the manifests under `manifests/<component>/` (and `helm-values/<component>/` if it's a Helm chart).
2. Add an `Application` manifest pointing at that path under the root app's directory.

## Helm vs. plain manifests

ArgoCD supports both natively:

- Plain YAML directories (most of `manifests/`) sync as-is.
- Helm charts reference `helm-values/<component>/values.yaml` as the `Application`'s `helm.valueFiles`.

Keep environment-specific overrides in `helm-values/` rather than forking manifests — one `Application` per environment can point at the same chart with a different values file.

## Sync policy

Recommended defaults for this repo:

- `syncPolicy.automated.prune: true` — remove resources deleted from Git
- `syncPolicy.automated.selfHeal: true` — revert manual `kubectl edit` drift
- `syncOptions: [CreateNamespace=true]` for new component namespaces

Turn off `selfHeal` temporarily during incident response if you need to hotfix in-cluster before the Git fix lands — remember to turn it back on.

## Promotion across environments

Use separate ArgoCD `Application`s (or a separate ArgoCD instance) per environment (dev/staging/prod), each pointing at the same manifests but a different Git branch, tag, or `helm-values/` overlay. Promote by merging/tagging in Git, not by editing the cluster.

Three common promotion strategies, in increasing order of rigor:

1. **Branch-per-environment** (`main` → staging, `production` branch → prod): promote by merging `main` into `production`. Simplest to reason about, but a long-lived `production` branch can drift from `main` if merges aren't disciplined — treat it as a fast-forward-only merge target, never commit directly to it.
2. **Tag-based promotion**: each environment's `Application.spec.source.targetRevision` pins a Git tag (`v1.4.2`) rather than a branch. Promote by moving the tag reference in the environment's `Application` manifest (a one-line PR), which gives you an explicit, auditable "what's actually running in prod right now" answer without needing branch archaeology.
3. **Overlay-based (Kustomize) promotion**: one set of base manifests plus per-environment `kustomization.yaml` overlays (`overlays/staging/`, `overlays/production/`) that patch image tags, replica counts, and resource limits. Promotion becomes "the same base manifests, different overlay," which is the strongest guarantee that staging and production aren't secretly different applications wearing the same name.

Whichever strategy you pick, the invariant that matters is: **the promotion action itself is a Git operation** (merge, tag move, PR-and-approve) — if promoting to production ever requires a person to run a `kubectl`/`helm` command by hand, the GitOps guarantee (Git as sole source of truth) is already broken for that environment.

### ApplicationSets for multi-environment/multi-cluster fan-out

Rather than hand-writing one `Application` per environment or cluster, an `ApplicationSet` generates them from a template:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-stack
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: staging
            cluster: https://staging-cluster.example.com
            valuesFile: helm-values/staging.yaml
          - env: production
            cluster: https://prod-cluster.example.com
            valuesFile: helm-values/production.yaml
  template:
    metadata:
      name: 'platform-stack-{{env}}'
    spec:
      source:
        repoURL: https://github.com/jisinth/kubernetes-production-templates.git
        targetRevision: main
        path: manifests/
        helm:
          valueFiles: ['{{valuesFile}}']
      destination:
        server: '{{cluster}}'
        namespace: platform
      syncPolicy:
        automated: {prune: true, selfHeal: true}
```

The `list` generator above is the simplest case; the `git` generator (scan a directory of environment folders) and `cluster` generator (fan out to every cluster Argo CD has registered) scale better once you have more than a handful of environments — see [`manifests/argocd/README.md`](../manifests/argocd/README.md#references) for the ApplicationSet controller docs.

### Progressive delivery (canary/blue-green) alongside GitOps

Plain `Application` sync is all-or-nothing at the Deployment level — for gradual rollout with automated metric-based rollback, pair Argo CD with [Argo Rollouts](https://argo-rollouts.readthedocs.io/): swap a Deployment for a `Rollout` CR, add an `AnalysisTemplate` querying Prometheus (see `manifests/prometheus/`) for error-rate/latency SLOs, and Argo CD syncs the `Rollout` object exactly like any other resource — the progressive-delivery logic runs inside the cluster via the Rollouts controller, not inside Argo CD itself.

### Rollback runbook

Because Git holds the full history, rollback is a promotion in reverse — but do it deliberately, not by panic-reverting:

1. Identify the last-known-good state: `argocd app history <app>` (deploy-level) or `git log -- manifests/<component>/` (change-level) to find the exact commit/sync ID.
2. Prefer `git revert` (a new commit undoing the change) over `git reset`/force-push — this preserves the audit trail of *what broke* rather than erasing it, which matters for the postmortem.
3. If the fix truly can't wait for a PR+merge cycle, `argocd app rollback <app> <HISTORY_ID>` reverts the *live* cluster to a prior sync immediately — but this creates exactly the kind of Git/cluster divergence GitOps exists to prevent, so follow up with the actual Git revert within the same incident, and expect `selfHeal` to fight your manual rollback until Git and cluster agree again (temporarily disable `selfHeal` on that Application if it's re-applying the bad state faster than you can revert Git).

## Verification

```bash
kubectl -n argocd get applications
argocd app get <app-name>
argocd app diff <app-name>
```

An `Application` in `OutOfSync` means the cluster has drifted from Git — investigate before syncing to avoid clobbering an intentional emergency change.

## Common problems

- `Application` stuck `Progressing` — check the underlying resource's events (`kubectl describe`); ArgoCD is usually waiting on a readiness condition, not stuck itself.
- Helm values not applying — confirm the `Application`'s `valueFiles` path matches `helm-values/<component>/values.yaml` exactly (relative to the Helm chart's directory context, which trips people up).
- Sync loops (constant `OutOfSync` → `Synced` → `OutOfSync`) — usually a mutating admission webhook (Kyverno) rewriting fields ArgoCD then sees as drift; add the field to `ignoreDifferences` on the `Application`.
