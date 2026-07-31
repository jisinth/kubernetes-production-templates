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

## Production hardening

- **Private/restricted API endpoint**: `eksctl utils update-cluster-endpoints --private-access=true --public-access=true --public-access-cidrs="<office-cidr>/32"` restricts the public API endpoint to known CIDRs, or disable public access entirely for a fully private cluster reachable only via VPN/Direct Connect/bastion.
- **Node pool separation**: run a small dedicated managed node group for system add-ons (CoreDNS, metrics-server, ingress-nginx) separate from application node groups, using taints/tolerations — protects control-plane-adjacent workloads from application-driven autoscaling churn.
- **EKS access entries over `aws-auth` ConfigMap**: modern EKS clusters should use [access entries](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html) (`aws eks create-access-entry`) to map IAM principals to Kubernetes RBAC instead of hand-editing the legacy `aws-auth` ConfigMap — less error-prone and auditable via CloudTrail.
- **Managed control-plane upgrades**: EKS control-plane version upgrades (`eksctl upgrade cluster`) are independent of node group upgrades; upgrade the control plane first, validate, then roll node groups (`eksctl upgrade nodegroup`) — Kubernetes' version skew policy (nodes up to 2 minor versions behind control plane) still applies and eksctl won't enforce it for you.
- **Cost controls**: Karpenter or a Spot-backed managed node group for interruptible workloads; remember the EKS control plane itself bills hourly regardless of node count, so tear down dev/test clusters (`eksctl delete cluster`) rather than just scaling nodes to zero.

## Multi-cluster & disaster recovery

- **Cross-region DR**: provision a second EKS cluster in a different AWS region, replicate the Velero S3 bucket cross-region (S3 Cross-Region Replication or a second `BackupStorageLocation` pointed at a bucket in the DR region) — see [`../../manifests/velero/README.md`](../../manifests/velero/README.md) and [`../../manifests/backup/README.md`](../../manifests/backup/README.md) for restore mechanics and DR posture (backup-only vs. pilot-light vs. warm standby).
- **GitOps fan-out**: one Argo CD instance can manage both clusters via registered cluster credentials and an `ApplicationSet` cluster generator, or run Argo CD per-cluster synced from the same repo — see [`docs/gitops.md`](../../docs/gitops.md#applicationsets-for-multi-environmentmulti-cluster-fan-out).
- **IRSA is per-cluster**: IAM roles trusted via OIDC are bound to a specific cluster's OIDC provider URL — a DR cluster needs its own IRSA role setup (`eksctl create iamserviceaccount` against the new cluster), it cannot simply reuse the primary cluster's role trust policy as-is.
