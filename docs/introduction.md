# Introduction

`kubernetes-production-templates` is a reference implementation of a production Kubernetes cluster, built as a set of composable manifests, Helm values, and scripts rather than a single monolithic install. The goal is that you can clone this repo, point it at an empty AKS/EKS/GKE/Minikube cluster, and end up with something you'd actually trust to run a workload — not a "hello world" demo.

## Philosophy

- **Order matters.** Ingress before workloads, cert-manager before ingress TLS, monitoring before you need to debug an incident, security policy before you go multi-tenant. The [workflow phases](../README.md#workflow-phases) encode this order.
- **Nothing is hardcoded.** Domains, account IDs, and secrets are placeholders. You're expected to fork or copy this repo and substitute your own values, ideally through `helm-values/` overrides or Kustomize overlays rather than editing manifests in place.
- **Every folder stands alone.** Each directory under `manifests/` has its own README following the layout in [CONTRIBUTING.md](../CONTRIBUTING.md) — prerequisites, install, verify, configure, secure, scale, troubleshoot. You should be able to read one folder's README without needing the whole repo's context.
- **CI enforces the bar.** `yamllint`, `kubeconform`, `trivy`, and `checkov` all run on every PR (see `.github/workflows/`). If it's in `main`, it has passed schema validation and a security scan.

## How to use this repo

1. Pick your target: AKS, EKS, GKE, or Minikube. Read the matching guide under [`examples/`](../examples/) for cluster creation and provider-specific notes (load balancer annotations, IRSA, Workload Identity, etc.).
2. Run `./scripts/install.sh` to install the stack phase by phase, or run each phase manually by applying the manifests under `manifests/<component>/` and the matching `helm-values/<component>/values.yaml`.
3. Deploy a sample app from `applications/` to confirm ingress, TLS, DNS, and monitoring are all wired correctly.
4. Layer in security (`manifests/kyverno`, `manifests/network-policy`, `manifests/pod-security`, `manifests/sealed-secrets`) once the base stack is stable.
5. Set up Velero backups (`manifests/velero`, `scripts/backup.sh`) before you consider the cluster production-ready.

## Who this is for

Platform/infra engineers standing up a new cluster who want a working starting point instead of assembling one from a dozen blog posts, and teams who already run Kubernetes but want a consistent, auditable baseline for ingress, observability, GitOps, and security across multiple clusters/clouds. It assumes working knowledge of Kubernetes primitives (Deployments, Services, RBAC) — it is not a Kubernetes tutorial.

## What "production-ready" means here

Concretely, every manifest in this repo is expected to:

- set resource `requests`/`limits` and liveness/readiness probes
- run as non-root with a restrictive `securityContext`
- be reachable only through the paths defined by NetworkPolicy, not open by default
- be observable (scraped by Prometheus, logs in Loki) from the moment it's deployed
- pass `kubeconform`, `trivy`, and `checkov` in CI (see `.github/workflows/`)

See [`docs/production-checklist.md`](production-checklist.md) for the full go-live checklist.

## Where to go next

- [`docs/architecture.md`](architecture.md) for the overall cluster topology
- [`docs/networking.md`](networking.md), [`docs/storage.md`](storage.md), [`docs/security.md`](security.md), [`docs/monitoring.md`](monitoring.md), [`docs/gitops.md`](gitops.md), [`docs/applications.md`](applications.md) for each layer of the stack
- [`docs/troubleshooting.md`](troubleshooting.md) when something doesn't come up cleanly
- [`docs/production-checklist.md`](production-checklist.md) before you call anything "done"
- [`architecture/README.md`](../architecture/README.md) for diagrams
