#!/bin/zsh
# ==============================================================================
# Colima Pulse — Canonical Hardened Build (QEMU + launchd supervision)
# ------------------------------------------------------------------------------
# Locked goals (DO NOT RELAX):
#   - Deterministic Colima bootstrap for macOS (Apple Silicon + Intel)
#   - ALWAYS QEMU (never VZ) + docker runtime
#   - system LaunchDaemon (pre-login) supervising `colima start --foreground`
#   - MUST run Colima + Docker actions as HOMEBREW_USER (deterministic login env)
#   - Force ~/.colima usage (unset XDG_CONFIG_HOME; export HOME=...); prevents drift
#   - ./containers contains plain text files with docker run commands (idempotent)
#   - Unified log file: LOG_PATH (stdout+stderr) for LaunchDaemon + this script
#
# Hardenings in THIS version (Feb 2026):
#   - PRUNE_MODE supports: none|safe|images|aggressive
#     - safe   = dangling images only (docker image prune -f)
#     - images = all unused images (docker image prune -af)
#   - Container files are treated as PLAIN TEXT:
#     - sanitizes CRLF + prompt glyphs, joins "\" continuations, writes temp script
#   - Container runs are forced to the Colima profile socket:
#     - DOCKER_HOST=unix:///Users/<user>/.colima/<profile>/docker.sock
#     - NEVER falls back to /var/run/docker.sock
#   - Transport failure resiliency:
#     - Treats ANY EOF (including _ping EOF) as transient
#     - Automatic recovery pipeline:
#         (1) restart docker/containerd inside VM (systemd + sysv + OpenRC)
#         (2) kickstart LaunchDaemon
#         (3) colima stop + kickstart LaunchDaemon
#   - Deep diagnostics when recovery fails:
#     - docker version/info/df
#     - launchctl print + colima status --verbose + daemon log tail
#
# IMPORTANT ABOUT .env (CRITICAL):
#   - This script DOES NOT "source" .env (to avoid executing arbitrary shell code).
#   - It parses .env as KEY=VALUE lines only (safe loader).
#   - Inline comments supported for unquoted values: FOO=bar   # comment
#   - Duplicate keys allowed; LAST assignment wins (common .env behaviour).
#
# IMPORTANT ABOUT RUNTIME / DESTRUCTIVE CHOICES:
#   - FULL_RESET / FORCE_YES / RESET_* confirmation are RUNTIME choices.
#   - They MUST NOT live in .env. If present in .env, they are ignored.
#   - Use flags:
#       zsh ./colima-pulse.sh                      (restart-only)
#       zsh ./colima-pulse.sh --full-reset         (interactive, requires token)
#       zsh ./colima-pulse.sh --full-reset --force-yes   (non-interactive)
#
# WHY THE "DESTROY" TOKEN EXISTS:
#   - A nuclear reset deletes your Colima VM/profile and state dirs.
#   - Typing an explicit token prevents accidental copy/paste destruction.
#   - It is a deliberate "human-in-the-loop" guardrail.
#
# IMPORTANT ABOUT LOGGING:
#   - If LOG_PATH is under /var/log, normal users cannot write it.
#   - This script uses sudo tee automatically when needed.
#   - If it STILL cannot write, it falls back to: ${SCRIPT_DIR}/colima-pulse.run.log
#
# IMPORTANT ABOUT COLIMA START OUTPUT:
#   - `colima start` is verbose (time="..." level=info ...).
#   - This script captures the raw output and appends it into LOG_PATH,
#     but filters those timestamped INFO lines from the terminal for readability.
# ==============================================================================

# Reset to a known baseline then apply strict mode
emulate -LR zsh
set -euo pipefail
setopt err_return 2>/dev/null || true

# ------------------------------------------------------------------------------
# Hard-disable tracing (defensive: some environments enable xtrace)
# ------------------------------------------------------------------------------
xtrace_off() {
  export PS4='+ '
  set +x 2>/dev/null || true
  unsetopt xtrace 2>/dev/null || true
  setopt no_xtrace 2>/dev/null || true
}
xtrace_off

# ------------------------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------------------------
say() { print -r -- "$*"; }
hr()  { print -r -- "-------------------------------------------------------------------------------"; }
die() { print -r -- "❌ $*" >&2; exit 1; }

# Color (auto-disable if not a TTY, TERM=dumb, or NO_COLOR is set)
supports_color() { [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; }
typeset -g C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
if supports_color; then
# --- Colors (portable: zsh + bash; safe on Intel + Apple Silicon) ---
# Real ESC byte via ANSI-C quoting:
C_ESC=$'\033'
C_RESET="${C_ESC}[0m"
C_BOLD="${C_ESC}[1m"
C_DIM="${C_ESC}[2m"
C_RED="${C_ESC}[31m"
C_GREEN="${C_ESC}[32m"
C_YELLOW="${C_ESC}[33m"
C_CYAN="${C_ESC}[36m"
fi

step() { say "${C_BOLD}${C_CYAN}$*${C_RESET}"; }
ok()   { say "${C_BOLD}${C_GREEN}$*${C_RESET}"; }
warn() { say "${C_BOLD}${C_YELLOW}$*${C_RESET}"; }
bad()  { say "${C_BOLD}${C_RED}$*${C_RESET}"; }
dim()  { say "${C_DIM}$*${C_RESET}"; }

# IMPORTANT:
# - Use STDIN to determine interactivity.
# - STDOUT may be redirected to tee for unified logging (so -t 1 is unreliable).
is_tty() { [[ -t 0 ]]; }

prompt_yn() {
  local q="$1"
  local def="${2:-n}"
  local ans=""
  if ! is_tty; then
    print -r -- "${def}"
    return 0
  fi
  if [[ "${def}" == "y" ]]; then
    read "ans?${q} (Y/n): "
    ans="${ans:-y}"
  else
    read "ans?${q} (y/N): "
    ans="${ans:-n}"
  fi
  ans="${ans:l}"
  [[ "${ans}" == "y" || "${ans}" == "yes" ]] && print -r -- "y" || print -r -- "n"
}

require_typed_confirm() {
  local token="$1"
  if ! is_tty; then
    return 1
  fi
  say ""
  warn "Type EXACTLY: ${token}"
  local confirm=""
  read confirm
  [[ "${confirm}" == "${token}" ]]
}

ts_now() { date +%Y%m%d-%H%M%S; }

# ------------------------------------------------------------------------------
# Runtime choices (NOT from .env)
# ------------------------------------------------------------------------------
# Default safe mode is restart-only.
# Options:
#   --full-reset                 Nuclear reset (destructive)
#   --restart-only               Restart only (default)
#   --backup=move|prompt|false   Backup/move aside behavior before deletion (default: move)
#   --confirm-token=WORD         Typed confirmation token (default: DESTROY)
#   --no-confirm                 Skip typed confirmation (dangerous)
#   --force-yes                  Allow --full-reset in non-interactive mode
parse_args() {
  emulate -L zsh
  xtrace_off

  local a
  while (( $# > 0 )); do
    a="$1"
    case "${a}" in
      --full-reset)       FULL_RESET="true"; shift ;;
      --restart-only|--no-reset) FULL_RESET="false"; shift ;;
      --force-yes)        FORCE_YES="true"; shift ;;
      --no-confirm)       RESET_REQUIRE_CONFIRM="false"; shift ;;
      --confirm)          RESET_REQUIRE_CONFIRM="true"; shift ;;
      --confirm-token=*)  RESET_CONFIRM_TOKEN="${a#*=}"; shift ;;
      --backup=*)         RESET_BACKUP_MODE="${a#*=}"; shift ;;
      -h|--help)
        hr
        say "Colima Pulse — boot-level Docker infra for macOS"
        say ""
        say "Usage: zsh ./colima-pulse.sh [options]"
        say ""
        say "Runtime options (NOT from .env):"
        say "  --full-reset                 Nuclear reset (destructive)"
        say "  --restart-only               Restart only (default)"
        say "  --backup=move|prompt|false   Pre-delete handling (default: move)"
        say "  --confirm-token=WORD         Typed confirm token (default: DESTROY)"
        say "  --no-confirm                 Skip typed confirm (dangerous)"
        say "  --force-yes                  Allow --full-reset in non-interactive mode"
        hr
        exit 0
        ;;
      *)
        die "Unknown option: ${a}" ;;
    esac
  done

  xtrace_off
}

