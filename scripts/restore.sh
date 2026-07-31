#!/usr/bin/env bash
#
# restore.sh - restore from a named Velero backup.
#
# Usage:
#   ./scripts/restore.sh <backup-name> [-- <extra velero args>]
#
# Example:
#   ./scripts/restore.sh prod-cluster-20260731120000
#   ./scripts/restore.sh prod-cluster-20260731120000 -- --include-namespaces monitoring
#
set -euo pipefail

log() { printf '\n[restore] %s\n' "$*"; }

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "Usage: $0 <backup-name> [-- <extra velero args>]" >&2
  exit 1
fi

BACKUP_NAME="$1"
shift

if [[ "${1:-}" == "--" ]]; then
  shift
fi
EXTRA_ARGS=("$@")

command -v velero >/dev/null 2>&1 || { echo "velero CLI not found in PATH" >&2; exit 1; }

if ! velero backup describe "${BACKUP_NAME}" >/dev/null 2>&1; then
  echo "Backup '${BACKUP_NAME}' was not found. List available backups with: velero backup get" >&2
  exit 1
fi

RESTORE_NAME="restore-${BACKUP_NAME}-$(date -u +%Y%m%d%H%M%S)"

log "Restoring from backup '${BACKUP_NAME}' as restore '${RESTORE_NAME}'"
velero restore create "${RESTORE_NAME}" --from-backup "${BACKUP_NAME}" "${EXTRA_ARGS[@]}"

log "Restore requested. Track status with:"
echo "  velero restore describe ${RESTORE_NAME}"
echo "  velero restore logs ${RESTORE_NAME}"
