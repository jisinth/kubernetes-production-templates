#!/usr/bin/env bash
#
# install.sh - install the kubernetes-production-templates stack in order.
#
# Phases (in order): namespaces -> ingress-nginx -> cert-manager -> external-dns
#   -> metrics-server -> observability (prometheus/grafana/loki/tempo/alertmanager)
#   -> argocd -> security (kyverno/network-policy/pod-security/sealed-secrets)
#
# Usage:
#   ./scripts/install.sh [flags]
#
# Flags:
#   --skip-namespaces       Skip namespace bootstrap
#   --skip-ingress          Skip ingress-nginx
#   --skip-cert-manager     Skip cert-manager
#   --skip-external-dns     Skip external-dns
#   --skip-metrics-server   Skip metrics-server
#   --skip-observability    Skip prometheus/grafana/loki/tempo/alertmanager
#   --skip-argocd           Skip ArgoCD
#   --skip-security         Skip kyverno/network-policy/pod-security/sealed-secrets
#   -h, --help              Show this help
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="${REPO_ROOT}/manifests"
VALUES="${REPO_ROOT}/helm-values"

SKIP_NAMESPACES=false
SKIP_INGRESS=false
SKIP_CERT_MANAGER=false
SKIP_EXTERNAL_DNS=false
SKIP_METRICS_SERVER=false
SKIP_OBSERVABILITY=false
SKIP_ARGOCD=false
SKIP_SECURITY=false

log() { printf '\n[install] %s\n' "$*"; }

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed -e '1d' -e 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-namespaces) SKIP_NAMESPACES=true ;;
    --skip-ingress) SKIP_INGRESS=true ;;
    --skip-cert-manager) SKIP_CERT_MANAGER=true ;;
    --skip-external-dns) SKIP_EXTERNAL_DNS=true ;;
    --skip-metrics-server) SKIP_METRICS_SERVER=true ;;
    --skip-observability) SKIP_OBSERVABILITY=true ;;
    --skip-argocd) SKIP_ARGOCD=true ;;
    --skip-security) SKIP_SECURITY=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found in PATH" >&2; exit 1; }
}

require_helm() {
  command -v helm >/dev/null 2>&1 || { echo "helm not found in PATH" >&2; exit 1; }
}

apply_dir() {
  local dir="$1"
  if [[ -d "$dir" ]] && find "$dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | grep -q .; then
    kubectl apply -f "$dir"
  else
    log "No manifests found in $dir, skipping kubectl apply"
  fi
}

helm_upgrade() {
  local release="$1" chart="$2" namespace="$3" values="$4"
  local extra_args=()
  if [[ -f "$values" ]]; then
    extra_args+=(-f "$values")
  fi
  helm upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace \
    "${extra_args[@]}"
}

require_kubectl

log "Cluster context: $(kubectl config current-context 2>/dev/null || echo 'unknown')"

# --- Phase 1: Cluster Setup ---

if [[ "$SKIP_NAMESPACES" == false ]]; then
  log "Phase: namespaces"
  apply_dir "${MANIFESTS}/namespace"
else
  log "Skipping namespaces"
fi

if [[ "$SKIP_INGRESS" == false ]]; then
  log "Phase: ingress-nginx"
  require_helm
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update ingress-nginx >/dev/null 2>&1 || true
  helm_upgrade ingress-nginx ingress-nginx/ingress-nginx ingress-nginx "${VALUES}/ingress-nginx/values.yaml"
  apply_dir "${MANIFESTS}/ingress-nginx"
else
  log "Skipping ingress-nginx"
fi

if [[ "$SKIP_CERT_MANAGER" == false ]]; then
  log "Phase: cert-manager"
  require_helm
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null 2>&1 || true
  helm_upgrade cert-manager jetstack/cert-manager cert-manager "${VALUES}/cert-manager/values.yaml"
  apply_dir "${MANIFESTS}/cert-manager"
else
  log "Skipping cert-manager"
fi

if [[ "$SKIP_EXTERNAL_DNS" == false ]]; then
  log "Phase: external-dns"
  require_helm
  helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
  helm repo update external-dns >/dev/null 2>&1 || true
  helm_upgrade external-dns external-dns/external-dns external-dns "${VALUES}/external-dns/values.yaml"
  apply_dir "${MANIFESTS}/external-dns"
else
  log "Skipping external-dns"
fi

if [[ "$SKIP_METRICS_SERVER" == false ]]; then
  log "Phase: metrics-server"
  apply_dir "${MANIFESTS}/metrics-server"
else
  log "Skipping metrics-server"
fi

# --- Phase 2: Observability ---

if [[ "$SKIP_OBSERVABILITY" == false ]]; then
  log "Phase: observability (prometheus, grafana, loki, tempo, alertmanager)"
  require_helm

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  helm_upgrade prometheus prometheus-community/prometheus monitoring "${VALUES}/prometheus/values.yaml"
  apply_dir "${MANIFESTS}/prometheus"

  helm_upgrade grafana grafana/grafana monitoring "${VALUES}/grafana/values.yaml"
  apply_dir "${MANIFESTS}/grafana"

  helm_upgrade loki grafana/loki monitoring "${VALUES}/loki/values.yaml"
  apply_dir "${MANIFESTS}/loki"

  helm_upgrade tempo grafana/tempo monitoring "${VALUES}/tempo/values.yaml"
  apply_dir "${MANIFESTS}/tempo"

  helm_upgrade alertmanager prometheus-community/alertmanager monitoring "${VALUES}/alertmanager/values.yaml"
  apply_dir "${MANIFESTS}/alertmanager"

  apply_dir "${MANIFESTS}/monitoring"
else
  log "Skipping observability"
fi

# --- Phase 3: GitOps ---

if [[ "$SKIP_ARGOCD" == false ]]; then
  log "Phase: argocd"
  require_helm
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null 2>&1 || true
  helm_upgrade argocd argo/argo-cd argocd "${VALUES}/argocd/values.yaml"
  apply_dir "${MANIFESTS}/argocd"
else
  log "Skipping argocd"
fi

# --- Phase 4: Security ---

if [[ "$SKIP_SECURITY" == false ]]; then
  log "Phase: security (kyverno, network-policy, pod-security, sealed-secrets)"
  require_helm
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  helm_upgrade kyverno kyverno/kyverno kyverno "${VALUES}/kyverno/values.yaml"
  apply_dir "${MANIFESTS}/kyverno"
  apply_dir "${MANIFESTS}/kyverno/policies"

  apply_dir "${MANIFESTS}/network-policy"
  apply_dir "${MANIFESTS}/pod-security"

  helm_upgrade sealed-secrets sealed-secrets/sealed-secrets kube-system "${VALUES}/sealed-secrets/values.yaml"
  apply_dir "${MANIFESTS}/sealed-secrets"

  apply_dir "${MANIFESTS}/security"
else
  log "Skipping security"
fi

log "Install complete. Run kubectl get pods -A to verify."
