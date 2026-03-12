#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/run_reviewer.sh --job-name <name> [--force]
EOF
}

validate_reviewer_output() {
  local json_file="$1"
  jq -e '
    (.summary | type == "string")
    and (.overall_grade == "S" or .overall_grade == "A" or .overall_grade == "B" or .overall_grade == "C")
    and (.findings | type == "array")
    and (
      all(.findings[]?;
        (.file | type == "string")
        and (.severity == "critical" or .severity == "high" or .severity == "medium" or .severity == "low")
        and (.title | type == "string")
        and (.reason | type == "string")
        and (.suggested_fix | type == "string")
      )
    )
  ' "${json_file}" >/dev/null
}

normalize_reviewer_output() {
  local json_file="$1"
  jq '
    .findings |= (
      map({
        file: (.file | tostring),
        severity: (.severity | tostring),
        title: (.title | tostring),
        reason: (.reason | tostring),
        suggested_fix: (.suggested_fix | tostring)
      })
    )
    | .critical_count = ([.findings[] | select(.severity == "critical")] | length)
  ' "${json_file}"
}

build_prompt_file() {
  local prompt_file="$1"
  local job_name="$2"
  local round_path="$3"
  local batch_label="$4"
  shift 4
  local batch_files=("$@")
  local summary_markdown summary_json file_path absolute_path
  summary_markdown="$(safe_read "${round_path}/claude_summary.md")"
  summary_json="$(safe_read "${round_path}/claude_summary.json")"

  {
    printf '# Reviewer Task\n\n'
    printf 'You are the totonoe Reviewer for job `%s`.\n\n' "${job_name}"
    printf 'Return only JSON that matches the provided schema.\n'
    printf 'Review only the files listed in this batch and prioritize bugs, regressions, and missing tests.\n\n'
    printf '## Engineer Summary\n\n'
    printf '%s\n\n' "${summary_markdown}"
    printf '## Summary Metadata\n\n'
    printf '```json\n%s\n```\n\n' "${summary_json}"
    printf '## Review Batch\n\n'
    printf 'Batch: %s\n\n' "${batch_label}"
    for file_path in "${batch_files[@]}"; do
      absolute_path="${REPO_ROOT}/${file_path}"
      printf '### File: %s\n\n' "${file_path}"
      if [ -f "${absolute_path}" ]; then
        printf '```text\n'
        cat -- "${absolute_path}"
        printf '\n```\n\n'
      else
        printf '_This file is not present in the current working tree. Treat it as deleted or moved._\n\n'
      fi
    done
    printf '## Output Rules\n\n'
    printf '- `severity` must be one of `critical`, `high`, `medium`, `low`\n'
    printf '- `overall_grade` must be one of `S`, `A`, `B`, `C`\n'
    printf '- `critical_count` must match the number of critical findings\n'
    printf '- If there are no findings, return an empty `findings` array and explain that in `summary`\n'
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

  local state_file state_json status current_round target_round round_path changed_file_list
  state_file="$(state_path "${job_name}")"
  state_json="$(safe_read "${state_file}")"
  status="$(printf '%s\n' "${state_json}" | jq -r '.status')"
  current_round="$(printf '%s\n' "${state_json}" | jq -r '.current_round')"
  target_round="${current_round}"

  if [ "${current_round}" -le 0 ]; then
    die "no recorded round exists for job: ${job_name}"
  fi
  if [ "${force}" != "1" ] && [ "${status}" != "reviewing" ]; then
    die "run_reviewer.sh requires status reviewing"
  fi

  round_path="$(round_dir "${job_name}" "${target_round}")"
  changed_file_list="${round_path}/changed_files.txt"

  local changed_files=()
  mapfile -t changed_files < <(safe_read "${changed_file_list}")

  local batch_outputs=()
  if [ "${#changed_files[@]}" -eq 0 ]; then
    jq -n '{
      summary: "No changed files were recorded for this round.",
      overall_grade: "S",
      critical_count: 0,
      findings: []
    }' | safe_write "${round_path}/reviewer_aggregate.json"
  else
    local batch_index=0
    local i batch_label prompt_file output_file normalized_output
    for ((i = 0; i < ${#changed_files[@]}; i += 3)); do
      batch_index=$((batch_index + 1))
      batch_label="$(printf '%03d' "${batch_index}")"
      prompt_file="${round_path}/reviewer_batch_${batch_label}.prompt.md"
      output_file="${round_path}/reviewer_batch_${batch_label}.json"
      normalized_output="$(mktemp)"

      build_prompt_file "${prompt_file}" "${job_name}" "${round_path}" "${batch_label}" \
        "${changed_files[@]:i:3}"

      if ! "${BIN_DIR}/run_ai_exec.sh" \
        --role reviewer \
        --prompt-file "${prompt_file}" \
        --schema-file "${SCHEMAS_DIR}/reviewer.schema.json" \
        --output-file "${output_file}" \
        --job-name "${job_name}"; then
        rm -f "${normalized_output}"
        die "reviewer execution failed for batch ${batch_label}"
      fi

      validate_reviewer_output "${output_file}" || {
        rm -f "${normalized_output}"
        die "reviewer output failed validation for batch ${batch_label}"
      }

      normalize_reviewer_output "${output_file}" > "${normalized_output}"
      safe_write "${output_file}" < "${normalized_output}"
      batch_outputs+=("${output_file}")

      rm -f "${normalized_output}"
    done

    jq -s '
      def grade_rank:
        if . == "S" then 0
        elif . == "A" then 1
        elif . == "B" then 2
        else 3
        end;
      {
        summary: (map(.summary) | map(select(length > 0)) | join("\n\n")),
        overall_grade: (
          map({grade: .overall_grade, rank: (.overall_grade | grade_rank)})
          | max_by(.rank).grade
        ),
        critical_count: (map([.findings[]? | select(.severity == "critical")] | length) | add // 0),
        findings: (map(.findings) | add // [])
      }
    ' "${batch_outputs[@]}" | safe_write "${round_path}/reviewer_aggregate.json"
  fi

  local aggregate_json aggregate_grade aggregate_critical batch_count
  aggregate_json="$(safe_read "${round_path}/reviewer_aggregate.json")"
  aggregate_grade="$(printf '%s\n' "${aggregate_json}" | jq -r '.overall_grade')"
  aggregate_critical="$(printf '%s\n' "${aggregate_json}" | jq -r '.critical_count')"
  batch_count="$(find "${round_path}" -maxdepth 1 -type f -name 'reviewer_batch_*.json' | wc -l | tr -d ' ')"

  acquire_job_lock "${job_name}"
  trap release_job_lock EXIT

  state_json="$(safe_read "${state_file}")"
  status="$(printf '%s\n' "${state_json}" | jq -r '.status')"
  current_round="$(printf '%s\n' "${state_json}" | jq -r '.current_round')"
  if [ "${force}" != "1" ] && [ "${status}" != "reviewing" ]; then
    die "run_reviewer.sh requires status reviewing"
  fi
  if [ "${current_round}" -ne "${target_round}" ]; then
    die "current round changed while reviewer was running"
  fi

  printf '%s\n' "${state_json}" | jq \
    --arg now "$(now_utc)" \
    --arg grade "${aggregate_grade}" \
    --argjson critical "${aggregate_critical}" \
    '
      .updated_at = $now
      | .status = "judging"
      | .last_reviewer_grade = $grade
      | .last_critical_count = $critical
    ' | safe_write "${state_file}"

  append_event_log_safe \
    "$(events_path "${job_name}")" \
    "$(jq -nc \
      --arg ts "$(now_utc)" \
      --arg job "${job_name}" \
      --argjson round "${current_round}" \
      --argjson batches "${batch_count}" \
      --arg grade "${aggregate_grade}" \
      --argjson critical "${aggregate_critical}" \
      '{
        ts: $ts,
        type: "reviewer_completed",
        job: $job,
        round: $round,
        batches: $batches,
        overall_grade: $grade,
        critical_count: $critical
      }')"

  release_job_lock
  trap - EXIT

  printf 'reviewer completed for job %s round %03d\n' "${job_name}" "${target_round}"
}

main "$@"
