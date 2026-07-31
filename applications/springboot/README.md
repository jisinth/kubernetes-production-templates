# Spring Boot Service

## What is this?
A production reference for a Spring Boot service with Actuator-based
liveness/readiness probes, JVM heap sizing tuned to the container memory
limit, graceful shutdown, and Prometheus metrics scraping via
`/actuator/prometheus`. It connects to a relational database (Postgres or
MySQL) in a separate namespace.

## Architecture
```
Internet -> Ingress (nginx, TLS via cert-manager, path /svc,
            blocks non-health /actuator/** at the ingress layer)
          -> Service (ClusterIP:80)
          -> Deployment "springboot-app" (2+ replicas, port 8080)
               - SPRING_PROFILES_ACTIVE, management endpoints from ConfigMap
               - application-overrides.yaml mounted at /config (additional Spring config location)
               - datasource credentials from Secret
               - logs volume from PVC "springboot-app-logs"
               -> egress -> Postgres/MySQL in "database" namespace, 5432/3306
          <- ingress -> Prometheus in "monitoring" namespace scrapes :8080/actuator/prometheus
```

## Prerequisites
- Kubernetes 1.27+
- ingress-nginx controller and cert-manager with `letsencrypt-prod` issuer
- A `database` namespace running Postgres or MySQL
- A `monitoring` namespace with Prometheus labeled
  `app.kubernetes.io/name: prometheus` (matches `networkpolicy.yaml`) —
  see `../../manifests/prometheus`
- A `gp3` StorageClass (see `../../manifests/storage/storageclass-examples.yaml`)
- Spring Boot 3.x image with `spring-boot-actuator` and
  `management.endpoint.health.probes.enabled=true`

## Installation
```bash
kubectl create namespace svc --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n svc -f pvc.yaml
kubectl apply -n svc -f configmap.yaml
kubectl apply -n svc -f secret.yaml
kubectl apply -n svc -f deployment.yaml
kubectl apply -n svc -f service.yaml
kubectl apply -n svc -f ingress.yaml
kubectl apply -n svc -f hpa.yaml
kubectl apply -n svc -f pdb.yaml
kubectl apply -n svc -f networkpolicy.yaml
```

## Verification
```bash
kubectl rollout status deployment/springboot-app -n svc
kubectl get pods -n svc -l app.kubernetes.io/name=springboot-app
kubectl port-forward -n svc svc/springboot-app 8080:80
curl -s http://localhost:8080/actuator/health/liveness
curl -s http://localhost:8080/actuator/health/readiness
curl -s http://localhost:8080/actuator/prometheus | head
```

## Configuration
| Setting | Location | Notes |
|---|---|---|
| Active profiles, actuator exposure | `configmap.yaml` | `production,kubernetes` |
| Tomcat threads, graceful shutdown, JPA batching | `configmap.yaml` (`application-overrides.yaml`) | mounted at `/config` |
| Datasource URL/username/password | `secret.yaml` | placeholder, replace before real use |
| JVM heap sizing | `deployment.yaml` `JAVA_TOOL_OPTIONS` | `MaxRAMPercentage=70.0` against a 1536Mi limit |
| Logs volume size | `pvc.yaml` | 10Gi RWO |
| Autoscaling bounds | `hpa.yaml` | 2-10 replicas, CPU 70%, conservative scale-down |

## Security
- Non-root uid 1000, `readOnlyRootFilesystem: true` (JVM tmp/scratch goes
  to the `/tmp` emptyDir), all capabilities dropped.
- Actuator is exposed only on the same port as the app (`8080`); the
  Ingress blocks every `/actuator/**` path except `/actuator/health` via
  an nginx `server-snippet`, and `MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE`
  is scoped to `health,info,prometheus` only (no `/actuator/env`,
  `/actuator/beans`, etc.).
- NetworkPolicy allows ingress only from `ingress-nginx` (app traffic) and
  `monitoring` (Prometheus scraping) — nothing else can reach port 8080.
