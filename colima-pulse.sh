#!/bin/zsh
# ==============================================================================
# Colima Pulse — Canonical Hardened Build (QEMU + launchd supervision)
# ------------------------------------------------------------------------------
# Locked goals (DO NOT RELAX):
#   - Deterministic Colima bootstrap for macOS (Apple Silicon + Intel)
#   - ALWAYS QEMU (never VZ) + docker runtime
#   - system LaunchDaemon (pre-login) supervising `colima start --foreground`
#   - MUST run as HOMEBREW_USER via: /usr/bin/su - USER -c "... exec colima start --foreground"
#   - Force ~/.colima usage (unset XDG_CONFIG_HOME; export HOME=...); prevents drift
#   - FULL_RESET=true = nuclear reset (daemon bootout + kill + delete + state purge)
#   - ./containers contains docker-run scripts, executed idempotently
#   - No hardcoded usernames (HOMEBREW_USER in .env)
#   - Unified log file: LOG_PATH (stdout+stderr)
#   - Visible wait loops (prints progress every 2s)
#   - Deep Docker runtime stabilization gate before container install
#
# Safety (does not change core behavior):
#   - Loud reset warning + typed confirmation token (DESTROY)
#   - Optional backups of state dirs before deletion
#   - Non-interactive destructive protection requires FORCE_YES=true
#   - Optional removal of OTHER colima launchd services to prevent dual VM state
#   - Docker prune occurs ONLY after Docker API is stable (never before)
#
# Optional repo hygiene (OFF by default):
#   - SYNC_TEMPLATES=true writes .env.example and appends missing keys to .env with backup
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------------------------
say() { print -r -- "$*"; }
hr()  { print -r -- "-------------------------------------------------------------------------------"; }
die() { print -r -- "❌ $*" >&2; exit 1; }

is_tty() { [[ -t 0 && -t 1 ]]; }

prompt_yn() {
  # Usage: prompt_yn "Question" "default"  -> prints y/n (y or n)
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
  # Usage: require_typed_confirm "TOKEN"
  local token="$1"
  if ! is_tty; then
    return 1
  fi
  say ""
  say "Type EXACTLY: ${token}"
  local confirm=""
  read confirm
  [[ "${confirm}" == "${token}" ]]
}

ts_now() { date +%Y%m%d-%H%M%S; }

# ------------------------------------------------------------------------------
# Paths / env
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${0}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONTAINERS_DIR="${SCRIPT_DIR}/containers"

[[ -f "${ENV_FILE}" ]] || die "Missing .env at: ${ENV_FILE}"

set -a
source "${ENV_FILE}"
set +a

: "${HOMEBREW_USER:?HOMEBREW_USER is required in .env}"
: "${FULL_RESET:=false}"

: "${COLIMA_PROFILE:=default}"
: "${COLIMA_RUNTIME:=docker}"
: "${COLIMA_VM_TYPE:=qemu}"

: "${COLIMA_CPUS:=2}"
: "${COLIMA_MEMORY:=1}"
: "${COLIMA_DISK:=20}"

: "${LABEL:=homebrew.mrcee.colima-pulse}"
: "${LOG_PATH:=/var/log/colima.log}"

# Safety knobs
: "${RESET_REQUIRE_CONFIRM:=true}"
: "${RESET_CONFIRM_TOKEN:=DESTROY}"

: "${RESET_BACKUP_MODE:=prompt}"            # prompt|true|false
: "${BACKUP_DIR_BASE:=${SCRIPT_DIR}/backups}"
: "${BACKUP_INCLUDE_DOT_COLIMA:=true}"
: "${BACKUP_INCLUDE_CONFIG_COLIMA:=true}"

: "${CLEAN_OTHER_COLIMA_DAEMONS:=prompt}"   # prompt|true|false

: "${PRUNE_MODE:=none}"                     # none|images|aggressive
: "${FORCE_YES:=false}"

: "${SYNC_TEMPLATES:=false}"

