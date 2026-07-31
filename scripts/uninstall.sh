#!/usr/bin/env bash
#
# uninstall.sh - tear down the kubernetes-production-templates stack in
# reverse order of install.sh: security -> argocd -> observability ->
# metrics-server -> external-dns -> cert-manager -> ingress-nginx -> namespaces
#
# Usage: ./scripts/uninstall.sh [-y]
#   -y   skip the confirmation prompt
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="${REPO_ROOT}/manifests"

AUTO_YES=false
if [[ "${1:-}" == "-y" ]]; then
  AUTO_YES=true
fi

log() { printf '\n[uninstall] %s\n' "$*"; }

if [[ "$AUTO_YES" == false ]]; then
  read -r -p "This will remove the entire stack from context '$(kubectl config current-context 2>/dev/null || echo unknown)'. Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

delete_dir() {
  local dir="$1"
  if [[ -d "$dir" ]] && find "$dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | grep -q .; then
    kubectl delete -f "$dir" --ignore-not-found=true
  fi
}

helm_uninstall() {
  local release="$1" namespace="$2"
  helm uninstall "$release" --namespace "$namespace" 2>/dev/null || true
}

log "Phase: security"
delete_dir "${MANIFESTS}/security"
helm_uninstall sealed-secrets kube-system
delete_dir "${MANIFESTS}/sealed-secrets"
delete_dir "${MANIFESTS}/pod-security"
delete_dir "${MANIFESTS}/network-policy"
delete_dir "${MANIFESTS}/kyverno/policies"
delete_dir "${MANIFESTS}/kyverno"
helm_uninstall kyverno kyverno

log "Phase: argocd"
delete_dir "${MANIFESTS}/argocd"
helm_uninstall argocd argocd

log "Phase: observability"
delete_dir "${MANIFESTS}/monitoring"
helm_uninstall alertmanager monitoring
delete_dir "${MANIFESTS}/alertmanager"
helm_uninstall tempo monitoring
delete_dir "${MANIFESTS}/tempo"
helm_uninstall loki monitoring
delete_dir "${MANIFESTS}/loki"
helm_uninstall grafana monitoring
delete_dir "${MANIFESTS}/grafana"
helm_uninstall prometheus monitoring
delete_dir "${MANIFESTS}/prometheus"

log "Phase: metrics-server"
delete_dir "${MANIFESTS}/metrics-server"

log "Phase: external-dns"
delete_dir "${MANIFESTS}/external-dns"
helm_uninstall external-dns external-dns

log "Phase: cert-manager"
delete_dir "${MANIFESTS}/cert-manager"
helm_uninstall cert-manager cert-manager

log "Phase: ingress-nginx"
delete_dir "${MANIFESTS}/ingress-nginx"
helm_uninstall ingress-nginx ingress-nginx

log "Phase: namespaces"
delete_dir "${MANIFESTS}/namespace"

log "Uninstall complete. Verify with: kubectl get all -A"
