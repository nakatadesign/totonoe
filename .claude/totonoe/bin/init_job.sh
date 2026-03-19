#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/init_job.sh \
    --job-name <name> \
    --goal-template <template> | --goal-file <path> | --goal-text "<text>" \
    [--max-rounds <n>] \
    [--with-knowledge] \
    [--force]
EOF
}

main() {
  require_cmd jq
  ensure_runtime_root

  local job_name=""
  local goal_template=""
  local goal_file=""
  local goal_text=""
  local max_rounds="8"
  local with_knowledge="0"
  local force="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
        shift 2
        ;;
      --goal-template)
        goal_template="${2:-}"
        shift 2
        ;;
      --goal-file)
        goal_file="${2:-}"
        shift 2
        ;;
      --goal-text)
        goal_text="${2:-}"
        shift 2
        ;;
      --max-rounds)
        max_rounds="${2:-}"
        shift 2
        ;;
      --with-knowledge)
        with_knowledge="1"
        shift
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
  [[ "${max_rounds}" =~ ^[0-9]+$ ]] || die "max rounds must be numeric"
  [ "${max_rounds}" -gt 0 ] || die "max rounds must be positive"

  local goal_option_count=0
  [ -n "${goal_template}" ] && goal_option_count=$((goal_option_count + 1))
  [ -n "${goal_file}" ] && goal_option_count=$((goal_option_count + 1))
  [ -n "${goal_text}" ] && goal_option_count=$((goal_option_count + 1))
  [ "${goal_option_count}" -eq 1 ] || die "specify exactly one goal source"

  local job_path
  job_path="$(job_dir "${job_name}")"

  if [ -e "${job_path}" ]; then
    [ "${force}" = "1" ] || die "job already exists: ${job_name}"
    assert_safe_job_reset_target "${job_name}"
    rm -rf "${job_path}"
  fi

  mkdir -p "${job_path}/rounds"

  local goal_content=""
  if [ -n "${goal_template}" ]; then
    local template_path="${GOALS_DIR}/${goal_template}.md"
    [ -f "${template_path}" ] || die "goal template not found: ${goal_template}"
    goal_content="$(safe_read "${template_path}")"
  elif [ -n "${goal_file}" ]; then
    local normalized_goal_file
    normalized_goal_file="$(normalize_repo_path "${goal_file}")"
    goal_content="$(safe_read "${REPO_ROOT}/${normalized_goal_file}")"
  else
    goal_content="${goal_text}"
  fi

  printf '%s\n' "${goal_content}" | safe_write "$(goal_path "${job_name}")"

  default_provider_state_json | write_provider_state "${job_name}"

  local knowledge_enabled="false"
  if [ "${with_knowledge}" = "1" ]; then
    "${BIN_DIR}/init_knowledge.sh"
    knowledge_enabled="true"
  fi

  jq -n \
    --arg job_name "${job_name}" \
    --arg repo_root "${REPO_ROOT}" \
    --arg now "$(now_utc)" \
    --argjson max_rounds "${max_rounds}" \
    --argjson knowledge_enabled "${knowledge_enabled}" \
    '{
      job_name: $job_name,
      repo_root: $repo_root,
      created_at: $now,
      updated_at: $now,
      current_round: 0,
      max_rounds: $max_rounds,
      status: "init",
      pause: null,
      last_decision: null,
      last_reviewer_grade: null,
      last_critical_count: 0,
      manager_spot_check: null,
      knowledge_enabled: $knowledge_enabled
    }' | safe_write "$(state_path "${job_name}")"

  jq -nc \
    --arg ts "$(now_utc)" \
    --arg job "${job_name}" \
    '{
      ts: $ts,
      type: "job_initialized",
      job: $job,
      result: "success"
    }' | safe_write "$(events_path "${job_name}")"

  printf 'initialized job: %s\n' "${job_name}"
}

main "$@"
