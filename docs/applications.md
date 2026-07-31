# Sample applications

`applications/` contains five reference workloads, each deployed the same way the rest of this repo expects: resource requests/limits, liveness/readiness probes, non-root `securityContext`, an `Ingress` through ingress-nginx, TLS via cert-manager, a scoped `NetworkPolicy`, and Prometheus scrape annotations.

| App | Path | Notes |
|---|---|---|
| nginx | `applications/nginx/` | Static content / reverse-proxy reference, simplest manifest set to start from |
| Node.js | `applications/nodejs/` | Exposes `/metrics` via `prom-client`, health checks on `/healthz`/`/readyz` |
| Python | `applications/python/` | Generic Python service (e.g. FastAPI/Flask-alternative) with `/metrics` via `prometheus-client` |
| Spring Boot | `applications/springboot/` | Uses Actuator's `/actuator/health` and `/actuator/prometheus` endpoints |
| Flask | `applications/flask/` | Minimal WSGI app behind gunicorn, `/metrics` via `prometheus_flask_exporter` |

## How they integrate with the rest of the stack

- **Ingress**: each app's `Ingress` uses the `nginx` `IngressClass` and a `cert-manager.io/cluster-issuer` annotation — see [`docs/networking.md`](networking.md).
- **DNS**: hostnames on the `Ingress` are picked up automatically by external-dns.
- **Monitoring**: each `Deployment`'s pod template carries `prometheus.io/scrape: "true"` (or a `ServiceMonitor`, if using the Prometheus Operator) so Prometheus discovers it without manual target configuration — see [`docs/monitoring.md`](monitoring.md).
- **Security**: each app ships a default-deny-friendly `NetworkPolicy` that only allows traffic from ingress-nginx and the monitoring namespace, plus whatever egress the app actually needs (e.g. a database) — see [`docs/security.md`](security.md).
- **Autoscaling**: apps reference an `HPA` template from `manifests/autoscaling/` scaling on CPU (and optionally custom metrics via Prometheus Adapter).

## Deploying a sample app

```bash
kubectl apply -f applications/nodejs/
kubectl -n <namespace> get pods,ingress
```

Confirm the `Ingress` gets an address, DNS resolves, TLS certificate is issued (`kubectl get certificate`), and the app shows up as a scrape target in Prometheus.

## Using these as a starting point

These are meant to be forked, not run as-is in production. Replace the container image, adjust resource sizing to your actual workload's profile (start from real load-test numbers, not guesses), and tighten the `NetworkPolicy` to the app's real dependency graph before shipping.

## Common problems

- 502 from ingress-nginx — readiness probe failing or app listening on the wrong port; check `kubectl describe ingress` and the `Service`'s `targetPort`.
- App not appearing in Prometheus targets — scrape annotation port mismatch, or the app's namespace lacks the label the `ServiceMonitor`'s `namespaceSelector` expects.
- `NetworkPolicy` blocking legitimate traffic — temporarily test in audit/log mode (if your CNI supports it) before enforcing.
