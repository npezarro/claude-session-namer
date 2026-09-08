#!/usr/bin/env python3
"""Rename a Claude Code session's DESKTOP (Remote Control) name via the bridge API.

The `--resume` picker reads transcript custom-title/ai-title; the Claude desktop
(Remote Control) UI instead shows the name each `claude` process advertises over
its bridge. That advertised name is set once at launch (a derived slug like
`npeza-f4`) and changes ONLY via a `rename_session` control request delivered over
the bridge. This posts exactly that control request to the session's event stream:

    POST https://api.anthropic.com/v1/code/sessions/<cse_id>/events
    Authorization: Bearer <claudeAiOauth.accessToken>
    { "session_id": "<cse_id>",
      "events": [ { "payload": {
          "type":"control_request", "request_id":"<uuid>",
          "request": { "subtype":"rename_session", "title":"<title>" } } } ] }

The worker (the live session) receives it over its SSE stream, runs
onRenameSession, and re-advertises — so the desktop updates. The local
`bridgeSessionId` (`session_XXX`) maps to the API's `cse_XXX` by prefix swap.

Reverse-engineered from claude 2.1.220 (SessionsV2Client). May break on updates.

Usage:
  bridge-rename.py --session <uuid> [--title <title>]   # one session (title from cache if omitted)
  bridge-rename.py --all                                # every live bridged interactive session, from cache

Always exits 0 (never break the calling Stop hook). Prints one status line per session.
"""
import argparse, glob, json, os, sys, time, uuid, urllib.request, urllib.error

HOME = os.path.expanduser("~")
SESS_DIR = os.path.join(HOME, ".claude", "sessions")
NAME_DIR = os.path.join(HOME, ".claude", "session-names")
CREDS = os.path.join(HOME, ".claude", ".credentials.json")
API = "https://api.anthropic.com/v1/code/sessions/{cse}/events"
# Don't POST to sessions whose registry file is stale (process likely dead / archived).
FRESH_SECS = 6 * 3600


def load_token():
    try:
        with open(CREDS) as f:
            o = json.load(f).get("claudeAiOauth", {})
    except Exception as e:
        return None, "no-credentials(%s)" % e
    tok = o.get("accessToken")
    if not tok:
        return None, "no-accessToken"
    exp = o.get("expiresAt")
    if isinstance(exp, (int, float)) and exp / 1000.0 < time.time():
        return None, "token-expired"
    return tok, None


def registry_rows():
    rows = []
    for p in glob.glob(os.path.join(SESS_DIR, "*.json")):
        try:
            with open(p) as f:
                d = json.load(f)
        except Exception:
            continue
        d["_mtime"] = os.path.getmtime(p)
        rows.append(d)
    return rows


def cse_from_bridge(bsid):
    if not bsid or not bsid.startswith("session_"):
        return None
    return "cse_" + bsid[len("session_"):]


def cached_title(uid):
    p = os.path.join(NAME_DIR, uid)
    try:
        with open(p) as f:
            return f.read().strip()
    except Exception:
        return None


def post_rename(tok, cse, title):
    body = json.dumps({
        "session_id": cse,
        "events": [{"payload": {
            "type": "control_request",
            "request_id": str(uuid.uuid4()),
            "request": {"subtype": "rename_session", "title": title},
        }}],
    }).encode()
    req = urllib.request.Request(
        API.format(cse=cse), data=body, method="POST",
        headers={
            "Authorization": "Bearer " + tok,
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, None
    except urllib.error.HTTPError as e:
        return e.code, (e.read(200).decode("utf-8", "replace") if e.fp else "")
    except Exception as e:
        return None, str(e)


def rename_one(tok, row, title):
    uid = row.get("sessionId", "")
    cse = cse_from_bridge(row.get("bridgeSessionId"))
    if not cse:
        print("  skip %s: no bridgeSessionId" % uid[:8]); return
    if not title:
        title = cached_title(uid)
    if not title:
        print("  skip %s: no title" % uid[:8]); return
    status, err = post_rename(tok, cse, title)
    if status == 200:
        print("  ok   %s -> %r" % (uid[:8], title[:60]))
    elif status == 401:
        print("  skip %s: 401 (token rejected)" % uid[:8])
    else:
        print("  fail %s: status=%s %s" % (uid[:8], status, (err or "")[:120]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session")
    ap.add_argument("--title")
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()

    tok, err = load_token()
    if not tok:
        print("bridge-rename: %s (skipping)" % err); return 0

    rows = registry_rows()
    if a.session:
        match = [r for r in rows if r.get("sessionId") == a.session]
        if not match:
            print("  skip %s: not in registry" % a.session[:8]); return 0
        rename_one(tok, match[0], a.title)
    elif a.all:
        now = time.time()
        targets = [r for r in rows
                   if r.get("kind") == "interactive"
                   and r.get("bridgeSessionId")
                   and now - r.get("_mtime", 0) < FRESH_SECS]
        if not targets:
            print("bridge-rename --all: no fresh bridged interactive sessions"); return 0
        for r in targets:
            rename_one(tok, r, None)
    else:
        print("nothing to do (use --session or --all)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