# ------------------------------------------------------------------------------
# Paths / env
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${0}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONTAINERS_DIR="${SCRIPT_DIR}/containers"

[[ -f "${ENV_FILE}" ]] || die "Missing .env at: ${ENV_FILE}"

# ------------------------------------------------------------------------------
# SAFE .env loader (NO execution; KEY=VALUE only)
# ------------------------------------------------------------------------------
load_env_file_safely() {
  xtrace_off

  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//$'\r'/}"
    line="${line#"${line%%[!$' \t']*}"}"
    [[ -z "${line}" ]] && continue
    [[ "${line}" == \#* ]] && continue

    if [[ "${line}" == "export "* ]]; then
      line="${line#export }"
      line="${line#"${line%%[!$' \t']*}"}"
    fi

    [[ "${line}" == *"="* ]] || continue

    key="${line%%=*}"
    val="${line#*=}"

    key="${key%"${key##*[!$' \t']}"}"
    key="${key#"${key%%[!$' \t']*}"}"
    [[ "${key}" == [A-Za-z_][A-Za-z0-9_]* ]] || continue

    val="${val#"${val%%[!$' \t']*}"}"

    if [[ "${val}" != \"* && "${val}" != \'* ]]; then
      val="${val%%\#*}"
      val="${val%"${val##*[!$' \t']}"}"
      val="${val#"${val%%[!$' \t']*}"}"
    else
      if [[ "${val}" == \"*\" ]]; then
        [[ "${#val}" -ge 2 ]] && val="${val:1:${#val}-2}"
      elif [[ "${val}" == \'*\' ]]; then
        [[ "${#val}" -ge 2 ]] && val="${val:1:${#val}-2}"
      fi
    fi

    export "${key}=${val}"
  done < "${ENV_FILE}"

  xtrace_off
}
load_env_file_safely

# ------------------------------------------------------------------------------
# Enforce runtime model: danger switches are NOT allowed to be driven by .env
# ------------------------------------------------------------------------------
FULL_RESET="false"
FORCE_YES="false"
RESET_REQUIRE_CONFIRM="true"
RESET_CONFIRM_TOKEN="DESTROY"
RESET_BACKUP_MODE="move"     # move|prompt|false

parse_args "$@"

# ------------------------------------------------------------------------------
# Required + stable configuration (allowed in .env)
# ------------------------------------------------------------------------------
: "${HOMEBREW_USER:?HOMEBREW_USER is required in .env}"

# COLIMA (stable)
: "${COLIMA_PROFILE:=default}"
: "${COLIMA_RUNTIME:=docker}"
: "${COLIMA_VM_TYPE:=qemu}"
: "${COLIMA_CPUS:=2}"
: "${COLIMA_MEMORY:=2}"
: "${COLIMA_DISK:=20}"

# launchd / logging (stable)
: "${LABEL:=homebrew.mrcee.colima-pulse}"
: "${LOG_PATH:=/var/log/colima.log}"

# backups (used only when --full-reset)
: "${BACKUP_DIR_BASE:=${SCRIPT_DIR}/backups}"

# other daemon cleanup preference (stable)
: "${CLEAN_OTHER_COLIMA_DAEMONS:=prompt}"   # prompt|true|false

# Docker prune (stable)
: "${PRUNE_MODE:=none}"                     # none|safe|images|aggressive
: "${PRUNE_DOCKER_AFTER_START:=true}"

# Timing knobs (stable)
: "${WAIT_SOCKET_MAX:=180}"
: "${WAIT_DOCKER_API_MAX:=180}"
: "${WAIT_QEMU_MAX:=120}"
: "${WAIT_STABLE_REQUIRED:=5}"

# Container knobs (stable)
: "${CONTAINER_TRIES:=3}"
: "${CONTAINER_DEBUG_SCRIPT:=false}"

# Optional: reduce colima start spam in terminal (raw still appended to LOG_PATH)
: "${COLIMA_START_FILTER_INFO:=true}"

# Optional: write .env.example (never edits .env)
: "${WRITE_ENV_EXAMPLE:=false}"

# ------------------------------------------------------------------------------
# Validate locked values
# ------------------------------------------------------------------------------
[[ "${COLIMA_VM_TYPE:l}" == "qemu" ]]   || die "COLIMA_VM_TYPE must be 'qemu' (got: ${COLIMA_VM_TYPE})"
[[ "${COLIMA_RUNTIME:l}" == "docker" ]] || die "COLIMA_RUNTIME must be 'docker' (got: ${COLIMA_RUNTIME})"

# Resolve user home (never hardcode usernames)
HOMEBREW_USER_HOME="$(dscl . -read "/Users/${HOMEBREW_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "${HOMEBREW_USER_HOME}" ]] || die "Failed to resolve home directory for user: ${HOMEBREW_USER}"
[[ -d "${HOMEBREW_USER_HOME}" ]] || die "Resolved home does not exist: ${HOMEBREW_USER_HOME}"

# ------------------------------------------------------------------------------
# Warn on .env keys that should NOT be there + duplicates (LAST assignment wins)
# ------------------------------------------------------------------------------
warn_env_runtime_keys_present() {
  local badkeys=(
    FULL_RESET FORCE_YES RESET_REQUIRE_CONFIRM RESET_CONFIRM_TOKEN RESET_BACKUP_MODE
  )
  local k found=0
  for k in "${badkeys[@]}"; do
    if /usr/bin/grep -Eq "^[[:space:]]*(export[[:space:]]+)?${k}=" "${ENV_FILE}" 2>/dev/null; then
      ((found++))
    fi
  done
  if (( found > 0 )); then
    hr
    warn "⚠️ .env contains runtime-only keys that are ignored by this script:"
    say "   FULL_RESET / FORCE_YES / RESET_*"
    say "   Use flags instead: --full-reset, --force-yes, --backup=..., --confirm-token=..., --no-confirm"
    hr
  fi
}

warn_env_duplicates() {
  emulate -L zsh
  xtrace_off

  # Only warn on stable keys (ones we actually accept from .env)
  local keys=(
    HOMEBREW_USER
    COLIMA_PROFILE COLIMA_RUNTIME COLIMA_VM_TYPE COLIMA_CPUS COLIMA_MEMORY COLIMA_DISK
    LABEL LOG_PATH
    BACKUP_DIR_BASE
    CLEAN_OTHER_COLIMA_DAEMONS
    PRUNE_MODE PRUNE_DOCKER_AFTER_START
    WAIT_SOCKET_MAX WAIT_DOCKER_API_MAX WAIT_QEMU_MAX WAIT_STABLE_REQUIRED
    CONTAINER_TRIES CONTAINER_DEBUG_SCRIPT
    COLIMA_START_FILTER_INFO
    WRITE_ENV_EXAMPLE
  )

  local k dup=0 __count=""
  for k in "${keys[@]}"; do
    __count="$(/usr/bin/grep -E "^[[:space:]]*(export[[:space:]]+)?${k}=" "${ENV_FILE}" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    if [[ "${__count}" -gt 1 ]]; then
      ((dup++))
      hr
      warn "⚠️ .env has duplicate assignments for: ${k} (${__count} times)"
      say "   Shell/.env behavior: the LAST one wins."
      say "   Lines:"
      /usr/bin/nl -ba "${ENV_FILE}" | /usr/bin/grep -E "^[[:space:]]*[0-9]+[[:space:]]+(export[[:space:]]+)?${k}=" || true
      hr
    fi
  done

  if [[ "${dup}" -gt 0 ]]; then
    warn "⚠️ Duplicate .env keys detected. Consider consolidating to ONE assignment per key."
    hr
  fi
}

warn_env_runtime_keys_present
warn_env_duplicates
xtrace_off

# ------------------------------------------------------------------------------
# Sudo keepalive (needed for launchd + system paths)
# ------------------------------------------------------------------------------
sudo -v

# ------------------------------------------------------------------------------
# Arch -> brew prefix
# ------------------------------------------------------------------------------
ARCH="$(uname -m)"
case "${ARCH}" in
  arm64)  BREW_PREFIX="/opt/homebrew" ;;
  x86_64) BREW_PREFIX="/usr/local" ;;
  *) die "Unsupported arch from uname -m: ${ARCH}" ;;
esac

# ------------------------------------------------------------------------------
# Homebrew + dependencies (MUST exist)
# ------------------------------------------------------------------------------
BREW_BIN="${BREW_PREFIX}/bin/brew"
if [[ ! -x "${BREW_BIN}" ]]; then
  BREW_BIN="$(command -v brew || true)"
fi

if [[ -z "${BREW_BIN}" || ! -x "${BREW_BIN}" ]]; then
  hr
  bad "❌ Homebrew is required but was not found."
  say ""
  say "Install Homebrew with this one-liner, then re-run:"
  say '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  hr
  exit 1
fi

have_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 && return 0
  [[ -x "${BREW_PREFIX}/bin/${cmd}" ]] && return 0
  return 1
}

brew_install_if_missing() {
  local formula="$1"
  local probe="${2:-$1}"

  if have_cmd "${probe}"; then
    return 0
  fi

  hr
  step "📦 Missing dependency detected: ${probe}"
  step "▶ Installing via Homebrew: ${formula}"
  hr

  sudo -u "${HOMEBREW_USER}" env -u XDG_CONFIG_HOME HOME="${HOMEBREW_USER_HOME}" \
    PATH="$(dirname -- "${BREW_BIN}"):${PATH}" \
    "${BREW_BIN}" install "${formula}"
}

brew_install_if_missing "colima" "colima"
brew_install_if_missing "docker" "docker"
brew_install_if_missing "qemu"   "qemu-img"

COLIMA_BIN="${BREW_PREFIX}/bin/colima"
DOCKER_BIN="${BREW_PREFIX}/bin/docker"
if [[ ! -x "${COLIMA_BIN}" ]]; then COLIMA_BIN="$(command -v colima || true)"; fi
[[ -n "${COLIMA_BIN}" && -x "${COLIMA_BIN}" ]] || die "colima not found even after install attempt."
if [[ ! -x "${DOCKER_BIN}" ]]; then DOCKER_BIN="$(command -v docker || true)"; fi
[[ -n "${DOCKER_BIN}" && -x "${DOCKER_BIN}" ]] || die "docker CLI not found even after install attempt."

# ------------------------------------------------------------------------------
# Deterministic socket + Docker host URI
# ------------------------------------------------------------------------------
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
COLIMA_SOCKET="${HOMEBREW_USER_HOME}/.colima/${COLIMA_PROFILE}/docker.sock"
DOCKER_HOST_URI="unix:///${COLIMA_SOCKET#/}"   # canonical: unix:///Users/...

# ------------------------------------------------------------------------------
# Run helpers (force correct user + deterministic env)
# ------------------------------------------------------------------------------
run_as_user() {
  sudo -u "${HOMEBREW_USER}" env -u XDG_CONFIG_HOME -u DOCKER_CONTEXT HOME="${HOMEBREW_USER_HOME}" \
    PATH="$(dirname -- "${DOCKER_BIN}")":"$(dirname -- "${COLIMA_BIN}")":"${PATH}" \
    "$@"
}

docker_as_user() {
  run_as_user "${DOCKER_BIN}" --host="${DOCKER_HOST_URI}" "$@"
}

# Prefer profile-aware ssh, but gracefully fall back if --profile unsupported.
colima_ssh_as_user() {
  local out rc
  out="$(
    ( set +e
      run_as_user "${COLIMA_BIN}" ssh --profile "${COLIMA_PROFILE}" -- "$@"
      echo "__RC__=$?"
    ) 2>&1
  )"
  rc="${out##*__RC__=}"
  out="${out%$'\n'__RC__=${rc}}"

  if [[ "${rc}" -eq 0 ]]; then
    return 0
  fi

  if print -r -- "${out}" | /usr/bin/grep -Eqi '(unknown flag|flag provided but not defined).*--profile'; then
    run_as_user "${COLIMA_BIN}" ssh -- "$@"
    return $?
  fi

  print -r -- "${out}" >&2
  return "${rc}"
}

# ------------------------------------------------------------------------------
# Sudo keepalive + cleanup registry
# ------------------------------------------------------------------------------
typeset -ga _CLEANUP_FILES=()
SUDO_KEEPALIVE_PID=""

cleanup_register() {
  local f="$1"
  [[ -n "${f}" ]] || return 0
  _CLEANUP_FILES+=("${f}")
}

_on_exit() {
  local f
  for f in "${_CLEANUP_FILES[@]:-}"; do
    [[ -n "${f}" ]] || continue
    run_as_user /bin/rm -f "${f}" >/dev/null 2>&1 || true
  done

  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "${SUDO_KEEPALIVE_PID}" >/dev/null 2>&1 || true
  fi
}

( while true; do sudo -n true 2>/dev/null || exit 0; sleep 30; done ) &
SUDO_KEEPALIVE_PID="$!"
trap '_on_exit' EXIT

# ------------------------------------------------------------------------------
# Unified run logging into LOG_PATH (FIXED)
# ------------------------------------------------------------------------------
init_run_logging() {
  xtrace_off

  local desired="${LOG_PATH}"
  local fallback="${SCRIPT_DIR}/colima-pulse.run.log"

  sudo /usr/bin/touch "${desired}" >/dev/null 2>&1 || true

  # 1) If we can append using sudo tee -> use sudo tee (works for /var/log)
  if /usr/bin/printf '' | sudo /usr/bin/tee -a "${desired}" >/dev/null 2>&1; then
    exec > >(sudo /usr/bin/tee -a "${desired}") 2>&1
    return 0
  fi

  # 2) Else if we can append directly -> append directly
  if { : >> "${desired}"; } 2>/dev/null; then
    exec >> "${desired}" 2>&1
    return 0
  fi

  # 3) Else -> fallback
  warn "⚠️ Cannot write to LOG_PATH=${desired}"
  warn "   Falling back to: ${fallback}"
  : > "${fallback}" 2>/dev/null || true
  exec >> "${fallback}" 2>&1
  LOG_PATH="${fallback}"
}

init_run_logging
xtrace_off

# Append a block to LOG_PATH without polluting STDOUT (best effort).
append_to_log_best_effort() {
  # Reads stdin, appends into LOG_PATH.
  if /usr/bin/printf '' | sudo /usr/bin/tee -a "${LOG_PATH}" >/dev/null 2>&1; then
    sudo /usr/bin/tee -a "${LOG_PATH}" >/dev/null 2>&1 || true
    return 0
  fi
  if { : >> "${LOG_PATH}"; } 2>/dev/null; then
    cat >> "${LOG_PATH}" 2>/dev/null || true
    return 0
  fi
  cat >/dev/null || true
}

# ------------------------------------------------------------------------------
# Optional: write .env.example (NEVER touches .env)
# ------------------------------------------------------------------------------
write_env_example_template() {
  cat <<'EOF'
# ==============================================================================
# Colima Pulse — Environment Configuration (SAFE)
# ==============================================================================
# This file is STABLE configuration only.
# Destructive actions are chosen at runtime:
#   Restart only:            zsh ./colima-pulse.sh
#   Nuclear reset:           zsh ./colima-pulse.sh --full-reset
#   Nuclear reset (no TTY):  zsh ./colima-pulse.sh --full-reset --force-yes
#
# REQUIRED
HOMEBREW_USER=your_username_here
#
# COLIMA
COLIMA_PROFILE=default
COLIMA_RUNTIME=docker
COLIMA_VM_TYPE=qemu
COLIMA_CPUS=2
COLIMA_MEMORY=2
COLIMA_DISK=20
#
# launchd / logging
LABEL=homebrew.mrcee.colima-pulse
LOG_PATH=/var/log/colima.log
#
# backups (used only when --full-reset)
BACKUP_DIR_BASE=./backups
#
# other daemon cleanup preference
CLEAN_OTHER_COLIMA_DAEMONS=prompt
#
# Docker prune behavior
PRUNE_DOCKER_AFTER_START=true
PRUNE_MODE=safe
#
# Timing
WAIT_SOCKET_MAX=180
WAIT_DOCKER_API_MAX=180
WAIT_QEMU_MAX=120
WAIT_STABLE_REQUIRED=5
#
# Containers
CONTAINER_TRIES=3
CONTAINER_DEBUG_SCRIPT=false
#
# Optional: reduce colima start spam in terminal (raw still appended to LOG_PATH)
COLIMA_START_FILTER_INFO=true
#
# Repo convenience
WRITE_ENV_EXAMPLE=false
EOF
}

maybe_write_env_example() {
  [[ "${WRITE_ENV_EXAMPLE:l}" == "true" ]] || return 0
  local out="${SCRIPT_DIR}/.env.example"
  local tmp="${out}.tmp.$$"
  write_env_example_template > "${tmp}"
  /bin/mv -f "${tmp}" "${out}"
  ok "📝 Wrote: ${out}"
  hr
}

# ------------------------------------------------------------------------------
# Header
# ------------------------------------------------------------------------------
say "================================================================================"
say "COLIMA PULSE — CANONICAL HARDENED BUILD (QEMU + launchd + guarded reset)"
say "================================================================================"
hr
say "▶ Resolved:"
say "  ARCH:                    ${ARCH}"
say "  BREW_PREFIX:             ${BREW_PREFIX}"
say "  HOMEBREW_USER:           ${HOMEBREW_USER}"
say "  USER_HOME:               ${HOMEBREW_USER_HOME}"
say "  COLIMA_BIN:              ${COLIMA_BIN}"
say "  DOCKER_BIN:              ${DOCKER_BIN}"
say "  PROFILE:                 ${COLIMA_PROFILE}"
say "  RUNTIME:                 ${COLIMA_RUNTIME}"
say "  VM_TYPE:                 ${COLIMA_VM_TYPE}"
say "  CPUS:                    ${COLIMA_CPUS}"
say "  MEMORY_GB:               ${COLIMA_MEMORY}"
say "  DISK_GB:                 ${COLIMA_DISK}"
say "  MODE(full_reset):        ${FULL_RESET}"
say "  LABEL:                   ${LABEL}"
say "  PLIST:                   ${PLIST_PATH}"
say "  LOG:                     ${LOG_PATH}"
say "  DOCKER_SOCK:             ${COLIMA_SOCKET}"
say "  DOCKER_HOST_URI:         ${DOCKER_HOST_URI}"
say "  BACKUP_DIR_BASE:         ${BACKUP_DIR_BASE}"
say "  CLEAN_OTHER_DAEMONS:     ${CLEAN_OTHER_COLIMA_DAEMONS}"
say "  PRUNE_MODE:              ${PRUNE_MODE}"
say "  PRUNE_AFTER_START:       ${PRUNE_DOCKER_AFTER_START}"
say "  WAIT_SOCKET_MAX:         ${WAIT_SOCKET_MAX}"
say "  WAIT_DOCKER_API_MAX:     ${WAIT_DOCKER_API_MAX}"
say "  WAIT_QEMU_MAX:           ${WAIT_QEMU_MAX}"
say "  WAIT_STABLE_REQUIRED:    ${WAIT_STABLE_REQUIRED}"
say "  CONTAINER_TRIES:         ${CONTAINER_TRIES}"
say "  CONTAINER_DEBUG_SCRIPT:  ${CONTAINER_DEBUG_SCRIPT}"
say "  COLIMA_START_FILTER_INFO:${COLIMA_START_FILTER_INFO}"
hr

if [[ "${COLIMA_MEMORY}" -lt 2 ]]; then
  warn "⚠️ Note: COLIMA_MEMORY=${COLIMA_MEMORY}GB is low. For flaky pulls, set COLIMA_MEMORY=4."
  hr
fi

maybe_write_env_example
xtrace_off

# ------------------------------------------------------------------------------
# launchd helpers (strict)
# ------------------------------------------------------------------------------
daemon_bootout_remove_if_present() {
  if [[ -f "${PLIST_PATH}" ]]; then
    sudo launchctl bootout system "${PLIST_PATH}" >/dev/null 2>&1 || true
  else
    sudo launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
  fi
  sudo launchctl remove "${LABEL}" >/dev/null 2>&1 || true
}

install_plist() {
  sudo /usr/bin/touch "${LOG_PATH}" >/dev/null 2>&1 || true

  cat <<EOF | sudo /usr/bin/tee "${PLIST_PATH}" >/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/su</string>
    <string>-</string>
    <string>${HOMEBREW_USER}</string>
    <string>-c</string>
    <string>unset XDG_CONFIG_HOME; export HOME=${HOMEBREW_USER_HOME}; exec ${COLIMA_BIN} start --profile ${COLIMA_PROFILE} --runtime ${COLIMA_RUNTIME} --vm-type ${COLIMA_VM_TYPE} --foreground</string>
  </array>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>

  <key>WorkingDirectory</key>
  <string>${HOMEBREW_USER_HOME}</string>

  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
EOF

  sudo chown root:wheel "${PLIST_PATH}" >/dev/null 2>&1 || true
  sudo chmod 0644 "${PLIST_PATH}" >/dev/null 2>&1 || true
  sudo /usr/bin/plutil -lint "${PLIST_PATH}" >/dev/null || die "Installed plist failed plutil -lint"
}

bootstrap_daemon_strict() {
  local out

  step "▶ Ensuring our LaunchDaemon is fully removed before install"
  daemon_bootout_remove_if_present
  hr

  step "▶ Installing LaunchDaemon plist: ${PLIST_PATH}"
  install_plist
  hr

  step "▶ Bootstrap LaunchDaemon (STRICT)"
  out="$(sudo launchctl bootstrap system "${PLIST_PATH}" 2>&1)" || {
    bad "❌ launchctl bootstrap failed:"
    say "${out}"
    say "---- last 120 lines: ${LOG_PATH} ----"
    sudo tail -n 120 "${LOG_PATH}" 2>/dev/null || true
    die "Bootstrap failed"
  }

  sudo launchctl enable "system/${LABEL}" >/dev/null 2>&1 || true

  step "▶ Kickstart LaunchDaemon"
  out="$(sudo launchctl kickstart -k "system/${LABEL}" 2>&1)" || {
    bad "❌ launchctl kickstart failed:"
    say "${out}"
    say "---- launchctl print system/${LABEL} ----"
    sudo launchctl print "system/${LABEL}" || true
    say "---- last 200 lines: ${LOG_PATH} ----"
    sudo tail -n 200 "${LOG_PATH}" 2>/dev/null || true
    die "Kickstart failed"
  }

  ok "✅ LaunchDaemon active: system/${LABEL}"
}

kickstart_daemon_best_effort() {
  sudo launchctl kickstart -k "system/${LABEL}" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Kill stack (TERM -> KILL)
# ------------------------------------------------------------------------------
kill_colima_stack() {
  step "▶ Killing any existing colima/qemu (TERM → KILL)"
  hr

  local uid
  uid="$(id -u "${HOMEBREW_USER}" 2>/dev/null || true)"
  [[ -n "${uid}" ]] || die "Could not resolve uid for ${HOMEBREW_USER}"

  run_as_user "${COLIMA_BIN}" stop --profile "${COLIMA_PROFILE}" >/dev/null 2>&1 || true

  sudo pkill -TERM -u "${uid}" -f "${COLIMA_BIN} start"        >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "${COLIMA_BIN} daemon start" >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "limactl"                    >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "qemu-system"                >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "sshfs.*_lima"               >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "ssh: .*_lima"               >/dev/null 2>&1 || true
  sudo pkill -TERM -f "/usr/bin/su - ${HOMEBREW_USER} -c"      >/dev/null 2>&1 || true

  local i=0
  while (( i < 8 )); do
    if ps aux | /usr/bin/grep -Ei 'colima start|colima daemon start|limactl|qemu-system|lima-colima|sshfs.*_lima' | /usr/bin/grep -v grep >/dev/null 2>&1; then
      sleep 1
      ((i++))
    else
      ok "✅ No lingering colima/lima/qemu processes detected"
      return 0
    fi
  done

  warn "⚠️ Still running — escalating to KILL"
  sudo pkill -KILL -u "${uid}" -f "${COLIMA_BIN} start"        >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "${COLIMA_BIN} daemon start" >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "limactl"                    >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "qemu-system"                >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "sshfs.*_lima"               >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "ssh: .*_lima"               >/dev/null 2>&1 || true
  sudo pkill -KILL -f "/usr/bin/su - ${HOMEBREW_USER} -c"      >/dev/null 2>&1 || true

  sleep 1
  if ps aux | /usr/bin/grep -Ei 'colima start|colima daemon start|limactl|qemu-system|lima-colima|sshfs.*_lima' | /usr/bin/grep -v grep >/dev/null 2>&1; then
    die "Unable to fully stop Colima/Lima/QEMU. Reboot and re-run."
  fi

  ok "✅ Forced shutdown complete"
}

# ------------------------------------------------------------------------------
# Detect + optionally remove other colima launchd services (prevents dual VM)
# ------------------------------------------------------------------------------
list_other_colima_labels_system() {
  sudo launchctl print system 2>/dev/null \
    | /usr/bin/awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {print $3}' \
    | /usr/bin/tr -d '"' \
    | /usr/bin/grep -i colima \
    | /usr/bin/grep -v -F "${LABEL}" \
    || true
}

bootout_remove_label_system() {
  local lbl="$1"
  local plist="/Library/LaunchDaemons/${lbl}.plist"

  if [[ -f "${plist}" ]]; then
    sudo launchctl bootout system "${plist}" >/dev/null 2>&1 || true
  else
    sudo launchctl bootout "system/${lbl}" >/dev/null 2>&1 || true
  fi
  sudo launchctl remove "${lbl}" >/dev/null 2>&1 || true
  sudo launchctl disable "system/${lbl}" >/dev/null 2>&1 || true

  if [[ -f "${plist}" ]]; then
    sudo rm -f "${plist}" >/dev/null 2>&1 || true
  fi
}

maybe_clean_other_colima_daemons() {
  local mode="${CLEAN_OTHER_COLIMA_DAEMONS:l}"
  [[ "${mode}" == "false" ]] && return 0

  local others
  others="$(list_other_colima_labels_system | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/[[:space:]]*$//')"
  [[ -n "${others}" ]] || return 0

  hr
  warn "⚠️ Detected other system launchd services containing 'colima':"
  say "  ${others}"
  hr

  local do_it="n"
  case "${mode}" in
    true) do_it="y" ;;
    prompt|*) do_it="$(prompt_yn "Remove these other colima services now (recommended)?" "y")" ;;
  esac

  [[ "${do_it}" == "y" ]] || { step "▶ Leaving other colima services in place"; hr; return 0; }

  step "▶ Removing other colima services (system domain)"
  hr

  local lbl
  for lbl in $(list_other_colima_labels_system); do
    say "  - Removing: ${lbl}"
    bootout_remove_label_system "${lbl}"
  done

  ok "✅ Other colima services removed"
  hr
}

# ------------------------------------------------------------------------------
# Backup helpers (MOVE-ASIDE, no tarballs)
# ------------------------------------------------------------------------------
move_aside_dir() {
  local src="$1"
  local dst="$2"
  [[ -d "${src}" ]] || return 0
  mkdir -p "$(dirname -- "${dst}")"
  /bin/mv "${src}" "${dst}"
}

maybe_backup_state() {
  [[ "${FULL_RESET:l}" == "true" ]] || return 0
  local mode="${RESET_BACKUP_MODE:l}"

  case "${mode}" in
    false|'')
      step "▶ Backup skipped (--backup=false)"
      hr
      return 0
      ;;
    move)
      local bdir="${BACKUP_DIR_BASE}"
      local stamp="$(ts_now)"
      local outbase="${bdir}/moved-${COLIMA_PROFILE}-${stamp}"

      hr
      step "▶ Moving existing Colima state aside (--backup=move)"
      say "  Target base: ${outbase}"
      hr

      if [[ -d "${HOMEBREW_USER_HOME}/.colima" ]]; then
        say "  - Moving: ${HOMEBREW_USER_HOME}/.colima"
        move_aside_dir "${HOMEBREW_USER_HOME}/.colima" "${outbase}.dotcolima"
        ok "    ✅ ${outbase}.dotcolima"
      fi

      if [[ -d "${HOMEBREW_USER_HOME}/.config/colima" ]]; then
        say "  - Moving: ${HOMEBREW_USER_HOME}/.config/colima"
        move_aside_dir "${HOMEBREW_USER_HOME}/.config/colima" "${outbase}.configcolima"
        ok "    ✅ ${outbase}.configcolima"
      fi

      hr
      return 0
      ;;
    prompt)
      if ! is_tty; then
        warn "⚠️ --backup=prompt but no TTY; treating as --backup=move"
        RESET_BACKUP_MODE="move"
        maybe_backup_state
        return 0
      fi
      local okk
      okk="$(prompt_yn "Move existing Colima state aside before deletion?" "y")"
      [[ "${okk}" == "y" ]] || { step "▶ Backup skipped"; hr; return 0; }
      RESET_BACKUP_MODE="move"
      maybe_backup_state
      return 0
      ;;
    *)
      warn "⚠️ Unknown --backup=${RESET_BACKUP_MODE}; treating as move"
      RESET_BACKUP_MODE="move"
      maybe_backup_state
      return 0
      ;;
  esac
}

