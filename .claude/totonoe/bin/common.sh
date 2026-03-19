#!/usr/bin/env bash

set -euo pipefail

COMMON_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TOTONOE_DIR="$(CDPATH='' cd -- "${COMMON_DIR}/.." && pwd -P)"
CLAUDE_DIR="$(CDPATH='' cd -- "${TOTONOE_DIR}/.." && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "${CLAUDE_DIR}/.." && pwd -P)"
RUNTIME_ROOT="${TOTONOE_DIR}/runtime"
GOALS_DIR="${TOTONOE_DIR}/goals"
SCHEMAS_DIR="${TOTONOE_DIR}/schemas"

# リポジトリルートの .env を自動読み込み（API キー等）
if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
  set +a
fi

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

  if [ "${TOTONOE_FORCE_MKDIR_LOCK:-}" != "1" ] && command -v flock >/dev/null 2>&1; then
    exec {JOB_LOCK_FD}> "${lock_file}"
    flock -x "${JOB_LOCK_FD}" || die "failed to acquire lock"
    JOB_LOCK_MODE="flock"
    return
  fi

  JOB_LOCK_DIR="${lock_file}.d"
  JOB_LOCK_MODE="mkdir"
  local attempts=0
  while ! mkdir "${JOB_LOCK_DIR}" 2>/dev/null; do
    # stale lock の回収を試みる
    if _try_reclaim_stale_lock "${JOB_LOCK_DIR}"; then
      continue
    fi
    attempts=$((attempts + 1))
    [ "${attempts}" -lt 300 ] || die "timed out acquiring lock"
    sleep 0.1
  done
  # lock 取得成功: owner metadata を書き込む
  _write_lock_metadata "${JOB_LOCK_DIR}"
}

# lock dir 内に owner metadata を保存する
# 書き込みに失敗した場合は lock dir を削除して die する
_write_lock_metadata() {
  local lock_dir="$1"
  local meta_file="${lock_dir}/owner.json"
  if ! jq -nc \
    --argjson pid "$$" \
    --arg hostname "$(hostname -s 2>/dev/null || printf 'unknown')" \
    --arg created_at "$(now_utc)" \
    '{pid: $pid, hostname: $hostname, created_at: $created_at}' \
    > "${meta_file}" 2>/dev/null; then
    rm -rf "${lock_dir}" 2>/dev/null || true
    die "failed to write lock metadata: ${lock_dir}"
  fi
}

# lock dir の経過秒数を返す
_lock_dir_age_seconds() {
  local lock_dir="$1"
  local mtime now_epoch
  if mtime="$(stat -f '%m' "${lock_dir}" 2>/dev/null)"; then
    :
  elif mtime="$(stat -c '%Y' "${lock_dir}" 2>/dev/null)"; then
    :
  else
    # mtime が取れない場合は安全側に倒して新しいとみなす
    printf '0\n'
    return
  fi
  now_epoch="$(date -u +%s)"
  printf '%s\n' "$(( now_epoch - mtime ))"
}

# metadata なし / 壊れた metadata の lock を安全に回収できるか判定する
# grace period（秒）以内なら owner がまだ metadata を書き込み中と判断して回収しない
_LOCK_GRACE_SECONDS=5

# stale lock を検出して回収する。回収できたら 0、できなかったら 1 を返す
_try_reclaim_stale_lock() {
  local lock_dir="$1"
  [ -d "${lock_dir}" ] || return 1

  local meta_file="${lock_dir}/owner.json"
  if [ ! -f "${meta_file}" ]; then
    # metadata がない場合、grace period 内なら owner が書き込み中の可能性がある
    local age
    age="$(_lock_dir_age_seconds "${lock_dir}")"
    if [ "${age}" -lt "${_LOCK_GRACE_SECONDS}" ]; then
      return 1
    fi
    warn "stale lock detected (no metadata, age ${age}s): ${lock_dir}"
    rm -rf "${lock_dir}" 2>/dev/null || return 1
    return 0
  fi

  local owner_pid
  owner_pid="$(jq -r '.pid // empty' "${meta_file}" 2>/dev/null)" || true
  if [ -z "${owner_pid}" ]; then
    # metadata が壊れている場合も grace period を確認する
    local age
    age="$(_lock_dir_age_seconds "${lock_dir}")"
    if [ "${age}" -lt "${_LOCK_GRACE_SECONDS}" ]; then
      return 1
    fi
    warn "stale lock detected (invalid metadata, age ${age}s): ${lock_dir}"
    rm -rf "${lock_dir}" 2>/dev/null || return 1
    return 0
  fi

  # owner PID が生きているか確認する
  if kill -0 "${owner_pid}" 2>/dev/null; then
    # PID は生きている。lock を奪わない
    return 1
  fi

  # owner PID が存在しない stale lock を回収する
  warn "stale lock detected (pid ${owner_pid} is dead): ${lock_dir}"
  rm -rf "${lock_dir}" 2>/dev/null || return 1
  return 0
}

# config.json のパスを返す
totonoe_config_path() {
  printf '%s/config.json\n' "${TOTONOE_DIR}"
}

