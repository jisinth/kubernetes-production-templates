# Node.js API (Express)

## What is this?
A production reference for an Express-style REST API running on Node.js.
It demonstrates a `/healthz` vs `/readyz` probe split (liveness checks the
event loop is alive; readiness checks DB connectivity), a startup probe to
tolerate slow cold starts, and a PVC for local file uploads staged before
being pushed to durable object storage.

## Architecture
```
Internet -> Ingress (nginx, TLS via cert-manager, path /api) -> Service (ClusterIP:80)
          -> Deployment "nodejs-api" (2+ replicas, port 3000)
               - config from ConfigMap (NODE_ENV, PORT, log level, CORS, rate limits)
               - DATABASE_URL/SESSION_SECRET from Secret
               - uploads volume from PVC "nodejs-api-uploads"
               -> egress -> Postgres in "database" namespace, port 5432
```

## Prerequisites
- Kubernetes 1.27+
- ingress-nginx controller and cert-manager with `letsencrypt-prod` issuer
- A `database` namespace with a Postgres Service labeled
  `app.kubernetes.io/name: postgres` (matches `networkpolicy.yaml`)
- A `gp3` StorageClass (see `../../manifests/storage/storageclass-examples.yaml`)
- An image published to `your-registry/nodejs-app:1.0.0` implementing
  `GET /healthz` (process liveness only) and `GET /readyz` (checks DB pool)

## Installation
```bash
kubectl create namespace api --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n api -f pvc.yaml
kubectl apply -n api -f configmap.yaml
kubectl apply -n api -f secret.yaml
kubectl apply -n api -f deployment.yaml
kubectl apply -n api -f service.yaml
kubectl apply -n api -f ingress.yaml
kubectl apply -n api -f hpa.yaml
kubectl apply -n api -f pdb.yaml
kubectl apply -n api -f networkpolicy.yaml
```

## Verification
```bash
kubectl rollout status deployment/nodejs-api -n api
kubectl get pods -n api -l app.kubernetes.io/name=nodejs-api
kubectl port-forward -n api svc/nodejs-api 8080:80
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/readyz
curl -i https://app.example.com/api/health
```

## Configuration
| Setting | Location | Notes |
|---|---|---|
| Runtime env (NODE_ENV, PORT, log level) | `configmap.yaml` | non-secret only |
| CORS / rate limiting | `configmap.yaml` | tune per environment |
| DB connection string, session secret | `secret.yaml` | placeholder, replace before real use |
| Upload storage size | `pvc.yaml` | 10Gi RWO by default |
| Resource sizing | `deployment.yaml` | 100m/128Mi requests, 500m/512Mi limits |
| Autoscaling bounds | `hpa.yaml` | 2-10 replicas, CPU 70% + memory 80% |

## Security
- Non-root uid 1000, `readOnlyRootFilesystem: true`, all capabilities
  dropped, `allowPrivilegeEscalation: false`.
- `automountServiceAccountToken: false` since this API does not call the
  Kubernetes API server.
- Secrets are never referenced via plain `env.value` — only `envFrom.secretRef`,
  keeping them out of `kubectl describe pod` env dumps in most viewers (they
  still appear via `kubectl get pod -o yaml`, so RBAC on Secrets still matters).
- NetworkPolicy default-denies everything except: ingress from
  `ingress-nginx`, DNS egress, and egress to Postgres in `database` ns on
  5432 — this pod cannot reach any other service in the cluster.
- Rotate `SESSION_SECRET` via a new sealed Secret + rolling restart; do not
  edit the Secret in place without also invalidating existing sessions.

## Scaling
- HPA scales on both CPU (70%) and memory (80%) utilization — Node.js apps
  often hit memory pressure (event loop backlog, large payload buffering)
  before CPU, so scaling on memory alone can catch cases CPU misses.
- Requires metrics-server (`../../manifests/metrics-server`).
- `maxUnavailable: 0` in the rolling update strategy plus the PDB
  (`minAvailable: 1`) means node drains and deploys never drop capacity
  below what's currently serving traffic.
- Uploads PVC is RWO — if you need uploads visible from every replica
  immediately, move to object storage (S3/GCS) instead of scaling the PVC.

## Common Problems
- **CrashLoopBackOff right after deploy**: usually `DATABASE_URL` pointing
  at a Postgres Service/namespace that doesn't match the NetworkPolicy
  egress rule — check `kubectl logs` for ECONNREFUSED/timeout and confirm
  the `database` namespace label and Postgres pod labels match
  `networkpolicy.yaml`.
- **Readiness flapping under load**: `/readyz` doing a live DB query on
  every probe can itself exhaust the DB connection pool at high replica
  counts — prefer a cached "last successful ping" check.
- **502/504 from Ingress**: check `nginx.ingress.kubernetes.io/proxy-read-timeout`
  against how long your slowest endpoint actually takes; also verify
  `/readyz` is passing (`kubectl get endpoints nodejs-api -n api`).
- **HPA shows `<unknown>` for targets**: metrics-server isn't installed or
  the pods don't have resource `requests` set (both are set here, so check
  metrics-server first with `kubectl top pods -n api`).
- **EACCES writing to /app/uploads**: PVC provisioned with a different
  `fsGroup` than the pod's `securityContext.fsGroup: 1000` — check the
  StorageClass/CSI driver honors `fsGroup`.

## Best Practices
- Keep liveness checks cheap (process/event-loop only) and readiness
  checks meaningful (DB/cache connectivity) — conflating them causes
  cascading restarts during downstream outages.
- Treat the uploads PVC as a staging buffer, not durable storage; push to
  S3/GCS and prune local files on a schedule.
- Set `NODE_OPTIONS=--max-old-space-size=...` consistent with the
  container memory limit to fail fast (OOM at Node heap, not silently at
  cgroup) if you add it to `configmap.yaml`.
- Never log `DATABASE_URL` or `SESSION_SECRET` — mask them in structured
  logs even at debug level.

## Useful Commands
```bash
# Tail logs from all replicas with JSON pretty-printing
kubectl logs -n api -l app.kubernetes.io/name=nodejs-api -f | jq .

# Check current resource usage vs requests/limits
kubectl top pods -n api -l app.kubernetes.io/name=nodejs-api

# Exec into a running pod to inspect env (secrets redacted in envFrom listing)
kubectl exec -n api deploy/nodejs-api -- printenv | sort

# Watch HPA decisions live
kubectl get hpa nodejs-api -n api -w

# Force a rolling restart after a ConfigMap/Secret change
kubectl rollout restart deployment/nodejs-api -n api
```

## References
- https://expressjs.com/en/advanced/best-practice-performance.html
- https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- `../../manifests/metrics-server`
- `../../manifests/sealed-secrets`
