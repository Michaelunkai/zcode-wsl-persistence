#!/usr/bin/env python3
"""fix_windows_paths.py — translate Windows paths to Linux equivalents so sessions
created on the Windows side resume natively in WSL.

The desktop app persists workspace/output-root paths with the values it saw at
session time. On Windows those are `F:\\study\\...`; the Linux app requires
absolute POSIX paths and refuses to resume otherwise ("Gen UI output root and
workspace must be absolute"). This script rewrites every Windows drive path to
its WSL mount equivalent (`F:\\x\\y` -> `/mnt/f/x/y`, `C:\\...` -> `/mnt/c/...`)
in:

  * ~/.zcode/v2/setting.json            (lastWorkspaceSession, recentProjects,
                                         webRemoteControl contexts, ...)
  * every *.sqlite under ~/.zcode       (session workspace / output-root rows in
                                         tasks-index, cli db, ...)

SQLite work is done row-by-row in one transaction per database, only touching
values that actually contain a Windows drive pattern, and only after backing
the database up (db.pre-pathfix.bak). Databases locked by a running app are
reported and skipped — the caller runs this before launching the app.
"""
import json
import os
import re
import shutil
import sqlite3
import sys
import time

HOME = os.path.expanduser("~")
ZCODE = os.path.join(HOME, ".zcode")
WIN_DRIVE = re.compile(r"\b([A-Za-z]):\\")

def to_linux(p: str) -> str:
    def sub(m):
        return f"/mnt/{m.group(1).lower()}/"
    out = WIN_DRIVE.sub(sub, p)
    # only convert backslashes that are path separators on the converted parts
    if out != p:
        out = out.replace("\\", "/")
    return out

def fix_json_file(path: str) -> int:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return 0
    changed = 0
    def walk(o):
        nonlocal changed
        if isinstance(o, dict):
            for k, v in list(o.items()):
                if isinstance(v, str) and WIN_DRIVE.search(v):
                    o[k] = to_linux(v); changed += 1
                else:
                    walk(v)
        elif isinstance(o, list):
            for i, v in enumerate(o):
                if isinstance(v, str) and WIN_DRIVE.search(v):
                    o[i] = to_linux(v); changed += 1
                else:
                    walk(v)
    walk(data)
    if changed:
        shutil.copy2(path, path + ".pre-pathfix.bak")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.chmod(path, 0o600)
    return changed

def fix_sqlite(path: str) -> int:
    if not os.path.exists(path + ".pre-pathfix.bak"):
        shutil.copy2(path, path + ".pre-pathfix.bak")
    con = None
    try:
        con = sqlite3.connect(path, timeout=5)
        con.row_factory = sqlite3.Row
        tables = [r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")]
        changed = 0
        con.execute("BEGIN")
        for t in tables:
            try:
                cols = [r[1] for r in con.execute(f'PRAGMA table_info("{t}")')]
            except sqlite3.DatabaseError:
                continue
            for c in cols:
                try:
                    rows = con.execute(
                        f'SELECT rowid, "{c}" FROM "{t}" '
                        f'WHERE "{c}" LIKE "_:%\\%" LIMIT 5000').fetchall()
                except sqlite3.DatabaseError:
                    continue
                for rowid, val in rows:
                    if not isinstance(val, str):
                        continue
                    new = to_linux(val)
                    if new != val:
                        con.execute(f'UPDATE "{t}" SET "{c}"=? WHERE rowid=?',
                                    (new, rowid))
                        changed += 1
        if changed:
            con.commit()
            return changed
        con.rollback()
        return 0
    except sqlite3.OperationalError as e:
        print(f"    locked or unreadable ({e}) — skipped", file=sys.stderr)
        return -1
    finally:
        if con is not None:
            try:
                con.close()
            except Exception:
                pass

def main() -> int:
    total_json = 0
    total_db = 0
    failures = 0
    setting = os.path.join(ZCODE, "v2", "setting.json")
    if os.path.exists(setting):
        n = fix_json_file(setting)
        if n:
            print(f"setting.json: {n} path(s) translated")
            total_json += n
    for root, _dirs, files in os.walk(ZCODE):
        depth = root[len(ZCODE):].count(os.sep)
        if depth > 3:
            _dirs[:] = []
            continue
        for fn in files:
            if not fn.endswith(".sqlite"):
                continue
            p = os.path.join(root, fn)
            n = fix_sqlite(p)
            if n < 0:
                failures += 1
            elif n:
                print(f"{os.path.relpath(p, ZCODE)}: {n} path(s) translated")
                total_db += n
    print(f"paths translated: json={total_json} sqlite={total_db} "
          f"locked-skipped={failures}")
    return 0 if failures == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