# Validate locked values
[[ "${COLIMA_VM_TYPE:l}" == "qemu" ]]   || die "COLIMA_VM_TYPE must be 'qemu' (got: ${COLIMA_VM_TYPE})"
[[ "${COLIMA_RUNTIME:l}" == "docker" ]] || die "COLIMA_RUNTIME must be 'docker' (got: ${COLIMA_RUNTIME})"

# Resolve user home
HOMEBREW_USER_HOME="$(dscl . -read "/Users/${HOMEBREW_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "${HOMEBREW_USER_HOME}" ]] || die "Failed to resolve home directory for user: ${HOMEBREW_USER}"
[[ -d "${HOMEBREW_USER_HOME}" ]] || die "Resolved home does not exist: ${HOMEBREW_USER_HOME}"

# Arch -> brew prefix
ARCH="$(uname -m)"
case "${ARCH}" in
  arm64)  BREW_PREFIX="/opt/homebrew" ;;
  x86_64) BREW_PREFIX="/usr/local" ;;
  *) die "Unsupported arch from uname -m: ${ARCH}" ;;
esac

COLIMA_BIN="${BREW_PREFIX}/bin/colima"
DOCKER_BIN="${BREW_PREFIX}/bin/docker"

if [[ ! -x "${COLIMA_BIN}" ]]; then COLIMA_BIN="$(command -v colima || true)"; fi
[[ -n "${COLIMA_BIN}" && -x "${COLIMA_BIN}" ]] || die "colima not found. Install via Homebrew for ${HOMEBREW_USER}."

if [[ ! -x "${DOCKER_BIN}" ]]; then DOCKER_BIN="$(command -v docker || true)"; fi
[[ -n "${DOCKER_BIN}" && -x "${DOCKER_BIN}" ]] || die "docker CLI not found. Install docker CLI (e.g., brew install docker)."

PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
COLIMA_SOCKET="${HOMEBREW_USER_HOME}/.colima/${COLIMA_PROFILE}/docker.sock"
DOCKER_HOST_URI="unix://${COLIMA_SOCKET}"

# ------------------------------------------------------------------------------
# Sudo keepalive
# ------------------------------------------------------------------------------
sudo -v
( while true; do sudo -n true 2>/dev/null || exit 0; sleep 30; done ) &
SUDO_KEEPALIVE_PID="$!"
trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT

# ------------------------------------------------------------------------------
# Optional: template sync (OFF by default)
# ------------------------------------------------------------------------------
write_env_example_template() {
  cat <<'EOF'
# ==============================================================================
# Colima Pulse — Environment Configuration
# ==============================================================================
# Copy this file to:
#   .env
# and adjust values as needed.
#
# Safety defaults:
#   - FULL_RESET=false
#   - RESET_BACKUP_MODE=prompt
#   - RESET_REQUIRE_CONFIRM=true
#   - PRUNE_MODE=none
# ==============================================================================

HOMEBREW_USER=your_username_here

FULL_RESET=false

COLIMA_PROFILE=default
COLIMA_RUNTIME=docker
COLIMA_VM_TYPE=qemu

COLIMA_CPUS=2
COLIMA_MEMORY=1
COLIMA_DISK=20

LABEL=homebrew.mrcee.colima-pulse
LOG_PATH=/var/log/colima.log

RESET_REQUIRE_CONFIRM=true
RESET_CONFIRM_TOKEN=DESTROY

RESET_BACKUP_MODE=prompt
BACKUP_DIR_BASE=./backups
BACKUP_INCLUDE_DOT_COLIMA=true
BACKUP_INCLUDE_CONFIG_COLIMA=true

CLEAN_OTHER_COLIMA_DAEMONS=prompt

PRUNE_MODE=none

FORCE_YES=false

SYNC_TEMPLATES=false
EOF
}

