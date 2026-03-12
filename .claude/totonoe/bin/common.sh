#!/usr/bin/env bash

set -euo pipefail

COMMON_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TOTONOE_DIR="$(CDPATH='' cd -- "${COMMON_DIR}/.." && pwd -P)"
CLAUDE_DIR="$(CDPATH='' cd -- "${TOTONOE_DIR}/.." && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "${CLAUDE_DIR}/.." && pwd -P)"
RUNTIME_ROOT="${TOTONOE_DIR}/runtime"
GOALS_DIR="${TOTONOE_DIR}/goals"
SCHEMAS_DIR="${TOTONOE_DIR}/schemas"

JOB_LOCK_MODE=""
JOB_LOCK_FD=""
JOB_LOCK_DIR=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_jq_min_version() {
  require_cmd jq

  local minimum="${1:-1.6}"
  local current raw_version current_major current_minor minimum_major minimum_minor
  raw_version="$(jq --version 2>/dev/null)" || die "unable to determine jq version"
  current="${raw_version#jq-}"
  current="${current%%[^0-9.]*}"

  current_major="${current%%.*}"
  current_minor="${current#*.}"
  current_minor="${current_minor%%.*}"
  minimum_major="${minimum%%.*}"
  minimum_minor="${minimum#*.}"
  minimum_minor="${minimum_minor%%.*}"

  [[ "${current_major}" =~ ^[0-9]+$ ]] || die "unexpected jq version: ${raw_version}"
  [[ "${current_minor}" =~ ^[0-9]+$ ]] || die "unexpected jq version: ${raw_version}"

  if [ "${current_major}" -lt "${minimum_major}" ] || {
    [ "${current_major}" -eq "${minimum_major}" ] && [ "${current_minor}" -lt "${minimum_minor}" ]
  }; then
    die "jq >= ${minimum} is required, found ${raw_version}"
  fi
}

