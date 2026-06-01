#!/usr/bin/env bash
# Auto-names Claude Code sessions on every Stop event.
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

if [[ -s "$CACHE_FILE" ]]; then
    NAME=$(cat "$CACHE_FILE")
else
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

    # Generate a short name using claude -p (non-interactive, no persistence)
    GENERATED=$(CLAUDE_AUTO_NAMING=1 TRANSCRIPT_PATH="" claude -p \
        --no-session-persistence \
        --model sonnet \
        "Generate a concise 2-5 word session name for this conversation. Reply with ONLY the name, nothing else. No quotes, no punctuation. Topic: ${FIRST_PROMPT}" \
        2>/dev/null | tr -d '\n' | head -c 40) || true

    [[ -z "$GENERATED" ]] && exit 0

    # Combine: "Generated Name — first prompt fragment..."
    FRAGMENT=$(printf '%s' "$FIRST_PROMPT" | tr '\n' ' ' | sed 's/  */ /g' | head -c 60)
    if [[ ${#FIRST_PROMPT} -gt 60 ]]; then
        FRAGMENT="${FRAGMENT% *}..."
    fi
    NAME="${GENERATED} — ${FRAGMENT}"

    printf '%s' "$NAME" > "$CACHE_FILE"
fi

# Append ai-title every Stop so we beat Claude Code's own ai-title write
# for the live in-session header. Also write custom-title once for the
# resume picker fallback.
SESSION_NAME="$NAME" SID="$SESSION_ID" TRANSCRIPT_PATH="$TRANSCRIPT" python3 << 'PYEOF' 2>/dev/null
import json, os
name = os.environ['SESSION_NAME']
sid = os.environ['SID']
path = os.environ['TRANSCRIPT_PATH']

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

exit 0