sync_templates_if_enabled() {
  [[ "${SYNC_TEMPLATES:l}" == "true" ]] || return 0

  hr
  say "▶ Repo templates: SYNC_TEMPLATES=true"
  hr

  local ex="${SCRIPT_DIR}/.env.example"
  local tmp="${SCRIPT_DIR}/.env.example.tmp.$$"

  write_env_example_template > "${tmp}"
  mv -f "${tmp}" "${ex}"
  say "📝 Updated: ${ex}"

  # Append missing keys to .env (no overwrites)
  local bak="${ENV_FILE}.bak.$(ts_now)"
  cp -p "${ENV_FILE}" "${bak}"
  say "🧩 Backed up .env to: ${bak}"

  # keys we ensure exist
  local keys=(
    "COLIMA_PROFILE" "COLIMA_RUNTIME" "COLIMA_VM_TYPE"
    "COLIMA_CPUS" "COLIMA_MEMORY" "COLIMA_DISK"
    "LABEL" "LOG_PATH"
    "RESET_REQUIRE_CONFIRM" "RESET_CONFIRM_TOKEN"
    "RESET_BACKUP_MODE" "BACKUP_DIR_BASE"
    "BACKUP_INCLUDE_DOT_COLIMA" "BACKUP_INCLUDE_CONFIG_COLIMA"
    "CLEAN_OTHER_COLIMA_DAEMONS"
    "PRUNE_MODE"
    "FORCE_YES"
    "SYNC_TEMPLATES"
  )

  local k
  for k in "${keys[@]}"; do
    if ! grep -Eq "^[[:space:]]*${k}=" "${ENV_FILE}"; then
      echo "" >> "${ENV_FILE}"
      echo "${k}=$(grep -E "^${k}=" "${ex}" | head -n1 | sed 's/^[[:space:]]*//')" >> "${ENV_FILE}"
    fi
  done
  say "🧩 Appended missing optional keys to .env (no overwrites)"
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
say "  ARCH:                  ${ARCH}"
say "  BREW_PREFIX:           ${BREW_PREFIX}"
say "  HOMEBREW_USER:         ${HOMEBREW_USER}"
say "  USER_HOME:             ${HOMEBREW_USER_HOME}"
say "  COLIMA_BIN:            ${COLIMA_BIN}"
say "  DOCKER_BIN:            ${DOCKER_BIN}"
say "  PROFILE:               ${COLIMA_PROFILE}"
say "  RUNTIME:               ${COLIMA_RUNTIME}"
say "  VM_TYPE:               ${COLIMA_VM_TYPE}"
say "  CPUS:                  ${COLIMA_CPUS}"
say "  MEMORY_GB:             ${COLIMA_MEMORY}"
say "  DISK_GB:               ${COLIMA_DISK}"
say "  FULL_RESET:            ${FULL_RESET}"
say "  LABEL:                 ${LABEL}"
say "  PLIST:                 ${PLIST_PATH}"
say "  LOG:                   ${LOG_PATH}"
say "  DOCKER_SOCK:           ${COLIMA_SOCKET}"
say "  RESET_CONFIRM_TOKEN:   ${RESET_CONFIRM_TOKEN}"
say "  RESET_BACKUP_MODE:     ${RESET_BACKUP_MODE}"
say "  CLEAN_OTHER_DAEMONS:   ${CLEAN_OTHER_COLIMA_DAEMONS}"
say "  PRUNE_MODE:            ${PRUNE_MODE}"
say "  FORCE_YES:             ${FORCE_YES}"
say "  SYNC_TEMPLATES:        ${SYNC_TEMPLATES}"
hr

sync_templates_if_enabled

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
  sudo touch "${LOG_PATH}"
  sudo chown root:wheel "${LOG_PATH}"
  sudo chmod 0644 "${LOG_PATH}"

  cat <<EOF | sudo tee "${PLIST_PATH}" >/dev/null
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

  sudo chown root:wheel "${PLIST_PATH}"
  sudo chmod 0644 "${PLIST_PATH}"
  sudo /usr/bin/plutil -lint "${PLIST_PATH}" >/dev/null || die "Installed plist failed plutil -lint"
}

