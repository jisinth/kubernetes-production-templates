# Sealed Secrets

## What is this?

`sealed-secrets` (Bitnami Labs) solves the "how do I put a Secret in Git" problem. Plain Kubernetes `Secret` objects are only base64-encoded, not encrypted — they should never be committed to a repository. `sealed-secrets` provides a cluster-side controller with an asymmetric keypair and a client-side CLI (`kubeseal`) that encrypts a plaintext `Secret` against the controller's public key, producing a `SealedSecret` custom resource. The `SealedSecret` is safe to commit: only the controller holding the matching private key (living only inside the cluster) can decrypt it, at which point it creates the real `Secret` object.

This is the GitOps-friendly answer to secret management when you don't want to run an external secret store (Vault, AWS Secrets Manager, etc.) — everything stays declarative and in Git, including the encrypted secret material.

## Architecture

```
Developer                    Git repo                      Cluster
──────────                   ────────                      ───────
kubectl create secret   ──►  (never committed — /tmp only)
        │
        ▼
kubeseal (encrypts with
controller's PUBLIC key)
        │
        ▼
SealedSecret YAML        ──►  committed to Git       ──►   kubectl/ArgoCD applies
                                                              │
                                                              ▼
                                                    sealed-secrets-controller
                                                    (holds PRIVATE key, in-cluster only)
                                                              │
                                                              ▼
                                                       plain Secret created
                                                       (consumed by pods as usual)
```

The controller's private key never leaves the cluster (it's stored as a `Secret` in the controller's own namespace) and is never transmitted to `kubeseal` — `kubeseal` only ever uses the public key, fetched once from the controller or from a saved cert.

## Prerequisites

