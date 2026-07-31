# ingress-nginx

## What is this?

**Why Ingress**: Kubernetes Services (`ClusterIP`/`NodePort`/`LoadBalancer`) give you L4 access to a single app. Once you have more than one HTTP(S) service, provisioning a cloud LoadBalancer per service gets expensive and gives you no shared routing, TLS termination, or virtual hosting. An `Ingress` resource plus an ingress controller gives you one L7 entry point that fans out to many backend Services by hostname/path, terminates TLS, and centralizes cross-cutting concerns (rate limiting, auth, redirects, compression).

`ingress-nginx` is the community (Kubernetes SIG) ingress controller built on NGINX — it watches `Ingress` and `IngressClass` objects and reconfigures an NGINX fleet to match. This folder provides both a Helm-based install (recommended) and a minimal standalone Deployment/Service/IngressClass for environments that can't run Helm.

## Architecture

```
Internet
   │
   ▼
Cloud LoadBalancer  (manifests/ingress-nginx/service.yaml, type: LoadBalancer)
   │
   ▼
ingress-nginx-controller pods (Deployment, 3+ replicas, spread across zones)
   │  reads Ingress + IngressClass objects, renders nginx.conf, reloads
   ▼
Backend Services (ClusterIP)  →  Pods
```

TLS is terminated at the controller. Certificates come from `cert-manager` (see `manifests/cert-manager/`), which watches `Ingress` objects annotated with `cert-manager.io/cluster-issuer` and populates the `Secret` referenced in `spec.tls[].secretName`. The controller then serves that certificate for the matching `host`.

## Prerequisites

- Kubernetes 1.25+ cluster with a cloud controller manager that supports `type: LoadBalancer` Services (or a bare-metal LB like MetalLB).
- `kubectl` and `helm` (v3.8+) configured against the target cluster.
- Cluster-admin RBAC to create the `IngressClass` (cluster-scoped) and the validating webhook configuration.
- DNS control for whatever hostnames you plan to route (manually, or via `manifests/external-dns/`).

## Installation

Full walkthrough: [`install.md`](install.md). Quick version:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f helm-values/ingress-nginx.yaml \
  --wait
