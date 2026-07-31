# EKS (Amazon Elastic Kubernetes Service)

## Prerequisites

- AWS CLI v2, configured (`aws configure` or SSO) with sufficient IAM permissions
- [`eksctl`](https://eksctl.io/) and `kubectl`/`helm` installed
- An existing VPC or willingness to let `eksctl` create one

## Create the cluster

```bash
eksctl create cluster \
  --name <CLUSTER_NAME> \
  --region us-east-1 \
  --zones us-east-1a,us-east-1b,us-east-1c \
  --version 1.29 \
  --nodegroup-name default \
  --node-type m6i.large \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 6 \
  --managed \
  --with-oidc
```

`--with-oidc` is required for IRSA (IAM Roles for Service Accounts), used heavily below.

```bash
aws eks update-kubeconfig --name <CLUSTER_NAME> --region us-east-1
```

## Provider-specific notes

- **IRSA for external-dns and cert-manager**: create dedicated IAM roles scoped to Route53 (`route53:ChangeResourceRecordSets` on the specific hosted zone) and bind them to each controller's `ServiceAccount` via `eksctl create iamserviceaccount` or Terraform. Avoid static AWS access keys entirely — this is the main reason `--with-oidc` matters.
- **LoadBalancer**: install the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) (also needs IRSA) if you want NLB/ALB-backed `Service`/`Ingress` objects instead of the classic ELB that ingress-nginx's `Service` provisions by default.
- **Storage**: default `StorageClass` uses `ebs.csi.aws.com`. Prefer `gp3` over `gp2` (better baseline IOPS/throughput at lower cost); the EBS CSI driver add-on must be enabled (`eksctl create addon --name aws-ebs-csi-driver`).
- **Autoscaling**: use Cluster Autoscaler or Karpenter; Karpenter is recommended for mixed instance types and faster scale-up.
- **Cost**: EKS control plane is billed hourly regardless of node count — factor that into dev/test cluster teardown habits (`eksctl delete cluster`).

## Install the stack

```bash
./scripts/install.sh
```

Update `helm-values/external-dns/values.yaml` and `helm-values/cert-manager/values.yaml` with the IRSA role ARNs annotated on their `ServiceAccount`s before installing those phases.

## Verification

```bash
kubectl get nodes -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller
aws sts get-caller-identity
```

Confirm the ELB/NLB is provisioned and DNS records begin appearing in Route53 once `manifests/external-dns/` is applied.