# reviewer_mode を返す。config.json がなければ "fallback" を返す
read_reviewer_mode() {
  local config_path
  config_path="$(totonoe_config_path)"
  if [ ! -f "${config_path}" ]; then
    printf 'fallback\n'
    return
  fi
  local mode
  mode="$(jq -r '.reviewer.mode // "fallback"' "${config_path}")"
  case "${mode}" in
    fallback|shadow)
      printf '%s\n' "${mode}"
      ;;
    *)
      warn "unknown reviewer mode '${mode}' in config.json, using fallback"
      printf 'fallback\n'
      ;;
  esac
}


# --- knowledge DB ヘルパー ---

KNOWLEDGE_DB="${TOTONOE_DIR}/knowledge.db"

# knowledge.quality_threshold_count を config.json から読む（デフォルト 20）
# 不正値の場合は warn を出してデフォルトにフォールバックする
read_knowledge_threshold() {
  local config_path val
  config_path="$(totonoe_config_path)"
  if [ -f "${config_path}" ]; then
    val="$(jq -r '.knowledge.quality_threshold_count // 20' "${config_path}")"
  else
    val="20"
  fi
  if ! [[ "${val}" =~ ^[0-9]+$ ]] || [ "${val}" -lt 1 ]; then
    warn "knowledge.quality_threshold_count の値が不正です: '${val}'（デフォルト 20 を使用）"
    val="20"
  fi
  printf '%s\n' "${val}"
}

# state.json の knowledge_enabled を確認する
is_knowledge_enabled() {
  local job_name="$1"
  local sf
  sf="$(state_path "${job_name}")"
  [ -f "${sf}" ] || return 1
  local enabled
  enabled="$(jq -r '.knowledge_enabled // false' "${sf}")"
  [ "${enabled}" = "true" ]
}

# knowledge.db が存在し knowledge_enabled な場合のみ true を返す
should_write_knowledge() {
  local job_name="$1"
  is_knowledge_enabled "${job_name}" || return 1
  [ -f "${KNOWLEDGE_DB}" ] || return 1
}

# SQL 文字列リテラルをエスケープする（シングルクォートを二重化）
_sql_quote() {
  printf "'%s'" "${1//\'/\'\'}"
}

# knowledge.db に対して SQL を実行する（foreign_keys = ON）
_kdb_exec() {
  sqlite3 "${KNOWLEDGE_DB}" "PRAGMA foreign_keys = ON; $1"
}

# --- runner lock ---

RUNNER_LOCK_MODE=""
RUNNER_LOCK_FD=""
RUNNER_LOCK_DIR=""

runner_lock_path() {
  local job_name="$1"
  local role="$2"
  printf '%s/%s.runner.lock\n' "$(job_dir "${job_name}")" "${role}"
}

acquire_runner_lock() {
  local job_name="$1"
  local role="$2"
  local lock_file
  lock_file="$(runner_lock_path "${job_name}" "${role}")"

  ensure_job_exists "${job_name}"

  if [ "${TOTONOE_FORCE_MKDIR_LOCK:-}" != "1" ] && command -v flock >/dev/null 2>&1; then
    exec {RUNNER_LOCK_FD}> "${lock_file}"
    if ! flock -nx "${RUNNER_LOCK_FD}"; then
      eval "exec ${RUNNER_LOCK_FD}>&-"
      RUNNER_LOCK_FD=""
      die "${role} runner is already running for job: ${job_name}"
    fi
    RUNNER_LOCK_MODE="flock"
    return
  fi

  RUNNER_LOCK_DIR="${lock_file}.d"
  RUNNER_LOCK_MODE="mkdir"
  if ! mkdir "${RUNNER_LOCK_DIR}" 2>/dev/null; then
    # stale lock の回収を試みる
    if _try_reclaim_stale_lock "${RUNNER_LOCK_DIR}"; then
      if ! mkdir "${RUNNER_LOCK_DIR}" 2>/dev/null; then
        die "${role} runner is already running for job: ${job_name}"
      fi
    else
      die "${role} runner is already running for job: ${job_name}"
    fi
  fi
  _write_lock_metadata "${RUNNER_LOCK_DIR}"
}

release_runner_lock() {
  case "${RUNNER_LOCK_MODE}" in
    flock)
      if [ -n "${RUNNER_LOCK_FD}" ]; then
        flock -u "${RUNNER_LOCK_FD}" || true
        eval "exec ${RUNNER_LOCK_FD}>&-"
        RUNNER_LOCK_FD=""
      fi
      ;;
    mkdir)
      if [ -n "${RUNNER_LOCK_DIR}" ]; then
        rm -f "${RUNNER_LOCK_DIR}/owner.json" 2>/dev/null || true
        rmdir "${RUNNER_LOCK_DIR}" 2>/dev/null || true
      fi
      RUNNER_LOCK_DIR=""
      ;;
    "")
      ;;
    *)
      warn "unknown runner lock mode: ${RUNNER_LOCK_MODE}"
      ;;
  esac
  RUNNER_LOCK_MODE=""
}

release_job_lock() {
  case "${JOB_LOCK_MODE}" in
    flock)
      flock -u "${JOB_LOCK_FD}" || true
      eval "exec ${JOB_LOCK_FD}>&-"
      JOB_LOCK_FD=""
      ;;
    mkdir)
      if [ -n "${JOB_LOCK_DIR}" ]; then
        rm -f "${JOB_LOCK_DIR}/owner.json" 2>/dev/null || true
        rmdir "${JOB_LOCK_DIR}" 2>/dev/null || true
      fi
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
