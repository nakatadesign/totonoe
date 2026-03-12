#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/apply_manager_decision.sh --job-name <name> --record-spot-check [--force]
  .claude/totonoe/bin/apply_manager_decision.sh --job-name <name> --decision <fix|continue|done|human> [--reason "<text>"] [--from-judge <path>] [--force]
EOF
}

done_guard_failure_reason() {
  local state_json="$1"
  local round_path="$2"
  local judge_file="$3"
  local failures=()
  local current_round critical_count analyze_status test_status recommendation spot_round

  current_round="$(printf '%s\n' "${state_json}" | jq -r '.current_round')"
  critical_count="$(safe_read "${round_path}/reviewer_aggregate.json" | jq -r '.critical_count')"
  analyze_status="$(safe_read "${round_path}/claude_summary.json" | jq -r '.quality_gate.analyze')"
  test_status="$(safe_read "${round_path}/claude_summary.json" | jq -r '.quality_gate.test')"
  recommendation="$(safe_read "${judge_file}" | jq -r '.recommendation')"
  spot_round="$(printf '%s\n' "${state_json}" | jq -r '.manager_spot_check.round // -1')"

  [ "${critical_count}" -eq 0 ] || failures+=("critical_count must be 0")
  { [ "${analyze_status}" = "passed" ] || [ "${analyze_status}" = "skipped" ]; } || failures+=("quality_gate.analyze must be passed or skipped")
  { [ "${test_status}" = "passed" ] || [ "${test_status}" = "skipped" ]; } || failures+=("quality_gate.test must be passed or skipped")
  [ "${recommendation}" = "done" ] || failures+=("judge recommendation must be done")
  [ "${spot_round}" = "${current_round}" ] || failures+=("manager_spot_check must exist for current round")

  if [ "${#failures[@]}" -eq 0 ]; then
    return 1
  fi

  local joined=""
  local item
  for item in "${failures[@]}"; do
    if [ -n "${joined}" ]; then
      joined="${joined}; ${item}"
    else
      joined="${item}"
    fi
  done
  printf '%s\n' "${joined}"
  return 0
}

main() {
  require_cmd jq

  local job_name=""
  local record_spot_check="0"
  local decision=""
  local reason=""
  local from_judge=""
  local force="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
        shift 2
        ;;
      --record-spot-check)
        record_spot_check="1"
        shift
        ;;
      --decision)
        decision="${2:-}"
        shift 2
        ;;
      --reason)
        reason="${2:-}"
        shift 2
        ;;
      --from-judge)
        from_judge="${2:-}"
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
  ensure_job_exists "${job_name}"

  if [ "${record_spot_check}" = "1" ] && [ -n "${decision}" ]; then
    die "record-spot-check and decision are mutually exclusive"
  fi
  if [ "${record_spot_check}" = "0" ] && [ -z "${decision}" ]; then
    die "specify either --record-spot-check or --decision"
  fi
  if [ -n "${decision}" ]; then
    case "${decision}" in
      fix|continue|done|human) ;;
      *)
        die "invalid decision: ${decision}"
        ;;
    esac
  fi

  acquire_job_lock "${job_name}"
  trap release_job_lock EXIT

  local state_file state_json status current_round round_path judge_file
  state_file="$(state_path "${job_name}")"
  state_json="$(safe_read "${state_file}")"
  status="$(printf '%s\n' "${state_json}" | jq -r '.status')"
  current_round="$(printf '%s\n' "${state_json}" | jq -r '.current_round')"

  if [ "${force}" != "1" ] && [ "${status}" != "manager_review" ]; then
    die "apply_manager_decision.sh requires status manager_review"
  fi
  if [ "${current_round}" -le 0 ]; then
    die "no recorded round exists for job: ${job_name}"
  fi

  round_path="$(round_dir "${job_name}" "${current_round}")"
  judge_file="${round_path}/judge.json"

  if [ -n "${from_judge}" ]; then
    local normalized_judge_file absolute_judge_file canonical_judge_file
    normalized_judge_file="$(normalize_repo_path "${from_judge}")"
    absolute_judge_file="${REPO_ROOT}/${normalized_judge_file}"
    [ -f "${absolute_judge_file}" ] || die "judge file not found: ${from_judge}"
    canonical_judge_file="$(canonical_existing_path "${absolute_judge_file}")"
    assert_path_within "${RUNTIME_ROOT}" "${canonical_judge_file}"
    judge_file="${absolute_judge_file}"
  fi

  [ -f "${judge_file}" ] || die "missing judge file: ${judge_file}"

  if [ "${record_spot_check}" = "1" ]; then
    local checked_files_json
    checked_files_json="$(safe_read "${round_path}/changed_files.txt" | jq -R . | jq -s .)"

    printf '%s\n' "${state_json}" | jq \
      --arg now "$(now_utc)" \
      --argjson current_round "${current_round}" \
      --argjson checked_files "${checked_files_json}" \
      '
        .updated_at = $now
        | .manager_spot_check = {
            checked_at: $now,
            round: $current_round,
            checked_files: $checked_files
          }
      ' | safe_write "${state_file}"

    append_event_log_safe \
      "$(events_path "${job_name}")" \
      "$(jq -nc \
        --arg ts "$(now_utc)" \
        --arg job "${job_name}" \
        --argjson round "${current_round}" \
        '{
          ts: $ts,
          type: "manager_spot_check_recorded",
          job: $job,
          round: $round
        }')"

    printf 'recorded manager spot check for job %s round %03d\n' "${job_name}" "${current_round}"
    exit 0
  fi

  local requested_decision final_decision final_status final_reason guard_failure judge_reason
  requested_decision="${decision}"
  final_decision="${decision}"
  final_reason="${reason}"

  if [ -z "${final_reason}" ]; then
    judge_reason="$(safe_read "${judge_file}" | jq -r '.reason')"
    final_reason="${judge_reason}"
  fi

  if [ "${requested_decision}" = "done" ]; then
    if guard_failure="$(done_guard_failure_reason "${state_json}" "${round_path}" "${judge_file}")"; then
      final_decision="human"
      final_reason="requested done but guard failed: ${guard_failure}"
    fi
  fi

  case "${final_decision}" in
    fix)
      final_status="fix_requested"
      ;;
    continue)
      final_status="continue_requested"
      ;;
    done)
      final_status="done"
      ;;
    human)
      final_status="human"
      ;;
    *)
      die "unexpected final decision: ${final_decision}"
      ;;
  esac

  printf '%s\n' "${state_json}" | jq \
    --arg now "$(now_utc)" \
    --arg status "${final_status}" \
    --arg decision "${final_decision}" \
    '
      .updated_at = $now
      | .status = $status
      | .last_decision = $decision
    ' | safe_write "${state_file}"

  append_event_log_safe \
    "$(events_path "${job_name}")" \
    "$(jq -nc \
      --arg ts "$(now_utc)" \
      --arg job "${job_name}" \
      --argjson round "${current_round}" \
      --arg requested "${requested_decision}" \
      --arg applied "${final_decision}" \
      --arg reason "${final_reason}" \
      '{
        ts: $ts,
        type: "manager_decision_applied",
        job: $job,
        round: $round,
        requested_decision: $requested,
        applied_decision: $applied,
        reason: $reason
      }')"

  printf 'applied manager decision %s for job %s round %03d\n' "${final_decision}" "${job_name}" "${current_round}"
}

main "$@"