# ------------------------------------------------------------------------------
# QEMU verification (retry-based)
# ------------------------------------------------------------------------------
verify_qemu_once() {
  local out
  out="$(run_as_user "${COLIMA_BIN}" status --profile "${COLIMA_PROFILE}" --verbose 2>&1 || true)"

  if print -r -- "${out}" | /usr/bin/grep -Eqi '(using[[:space:]]+VZ|virtualization[[:space:]]+framework|internal VM driver[[:space:]]+"vz"|vmType:[[:space:]]*vz|vm-type[[:space:]]+vz)'; then
    return 1
  fi

  if print -r -- "${out}" | /usr/bin/grep -Eqi '(using[[:space:]]+QEMU|internal VM driver[[:space:]]+"qemu"|vmType:[[:space:]]*qemu|vm-type[[:space:]]+qemu)'; then
    return 0
  fi

  return 2
}

verify_qemu_retry() {
  step "▶ Verifying QEMU (retry up to ${WAIT_QEMU_MAX}s)"
  local i=0
  while (( i < WAIT_QEMU_MAX )); do
    if verify_qemu_once; then
      ok "✅ QEMU verified"
      return 0
    else
      local rc=$?
      if [[ "${rc}" -eq 1 ]]; then
        bad "❌ VZ detected (t=${i}s)"
      else
        dim "… unable to confirm VM type yet (t=${i}s)"
      fi
    fi
    sleep 1
    ((i++))
  done
  return 1
}