```

Standalone (non-Helm) alternative:

```bash
kubectl create namespace ingress-nginx
kubectl apply -f manifests/ingress-nginx/ingressclass.yaml
kubectl apply -f manifests/ingress-nginx/deployment.yaml
kubectl apply -f manifests/ingress-nginx/service.yaml
```

The standalone path omits the Helm chart's RBAC, admission webhook, and ServiceMonitor — add those yourself or accept a controller that can't validate Ingress objects at admission time (misconfigured Ingresses will only surface as runtime errors instead of being rejected up front).

## Verification

```bash
kubectl get pods -n ingress-nginx
kubectl get svc ingress-nginx-controller -n ingress-nginx    # wait for EXTERNAL-IP
kubectl get ingressclass                                      # "nginx" should show as default
curl -v http://<EXTERNAL-IP>/healthz                           # controller health endpoint (200 OK)
```

Deploy a test Ingress and curl it with `-H "Host: <hostname>"` as shown in [`install.md`](install.md#7-smoke-test) to confirm end-to-end routing before cutting over real DNS.

## Configuration

Key knobs, set in [`values.yaml`](values.yaml) / [`../../helm-values/ingress-nginx.yaml`](../../helm-values/ingress-nginx.yaml):

- `controller.config` — a passthrough to the NGINX ConfigMap (`proxy-body-size`, `hsts`, `use-forwarded-headers`, `ssl-redirect`, etc.). Anything in [ingress-nginx's ConfigMap keys](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/) can go here.
- `controller.service.externalTrafficPolicy: Local` — preserves client source IP (needed for IP-based rate limiting/allowlisting) at the cost of slightly uneven load balancing across nodes.
- Per-Ingress annotations (not in this repo, applied on your app's `Ingress` object) override global config, e.g.:
  ```yaml
  metadata:
    annotations:
      nginx.ingress.kubernetes.io/rewrite-target: /
      nginx.ingress.kubernetes.io/proxy-body-size: "50m"
      nginx.ingress.kubernetes.io/limit-rps: "10"
  ```
- **SSL/TLS via cert-manager**: annotate the Ingress with `cert-manager.io/cluster-issuer: letsencrypt-prod` (see `manifests/cert-manager/`) and add:
  ```yaml
  spec:
    tls:
      - hosts: ["app.example.com"]
        secretName: app-example-com-tls
  ```
  cert-manager watches for this annotation, solves the ACME HTTP-01 challenge through this same ingress-nginx controller, and populates the `Secret`. No manual certificate handling required.

## Security

- Run the controller pods as non-root (`runAsUser: 101`, `allowPrivilegeEscalation: false`, capabilities dropped except `NET_BIND_SERVICE`) — see [`deployment.yaml`](deployment.yaml).
- Keep the validating admission webhook enabled (`controller.admissionWebhooks.enabled: true` in the Helm chart) — it rejects syntactically invalid or conflicting Ingress objects before they reach NGINX.
- Set `hsts: "true"` and a sane `hsts-max-age` once you're confident all hosts behind the controller support HTTPS.
- Restrict who can create `Ingress` objects in shared clusters via RBAC — an Ingress can expose any Service in its namespace to the internet.
- Consider `nginx.ingress.kubernetes.io/whitelist-source-range` or a WAF (e.g. ModSecurity, ingress-nginx's built-in module) for internet-facing admin endpoints.

## Scaling

- `controller.autoscaling` (HPA) targets CPU/memory; NGINX is largely single-threaded-per-worker and CPU-bound under high connection churn, so watch CPU first.
- `controller.replicaCount: 3` plus `topologySpreadConstraints` keeps the controller available across a zone outage; never run fewer than 2 for anything internet-facing.
- `podDisruptionBudget.minAvailable: 2` prevents a node drain/cluster upgrade from taking out all controllers simultaneously.
- Horizontal scaling of the controller doesn't shard by hostname — every replica holds the full NGINX config for every Ingress in the cluster. At very large Ingress counts (thousands), watch controller reload latency and consider `ingress-nginx`'s dynamic configuration mode (already default in modern chart versions) which avoids full reloads for endpoint-only changes.

## Common Problems

1. **`EXTERNAL-IP` stuck at `<pending>`** — the cluster's cloud controller manager isn't provisioning LoadBalancers, or you're on bare metal without MetalLB/similar. Check `kubectl describe svc ingress-nginx-controller -n ingress-nginx` for events; on bare metal, switch to `NodePort` + an external LB, or install MetalLB.
2. **`503 Service Temporarily Unavailable` for a valid Ingress** — usually the backend Service has no ready endpoints. Check `kubectl get endpoints <svc>` — if empty, the backend pods are failing readiness probes, not an ingress-nginx problem.
3. **`Ingress` applied but never picked up / no route** — `spec.ingressClassName` doesn't match `nginx`, or an older cluster is relying on the deprecated `kubernetes.io/ingress.class` annotation which this controller version may not read by default. Set `ingressClassName: nginx` explicitly.
4. **cert-manager challenge fails with `404` from the ACME validation server** — the HTTP-01 solver's temporary Ingress isn't routing through this same controller/IngressClass, often because a second ingress controller in the cluster is intercepting the challenge path. Confirm only one `IngressClass` is marked `is-default-class: true`, and that the solver's `ingressClassName` matches this controller.

## Best Practices

- Always pin `controller.image.tag` to a specific version — don't float on `latest`; validate upgrades in staging first, since NGINX config directives occasionally change between major chart versions.
- Terminate TLS at the ingress controller, not further downstream, unless you have a specific mTLS requirement between the controller and backends.
- Use one shared ingress-nginx deployment per cluster/tier rather than one per app namespace — it's a control-plane-adjacent component with cluster-wide visibility via the `IngressClass`.
- Keep `externalTrafficPolicy: Local` unless you specifically need even node-level load distribution over source IP preservation.
- Version-control every `Ingress` object's annotations alongside the app that owns it — ingress-nginx config drift across dozens of hand-edited Ingresses is a common source of inconsistent behavior.

## Useful Commands

```bash
# Tail controller logs (NGINX access/error + controller reconciliation logs)
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller -f

# Dump the live, rendered nginx.conf from a running controller pod
kubectl exec -n ingress-nginx <controller-pod> -- cat /etc/nginx/nginx.conf

# List all Ingress objects cluster-wide and which class they use
kubectl get ingress -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host

# Check current Helm release values vs. defaults
helm get values ingress-nginx -n ingress-nginx

# Force a controller reload without restarting pods (rarely needed; config is normally dynamic)
kubectl exec -n ingress-nginx <controller-pod> -- nginx -s reload

# Check webhook health if Ingress applies are hanging
kubectl get validatingwebhookconfigurations ingress-nginx-admission -o yaml
```

## References

- [ingress-nginx documentation](https://kubernetes.github.io/ingress-nginx/)
- [ingress-nginx Helm chart values](https://github.com/kubernetes/ingress-nginx/tree/main/charts/ingress-nginx)
- [ConfigMap configuration options](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/)
- [Ingress annotations reference](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [Kubernetes Ingress concept docs](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [cert-manager + ingress-nginx tutorial](https://cert-manager.io/docs/tutorials/acme/nginx-ingress/)
