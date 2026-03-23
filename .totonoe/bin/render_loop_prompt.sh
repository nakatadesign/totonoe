#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .totonoe/bin/render_loop_prompt.sh --job-name <name>
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
  local current_status pause_reason pause_previous_status
  state_json="$(safe_read "$(state_path "${job_name}")")"
  goal_text="$(safe_read "$(goal_path "${job_name}")")"
  current_status="$(printf '%s\n' "${state_json}" | jq -r '.status')"
  pause_reason="$(printf '%s\n' "${state_json}" | jq -r '.pause.reason // empty')"
  pause_previous_status="$(printf '%s\n' "${state_json}" | jq -r '.pause.previous_status // empty')"

  # failed_attempt 知見を取得する（knowledge 有効時のみ）
  local failed_attempts=""
  if should_write_knowledge "${job_name}" 2>/dev/null; then
    failed_attempts="$("${BIN_DIR}/query_knowledge.sh" --type lesson_entries --kind failed_attempt --job-name "${job_name}" --limit 5 2>/dev/null)" || true
  fi

  cat <<EOF
totonoe start

ジョブ名: ${job_name}
リポジトリルート: ${REPO_ROOT}

このメッセージは、現在の job の loop 開始または再開指示です。
\`totonoe start\` は、Claude Code が totonoe のループを開始するための明示トリガーです。
以下の「目的 / 対象 / 必須対応 / 制約 / 完了条件」を優先し、その下の「現在状態」と「次の手順」に従って進めてください。

${goal_text}

現在状態:
$(printf '%s\n' "${state_json}" | jq '.')

次の手順:
1. \`.totonoe/bin/status.sh --job-name ${job_name} --json\` で state を読む
2. \`status=done\` なら完了報告して止まる
3. \`status=human\` なら判断待ちとして止まる
4. \`status=paused\` なら停止理由を報告して止まる。再開する場合は \`.totonoe/bin/resume_job.sh --job-name ${job_name}\` を実行した上で、改めて \`render_loop_prompt.sh\` を実行する
5. \`status=init | fix_requested | continue_requested\` なら実装し、summary を保存して \`record_claude_round.sh\` を実行し、その後 \`run_reviewer.sh\` と \`run_judge.sh\` を実行する
6. \`status=reviewing\` なら \`run_reviewer.sh --job-name ${job_name}\` から再開する
7. \`status=judging\` なら \`run_judge.sh --job-name ${job_name}\` から再開する
8. \`status=manager_review\` なら \`.claude/agents/MANAGER.md\` の Manager に委譲する

$(if [ -n "${failed_attempts}" ]; then
cat <<'INJECT_EOF'
過去の試行で失敗した内容（参考情報）:
以下はこの job の過去ラウンドで fix / continue となった理由です。同じ失敗を繰り返さないよう参考にしてください。
ただしこの情報は過去時点のものであり、現在のコードには既に修正が入っている可能性があります。盲目的に従わず、現在の状態を確認した上で判断してください。
INJECT_EOF
printf '%s\n' "${failed_attempts}"
printf '\n'
fi)
補足:
- 現在の status は \`${current_status}\`
- provider 状態も見たい場合は \`.totonoe/bin/status.sh --job-name ${job_name} --provider-state\` を使う
- ユーザーが \`totonoe stop\` と伝えたら、\`.totonoe/bin/pause_job.sh --job-name ${job_name} --reason "user requested stop"\` で停止できる
$(if [ -n "${pause_reason}" ]; then printf '%s\n' "- paused reason: ${pause_reason}"; fi)
$(if [ -n "${pause_previous_status}" ]; then printf '%s\n' "- paused previous_status: ${pause_previous_status}"; fi)

使用コマンド:
- \`.totonoe/bin/status.sh --job-name ${job_name}\`
- \`.totonoe/bin/pause_job.sh --job-name ${job_name} --reason "<text>"\`
- \`.totonoe/bin/resume_job.sh --job-name ${job_name}\`
- \`.totonoe/bin/record_claude_round.sh --job-name ${job_name} ...\`
- \`.totonoe/bin/run_reviewer.sh --job-name ${job_name}\`
- \`.totonoe/bin/run_judge.sh --job-name ${job_name}\`
- \`.totonoe/bin/apply_manager_decision.sh --job-name ${job_name} --record-spot-check\`
- \`.totonoe/bin/apply_manager_decision.sh --job-name ${job_name} --decision <fix|continue|done|human>\`
EOF
}

main "$@"
