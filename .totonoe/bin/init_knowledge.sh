#!/usr/bin/env bash
# init_knowledge.sh — knowledge.db の初期化・マイグレーション
#
# 使用法: init_knowledge.sh [--force]
#
# - knowledge.db が存在しなければ作成し、スキーマを適用する
# - 既に存在する場合は schema_version を確認し、未適用のマイグレーションだけ実行する
# - --force: 既存の knowledge.db を削除して再作成する
#
# 終了コード:
#   0: 成功
#   1: sqlite3 が見つからない / エラー

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TOTONOE_DIR="$(CDPATH='' cd -- "${BIN_DIR}/.." && pwd -P)"

KNOWLEDGE_DB="${TOTONOE_DIR}/knowledge.db"
MIGRATIONS_DIR="${TOTONOE_DIR}/migrations"

# --- 引数解析 ---

force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    --help|-h)
      sed -n '2,/^$/s/^# \?//p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      printf 'エラー: 不明な引数: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

# --- sqlite3 存在確認 ---

if ! command -v sqlite3 >/dev/null 2>&1; then
  printf 'エラー: sqlite3 が見つかりません。インストールしてください。\n' >&2
  exit 1
fi

# --- --force 処理 ---

if [ "${force}" = "1" ] && [ -f "${KNOWLEDGE_DB}" ]; then
  rm -f "${KNOWLEDGE_DB}" "${KNOWLEDGE_DB}-wal" "${KNOWLEDGE_DB}-shm"
  printf 'knowledge.db を削除しました（--force）\n'
fi

# --- マイグレーション適用 ---

# 現在の schema_version を取得（DB が存在しない or テーブルがなければ 0）
current_version=0
if [ -f "${KNOWLEDGE_DB}" ]; then
  current_version=$(sqlite3 "${KNOWLEDGE_DB}" \
    "SELECT COALESCE(MAX(version), 0) FROM schema_version;" 2>/dev/null || echo 0)
fi

# マイグレーションファイルを番号順に取得して適用
applied=0
for migration_file in "${MIGRATIONS_DIR}"/[0-9][0-9][0-9]_*.sql; do
  [ -f "${migration_file}" ] || continue

  # ファイル名から番号を抽出（例: 001_initial.sql → 1）
  filename="$(basename "${migration_file}")"
  version=$(echo "${filename}" | sed 's/^0*//' | cut -d_ -f1)
  version=$((version))  # 数値に変換

  if [ "${version}" -le "${current_version}" ]; then
    continue
  fi

  printf 'マイグレーション適用中: %s\n' "${filename}"
  sqlite3 "${KNOWLEDGE_DB}" < "${migration_file}"
  applied=$((applied + 1))
done

if [ "${applied}" -eq 0 ] && [ -f "${KNOWLEDGE_DB}" ]; then
  printf 'knowledge.db は最新です（version: %s）\n' "${current_version}"
else
  final_version=$(sqlite3 "${KNOWLEDGE_DB}" "SELECT MAX(version) FROM schema_version;")
  printf 'knowledge.db を初期化しました（version: %s, 適用: %d 件）\n' "${final_version}" "${applied}"
fi
