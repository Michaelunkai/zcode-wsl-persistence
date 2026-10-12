#!/usr/bin/env bash
# sync_zcode.sh — non-destructive one-way background sync (used by cron + boot).
#
# SAFETY CONTRACT (never violate):
#   * NEVER uses --delete or any flag that can remove files on either side.
#   * Source (/mnt/c/...) is strictly read-only input; we never write to /mnt/c.
#   * --update --ignore-existing: files that already exist in Linux are never
#     overwritten, so Linux-side state created by the running Linux ZCode is
#     always authoritative once imported (decoupling by design).
#   * --no-owner --no-group: imported files stay owned by the invoking Linux
#     user (the mission requires ownership strictly by $USER; drvfs presents
#     Windows files as root-owned, so preserving owner/group would violate it).
#   * flock: a single sync instance at a time; never overlaps a running GUI in
#     a racy way (rsync writes to a temp name then renames per file).
set -u

MIG="${HOME}/zcode-wsl-migration"
LOGDIR="${MIG}/logs"
LOG="${LOGDIR}/sync.log"
mkdir -p "${LOGDIR}"

# Single-instance guard.
exec 9>"${LOGDIR}/sync.lock"
if ! flock -n 9; then
  echo "$(date -Is) another sync is already running — skipping" >> "${LOG}"
  exit 0
fi

# Keep the log bounded (rotate at 5 MB).
if [ -f "${LOG}" ] && [ "$(stat -c%s "${LOG}")" -gt 5242880 ]; then
  mv -f "${LOG}" "${LOG}.old"
fi

SRC_ZCODE="/mnt/c/Users/Admin/.zcode/"
DST_ZCODE="${HOME}/.zcode/"
SRC_APPDATA="/mnt/c/Users/Admin/AppData/Roaming/ZCode/"
DST_APPDATA="${HOME}/.config/ZCode/"

# Auth/connection bundle: the small set of files that make the Linux app
# ALREADY CONNECTED at launch (OAuth tokens, active provider, onboarding,
# UI settings). These live-rewrite on the Windows side, so the first bulk
# sync can legitimately miss them (rsync exit 23, file changed as read).
# Policy for the bundle only: --update (newer wins, never deletes, never
# overwrites a Linux file that is NEWER — e.g. Linux-side token refreshes)，
# retried up to 3 times against the live source.
AUTH_FILES=(
  "v2/credentials.json"
  "v2/provider_config.json"
  "v2/onboarding-record.json"
  "v2/setting.json"
  "v2/bot-config.v3.json"
  "v2/bot-state.v3.json"
  "v2/telemetry-state.json"
)
sync_auth_bundle() {
  local f rc
  for f in "${AUTH_FILES[@]}"; do
    [ -f "${SRC_ZCODE}${f}" ] || continue
    mkdir -p "${DST_ZCODE}$(dirname "${f}")"
    rc=0
    for _ in 1 2 3; do
      rsync -av --update --no-owner --no-group \
        "${SRC_ZCODE}${f}" "${DST_ZCODE}${f}" >> "${LOG}" 2>&1 && break
      rc=$?
      sleep 2
    done
    [ "${rc}" -ne 0 ] && echo "$(date -Is) WARN: auth bundle file ${f} rsync rc=${rc} (will retry next cycle)" >> "${LOG}"
  done

  # credentials.json lifecycle (cross-OS blob re-wrap model):
  #  * The Windows original is DPAPI-encrypted and undecryptable on Linux, so it
  #    is always synced to a STAGING copy (credentials.windows.json) — never to
  #    the live file once adopted.
  #  * Before adoption (no marker): also refresh the live file verbatim so the
  #    migrator sees the freshest blobs.
  #  * After adoption (marker present): the live store is Linux-authoritative;
  #    the running Linux app refreshes its own tokens and sync never overwrites.
  local CREDS_MARK="${DST_ZCODE}v2/.wsl-auth-adopted"
  if [ -f "${SRC_ZCODE}v2/credentials.json" ]; then
    rc=0
    for _ in 1 2 3; do
      rsync -av --update --no-owner --no-group \
        "${SRC_ZCODE}v2/credentials.json" "${DST_ZCODE}v2/credentials.windows.json" >> "${LOG}" 2>&1 && break
      rc=$?
      sleep 2
    done
    [ "${rc}" -ne 0 ] && echo "$(date -Is) WARN: credentials staging sync rc=${rc}" >> "${LOG}"
    if [ ! -e "${CREDS_MARK}" ] && [ ! -f "${DST_ZCODE}v2/credentials.json" ]; then
      cp -p "${DST_ZCODE}v2/credentials.windows.json" "${DST_ZCODE}v2/credentials.json" 2>/dev/null || true
    fi
  fi
}

rc=0
echo "$(date -Is) sync start (pid $$)" >> "${LOG}"

if [ -d "${SRC_ZCODE}" ]; then
  mkdir -p "${DST_ZCODE}"
  rsync -av --update --ignore-existing --no-owner --no-group \
    "${SRC_ZCODE}" "${DST_ZCODE}" >> "${LOG}" 2>&1 || rc=$?
else
  # Windows source gone (wiped / uninstalled / WSL started offline): the Linux
  # copy is fully self-contained and stays authoritative. Not an error.
  echo "$(date -Is) NOTE: ${SRC_ZCODE} unavailable — Linux copy remains authoritative (isolation by design)" >> "${LOG}"
fi

if [ -d "${SRC_APPDATA}" ]; then
  mkdir -p "${DST_APPDATA}"
  rsync -av --update --ignore-existing --no-owner --no-group \
    "${SRC_APPDATA}" "${DST_APPDATA}" >> "${LOG}" 2>&1 || rc=$?
fi

# Auth bundle runs LAST so connection state lands even if the bulk pass hit
# a transient race with the live Windows app.
sync_auth_bundle

echo "$(date -Is) sync done rc=${rc}" >> "${LOG}"
exit "${rc}"
