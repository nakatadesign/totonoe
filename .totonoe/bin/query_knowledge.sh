#!/usr/bin/env bash
# query_knowledge.sh — knowledge.db から過去の知見を検索する
#
# 使用法:
#   query_knowledge.sh --type findings [--severity critical] [--job-name xxx] [--limit N] [--max-chars N]
#   query_knowledge.sh --type verdicts [--engineer-type security] [--limit N] [--max-chars N]
#   query_knowledge.sh --type summary [--max-chars N]
#
# 出力形式: プロンプトに埋め込みやすいプレーンテキスト（stdout）
#
# 終了コード:
#   0: 結果あり
#   1: 結果なし
#   2: knowledge.db が存在しない

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

# --- マルチバイト安全な文字数切り詰め ---
_truncate_chars() {
  local max_chars="$1"
  awk -v max="${max_chars}" '
    BEGIN { out = "" }
    { out = out (NR > 1 ? "\n" : "") $0 }
    END {
      if (length(out) > max) {
        print substr(out, 1, max) " [truncated]"
      } else {
        print out
      }
    }
  '
}

# --- findings クエリ ---
_query_findings() {
  local limit="$1"
  local severity_filter="$2"
  local job_name_filter="$3"

  local where="resolved = 0"
  if [ -n "${severity_filter}" ]; then
    local q_sev
    q_sev="$(_sql_quote "${severity_filter}")"
    where="${where} AND severity = ${q_sev}"
  fi
  if [ -n "${job_name_filter}" ]; then
    local q_jn
    q_jn="$(_sql_quote "${job_name_filter}")"
    where="${where} AND job_name = ${q_jn}"
  fi

  # JSON 行で返し、jq で整形する（フィールドに | が入っても壊れない）
  local json_rows
  json_rows="$(_kdb_exec "
    SELECT json_object(
      'severity', severity,
      'file', file,
      'title', title,
      'reason', reason,
      'job_name', job_name,
      'round', round
    )
    FROM review_findings
    WHERE ${where}
    ORDER BY
      CASE severity
        WHEN 'critical' THEN 0
        WHEN 'high' THEN 1
        WHEN 'medium' THEN 2
        WHEN 'low' THEN 3
      END,
      created_at DESC
    LIMIT ${limit};
  ")"

  [ -n "${json_rows}" ] || return 1

  printf '%s\n' "${json_rows}" | jq -r \
    '"- [\(.severity)] \(.file): \(.title) — \(.reason) (job: \(.job_name), round: \(.round))"'
}

# --- verdicts クエリ ---
_query_verdicts() {
  local limit="$1"
  local engineer_type_filter="$2"

  local where="1=1"
  if [ -n "${engineer_type_filter}" ]; then
    local q_et
    q_et="$(_sql_quote "${engineer_type_filter}")"
    where="engineer_type = ${q_et}"
  fi

  local json_rows
  json_rows="$(_kdb_exec "
    SELECT json_object(
      'recommendation', recommendation,
      'engineer_type', engineer_type,
      'reason', reason,
      'job_name', job_name,
      'round', round
    )
    FROM verdicts
    WHERE ${where}
    ORDER BY created_at DESC
    LIMIT ${limit};
  ")"

  [ -n "${json_rows}" ] || return 1

  printf '%s\n' "${json_rows}" | jq -r \
    '"- \(.recommendation) (\(.engineer_type)): \(.reason) (job: \(.job_name), round: \(.round))"'
}

# --- lessons クエリ ---
_query_lessons() {
  local limit="$1"

  local json_rows
  json_rows="$(_kdb_exec "
    SELECT json_object(
      'job_name', job_name,
      'lesson', lesson,
      'created_at', created_at
    )
    FROM lessons
    ORDER BY created_at DESC
    LIMIT ${limit};
  ")"

  [ -n "${json_rows}" ] || return 1

  printf '%s\n' "${json_rows}" | jq -r \
    '"- [\(.job_name)] \(.lesson)"'
}

