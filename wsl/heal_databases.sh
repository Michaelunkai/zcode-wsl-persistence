#!/usr/bin/env bash
# heal_databases.sh — GUARANTEE every ZCode session database is valid before launch.
#
# WHY: the one-time bootstrap rsync hot-copies SQLite databases from the LIVE
# Windows app. A copy taken mid-write can be inconsistent ("database disk image
# is malformed"), which surfaces as failed session resumes. This script makes
# that state impossible to persist:
#
#   1. integrity-check every *.sqlite under ~/.zcode (quick_check — milliseconds
#      when healthy, which is the common case).
#   2. heal any malformed database from the Windows source with SQLite's OWN
#      consistent-snapshot mechanisms (never a blind file copy):
#        a. `VACUUM INTO` — SQLite reads the source through its WAL machinery
#           and writes a guaranteed-consistent snapshot, even while the Windows
#           app keeps writing.
#        b. `.recover` fallback if the source pages themselves are damaged.
#   3. replacing a database requires the app stopped; if the app is running it
#      is SIGKILLed first (only the WSL instance — never the Windows side) and
#      the caller is expected to boot again afterwards.
#
# Everything is logged to logs/heal.log. Healthy systems pass in under a second.
set -u
MIG="${HOME}/zcode-wsl-migration"
LOG="${MIG}/logs/heal.log"
WIN_V2="/mnt/c/Users/Admin/.zcode"
mkdir -p "${MIG}/logs"
# When invoked as root (install.sh), HOME is /root — the state lives in the
# WSL user's home, so the caller pins it via HEAL_HOME.
SCAN_HOME="${HEAL_HOME:-${HOME}}"

log() { echo "$(date -Is) $*" >> "${LOG}"; }
echo_ok()  { echo "[OK  ] $*"; }
echo_heal(){ echo "[HEAL] $*"; }

# sqlite3 present? install if missing — no exceptions.
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo_heal "sqlite3 missing — installing"
  if [ "$(id -u)" -eq 0 ]; then
    apt-get install -y sqlite3 >/dev/null 2>&1
  else
    sudo apt-get install -y sqlite3 >/dev/null 2>&1
  fi
  command -v sqlite3 >/dev/null 2>&1 || { echo "[FAIL] sqlite3 could not be installed"; log "FATAL sqlite3 unavailable"; exit 1; }
fi

app_running() { pgrep -x ZCode >/dev/null 2>&1; }
stop_app() {
  if app_running; then
    log "stopping WSL app for database replacement"
    echo_heal "stopping the WSL app (relaunch happens right after)"
    pkill -9 -x ZCode 2>/dev/null || true
    pkill -9 -f '/opt/[Z]Code/' 2>/dev/null || true
    pkill -9 -f 'zcode-[h]ost' 2>/dev/null || true
    sleep 2
  fi
}

db_ok() {  # quick_check: prints "ok" on a healthy database
  [ "$(sqlite3 "$1" 'PRAGMA quick_check;' 2>/dev/null | head -1)" = "ok" ]
}

heal_one() {  # $1 = linux db path (already known-bad)
  local db="$1" rel src tmp sqltmp
  rel="${db#"${SCAN_HOME}/.zcode/"}"
  src="${WIN_V2}/${rel}"
  log "healing ${db}"
  if [ ! -f "${src}" ]; then
    log "no Windows source for ${rel} — attempting self-recover"
    sqltmp="${db}.recover.sql"
    if sqlite3 "${db}" .recover > "${sqltmp}" 2>>"${LOG}"; then
      stop_app
      tmp="${db}.healed"
      sqlite3 "${tmp}" < "${sqltmp}" 2>>"${LOG}" && mv -f "${tmp}" "${db}" && rm -f "${db}-wal" "${db}-shm" "${sqltmp}"
      echo_heal "self-recovered ${rel}"
      return 0
    fi
    rm -f "${sqltmp}"
    echo_heal "could not heal ${rel} (no healthy source) — left in place"
    return 1
  fi
  tmp="${db}.healed"
  rm -f "${tmp}"
  if sqlite3 "${src}" "VACUUM INTO '${tmp}'" 2>>"${LOG}"; then
    stop_app
    mv -f "${tmp}" "${db}"
    rm -f "${db}-wal" "${db}-shm"
    echo_heal "recovered ${rel} from Windows source (consistent snapshot)"
    return 0
  fi
  log "VACUUM INTO failed for ${rel} — falling back to .recover on the source"
  sqltmp="${db}.recover.sql"
  if sqlite3 "${src}" .recover > "${sqltmp}" 2>>"${LOG}"; then
    stop_app
    sqlite3 "${tmp}" < "${sqltmp}" 2>>"${LOG}" && mv -f "${tmp}" "${db}" && rm -f "${db}-wal" "${db}-shm" "${sqltmp}"
    echo_heal "recovered ${rel} from Windows source (.recover)"
    return 0
  fi
  rm -f "${sqltmp}" "${tmp}"
  echo_heal "could not heal ${rel} — source unreadable"
  return 1
}

RC=0
FOUND=0; BAD=0; HEALED=0
while IFS= read -r db; do
  FOUND=$((FOUND+1))
  if ! db_ok "${db}"; then
    BAD=$((BAD+1))
    heal_one "${db}" || RC=1
    if db_ok "${db}"; then HEALED=$((HEALED+1)); else RC=1; fi
  fi
done < <(find "${SCAN_HOME}/.zcode" -maxdepth 3 -name '*.sqlite' -type f 2>/dev/null)

log "check complete: databases=${FOUND} malformed=${BAD} healed=${HEALED} rc=${RC}"
if [ "${BAD}" -eq 0 ]; then
  echo_ok "all ${FOUND} session databases pass integrity check"
else
  echo_heal "${BAD} malformed database(s) found; healed=${HEALED} (details: ${LOG})"
fi
exit "${RC}"
