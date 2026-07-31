# Troubleshooting

Common failure modes across the stack, grouped by area. Each component's own README (under `manifests/<component>/`) has a more detailed "Common Problems" section — this page is the cross-cutting index.

## Ingress / TLS (`manifests/ingress-nginx/`, `manifests/cert-manager/`)

- **502/504 from the load balancer**: check the ingress-nginx controller pods are `Running` and the backend `Service`/pod is passing its readiness probe. `kubectl -n ingress-nginx logs deploy/ingress-nginx-controller`.
- **Certificate stuck in `Pending`**: `kubectl describe certificate <name>` and `kubectl describe certificaterequest` — usually an ACME challenge failing because DNS-01 credentials are wrong or HTTP-01 can't reach the pod through the LB yet.
- **`ERR_CERT_AUTHORITY_INVALID` in browser**: confirm you're using a production `ClusterIssuer`, not the Let's Encrypt staging issuer.

## DNS (`manifests/external-dns/`)

- **Record not created**: check external-dns logs (`kubectl -n external-dns logs deploy/external-dns`) for permission errors — the most common cause is an IAM/Managed Identity/Workload Identity binding scoped to the wrong zone.
- **Stale record after Ingress change**: external-dns runs on a poll interval (default ~1m); also check `--policy` isn't set to `upsert-only` if you expect deletions to propagate.

## Observability (`manifests/prometheus/`, `manifests/loki/`, `manifests/tempo/`, `manifests/grafana/`, `manifests/alertmanager/`)

- **Prometheus `OOMKilled`**: check cardinality (`prometheus_tsdb_symbol_table_size_bytes`, active series count) before just raising the memory limit — a label with unbounded values (like a raw user ID) is the usual culprit.
- **Grafana panel "No data"**: confirm the data source URL/auth in `manifests/grafana/datasources/`, then check the underlying Prometheus/Loki/Tempo query directly via their own UI/API.
- **Alertmanager not paging**: verify the `PrometheusRule` label set matches the route's `matchers` exactly — a typo'd label is the most common silent failure.

## GitOps (`manifests/argocd/`)

- **`Application` stuck `OutOfSync`**: run `argocd app diff <app>` to see the exact drifted fields; a mutating webhook (Kyverno) is a common cause — add to `ignoreDifferences`.
- **Sync fails on CRDs**: apply CRDs in a separate `Application`/sync-wave before the resources that depend on them (`argocd.argoproj.io/sync-wave` annotation).

## Security (`manifests/kyverno/`, `manifests/network-policy/`, `manifests/pod-security/`, `manifests/sealed-secrets/`)

- **New workload rejected by admission**: `kubectl get events` and check for a Kyverno policy denial message — start new policies in `audit` mode to avoid surprise outages.
- **Pod can't resolve DNS after default-deny NetworkPolicy applied**: add an explicit egress allow rule to kube-system UDP/TCP 53 before enforcing default-deny (see [`docs/networking.md`](networking.md#network-policy)).
- **SealedSecret won't decrypt**: it was sealed against a different controller instance/key (e.g. a re-installed cluster) — reseal against the current controller's public cert.

## Backup/DR (`manifests/velero/`)

- **Backup stuck `InProgress`**: check the Velero pod logs and object storage bucket permissions; a hung backup is almost always a storage credential or network egress problem.
- **Restore doesn't bring back PVC data**: confirm the CSI snapshot plugin was enabled at backup time — a plain Velero backup without the CSI plugin only captures Kubernetes objects, not volume contents.

## General diagnostics

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -50
kubectl top pods -A
kubectl -n <ns> describe pod <pod>
```

If a component won't come up at all, check `kubectl -n <ns> get pods` for `ImagePullBackOff` (registry/tag typo) before assuming a config problem.
