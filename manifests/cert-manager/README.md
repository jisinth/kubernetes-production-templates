# cert-manager

## What is this?

`cert-manager` is a Kubernetes controller that automates X.509 certificate issuance and renewal. It watches `Certificate`, `Issuer`, and `ClusterIssuer` custom resources and talks to certificate authorities on your behalf — most commonly Let's Encrypt via the ACME protocol — to request, validate, and renew TLS certificates, storing the result as a `Secret` your Ingress (or any workload) can mount.

Paired with `ingress-nginx` (`manifests/ingress-nginx/`), this eliminates manual certificate handling entirely: annotate an `Ingress` with a `ClusterIssuer` name, and cert-manager solves the ACME challenge through that same ingress controller and keeps the certificate renewed for the life of the Ingress.

## Architecture

```
Ingress (annotated: cert-manager.io/cluster-issuer: letsencrypt-prod)
   │
   ▼
cert-manager controller  ──creates──▶  Certificate (implicit, from the Ingress shim)
   │                                          │
   │                                          ▼
   │                                   CertificateRequest ──▶ Order ──▶ Challenge
   │                                          │
   ▼                                          ▼
ClusterIssuer (ACME, Let's Encrypt)   HTTP-01 solver: temporary Ingress path
                                       served through ingress-nginx, validated
                                       by Let's Encrypt's servers
                                          │
                                          ▼
                                   Secret (tls.crt / tls.key) mounted by the
                                   original Ingress for TLS termination
```

Two `ClusterIssuer`s are provided: `letsencrypt-staging` (untrusted certs, high rate limits — use while testing) and `letsencrypt-prod` (trusted certs, tight rate limits — use once verified).

## Prerequisites

- Kubernetes 1.25+ cluster with `ingress-nginx` installed (`manifests/ingress-nginx/`) if using the HTTP-01 solver via Ingress.
- Public DNS pointing at the ingress controller's external IP for any domain you request a certificate for — Let's Encrypt's HTTP-01 challenge must reach your cluster over the public internet.
- `kubectl` and `helm` (v3.8+).
- An email address for ACME registration (expiry/problem notifications) — update it in both `cluster-issuer-letsencrypt-*.yaml` files before applying.

## Installation

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --namespace cert-manager --create-namespace \
  -f helm-values/cert-manager.yaml \
  --wait

# Apply issuers after the controller is ready (CRDs must exist first)
kubectl apply -f manifests/cert-manager/cluster-issuer-letsencrypt-staging.yaml
kubectl apply -f manifests/cert-manager/cluster-issuer-letsencrypt-prod.yaml
```

`installCRDs: true` in [`values.yaml`](values.yaml) installs the `Certificate`/`Issuer`/`ClusterIssuer`/etc. CRDs as part of the chart. If you manage CRDs separately (common in GitOps setups where CRDs are applied out-of-band), set it to `false` and apply the CRD manifests from the [cert-manager release](https://github.com/cert-manager/cert-manager/releases) yourself first.

### Upgrading

cert-manager ships a compatibility policy of supporting the last few Kubernetes minor versions; always check the [supported releases table](https://cert-manager.io/docs/releases/) before upgrading either cert-manager or the cluster.

1. **CRDs upgrade before the controller.** Helm's `installCRDs: true` handles this automatically on `helm upgrade`, but if CRDs are managed out-of-band, apply the new CRD manifests *first*, then upgrade the chart — running an old controller against new CRD schemas is fine, but a new controller against stale CRDs can fail to start.
2. **Check for API version deprecations** — cert-manager has migrated its CRD API group across major versions before (`certmanager.k8s.io` → `cert-manager.io`, and `v1alpha2`/`v1alpha3`/`v1beta1` → `v1`). Run `cmctl upgrade migrate-api-version` before upgrading if you have any resources still on non-`v1` API versions — the tool rewrites `Issuer`/`Certificate`/etc. resources in place.
3. **Never skip more than one major version** in a single upgrade — go through each major version's own upgrade notes sequentially; multi-version jumps are the most common source of cert-manager upgrade incidents reported upstream.
4. Validate in staging with a real `Certificate` issuance/renewal cycle against `letsencrypt-staging` after every upgrade — a webhook or CRD conversion bug can pass health checks while silently breaking issuance.

### Migrating from another certificate solution

Moving from a different renewal mechanism (e.g. `kube-lego`, a manual/cron-based `certbot` setup, or hand-rotated certificates):

1. Install cert-manager and apply `cluster-issuer-letsencrypt-staging.yaml` without touching any existing Ingress yet.
2. Pick one low-traffic hostname, add the `cert-manager.io/cluster-issuer: letsencrypt-staging` annotation and a `tls` block pointing at a **new** `secretName` (don't reuse the existing manually-managed Secret name yet) — confirm end-to-end issuance works before touching production traffic.
3. Once confirmed, re-point that Ingress's `secretName` to a fresh name managed by cert-manager against `letsencrypt-prod`, then repeat per-hostname across the fleet.
4. Only after every hostname is cut over, remove the old renewal cron job/kube-lego deployment — running both systems against the same hostname simultaneously causes a race for the `Secret` and provider rate-limit consumption from duplicate issuance attempts.

## Verification

```bash
kubectl get pods -n cert-manager                     # controller, webhook, cainjector all Running
kubectl get clusterissuer                            # letsencrypt-staging / letsencrypt-prod: READY=True
kubectl describe clusterissuer letsencrypt-staging    # check .status.conditions for ACME registration errors

