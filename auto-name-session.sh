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

if [[ -s "$CACHE_FILE" ]]; then
    # Already named on a prior Stop — re-assert it and stop.
    finalize_title "$(cat "$CACHE_FILE")"
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

# STEP 3 — finalize: custom-title (highest display tier) + ai-title.
finalize_title "$NAME"

exit 0
