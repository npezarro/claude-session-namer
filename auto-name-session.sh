#!/usr/bin/env bash
# Auto-names Claude Code sessions on every Stop event.
#
# Design (2026-09: deterministic-first-then-upgrade):
#   A deterministic first-prompt name is written FIRST, before the model call,
#   so a name exists even when this async hook is torn down together with a
#   short-lived headless `claude -p` process before the (multi-second) model
#   call can return. The model-generated name then UPGRADES it. If the model
#   call comes back empty (usage cap, stale auth, model unavailable, 30s hook
#   timeout) the deterministic name stands — previously an empty result did
#   `exit 0` and left the session permanently on its <hostname>-<slug> fallback.
#
# The generated title is cached per session_id so we only call `claude -p` once;
# subsequent Stops re-append an ai-title entry to win the last-write race against
# Claude Code's own ai-title (which would otherwise overwrite the live display).

set -euo pipefail

# Guard: don't recurse if we're already naming
[[ "${CLAUDE_AUTO_NAMING:-}" == "1" ]] && exit 0

# Read hook input from stdin
INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('session_id',''))" 2>/dev/null) || true
TRANSCRIPT=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('transcript_path',''))" 2>/dev/null) || true

[[ -z "$SESSION_ID" || -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

CACHE_DIR="$HOME/.claude/session-names"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/$SESSION_ID"

# Self-prune: drop cache entries older than 30 days. Cheap, runs every Stop.
find "$CACHE_DIR" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null || true

# Append an ai-title record (the "auto-generated summary" tier). Safe to call
# repeatedly; last write wins for the live display. No custom-title here.
append_ai_title() {
    SESSION_NAME="$1" SID="$SESSION_ID" TRANSCRIPT_PATH="$TRANSCRIPT" python3 << 'PYEOF' 2>/dev/null || true
import json, os
name = os.environ['SESSION_NAME']; sid = os.environ['SID']; path = os.environ['TRANSCRIPT_PATH']
with open(path, 'a') as f:
    f.write(json.dumps({'type': 'ai-title', 'aiTitle': name, 'sessionId': sid}) + '\n')
PYEOF
}

# Write the final name: custom-title (once — highest-priority display tier) plus
# an ai-title. custom-title is only written if none exists yet.
finalize_title() {
    SESSION_NAME="$1" SID="$SESSION_ID" TRANSCRIPT_PATH="$TRANSCRIPT" python3 << 'PYEOF' 2>/dev/null || true
import json, os
name = os.environ['SESSION_NAME']; sid = os.environ['SID']; path = os.environ['TRANSCRIPT_PATH']
has_custom = False
try:
    with open(path, 'r') as f:
        for line in f:
            if '"custom-title"' in line:
                has_custom = True
                break
except FileNotFoundError:
    pass
with open(path, 'a') as f:
    if not has_custom:
        f.write(json.dumps({'type': 'custom-title', 'customTitle': name, 'sessionId': sid}) + '\n')
    f.write(json.dumps({'type': 'ai-title', 'aiTitle': name, 'sessionId': sid}) + '\n')
PYEOF
}

# Mirror the name into the FleetView per-process registry so the Desktop UI shows
# it too. The transcript custom-title/ai-title above are read ONLY by the
# `--resume` picker (via its hKt() title resolver). The Desktop UI (FleetView)
# instead renders the `name` field of ~/.claude/sessions/<pid>.json, which for an
# interactive session is a derived slug (e.g. "npeza-f4", nameSource:"derived")
# written once at startup and never upgraded from the transcript title. That is
# why names showed in --resume but not in the Desktop UI. Here we replicate
# Claude's own in-app "Rename session" write (set `name`, drop `nameSource`);
# interactive status updates merge-preserve it, so it sticks for the process life.
#
# Overwrite rule (never clobber a human rename or a bg-job auto name):
#   - nameSource == "derived"      -> overwrite (it's the startup slug)
#   - name already == our title    -> re-assert idempotently
#   - name empty/absent            -> fill it
#   - otherwise (manual rename / nameSource == "auto") -> leave untouched
update_registry_name() {
    SESSION_NAME="$1" SID="$SESSION_ID" python3 << 'PYEOF' 2>/dev/null || true
import json, os, glob, tempfile, time
name = os.environ.get('SESSION_NAME', ''); sid = os.environ.get('SID', '')
if not name or not sid:
    raise SystemExit(0)
reg_dir = os.path.join(os.path.expanduser('~'), '.claude', 'sessions')
for path in glob.glob(os.path.join(reg_dir, '*.json')):
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        continue
    if d.get('sessionId') != sid:
        continue
    ns = d.get('nameSource'); cur = d.get('name', '')
    if not (ns == 'derived' or cur == name or not cur):
        continue
    if cur == name and ns in (None, ''):
        continue  # already correct — don't rewrite (avoids a needless race)
    d['name'] = name
    d.pop('nameSource', None)          # match Claude's rename: nameSource omitted
    d['updatedAt'] = int(time.time() * 1000)
    try:
        tmp = tempfile.NamedTemporaryFile('w', dir=reg_dir, delete=False)
        json.dump(d, tmp); tmp.flush(); os.fsync(tmp.fileno()); tmp.close()
        os.replace(tmp.name, path)     # atomic swap: shrink the clobber window
    except Exception:
        try: os.unlink(tmp.name)
        except Exception: pass
PYEOF
}

if [[ -s "$CACHE_FILE" ]]; then
    # Already named on a prior Stop — re-assert it (both display tiers) and stop.
    CACHED_NAME="$(cat "$CACHE_FILE")"
    finalize_title "$CACHED_NAME"
    update_registry_name "$CACHED_NAME"
    exit 0
fi

# Extract the first user text prompt (skip tool results)
FIRST_PROMPT=$(TRANSCRIPT_PATH="$TRANSCRIPT" python3 << 'PYEOF'
import json, sys, os

transcript = os.environ.get("TRANSCRIPT_PATH", "")
if not transcript:
    sys.exit(0)

with open(transcript, 'r') as f:
    for line in f:
        try:
            entry = json.loads(line.strip())
        except:
            continue
        if entry.get('type') != 'user':
            continue
        msg = entry.get('message', {})
        if msg.get('role') != 'user':
            continue
        content = msg.get('content', [])
        if isinstance(content, list):
            texts = [c.get('text','') for c in content if isinstance(c, dict) and c.get('type') == 'text']
            if texts:
                print(texts[0][:300])
                break
        elif isinstance(content, str):
            print(content[:300])
            break
PYEOF
) || true

[[ -z "$FIRST_PROMPT" ]] && exit 0

# Deterministic first-prompt fragment: used as the label suffix, and as the whole
# name whenever the model call is unavailable.
FRAGMENT=$(printf '%s' "$FIRST_PROMPT" | tr '\n' ' ' | sed 's/  */ /g' | head -c 60)
if [[ ${#FIRST_PROMPT} -gt 60 ]]; then
    FRAGMENT="${FRAGMENT% *}..."
fi

# STEP 1 — write the deterministic name NOW, before the slow model call, so a
# headless `-p` process that exits immediately still leaves a name behind.
append_ai_title "$FRAGMENT"

# STEP 2 — best-effort upgrade to a concise model-generated name.
GENERATED=$(CLAUDE_AUTO_NAMING=1 TRANSCRIPT_PATH="" claude -p \
    --no-session-persistence \
    --model sonnet \
    "Generate a concise 2-5 word session name for this conversation. Reply with ONLY the name, nothing else. No quotes, no punctuation. Topic: ${FIRST_PROMPT}" \
    2>/dev/null | tr -d '\n' | head -c 40) || true

if [[ -n "$GENERATED" ]]; then
    # Combine: "Generated Name — first prompt fragment..."
    NAME="${GENERATED} — ${FRAGMENT}"
else
    # Model call failed/empty — keep the deterministic name.
    NAME="$FRAGMENT"
fi

printf '%s' "$NAME" > "$CACHE_FILE"

# STEP 3 — finalize: custom-title (highest display tier) + ai-title for the
# --resume picker, plus the FleetView registry name for the Desktop UI.
finalize_title "$NAME"
update_registry_name "$NAME"

exit 0
