#!/usr/bin/env bash

# PreCompact フック: コンテキスト圧縮直前に active ジョブを自動で paused にする。
# Claude Code の hooks.PreCompact から呼ばれる。
# フック失敗で Claude のループを壊さないよう、常に exit 0 で終了する。

set -uo pipefail

HOOKS_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="$(CDPATH='' cd -- "${HOOKS_DIR}/.." && pwd -P)"

# find_active_job.sh の stderr（複数 active 時の警告）はログに残す
active_job="$("${BIN_DIR}/find_active_job.sh" || true)"

if [ -z "${active_job}" ]; then
  exit 0
fi

if "${BIN_DIR}/pause_job.sh" \
  --job-name "${active_job}" \
  --reason "PreCompact triggered: context compression detected"; then
  printf '[totonoe/precompact] ジョブ "%s" を paused にしました。再開: resume_job.sh → render_loop_prompt.sh\n' "${active_job}" >&2
else
  printf '[totonoe/precompact] WARN: ジョブ "%s" の pause に失敗しました（既に paused/done の可能性あり）\n' "${active_job}" >&2
fi

exit 0
