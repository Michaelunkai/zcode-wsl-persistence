#!/usr/bin/env bash
# persistence-drill.sh — end-to-end reboot simulation WITHOUT rebooting Windows.
# 1. terminates the Ubuntu WSL distro (kills tmux, GUI, everything inside)
# 2. fires the EXACT hidden boot path Windows uses at logon (wscript -> VBS, zero popups)
# 3. proves the managed tmux session + ZCode GUI return on their own.
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

echo "== 1. terminate Ubuntu distro (simulated reboot) =="
wsl.exe -t Ubuntu
sleep 3
wsl.exe -l -v 2>&1 | tr -d '\0'

echo "== 2. fire the exact silent logon path (hidden VBS via wscript) =="
/c/Windows/System32/wscript.exe 'C:\Users\Admin\AppData\Local\ZCodeWslBoot\zcode-wsl-silent-boot.vbs'

echo "== 3. watch the persistence engine bring everything back =="
PROCS=0
for i in $(seq 1 24); do
  sleep 5
  RUNNING=$(wsl.exe -l --running 2>/dev/null | tr -d '\0' | grep -c Ubuntu || true)
  SESS=$(wsl.exe -d Ubuntu -u ubuntu -- bash -c 'tmux has-session -t zcode 2>/dev/null && echo yes || echo no' 2>/dev/null | tr -d '\0')
  PROCS=$(wsl.exe -d Ubuntu -u ubuntu -- bash -c 'pgrep -c -u ubuntu -f /opt/ZCode/zcode' 2>/dev/null | tr -d '\0')
  echo "t=$((i*5))s running=${RUNNING} session=${SESS} procs=${PROCS}"
  [ "${PROCS:-0}" -ge 3 ] && break
done

echo "== final evidence =="
wsl.exe -d Ubuntu -u ubuntu -- bash -c 'tmux ls; echo "X-connections: $(ss -x 2>/dev/null | grep -c ESTAB.*X0)"; tail -4 ~/zcode-wsl-migration/logs/boot.log' 2>&1 | tr -d '\0'
/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "Get-Process msrdc -ErrorAction SilentlyContinue | Where-Object { \$_.MainWindowTitle } | Select-Object ProcessName,MainWindowTitle | Format-Table -AutoSize | Out-String -Width 120"