# ------------------------------------------------------------------------------
# Wait loops (use docker --host=... via docker_as_user)
# ------------------------------------------------------------------------------
wait_for_socket() {
  local elapsed=0 max="${WAIT_SOCKET_MAX}"
  step "▶ Waiting for docker.sock..."
  while (( elapsed < max )); do
    if [[ -S "${COLIMA_SOCKET}" ]]; then
      ok "✅ docker.sock present"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    dim "  … ${elapsed}s"
  done
  die "Timed out waiting for docker.sock after ${max}s"
}

wait_for_docker_api() {
  local elapsed=0 max="${WAIT_DOCKER_API_MAX}"
  step "▶ Waiting for Docker API..."
  while (( elapsed < max )); do
    if docker_as_user version >/dev/null 2>&1; then
      ok "✅ Docker API responding"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    dim "  … ${elapsed}s"
  done
  die "Timed out waiting for Docker API after ${max}s"
}

wait_for_docker_stable() {
  step "▶ Deep Docker stabilization check..."
  local stable=0 required="${WAIT_STABLE_REQUIRED}"
  while true; do
    if docker_as_user info >/dev/null 2>&1 \
      && docker_as_user ps >/dev/null 2>&1 \
      && docker_as_user system info >/dev/null 2>&1; then
      stable=$((stable + 1))
      dim "  - Stability ${stable}/${required}"
    else
      stable=0
      dim "  - Docker not fully stable yet…"
    fi
    [[ "${stable}" -ge "${required}" ]] && break
    sleep 1
  done
  ok "✅ Docker runtime stabilized"
}

