#!/usr/bin/env bash
# cursor-governance-managed:1.0.0
set -u
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf '%s\n' "PREFLIGHT_BLOCK" "reason=NOT_A_GIT_REPO"
  exit 1
}
MODE="${GOVERNANCE_MODE:-${1:-push}}"
exec /usr/bin/env bash "$ROOT/scripts/preflight.sh" "$MODE"