bootstrap_daemon_strict() {
  local out

  say "▶ Ensuring our LaunchDaemon is fully removed before install"
  daemon_bootout_remove_if_present
  hr

  say "▶ Installing LaunchDaemon plist: ${PLIST_PATH}"
  install_plist
  hr

  say "▶ Bootstrap LaunchDaemon (STRICT)"
  out="$(sudo launchctl bootstrap system "${PLIST_PATH}" 2>&1)" || {
    say "❌ launchctl bootstrap failed:"
    say "${out}"
    say "---- last 120 lines: ${LOG_PATH} ----"
    sudo tail -n 120 "${LOG_PATH}" 2>/dev/null || true
    die "Bootstrap failed"
  }

  sudo launchctl enable "system/${LABEL}" >/dev/null 2>&1 || true

  say "▶ Kickstart LaunchDaemon"
  out="$(sudo launchctl kickstart -k "system/${LABEL}" 2>&1)" || {
    say "❌ launchctl kickstart failed:"
    say "${out}"
    say "---- launchctl print system/${LABEL} ----"
    sudo launchctl print "system/${LABEL}" || true
    say "---- last 200 lines: ${LOG_PATH} ----"
    sudo tail -n 200 "${LOG_PATH}" 2>/dev/null || true
    die "Kickstart failed"
  }

  say "✅ LaunchDaemon active: system/${LABEL}"
}

# ------------------------------------------------------------------------------
# Kill stack (TERM -> KILL)
# ------------------------------------------------------------------------------
kill_colima_stack() {
  say "▶ Killing any existing colima/qemu (TERM → KILL)"
  hr

  local uid
  uid="$(id -u "${HOMEBREW_USER}" 2>/dev/null || true)"
  [[ -n "${uid}" ]] || die "Could not resolve uid for ${HOMEBREW_USER}"

  # Best-effort stop via colima (as target user, forced ~/.colima)
  sudo -u "${HOMEBREW_USER}" env -u XDG_CONFIG_HOME HOME="${HOMEBREW_USER_HOME}" \
    "${COLIMA_BIN}" stop --profile "${COLIMA_PROFILE}" >/dev/null 2>&1 || true

  sudo pkill -TERM -u "${uid}" -f "${COLIMA_BIN} start"        >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "${COLIMA_BIN} daemon start" >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "limactl"                    >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "qemu-system"                >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "sshfs.*_lima"               >/dev/null 2>&1 || true
  sudo pkill -TERM -u "${uid}" -f "ssh: .*_lima"               >/dev/null 2>&1 || true
  sudo pkill -TERM -f "/usr/bin/su - ${HOMEBREW_USER} -c"      >/dev/null 2>&1 || true

  local i=0
  while (( i < 8 )); do
    if ps aux | grep -Ei 'colima start|colima daemon start|limactl|qemu-system|lima-colima|sshfs.*_lima' | grep -v grep >/dev/null 2>&1; then
      sleep 1
      ((i++))
    else
      say "✅ No lingering colima/lima/qemu processes detected"
      return 0
    fi
  done

  say "⚠️ Still running — escalating to KILL"
  sudo pkill -KILL -u "${uid}" -f "${COLIMA_BIN} start"        >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "${COLIMA_BIN} daemon start" >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "limactl"                    >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "qemu-system"                >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "sshfs.*_lima"               >/dev/null 2>&1 || true
  sudo pkill -KILL -u "${uid}" -f "ssh: .*_lima"               >/dev/null 2>&1 || true
  sudo pkill -KILL -f "/usr/bin/su - ${HOMEBREW_USER} -c"      >/dev/null 2>&1 || true

  sleep 1
  if ps aux | grep -Ei 'colima start|colima daemon start|limactl|qemu-system|lima-colima|sshfs.*_lima' | grep -v grep >/dev/null 2>&1; then
    die "Unable to fully stop Colima/Lima/QEMU. Reboot and re-run."
  fi

  say "✅ Forced shutdown complete"
}

# ------------------------------------------------------------------------------
# Detect + optionally remove other colima launchd services (prevents dual VM)
# ------------------------------------------------------------------------------
list_other_colima_labels_system() {
  # returns labels (one per line) that look colima-related in system domain, excluding ours
  sudo launchctl print system 2>/dev/null \
    | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {print $3}' \
    | tr -d '"' \
    | grep -i colima \
    | grep -v -F "${LABEL}" \
    || true
}