wait_for_docker_api_quick() {
  local max="${1:-30}"
  local i=0
  while (( i < max )); do
    docker_as_user version >/dev/null 2>&1 && return 0
    sleep 1
    ((i++))
  done
  return 1
}

# ------------------------------------------------------------------------------
# Docker prune (ONLY AFTER Docker is stable)
# ------------------------------------------------------------------------------
maybe_prune_after_ready() {
  [[ "${PRUNE_DOCKER_AFTER_START:l}" == "true" ]] || {
    step "▶ Prune skipped (PRUNE_DOCKER_AFTER_START=false)"
    hr
    return 0
  }

  local mode="${PRUNE_MODE:l}"

  if [[ "${FULL_RESET:l}" == "true" && "${mode}" == "none" ]]; then
    mode="safe"
  fi

  case "${mode}" in
    none)
      step "▶ Prune skipped (PRUNE_MODE=none)"
      hr
      return 0
      ;;
    safe)
      hr
      step "▶ Pruning Docker (SAFE): dangling images only"
      hr
      docker_as_user image prune -f || true
      hr
      return 0
      ;;
    images)
      hr
      step "▶ Pruning Docker (IMAGES): all unused images"
      hr
      docker_as_user image prune -af || true
      hr
      return 0
      ;;
    aggressive)
      hr
      warn "▶ Pruning Docker (AGGRESSIVE): includes volumes (DESTRUCTIVE)"
      hr
      if ! is_tty && [[ "${FORCE_YES:l}" != "true" ]]; then
        die "Aggressive prune refused without TTY unless you also pass --force-yes"
      fi
      if is_tty; then
        local okk
        okk="$(prompt_yn "Proceed with docker system prune -af --volumes ?" "n")"
        [[ "${okk}" == "y" ]] || { step "▶ Aggressive prune aborted"; hr; return 0; }
      fi
      docker_as_user system prune -af --volumes || true
      hr
      return 0
      ;;
    *)
      hr
      warn "⚠️ Unknown PRUNE_MODE=${PRUNE_MODE} — treating as none"
      hr
      return 0
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Diagnostics / recovery
# ------------------------------------------------------------------------------
docker_diag_brief() {
  say "  ---- docker version ----"
  docker_as_user version 2>&1 || true
  say "  ---- docker info (top) ----"
  docker_as_user info 2>&1 | /usr/bin/sed -n '1,120p' || true
  say "  ---- docker system df ----"
  docker_as_user system df 2>&1 || true
  say "  ---- socket ----"
  /bin/ls -la "${COLIMA_SOCKET}" 2>&1 || true
}

