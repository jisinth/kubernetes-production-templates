# Autoscaling

## What is this?

Four complementary autoscaling mechanisms for different layers of the
stack:

- **HPA** (`HorizontalPodAutoscaler`, built into Kubernetes) — adds/removes
  **pod replicas** based on CPU/memory utilization or custom metrics.
- **VPA** (`VerticalPodAutoscaler`, separate controller) — adjusts a pod's
  CPU/memory **requests and limits** based on observed usage, rather than
  its replica count.
- **Cluster Autoscaler** — adds/removes **nodes** in the underlying cloud
  provider's node group/ASG/VMSS based on unschedulable pods and node
  idle time.
- **KEDA** (`ScaledObject`, separate controller) — extends HPA-style
  scaling to **arbitrary event sources and custom metrics** (queue depth, a
  Prometheus query, Kafka lag, cron schedules), including scale-to-zero,
  which plain HPA cannot do.

This folder has one example of each, covering the full stack from "not
enough pods" to "not enough nodes to run more pods."

## Architecture

```
   Cloud provider (ASG / VMSS / MIG)
        ▲
        │ add/remove nodes when pods are unschedulable / nodes are idle
        │
   Cluster Autoscaler
        ▲
        │ pods Pending due to insufficient node capacity
        │
   ┌────┴──────────────────────────────────────────────┐
   │                    Kubernetes cluster               │
   │                                                      │
   │   HPA ──scales replicas──▶ Deployment ◀──scales requests/limits── VPA │
   │    ▲                                                      │
   │    │ CPU/memory metrics-server, or                        │
   │    │ custom/external metrics                              │
   │    │                                                       │
   │   KEDA ──creates & manages an HPA──▶ (same Deployment,     │
   │    │                                  scale-to-zero capable)│
   │    └── polls external sources: Prometheus, queues, cron   │
   └──────────────────────────────────────────────────────┘
```

KEDA doesn't replace HPA — it creates and manages an HPA object on your
behalf (`keda-hpa-<scaledobject-name>`), translating external metrics into
the same `autoscaling/v2` API HPA already understands, then adds
scale-to-zero as a layer HPA alone can't provide (HPA's `minReplicas`
floor is always >= 1).

## Prerequisites

- **HPA**: `metrics-server` installed and healthy
  (`manifests/metrics-server/`) for CPU/memory metrics.
- **VPA**: the VPA CRDs and controllers (`vpa-updater`,
  `vpa-recommender`, `vpa-admission-controller`) installed — not bundled
  with core Kubernetes.
- **Cluster Autoscaler**: cloud IAM permissions to describe/resize the
  node group (IRSA on EKS, a managed identity on AKS, a service account on
  GKE — though GKE users should generally prefer the built-in
  autoscaler over self-hosting this chart, see the values file).
- **KEDA**: the KEDA CRDs and operator installed, plus network access from
  KEDA to whatever external system (Prometheus, a broker, a cloud API) the
  chosen scaler queries.

## Installation

```bash
# HPA — no separate install, just apply against a running Deployment
kubectl apply -f manifests/autoscaling/hpa-example.yaml

# VPA — install the controller once per cluster
git clone https://github.com/kubernetes/autoscaler
./autoscaler/vertical-pod-autoscaler/hack/vpa-up.sh
kubectl apply -f manifests/autoscaling/vpa-example.yaml

# Cluster Autoscaler
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system -f manifests/autoscaling/cluster-autoscaler-values.yaml

# KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm upgrade --install keda kedacore/keda -n keda --create-namespace
kubectl apply -f manifests/autoscaling/keda-scaledobject-example.yaml
```

## Verification

```bash
# HPA: current vs. target utilization and replica count
kubectl get hpa web-app-hpa -w

# VPA: recommendation the controller has computed
kubectl describe vpa batch-worker-vpa | grep -A 12 Recommendation

# Cluster Autoscaler: watch scale-up/down decisions in logs
kubectl -n kube-system logs deploy/cluster-autoscaler -f | grep -i scale

# KEDA: confirm it created the underlying HPA and see current metric value
kubectl get scaledobject order-processor-scaledobject
kubectl get hpa keda-hpa-order-processor-scaledobject -w

# Load-test to trigger a real scale event
kubectl run load-gen --image=busybox --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://web-app; done"
```

