#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/templates.sh
  .claude/totonoe/bin/templates.sh --show <template-name>
EOF
}

main() {
  local show_template=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --show)
        show_template="${2:-}"
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

  if [ -n "${show_template}" ]; then
    local template_path="${GOALS_DIR}/${show_template}.md"
    [ -f "${template_path}" ] || die "template not found: ${show_template}"
    safe_read "${template_path}"
    exit 0
  fi

  find "${GOALS_DIR}" -maxdepth 1 -type f -name '*.md' -print \
    | sed "s#${GOALS_DIR}/##" \
    | sed 's/\.md$//' \
    | sort
}

main "$@"
