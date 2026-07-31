# kubernetes-production-templates

Production-ready Kubernetes manifests, Helm values, security policies, monitoring configs, and GitOps patterns for real clusters — AKS, EKS, GKE, and Minikube.

This repo is not a toy. Every folder is meant to be applied to a cluster that serves real traffic: sane resource requests/limits, PodDisruptionBudgets, NetworkPolicies, RBAC, and monitoring wired in from day one. Pick the pieces you need, adapt the placeholders, and ship.

## What's included

- **Cluster bootstrap**: namespaces, ingress-nginx, cert-manager, external-dns, metrics-server
- **Observability**: Prometheus, Grafana, Loki, Tempo, Alertmanager — a full metrics/logs/traces stack
- **GitOps**: ArgoCD manifests and application-of-applications patterns
- **Security**: Kyverno policies, NetworkPolicies, Pod Security Standards, Sealed Secrets, RBAC hardening
- **Autoscaling & storage**: HPA/VPA examples, StorageClass and PVC templates
- **Backup & DR**: Velero backup/restore configs and scripts
- **Sample applications**: nginx, Node.js, Python, Spring Boot, Flask deployments wired to the above
- **Cloud examples**: cluster creation and provider-specific notes for AKS, EKS, GKE, and Minikube

## Project structure

```
kubernetes-production-templates/
├── README.md
├── LICENSE
├── CONTRIBUTING.md
├── docs/
├── architecture/
├── manifests/
│   ├── namespace/
│   ├── ingress-nginx/
│   ├── cert-manager/
│   ├── metrics-server/
│   ├── external-dns/
│   ├── sealed-secrets/
│   ├── prometheus/
│   ├── grafana/
│   ├── loki/
│   ├── tempo/
│   ├── alertmanager/
│   ├── argocd/
│   ├── velero/
│   ├── kyverno/
│   ├── network-policy/
│   ├── pod-security/
│   ├── autoscaling/
│   ├── storage/
│   ├── backup/
│   ├── logging/
│   ├── monitoring/
│   └── security/
├── helm-values/
├── applications/
│   ├── nginx/
│   ├── nodejs/
│   ├── python/
│   ├── springboot/
│   └── flask/
├── scripts/
└── examples/
    ├── AKS/
    ├── EKS/
    ├── GKE/
    └── Minikube/
```

## Workflow phases

The repo is organized around the order you'd actually stand up a production cluster:

1. **Cluster Setup** — namespaces, ingress-nginx, cert-manager, external-dns, metrics-server. Gets you a cluster that can route traffic, terminate TLS, and manage DNS records automatically.
2. **Observability** — Prometheus + Grafana + Loki + Tempo + Alertmanager. Metrics, logs, and traces in one stack, with dashboards and alert routing before you onboard real workloads.
3. **GitOps** — ArgoCD. Move from imperative `kubectl apply` to declarative, Git-driven reconciliation for every manifest in this repo.
4. **Security** — Kyverno policy enforcement, NetworkPolicies (default-deny + explicit allows), Pod Security Standards, Sealed Secrets for encrypted-at-rest secrets in Git.
5. **Scaling** — HPA/VPA autoscaling configs and storage classes tuned per cloud provider.
6. **Backup** — Velero scheduled backups and tested restore/disaster-recovery procedures.

## Quick start

```bash
./scripts/install.sh
```

`install.sh` walks through the phases above in order and accepts flags to skip any of them (e.g. `--skip-security`, `--skip-backup`). See [`scripts/`](scripts/) for install, uninstall, backup, restore, and validation scripts, and [`docs/introduction.md`](docs/introduction.md) for a guided walkthrough.

For cloud-specific cluster creation, start with [`examples/AKS/README.md`](examples/AKS/README.md), [`examples/EKS/README.md`](examples/EKS/README.md), [`examples/GKE/README.md`](examples/GKE/README.md), or [`examples/Minikube/README.md`](examples/Minikube/README.md).

## Documentation

- [`docs/introduction.md`](docs/introduction.md) — overview and philosophy
- [`docs/architecture.md`](docs/architecture.md) — cluster topology
- [`docs/networking.md`](docs/networking.md) — ingress, DNS, network policy
- [`docs/storage.md`](docs/storage.md) — storage classes and persistent volumes
- [`docs/security.md`](docs/security.md) — policy enforcement and secrets
- [`docs/monitoring.md`](docs/monitoring.md) — the observability stack
- [`docs/gitops.md`](docs/gitops.md) — ArgoCD patterns
- [`docs/applications.md`](docs/applications.md) — sample application deployments
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — common failure modes
- [`docs/production-checklist.md`](docs/production-checklist.md) — go-live checklist
- [`architecture/README.md`](architecture/README.md) — diagrams (Mermaid)

## Roadmap

- **v1.0** — Namespace templates, Ingress NGINX, Metrics Server, Cert Manager, External DNS
- **v2.0** — Prometheus, Grafana, Loki, Alertmanager, Tempo
- **v3.0** — ArgoCD, Helm examples, GitOps patterns
- **v4.0** — Kyverno, Network Policies, Sealed Secrets, RBAC hardening
- **v5.0** — Velero backup, Disaster recovery, Multi-cluster setup, AKS/EKS/GKE production examples

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for coding standards, the required per-folder documentation layout, and the PR checklist (helm lint, kubeconform, trivy, checkov).

## License

Released under the [MIT License](LICENSE).
