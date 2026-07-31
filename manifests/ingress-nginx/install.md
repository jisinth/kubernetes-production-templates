# Installing ingress-nginx

Step-by-step walkthrough for installing the ingress-nginx controller via Helm using the values in this repo. This is the path used by `scripts/install.sh`; follow it manually if you want to install just this component.

## 1. Add the Helm repo

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

## 2. Create the namespace

If you've already applied `manifests/namespace/`, use one of those namespaces, or create a dedicated `ingress-nginx` namespace for the controller itself (recommended — keep infra add-ons out of application namespaces):

```bash
kubectl create namespace ingress-nginx
```

## 3. Review the values file

Open [`helm-values/ingress-nginx.yaml`](../../helm-values/ingress-nginx.yaml) (identical to [`values.yaml`](values.yaml) in this folder) and adjust before installing:

- `controller.service.annotations` — uncomment the block matching your cloud provider (AWS NLB, GCP, Azure) so the LoadBalancer Service provisions the right kind of external load balancer.
- `controller.replicaCount` / `controller.autoscaling` — size for your traffic; 3 replicas is the minimum for HA across zones.
- `controller.metrics.serviceMonitor.enabled` — requires the Prometheus Operator CRDs to already be installed (see `manifests/prometheus/`); set to `false` if you haven't installed Prometheus yet, or install order will fail.

## 4. Install

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f helm-values/ingress-nginx.yaml \
  --wait --timeout 5m
```

`--wait` blocks until the Deployment's pods are ready and the admission webhook Job has completed — don't skip it in CI, since Ingress objects applied before the webhook is ready will fail validation.

## 5. Wait for the external IP

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx -w
```

Cloud LoadBalancer provisioning typically takes 30 seconds to a few minutes. Once `EXTERNAL-IP` is populated, point your DNS (manually, or via `manifests/external-dns/`) at it.

## 6. Verify the IngressClass

```bash
kubectl get ingressclass
```

You should see `nginx` marked as the default. If you're not using the Helm chart's `ingressClassResource`, apply the standalone one instead:

```bash
kubectl apply -f manifests/ingress-nginx/ingressclass.yaml
```

## 7. Smoke test

Deploy a sample app and Ingress:

```bash
kubectl create deployment demo --image=nginx -n default
kubectl expose deployment demo --port=80 -n default
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
  namespace: default
spec:
  ingressClassName: nginx
  rules:
    - host: demo.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo
                port:
                  number: 80
EOF

curl -H "Host: demo.example.com" http://<EXTERNAL-IP>/
```

## 8. Next steps

- Install `cert-manager` (`manifests/cert-manager/`) and add a `cert-manager.io/cluster-issuer` annotation plus `spec.tls` to your Ingress objects to get automatic TLS.
- Install `external-dns` (`manifests/external-dns/`) so Ingress `host` fields automatically create DNS records instead of manual pointing.

## Uninstall

```bash
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx
```

Note: this leaves the cloud LoadBalancer's DNS/health-check config as-is until the cloud provider reclaims it — check your cloud console if you need to confirm teardown.
