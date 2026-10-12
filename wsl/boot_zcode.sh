#!/usr/bin/env bash
# boot_zcode.sh — idempotent boot hook (cron @reboot + hidden Windows logon task).
# Guarantees: at most ONE tmux session named `zcode`, at most ONE GUI process,
# silent everywhere, safe to call repeatedly and concurrently.
#
# LOCKING NOTE: the lock is a directory (mkdir is atomic on ext4) — never an
# flock'd fd. The tmux server forks from `tmux new-session` and would inherit
# any open fd (and its flock) forever, deadlocking every later boot hook.
set -u

MIG="${HOME}/zcode-wsl-migration"
LOG="${MIG}/logs/boot.log"
LOCKDIR="${MIG}/logs/boot.lockdir"
GUILOG="${MIG}/logs/gui.log"
mkdir -p "${MIG}/logs"
# Bound the GUI log (pipe-pane appends forever otherwise).
if [ -f "${GUILOG}" ] && [ "$(stat -c%s "${GUILOG}" 2>/dev/null || echo 0)" -gt 10485760 ]; then
  mv -f "${GUILOG}" "${GUILOG}.old"
fi
echo "$(date -Is) boot_zcode.sh invoked (pid $$)" >> "${LOG}"

acquire_lock() {
  if mkdir "${LOCKDIR}" 2>/dev/null; then
    echo $$ > "${LOCKDIR}/pid"
    return 0
  fi
  # Stale-holder detection: if the recorded pid is gone, break the lock.
  local holder
  holder="$(cat "${LOCKDIR}/pid" 2>/dev/null || true)"
  if [ -n "${holder}" ] && ! kill -0 "${holder}" 2>/dev/null; then
    echo "$(date -Is) breaking stale boot lock (holder ${holder} gone)" >> "${LOG}"
    rm -rf "${LOCKDIR}"
    mkdir "${LOCKDIR}" 2>/dev/null && { echo $$ > "${LOCKDIR}/pid"; return 0; }
  fi
  return 1
}

release_lock() { rm -rf "${LOCKDIR}" 2>/dev/null || true; }

# Wait for the WSLg X server socket (cron @reboot can race early WSL boot).
for _ in $(seq 1 60); do
  [ -S /tmp/.X11-unix/X0 ] && break
  sleep 1
done

export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"

# Same portable credential secret as launch_zcode.sh (the app's key derivation
# input; see migrate_credentials.py). Ensured to exist before any launch.
SECRET_FILE="${HOME}/.zcode-wsl-auth-secret"
if [ ! -s "${SECRET_FILE}" ]; then
  umask 077
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${SECRET_FILE}"
  umask 022
fi
export ZCODE_CREDENTIAL_SECRET="$(cat "${SECRET_FILE}")"

# Import before launch: full sync only on first bootstrap (thin state);
# afterwards a --quick pass (auth/settings bundle, seconds) keeps boot instant.
state_populated() {
  [ -d "${HOME}/.zcode/v2" ] || return 1
  [ "$(find "${HOME}/.zcode" -type f 2>/dev/null | head -3001 | wc -l)" -ge 3000 ]
}
if state_populated; then
  "${MIG}/sync_zcode.sh" --quick || true
else
  "${MIG}/sync_zcode.sh" || true
fi

# Session-database integrity: a malformed database would surface as failed
# session resumes ("database disk image is malformed"). Check before launch;
# heal from the Windows source when needed (milliseconds when healthy).
if [ -f "${MIG}/heal_databases.sh" ]; then
  bash "${MIG}/heal_databases.sh" >> "${MIG}/logs/heal.log" 2>&1 || true
fi

# Workspace path translation + failed-restore recovery: Windows-side sessions
# carry F:\ paths (translated to /mnt/...), and a store the app previously
# truncated (failed restore) is re-adopted from staging so every boot connects.
if [ -f "${MIG}/fix_windows_paths.py" ]; then
  python3 "${MIG}/fix_windows_paths.py" >> "${MIG}/logs/heal.log" 2>&1 || true
fi
if [ -f "${MIG}/migrate_credentials.py" ] && [ -s "${HOME}/.zcode-wsl-auth-secret" ]; then
  LIVE_N="$(python3 -c "import json,os;print(len(json.load(open(os.path.expanduser('~/.zcode/v2/credentials.json')))))" 2>/dev/null || echo 0)"
  STAGE_N="$(python3 -c "import json,os;print(len(json.load(open(os.path.expanduser('~/.zcode/v2/credentials.windows.json')))))" 2>/dev/null || echo 0)"
  if [ "${LIVE_N}" -lt 8 ] && [ "${STAGE_N}" -gt "${LIVE_N}" ]; then
    echo "$(date -Is) live store truncated (${LIVE_N}) — re-adopting from staging (${STAGE_N})" >> "${LOG}"
    export ZCODE_CREDENTIAL_SECRET="$(cat "${SECRET_FILE}")"
    python3 "${MIG}/migrate_credentials.py" >> "${MIG}/logs/heal.log" 2>&1 || true
  fi
fi

reap_orphans() {
  # NOTE: the Electron MAIN process renames itself (comm "ZCode", argv "ZCode"),
  # so it is invisible to /opt/ZCode path patterns — match it by exact comm too.
  pkill -KILL -u "$(id -un)" -x ZCode 2>/dev/null || true
  pkill -KILL -u "$(id -un)" -f '/opt/ZCode/' 2>/dev/null || true
  pkill -KILL -u "$(id -un)" -f 'user-data-dir=.*/\.config/ZCode' 2>/dev/null || true
  pkill -KILL -u "$(id -un)" -f 'zcode-host' 2>/dev/null || true
}

new_managed_session() {
  tmux new-session -d -s zcode -n gui "${MIG}/launch_zcode.sh" \; \
    pipe-pane -o "cat >> ${GUILOG}"
  echo "$(date -Is) tmux session 'zcode' created (GUI launching via WSLg, log: ${GUILOG})" >> "${LOG}"
}

ensure_session() {
  if tmux has-session -t zcode 2>/dev/null; then
    if tmux list-panes -t zcode -F '#{pane_dead}' 2>/dev/null | grep -q '^0$'; then
      echo "$(date -Is) tmux session 'zcode' already alive — no action" >> "${LOG}"
      return 0
    fi
    tmux kill-session -t zcode 2>/dev/null || true
    reap_orphans
    echo "$(date -Is) stale tmux session 'zcode' recycled (orphans reaped)" >> "${LOG}"
  else
    reap_orphans
  fi
  new_managed_session
  # Liveness re-check: if the pane died immediately (e.g. a losing single-instance
  # race), recycle exactly once.
  sleep 3
  if tmux has-session -t zcode 2>/dev/null && \
     ! tmux list-panes -t zcode -F '#{pane_dead}' 2>/dev/null | grep -q '^0$'; then
    tmux kill-session -t zcode 2>/dev/null || true
    reap_orphans
    new_managed_session
    echo "$(date -Is) pane died at birth — session re-created once" >> "${LOG}"
  fi
}

# Serialize concurrent invocations (cron @reboot + hidden Windows logon task),
# bounded: stand down if another hook is already managing the session.
if acquire_lock; then
  ensure_session
  release_lock
else
  echo "$(date -Is) another boot hook is active — standing down" >> "${LOG}"
fi