## Configuration

- **`hpa-example.yaml`** — CPU (70%) + memory (80%) targets, asymmetric
  scale-up/scale-down `behavior` (fast up, slow down) to avoid flapping.
- **`vpa-example.yaml`** — `updateMode: Auto` with `minAllowed`/
  `maxAllowed` guardrails so VPA can't recommend absurdly small or large
  requests; targets a different Deployment than the HPA example
  deliberately (see Common Problems).
- **`cluster-autoscaler-values.yaml`** — AWS placeholder
  (`cloudProvider: aws`, IRSA role ARN, ASG tag-based `autoDiscovery`) with
  inline comments for the Azure/GCP equivalents.
- **`keda-scaledobject-example.yaml`** — Prometheus scaler querying a
  RabbitMQ queue-depth metric, with `idleReplicaCount: 0` enabling
  scale-to-zero and a 5-minute `cooldownPeriod` before scaling back down.

## Security

- **Cluster Autoscaler's cloud credentials should be scoped to exactly the
  node groups it manages** — `autoscaling:SetDesiredCapacity` and
  `autoscaling:TerminateInstanceInAutoScalingGroup` on account-wide `*`
  resources lets a compromised pod (if the role is over-mounted) resize or
  kill unrelated ASGs. Use IRSA/Workload Identity scoped to tagged ASGs
  only, as shown in `cluster-autoscaler-values.yaml`.
- **VPA's `updateMode: Auto` evicts and recreates pods** — make sure a
  PodDisruptionBudget exists for anything VPA manages in `Auto` mode, or a
  VPA-triggered eviction can violate your own availability guarantees
  during a legitimate resize.
- **KEDA's Prometheus/external scalers may need credentials to reach the
  metric source** — store those in a Secret referenced by
  `triggers[].authenticationRef`, not inlined in the `ScaledObject`.
- **Don't let HPA/VPA/KEDA collectively bypass ResourceQuota** — a runaway
  scale-up (bad metric, misconfigured threshold) can still exhaust a
  namespace's or cluster's quota; keep `maxReplicaCount`/`maxReplicas` and
  Cluster Autoscaler's overall max-node bounds as hard ceilings.

## Scaling

(Yes, this section is about how these scaling mechanisms themselves scale
and interact.)

- **HPA polls metrics-server every 15s by default** (`--horizontal-pod-
  autoscaler-sync-period` on the controller-manager) — for faster reaction
  under bursty load, this is a cluster-wide controller-manager flag, not
  per-HPA.
- **VPA and HPA must not both control the same resource dimension on the
  same workload.** If HPA scales on CPU utilization and VPA (`Auto`) is
  also changing that container's CPU *requests*, the utilization
  percentage HPA reads shifts every time VPA acts, causing oscillation.
  Either scope VPA to `controlledResources: [memory]` only when HPA
  already covers CPU, or use VPA's `updateMode: Off` (recommendations
  only) on any workload HPA already scales.
- **Cluster Autoscaler reacts to Pending pods, so HPA/KEDA scale-outs that
  outpace node availability show up as a temporary Pending backlog** — set
  `max-node-provision-time` generously enough for your cloud's actual
  instance boot time, and consider over-provisioning a small buffer
  (a low-priority "placeholder" Deployment) to keep spare capacity warm for
  latency-sensitive scale-out.
- **KEDA scales to zero, Cluster Autoscaler doesn't scale nodes to zero on
  its own** unless every pod on a node is gone and
  `scale-down-unneeded-time` elapses — for spiky, bursty workloads that
  need true zero-to-N-to-zero economics, pair KEDA with a dedicated,
  taint-isolated node group so Cluster Autoscaler can cleanly drain it.

## Common Problems

