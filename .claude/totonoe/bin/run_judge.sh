#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/run_judge.sh --job-name <name> [--force]
EOF
}

validate_judge_output() {
  local json_file="$1"
  jq -e '
    (.recommendation == "fix" or .recommendation == "continue" or .recommendation == "done" or .recommendation == "human")
    and (.reason | type == "string")
    and (.must_fix | type == "array")
    and (.can_defer | type == "array")
    and (.next_step | type == "string")
    and (all(.must_fix[]?; type == "string"))
    and (all(.can_defer[]?; type == "string"))
    and (.engineer_type == "security" or .engineer_type == "test" or .engineer_type == "performance" or .engineer_type == "refactor" or .engineer_type == "generic")
    and (.spot_check_required | type == "boolean")
  ' "${json_file}" >/dev/null
}

normalize_judge_output() {
  local json_file="$1"
  jq '
    .reason |= tostring
    | .next_step |= tostring
    | .must_fix |= map(tostring)
    | .can_defer |= map(tostring)
    | .engineer_type = (
        if .engineer_type == "security" or .engineer_type == "test"
           or .engineer_type == "performance" or .engineer_type == "refactor"
           or .engineer_type == "generic"
        then .engineer_type
        else "generic"
        end
      )
    | .spot_check_required = (.recommendation == "done")
  ' "${json_file}"
}

build_prompt_file() {
  local prompt_file="$1"
  local job_name="$2"
  local round_path="$3"
  local summary_json aggregate_json supervisor_text
  summary_json="$(safe_read "${round_path}/claude_summary.json")"
  aggregate_json="$(safe_read "${round_path}/reviewer_aggregate.json")"
  supervisor_text="$(safe_read "${TOTONOE_DIR}/SUPERVISOR.md")"

  {
    printf '# Judge Task\n\n'
    printf 'You are the totonoe Analyst for job `%s`.\n\n' "${job_name}"
    printf 'Return only JSON that matches the provided schema.\n\n'
    printf '## Supervisor Instructions\n\n'
    printf '%s\n\n' "${supervisor_text}"
    printf '## Claude Summary\n\n'
    printf '```json\n%s\n```\n\n' "${summary_json}"
    printf '## Reviewer Aggregate\n\n'
    printf '```json\n%s\n```\n\n' "${aggregate_json}"
    printf '## Output Rules\n\n'
    printf -- '- `recommendation` must be one of `fix`, `continue`, `done`, `human`\n'
    printf -- '- `engineer_type` is required. Must be one of `security`, `test`, `performance`, `refactor`, `generic`\n'
    printf -- '- `must_fix` should contain only issues that block completion\n'
    printf -- '- `can_defer` should contain only lower-priority items\n'
    printf -- '- `next_step` should be one sentence\n'
    printf -- '- `spot_check_required` is computed at runtime. Do NOT include it in your output\n'
  } | safe_write "${prompt_file}"
}

main() {
  require_cmd jq

  local job_name=""
  local force="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
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

  local state_file state_json status current_round target_round round_path prompt_file normalized_output
  state_file="$(state_path "${job_name}")"
  state_json="$(safe_read "${state_file}")"
  status="$(printf '%s\n' "${state_json}" | jq -r '.status')"
  current_round="$(printf '%s\n' "${state_json}" | jq -r '.current_round')"
  target_round="${current_round}"

  if [ "${current_round}" -le 0 ]; then
    die "no recorded round exists for job: ${job_name}"
  fi
  if [ "${force}" != "1" ] && [ "${status}" != "judging" ]; then
    die "run_judge.sh requires status judging"
  fi

  round_path="$(round_dir "${job_name}" "${target_round}")"
  [ -f "${round_path}/reviewer_aggregate.json" ] || die "missing reviewer_aggregate.json"

  prompt_file="${round_path}/judge.prompt.md"
  normalized_output="$(mktemp)"

  build_prompt_file "${prompt_file}" "${job_name}" "${round_path}"

  if ! "${BIN_DIR}/run_ai_exec.sh" \
    --role judge \
    --prompt-file "${prompt_file}" \
    --schema-file "${SCHEMAS_DIR}/judge.schema.json" \
    --output-file "${round_path}/judge.json" \
    --job-name "${job_name}"; then
    rm -f "${normalized_output}"
    die "judge execution failed"
  fi

  normalize_judge_output "${round_path}/judge.json" > "${normalized_output}"
  safe_write "${round_path}/judge.json" < "${normalized_output}"

  validate_judge_output "${round_path}/judge.json" || {
    rm -f "${normalized_output}"
    die "judge output failed validation"
  }

  local recommendation
  recommendation="$(safe_read "${round_path}/judge.json" | jq -r '.recommendation')"

  acquire_job_lock "${job_name}"
  trap release_job_lock EXIT

  state_json="$(safe_read "${state_file}")"
  status="$(printf '%s\n' "${state_json}" | jq -r '.status')"
  current_round="$(printf '%s\n' "${state_json}" | jq -r '.current_round')"
  if [ "${force}" != "1" ] && [ "${status}" != "judging" ]; then
    die "run_judge.sh requires status judging"
  fi
  if [ "${current_round}" -ne "${target_round}" ]; then
    die "current round changed while judge was running"
  fi

  printf '%s\n' "${state_json}" | jq \
    --arg now "$(now_utc)" \
    '
      .updated_at = $now
      | .status = "manager_review"
    ' | safe_write "${state_file}"

  append_event_log_safe \
    "$(events_path "${job_name}")" \
    "$(jq -nc \
      --arg ts "$(now_utc)" \
      --arg job "${job_name}" \
      --argjson round "${current_round}" \
      --arg recommendation "${recommendation}" \
      '{
        ts: $ts,
        type: "judge_completed",
        job: $job,
        round: $round,
        recommendation: $recommendation
      }')"

  release_job_lock
  trap - EXIT

  rm -f "${normalized_output}"

  printf 'judge completed for job %s round %03d\n' "${job_name}" "${target_round}"
}

main "$@"
