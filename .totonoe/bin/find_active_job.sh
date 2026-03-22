#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

# RUNTIME_ROOT 配下の各ジョブの state.json を走査し、active なジョブを検出する。
#
# 終了コード:
#   0: active がちょうど 1 つ → stdout にジョブ名のみ 1 行
#   1: 0 件 → stdout 空
#   2: 複数件 → stderr に警告、updated_at が最も新しいジョブ名を stdout に 1 行

# pause_job.sh と一致する active ステータス一覧
readonly ACTIVE_STATUSES="init fix_requested continue_requested reviewing judging manager_review"

is_active_status() {
  local status="$1"
  local s
  for s in ${ACTIVE_STATUSES}; do
    [ "${s}" = "${status}" ] && return 0
  done
  return 1
}

main() {
  require_cmd jq

  if [ ! -d "${RUNTIME_ROOT}" ]; then
    exit 1
  fi

  local active_jobs=()
  local active_updated=()

  local job_entry
  for job_entry in "${RUNTIME_ROOT}"/*/; do
    [ -d "${job_entry}" ] || continue

    local job_name
    job_name="$(basename -- "${job_entry}")"

    # ジョブ名バリデーション（不正なディレクトリ名はスキップ）
    [[ "${job_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue

    # パストラバーサル回避: symlink チェック
    [ ! -L "${job_entry%/}" ] || continue

    local state_file="${job_entry}state.json"
    [ -f "${state_file}" ] || continue
    [ ! -L "${state_file}" ] || continue

    local status updated_at
    status="$(jq -r '.status // empty' "${state_file}" 2>/dev/null)" || continue
    [ -n "${status}" ] || continue

    if is_active_status "${status}"; then
      updated_at="$(jq -r '.updated_at // ""' "${state_file}" 2>/dev/null)" || updated_at=""
      active_jobs+=("${job_name}")
      active_updated+=("${updated_at}")
    fi
  done

  local count="${#active_jobs[@]}"

  if [ "${count}" -eq 0 ]; then
    exit 1
  fi

  if [ "${count}" -eq 1 ]; then
    printf '%s\n' "${active_jobs[0]}"
    exit 0
  fi

  # 複数件: updated_at が最も新しいものを選ぶ（ISO 文字列比較）
  warn "複数の active ジョブを検出しました (${count} 件): ${active_jobs[*]}"

  local best_idx=0
  local best_ts="${active_updated[0]}"
  local i
  for (( i = 1; i < count; i++ )); do
    if [[ "${active_updated[i]}" > "${best_ts}" ]]; then
      best_idx="${i}"
      best_ts="${active_updated[i]}"
    fi
  done

  printf '%s\n' "${active_jobs[${best_idx}]}"
  exit 2
}

main "$@"
