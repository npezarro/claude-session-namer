#!/usr/bin/env bash
# Auto-names Claude Code sessions after the first meaningful exchange.
# Runs as a Stop hook. Reads hook input from stdin, extracts session info,
# generates a short name via claude -p, and writes a custom-title entry.

set -euo pipefail

# Guard: don't recurse if we're already naming
[[ "${CLAUDE_AUTO_NAMING:-}" == "1" ]] && exit 0

# Read hook input from stdin
INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('session_id',''))" 2>/dev/null) || true
TRANSCRIPT=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('transcript_path',''))" 2>/dev/null) || true

[[ -z "$SESSION_ID" || -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# Skip if custom-title already exists
if grep -q '"custom-title"' "$TRANSCRIPT" 2>/dev/null; then
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

# Generate a short name using claude -p (non-interactive, no persistence)
NAME=$(CLAUDE_AUTO_NAMING=1 TRANSCRIPT_PATH="" claude -p \
    --no-session-persistence \
    --model sonnet \
    "Generate a concise 2-5 word session name for this conversation. Reply with ONLY the name, nothing else. No quotes, no punctuation. Topic: ${FIRST_PROMPT}" \
    2>/dev/null | tr -d '\n' | head -c 40) || true

[[ -z "$NAME" ]] && exit 0

# Combine: "Generated Name — first prompt fragment..."
FRAGMENT=$(printf '%s' "$FIRST_PROMPT" | tr '\n' ' ' | sed 's/  */ /g' | head -c 60)
# Trim trailing partial word if truncated
if [[ ${#FIRST_PROMPT} -gt 60 ]]; then
    FRAGMENT="${FRAGMENT% *}..."
fi
NAME="${NAME} — ${FRAGMENT}"

# Write the custom-title entry to the session JSONL
SESSION_NAME="$NAME" SID="$SESSION_ID" TRANSCRIPT_PATH="$TRANSCRIPT" python3 -c "
import json, os
name = os.environ['SESSION_NAME']
sid = os.environ['SID']
path = os.environ['TRANSCRIPT_PATH']
entry = {'type': 'custom-title', 'customTitle': name, 'sessionId': sid}
with open(path, 'a') as f:
    f.write(json.dumps(entry) + '\n')
" 2>/dev/null

exit 0
