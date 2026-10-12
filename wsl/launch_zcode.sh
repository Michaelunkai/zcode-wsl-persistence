#!/usr/bin/env bash
# launch_zcode.sh — ZCode Linux Desktop GUI launcher (runs inside the managed tmux session).
#
# SAFETY: the rsync below is one-way and read-only towards Windows. It only READS
# /mnt/c/Users/Admin/.zcode/ and can never delete, overwrite-destroy, lock, or
# interrupt anything running on the Windows side. 2>/dev/null keeps the tmux pane
# clean; `|| true` guarantees the GUI still launches even if /mnt/c is absent
# (full isolation after a Windows-side wipe).
# The Windows credentials file is DPAPI-encrypted (undecryptable on Linux) and is
# handled by sync_zcode.sh's staging + migrate_credentials.py re-wrap — excluded
# here so a Windows-side token refresh can never clobber the adopted Linux store.
# Gated: the full tree pass runs only while local state is thin (first bootstrap);
# once populated this line is a no-op, so launch is instant. The daily cron keeps
# the state fresh.
state_populated() {
  [ -d "${HOME}/.zcode/v2" ] || return 1
  [ "$(find "${HOME}/.zcode" -type f 2>/dev/null | head -3001 | wc -l)" -ge 3000 ]
}
if ! state_populated; then
  rsync -av --update \
    --exclude 'v2/credentials.json' \
    /mnt/c/Users/Admin/.zcode/ ~/.zcode/ 2>/dev/null || true
fi
export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-0

# Portable credential secret: the app derives its AES-256-GCM credential key
# from $ZCODE_CREDENTIAL_SECRET when set. A fixed per-machine secret makes the
# re-wrapped credential store decryptable across launches (see
# migrate_credentials.py). Generated once, 0600, never committed.
SECRET_FILE="${HOME}/.zcode-wsl-auth-secret"
if [ ! -s "${SECRET_FILE}" ]; then
  umask 077
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${SECRET_FILE}"
  umask 022
fi
export ZCODE_CREDENTIAL_SECRET="$(cat "${SECRET_FILE}")"

exec zcode --no-sandbox