- Datasource credentials are placeholders; replace with values sealed via
  `../../manifests/sealed-secrets` or synced through external-secrets.
- `management.endpoint.health.show-details: when-authorized` prevents
  leaking downstream dependency details (DB host, etc.) to unauthenticated
  callers.

## Scaling
- HPA targets 70% CPU, but uses a longer stabilization window on scale-down
  (600s) than the other apps in this repo because JVM warmup (class
  loading, JIT compilation) makes new pods expensive — avoid flapping.
- Requires metrics-server (`../../manifests/metrics-server`).
- `startupProbe` gives the JVM up to 120s (24 x 5s) to become live before
  liveness probes start counting failures — increase `failureThreshold` if
  your app context takes longer to initialize (large bean graphs, Flyway
  migrations, etc.).
- PDB `minAvailable: 1` combined with `maxUnavailable: 0` rolling updates
  and `terminationGracePeriodSeconds: 60` gives in-flight requests time to
  drain during graceful shutdown (`server.shutdown: graceful`).

## Common Problems
- **Pod killed before finishing startup**: `startupProbe.failureThreshold`
  too low for your app's actual boot time — check
  `kubectl logs -n svc <pod> --previous` for the last log line before
  `SIGTERM`/`SIGKILL` and compare to your app's typical "Started
  Application in Ns" log line.
- **OOMKilled despite `MaxRAMPercentage=70.0`**: metaspace, thread stacks
  (`Xss` x thread count), or off-heap buffers (e.g. Netty, JDBC drivers)
  consuming the remaining 30% — profile with
  `kubectl exec -n svc <pod> -- jcmd 1 VM.native_memory summary` or raise
  the memory limit.
- **Readiness never becomes true**: `/actuator/health/readiness` includes
  a `db` health indicator by default — check datasource connectivity and
  that the NetworkPolicy egress rule matches the actual DB namespace/port.
- **`/actuator/prometheus` returns 404 through the Ingress**: the
  server-snippet only allow-lists `/actuator/health` — reach Prometheus
  metrics via the Service directly (as Prometheus does, in-cluster), not
  through the public Ingress.
- **Slow rolling updates**: JVM apps take longer to become ready than
  interpreted-language apps; tune `readinessProbe.initialDelaySeconds` and
  `startupProbe.failureThreshold` rather than reducing `maxSurge`.

## Best Practices
- Always size `-XX:MaxRAMPercentage` against the container memory *limit*,
  never assume host memory — the JVM respects cgroup limits since JDK 10+
  when running containerized.
- Split liveness (process/deadlock detection) from readiness (dependency
  health) using Spring Boot's health groups — never let a flaky downstream
  dependency trigger container restarts via liveness.
- Keep `management.endpoints.web.exposure.include` to the minimum needed;
  never expose `env`, `beans`, `heapdump`, `threaddump`, or `shutdown`
  outside a locked-down internal network.
- Use `server.shutdown: graceful` with a `terminationGracePeriodSeconds`
  that comfortably exceeds `spring.lifecycle.timeout-per-shutdown-phase`.

## Useful Commands
```bash
# Tail logs across all replicas
kubectl logs -n svc -l app.kubernetes.io/name=springboot-app -f

# Check actuator health directly inside a pod
kubectl exec -n svc deploy/springboot-app -- \
  wget -qO- http://localhost:8080/actuator/health | jq .

# Inspect JVM heap/memory usage live
kubectl exec -n svc deploy/springboot-app -- jcmd 1 GC.heap_info

# Check current resource usage vs requests/limits
kubectl top pods -n svc -l app.kubernetes.io/name=springboot-app

# Force a rolling restart after a ConfigMap/Secret change
kubectl rollout restart deployment/springboot-app -n svc
```

## References
- https://docs.spring.io/spring-boot/reference/actuator/endpoints.html
- https://docs.spring.io/spring-boot/reference/web/graceful-shutdown.html
- https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- `../../manifests/prometheus`
- `../../manifests/sealed-secrets`