bootout_remove_label_system() {
  local lbl="$1"
  local plist="/Library/LaunchDaemons/${lbl}.plist"

  # Try bootout via plist if present
  if [[ -f "${plist}" ]]; then
    sudo launchctl bootout system "${plist}" >/dev/null 2>&1 || true
  else
    sudo launchctl bootout "system/${lbl}" >/dev/null 2>&1 || true
  fi
  sudo launchctl remove "${lbl}" >/dev/null 2>&1 || true

  # Also attempt to disable if an override exists
  sudo launchctl disable "system/${lbl}" >/dev/null 2>&1 || true

  # Remove plist if it exists (we only remove on explicit cleanup decision)
  if [[ -f "${plist}" ]]; then
    sudo rm -f "${plist}" >/dev/null 2>&1 || true
  fi
}

maybe_clean_other_colima_daemons() {
  local mode="${CLEAN_OTHER_COLIMA_DAEMONS:l}"
  [[ "${mode}" == "false" ]] && return 0

  local others
  others="$(list_other_colima_labels_system | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  [[ -n "${others}" ]] || return 0

  hr
  say "⚠️ Detected other system launchd services containing 'colima':"
  say "  ${others}"
  say ""
  say "These commonly cause the dual-state problem you showed:"
  say "  - one VM under ~/.colima"
  say "  - another VM under ~/.config/colima"
  hr

  local do_it="n"
  case "${mode}" in
    true) do_it="y" ;;
    prompt|*) do_it="$(prompt_yn "Remove these other colima services now (recommended)?" "y")" ;;
  esac

  [[ "${do_it}" == "y" ]] || { say "▶ Leaving other colima services in place"; hr; return 0; }

  say "▶ Removing other colima services (system domain)"
  hr

  local lbl
  for lbl in $(list_other_colima_labels_system); do
    say "  - Removing: ${lbl}"
    bootout_remove_label_system "${lbl}"
  done

  say "✅ Other colima services removed"
  hr
}

# ------------------------------------------------------------------------------
# Backup helpers
# ------------------------------------------------------------------------------
backup_one_dir_tar() {
  # args: src_dir tar_path (tar.gz)
  local src="$1"
  local out="$2"
  [[ -d "${src}" ]] || return 0

  local parent name
  parent="$(dirname -- "${src}")"
  name="$(basename -- "${src}")"

  # Deterministic macOS-safe tar:
  # - COPYFILE_DISABLE=1 prevents AppleDouble metadata
  # - --no-xattrs avoids extended attribute warnings
  # - exclude sockets (docker/containerd/lima sockets are not archivable)
  #
  # We silence tar's socket/xattr noise without failing backups.
  COPYFILE_DISABLE=1 /usr/bin/tar --no-xattrs \
    --exclude="*.sock" \
    --exclude=".colima/docker.sock" \
    --exclude=".colima/*/docker.sock" \
    --exclude=".colima/*/containerd.sock" \
    --exclude=".colima/_lima/**" \
    -C "${parent}" -czf "${out}" "${name}" 2>/dev/null
}

maybe_backup_state() {
  [[ "${FULL_RESET:l}" == "true" ]] || return 0

  local mode="${RESET_BACKUP_MODE:l}"
  local do_backup="n"

  case "${mode}" in
    true) do_backup="y" ;;
    false) do_backup="n" ;;
    prompt|*) do_backup="$(prompt_yn "Create backup before deletion?" "y")" ;;
  esac

  [[ "${do_backup}" == "y" ]] || { say "▶ Backup skipped"; hr; return 0; }

  local bdir="${BACKUP_DIR_BASE}"
  local stamp="$(ts_now)"
  local outbase="${bdir}/backup-${COLIMA_PROFILE}-${stamp}"
  mkdir -p "${bdir}"

  hr
  say "▶ Backup selected"
  say "  Target base: ${outbase}"
  hr

  if [[ "${BACKUP_INCLUDE_DOT_COLIMA:l}" == "true" && -d "${HOMEBREW_USER_HOME}/.colima" ]]; then
    say "  - Backing up: ${HOMEBREW_USER_HOME}/.colima"
    backup_one_dir_tar "${HOMEBREW_USER_HOME}/.colima" "${outbase}.dotcolima.tar.gz"
    say "    ✅ ${outbase}.dotcolima.tar.gz"
  fi

  if [[ "${BACKUP_INCLUDE_CONFIG_COLIMA:l}" == "true" && -d "${HOMEBREW_USER_HOME}/.config/colima" ]]; then
    say "  - Backing up: ${HOMEBREW_USER_HOME}/.config/colima"
    backup_one_dir_tar "${HOMEBREW_USER_HOME}/.config/colima" "${outbase}.configcolima.tar.gz"
    say "    ✅ ${outbase}.configcolima.tar.gz"
  fi

  hr
}

