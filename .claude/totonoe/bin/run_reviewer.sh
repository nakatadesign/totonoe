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
      local snapshot_path="${round_path}/snapshot/${file_path}"
      printf '### File: %s\n\n' "${file_path}"
      if [ -f "${snapshot_path}" ]; then
        printf '```text\n'
        safe_read "${snapshot_path}"
        printf '\n```\n\n'
      else
        printf '_This file is not present in the snapshot. Treat it as deleted or moved._\n\n'
      fi
    done
    printf '## Output Rules\n\n'
    printf -- '- `severity` must be one of `critical`, `high`, `medium`, `low`\n'
    printf -- '- `overall_grade` must be one of `S`, `A`, `B`, `C`\n'
    printf -- '- `critical_count` must match the number of critical findings\n'
    printf -- '- If there are no findings, return an empty `findings` array and explain that in `summary`\n'
  } | safe_write "${prompt_file}"
}

# shadow provider で reviewer を実行する
# 戻り値: 0=成功, 1=実行失敗, 2=出力バリデーション失敗
run_shadow_reviewer() {
  local job_name="$1"
  local batch_label="$2"
  local prompt_file="$3"
  local round_path="$4"

  local shadow_output_file="${round_path}/reviewer_batch_${batch_label}_shadow.json"
  local shadow_tmp
  shadow_tmp="$(mktemp)"

  if ! "${BIN_DIR}/run_ai_exec.sh" \
    --role reviewer \
    --prompt-file "${prompt_file}" \
    --schema-file "${SCHEMAS_DIR}/reviewer.schema.json" \
    --output-file "${shadow_output_file}" \
    --job-name "${job_name}" \
    --provider-role shadow; then
    warn "shadow reviewer execution failed for batch ${batch_label}"
    rm -f "${shadow_tmp}"
    return 1
  fi

  if ! validate_reviewer_output "${shadow_output_file}"; then
    warn "shadow reviewer output failed validation for batch ${batch_label}"
    rm -f "${shadow_tmp}"
    return 2
  fi

  normalize_reviewer_output "${shadow_output_file}" > "${shadow_tmp}"
  safe_write "${shadow_output_file}" < "${shadow_tmp}"
  rm -f "${shadow_tmp}"
}

# reviewer_shadow_status.json を round ディレクトリに書き出す
write_shadow_status() {
  local round_path="$1"
  shift
  local entries=("$@")

  if [ "${#entries[@]}" -eq 0 ]; then
    jq -n '{mode: "shadow", batches: []}' | safe_write "${round_path}/reviewer_shadow_status.json"
    return
  fi

  printf '%s\n' "${entries[@]}" | jq -s '{mode: "shadow", batches: .}' \
    | safe_write "${round_path}/reviewer_shadow_status.json"
}

# shadow バッチを集約して reviewer_shadow.json を生成する
build_shadow_aggregate() {
  local round_path="$1"
  shift
  local shadow_batch_files=("$@")

  if [ "${#shadow_batch_files[@]}" -eq 0 ]; then
    return 0
  fi

  # 存在するファイルだけを対象にする
  local existing=()
  local f
  for f in "${shadow_batch_files[@]}"; do
    [ -f "${f}" ] && existing+=("${f}")
  done

  [ "${#existing[@]}" -eq 0 ] && return 0

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
  ' "${existing[@]}" | safe_write "${round_path}/reviewer_shadow.json"
}

