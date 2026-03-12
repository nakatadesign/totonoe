#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/render_loop_prompt.sh --job-name <name>
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

  local state_json goal_text
  local current_status
  state_json="$(safe_read "$(state_path "${job_name}")")"
  goal_text="$(safe_read "$(goal_path "${job_name}")")"
  current_status="$(printf '%s\n' "${state_json}" | jq -r '.status')"

  cat <<EOF
active job: ${job_name}
repo root: ${REPO_ROOT}

goal:
${goal_text}

state:
$(printf '%s\n' "${state_json}" | jq '.')

totonoe tick:
1. \`.claude/totonoe/bin/status.sh --job-name ${job_name} --json\` で state を読む
2. \`status=done\` なら完了報告して止まる
3. \`status=human\` なら判断待ちとして止まる
4. \`status=init | fix_requested | continue_requested\` なら実装し、summary を保存して \`record_claude_round.sh\` を実行し、その後 \`run_reviewer.sh\` と \`run_judge.sh\` を実行する
5. \`status=reviewing\` なら \`run_reviewer.sh --job-name ${job_name}\` から再開する
6. \`status=judging\` なら \`run_judge.sh --job-name ${job_name}\` から再開する
7. \`status=manager_review\` なら \`.claude/agents/MANAGER.md\` の Manager に委譲する

current status guidance:
- 現在の status は \`${current_status}\`
- provider 状態も見たい場合は \`.claude/totonoe/bin/status.sh --job-name ${job_name} --provider-state\` を使う

使用コマンド:
- \`.claude/totonoe/bin/status.sh --job-name ${job_name}\`
- \`.claude/totonoe/bin/record_claude_round.sh --job-name ${job_name} ...\`
- \`.claude/totonoe/bin/run_reviewer.sh --job-name ${job_name}\`
- \`.claude/totonoe/bin/run_judge.sh --job-name ${job_name}\`
- \`.claude/totonoe/bin/apply_manager_decision.sh --job-name ${job_name} --record-spot-check\`
- \`.claude/totonoe/bin/apply_manager_decision.sh --job-name ${job_name} --decision <fix|continue|done|human>\`
EOF
}

main "$@"