# ------------------------------------------------------------------------------
# QEMU verification (retry-based)
# ------------------------------------------------------------------------------
verify_qemu_once() {
  local out
  out="$(
    sudo -u "${HOMEBREW_USER}" env -u XDG_CONFIG_HOME HOME="${HOMEBREW_USER_HOME}" \
      "${COLIMA_BIN}" status --profile "${COLIMA_PROFILE}" --verbose 2>&1 || true
  )"

  if print -r -- "${out}" | grep -Eqi '(using[[:space:]]+VZ|virtualization[[:space:]]+framework|internal VM driver[[:space:]]+"vz"|vmType:[[:space:]]*vz|vm-type[[:space:]]+vz)'; then
    return 1
  fi

  if print -r -- "${out}" | grep -Eqi '(using[[:space:]]+QEMU|internal VM driver[[:space:]]+"qemu"|vmType:[[:space:]]*qemu|vm-type[[:space:]]+qemu)'; then
    return 0
  fi

  return 2
}

verify_qemu_retry() {
  say "▶ Verifying QEMU (retry up to 12x)"
  local i=1
  while (( i <= 12 )); do
    if verify_qemu_once; then
      say "✅ QEMU verified"
      return 0
    else
      local rc=$?
      if [[ "${rc}" -eq 1 ]]; then
        say "❌ VZ detected (attempt ${i}/12)"
      else
        say "⚠️ Unable to confirm VM type yet (attempt ${i}/12)"
      fi
    fi
    sleep 1
    ((i++))
  done
  return 1
}

# ------------------------------------------------------------------------------
# Wait loops
# ------------------------------------------------------------------------------
wait_for_socket() {
  local elapsed=0 max=180
  say "▶ Waiting for docker.sock..."
  while (( elapsed < max )); do
    if [[ -S "${COLIMA_SOCKET}" ]]; then
      say "✅ docker.sock present"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    say "  ... ${elapsed}s"
  done
  die "Timed out waiting for docker.sock after ${max}s"
}

wait_for_docker_api() {
  local elapsed=0 max=180
  say "▶ Waiting for Docker API..."
  while (( elapsed < max )); do
    if DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" version >/dev/null 2>&1; then
      say "✅ Docker API responding"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    say "  ... ${elapsed}s"
  done
  die "Timed out waiting for Docker API after ${max}s"
}

wait_for_docker_stable() {
  say "▶ Deep Docker stabilization check..."
  local stable=0 required=5
  while true; do
    if DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" info >/dev/null 2>&1 \
      && DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" ps >/dev/null 2>&1 \
      && DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" system info >/dev/null 2>&1; then
      stable=$((stable + 1))
      say "  - Stability ${stable}/${required}"
    else
      stable=0
      say "  - Docker not fully stable yet..."
    fi
    [[ "${stable}" -ge "${required}" ]] && break
    sleep 1
  done
  say "✅ Docker runtime stabilized"
}

