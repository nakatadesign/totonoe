#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CLAUDE_DIR="${SCRIPT_DIR}/.claude"
GITIGNORE_ADDITIONS="${SCRIPT_DIR}/gitignore.additions"

usage() {
  cat <<'EOF'
Usage:
  ./setup.sh --target <repo-root> [--force]
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

main() {
  local target_repo=""
  local force="0"

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

  if [ -e "${target_repo}/.claude/totonoe" ] && [ "${force}" != "1" ]; then
    die ".claude/totonoe already exists in target; rerun with --force to overwrite"
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

  rm -rf "${target_repo}/.claude/totonoe"
  mkdir -p "${target_repo}/.claude"
  cp -R "${SOURCE_CLAUDE_DIR}/totonoe" "${target_repo}/.claude/totonoe"
  chmod +x "${target_repo}"/.claude/totonoe/bin/*.sh
  printf 'copied: %s\n' "${target_repo}/.claude/totonoe"

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

  cat <<EOF
setup complete for: ${target_repo}

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
