# Contributing to kubernetes-production-templates

Thanks for helping build out this reference repo. It only stays useful if every folder is consistent, correct, and safe to apply to a real cluster. Please read this before opening a PR.

## Coding standards

### YAML

- **2-space indentation.** No tabs, no 4-space blocks.
- **No hardcoded secrets, tokens, passwords, or account IDs.** Use placeholders (`<AWS_ACCOUNT_ID>`, `<CLUSTER_NAME>`, `<DOMAIN>`) or reference a `Secret`/`SealedSecret`/external secret store. Never commit real credentials, even "example" ones that look plausible — use obviously fake values (`example.com`, `000000000000`).
- Prefer `kubectl apply -k` / Kustomize overlays or Helm `values.yaml` overrides over duplicating whole manifests per environment.
- Every `Deployment`/`StatefulSet` must set resource `requests` and `limits`, a `livenessProbe`/`readinessProbe`, and a non-root `securityContext` unless there's a documented reason not to.
- Pin image tags (no `:latest`) and Helm chart versions.
- Run manifests through `yamllint` (config at repo root, if present) before committing.

### Scripts

- Bash scripts use `set -euo pipefail` and `#!/usr/bin/env bash`.
- Prefer explicit flags over positional magic; validate required arguments and fail with a clear message.

## Required folder documentation layout

Every folder under `manifests/`, `helm-values/`, and `applications/` must contain a `README.md` with these sections, in this order:

1. **What is this?** — one paragraph, plain language.
2. **Architecture** — how it fits into the cluster (diagram or bullet list).
3. **Prerequisites** — CRDs, controllers, or other manifests that must exist first.
4. **Installation** — exact `kubectl apply` / `helm upgrade --install` commands.
5. **Verification** — how to confirm it's working (`kubectl get`, `kubectl logs`, test requests).
6. **Configuration** — key values/env vars/CRD fields you're expected to change per environment.
7. **Security** — RBAC, NetworkPolicy, secrets handling relevant to this component.
8. **Scaling** — how this component behaves/should be tuned under load.
9. **Common Problems** — known failure modes and fixes.
10. **Best Practices** — do's and don'ts specific to this component.
11. **Useful Commands** — a cheat sheet of `kubectl`/`helm`/CLI commands for day-2 operations.
12. **References** — links to upstream docs.

## Adding a new manifest folder

1. Create the folder under `manifests/<name>/` (or `applications/<name>/` for a sample app).
2. Add manifests using placeholders for anything environment-specific.
3. Add a `README.md` following the layout above.
4. If the component ships a Helm chart, add a matching `helm-values/<name>/values.yaml` with inline comments explaining non-default overrides.
5. Wire it into `scripts/install.sh` (and `uninstall.sh`, in reverse order) if it's part of the standard install flow.
6. Add or update the relevant `docs/*.md` page to reference the new folder by relative path.

## Adding a new sample application

1. Create `applications/<name>/` with `Deployment`, `Service`, `Ingress` (or `HTTPRoute`), and any `ConfigMap`/`Secret` templates it needs.
2. Follow the same resource limits, probes, and non-root `securityContext` conventions as the rest of the repo.
3. Add a `README.md` following the required layout above, including how the app integrates with ingress-nginx, cert-manager, and the monitoring stack.
4. Add a NetworkPolicy scoped to the app's actual traffic needs.

## PR checklist

Before opening a PR, confirm locally (see `scripts/validate.sh`):

- [ ] `helm lint` passes on any chart-like directory you touched
- [ ] `kubeconform -strict -ignore-missing-schemas` passes on all changed YAML
- [ ] `trivy config` reports no new HIGH/CRITICAL findings
- [ ] `checkov` reports no new failed checks (or failures are explicitly justified in the PR description)
- [ ] Every new/changed folder has a README following the required layout
- [ ] No secrets, tokens, or real account identifiers were committed

## CI

Every PR runs automated checks (see `.github/workflows/`):

- `lint.yml` — yamllint + `helm lint`
- `validate.yml` — kubeconform schema validation
- `security.yml` — Trivy config scan + Checkov, results uploaded as SARIF

A PR that fails any of these will not be merged. If a finding is a deliberate, documented exception (e.g. a policy that's intentionally permissive for a Minikube example), say so explicitly in the PR description.
