#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .totonoe/bin/run_ai_exec.sh \
    --role <reviewer|judge> \
    --prompt-file <path> \
    --schema-file <path> \
    --output-file <path> \
    --job-name <name>
EOF
}

ai_event_json() {
  local job_name="$1"
  local role="$2"
  local provider="$3"
  local model="$4"
  local result="$5"
  local reason="$6"
  local provider_role="${7:-primary}"

  jq -nc \
    --arg ts "$(now_utc)" \
    --arg job "${job_name}" \
    --arg role "${role}" \
    --arg provider "${provider}" \
    --arg result "${result}" \
    --arg reason "${reason}" \
    --arg model "${model}" \
    --arg provider_role "${provider_role}" \
    '{
      ts: $ts,
      type: "ai_exec",
      job: $job,
      role: $role,
      provider: $provider,
      provider_role: $provider_role,
      model: (if $model == "" then null else $model end),
      result: $result,
      reason: $reason
    }'
}

iso8601_to_epoch() {
  perl -MTime::Piece -e '
    my $value = shift @ARGV;
    my $t = Time::Piece->strptime($value, "%Y-%m-%dT%H:%M:%SZ");
    print $t->epoch;
  ' "$1"
}

epoch_to_iso8601() {
  perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(shift @ARGV));' "$1"
}

cooldown_is_active() {
  local provider_state_json="$1"
  local cooldown_until cooldown_epoch now_epoch

  cooldown_until="$(printf '%s\n' "${provider_state_json}" | jq -r '.cooldown_until // empty')"
  [ -n "${cooldown_until}" ] || return 1

  cooldown_epoch="$(iso8601_to_epoch "${cooldown_until}")" || return 1
  now_epoch="$(date -u +%s)"
  [ "${cooldown_epoch}" -gt "${now_epoch}" ]
}

calculate_cooldown_seconds() {
  local failure_count="$1"
  local base_seconds="${AI_PROVIDER_COOLDOWN_BASE_SECONDS:-1800}"
  [[ "${base_seconds}" =~ ^[0-9]+$ ]] || die "AI_PROVIDER_COOLDOWN_BASE_SECONDS must be numeric"
  [ "${base_seconds}" -gt 0 ] || die "AI_PROVIDER_COOLDOWN_BASE_SECONDS must be positive"

  local seconds="${base_seconds}"
  local i
  for ((i = 1; i < failure_count; i += 1)); do
    seconds=$((seconds * 2))
    if [ "${seconds}" -ge 7200 ]; then
      printf '7200\n'
      return
    fi
  done

  if [ "${seconds}" -gt 7200 ]; then
    seconds=7200
  fi
  printf '%s\n' "${seconds}"
}

codex_failure_reason() {
  local stdout_file="$1"
  local stderr_file="$2"

  if grep -Eiq 'insufficient[_ -]?quota' "${stderr_file}" "${stdout_file}" 2>/dev/null; then
    printf 'insufficient_quota\n'
    return
  fi
  if grep -Eiq 'context[._ -]*length[._ -]*exceeded' "${stderr_file}" "${stdout_file}" 2>/dev/null; then
    printf 'context_length_exceeded\n'
    return
  fi
  if grep -Eiq 'token[._ -]*limit|exceeded.*token' "${stderr_file}" "${stdout_file}" 2>/dev/null; then
    printf 'token_limit\n'
    return
  fi
  if grep -Eiq 'rate[._ -]*limit' "${stderr_file}" "${stdout_file}" 2>/dev/null; then
    printf 'rate_limit\n'
    return
  fi
  if grep -Eiq 'quota' "${stderr_file}" "${stdout_file}" 2>/dev/null; then
    printf 'quota\n'
    return
  fi
  if grep -Eiq 'usage[_ -]*limit|hit.*limit' "${stderr_file}" "${stdout_file}" 2>/dev/null; then
    printf 'usage_limit\n'
    return
  fi
  printf '\n'
}

validate_role_json() {
  local role="$1"
  local json_file="$2"

  case "${role}" in
    reviewer)
      if ! jq -e '
        (.findings | type == "array")
        and (.overall_grade == "S" or .overall_grade == "A" or .overall_grade == "B" or .overall_grade == "C")
        and (.critical_count | type == "number")
      ' "${json_file}" >/dev/null; then
        return 1
      fi
      ;;
    judge)
      if ! jq -e '
        (.recommendation == "fix" or .recommendation == "continue" or .recommendation == "done" or .recommendation == "human")
        and (.must_fix | type == "array")
        and (.can_defer | type == "array")
        and (.next_step | type == "string")
        and (.reason | type == "string")
        and (.engineer_type | type == "string")
      ' "${json_file}" >/dev/null; then
        return 1
      fi
      ;;
    *)
      die "unsupported role: ${role}"
      ;;
  esac
}

