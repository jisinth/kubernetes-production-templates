# Networking

## Ingress

`manifests/ingress-nginx/` deploys the ingress-nginx controller as a `Deployment` (or `DaemonSet` on bare-metal-style clusters) fronted by a `Service` of type `LoadBalancer`. All north-south HTTP(S) traffic enters here. `Ingress` resources in `applications/*` reference the `nginx` `IngressClass` and typically set:

- `nginx.ingress.kubernetes.io/ssl-redirect: "true"`
- `cert-manager.io/cluster-issuer: <issuer-name>` to request a certificate
- rate-limit / body-size annotations per application as needed

See provider notes in `examples/AKS`, `examples/EKS`, `examples/GKE` for the LoadBalancer annotations each cloud requires (internal vs. external LB, health-check paths, etc.).

## TLS

`manifests/cert-manager/` installs cert-manager and a `ClusterIssuer` (Let's Encrypt HTTP-01 or DNS-01, depending on provider). Every `Ingress` that needs TLS gets a `tls:` block referencing a `Secret` name; cert-manager creates and renews that `Secret` automatically. DNS-01 is required for wildcard certs and is preferred on EKS/GKE where `external-dns` already manages the zone.

## DNS

`manifests/external-dns/` runs external-dns watching `Ingress` and `Service` objects, syncing `A`/`CNAME` records into the cloud DNS zone (Route53, Azure DNS, Cloud DNS). It needs provider credentials scoped narrowly to the DNS zone — see the IRSA (EKS) / Workload Identity (GKE) / Managed Identity (AKS) notes in `examples/<provider>/README.md`.

## Network policy

`manifests/network-policy/` ships a **default-deny-all** `NetworkPolicy` per namespace, plus explicit allow rules for:

- ingress-nginx → application pods (by namespace + port)
- application pods → DNS (kube-system, UDP/TCP 53)
- application pods → their own dependencies (databases, caches) by label selector
- monitoring namespace → application pods (Prometheus scrape traffic)

Apply the default-deny policy *after* verifying the required allow rules are in place — apply it too early and you'll cut off DNS resolution and break everything.

## Service mesh

Not included by default — this repo targets ingress-nginx + NetworkPolicy as the baseline. If you introduce a mesh (Istio/Linkerd), it replaces the ingress and network-policy layers; treat `manifests/ingress-nginx/` and `manifests/network-policy/` as the reference for what traffic rules need to be preserved.

## Troubleshooting

See [`docs/troubleshooting.md`](troubleshooting.md) for common ingress 502/504s, cert-manager stuck `CertificateRequest`s, and external-dns record propagation delays.
