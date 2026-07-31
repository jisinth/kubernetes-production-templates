# Security

Security in this repo is layered: policy enforcement, network isolation, pod hardening, and secret management are each handled by a dedicated component rather than one giant config.

## Policy enforcement — Kyverno

`manifests/kyverno/` installs Kyverno and a set of policies under `manifests/kyverno/policies/` that validate/mutate/generate cluster objects, for example:

- deny containers running as root or with `allowPrivilegeEscalation: true`
- require resource `requests`/`limits` on every container
- deny `:latest` image tags
- require a matching `NetworkPolicy` to exist before a `Deployment` is admitted (audit mode recommended before switching to enforce)

Start every new policy in `audit` mode, review violations, then flip to `enforce`.

## Network isolation

`manifests/network-policy/` — default-deny per namespace plus explicit allows. See [`docs/networking.md`](networking.md#network-policy) for the rollout order (allow rules before default-deny, always).

## Pod Security Standards

`manifests/pod-security/` applies the `restricted` Pod Security Standard at the namespace level (`pod-security.kubernetes.io/enforce: restricted` label) for application namespaces, and `baseline` for infra namespaces that need slightly more latitude (e.g. ingress-nginx needing `NET_BIND_SERVICE`). This replaces the deprecated PodSecurityPolicy API.

## Secrets management

`manifests/sealed-secrets/` installs the Bitnami Sealed Secrets controller so secret *ciphertext* can be committed to Git safely — only the controller in-cluster can decrypt a `SealedSecret` back into a real `Secret`. Workflow:

```bash
kubeseal --format yaml < secret.yaml > sealed-secret.yaml
```

Commit `sealed-secret.yaml`, never the plaintext `secret.yaml`. For cloud-native alternatives, IRSA (EKS)/Workload Identity (GKE)/Managed Identity (AKS) can be used to avoid static credentials entirely for controllers like external-dns and cert-manager — see the relevant `examples/<provider>/README.md`.

## RBAC

Every controller installed by this repo (ingress-nginx, cert-manager, external-dns, Prometheus, ArgoCD, Kyverno, Velero) gets a dedicated `ServiceAccount` with a narrowly-scoped `ClusterRole`/`Role` — avoid binding `cluster-admin` to anything except break-glass human access. Application `ServiceAccount`s under `applications/` get no cluster-scoped permissions by default.

## Image and manifest scanning

CI (`security.yml`) runs Trivy config scanning and Checkov against every manifest and application on every PR, uploading SARIF results to the repo's Security tab. Findings block merges unless explicitly justified in the PR description — see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Checklist

Before calling a cluster production-ready, walk through the security section of [`docs/production-checklist.md`](production-checklist.md).
