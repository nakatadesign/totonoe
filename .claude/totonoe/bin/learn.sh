#!/usr/bin/env bash
# learn.sh — ジョブ完了時の知見保存
#
# 使用法: learn.sh --job-name <name> [--lesson "<text>"]
#
# - review_findings の resolved フラグを 1 に一括更新する（そのジョブ全件）
# - --lesson が指定された場合、lessons テーブルに保存する（INSERT OR REPLACE）
# - knowledge_enabled でない、または knowledge.db がない場合は no-op で exit 0
#
# 終了コード:
#   0: 成功（no-op 含む）
#   1: エラー

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

main() {
  local job_name=""
  local lesson=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
        shift 2
        ;;
      --lesson)
        lesson="${2:-}"
        shift 2
        ;;
      --help|-h)
        sed -n '2,/^$/s/^# \?//p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
      *)
        die "不明な引数: $1"
        ;;
    esac
  done

  [ -n "${job_name}" ] || die "--job-name は必須です"
  validate_job_name "${job_name}"

  # knowledge 無効 or DB 不在 → no-op
  should_write_knowledge "${job_name}" || return 0

  # 1 transaction で resolved 更新 + lesson upsert を行う
  local q_jn
  q_jn="$(_sql_quote "${job_name}")"

  local sql="BEGIN;"
  sql+="UPDATE review_findings SET resolved = 1 WHERE job_name = ${q_jn};"

  if [ -n "${lesson}" ]; then
    local q_lesson
    q_lesson="$(_sql_quote "${lesson}")"
    sql+="INSERT OR REPLACE INTO lessons (job_name, lesson) VALUES (${q_jn}, ${q_lesson});"
  fi

  sql+="COMMIT;"

  _kdb_exec "${sql}"

  if [ -n "${lesson}" ]; then
    printf 'learned for job %s (resolved + lesson saved)\n' "${job_name}"
  else
    printf 'learned for job %s (resolved only)\n' "${job_name}"
  fi
}

main "$@"
