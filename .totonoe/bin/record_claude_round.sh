#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .totonoe/bin/record_claude_round.sh \
    --job-name <name> \
    --summary-file <path> \
    --changed-file <file> [--changed-file <file> ...] \
    --quality-analyze "<status>" \
    --quality-test "<status>" \
    [--quality-notes "<text>"] \
    [--force]
EOF
}

main() {
  require_cmd jq

  local job_name=""
  local summary_file=""
  local quality_analyze=""
  local quality_test=""
  local quality_notes=""
  local force="0"
  local changed_files=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
        shift 2
        ;;
      --summary-file)
        summary_file="${2:-}"
        shift 2
        ;;
      --changed-file)
        changed_files+=("${2:-}")
        shift 2
        ;;
      --quality-analyze)
        quality_analyze="${2:-}"
        shift 2
        ;;
      --quality-test)
        quality_test="${2:-}"
        shift 2
        ;;
      --quality-notes)
        quality_notes="${2:-}"
        shift 2
        ;;
      --force)
        force="1"
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
  [ -n "${summary_file}" ] || die "summary file is required"
  [ -n "${quality_analyze}" ] || die "quality-analyze is required"
  [ -n "${quality_test}" ] || die "quality-test is required"
  [ "${#changed_files[@]}" -gt 0 ] || die "at least one changed file is required"

  case "${quality_analyze}" in
    passed|skipped|failed) ;;
    *)
      die "quality-analyze must be passed, skipped, or failed"
      ;;
  esac

  case "${quality_test}" in
    passed|skipped|failed) ;;
    *)
      die "quality-test must be passed, skipped, or failed"
      ;;
  esac

  ensure_job_exists "${job_name}"
  acquire_job_lock "${job_name}"
  trap release_job_lock EXIT

  local state_file state_json status current_round max_rounds next_round round_path
  state_file="$(state_path "${job_name}")"
  state_json="$(safe_read "${state_file}")"
  status="$(printf '%s\n' "${state_json}" | jq -r '.status')"
  current_round="$(printf '%s\n' "${state_json}" | jq -r '.current_round')"
  max_rounds="$(printf '%s\n' "${state_json}" | jq -r '.max_rounds')"

  if [ "${force}" != "1" ]; then
    case "${status}" in
      init|fix_requested|continue_requested) ;;
      *)
        die "record_claude_round.sh requires status init, fix_requested, or continue_requested"
        ;;
    esac
  fi

  next_round=$((current_round + 1))
  if [ "${force}" != "1" ] && [ "${next_round}" -gt "${max_rounds}" ]; then
    die "max rounds exceeded: ${max_rounds}"
  fi

  local normalized_summary_file
  normalized_summary_file="$(normalize_repo_path "${summary_file}")"
  local summary_markdown
  summary_markdown="$(safe_read "${REPO_ROOT}/${normalized_summary_file}")"

  local normalized_files=()
  local file_path
  for file_path in "${changed_files[@]}"; do
    normalized_files+=("$(normalize_repo_path "${file_path}")")
  done

  round_path="$(round_dir "${job_name}" "${next_round}")"
  mkdir -p "${round_path}"

  printf '%s\n' "${summary_markdown}" | safe_write "${round_path}/claude_summary.md"
  printf '%s\n' "${normalized_files[@]}" | safe_write "${round_path}/changed_files.txt"

  # 変更ファイルの snapshot を保存する（reviewer が作業ツリーではなく snapshot を読むため）
  local snap_dir="${round_path}/snapshot"
  mkdir -p "${snap_dir}"
  local snap_file abs_src snap_dest
  for snap_file in "${normalized_files[@]}"; do
    abs_src="${REPO_ROOT}/${snap_file}"
    snap_dest="${snap_dir}/${snap_file}"
    if [ -f "${abs_src}" ]; then
      mkdir -p "$(dirname -- "${snap_dest}")"
      safe_read "${abs_src}" | safe_write "${snap_dest}"
    fi
  done

  local changed_json
  changed_json="$(printf '%s\n' "${normalized_files[@]}" | jq -R . | jq -s .)"

  jq -n \
    --arg summary_markdown "${summary_markdown}" \
    --argjson changed_files "${changed_json}" \
    --arg analyze "${quality_analyze}" \
    --arg test "${quality_test}" \
    --arg quality_notes "${quality_notes}" \
    '
      {
        summary_markdown: $summary_markdown,
        changed_files: $changed_files,
        quality_gate: {
          analyze: $analyze,
          test: $test
        }
      }
      + (if $quality_notes == "" then {} else {quality_notes: $quality_notes} end)
    ' | safe_write "${round_path}/claude_summary.json"

  printf '%s\n' "${state_json}" | jq \
    --arg now "$(now_utc)" \
    --argjson next_round "${next_round}" \
    '
      .current_round = $next_round
      | .updated_at = $now
      | .status = "reviewing"
      | .manager_spot_check = null
    ' | safe_write "${state_file}"

  append_event_log_safe \
    "$(events_path "${job_name}")" \
    "$(jq -nc \
      --arg ts "$(now_utc)" \
      --arg job "${job_name}" \
      --argjson round "${next_round}" \
      --arg analyze "${quality_analyze}" \
      --arg test "${quality_test}" \
      '{
        ts: $ts,
        type: "claude_round_recorded",
        job: $job,
        round: $round,
        quality_analyze: $analyze,
        quality_test: $test
      }')"

  printf 'recorded round %03d for job %s\n' "${next_round}" "${job_name}"
}

main "$@"
