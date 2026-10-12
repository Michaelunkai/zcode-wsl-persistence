#!/usr/bin/env bash
# install.sh — idempotent fast-path provisioner for the ZCode WSL2 GUI persistence engine.
# Run INSIDE Ubuntu 24.04 (Noble) WSL2 as root:
#   sudo bash install.sh
#
# BEHAVIOUR (what you asked for):
#   * EVERY step is check-then-skip: anything already installed/available is
#     skipped to save time — apt, packages, the .deb, cron, user, sync,
#     credential adoption, crontab.
#   * If everything is already present the script does almost nothing and makes
#     sure the app is OPEN and CONNECTED immediately (a healthy running instance
#     is never restarted).
#   * Anything missing is installed — no exceptions — then the app is opened.
#
# Environment overrides:
#   ZCODE_DEB_URL  (default: official 3.15.1 linux-x64 .deb from cdn-zcode.z.ai)
#   WSL_USER       (default: ubuntu)
#   VERIFY=1       also run the full 24-assertion verification gate at the end
set -uo pipefail

ZCODE_DEB_URL="${ZCODE_DEB_URL:-https://cdn-zcode.z.ai/zcode/electron/releases/3.15.1/linux-x64/ZCode-3.15.1-linux-x64.deb}"
WSL_USER="${WSL_USER:-ubuntu}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIG="/home/${WSL_USER}/zcode-wsl-migration"
HOME_U="/home/${WSL_USER}"
T0=$(date +%s)
DONE_INSTALL=0; DONE_SKIP=0

log()  { echo "[install] $*"; }
do_it(){ DONE_INSTALL=$((DONE_INSTALL+1)); echo "[DO   ] $*"; }
skip_it(){ DONE_SKIP=$((DONE_SKIP+1)); echo "[SKIP ] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash install.sh"; exit 1; }

# ----------------------------------------------------------------- helpers
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

zcode_bin() {
  local b
  b="$(command -v zcode 2>/dev/null || true)"
  [ -n "$b" ] || b="$(ls /opt/ZCode/zcode /usr/bin/zcode /usr/local/bin/zcode 2>/dev/null | head -1 || true)"
  echo "$b"
}

zcode_libs_clean() {
  local b; b="$(zcode_bin)"; [ -n "$b" ] || return 1
  [ -z "$(ldd "$(readlink -f "$b")" 2>/dev/null | grep 'not found' || true)" ]
}

state_populated() {  # migrated state present? (early-exit count: cheap)
  [ -d "${HOME_U}/.zcode/v2" ] || return 1
  [ "$(find "${HOME_U}/.zcode" -type f 2>/dev/null | head -3001 | wc -l)" -ge 3000 ]
}

creds_adopted() {
  [ -e "${HOME_U}/.zcode/v2/.wsl-auth-adopted" ] || return 1
  [ -s "${HOME_U}/.zcode-wsl-auth-secret" ] || return 1
  [ "$(runuser -u "${WSL_USER}" -- python3 -c "import json,os;print(len(json.load(open(os.path.expanduser('~/.zcode/v2/credentials.json')))))" 2>/dev/null || echo 0)" -ge 8 ]
}

export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------- phase 1: packages
MISSING_PKGS=()
for p in rsync tmux curl wget cron ca-certificates gnupg \
         libgtk-3-0t64 libnotify4 libnss3 libxss1 libasound2t64 libgbm1 \
         x11-utils wmctrl libsecret-1-0 libxkbcommon0 libdrm2 \
         fonts-liberation util-linux procps psmisc lsof; do
  pkg_installed "$p" || MISSING_PKGS+=("$p")
done
if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
  skip_it "apt packages (all already installed)"
else
  do_it "apt: installing ${#MISSING_PKGS[@]} missing package(s): ${MISSING_PKGS[*]}"
  apt-get update -y
  apt-get install -y --no-install-recommends "${MISSING_PKGS[@]}"
fi

if systemctl is-active cron >/dev/null 2>&1; then
  skip_it "cron service (already active)"
else
  do_it "cron service: enabling"
  systemctl enable --now cron 2>/dev/null || service cron start
fi

# ----------------------------------------------------------------- user
if id "${WSL_USER}" >/dev/null 2>&1; then
  skip_it "user ${WSL_USER} (already exists)"
else
  do_it "creating user ${WSL_USER}"
  useradd -m -s /bin/bash -G sudo "${WSL_USER}"
fi
if grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
  skip_it "/etc/wsl.conf default user (already set)"
else
  do_it "/etc/wsl.conf: default user -> ${WSL_USER}"
  printf '\n[user]\ndefault=%s\n' "${WSL_USER}" >> /etc/wsl.conf
fi

# ----------------------------------------------------------------- phase 2: app
if [ -n "$(zcode_bin)" ] && zcode_libs_clean; then
  skip_it "ZCode desktop app ($(zcode_bin) — binary present, libraries clean)"
