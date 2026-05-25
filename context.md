# context.md

## Last Updated
2026-05-24 -- Initial release

## Current State
- Public repo, fully functional
- Single bash script (`auto-name-session.sh`) that runs as a Claude Code Stop hook
- Generates AI-powered session names using `claude -p --model sonnet`
- Format: "AI Title -- prompt fragment..."
- No dependencies beyond Python 3, Bash, and Claude Code CLI

## Open Work
- Name quality could be improved with few-shot examples in the prompt
- Could add a batch-naming script for retroactively naming historical sessions
- Local copy at `~/.claude/hooks/auto-name-session.sh` and repo copy are independent; consider symlinking

## Environment Notes
- **Deploy target:** Local only (Claude Code hook)
- **Node version:** N/A (bash + python3)
