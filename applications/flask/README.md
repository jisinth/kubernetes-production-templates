# Flask App (gunicorn)

## What is this?
A production reference for a Flask application served by gunicorn using
threaded workers (`gthread`), rather than Flask's development server. It
demonstrates the standard Flask "instance folder" pattern on a PVC, secure
cookie settings, and a `SECRET_KEY` managed as a Kubernetes Secret instead
of hardcoded in `config.py`.

## Architecture
```
Internet -> Ingress (nginx, TLS via cert-manager, path /flask) -> Service (ClusterIP:80)
          -> Deployment "flask-app" (2+ replicas, port 8000)
               command: gunicorn --bind=0.0.0.0:8000 --workers=4 --threads=2
                        --worker-class=gthread wsgi:app
               - FLASK_ENV/config from ConfigMap
               - SECRET_KEY from Secret
               - instance volume from PVC "flask-app-instance"
               -> egress -> Postgres in "database" namespace, port 5432 (optional)
```

## Prerequisites
- Kubernetes 1.27+
- ingress-nginx controller and cert-manager with `letsencrypt-prod` issuer
- A `gp3` StorageClass (see `../../manifests/storage/storageclass-examples.yaml`)
- An image at `your-registry/flask-app:1.0.0` with a `wsgi.py` exposing
  `app`, plus `GET /healthz` and `GET /readyz` routes
- gunicorn installed in the image (`pip install gunicorn`)

## Installation
```bash
kubectl create namespace flask --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n flask -f pvc.yaml
kubectl apply -n flask -f configmap.yaml
kubectl apply -n flask -f secret.yaml
kubectl apply -n flask -f deployment.yaml
kubectl apply -n flask -f service.yaml
kubectl apply -n flask -f ingress.yaml
kubectl apply -n flask -f hpa.yaml
kubectl apply -n flask -f pdb.yaml
kubectl apply -n flask -f networkpolicy.yaml
```

## Verification
```bash
kubectl rollout status deployment/flask-app -n flask
kubectl get pods -n flask -l app.kubernetes.io/name=flask-app
kubectl port-forward -n flask svc/flask-app 8080:80
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/readyz
curl -i https://app.example.com/flask/
```

## Configuration
| Setting | Location | Notes |
|---|---|---|
| FLASK_ENV, config class, cookie flags | `configmap.yaml` | non-secret only |
| gunicorn workers/threads/timeout | `deployment.yaml` `args` | 4 workers x 2 threads, 30s timeout |
| SECRET_KEY | `secret.yaml` | placeholder, MUST be replaced before real use |
| Instance folder size | `pvc.yaml` | 5Gi RWO |
| Autoscaling bounds | `hpa.yaml` | 2-10 replicas, CPU 70% |

## Security
- Non-root uid 1000, `readOnlyRootFilesystem: true`, all capabilities
  dropped, `allowPrivilegeEscalation: false`.
- `SESSION_COOKIE_SECURE`/`SESSION_COOKIE_HTTPONLY` set to `true` in
  `configmap.yaml` — cookies are never sent over plain HTTP and are
  inaccessible to JavaScript.
- `SECRET_KEY` is a placeholder (decodes to `changeme`); a weak session
  signing key allows forged sessions/CSRF tokens — generate a real one
  with `python -c "import secrets; print(secrets.token_hex(32))"` and seal
  it via `../../manifests/sealed-secrets` before any real deployment.
- `MAX_CONTENT_LENGTH` caps request body size (5MB) to reduce DoS surface
  from large uploads.
- NetworkPolicy restricts ingress to `ingress-nginx` only and egress to
  DNS + Postgres in the `database` namespace — no lateral movement to
  other services.

## Scaling
- HPA scales 2-10 replicas on 70% average CPU; requires metrics-server
  (`../../manifests/metrics-server`).
- gunicorn's `gthread` worker class handles moderate I/O concurrency per
  pod (4 workers x 2 threads = 8 concurrent requests/pod); for CPU-bound
  workloads switch to `sync` workers and rely more heavily on the HPA/pod
  count instead of in-process concurrency.
- PDB `minAvailable: 1` plus `maxUnavailable: 0` rolling updates ensure
  capacity never drops below serving level during drains/deploys.
- Sessions/instance data are per-pod (PVC is RWO) — do not rely on
  in-memory or local-disk session state if you plan to scale beyond a
  handful of replicas; use a shared session store (Redis) instead.

## Common Problems
- **502 Bad Gateway from Ingress**: gunicorn's `--timeout=30` killed a
  worker mid-request because it exceeded 30s — check
  `nginx.ingress.kubernetes.io/proxy-read-timeout` (set to 35s here,
  intentionally slightly higher) and raise gunicorn's `--timeout` if
  legitimate requests take longer.
- **Sessions invalidated on every rollout**: `SECRET_KEY` changed between
  deployments — keep it stable across rollouts (it's sealed/stored once,
  not regenerated per deploy) or accept that rolling it invalidates all
  active sessions.
- **`OSError: [Errno 13] Permission denied` writing to instance folder**:
  PVC's `fsGroup` doesn't match the pod's `securityContext.fsGroup: 1000`
  — check the StorageClass/CSI driver honors `fsGroup`.
- **Worker timeouts under load with `gthread`**: threads share the GIL for
  CPU-bound work — if request handlers are CPU-heavy (image processing,
  serialization), scale pod replicas via the HPA rather than increasing
  thread count.
- **HPA `<unknown>` targets**: metrics-server missing or CPU `requests`
  unset (set here) — verify with `kubectl top pods -n flask`.

## Best Practices
- Never run Flask's built-in development server (`flask run` /
  `app.run()`) in production — always front it with gunicorn (or uWSGI)
  as shown here.
- Keep `FLASK_DEBUG=0` in every non-local environment; the debugger allows
  arbitrary code execution if ever exposed.
- Store `SECRET_KEY` once per environment and keep it stable; rotate
  deliberately with a plan for session invalidation, not accidentally via
  redeploys.
- Prefer a real session backend (Redis, database-backed sessions) over
  filesystem/instance-folder session storage once you run more than one
  replica.

## Useful Commands
```bash
# Tail gunicorn access/error logs across all replicas
kubectl logs -n flask -l app.kubernetes.io/name=flask-app -f

# Check gunicorn worker processes inside a pod
kubectl exec -n flask deploy/flask-app -- ps aux

# Check current resource usage vs requests/limits
kubectl top pods -n flask -l app.kubernetes.io/name=flask-app

# Watch HPA decisions live
kubectl get hpa flask-app -n flask -w

# Force a rolling restart after a ConfigMap/Secret change
kubectl rollout restart deployment/flask-app -n flask
```

## References
- https://docs.gunicorn.org/en/stable/settings.html
- https://flask.palletsprojects.com/en/latest/config/
- https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- `../../manifests/metrics-server`
- `../../manifests/sealed-secrets`
