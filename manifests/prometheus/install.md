# Installing kube-prometheus-stack

Step-by-step walkthrough for standing up Prometheus + Alertmanager + the
Prometheus Operator via the `kube-prometheus-stack` Helm chart, using the
values checked into this repo.

## 1. Add the Helm repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

## 2. Create the namespace

```bash
kubectl create namespace monitoring
```

## 3. Review the values file

This repo ships two copies of the same values, kept in sync:

- `manifests/prometheus/values.yaml` — the annotated source of truth, lives
  next to the rest of the Prometheus manifests.
- `helm-values/prometheus.yaml` — the canonical copy referenced by
  `scripts/install.sh` and CI.

Open `helm-values/prometheus.yaml` and adjust at minimum:

- `prometheus.prometheusSpec.storageSpec` — storage class name for your
  cluster (`gp3` is an EKS/EBS example; use `standard`, `premium-rwo`, etc.
  on GKE/AKS).
- `prometheus.prometheusSpec.retention` / `retentionSize` — how much local
  history you need before remote-write/long-term storage takes over.
- `prometheus.prometheusSpec.resources` — size to your node pool.

## 4. Install (or upgrade) the chart

```bash
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values helm-values/prometheus.yaml \
  --version 62.x  # pin a chart version; check `helm search repo -l` for latest
```

## 5. Apply the ServiceMonitor and rules

The chart only installs the Operator and its own default rules — your own
alert/recording rules and ServiceMonitors are applied separately so they can
be versioned and reviewed independently of the chart upgrade cycle:

```bash
kubectl apply -f manifests/prometheus/service-monitor.yaml
kubectl apply -f manifests/prometheus/alert-rules.yaml
kubectl apply -f manifests/prometheus/recording-rules.yaml
```

## 6. Verify

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
kubectl get prometheusrules -n monitoring
kubectl get servicemonitors -A

# Port-forward and check targets/rules loaded correctly
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# then open http://localhost:9090/targets and http://localhost:9090/rules
```

## 7. Uninstall

```bash
helm uninstall kube-prometheus-stack -n monitoring
# CRDs are NOT removed by helm uninstall — clean them up explicitly if you're
# fully decommissioning the Operator (this deletes ALL PrometheusRule/
# ServiceMonitor/Alertmanager objects cluster-wide, so be certain first):
# kubectl delete crd -l app.kubernetes.io/part-of=kube-prometheus-stack
```

See `manifests/prometheus/README.md` for architecture, troubleshooting, and
day-2 operational guidance.
