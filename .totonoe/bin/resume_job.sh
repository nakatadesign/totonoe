#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .totonoe/bin/resume_job.sh --job-name <name>
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

  local state_file state_json status previous_status
  state_file="$(state_path "${job_name}")"
  state_json="$(safe_read "${state_file}")"
  status="$(printf '%s\n' "${state_json}" | jq -r '.status')"
  [ "${status}" = "paused" ] || die "resume_job.sh requires status paused"

  previous_status="$(printf '%s\n' "${state_json}" | jq -r '.pause.previous_status // empty')"
  case "${previous_status}" in
    init|fix_requested|continue_requested|reviewing|judging|manager_review) ;;
    *)
      die "paused job is missing a resumable previous status"
      ;;
  esac

  printf '%s\n' "${state_json}" | jq \
    --arg now "$(now_utc)" \
    --arg resumed_status "${previous_status}" \
    '
      .updated_at = $now
      | .status = $resumed_status
      | .pause = null
    ' | safe_write "${state_file}"

  append_event_log_safe \
    "$(events_path "${job_name}")" \
    "$(jq -nc \
      --arg ts "$(now_utc)" \
      --arg job "${job_name}" \
      --arg resumed_status "${previous_status}" \
      '{
        ts: $ts,
        type: "job_resumed",
        job: $job,
        resumed_status: $resumed_status
      }')"

  printf 'resumed job %s (status: %s)\n' "${job_name}" "${previous_status}"
}

main "$@"