colima_diag_brief() {
  hr
  step "▶ Colima/launchd diagnostics (brief)"
  hr

  say "  ---- launchctl print (head) ----"
  sudo launchctl print "system/${LABEL}" 2>&1 | /usr/bin/sed -n '1,140p' || true

  say "  ---- colima status --verbose (head) ----"
  run_as_user "${COLIMA_BIN}" status --profile "${COLIMA_PROFILE}" --verbose 2>&1 | /usr/bin/sed -n '1,200p' || true

  say "  ---- daemon log tail ----"
  sudo tail -n 180 "${LOG_PATH}" 2>&1 || true

  say "  ---- vm quick probe (best-effort) ----"
  colima_ssh_as_user sh -lc '
    set +e
    uname -a
    cat /etc/os-release 2>/dev/null || true
    (free -m 2>/dev/null || vmstat 2>/dev/null || true) | head -n 30
    df -h 2>/dev/null | head -n 30
    ps -ef 2>/dev/null | egrep "dockerd|containerd" | head -n 60 || true
    exit 0
  ' 2>&1 || true

  hr
}

restart_docker_in_vm_best_effort() {
  dim "  ↻ Restarting docker+containerd inside Colima VM (best-effort)..."

  colima_ssh_as_user sh -lc '
    set +e
    sudo systemctl restart containerd 2>/dev/null || true
    sudo systemctl restart docker      2>/dev/null || true
    sudo service containerd restart     2>/dev/null || true
    sudo service docker restart         2>/dev/null || true
    sudo /etc/init.d/containerd restart 2>/dev/null || true
    sudo /etc/init.d/docker restart     2>/dev/null || true
    sudo rc-service containerd restart 2>/dev/null || true
    sudo rc-service docker restart      2>/dev/null || true
    exit 0
  ' >/dev/null 2>&1 || true

  local i=0
  while (( i < 30 )); do
    docker_as_user version >/dev/null 2>&1 && return 0
    sleep 1
    ((i++))
  done
  return 1
}

