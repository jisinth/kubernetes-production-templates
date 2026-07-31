#!/usr/bin/env bash
#
# validate.sh - run the same checks CI runs (kubeconform + yamllint) locally
# against manifests/ and applications/. Useful as a pre-commit / pre-push gate.
#
# Usage: ./scripts/validate.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\n[validate] %s\n' "$*"; }
fail=0

log "Checking required tools"
for tool in yamllint kubeconform; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "  MISSING: $tool (see https://github.com/yannh/kubeconform or 'pip install yamllint')" >&2
    fail=1
  fi
done
if [[ "$fail" -eq 1 ]]; then
  echo "Install missing tools above and re-run." >&2
  exit 1
fi

log "Running yamllint on manifests/"
yamllint -d "{extends: default, rules: {line-length: {max: 200}}}" "${REPO_ROOT}/manifests" || fail=1

log "Running yamllint on helm-values/"
yamllint -d "{extends: default, rules: {line-length: {max: 200}}}" "${REPO_ROOT}/helm-values" || fail=1

log "Running yamllint on applications/"
yamllint -d "{extends: default, rules: {line-length: {max: 200}}}" "${REPO_ROOT}/applications" || fail=1

log "Running kubeconform on manifests/"
find "${REPO_ROOT}/manifests" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 \
  | xargs -0 --no-run-if-empty kubeconform -strict -ignore-missing-schemas -summary \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  || fail=1

log "Running kubeconform on applications/"
find "${REPO_ROOT}/applications" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 \
  | xargs -0 --no-run-if-empty kubeconform -strict -ignore-missing-schemas -summary \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  || fail=1

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "validate.sh: one or more checks FAILED. See output above." >&2
  exit 1
fi

echo
echo "validate.sh: all checks passed."