# --- summary クエリ ---
_query_summary() {
  local job_count round_count grade_dist severity_top engineer_top

  job_count="$(_kdb_exec "SELECT COUNT(DISTINCT job_name) FROM review_rounds;")"
  round_count="$(_kdb_exec "SELECT COUNT(*) FROM review_rounds;")"

  [ "${round_count}" -gt 0 ] 2>/dev/null || return 1

  grade_dist="$(_kdb_exec "
    SELECT 'S=' || SUM(CASE WHEN overall_grade='S' THEN 1 ELSE 0 END)
      || ' A=' || SUM(CASE WHEN overall_grade='A' THEN 1 ELSE 0 END)
      || ' B=' || SUM(CASE WHEN overall_grade='B' THEN 1 ELSE 0 END)
      || ' C=' || SUM(CASE WHEN overall_grade='C' THEN 1 ELSE 0 END)
    FROM review_rounds;
  ")"

  severity_top="$(_kdb_exec "
    SELECT severity || '=' || COUNT(*)
    FROM review_findings
    GROUP BY severity
    ORDER BY COUNT(*) DESC
    LIMIT 3;
  " | tr '\n' ' ')"

  engineer_top="$(_kdb_exec "
    SELECT engineer_type || '=' || COUNT(*)
    FROM verdicts
    GROUP BY engineer_type
    ORDER BY COUNT(*) DESC
    LIMIT 3;
  " | tr '\n' ' ')"

  printf 'ジョブ数: %s / ラウンド数: %s\n' "${job_count}" "${round_count}"
  printf 'グレード分布: %s\n' "${grade_dist}"
  [ -n "${severity_top}" ] && printf 'severity 上位: %s\n' "${severity_top}"
  [ -n "${engineer_top}" ] && printf 'engineer_type 傾向: %s\n' "${engineer_top}"
}

# --- main ---

main() {
  local query_type=""
  local limit="3"
  local max_chars=""
  local severity=""
  local job_name_filter=""
  local engineer_type=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --type)
        query_type="${2:-}"
        shift 2
        ;;
      --limit)
        limit="${2:-3}"
        shift 2
        ;;
      --max-chars)
        max_chars="${2:-}"
        shift 2
        ;;
      --severity)
        severity="${2:-}"
        shift 2
        ;;
      --job-name)
        job_name_filter="${2:-}"
        shift 2
        ;;
      --engineer-type)
        engineer_type="${2:-}"
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

  [ -n "${query_type}" ] || die "--type は必須です（findings / verdicts / lessons / summary）"

  # 引数検証
  [[ "${limit}" =~ ^[0-9]+$ ]] && [ "${limit}" -gt 0 ] \
    || die "--limit は正の整数を指定してください: '${limit}'"
  if [ -n "${max_chars}" ]; then
    [[ "${max_chars}" =~ ^[0-9]+$ ]] && [ "${max_chars}" -gt 0 ] \
      || die "--max-chars は正の整数を指定してください: '${max_chars}'"
  fi

  # knowledge.db が存在しなければ exit 2 で静かに終了する
  if [ ! -f "${KNOWLEDGE_DB}" ]; then
    exit 2
  fi

  local output=""
  case "${query_type}" in
    findings)
      output="$(_query_findings "${limit}" "${severity}" "${job_name_filter}")" || exit 1
      ;;
    verdicts)
      output="$(_query_verdicts "${limit}" "${engineer_type}")" || exit 1
      ;;
    lessons)
      output="$(_query_lessons "${limit}")" || exit 1
      ;;
    summary)
      output="$(_query_summary)" || exit 1
      ;;
    *)
      die "不明な --type: ${query_type}（findings / verdicts / lessons / summary のいずれか）"
      ;;
  esac

  if [ -n "${max_chars}" ]; then
    printf '%s' "${output}" | _truncate_chars "${max_chars}"
  else
    printf '%s' "${output}"
  fi
}

main "$@"
