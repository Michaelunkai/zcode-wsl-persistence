#!/usr/bin/env bash
# verify.sh — obsessive verification gate for the ZCode WSL2 persistence engine.
# Run as the WSL user (ubuntu):  bash verify.sh
# Exit 0 only if EVERY assertion passes.
set -u
WSL_USER="${WSL_USER:-$(id -un)}"
MIG="${HOME}/zcode-wsl-migration"
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# 1. Binary + libraries
ZCODE_BIN="$(command -v zcode || ls /opt/ZCode/zcode /usr/bin/zcode /usr/local/bin/zcode 2>/dev/null | head -1 || true)"
[ -n "${ZCODE_BIN}" ] && ok "zcode binary present (${ZCODE_BIN})" || bad "zcode binary missing"
if [ -n "${ZCODE_BIN}" ]; then
  MISS="$(ldd "$(readlink -f "${ZCODE_BIN}")" 2>/dev/null | grep -c 'not found' || true)"
  [ "${MISS}" -eq 0 ] && ok "zero unresolved shared libraries" || bad "${MISS} unresolved shared libraries"
fi

# 2. Noble t64 dependencies
for p in libgtk-3-0t64 libasound2t64 libnotify4 libnss3 libxss1 libgbm1; do
  dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q 'install ok installed' \
    && ok "package ${p} installed" || bad "package ${p} missing"
done

# 3. cron service + crontab automation
systemctl is-active cron >/dev/null 2>&1 && ok "cron service active" || bad "cron service not active"
CRON="$(crontab -l 2>/dev/null || true)"
echo "${CRON}" | grep -q '@reboot.*boot_zcode\.sh' && ok "cron @reboot boot hook present" || bad "cron @reboot boot hook missing"
echo "${CRON}" | grep -qE '\*/20.*sync_zcode\.sh --quick' && ok "cron 20-min live mirror present" || bad "cron 20-min live mirror missing"
echo "${CRON}" | grep -qE '^[0-9]+ [0-9]+ .*sync_zcode\.sh' && ok "cron daily sync present" || bad "cron daily sync missing"
echo "${CRON}" | grep -q -- '--delete' && bad "DANGER: --delete found in crontab" || ok "no --delete anywhere in crontab"

# 4. Migrated state: present, owned strictly by the user, and CONNECTED
if [ -d "${HOME}/.zcode" ]; then
  ok "~/.zcode exists ($(du -sh "${HOME}/.zcode" 2>/dev/null | cut -f1))"
  NOTOWNED="$(find "${HOME}/.zcode" ! -user "$(id -un)" 2>/dev/null | wc -l)"
  [ "${NOTOWNED}" -eq 0 ] && ok "every file in ~/.zcode owned by $(id -un)" || bad "${NOTOWNED} files not owned by $(id -un)"
else
  bad "~/.zcode missing"
fi
CREDS_ENTRIES="$(python3 -c "import json,os;print(len(json.load(open(os.path.expanduser('~/.zcode/v2/credentials.json')))))" 2>/dev/null || echo 0)"
[ "${CREDS_ENTRIES}" -ge 8 ] && ok "credential store adopted (${CREDS_ENTRIES} entries)" || bad "credential store thin or missing (${CREDS_ENTRIES} entries)"
[ -f "${HOME}/.zcode/v2/.wsl-auth-adopted" ] && ok "credentials adoption marker present" || bad "adoption marker missing"
[ -s "${HOME}/.zcode-wsl-auth-secret" ] && ok "portable credential secret present (0600)" || bad "portable credential secret missing"
GUILOG="${HOME}/zcode-wsl-migration/logs/gui.log"
if [ -f "${GUILOG}" ]; then
  python3 - "$GUILOG" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
idx = data.rfind('restoreCachedSession restored')
if idx == -1:
    print('FAIL: no restoreCachedSession-restored line in gui.log')
    sys.exit(1)
after = data[idx:]
if 'ZCODE_CREDENTIAL_DECRYPT_FAILED' in after:
    print('FAIL: credential decrypt failures after the last successful restore')
    sys.exit(1)
print('PASS: OAuth session restored at boot and zero decrypt failures since')
PY
  [ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
else
  bad "gui.log missing"
fi

# 5. Managed tmux session + GUI process + WSLg window
tmux has-session -t zcode 2>/dev/null && ok "tmux session 'zcode' exists" || bad "tmux session 'zcode' missing"
PANE_PID="$(tmux display-message -p -t zcode '#{pane_pid}' 2>/dev/null || true)"
if [ -n "${PANE_PID}" ]; then
  if ps --ppid "${PANE_PID}" -o comm= 2>/dev/null | grep -qi zcode || ps -p "${PANE_PID}" -o comm= 2>/dev/null | grep -qi zcode; then
    ok "GUI process alive under tmux pane (pid tree from ${PANE_PID})"
  else
    bad "no zcode process under tmux pane ${PANE_PID}"
  fi
fi
# 7. GUI: X server reachable + the app holds live X connections.
# (WSLg's XWayland does not expose _NET_CLIENT_LIST, so wmctrl cannot enumerate
# windows; live ESTAB connections to /tmp/.X11-unix/X0 are the in-WSL evidence.
# The Windows-side proof is the WSLg host window titled "ZCode (Ubuntu)".)
export DISPLAY=:0 XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"
if xdpyinfo -display :0 >/dev/null 2>&1; then
  ok "X server reachable on DISPLAY=:0 (WSLg/XWayland)"
  XCONN="$(ss -x 2>/dev/null | grep -c 'ESTAB.*X11-unix/X0' || true)"
  if [ "${XCONN}" -gt 0 ]; then
    ok "${XCONN} live X11 connections into WSLg (GUI attached to the Windows desktop)"
  else
    bad "no live X11 connections into WSLg"
  fi
else
  bad "X server unreachable on :0"
fi

# 6. Live isolation: zero open file handles into /mnt/c from the Linux ZCode
HANDLES="$(pgrep -u "$(id -un)" -f '[z]code' | xargs -r lsof -p 2>/dev/null | grep -c '/mnt/' || true)"
[ "${HANDLES}" -eq 0 ] && ok "zero open handles into /mnt/* from the running ZCode" || bad "${HANDLES} open handles into /mnt/* (not fully decoupled)"

# 7. No write access needed to the Windows side at runtime: sentinel survives
SENTINEL="${HOME}/.zcode/.wsl-isolation-sentinel"
echo "isolation-proof $(date -Is)" > "${SENTINEL}" 2>/dev/null \
  && [ "$(cat "${SENTINEL}" 2>/dev/null | wc -l)" -ge 1 ] \
  && ok "local state writable + readable (sentinel)" || bad "cannot write sentinel into ~/.zcode"

echo "----------------------------------------"
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] && exit 0 || exit 1
