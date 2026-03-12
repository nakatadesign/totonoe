#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/pause_job.sh --job-name <name> [--reason "<text>"]
EOF
}

main() {
  require_cmd jq

  local job_name=""
  local reason="user requested stop"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
        shift 2
        ;;
      --reason)
        reason="${2:-}"
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

  local state_file state_json status
  state_file="$(state_path "${job_name}")"
  state_json="$(safe_read "${state_file}")"
  status="$(printf '%s\n' "${state_json}" | jq -r '.status')"

  case "${status}" in
    init|fix_requested|continue_requested|reviewing|judging|manager_review) ;;
    paused)
      die "job is already paused: ${job_name}"
      ;;
    human)
      die "job is already waiting for human judgment: ${job_name}"
      ;;
    done)
      die "cannot pause completed job: ${job_name}"
      ;;
    *)
      die "cannot pause job from status: ${status}"
      ;;
  esac

  printf '%s\n' "${state_json}" | jq \
    --arg now "$(now_utc)" \
    --arg reason "${reason}" \
    --arg previous_status "${status}" \
    '
      .updated_at = $now
      | .status = "paused"
      | .pause = {
          paused_at: $now,
          reason: $reason,
          previous_status: $previous_status
        }
    ' | safe_write "${state_file}"

  append_event_log_safe \
    "$(events_path "${job_name}")" \
    "$(jq -nc \
      --arg ts "$(now_utc)" \
      --arg job "${job_name}" \
      --arg previous_status "${status}" \
      --arg reason "${reason}" \
      '{
        ts: $ts,
        type: "job_paused",
        job: $job,
        previous_status: $previous_status,
        reason: $reason
      }')"

  printf 'paused job %s (previous status: %s)\n' "${job_name}" "${status}"
}

main "$@"
