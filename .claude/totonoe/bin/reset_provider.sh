#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/reset_provider.sh --job-name <name>
EOF
}

main() {
  require_cmd jq

  local job_name=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
        shift 2
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
  acquire_job_lock "${job_name}"
  trap release_job_lock EXIT

  read_provider_state "${job_name}" | jq '
    .preferred_provider = "codex"
    | .codex_consecutive_failures = 0
    | .cooldown_until = null
    | .last_fallback_reason = null
  ' | write_provider_state "${job_name}"

  append_event_log_safe \
    "$(events_path "${job_name}")" \
    "$(jq -nc \
      --arg ts "$(now_utc)" \
      --arg job "${job_name}" \
      '{
        ts: $ts,
        type: "manual_reset",
        job: $job,
        provider: "codex",
        reason: "manual"
      }')"

  printf 'provider reset to codex for job %s\n' "${job_name}"
}

main "$@"