# ------------------------------------------------------------------------------
# Docker prune (ONLY AFTER Docker is stable)
# ------------------------------------------------------------------------------
maybe_prune_after_ready() {
  local mode="${PRUNE_MODE:l}"

  # Default behavior: if FULL_RESET=true and user left PRUNE_MODE=none, use images.
  if [[ "${FULL_RESET:l}" == "true" && "${mode}" == "none" ]]; then
    mode="images"
  fi

  [[ "${mode}" == "none" ]] && { say "▶ Prune skipped (PRUNE_MODE=none)"; hr; return 0; }

  hr
  say "▶ Pruning Docker (AFTER docker is stable): PRUNE_MODE=${mode}"
  hr

  case "${mode}" in
    images)
      DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" image prune -af || true
      ;;
    aggressive)
      hr
      say "⚠️ AGGRESSIVE PRUNE includes volumes (DESTRUCTIVE)."
      if ! is_tty && [[ "${FORCE_YES:l}" != "true" ]]; then
        die "Non-interactive aggressive prune refused without FORCE_YES=true"
      fi
      if is_tty; then
        local ok
        ok="$(prompt_yn "Proceed with docker system prune -af --volumes ?" "n")"
        [[ "${ok}" == "y" ]] || { say "▶ Aggressive prune aborted"; hr; return 0; }
      fi
      DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" system prune -af --volumes || true
      ;;
    *)
      say "⚠️ Unknown PRUNE_MODE=${mode} — skipping"
      ;;
  esac

  hr
}

# ------------------------------------------------------------------------------
# Containers install (idempotent docker run scripts)
# ------------------------------------------------------------------------------
# Stage A: normalize a docker-run file into a single line.
normalize_container_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  # Collapse backslash-newline continuations into spaces so wrapped args still match
  sed -E ':a;N;$!ba;s/[[:space:]]*\\[[:space:]]*\n/ /g' -- "$file" 2>/dev/null
}