- **HPA shows `<unknown>` for current metrics** — `metrics-server` isn't
  installed, isn't healthy, or the target Deployment's pods don't declare
  CPU/memory `requests` (HPA's utilization percentage is requests-relative
  — no requests, no percentage to compute). Fix: confirm
  `kubectl top pods` works at all first.
- **HPA and VPA(Auto) fight, replica count and pod size oscillate
  together** — see the Scaling section above; this is the single most
  common HPA/VPA misconfiguration. Split responsibility: HPA on CPU, VPA
  restricted to memory only (or VPA in `Off`/recommendation mode).
- **Cluster Autoscaler won't scale up despite Pending pods** — the ASG/node
  group isn't tagged for autodiscovery
  (`k8s.io/cluster-autoscaler/enabled=true` and
  `k8s.io/cluster-autoscaler/<cluster-name>=owned` on AWS), or the pod's
  node affinity/taints don't match any autoscaling group's node template.
  Check `kubectl -n kube-system logs deploy/cluster-autoscaler` for
  `NoScaleUpReason` events.
- **Cluster Autoscaler won't scale down an underused node** —
  `scale-down-utilization-threshold` not yet crossed, or a pod on that
  node blocks eviction (no controller owner, local storage, or a
  restrictive PDB with `maxUnavailable: 0`). Autoscaler logs the specific
  blocking reason per node.
- **KEDA `ScaledObject` shows `False` for `Active`/`ScalingActive`
  condition** — the query returned no data or an error; test the exact
  PromQL from `triggers[].metadata.query` directly against Prometheus
  first (`serverAddress` typos are the most common cause).
- **KEDA and a hand-written HPA both target the same Deployment** — this
  produces two competing HPAs; delete the hand-written HPA once KEDA
  manages the target, or KEDA's own `keda-hpa-*` object will conflict with
  it.

## Best Practices

- Set `resources.requests` on every container — HPA's CPU/memory
  percentages and VPA's recommendations are both meaningless without them.
- Always set a `maxReplicas`/`maxReplicaCount` ceiling, even a generous
  one — the failure mode of "no ceiling" is a cost/quota incident, not
  just a scaling inefficiency.
- Prefer KEDA over hand-rolled custom-metrics-adapter setups for anything
  beyond CPU/memory — it has a large library of maintained scalers
  (Prometheus, SQS, Kafka, RabbitMQ, cron, etc.) instead of a bespoke
  metrics pipeline.
- Pair Cluster Autoscaler with PodDisruptionBudgets on every workload — a
  scale-down operation drains nodes via normal eviction, and a missing PDB
  means Autoscaler can (correctly, per its contract) evict all replicas of
  something at once.
- Use `behavior` stanzas (HPA) and `advanced.horizontalPodAutoscalerConfig`
  (KEDA) to bias toward fast scale-up / slow scale-down — over-scaling
  briefly is cheap, thrashing replica counts is not.
- Test autoscaling behavior under synthetic load before trusting it in
  production incidents — an HPA/KEDA config that's never fired for real is
  an assumption, not a verified capability.

## Useful Commands

```bash
# Watch HPA decisions live
kubectl get hpa -A -w

# Force-refresh metrics-server data (useful when debugging <unknown>)
kubectl top pods -A

# See VPA's computed recommendation without waiting for the next eviction
kubectl describe vpa batch-worker-vpa

# List Cluster Autoscaler's view of node groups
kubectl -n kube-system exec deploy/cluster-autoscaler -- \
  cluster-autoscaler --help >/dev/null; \
kubectl -n kube-system logs deploy/cluster-autoscaler | grep -i "node group"

# List all KEDA ScaledObjects and their active/ready status
kubectl get scaledobject -A

# Manually pause a KEDA ScaledObject (freeze at current replica count)
kubectl annotate scaledobject order-processor-scaledobject \
  autoscaling.keda.sh/paused-replicas="5" --overwrite
```

## References

- [Horizontal Pod Autoscaler](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HPA v2 API walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
- [Vertical Pod Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler)
- [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
- [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
- [KEDA documentation](https://keda.sh/docs/latest/)
- [KEDA scalers reference](https://keda.sh/docs/latest/scalers/)
