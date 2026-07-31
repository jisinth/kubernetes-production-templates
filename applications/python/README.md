# Python App (API/Worker)

## What is this?
A production reference for a generic Python service (e.g. FastAPI API or a
long-running worker process) that calls out to third-party APIs and keeps a
local on-disk cache of downloaded/computed artifacts. It's intentionally
framework-agnostic — swap the `command`/`args` in `deployment.yaml` for
`gunicorn`, `uvicorn`, `celery worker`, etc. as needed.

## Architecture
```
Internet -> Ingress (nginx, TLS via cert-manager, path /py) -> Service (ClusterIP:80)
          -> Deployment "python-app" (2+ replicas, port 8000)
               - config from ConfigMap (env, log level, worker count, cache settings)
               - THIRD_PARTY_API_KEY/ENCRYPTION_KEY from Secret
               - cache volume from PVC "python-app-cache" (per-pod, RWO)
               -> egress -> HTTPS (443) to external APIs
```

## Prerequisites
- Kubernetes 1.27+
- ingress-nginx controller and cert-manager with `letsencrypt-prod` issuer
- A `gp3` StorageClass (see `../../manifests/storage/storageclass-examples.yaml`)
- An image at `your-registry/python-app:1.0.0` running `python -m app.main`
  and exposing `GET /healthz` and `GET /readyz` on port 8000

## Installation
```bash
kubectl create namespace py-app --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n py-app -f pvc.yaml
kubectl apply -n py-app -f configmap.yaml
kubectl apply -n py-app -f secret.yaml
kubectl apply -n py-app -f deployment.yaml
kubectl apply -n py-app -f service.yaml
kubectl apply -n py-app -f ingress.yaml
kubectl apply -n py-app -f hpa.yaml
kubectl apply -n py-app -f pdb.yaml
kubectl apply -n py-app -f networkpolicy.yaml
```

## Verification
```bash
kubectl rollout status deployment/python-app -n py-app
kubectl get pods -n py-app -l app.kubernetes.io/name=python-app
kubectl port-forward -n py-app svc/python-app 8080:80
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/readyz
curl -i https://app.example.com/py/health
```

## Configuration
| Setting | Location | Notes |
|---|---|---|
| App env, log level, worker count | `configmap.yaml` | non-secret only |
| Cache directory/TTL | `configmap.yaml` | backed by PVC |
| Third-party API key, encryption key | `secret.yaml` | placeholder, replace before real use |
| Cache volume size | `pvc.yaml` | 20Gi RWO |
| Resource sizing | `deployment.yaml` | 150m/256Mi requests, 750m/768Mi limits |
| Autoscaling bounds | `hpa.yaml` | 2-10 replicas, CPU 70% |

## Security
- Non-root uid 1000, `readOnlyRootFilesystem: true`, all capabilities
  dropped, `allowPrivilegeEscalation: false`.
- `automountServiceAccountToken: false`.
- Egress is scoped to DNS + HTTPS(443) only, with the AWS/GCP/Azure
  instance-metadata IP (`169.254.169.254`) explicitly excluded from the
  broad egress rule to prevent SSRF-style credential theft from a
  compromised process.
- `ENCRYPTION_KEY`/`THIRD_PARTY_API_KEY` are placeholders; replace with
  real values sealed via `../../manifests/sealed-secrets` or synced with
  external-secrets before any real deployment.
- Because egress allows all of `0.0.0.0/0:443` (any third-party API host),
  tighten `networkpolicy.yaml` to specific `ipBlock` CIDRs if the set of
  external dependencies is known and fixed.

## Scaling
- HPA scales 2-10 replicas on 70% average CPU; requires metrics-server
  (`../../manifests/metrics-server`).
- If this deployment is a Celery-style worker instead of a request/response
  API, consider scaling on a custom metric (queue depth) via
  `../../manifests/autoscaling` instead of CPU alone.
- PDB `minAvailable: 1` plus `maxUnavailable: 0` rolling updates keep at
  least one worker/API instance up during node drains and deploys.

## Common Problems
- **`readyz` fails immediately after startup**: check whether the readiness
  probe depends on the cache directory being writable — verify PVC is
  `Bound` (`kubectl get pvc -n py-app`) before troubleshooting app code.
- **OOMKilled under load**: Python processes (especially with multiple
  workers) can exceed `memory.limits` quickly; check `WORKERS` in
  `configmap.yaml` against the container memory limit — reduce worker
  count or raise the limit.
- **Egress blocked to a third-party API**: confirm the NetworkPolicy allows
  port 443 broadly, or add a specific `ipBlock` if you've tightened it;
  also check DNS egress (UDP/TCP 53) is intact or hostnames won't resolve.
- **HPA `<unknown>` targets**: metrics-server missing, or CPU `requests`
  unset (they're set here) — verify with `kubectl top pods -n py-app`.
- **Slow first request after scale-up**: cold cache on a freshly scheduled
  pod (new PVC-backed cache starts empty) — expected; consider a
  pre-warming init container if cold-start latency matters.

## Best Practices
- Keep the on-disk cache treated as disposable — the app must function
  correctly (just slower) with an empty cache directory.
- Set `PYTHONUNBUFFERED=1` (already in `configmap.yaml`) so logs stream to
  stdout immediately instead of buffering, which matters for `kubectl logs`
  and log aggregation.
- Pin third-party dependency versions in the image and rebuild on a
  schedule for CVE patching rather than relying on `:latest` base images.
- Avoid storing computed secrets (e.g. derived encryption keys) on the PVC
  cache — treat the cache as non-secret data only.

## Useful Commands
```bash
# Tail logs across all replicas
kubectl logs -n py-app -l app.kubernetes.io/name=python-app -f

# Check cache volume usage inside a pod
kubectl exec -n py-app deploy/python-app -- du -sh /app/cache

# Check current resource usage vs requests/limits
kubectl top pods -n py-app -l app.kubernetes.io/name=python-app

# Watch HPA decisions live
kubectl get hpa python-app -n py-app -w

# Force a rolling restart after a ConfigMap/Secret change
kubectl rollout restart deployment/python-app -n py-app
```

## References
- https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- https://kubernetes.io/docs/concepts/services-networking/network-policies/
- https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- `../../manifests/metrics-server`
- `../../manifests/sealed-secrets`