codex_exec() {
  local role="$1"
  local prompt_file="$2"
  local schema_file="$3"
  local output_json_file="$4"
  local stderr_file="$5"

  local -a cmd=(codex exec)
  if [ "${role}" = "reviewer" ]; then
    cmd+=(--sandbox read-only)
  fi
  cmd+=(--output-schema "${schema_file}")

  if "${cmd[@]}" < "${prompt_file}" > "${output_json_file}" 2> "${stderr_file}"; then
    return 0
  fi
  return 1
}

curl_supports_fail_with_body() {
  curl --help all 2>/dev/null | grep -q -- '--fail-with-body'
}

gemini_request_payload() {
  local prompt_file="$1"
  local schema_file="$2"

  jq -nc \
    --rawfile prompt "${prompt_file}" \
    --slurpfile schema "${schema_file}" \
    '{
      contents: [
        {
          parts: [
            {
              text: $prompt
            }
          ]
        }
      ],
      generationConfig: {
        responseMimeType: "application/json",
        responseJsonSchema: $schema[0]
      }
    }'
}

gemini_http_call() {
  local payload_file="$1"
  local response_file="$2"
  local error_file="$3"
  local model="$4"
  local url="https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent"
  local -a cmd=(
    curl
    -sS
    -H "x-goog-api-key: ${GEMINI_API_KEY}"
    -H "Content-Type: application/json"
    -X POST
    "${url}"
    --data-binary "@${payload_file}"
  )

  if curl_supports_fail_with_body; then
    if "${cmd[@]}" --fail-with-body -o "${response_file}" 2> "${error_file}"; then
      return 0
    fi
    return 1
  fi

  local http_code=""
  if ! http_code="$("${cmd[@]}" -o "${response_file}" -w '%{http_code}' 2> "${error_file}")"; then
    return 1
  fi
  if ! [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
    {
      printf 'HTTP %s\n' "${http_code}"
      [ -f "${response_file}" ] && cat -- "${response_file}"
    } >> "${error_file}"
    return 1
  fi
}

gemini_parse_json_text() {
  local response_file="$1"
  local parsed_json_file="$2"

  if jq -e '.error' "${response_file}" >/dev/null 2>&1; then
    return 1
  fi

  local text_payload=""
  text_payload="$(jq -er '.candidates[0].content.parts[0].text' "${response_file}")" || return 1
  if ! printf '%s' "${text_payload}" | jq -e . > "${parsed_json_file}"; then
    return 1
  fi
}

provider_state_after_codex_success() {
  local provider_state_json="$1"

  printf '%s\n' "${provider_state_json}" | jq '
    .preferred_provider = "codex"
    | .last_used_provider = "codex"
    | .codex_consecutive_failures = 0
    | .cooldown_until = null
  '
}

provider_state_after_gemini_fallback_success() {
  local provider_state_json="$1"
  local codex_reason="$2"
  local now_iso="$3"
  local now_epoch="$4"

  local failures
  failures="$(printf '%s\n' "${provider_state_json}" | jq -r '(.codex_consecutive_failures // 0) + 1')"
  local cooldown_seconds cooldown_until
  cooldown_seconds="$(calculate_cooldown_seconds "${failures}")"
  cooldown_until="$(epoch_to_iso8601 "$((now_epoch + cooldown_seconds))")"

  printf '%s\n' "${provider_state_json}" | jq \
    --arg now "${now_iso}" \
    --arg reason "${codex_reason}" \
    --arg cooldown_until "${cooldown_until}" \
    --argjson failures "${failures}" \
    '
      .preferred_provider = "codex"
      | .last_used_provider = "gemini"
      | .codex_consecutive_failures = $failures
      | .fallback_count = ((.fallback_count // 0) + 1)
      | .last_fallback_at = $now
      | .last_fallback_reason = $reason
      | .cooldown_until = $cooldown_until
    '
}

provider_state_after_gemini_cooldown_success() {
  local provider_state_json="$1"

  printf '%s\n' "${provider_state_json}" | jq '
    .preferred_provider = "codex"
    | .last_used_provider = "gemini"
  '
}

main() {
  require_jq_min_version 1.6

  local role="" prompt_file="" schema_file="" output_file="" job_name=""
  local provider_role_arg="primary"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --role)
        role="${2:-}"
        shift 2
        ;;
      --prompt-file)
        prompt_file="${2:-}"
        shift 2
        ;;
      --schema-file)
        schema_file="${2:-}"
        shift 2
        ;;
      --output-file)
        output_file="${2:-}"
        shift 2
        ;;
      --job-name)
        job_name="${2:-}"
        shift 2
        ;;
      --provider-role)
        provider_role_arg="${2:-primary}"
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

  case "${role}" in
    reviewer|judge) ;;
    *)
      die "role must be reviewer or judge"
      ;;
  esac
  validate_job_name "${job_name}"
  [ -n "${prompt_file}" ] || die "prompt-file is required"
  [ -n "${schema_file}" ] || die "schema-file is required"
  [ -n "${output_file}" ] || die "output-file is required"

  ensure_job_exists "${job_name}"

  local normalized_prompt normalized_schema normalized_output
  normalized_prompt="$(normalize_repo_path "${prompt_file}")"
  normalized_schema="$(normalize_repo_path "${schema_file}")"
  normalized_output="$(normalize_repo_path "${output_file}")"

  local prompt_path="${REPO_ROOT}/${normalized_prompt}"
  local schema_path="${REPO_ROOT}/${normalized_schema}"
  local output_path="${REPO_ROOT}/${normalized_output}"

  [ -f "${prompt_path}" ] || die "prompt file not found: ${prompt_file}"
  [ -f "${schema_path}" ] || die "schema file not found: ${schema_file}"

  local codex_output="" codex_stderr=""
  local gemini_payload="" gemini_response="" gemini_error="" gemini_parsed=""

  cleanup() {
    [ -n "${codex_output:-}" ] && rm -f "${codex_output}"
    [ -n "${codex_stderr:-}" ] && rm -f "${codex_stderr}"
    [ -n "${gemini_payload:-}" ] && rm -f "${gemini_payload}"
    [ -n "${gemini_response:-}" ] && rm -f "${gemini_response}"
    [ -n "${gemini_error:-}" ] && rm -f "${gemini_error}"
    [ -n "${gemini_parsed:-}" ] && rm -f "${gemini_parsed}"
    release_job_lock
  }
  trap cleanup EXIT

  # Phase 1: read provider state under a short lock.
  acquire_job_lock "${job_name}"
  local provider_state_json
  provider_state_json="$(read_provider_state "${job_name}")"
  release_job_lock

  local provider_mode="codex_first"
  if cooldown_is_active "${provider_state_json}"; then
    provider_mode="gemini_cooldown"
  fi

  # shadow role の場合は Gemini を直接使う（現時点で shadow provider は Gemini 固定）
  if [ "${provider_role_arg}" = "shadow" ]; then
    provider_mode="shadow_gemini"
  fi

  codex_output="$(mktemp)"
  codex_stderr="$(mktemp)"
  gemini_payload="$(mktemp)"
  gemini_response="$(mktemp)"
  gemini_error="$(mktemp)"
  gemini_parsed="$(mktemp)"

  # Phase 2: run the AI call without holding the job lock.
  local result_source="" result_provider="" result_model="" result_codex_reason=""
  local final_event_reason="" final_event_result=""

  if [ "${provider_mode}" = "shadow_gemini" ]; then
    require_cmd curl
    [ -n "${GEMINI_API_KEY:-}" ] || die "GEMINI_API_KEY is required when shadow mode uses Gemini"

    gemini_request_payload "${prompt_path}" "${schema_path}" > "${gemini_payload}"
    if ! gemini_http_call "${gemini_payload}" "${gemini_response}" "${gemini_error}" "${GEMINI_MODEL:-gemini-2.5-flash-lite}"; then
      append_event_log_safe "$(events_path "${job_name}")" \
        "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "http_failure" "shadow")"
      die "gemini request failed in shadow mode"
    fi

    if ! gemini_parse_json_text "${gemini_response}" "${gemini_parsed}"; then
      append_event_log_safe "$(events_path "${job_name}")" \
        "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "invalid_response" "shadow")"
      die "gemini shadow response did not contain valid JSON"
    fi

    validate_role_json "${role}" "${gemini_parsed}" || {
      append_event_log_safe "$(events_path "${job_name}")" \
        "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "shape_check_failed" "shadow")"
      die "gemini shadow response failed shape check"
    }

    result_source="${gemini_parsed}"
    result_provider="gemini"
    result_model="${GEMINI_MODEL:-gemini-2.5-flash-lite}"
    final_event_reason="shadow"
    final_event_result="success"
  elif [ "${provider_mode}" = "gemini_cooldown" ]; then
    require_cmd curl
    [ -n "${GEMINI_API_KEY:-}" ] || die "GEMINI_API_KEY is required when Gemini fallback is used"

    gemini_request_payload "${prompt_path}" "${schema_path}" > "${gemini_payload}"
    if ! gemini_http_call "${gemini_payload}" "${gemini_response}" "${gemini_error}" "${GEMINI_MODEL:-gemini-2.5-flash-lite}"; then
      append_event_log_safe "$(events_path "${job_name}")" \
        "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "http_failure" "${provider_role_arg}")"
      die "gemini request failed during cooldown"
    fi

    if ! gemini_parse_json_text "${gemini_response}" "${gemini_parsed}"; then
      append_event_log_safe "$(events_path "${job_name}")" \
        "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "invalid_response" "${provider_role_arg}")"
      die "gemini response did not contain valid JSON"
    fi

    validate_role_json "${role}" "${gemini_parsed}" || {
      append_event_log_safe "$(events_path "${job_name}")" \
        "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "shape_check_failed" "${provider_role_arg}")"
      die "gemini response failed shape check"
    }

    result_source="${gemini_parsed}"
    result_provider="gemini"
    result_model="${GEMINI_MODEL:-gemini-2.5-flash-lite}"
    final_event_reason="cooldown_active"
    final_event_result="success"
  else
    require_cmd codex
    if codex_exec "${role}" "${prompt_path}" "${schema_path}" "${codex_output}" "${codex_stderr}"; then
      if ! jq -e . "${codex_output}" >/dev/null 2>&1; then
        append_event_log_safe "$(events_path "${job_name}")" \
          "$(ai_event_json "${job_name}" "${role}" "codex" "${CODEX_MODEL:-}" "failed" "invalid_json" "${provider_role_arg}")"
        die "codex returned invalid JSON"
      fi

      validate_role_json "${role}" "${codex_output}" || {
        append_event_log_safe "$(events_path "${job_name}")" \
          "$(ai_event_json "${job_name}" "${role}" "codex" "${CODEX_MODEL:-}" "failed" "shape_check_failed" "${provider_role_arg}")"
        die "codex output failed shape check"
      }

      result_source="${codex_output}"
      result_provider="codex"
      result_model="${CODEX_MODEL:-}"
      final_event_reason="ok"
      final_event_result="success"
    else
      result_codex_reason="$(codex_failure_reason "${codex_output}" "${codex_stderr}")"
      append_event_log_safe "$(events_path "${job_name}")" \
        "$(ai_event_json "${job_name}" "${role}" "codex" "${CODEX_MODEL:-}" "failed" "${result_codex_reason:-unknown_error}" "${provider_role_arg}")"

      [ -n "${result_codex_reason}" ] || die "codex failed with a non-fallback error"

      require_cmd curl
      [ -n "${GEMINI_API_KEY:-}" ] || die "GEMINI_API_KEY is required when Gemini fallback is used"

      gemini_request_payload "${prompt_path}" "${schema_path}" > "${gemini_payload}"
      if ! gemini_http_call "${gemini_payload}" "${gemini_response}" "${gemini_error}" "${GEMINI_MODEL:-gemini-2.5-flash-lite}"; then
        append_event_log_safe "$(events_path "${job_name}")" \
          "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "http_failure" "${provider_role_arg}")"
        die "gemini fallback request failed"
      fi

      if ! gemini_parse_json_text "${gemini_response}" "${gemini_parsed}"; then
        append_event_log_safe "$(events_path "${job_name}")" \
          "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "invalid_response" "${provider_role_arg}")"
        die "gemini fallback response did not contain valid JSON"
      fi

      validate_role_json "${role}" "${gemini_parsed}" || {
        append_event_log_safe "$(events_path "${job_name}")" \
          "$(ai_event_json "${job_name}" "${role}" "gemini" "${GEMINI_MODEL:-gemini-2.5-flash-lite}" "failed" "shape_check_failed" "${provider_role_arg}")"
        die "gemini fallback response failed shape check"
      }

      result_source="${gemini_parsed}"
      result_provider="gemini"
      result_model="${GEMINI_MODEL:-gemini-2.5-flash-lite}"
      final_event_reason="fallback_${result_codex_reason}"
      final_event_result="success"
    fi
  fi

  # Phase 3: persist output and provider state under a short lock.
  acquire_job_lock "${job_name}"

  jq '.' "${result_source}" | safe_write "${output_path}"

  # shadow 実行では provider_state を更新しない
  if [ "${provider_role_arg}" != "shadow" ]; then
    local fresh_provider_state_json
    fresh_provider_state_json="$(read_provider_state "${job_name}")"

    if [ "${result_provider}" = "codex" ]; then
      provider_state_after_codex_success "${fresh_provider_state_json}" | write_provider_state "${job_name}"
    elif [ "${provider_mode}" = "gemini_cooldown" ]; then
      provider_state_after_gemini_cooldown_success "${fresh_provider_state_json}" | write_provider_state "${job_name}"
    else
      provider_state_after_gemini_fallback_success \
        "${fresh_provider_state_json}" \
        "${result_codex_reason}" \
        "$(now_utc)" \
        "$(date -u +%s)" | write_provider_state "${job_name}"
    fi
  fi

  append_event_log_safe "$(events_path "${job_name}")" \
    "$(ai_event_json "${job_name}" "${role}" "${result_provider}" "${result_model}" "${final_event_result}" "${final_event_reason}" "${provider_role_arg}")"
}

main "$@"
