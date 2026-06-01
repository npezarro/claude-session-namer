# context.md

## Last Updated
2026-05-31 -- Persist title across turns (ai-title every Stop)

## Current State
- Public repo, fully functional
- Single bash script (`auto-name-session.sh`) that runs as a Claude Code Stop hook
- Generates AI-powered session names using `claude -p --model sonnet`
- Format: "AI Title — prompt fragment..."
- Caches generated name at `~/.claude/session-names/<session_id>` so `claude -p` runs once per session
- Appends `{type:"ai-title", ...}` on EVERY Stop (beats Claude Code's own ai-title for the live header) and `{type:"custom-title", ...}` once (resume picker fallback)
- No dependencies beyond Python 3, Bash, and Claude Code CLI

## Why ai-title (not custom-title) for the live header
Claude Code writes its own `{type:"ai-title"}` entry on every Stop and the in-session title reads the latest one. A one-shot `custom-title` write only survives turn 1. Hook now wins the last-write race.

## Open Work
- Name quality could be improved with few-shot examples in the prompt
- Could add a batch-naming script for retroactively naming historical sessions
- Local copy at `~/.claude/hooks/auto-name-session.sh` and repo copy are independent; consider symlinking
- ~~Live multi-turn verification pending~~ confirmed working 2026-05-31

Cache self-prunes entries older than 30 days on every Stop (`find ... -mtime +30 -delete`).

Full closeout: privateContext/deliverables/closeouts/2026-05-31-session-namer-persist-title.md

## Environment Notes
- **Deploy target:** Local only (Claude Code hook)
- **Node version:** N/A (bash + python3)