# Stage B: extract FIRST --name token from normalized text.
# Supported:
#   --name foo
#   --name "foo"
#   --name 'foo'
#   --name=foo
#   --name = "foo"
extract_name_from_text() {
  local text="$1"

  # Pure zsh extraction (no grep/sed/perl). First match wins.
  # Supports:
  #   --name foo
  #   --name "foo"
  #   --name 'foo'
  #   --name=foo
  #   --name = "foo"
  #
  # NOTE: zsh [[ str =~ regex ]] sets the $match array.
  #       We return ${match[1]} from the first successful pattern.

  # --name = "foo"   OR   --name="foo"
  if [[ "$text" =~ --name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
    print -r -- "${match[1]}"; return 0
  fi

  # --name = 'foo'   OR   --name='foo'
  if [[ "$text" =~ --name[[:space:]]*=[[:space:]]*[\'\"]?([^\ \t\'\"]+)[\'\"]? ]]; then
    # This fallback is intentionally conservative for '=' form.
    # It accepts bare tokens and simple quoted tokens (single/double).
    print -r -- "${match[1]}"; return 0
  fi

  # --name "foo"
  if [[ "$text" =~ --name[[:space:]]+\"([^\"]+)\" ]]; then
    print -r -- "${match[1]}"; return 0
  fi

  # --name 'foo'
  if [[ "$text" =~ --name[[:space:]]+\'([^\']+)\' ]]; then
    print -r -- "${match[1]}"; return 0
  fi

  # --name foo
  if [[ "$text" =~ --name[[:space:]]+([^[:space:]]+) ]]; then
    print -r -- "${match[1]}"; return 0
  fi

  return 1
}

# Stage C: file -> name
extract_container_name() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  local content name
  content="$(normalize_container_file "$file" || true)"
  [[ -n "$content" ]] || return 1

  name="$(extract_name_from_text "$content" || true)"
  [[ -n "$name" ]] || return 1

  print -r -- "$name"
}

# Stage D: run container scripts idempotently
install_containers() {
  [[ -d "${CONTAINERS_DIR}" ]] || { say "ℹ️ No ./containers directory found; skipping."; return 0; }

  say "▶ Installing containers"
  hr

  local f name any=0
  for f in "${CONTAINERS_DIR}"/*; do
    [[ -f "${f}" ]] || continue
    any=1

    say "▶ ${f}"

    if ! name="$(extract_container_name "${f}" 2>/dev/null)"; then
      say "  ❌ No --name detected — skipping: ${f}"
      hr
      continue
    fi

    say "  - Detected --name: ${name} (removing if exists)"
    DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" rm -f "${name}" >/dev/null 2>&1 || true

    (
      export DOCKER_HOST="${DOCKER_HOST_URI}"
      export PATH="$(dirname -- "${DOCKER_BIN}"):${PATH}"
      zsh "${f}"
    )

    say "✅ Completed"
    hr
  done

  [[ "${any}" -eq 1 ]] || say "ℹ️ ./containers exists but has no files; skipping."
}

# Stage E: status summary
print_docker_ps_summary() {
  hr
  say "📦 DOCKER RUNTIME STATUS"
  hr
  if DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
    DOCKER_HOST="${DOCKER_HOST_URI}" "${DOCKER_BIN}" ps
  else
    say "ℹ️ No running containers."
  fi
  hr
}

# ------------------------------------------------------------------------------
# Nuclear guard
# ------------------------------------------------------------------------------
guard_nuclear_reset() {
  [[ "${FULL_RESET:l}" == "true" ]] || return 0

  hr
  say "🚨🚨🚨  NUCLEAR RESET SELECTED  🚨🚨🚨"
  hr
  say "This will delete:"
  say "  - Colima profile: ${COLIMA_PROFILE}"
  say "  - ~/.colima (if present)"
  say "  - ~/.config/colima (if present)"
  say "  - Containers + images/volumes depending on PRUNE_MODE (after restart)"
  hr

  if ! is_tty && [[ "${FORCE_YES:l}" != "true" ]]; then
    die "FULL_RESET=true in non-interactive mode. Refusing without FORCE_YES=true."
  fi

  maybe_backup_state

  if [[ "${RESET_REQUIRE_CONFIRM:l}" == "true" ]]; then
    if [[ "${FORCE_YES:l}" == "true" && ! is_tty ]]; then
      say "⚠️ FORCE_YES=true non-interactive: skipping typed confirmation"
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
say "▶ Pre-flight: reset guard"
guard_nuclear_reset
hr

# Optional cleanup of other launchd colima services (prevents dual VM)
maybe_clean_other_colima_daemons

say "▶ Ensuring our LaunchDaemon is not running during reset/provision"
daemon_bootout_remove_if_present
sudo rm -f "${PLIST_PATH}" >/dev/null 2>&1 || true
hr

kill_colima_stack
hr

if [[ "${FULL_RESET:l}" == "true" ]]; then
  say "▶ Deleting profile ${COLIMA_PROFILE}"
  sudo -u "${HOMEBREW_USER}" env -u XDG_CONFIG_HOME HOME="${HOMEBREW_USER_HOME}" \
    "${COLIMA_BIN}" delete --profile "${COLIMA_PROFILE}" -f >/dev/null 2>&1 || true

  say "▶ Purging state dirs"
  # Remove both locations to prevent the exact dual-state issue you saw
  sudo -u "${HOMEBREW_USER}" /bin/rm -rf "${HOMEBREW_USER_HOME}/.colima" >/dev/null 2>&1 || true
  sudo -u "${HOMEBREW_USER}" /bin/rm -rf "${HOMEBREW_USER_HOME}/.config/colima" >/dev/null 2>&1 || true
  hr
else
  say "▶ FULL_RESET=false — keeping state dirs"
  hr
fi

say "▶ Starting colima provisioning (one-time start)"
sudo -u "${HOMEBREW_USER}" env -u XDG_CONFIG_HOME HOME="${HOMEBREW_USER_HOME}" \
  "${COLIMA_BIN}" start \
    --profile "${COLIMA_PROFILE}" \
    --runtime "${COLIMA_RUNTIME}" \
    --vm-type "${COLIMA_VM_TYPE}" \
    --cpus "${COLIMA_CPUS}" \
    --memory "${COLIMA_MEMORY}" \
    --disk "${COLIMA_DISK}"

hr
verify_qemu_retry || die "Colima not using QEMU"

hr
say "▶ Stopping provisioning instance (daemon will supervise foreground)"
sudo -u "${HOMEBREW_USER}" env -u XDG_CONFIG_HOME HOME="${HOMEBREW_USER_HOME}" \
  "${COLIMA_BIN}" stop --profile "${COLIMA_PROFILE}" >/dev/null 2>&1 || true
hr

say "▶ Installing + bootstrapping LaunchDaemon (${LABEL})"
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
say "✅ SUCCESS — QEMU enforced, daemon supervised, Docker stable, containers installed cleanly."
echo "================================================================================"
echo ""

