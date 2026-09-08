#!/usr/bin/env bash
# One-time backfill: copy already-generated session titles into the FleetView
# per-process registry so sessions that were ALREADY running when you installed
# the registry-mirror change show their real name in the Desktop UI.
#
# The Stop hook (auto-name-session.sh) only mirrors a session's name into the
# registry on that session's *next* Stop. Sessions that are already open keep
# their derived slug (e.g. npeza-f4) until then. This script fixes them now by
# reading the cached titles in ~/.claude/session-names/<sessionId> and writing
# them into ~/.claude/sessions/<pid>.json using the SAME safe overwrite rule as
# the hook: only a `derived` slug (or an empty name) is replaced; a manual rename
# (nameSource absent) or a background auto name (nameSource == "auto") is left
# untouched.
#
# Idempotent. Safe to run repeatedly. Prints a before -> after report.

set -euo pipefail

python3 << 'PYEOF'
import json, os, glob, tempfile, time

home = os.path.expanduser('~')
reg_dir = os.path.join(home, '.claude', 'sessions')
sn_dir  = os.path.join(home, '.claude', 'session-names')

changed = skipped = 0
for path in sorted(glob.glob(os.path.join(reg_dir, '*.json'))):
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        continue
    sid = d.get('sessionId')
    if not sid:
        continue
    ns = d.get('nameSource'); cur = d.get('name', '')
    # Only backfill derived slugs / empty names — never a human or bg-auto name.
    if not (ns == 'derived' or not cur):
        continue
    snf = os.path.join(sn_dir, sid)
    if not os.path.exists(snf):
        continue
    try:
        title = open(snf).read().strip()
    except Exception:
        continue
    if not title or title == cur:
        continue
    d['name'] = title
    d.pop('nameSource', None)
    d['updatedAt'] = int(time.time() * 1000)
    try:
        tmp = tempfile.NamedTemporaryFile('w', dir=reg_dir, delete=False)
        json.dump(d, tmp); tmp.flush(); os.fsync(tmp.fileno()); tmp.close()
        os.replace(tmp.name, path)
    except Exception as e:
        try: os.unlink(tmp.name)
        except Exception: pass
        print(f"  ERROR {os.path.basename(path)}: {e}")
        continue
    changed += 1
    print(f"  {sid[:8]}  {cur!r:<20} ->  {title[:70]!r}")

print(f"\nBackfilled {changed} registry entr{'y' if changed==1 else 'ies'}.")
PYEOF