- Kubernetes 1.25+ cluster.
- `kubeseal` CLI installed locally (matching the controller's major version) — `brew install kubeseal` or download from the [release page](https://github.com/bitnami-labs/sealed-secrets/releases).
- Cluster-admin RBAC to install the controller and its CRD.
- A plan for backing up the controller's signing keypair (see "Security") — this is the single most important operational detail of running sealed-secrets.

## Installation

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  -f manifests/sealed-secrets/values.yaml \
  --wait
```

Standalone (non-Helm):

```bash
kubectl apply -f manifests/sealed-secrets/controller.yaml
```

Install the matching `kubeseal` CLI version locally:

```bash
KUBESEAL_VERSION=0.27.1
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

### Upgrading

1. **Controller and `kubeseal` CLI versions should stay close together.** The wire format between them has been stable across releases, but a very old `kubeseal` against a much newer controller (or vice versa) is untested territory — pin both to the same minor version range and bump them together.
2. **Never touch the existing keypair Secret during a controller upgrade.** A `helm upgrade` on the controller Deployment doesn't rotate or regenerate the signing key by default — verify `kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key` shows the same key(s) before and after upgrading, since an upgrade that somehow drops the key backing store is equivalent to permanent data loss for every `SealedSecret` in Git.
3. **Take a fresh keypair backup immediately before any controller upgrade**, in addition to the standing backup practice — this is the cheapest insurance against an upgrade-induced key loss, and costs one command (see Security below).
4. After upgrading, run the full round-trip verification test (seal a throwaway secret, confirm it decrypts) before considering the upgrade complete — a controller that starts but can't actually decrypt is a silent failure mode that otherwise surfaces only when someone next tries to roll out a real `SealedSecret`.

### Migrating to/from an external secrets manager

**From sealed-secrets to Vault/AWS Secrets Manager/External Secrets Operator** (common once an org outgrows Git-committed encrypted secrets — e.g. needing dynamic secret rotation, audit logging of *reads* not just writes, or centralized secret lifecycle across multiple clusters):

1. Install External Secrets Operator (or equivalent) alongside sealed-secrets — they don't conflict, since ESO creates plain `Secret` objects from an external store while sealed-secrets creates them from `SealedSecret` CRs; both can target the same namespaces.
2. Migrate the actual secret *values* into the external store first (out-of-band, not via this repo), then replace each `SealedSecret` manifest with the equivalent `ExternalSecret` CR pointing at the same path/name.
3. Confirm the resulting plain `Secret` object is byte-identical (same keys, same values) before deleting the old `SealedSecret` — a mismatch here breaks the consuming app silently at the next pod restart, not at migration time.
4. Do not delete the sealed-secrets controller or its keypair backup until every `SealedSecret` in every environment/branch of this repo (including old tags/releases someone might roll back to) has been migrated — a rollback to an old commit that still references sealed-secrets needs the controller and its key to still exist.

**From an external secrets manager to sealed-secrets** (simplifying away from a dependency on an external system): reverse the above — seal each secret's current value from the external store using `kubeseal`, commit the `SealedSecret`, verify it decrypts to the same value, then remove the `ExternalSecret`/equivalent resource.

## Verification

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets
kubectl get customresourcedefinition sealedsecrets.bitnami.com

# Fetch the controller's public cert (confirms it's reachable and serving)
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system > pub-cert.pem
```

Full round-trip test — create a throwaway Secret, seal it, apply the SealedSecret, confirm the plain Secret materializes:

```bash
kubectl create secret generic test-secret --from-literal=foo=bar --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --format=yaml \
  | kubectl apply -f -

kubectl get secret test-secret -o jsonpath='{.data.foo}' | base64 -d   # should print: bar
kubectl delete sealedsecret test-secret
```

## Configuration

- **Scope** — by default a `SealedSecret` is bound to a specific namespace + name (the controller refuses to unseal it if either changes, preventing a sealed value from being replayed into a different namespace). Use `kubeseal --scope namespace-wide` or `--scope cluster-wide` if you need a sealed value reusable across names/namespaces, but understand this weakens the binding.
- **Key rotation** — `keyrenewperiod: "720h"` (30 days) in [`values.yaml`](values.yaml) has the controller generate a new keypair on that cadence automatically. Old keys are kept so previously-sealed `SealedSecret`s already in Git remain decryptable — the controller tries all known keys.
- **Re-sealing after rotation is not required** — existing `SealedSecret`s keep working as long as the old private key still exists in the controller's namespace. Only re-seal if you're rotating the *secret value* itself, not just the sealing key.
- **Template field** — `spec.template` in a `SealedSecret` (see [`sealedsecret-example.yaml`](sealedsecret-example.yaml)) lets you set labels, annotations, and `type` on the resulting `Secret` without those fields needing to be encrypted themselves.

## Security

- **Back up the controller's keypair.** It's stored as a `Secret` (labeled `sealedsecrets.bitnami.com/sealed-secrets-key`) in the controller's namespace. Losing it makes every `SealedSecret` ever committed to Git permanently undecryptable — there is no recovery path. Export and store it in your organization's normal backup/secret-storage process (e.g. `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > backup.yaml`, then store `backup.yaml` somewhere secure, not in the same Git repo as the SealedSecrets).
- `SealedSecret` ciphertext is safe in a public repo — it only encrypts to the specific controller keypair that sealed it, and (by default) to the specific namespace/name it was sealed for.
- Restrict who can `kubectl get secret` on the resulting plain `Secret` in-cluster via RBAC — sealed-secrets protects secrets in Git, not access to the decrypted Secret once it's live in the cluster.
- Run the controller as non-root with a read-only root filesystem and capabilities dropped (already set in [`values.yaml`](values.yaml) / [`controller.yaml`](controller.yaml)).
- Never commit the plaintext `Secret` YAML used as `kubeseal`'s input — always pipe it directly (`kubectl create secret ... --dry-run=client -o yaml | kubeseal ...`) rather than writing it to a file first, or delete the file immediately after sealing.

## Scaling

- Run a single controller replica (`replicaCount: 1`) — it holds the active private key and there's no meaningful throughput benefit to more replicas; the controller's workload (decrypt-on-apply) is lightweight and infrequent.
- `strategy: Recreate` avoids two controller pods briefly running with different key states during a rollout.
- Backing up/restoring the keypair is what actually matters for "scaling" this component's reliability, not replica count — a controller with a lost key is equivalent to a total outage regardless of how many pods you run.

### High Availability considerations: disaster recovery, not uptime

Sealed-secrets deliberately doesn't offer HA in the usual sense (multiple active replicas) — the real reliability question for this component is disaster recovery of the keypair, not pod uptime:

- **A brief controller outage (pod restart, node drain) is a non-event** — already-created plain `Secret` objects are unaffected; only *new* `SealedSecret` → `Secret` decryption pauses until the single replica comes back, typically seconds.
- **The keypair backup is the actual availability story.** If the controller's namespace/PVC/etcd data were ever lost entirely (cluster rebuild, disaster recovery scenario), restoring from a keypair backup (see Security) is what makes every `SealedSecret` already in Git decryptable again on the new cluster — without that backup, cluster rebuild means re-sealing every secret from original plaintext, which requires that plaintext still exists somewhere.
- **Multi-cluster is not automatically multi-replica-HA** — each cluster's sealed-secrets controller generates its own independent keypair by default; a `SealedSecret` sealed for cluster A's controller is not decryptable by cluster B's controller. For multi-cluster deployments sharing the same sealed manifests (e.g. via GitOps `ApplicationSet` fan-out), either seal separately per cluster or deliberately provision the *same* keypair across clusters (advanced, requires manually importing the private key Secret into each cluster) — don't assume one `SealedSecret` YAML works everywhere just because the manifest is shared.
- **Test the restore path, not just the backup step** — a backup you've never restored from is unverified; periodically (e.g. quarterly) restore the keypair backup into a scratch cluster and confirm a previously-sealed `SealedSecret` actually decrypts there.

## Common Problems

1. **`SealedSecret` applied but `Secret` never materializes** — check `kubectl describe sealedsecret <name> -n <namespace>` for an error like `no key could decrypt secret`. Usually means the SealedSecret was sealed against a different controller instance/keypair (e.g. sealed for a different cluster, or the controller's key was lost/rotated away without keeping old keys).
2. **`error: cannot fetch certificate: no endpoints available`** from `kubeseal` — the controller pod isn't running or the Service/namespace name passed to `--controller-name`/`--controller-namespace` doesn't match. Confirm with `kubectl get pods,svc -n kube-system -l app.kubernetes.io/name=sealed-secrets`.
3. **SealedSecret works in one namespace but fails when copied to another** — default scope binds to namespace + name; copying the YAML to a different namespace without re-sealing (or without `--scope namespace-wide`/`cluster-wide` at seal time) will fail to decrypt by design. Re-seal for the target namespace instead of copy-pasting.
4. **Lost controller keypair, all existing SealedSecrets now undecryptable** — this is unrecoverable without a backup. The only fix is to re-seal every affected secret from its original plaintext against the new keypair — which requires you (or someone) still has the original plaintext values stored somewhere. This is the reason the backup step in "Security" is not optional for production use.
5. **A `SealedSecret` that worked for months suddenly fails to decrypt after a disaster-recovery cluster rebuild** — the new cluster's controller generated a fresh keypair instead of being restored from the old cluster's backup. Confirm the DR runbook explicitly restores the keypair Secret as one of the first steps (before re-applying any `SealedSecret` manifests), not as an afterthought discovered only when secrets fail to materialize.
6. **`kubeseal` produces a `SealedSecret` that the controller rejects with a version/format error** — a `kubeseal` CLI version far ahead of (or behind) the controller's version used an incompatible serialization detail. Pin `kubeseal` to match the controller's version range (see Upgrading) rather than always grabbing the latest CLI release.

## Best Practices

- Back up the controller keypair immediately after installation, before sealing anything for real, and re-verify the backup after any key rotation.
- Never store the plaintext `Secret` YAML on disk longer than the single command needed to pipe it into `kubeseal`.
- Default to namespace-scoped sealing (the default) rather than `cluster-wide` — narrower blast radius if a `SealedSecret` YAML is ever misapplied to the wrong namespace.
- Keep the `kubeseal` CLI version reasonably close to the controller's version — the wire format has been stable across releases, but stay current on both together during upgrades.
- Treat "who can create `SealedSecret` objects in this namespace" as equivalent to "who can create Secrets" from an RBAC/audit perspective — a SealedSecret is a promise of a future Secret, review PRs touching them like you would a Secret change.

## Useful Commands

```bash
# Seal a Secret from stdin (recommended — avoids a plaintext file on disk)
kubectl create secret generic my-secret --from-literal=key=value --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --format=yaml > my-sealedsecret.yaml

# Re-fetch the controller's current public cert (e.g. after a key rotation)
kubeseal --fetch-cert --controller-name=sealed-secrets-controller --controller-namespace=kube-system > pub-cert.pem

# Seal offline using a saved public cert (no live cluster access needed)
kubeseal --cert=pub-cert.pem --format=yaml < my-secret.yaml > my-sealedsecret.yaml

# List all sealing keys the controller currently holds
kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key

# Force an immediate key rotation
kubectl annotate secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key sealedsecrets.bitnami.com/sealed-secrets-key- 2>/dev/null; kubectl rollout restart deployment/sealed-secrets-controller -n kube-system

# Check controller logs for decrypt failures
kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets -f
```

## References

- [sealed-secrets GitHub](https://github.com/bitnami-labs/sealed-secrets)
- [sealed-secrets Helm chart](https://github.com/bitnami-labs/sealed-secrets/tree/main/helm/sealed-secrets)
- [kubeseal CLI usage](https://github.com/bitnami-labs/sealed-secrets#usage)
- [Scopes documentation](https://github.com/bitnami-labs/sealed-secrets#scopes)
- [Key rotation details](https://github.com/bitnami-labs/sealed-secrets#sealing-key-renewal)