else
  do_it "ZCode desktop app: download + install ($ZCODE_DEB_URL)"
  if [ ! -s /tmp/zcode-desktop.deb ]; then
    curl -fL --retry 3 -o /tmp/zcode-desktop.deb "${ZCODE_DEB_URL}"
  fi
  dpkg -i /tmp/zcode-desktop.deb || apt-get install -f -y
  [ -n "$(zcode_bin)" ] || { echo "FATAL: zcode binary not found after install"; exit 1; }
  apt-get install -f -y || true
  zcode_libs_clean || { echo "FATAL: unresolved libraries"; ldd "$(readlink -f "$(zcode_bin)")" | grep 'not found'; exit 1; }
fi

# ----------------------------------------------------------------- phase 4a: scripts (always cheap, keeps latest)
# SELF-DEPLOY GUARD: when this script runs from the deployed location itself
# (SRC_DIR == MIG) the copy would truncate the files in place (tr < f > f) —
# skip instead; the scripts are already current there.
if [ "$(cd "${SRC_DIR}" && pwd)" = "${MIG}" ]; then
  skip_it "script deployment (running from the deployed location — already current)"
else
  do_it "deploying runtime scripts to ${MIG}"
  mkdir -p "${MIG}/logs"
  for f in launch_zcode.sh sync_zcode.sh boot_zcode.sh migrate_credentials.py; do
    tr -d '\r' < "${SRC_DIR}/${f}" > "${MIG}/${f}.tmp" && mv -f "${MIG}/${f}.tmp" "${MIG}/${f}"
    chmod 755 "${MIG}/${f}"
  done
  chown -R "${WSL_USER}:${WSL_USER}" "${MIG}" 2>/dev/null || true
fi

# ----------------------------------------------------------------- phase 3: state sync (the big one)
if state_populated; then
  skip_it "bulk state sync (~/.zcode already populated — daily cron keeps it fresh)"
else
  do_it "bulk state sync: /mnt/c/Users/Admin/.zcode -> ${HOME_U}/.zcode (one-way, never --delete)"
  runuser -u "${WSL_USER}" -- "${MIG}/sync_zcode.sh" || true
fi
if [ -d "/mnt/c/Users/Admin/AppData/Roaming/ZCode" ] && [ ! -d "${HOME_U}/.config/ZCode/session" ]; then
  do_it "Electron profile first-time import"
  runuser -u "${WSL_USER}" -- "${MIG}/sync_zcode.sh" || true
else
  skip_it "Electron profile import (already present)"
fi
chown -R "${WSL_USER}:${WSL_USER}" "${HOME_U}/.zcode" "${HOME_U}/.config/ZCode" 2>/dev/null || true

# ----------------------------------------------------------------- phase 3b: credential adoption
if creds_adopted; then
  skip_it "credential adoption (store re-wrapped and decryptable — already connected)"
else
  do_it "credential adoption: re-wrapping Windows DPAPI blobs for Linux"
  runuser -u "${WSL_USER}" -- bash -c '
    set -e
    F="${HOME}/.zcode-wsl-auth-secret"
    if [ ! -s "${F}" ]; then umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > "${F}"; umask 022; fi
    export ZCODE_CREDENTIAL_SECRET="$(cat "${F}")"
    python3 "'"${MIG}"'/migrate_credentials.py"
    [ -f "${HOME}/.zcode/v2/.wsl-auth-adopted" ] || date -Is > "${HOME}/.zcode/v2/.wsl-auth-adopted"
    chmod 600 "${HOME}/.zcode/v2/credentials.json"
  '
fi

# ----------------------------------------------------------------- phase 5: crontab
CRON_OK=0
crontab -u "${WSL_USER}" -l 2>/dev/null | grep -q 'boot_zcode\.sh' && \
crontab -u "${WSL_USER}" -l 2>/dev/null | grep -q '\*/20.*sync_zcode\.sh --quick' && \
crontab -u "${WSL_USER}" -l 2>/dev/null | grep -q '17 4.*sync_zcode\.sh' && CRON_OK=1
if [ "${CRON_OK}" -eq 1 ]; then
  skip_it "crontab (@reboot + 20-min live mirror + daily sync already registered)"
else
  do_it "crontab: registering @reboot boot + 20-min live mirror + daily sync"
  EXISTING="$(crontab -u "${WSL_USER}" -l 2>/dev/null | grep -v 'zcode-wsl-migration' || true)"
  NEW="@reboot ${MIG}/boot_zcode.sh >> ${MIG}/logs/boot.log 2>&1
*/20 * * * * ${MIG}/sync_zcode.sh --quick
17 4 * * * ${MIG}/sync_zcode.sh"
  { echo "${EXISTING}"; echo "${NEW}"; } | sed '/^$/d' | crontab -u "${WSL_USER}" -
fi

# ----------------------------------------------------------------- phase 4b: open the app (idempotent, instant if healthy)
log "opening the app (a healthy running instance is never restarted)…"
runuser -u "${WSL_USER}" -- "${MIG}/boot_zcode.sh" || true

# ----------------------------------------------------------------- optional verification gate
if [ "${VERIFY:-0}" = "1" ]; then
  runuser -u "${WSL_USER}" -- bash "${MIG}/verify.sh" || true
fi

ELAPSED=$(( $(date +%s) - T0 ))
log "DONE in ${ELAPSED}s — installed: ${DONE_INSTALL}, skipped: ${DONE_SKIP}"
log "app: tmux session 'zcode' | window: ZCode (Ubuntu) | verify: run ${MIG}/verify.sh"
