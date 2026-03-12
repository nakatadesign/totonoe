#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/status.sh --job-name <name> [--json] [--provider-state]
EOF
}

main() {
  require_cmd jq

  local job_name=""
  local json_mode="0"
  local provider_state_mode="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
        shift 2
        ;;
      --json)
        json_mode="1"
        shift
        ;;
      --provider-state)
        provider_state_mode="1"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  validate_job_name "${job_name}"
  ensure_job_exists "${job_name}"

  local state_file
  state_file="$(state_path "${job_name}")"

  if [ "${json_mode}" = "1" ]; then
    if [ "${provider_state_mode}" = "1" ]; then
      jq -n \
        --argjson state "$(safe_read "${state_file}")" \
        --argjson provider_state "$(read_provider_state "${job_name}")" \
        '{
          state: $state,
          provider_state: $provider_state
        }'
      exit 0
    fi
    safe_read "${state_file}" | jq '.'
    exit 0
  fi

  safe_read "${state_file}" | jq -r --arg job_dir "$(job_dir "${job_name}")" '
    [
      "job_name: \(.job_name)",
      "status: \(.status)",
      "current_round: \(.current_round)",
      "max_rounds: \(.max_rounds)",
      "last_decision: \(.last_decision // "null")",
      "last_reviewer_grade: \(.last_reviewer_grade // "null")",
      "last_critical_count: \(.last_critical_count)",
      "job_dir: \($job_dir)"
    ] | join("\n")
  '

  if [ "${provider_state_mode}" = "1" ]; then
    printf '\n'
    printf '%s\n' "$(read_provider_state "${job_name}" | jq -r '
      [
        "provider.preferred_provider: \(.preferred_provider)",
        "provider.last_used_provider: \(.last_used_provider)",
        "provider.codex_consecutive_failures: \(.codex_consecutive_failures)",
        "provider.fallback_count: \(.fallback_count)",
        "provider.last_fallback_at: \(.last_fallback_at // "null")",
        "provider.last_fallback_reason: \(.last_fallback_reason // "null")",
        "provider.cooldown_until: \(.cooldown_until // "null")"
      ] | join("\n")
    ')"
  fi
}

main "$@"
