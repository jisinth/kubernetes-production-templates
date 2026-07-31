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