# End-to-end test against staging first
kubectl apply -f manifests/cert-manager/certificate-example.yaml   # change issuerRef to letsencrypt-staging first
kubectl get certificate -n production -w
kubectl describe certificate app-example-com-tls -n production     # watch Events for challenge progress
```

A `Certificate` reaching `READY=True` with a populated `secretName` confirms the full ACME flow worked end to end.

## Configuration

- **Switching solvers**: this repo uses HTTP-01 (`solvers[].http01.ingress.ingressClassName: nginx`) because it requires no cloud credentials. If you need wildcard certificates or your Ingress isn't publicly reachable, switch to DNS-01 by replacing `http01` with a `dns01` block for your DNS provider (Route53, Cloud DNS, Cloudflare, etc.) plus the relevant IAM/API-token Secret.
- **Requesting a cert via Ingress annotation** (no explicit `Certificate` object needed):
  ```yaml
  metadata:
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
  spec:
    tls:
      - hosts: ["app.example.com"]
        secretName: app-example-com-tls
  ```
- **Explicit `Certificate` resource** ([`certificate-example.yaml`](certificate-example.yaml)) — use when you need a cert not tied to a single Ingress, control over `duration`/`renewBefore`, or SAN lists spanning multiple hostnames.
- **`renewBefore`** — cert-manager renews automatically; 15 days before a 90-day Let's Encrypt cert's expiry is a safe default that leaves room to debug a failed renewal before the cert actually expires.
- **Rate limits** — Let's Encrypt production allows 50 certificates per registered domain per week and 5 duplicate certificates per week; always validate against `letsencrypt-staging` first.

## Security

- Run controller/webhook/cainjector as non-root with `allowPrivilegeEscalation: false` and all capabilities dropped (already set in [`values.yaml`](values.yaml)).
- Store the ACME account private key (`privateKeySecretRef`) — cert-manager creates and manages this Secret; don't hand-edit it.
- Scope who can create/edit `ClusterIssuer` objects via RBAC — a malicious or buggy `ClusterIssuer`/`Certificate` can exhaust your domain's Let's Encrypt rate limit for a week.
- Keep the validating webhook enabled; it catches malformed `Certificate`/`Issuer` specs before they reach the controller.
- Rotate the ACME account key only if compromised — routine rotation isn't necessary since the key only authenticates to Let's Encrypt, it isn't the TLS key served to clients.

## Scaling

- `replicaCount: 2` for the controller, webhook, and cainjector gives HA via leader election (controller) or stateless replication (webhook/cainjector) — only one controller replica is ever active, the rest are hot standby, so scaling beyond 2 doesn't increase issuance throughput.
- Issuance throughput is bounded by the ACME server's rate limits, not cert-manager's own resource allocation — raising `resources.limits` won't get you certificates faster.
- With many `Certificate` objects (hundreds+), watch controller CPU during renewal windows (cert-manager batches renewal checks) and increase `resources.requests.cpu` if reconciliation lags.

### High Availability considerations

- **Leader election, not active-active**: `replicaCount: 2` for the controller relies on Kubernetes lease-based leader election — only one replica actively reconciles at any time. This protects against a single pod/node failure with a fast failover (leases expire in seconds), but it does not increase issuance throughput; don't scale the controller for capacity, only for availability.
- **webhook and cainjector are stateless** — both scale horizontally with no coordination needed; 2 replicas of each purely for pod/node-failure tolerance during a cluster upgrade or node drain.
- **cainjector is a soft dependency at steady state**: it only matters when the webhook's CA bundle needs (re)injecting — typically at install/upgrade time. A brief cainjector outage on an already-running cluster doesn't stop certificate issuance/renewal, only new webhook CA rotations.
- **Renewal storms after an outage**: if cert-manager is down for an extended period (e.g. a botched upgrade) and several certificates cross their `renewBefore` threshold simultaneously, expect a burst of renewal requests on recovery — this can bump against Let's Encrypt's rate limits if dozens of certs queue up at once. Stagger `duration`/`renewBefore` across unrelated certificates rather than issuing them all with identical timing if you manage a large fleet.

## Common Problems

1. **`Certificate` stuck at `READY=False`, Challenge stuck `pending`** — the HTTP-01 challenge path (`/.well-known/acme-challenge/...`) isn't reachable from the public internet. Check DNS actually resolves to the ingress-nginx external IP, and that no `NetworkPolicy`/firewall blocks inbound port 80 (ACME does not use 443 for the HTTP-01 challenge itself).
2. **`urn:ietf:params:acme:error:rateLimited`** — you hit Let's Encrypt's production rate limit, usually from repeated failed attempts while debugging against `letsencrypt-prod` instead of `letsencrypt-staging`. Switch to staging, fix the underlying issue, confirm success, then re-point `issuerRef` to prod.
3. **Webhook `x509: certificate signed by unknown authority` on `helm upgrade`** — the cainjector hasn't yet injected the webhook's CA bundle, usually right after install. Wait ~30s and retry, or check `kubectl get pods -n cert-manager` for a crashlooping cainjector.
4. **Certificate issues successfully but browsers still show untrusted/self-signed** — you're pointed at `letsencrypt-staging`, which is a real ACME flow but its root CA isn't in any trust store by design. Re-issue against `letsencrypt-prod` once staging validates cleanly.
5. **Resources stuck referencing a deprecated CRD API version after a cert-manager upgrade** — objects created under `v1alpha2`/`v1beta1` don't auto-migrate; the controller may refuse to reconcile them post-upgrade. Run `cmctl upgrade migrate-api-version` (or `kubectl get certificate.v1.cert-manager.io -A -o yaml` and reapply) to move them to `v1` before assuming the upgrade is broken.
6. **Duplicate `Certificate` objects for the same hostname fighting each other** — one created via the Ingress-shim annotation and another via an explicit `Certificate` manifest both targeting the same `secretName` will race on renewal and issuance, doubling ACME calls against the same rate limit bucket. Pick one mechanism per hostname — either the annotation shim or an explicit `Certificate`, never both.
7. **Renewal succeeds but the Ingress keeps serving the old (expiring) certificate** — some ingress controllers cache TLS certificate data per-connection or per-worker and don't always pick up a `Secret` update instantly. Confirm the `Secret`'s `tls.crt` actually changed (`kubectl get secret ... -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates`) before assuming cert-manager failed — if the Secret is correct but the served cert is stale, it's an ingress-nginx reload issue, not a cert-manager one.

## Best Practices

- Always validate new Ingress/domain/solver configurations against `letsencrypt-staging` before switching to `letsencrypt-prod` — production rate limits are unforgiving.
- Prefer the Ingress-shim annotation over hand-written `Certificate` objects unless you have a specific reason (multiple SANs, non-Ingress workloads, custom renewal window) — fewer objects to keep in sync.
- Use `rotationPolicy: Always` with ECDSA P-256 keys (smaller, faster TLS handshakes than RSA-2048) unless a client requires RSA.
- Monitor `certmanager_certificate_ready_status` and `certmanager_certificate_expiration_timestamp_seconds` (exposed via the ServiceMonitor) and alert well before expiry as a backstop to automatic renewal.
- Keep one email address for ACME registration per cluster/environment so expiry notices from Let's Encrypt reach the right team.

## Useful Commands

```bash
# Watch certificate issuance end to end
kubectl get certificate,certificaterequest,order,challenge -A

# Full status/history for a stuck certificate
kubectl describe certificate app-example-com-tls -n production

# Controller logs (ACME errors, challenge failures surface here)
kubectl logs -n cert-manager -l app.kubernetes.io/component=controller -f

# Force a renewal (cert-manager >= 1.14, via kubectl cert-manager plugin)
kubectl cert-manager renew app-example-com-tls -n production

# Check ClusterIssuer health / ACME registration status
kubectl get clusterissuer -o wide
kubectl describe clusterissuer letsencrypt-prod

# Inspect the issued certificate's actual expiry/SANs
kubectl get secret app-example-com-tls -n production -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates -subject -ext subjectAltName
```

## References

- [cert-manager documentation](https://cert-manager.io/docs/)
- [cert-manager Helm chart](https://cert-manager.io/docs/installation/helm/)
- [ACME HTTP-01 with ingress-nginx tutorial](https://cert-manager.io/docs/tutorials/acme/nginx-ingress/)
- [ACME DNS-01 providers](https://cert-manager.io/docs/configuration/acme/dns01/)
- [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/)
- [cert-manager troubleshooting guide](https://cert-manager.io/docs/troubleshooting/)