recover_docker_api_best_effort() {
  local reason="${1:-docker transport failure}"
  warn "  🔧 Recovery triggered: ${reason}"

  say "  - Step 1: restart docker/containerd inside VM"
  restart_docker_in_vm_best_effort || true
  wait_for_docker_api_quick 25 && { ok "  ✅ Recovery OK (VM service restart)"; return 0; }

  say "  - Step 2: kickstart LaunchDaemon (${LABEL})"
  kickstart_daemon_best_effort || true
  wait_for_docker_api_quick 45 && { ok "  ✅ Recovery OK (daemon kickstart)"; return 0; }

  say "  - Step 3: colima stop + kickstart daemon"
  run_as_user "${COLIMA_BIN}" stop --profile "${COLIMA_PROFILE}" >/dev/null 2>&1 || true
  kickstart_daemon_best_effort || true
  wait_for_docker_api_quick 90 && { ok "  ✅ Recovery OK (stop + kickstart)"; return 0; }

  bad "  ❌ Recovery failed (docker still EOF/flaky)"
  colima_diag_brief
  return 1
}

# ------------------------------------------------------------------------------
# Quiet colima provisioning start (filters time=... INFO spam from terminal)
# ------------------------------------------------------------------------------
colima_start_provisioning_quiet() {
  local tmp rc
  rc=0

  tmp="$(run_as_user /usr/bin/mktemp "/tmp/colima-pulse.colima-start.${COLIMA_PROFILE}.XXXXXX")" \
    || die "mktemp failed for colima start"
  cleanup_register "${tmp}"

  set +e
  run_as_user "${COLIMA_BIN}" start \
    --profile "${COLIMA_PROFILE}" \
    --runtime "${COLIMA_RUNTIME}" \
    --vm-type "${COLIMA_VM_TYPE}" \
    --cpus "${COLIMA_CPUS}" \
    --memory "${COLIMA_MEMORY}" \
    --disk "${COLIMA_DISK}" \
    > "${tmp}" 2>&1
  rc=$?
  set -e

  # Always append FULL raw output into LOG_PATH for forensics.
  {
    echo "-------------------------------------------------------------------------------"
    echo "colima start raw output ($(date))"
    echo "-------------------------------------------------------------------------------"
    cat "${tmp}"
    echo "-------------------------------------------------------------------------------"
    echo "end colima start raw output"
    echo "-------------------------------------------------------------------------------"
  } | append_to_log_best_effort

  # Terminal output: filtered (no time="..." level=info spam)
  if [[ "${COLIMA_START_FILTER_INFO:l}" == "true" ]]; then
    if is_tty && [[ -w /dev/tty ]]; then
      /usr/bin/grep -Ev '^time="[^"]+" level=info ' "${tmp}" > /dev/tty || true
    else
      /usr/bin/grep -Ev '^time="[^"]+" level=info ' "${tmp}" || true
    fi
  else
    if is_tty && [[ -w /dev/tty ]]; then
      cat "${tmp}" > /dev/tty || true
    else
      cat "${tmp}" || true
    fi
  fi

  [[ "${rc}" -eq 0 ]] || die "colima start failed (rc=${rc}) — see ${LOG_PATH}"
}

# ------------------------------------------------------------------------------
# Containers install (plain text docker run commands, idempotent)
# ------------------------------------------------------------------------------
sanitize_container_text() {
  local file="$1"
  [[ -f "${file}" ]] || return 1

  /usr/bin/perl -0777 -pe '
    s/\r//g;
    s/[│┆┊┇┋]/ /g;
    s/^[ \t]*(?:\$\s+|❯\s+|➜\s+|>\s+)//mg;
    s/\\[ \t]*\n/ /g;
  ' -- "${file}"
}