# primary と shadow の差分サマリーを生成する
build_shadow_summary() {
  local round_path="$1"

  local primary_file="${round_path}/reviewer_aggregate.json"
  local shadow_file="${round_path}/reviewer_shadow.json"

  [ -f "${primary_file}" ] || return 0
  [ -f "${shadow_file}" ]  || return 0

  jq -n \
    --slurpfile primary "${primary_file}" \
    --slurpfile shadow "${shadow_file}" \
    '
      ($primary[0]) as $p |
      ($shadow[0])  as $s |
      {
        primary_grade:         $p.overall_grade,
        shadow_grade:          $s.overall_grade,
        grade_diff:            (
          (if $p.overall_grade == "S" then 0 elif $p.overall_grade == "A" then 1 elif $p.overall_grade == "B" then 2 else 3 end)
          - (if $s.overall_grade == "S" then 0 elif $s.overall_grade == "A" then 1 elif $s.overall_grade == "B" then 2 else 3 end)
          | fabs | floor
        ),
        primary_critical_count: $p.critical_count,
        shadow_critical_count:  $s.critical_count,
        critical_count_diff:    ($p.critical_count - $s.critical_count | fabs),
        primary_only_critical:  (
          ([$p.findings[] | select(.severity == "critical")] | map({file: .file, title: .title})) as $pc |
          ([$s.findings[] | select(.severity == "critical")] | map({file: .file, title: .title})) as $sc |
          [$pc[] | select(. as $x | $sc | map(select(.file == $x.file and .title == $x.title)) | length == 0)]
        ),
        shadow_only_critical:   (
          ([$p.findings[] | select(.severity == "critical")] | map({file: .file, title: .title})) as $pc |
          ([$s.findings[] | select(.severity == "critical")] | map({file: .file, title: .title})) as $sc |
          [$sc[] | select(. as $x | $pc | map(select(.file == $x.file and .title == $x.title)) | length == 0)]
        ),
        primary_finding_count:  ($p.findings | length),
        shadow_finding_count:   ($s.findings | length)
      }
    ' | safe_write "${round_path}/reviewer_shadow_summary.json"
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

    # shadow mode で変更ファイルがない場合も status を記録する
    local reviewer_mode_empty
    reviewer_mode_empty="$(read_reviewer_mode)"
    if [ "${reviewer_mode_empty}" = "shadow" ]; then
      write_shadow_status "${round_path}"
    fi
  else
    local reviewer_mode
    reviewer_mode="$(read_reviewer_mode)"

    local shadow_batch_files=()
    local shadow_status_entries=()
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

      # primary 実行
      if ! "${BIN_DIR}/run_ai_exec.sh" \
        --role reviewer \
        --prompt-file "${prompt_file}" \
        --schema-file "${SCHEMAS_DIR}/reviewer.schema.json" \
        --output-file "${output_file}" \
        --job-name "${job_name}" \
        --provider-role primary; then
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

      # shadow 実行（shadow mode のときのみ）
      if [ "${reviewer_mode}" = "shadow" ]; then
        # primary が実際に使った provider を確認する
        local actual_provider
        actual_provider="$(read_provider_state "${job_name}" | jq -r '.last_used_provider')"

        if [ "${actual_provider}" = "gemini" ]; then
          # primary が Gemini を使った batch では shadow 比較価値が低いためスキップする
          shadow_status_entries+=("$(jq -nc --arg b "${batch_label}" '{batch: $b, status: "skipped", reason: "primary_used_gemini_fallback"}')")
          warn "shadow skipped for batch ${batch_label}: primary used gemini"
        else
          local shadow_result=0
          run_shadow_reviewer "${job_name}" "${batch_label}" "${prompt_file}" "${round_path}" || shadow_result=$?

          local shadow_batch_file="${round_path}/reviewer_batch_${batch_label}_shadow.json"
          case "${shadow_result}" in
            0)
              shadow_batch_files+=("${shadow_batch_file}")
              shadow_status_entries+=("$(jq -nc --arg b "${batch_label}" '{batch: $b, status: "success", provider: "gemini"}')")
              ;;
            2)
              shadow_status_entries+=("$(jq -nc --arg b "${batch_label}" '{batch: $b, status: "failed", reason: "shadow_output_invalid"}')")
              ;;
            *)
              shadow_status_entries+=("$(jq -nc --arg b "${batch_label}" '{batch: $b, status: "failed", reason: "shadow_execution_failed"}')")
              ;;
          esac
        fi
      fi
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

    # shadow aggregate, summary, status を生成する（shadow mode のときのみ）
    if [ "${reviewer_mode}" = "shadow" ]; then
      if [ "${#shadow_batch_files[@]}" -gt 0 ]; then
        build_shadow_aggregate "${round_path}" "${shadow_batch_files[@]}"
        build_shadow_summary "${round_path}"
      fi
      write_shadow_status "${round_path}" "${shadow_status_entries[@]}"
    fi
  fi

  local aggregate_json aggregate_grade aggregate_critical batch_count
  aggregate_json="$(safe_read "${round_path}/reviewer_aggregate.json")"
  aggregate_grade="$(printf '%s\n' "${aggregate_json}" | jq -r '.overall_grade')"
  aggregate_critical="$(printf '%s\n' "${aggregate_json}" | jq -r '.critical_count')"
  batch_count="$(find "${round_path}" -maxdepth 1 -type f -name 'reviewer_batch_*.json' ! -name '*_shadow.json' | wc -l | tr -d ' ')"

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