validate_job_name() {
  local job_name="${1:-}"
  [[ -n "${job_name}" ]] || die "job name is required"
  [[ "${job_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid job name: ${job_name}"
}

portable_realpath() {
  local target="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "${target}"
    return
  fi
  perl -MCwd=abs_path -e '
    my $path = shift @ARGV;
    my $resolved = abs_path($path);
    die "cannot resolve path\n" if !defined $resolved;
    print "$resolved\n";
  ' "${target}"
}

canonical_existing_path() {
  local target="$1"
  [ -e "${target}" ] || die "path does not exist: ${target}"
  portable_realpath "${target}"
}

canonical_target_path() {
  local target="$1"
  if [ -e "${target}" ]; then
    canonical_existing_path "${target}"
    return
  fi

  # When the file and some parent directories were deleted, walk upward
  # until an existing ancestor is found and then rebuild the target path.
  local current="${target}"
  local trailing=""
  while true; do
    local parent
    parent="$(dirname -- "${current}")"
    [ "${parent}" != "${current}" ] || die "no existing ancestor found for: ${target}"

    local name
    name="$(basename -- "${current}")"
    trailing="${name}${trailing:+/}${trailing}"
    current="${parent}"

    if [ -d "${current}" ]; then
      local canonical_current
      canonical_current="$(canonical_existing_path "${current}")"
      printf '%s/%s\n' "${canonical_current}" "${trailing}"
      return
    fi
  done
}

assert_path_within() {
  local root="$1"
  local candidate="$2"
  case "${candidate}" in
    "${root}"|${root}/*) ;;
    *) die "path escapes root: ${candidate}" ;;
  esac
}

file_link_count() {
  local path="$1"
  local count=""
  if count="$(stat -f '%l' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${count}"
    return
  fi
  if count="$(stat -c '%h' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${count}"
    return
  fi
  die "unable to determine link count: ${path}"
}

assert_regular_file_safe() {
  local path="$1"
  [ -L "${path}" ] && die "symlink is not allowed: ${path}"
  [ -f "${path}" ] || die "regular file expected: ${path}"
  [ "$(file_link_count "${path}")" -eq 1 ] || die "hardlink is not allowed: ${path}"
}

ensure_runtime_root() {
  [ ! -L "${RUNTIME_ROOT}" ] || die "runtime root cannot be a symlink"
  mkdir -p "${RUNTIME_ROOT}"
  local canonical_runtime
  canonical_runtime="$(canonical_existing_path "${RUNTIME_ROOT}")"
  assert_path_within "${REPO_ROOT}" "${canonical_runtime}"
}

job_dir() {
  validate_job_name "$1"
  printf '%s/%s\n' "${RUNTIME_ROOT}" "$1"
}

round_dir() {
  local job_name="$1"
  local round_number="$2"
  printf '%s/rounds/%03d\n' "$(job_dir "${job_name}")" "${round_number}"
}

state_path() {
  printf '%s/state.json\n' "$(job_dir "$1")"
}

goal_path() {
  printf '%s/goal.md\n' "$(job_dir "$1")"
}

events_path() {
  printf '%s/events.jsonl\n' "$(job_dir "$1")"
}

provider_state_path() {
  printf '%s/provider_state.json\n' "$(job_dir "$1")"
}

default_provider_state_json() {
  jq -n '{
    preferred_provider: "codex",
    last_used_provider: "codex",
    codex_consecutive_failures: 0,
    fallback_count: 0,
    last_fallback_at: null,
    last_fallback_reason: null,
    cooldown_until: null
  }'
}

read_provider_state() {
  local job_name="$1"
  local path
  path="$(provider_state_path "${job_name}")"
  if [ -f "${path}" ]; then
    safe_read "${path}"
    return
  fi
  default_provider_state_json
}

write_provider_state() {
  local job_name="$1"
  safe_write "$(provider_state_path "${job_name}")"
}

ensure_job_exists() {
  local job_name="$1"
  local job_path
  ensure_runtime_root
  job_path="$(job_dir "${job_name}")"
  [ -d "${job_path}" ] || die "job does not exist: ${job_name}"
  [ ! -L "${job_path}" ] || die "job directory cannot be a symlink"
  local canonical_job
  canonical_job="$(canonical_existing_path "${job_path}")"
  assert_path_within "${RUNTIME_ROOT}" "${canonical_job}"
}

assert_safe_job_reset_target() {
  local job_name="$1"
  local job_path
  job_path="$(job_dir "${job_name}")"
  [ -e "${job_path}" ] || return 0
  [ ! -L "${job_path}" ] || die "refusing to reset symlinked job directory"
  local canonical_job
  canonical_job="$(canonical_existing_path "${job_path}")"
  assert_path_within "${RUNTIME_ROOT}" "${canonical_job}"
}

safe_read() {
  local target="$1"
  local canonical_target
  [ -e "${target}" ] || die "file does not exist: ${target}"
  assert_regular_file_safe "${target}"
  canonical_target="$(canonical_existing_path "${target}")"
  assert_path_within "${REPO_ROOT}" "${canonical_target}"
  cat -- "${target}"
}

safe_write() {
  local target="$1"
  local parent canonical_parent canonical_target tmp_file

  parent="$(dirname -- "${target}")"
  mkdir -p "${parent}"
  canonical_parent="$(canonical_existing_path "${parent}")"
  assert_path_within "${REPO_ROOT}" "${canonical_parent}"

  if [ -e "${target}" ]; then
    assert_regular_file_safe "${target}"
    canonical_target="$(canonical_existing_path "${target}")"
    assert_path_within "${REPO_ROOT}" "${canonical_target}"
  fi

  tmp_file="$(mktemp "${canonical_parent}/.tmp.write.XXXXXX")"
  cat > "${tmp_file}"
  chmod 600 "${tmp_file}" 2>/dev/null || true
  mv -f "${tmp_file}" "${target}"
}

append_event_log_safe() {
  local target="$1"
  local line="$2"
  local parent canonical_parent

  parent="$(dirname -- "${target}")"
  mkdir -p "${parent}"
  canonical_parent="$(canonical_existing_path "${parent}")"
  assert_path_within "${REPO_ROOT}" "${canonical_parent}"

  if [ -e "${target}" ]; then
    assert_regular_file_safe "${target}"
  else
    : > "${target}"
  fi

  printf '%s\n' "${line}" >> "${target}"
}

normalize_repo_path() {
  local input_path="$1"
  local target_path canonical_target

  if [[ "${input_path}" = /* ]]; then
    target_path="${input_path}"
  else
    target_path="${REPO_ROOT}/${input_path}"
  fi

  canonical_target="$(canonical_target_path "${target_path}")"
  assert_path_within "${REPO_ROOT}" "${canonical_target}"

  if [ "${canonical_target}" = "${REPO_ROOT}" ]; then
    die "path cannot point to repository root"
  fi

  printf '%s\n' "${canonical_target#"${REPO_ROOT}/"}"
}

acquire_job_lock() {
  local job_name="$1"
  local lock_file

  ensure_job_exists "${job_name}"
  lock_file="$(job_dir "${job_name}")/.job.lock"

  if command -v flock >/dev/null 2>&1; then
    exec {JOB_LOCK_FD}> "${lock_file}"
    flock -x "${JOB_LOCK_FD}" || die "failed to acquire lock"
    JOB_LOCK_MODE="flock"
    return
  fi

  JOB_LOCK_DIR="${lock_file}.d"
  JOB_LOCK_MODE="mkdir"
  local attempts=0
  while ! mkdir "${JOB_LOCK_DIR}" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "${attempts}" -lt 300 ] || die "timed out acquiring lock"
    sleep 0.1
  done
}

release_job_lock() {
  case "${JOB_LOCK_MODE}" in
    flock)
      flock -u "${JOB_LOCK_FD}" || true
      eval "exec ${JOB_LOCK_FD}>&-"
      JOB_LOCK_FD=""
      ;;
    mkdir)
      [ -n "${JOB_LOCK_DIR}" ] && rmdir "${JOB_LOCK_DIR}" 2>/dev/null || true
      JOB_LOCK_DIR=""
      ;;
    "")
      ;;
    *)
      warn "unknown lock mode: ${JOB_LOCK_MODE}"
      ;;
  esac
  JOB_LOCK_MODE=""
}
