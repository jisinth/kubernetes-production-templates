# Nginx Static Site

## What is this?
A production reference for serving a static site (SPA build output, marketing
site, generated docs) with nginx on Kubernetes. Content lives on a
PersistentVolumeClaim rather than baked into the image, so it can be updated
by a CI pipeline or sync sidecar without rebuilding/rolling the Deployment.
nginx itself is configured entirely via a mounted `nginx.conf` in the
ConfigMap, runs as a non-root user, and exposes an unauthenticated
`/healthz` endpoint for probes.

## Architecture
```
Internet -> Ingress (nginx, TLS via cert-manager) -> Service (ClusterIP:80)
          -> Deployment "nginx-web" (2+ replicas, port 8080)
               - nginx.conf from ConfigMap (subPath mount)
               - static content from PVC "nginx-web-content" (read-only)
               - optional htpasswd from Secret (basic auth, disabled by default)
```
Writable paths the container needs (`/tmp`, `/var/run`, `/var/cache/nginx`)
are `emptyDir` volumes because `readOnlyRootFilesystem: true` is set on the
container.

## Prerequisites
- Kubernetes 1.27+
- ingress-nginx controller installed (`../../manifests/ingress-nginx`)
- cert-manager installed with a `letsencrypt-prod` ClusterIssuer
- A StorageClass named `gp3` (or edit `pvc.yaml`) — see
  `../../manifests/storage/storageclass-examples.yaml`
- A way to populate `/usr/share/nginx/html` on the PVC (CI job, `kubectl cp`,
  init container pulling from object storage, etc.) — this reference does
  not include that pipeline

## Installation
```bash
kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n web -f pvc.yaml
kubectl apply -n web -f configmap.yaml
kubectl apply -n web -f secret.yaml
kubectl apply -n web -f deployment.yaml
kubectl apply -n web -f service.yaml
kubectl apply -n web -f ingress.yaml
kubectl apply -n web -f hpa.yaml
kubectl apply -n web -f pdb.yaml
kubectl apply -n web -f networkpolicy.yaml
```
Populate the content volume once the PVC is bound, e.g.:
```bash
kubectl run -n web content-loader --rm -it --restart=Never \
  --image=busybox --overrides='{"spec":{"containers":[{"name":"content-loader","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"content","mountPath":"/content"}]}],"volumes":[{"name":"content","persistentVolumeClaim":{"claimName":"nginx-web-content"}}]}}' -- true
kubectl cp ./dist web/content-loader:/content
```

## Verification
```bash
kubectl get pods -n web -l app.kubernetes.io/name=nginx-web
kubectl rollout status deployment/nginx-web -n web
kubectl port-forward -n web svc/nginx-web 8080:80
curl -i http://localhost:8080/healthz
curl -i https://app.example.com/
kubectl get certificate -n web nginx-web-tls
```

## Configuration
| Setting | Location | Notes |
|---|---|---|
| Server block, gzip, caching | `configmap.yaml` (`nginx.conf`) | mounted via subPath, restart pods to pick up changes |
| Basic auth | `ingress.yaml` (commented annotations) + `secret.yaml` | disabled by default |
| Content storage size/class | `pvc.yaml` | `gp3`, 5Gi, RWO by default |
| Public hostname | `ingress.yaml` `spec.rules[0].host` | replace `app.example.com` |
| Replica count / scaling bounds | `hpa.yaml` | min 2, max 10, 70% CPU target |

Because `nginx.conf` is mounted via `subPath`, editing the ConfigMap does
**not** hot-reload the running container — you must roll the Deployment
(`kubectl rollout restart deployment/nginx-web -n web`).

## Security
- Runs as non-root uid/gid 101 (the standard nginx-alpine user), with
  `readOnlyRootFilesystem: true` and all Linux capabilities dropped.
- `automountServiceAccountToken: false` — this pod never talks to the
  Kubernetes API.
- NetworkPolicy restricts ingress to the `ingress-nginx` namespace only —
  no pod-to-pod traffic in the cluster can reach nginx directly.
- The `secret.yaml` htpasswd value is a placeholder. Generate a real one with
  `htpasswd -nbB admin '<password>'`, then re-seal it via
  `../../manifests/sealed-secrets` before committing anything to git.
- Content volume is mounted `readOnly: true` in the container — nginx can
  never write into the served directory, limiting blast radius of an RCE.

## Scaling
- HPA scales 2-10 replicas on 70% average CPU utilization; requires
  metrics-server (`../../manifests/metrics-server`) to be running.
- Because content is served from a shared RWX-friendly PVC path (or a
  read replica pattern), scaling out does not require redeploying content.
- PDB (`minAvailable: 1`) ensures at least one replica survives voluntary
  disruptions (node drains, cluster upgrades).
- If you scale beyond 1 replica while using an RWO `gp3` PVC, additional
  pods will be stuck `Pending` — switch to an RWX StorageClass (see
  `pvc.yaml` comments) first.

## Common Problems
- **Pods stuck `Pending` / PVC `Pending`**: RWO volumes can only attach to
  one node at a time; with `replicas: 2` on `gp3` (RWO), the second pod's
  volume mount will fail unless both pods land on the same node or you
  switch to an RWX StorageClass.
- **503 from the Ingress**: check `kubectl get endpoints nginx-web -n web`
  — if empty, readiness probes are failing, usually because `/healthz`
  isn't reachable (check `nginx.conf` is mounted correctly).
- **`nginx.conf` changes not taking effect**: subPath-mounted ConfigMaps do
  not auto-update the container; you must restart the Deployment.
- **Permission denied writing to `/var/cache/nginx` or `/tmp`**: caused by
  removing the `emptyDir` volumes for those paths while
  `readOnlyRootFilesystem: true` is set — keep all three writable mounts.
- **TLS certificate stuck in `Pending`**: verify the `letsencrypt-prod`
  ClusterIssuer exists and DNS for `app.example.com` actually resolves to
  the ingress controller's external IP (`kubectl describe certificate`).

## Best Practices
- Keep content delivery (CI/CD to the PVC) decoupled from Deployment
  rollouts — nginx pods should never need to restart to pick up new content
  if you avoid subPath mounts for content itself.
- Prefer an immutable image + baked-in content for pure static sites when
  RWX storage isn't available; use the PVC pattern shown here when content
  updates need to be independent of image builds.
- Always set explicit `Cache-Control` headers for hashed static assets vs.
  `index.html` (short TTL) to avoid stale SPA shells.
- Pin the nginx image tag (avoid `:latest`) and patch on a regular cadence.

## Useful Commands
```bash
# Tail logs across all replicas
kubectl logs -n web -l app.kubernetes.io/name=nginx-web -f --max-log-requests=10

# Validate the mounted config inside a running pod
kubectl exec -n web deploy/nginx-web -- nginx -t

# Force a config reload after updating the ConfigMap
kubectl rollout restart deployment/nginx-web -n web

# Check current HPA status
kubectl get hpa nginx-web -n web

# Describe why a pod isn't scheduling
kubectl describe pod -n web -l app.kubernetes.io/name=nginx-web
```

## References
- https://kubernetes.io/docs/concepts/services-networking/ingress/
- https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- https://cert-manager.io/docs/usage/ingress/
- https://nginx.org/en/docs/
- `../../manifests/storage/storageclass-examples.yaml`
- `../../manifests/sealed-secrets`