extract_name_from_text() {
  local text="$1"
  if [[ "$text" =~ --name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then print -r -- "${match[1]}"; return 0; fi
  if [[ "$text" =~ --name[[:space:]]*=[[:space:]]*\'([^\']+)\' ]]; then print -r -- "${match[1]}"; return 0; fi
  if [[ "$text" =~ --name[[:space:]]*=[[:space:]]*([^[:space:]]+) ]]; then print -r -- "${match[1]}"; return 0; fi
  if [[ "$text" =~ --name[[:space:]]+\"([^\"]+)\" ]]; then print -r -- "${match[1]}"; return 0; fi
  if [[ "$text" =~ --name[[:space:]]+\'([^\']+)\' ]]; then print -r -- "${match[1]}"; return 0; fi
  if [[ "$text" =~ --name[[:space:]]+([^[:space:]]+) ]]; then print -r -- "${match[1]}"; return 0; fi
  return 1
}

extract_container_name() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local content name
  content="$(sanitize_container_text "$file" 2>/dev/null || true)"
  [[ -n "$content" ]] || return 1
  name="$(extract_name_from_text "$content" || true)"
  [[ -n "$name" ]] || return 1
  name="${name#\"}"; name="${name%\"}"
  name="${name#\'}"; name="${name%\'}"
  [[ -n "$name" ]] || return 1
  print -r -- "$name"
}

is_transient_docker_error() {
  local text="$1"
  # Treat ANY EOF as transient for Colima VM docker socket flakiness.
  print -r -- "${text}" | /usr/bin/grep -Eqi \
    '(_ping.*EOF|\bEOF\b|context canceled|client connection is closing|connection reset by peer|broken pipe|i/o timeout|TLS handshake timeout|unexpected EOF|http2:.*stream|net/http: TLS handshake timeout|connection refused|no such file or directory)'
}

run_container_file_with_retry() {
  local src="$1"
  local name="$2"

  local tries="${CONTAINER_TRIES}"
  local attempt=1
  local out rc marker="__COLIMA_PULSE_RC__="

  local tmp
  tmp="$(run_as_user /usr/bin/mktemp "/tmp/colima-pulse-container.${name}.XXXXXX")" \
    || die "mktemp failed for container ${name}"
  cleanup_register "${tmp}"

  local stamp="$(ts_now)"
  local runlog_base="/tmp/colima-pulse.${name}.${stamp}"

  {
    print -r -- "#!/bin/zsh"
    print -r -- "set -e"
    print -r -- "set -o pipefail"
    print -r -- ""
    sanitize_container_text "${src}"
  } | run_as_user /usr/bin/tee "${tmp}" >/dev/null

  run_as_user /bin/chmod 0700 "${tmp}" >/dev/null 2>&1 || true

  say "  - Built temp script: ${tmp}"
  say "  - Logs base: ${runlog_base}.attemptN.log"

  if [[ "${CONTAINER_DEBUG_SCRIPT:l}" == "true" ]]; then
    hr
    say "  - Sanitized script (first 160 lines):"
    run_as_user /usr/bin/sed -n '1,160p' "${tmp}" 2>&1 || true
    hr
  fi

  if ! docker_as_user version >/dev/null 2>&1; then
    warn "  ⚠️ Docker API not healthy before container run."
    recover_docker_api_best_effort "pre-container docker version failed" || true
  fi

  while (( attempt <= tries )); do
    local runlog="${runlog_base}.attempt${attempt}.log"

    say "  - Attempt ${attempt}/${tries}"
    docker_as_user rm -f "${name}" >/dev/null 2>&1 || true

    out="$(
      ( set +e
        run_as_user env DOCKER_HOST="${DOCKER_HOST_URI}" "${tmp}"
        echo "${marker}$?"
      ) 2>&1
    )"

    print -r -- "${out}" | run_as_user /usr/bin/tee "${runlog}" >/dev/null || true
    say "  - Saved output: ${runlog}"

    rc="${out##*${marker}}"
    out="${out%$'\n'"${marker}${rc}"}"

    if [[ "${rc}" -eq 0 ]]; then
      [[ -n "${out}" ]] && print -r -- "${out}"
      return 0
    fi

    if is_transient_docker_error "${out}"; then
      warn "  ⚠️ Transient Docker error detected (rc=${rc})."
      say "  ↻ Attempting recovery..."
      recover_docker_api_best_effort "container run/pull transport error" || true
      sleep 2
      ((attempt++))
      continue
    fi

    hr
    bad "❌ Container install failed (non-transient) for: ${name}"
    say "  Source: ${src}"
    say "  Temp:   ${tmp}"
    say "  Log:    ${runlog}"
    hr
    [[ -n "${out}" ]] && print -r -- "${out}"
    hr
    step "▶ Docker diagnostics (brief)"
    docker_diag_brief
    hr
    return "${rc}"
  done

  hr
  bad "❌ Container install failed after ${tries} attempts: ${name}"
  say "  Source:   ${src}"
  say "  Temp:     ${tmp}"
  say "  Last log: ${runlog_base}.attempt${tries}.log"
  hr
  step "▶ Docker diagnostics (brief)"
  docker_diag_brief
  hr
  step "▶ Colima/launchd diagnostics (brief)"
  colima_diag_brief
  return "${rc:-1}"
}

install_containers() {
  [[ -d "${CONTAINERS_DIR}" ]] || { dim "ℹ️ No ./containers directory found; skipping."; return 0; }

  step "▶ Installing containers"
  hr

  local f name any=0
  for f in "${CONTAINERS_DIR}"/*; do
    [[ -f "${f}" ]] || continue

    case "${f:t:l}" in
      readme.md|*.md) continue ;;
    esac

    any=1
    step "▶ ${f}"

    if ! name="$(extract_container_name "${f}" 2>/dev/null)"; then
      bad "  ❌ No --name detected — skipping: ${f}"
      hr
      continue
    fi

    say "  - Detected --name: ${name} (removing if exists)"
    docker_as_user rm -f "${name}" >/dev/null 2>&1 || true

    run_container_file_with_retry "${f}" "${name}"

    ok "✅ Completed"
    hr
  done

  [[ "${any}" -eq 1 ]] || dim "ℹ️ ./containers exists but has no installable files; skipping."
}

print_docker_ps_summary() {
  hr
  step "📦 DOCKER RUNTIME STATUS"
  hr
  if docker_as_user ps --format '{{.Names}}' 2>/dev/null | /usr/bin/grep -q .; then
    docker_as_user ps
  else
    dim "ℹ️ No running containers."
  fi
  hr
}

# ------------------------------------------------------------------------------
# Nuclear guard
# ------------------------------------------------------------------------------
guard_nuclear_reset() {
  if [[ "${FULL_RESET:l}" != "true" ]]; then
    hr
    ok "🟢 MODE: RESTART-ONLY (no deletion)"
    hr
    return 0
  fi

  hr
  bad "🚨🚨🚨  MODE: NUCLEAR RESET  🚨🚨🚨"
  hr
  warn "This will delete:"
  say "  - Colima profile: ${COLIMA_PROFILE}"
  say "  - ~/.colima (if present)"
  say "  - ~/.config/colima (if present)"
  say "  - Containers + images/volumes depending on PRUNE_MODE (after restart)"
  hr

  if ! is_tty && [[ "${FORCE_YES:l}" != "true" ]]; then
    die "--full-reset in non-interactive mode is refused without --force-yes."
  fi

  maybe_backup_state

  if [[ "${RESET_REQUIRE_CONFIRM:l}" == "true" ]]; then
    if [[ "${FORCE_YES:l}" == "true" && ! is_tty ]]; then
      warn "⚠️ --force-yes non-interactive: skipping typed confirmation"
      hr
      return 0
    fi
    if ! require_typed_confirm "${RESET_CONFIRM_TOKEN}"; then
      die "Nuclear reset aborted."
    fi
    hr
  fi
}

# ==============================================================================
# MAIN
# ==============================================================================
hr
step "▶ Pre-flight: reset guard"
guard_nuclear_reset
hr

maybe_clean_other_colima_daemons

step "▶ Ensuring our LaunchDaemon is not running during reset/provision"
daemon_bootout_remove_if_present
sudo rm -f "${PLIST_PATH}" >/dev/null 2>&1 || true
hr

kill_colima_stack
hr

if [[ "${FULL_RESET:l}" == "true" ]]; then
  step "▶ Deleting profile ${COLIMA_PROFILE}"
  run_as_user "${COLIMA_BIN}" delete --profile "${COLIMA_PROFILE}" -f >/dev/null 2>&1 || true

  step "▶ Purging state dirs"
  run_as_user /bin/rm -rf "${HOMEBREW_USER_HOME}/.colima" >/dev/null 2>&1 || true
  run_as_user /bin/rm -rf "${HOMEBREW_USER_HOME}/.config/colima" >/dev/null 2>&1 || true
  hr
else
  step "▶ FULL_RESET=false — keeping state dirs"
  hr
fi

step "▶ Starting colima provisioning (one-time start)"
colima_start_provisioning_quiet

hr
verify_qemu_retry || die "Colima not using QEMU"

hr
step "▶ Stopping provisioning instance (daemon will supervise foreground)"
run_as_user "${COLIMA_BIN}" stop --profile "${COLIMA_PROFILE}" >/dev/null 2>&1 || true
hr

step "▶ Installing + bootstrapping LaunchDaemon (${LABEL})"
bootstrap_daemon_strict
hr

wait_for_socket
wait_for_docker_api
wait_for_docker_stable

maybe_prune_after_ready

install_containers
print_docker_ps_summary

echo ""
echo "================================================================================"
ok "✅ SUCCESS — QEMU enforced, daemon supervised, Docker stable, containers installed cleanly."
echo "================================================================================"
echo ""
