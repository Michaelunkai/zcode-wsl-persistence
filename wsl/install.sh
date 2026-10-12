#!/usr/bin/env bash
# install.sh — one-shot provisioner for the ZCode WSL2 GUI persistence engine.
# Run INSIDE Ubuntu 24.04 (Noble) WSL2 as root:
#   sudo bash install.sh
# Environment overrides:
#   ZCODE_DEB_URL  (default: official 3.15.1 linux-x64 .deb from cdn-zcode.z.ai)
#   WSL_USER       (default: ubuntu)
#
# What it does (phases 1–5 of the mission):
#   1. apt dependencies (Noble t64 names) + cron service enabled
#   2. ZCode Linux Desktop .deb downloaded to /tmp/zcode-desktop.deb and installed
#   3. non-destructive one-way sync  /mnt/c/.../.zcode  ->  ~/.zcode  (+ Electron appdata)
#   4. ~/zcode-wsl-migration deployed; managed tmux session `zcode` started
#   5. user crontab installed (@reboot boot hook + daily sync)
#
# SAFETY: nothing here writes to, deletes from, locks, or kills anything under
# /mnt/c. The Windows ZCode installation and its live processes are untouched.
set -euo pipefail

ZCODE_DEB_URL="${ZCODE_DEB_URL:-https://cdn-zcode.z.ai/zcode/electron/releases/3.15.1/linux-x64/ZCode-3.15.1-linux-x64.deb}"
WSL_USER="${WSL_USER:-ubuntu}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # canonical repo: wsl/ dir
MIG="/home/${WSL_USER}/zcode-wsl-migration"

log() { echo "[install] $(date -Is) $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash install.sh"; exit 1; }

# ---------------------------------------------------------------- phase 1
log "PHASE 1: apt dependencies (Ubuntu 24.04 Noble, t64 package names)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  rsync tmux curl wget cron ca-certificates gnupg \
  libgtk-3-0t64 libnotify4 libnss3 libxss1 libasound2t64 libgbm1 \
  x11-utils wmctrl libsecret-1-0 libxkbcommon0 libdrm2 \
  fonts-liberation util-linux procps psmisc lsof
systemctl enable --now cron 2>/dev/null || service cron start
systemctl is-active cron >/dev/null 2>&1 || service cron start
log "cron active: $(systemctl is-active cron 2>/dev/null || echo 'service:started')"

# ---------------------------------------------------------------- user setup
if ! id "${WSL_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "${WSL_USER}"
  log "created user ${WSL_USER}"
fi
if ! grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
  printf '\n[user]\ndefault=%s\n' "${WSL_USER}" >> /etc/wsl.conf
  log "/etc/wsl.conf: default user set to ${WSL_USER}"
fi

# ---------------------------------------------------------------- phase 2
log "PHASE 2: ZCode Linux Desktop .deb <- ${ZCODE_DEB_URL}"
if [ ! -s /tmp/zcode-desktop.deb ]; then
  curl -fL --retry 3 -o /tmp/zcode-desktop.deb "${ZCODE_DEB_URL}"
fi
dpkg -i /tmp/zcode-desktop.deb || apt-get install -f -y
ZCODE_BIN="$(command -v zcode || true)"
[ -n "${ZCODE_BIN}" ] || ZCODE_BIN="$(ls /opt/ZCode/zcode /usr/bin/zcode /usr/local/bin/zcode 2>/dev/null | head -1 || true)"
[ -n "${ZCODE_BIN}" ] || { echo "FATAL: zcode binary not found after install"; exit 1; }
log "zcode binary: ${ZCODE_BIN} ($(readlink -f "${ZCODE_BIN}"))"
MISSING_LIBS="$(ldd "$(readlink -f "${ZCODE_BIN}")" 2>/dev/null | grep 'not found' || true)"
if [ -n "${MISSING_LIBS}" ]; then
  apt-get install -f -y || true
  MISSING_LIBS="$(ldd "$(readlink -f "${ZCODE_BIN}")" 2>/dev/null | grep 'not found' || true)"
fi
[ -z "${MISSING_LIBS}" ] || { echo "FATAL: unresolved libraries:"; echo "${MISSING_LIBS}"; exit 1; }
log "dynamic library check: clean"

# ---------------------------------------------------------------- phase 4 (deploy before first sync)
log "PHASE 4a: deploying scripts to ${MIG}"
mkdir -p "${MIG}/logs"
for f in launch_zcode.sh sync_zcode.sh boot_zcode.sh migrate_credentials.py; do
  tr -d '\r' < "${SRC_DIR}/${f}" > "${MIG}/${f}"
  chmod 755 "${MIG}/${f}"
done
chown -R "${WSL_USER}:${WSL_USER}" "${MIG}"

# ---------------------------------------------------------------- phase 3
log "PHASE 3: non-destructive one-way sync (source is read-only; never --delete)"
runuser -u "${WSL_USER}" -- "${MIG}/sync_zcode.sh" || true
chown -R "${WSL_USER}:${WSL_USER}" "/home/${WSL_USER}/.zcode" "/home/${WSL_USER}/.config/ZCode" 2>/dev/null || true
log "sync complete: $(du -sh /home/${WSL_USER}/.zcode 2>/dev/null | cut -f1) imported"

# ---------------------------------------------------------------- phase 3b: credential adoption
# The Windows credentials.json is DPAPI-envelope-encrypted (undecryptable on
# Linux). migrate_credentials.py re-wraps every blob under a portable secret
# (generated 0600 at ~/.zcode-wsl-auth-secret; launch_zcode.sh exports it).
log "PHASE 3b: credential store cross-OS adoption"
runuser -u "${WSL_USER}" -- bash -c '
  set -e
  F="${HOME}/.zcode-wsl-auth-secret"
  if [ ! -s "${F}" ]; then umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > "${F}"; umask 022; fi
  export ZCODE_CREDENTIAL_SECRET="$(cat "${F}")"
  python3 "'"${MIG}"'/migrate_credentials.py"
  [ -f "${HOME}/.zcode/v2/.wsl-auth-adopted" ] || date -Is > "${HOME}/.zcode/v2/.wsl-auth-adopted"
  chown -R '"${WSL_USER}"':'"${WSL_USER}"' "${HOME}/.zcode/v2/credentials.json" "${HOME}/.zcode/v2/.wsl-auth-adopted" "${F}"
'
log "credential store adopted and re-wrapped"

# ---------------------------------------------------------------- phase 4b
log "PHASE 4b: starting managed tmux session 'zcode' (GUI via WSLg)"
runuser -u "${WSL_USER}" -- "${MIG}/boot_zcode.sh"

# ---------------------------------------------------------------- phase 5
log "PHASE 5: user crontab (@reboot boot + daily sync)"
EXISTING="$(crontab -u "${WSL_USER}" -l 2>/dev/null | grep -v 'zcode-wsl-migration' || true)"
{ echo "${EXISTING}"; grep -v '^\s*#' "${SRC_DIR}/zcode-sync.crontab" | grep -v '^\s*$'; } | crontab -u "${WSL_USER}" -
crontab -u "${WSL_USER}" -l

log "INSTALL COMPLETE — run verify.sh next."
