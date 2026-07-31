#!/usr/bin/env bash
#
# backup.sh - trigger a timestamped Velero backup.
#
# Usage:
#   ./scripts/backup.sh [name-prefix] [-- <extra velero args>]
#
# Example:
#   ./scripts/backup.sh prod-cluster
#   ./scripts/backup.sh prod-cluster -- --include-namespaces monitoring,argocd
#
set -euo pipefail

PREFIX="${1:-manual-backup}"
shift || true

if [[ "${1:-}" == "--" ]]; then
  shift
fi
EXTRA_ARGS=("$@")

log() { printf '\n[backup] %s\n' "$*"; }

command -v velero >/dev/null 2>&1 || { echo "velero CLI not found in PATH" >&2; exit 1; }

if ! velero backup-location get >/dev/null 2>&1; then
  echo "Velero does not appear to be installed/reachable in this cluster (velero backup-location get failed)." >&2
  echo "Install it first: see manifests/velero/README.md" >&2
  exit 1
fi

TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
BACKUP_NAME="${PREFIX}-${TIMESTAMP}"

log "Creating Velero backup: ${BACKUP_NAME}"
velero backup create "${BACKUP_NAME}" "${EXTRA_ARGS[@]}"

log "Backup requested. Track status with:"
echo "  velero backup describe ${BACKUP_NAME}"
echo "  velero backup logs ${BACKUP_NAME}"
