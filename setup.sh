#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CLAUDE_DIR="${SCRIPT_DIR}/.claude"
SOURCE_TOTONOE_DIR="${SCRIPT_DIR}/.totonoe"
GITIGNORE_ADDITIONS="${SCRIPT_DIR}/gitignore.additions"

usage() {
  cat <<'EOF'
Usage:
  ./setup.sh --target <repo-root> [--force]
  ./setup.sh --target <repo-root> --migrate-v2
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

copy_file_if_needed() {
  local source_file="$1"
  local target_file="$2"
  local force="$3"

  if [ -e "${target_file}" ] && [ "${force}" != "1" ]; then
    printf 'skip existing file: %s\n' "${target_file}"
    return
  fi

  mkdir -p "$(dirname -- "${target_file}")"
  cp "${source_file}" "${target_file}"
  printf 'copied: %s\n' "${target_file}"
}

append_gitignore_line() {
  local target_gitignore="$1"
  local line="$2"

  touch "${target_gitignore}"
  if grep -Fxq "${line}" "${target_gitignore}"; then
    return
  fi
  printf '%s\n' "${line}" >> "${target_gitignore}"
}

migrate_v2() {
  local target_repo="$1"
  local old_dir="${target_repo}/.claude/totonoe"
  local new_dir="${target_repo}/.totonoe"

  [ -d "${old_dir}" ] || die "v2 installation not found: ${old_dir}"
  [ ! -e "${new_dir}" ] || die ".totonoe already exists; remove it first or use fresh install"

  # 1. 新 runtime core をコピー
  mkdir -p "${new_dir}"
  cp -R "${SOURCE_TOTONOE_DIR}/bin" "${new_dir}/bin"
  cp -R "${SOURCE_TOTONOE_DIR}/migrations" "${new_dir}/migrations"
  cp -R "${SOURCE_TOTONOE_DIR}/schemas" "${new_dir}/schemas"
  cp -R "${SOURCE_TOTONOE_DIR}/goals" "${new_dir}/goals"
  cp "${SOURCE_TOTONOE_DIR}/VERSION" "${new_dir}/VERSION"
  cp "${SOURCE_TOTONOE_DIR}/RUNBOOK.md" "${new_dir}/RUNBOOK.md"
  cp "${SOURCE_TOTONOE_DIR}/README.md" "${new_dir}/README.md"
  cp "${SOURCE_TOTONOE_DIR}/SUPERVISOR.md" "${new_dir}/SUPERVISOR.md"
  chmod +x "${new_dir}"/bin/*.sh

  # 2. 既存データを移行（runtime/, knowledge.db*, config.json）
  [ -d "${old_dir}/runtime" ] && mv "${old_dir}/runtime" "${new_dir}/runtime"
  for db_file in knowledge.db knowledge.db-wal knowledge.db-shm; do
    [ -f "${old_dir}/${db_file}" ] && mv "${old_dir}/${db_file}" "${new_dir}/${db_file}"
  done
  [ -f "${old_dir}/config.json" ] && mv "${old_dir}/config.json" "${new_dir}/config.json"

  # 3. 旧ディレクトリを削除
  rm -rf "${old_dir}"

  # 4. settings.json の permission パスを更新
  local settings="${target_repo}/.claude/settings.json"
  if [ -f "${settings}" ]; then
    sed -i.bak 's|\.claude/totonoe/bin/|.totonoe/bin/|g' "${settings}"
    rm -f "${settings}.bak"
  fi

  # 5. .gitignore を更新（置換 + 不足行の追記）
  local gi="${target_repo}/.gitignore"
  if [ -f "${gi}" ]; then
    sed -i.bak 's|\.claude/totonoe/|.totonoe/|g' "${gi}"
    rm -f "${gi}.bak"
  fi
  while IFS= read -r gitignore_line; do
    [ -n "${gitignore_line}" ] || continue
    append_gitignore_line "${target_repo}/.gitignore" "${gitignore_line}"
  done < "${GITIGNORE_ADDITIONS}"

  # 6. テンプレートファイルを v3 で上書き
  cp "${SCRIPT_DIR}/CLAUDE.totonoe.template.md" "${target_repo}/CLAUDE.totonoe.template.md"
  printf 'updated: %s\n' "${target_repo}/CLAUDE.totonoe.template.md"
  cp "${SCRIPT_DIR}/AGENTS.totonoe.template.md" "${target_repo}/AGENTS.totonoe.template.md"
  printf 'updated: %s\n' "${target_repo}/AGENTS.totonoe.template.md"

  printf 'migration complete: %s → %s\n' "${old_dir}" "${new_dir}"
}

main() {
  local target_repo=""
  local force="0"
  local do_migrate_v2="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target)
        target_repo="${2:-}"
        shift 2
        ;;
      --force)
        force="1"
        shift
        ;;
      --migrate-v2)
        do_migrate_v2="1"
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

  [ -n "${target_repo}" ] || die "target is required"
  [ -d "${target_repo}" ] || die "target repo does not exist: ${target_repo}"

  if [ "${do_migrate_v2}" = "1" ]; then
    migrate_v2 "${target_repo}"
    return
  fi

  if [ -e "${target_repo}/.totonoe" ] && [ "${force}" != "1" ]; then
    die ".totonoe already exists in target; rerun with --force to overwrite"
  fi

  copy_file_if_needed \
    "${SOURCE_CLAUDE_DIR}/agents/MANAGER.md" \
    "${target_repo}/.claude/agents/MANAGER.md" \
    "${force}"
  copy_file_if_needed \
    "${SOURCE_CLAUDE_DIR}/agents/GENERIC-ENGINEER.md" \
    "${target_repo}/.claude/agents/GENERIC-ENGINEER.md" \
    "${force}"
  copy_file_if_needed \
    "${SOURCE_CLAUDE_DIR}/agents/SECURITY-ENGINEER.md" \
    "${target_repo}/.claude/agents/SECURITY-ENGINEER.md" \
    "${force}"
  copy_file_if_needed \
    "${SOURCE_CLAUDE_DIR}/agents/TEST-ENGINEER.md" \
    "${target_repo}/.claude/agents/TEST-ENGINEER.md" \
    "${force}"
  copy_file_if_needed \
    "${SOURCE_CLAUDE_DIR}/agents/PERF-ENGINEER.md" \
    "${target_repo}/.claude/agents/PERF-ENGINEER.md" \
    "${force}"
  copy_file_if_needed \
    "${SOURCE_CLAUDE_DIR}/agents/REFACTOR-ENGINEER.md" \
    "${target_repo}/.claude/agents/REFACTOR-ENGINEER.md" \
    "${force}"
  copy_file_if_needed \
    "${SOURCE_CLAUDE_DIR}/settings.json" \
    "${target_repo}/.claude/settings.json" \
    "${force}"

  rm -rf "${target_repo}/.totonoe"
  mkdir -p "${target_repo}"
  cp -R "${SOURCE_TOTONOE_DIR}" "${target_repo}/.totonoe"
  chmod +x "${target_repo}"/.totonoe/bin/*.sh
  printf 'copied: %s\n' "${target_repo}/.totonoe"

  copy_file_if_needed \
    "${SCRIPT_DIR}/CLAUDE.totonoe.template.md" \
    "${target_repo}/CLAUDE.totonoe.template.md" \
    "${force}"
  copy_file_if_needed \
    "${SCRIPT_DIR}/AGENTS.totonoe.template.md" \
    "${target_repo}/AGENTS.totonoe.template.md" \
    "${force}"
  copy_file_if_needed \
    "${SCRIPT_DIR}/.env.example" \
    "${target_repo}/.env.example" \
    "${force}"

  while IFS= read -r gitignore_line; do
    [ -n "${gitignore_line}" ] || continue
    append_gitignore_line "${target_repo}/.gitignore" "${gitignore_line}"
  done < "${GITIGNORE_ADDITIONS}"

  local totonoe_version=""
  if [ -f "${SOURCE_TOTONOE_DIR}/VERSION" ]; then
    totonoe_version="$(cat "${SOURCE_TOTONOE_DIR}/VERSION" | tr -d '[:space:]')"
  fi

  cat <<EOF
setup complete for: ${target_repo}
totonoe version: ${totonoe_version:-unknown}

next steps:
- Merge ${target_repo}/CLAUDE.totonoe.template.md into your CLAUDE.md
- Merge ${target_repo}/AGENTS.totonoe.template.md into your AGENTS.md
- Customize ${target_repo}/.claude/agents/GENERIC-ENGINEER.md for this repository
- Add or adjust specialized Engineers under ${target_repo}/.claude/agents as needed
- If ${target_repo}/.claude/settings.json already existed and was kept, manually merge the totonoe permissions into it
- Copy ${target_repo}/.env.example to ${target_repo}/.env and set GEMINI_API_KEY
  (Gemini is used for fallback and shadow mode; GEMINI_API_KEY is required to use these features)
EOF
}

main "$@"
