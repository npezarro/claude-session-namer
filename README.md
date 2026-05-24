# Claude Session Namer

Automatically generates descriptive names for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions, replacing cryptic session IDs in the `--resume` picker with human-readable titles.

## Before vs After

**Before:**
```
  35fe3102  /mnt/c/Users/npeza  2 hours ago
  50615df7  /mnt/c/Users/npeza  3 hours ago
  80360201  /mnt/c/Users/npeza  5 hours ago
```

**After:**
```
  Auto Session Naming Tool — I want to create a tool that auto determines...
  Usage Gate Debugging — Another 5% of 7d capacity got used overnight...
  Foodie Discord App Creation — Lets do the same as Shopper and Travel...
```

## How It Works

A Claude Code [Stop hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that fires after the first assistant response in each session:

1. Reads the session ID and transcript path from hook input
2. Checks if the session already has a name (skips if so)
3. Extracts the first user prompt from the session transcript
4. Calls `claude -p --model sonnet` to generate a concise 2-5 word title
5. Appends a fragment of the original prompt for context
6. Writes the name to the session transcript as a `custom-title` entry

The hook runs **asynchronously** so it never blocks your session.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Python 3 (used for JSON parsing)
- Bash

## Installation

### 1. Clone or download the script

```bash
git clone https://github.com/npezarro/claude-session-namer.git
chmod +x claude-session-namer/auto-name-session.sh
```

Or just download the script directly:

```bash
mkdir -p ~/.claude/hooks
curl -o ~/.claude/hooks/auto-name-session.sh \
  https://raw.githubusercontent.com/npezarro/claude-session-namer/main/auto-name-session.sh
chmod +x ~/.claude/hooks/auto-name-session.sh
```

### 2. Add the Stop hook to your Claude Code settings

Add to `~/.claude/settings.json` (create the file if it doesn't exist):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'printf \"%s\" \"$(cat)\" | bash ~/.claude/hooks/auto-name-session.sh; exit 0'",
            "timeout": 30,
            "async": true
          }
        ]
      }
    ]
  }
}
```

If you already have Stop hooks, add the new hook entry to your existing hooks array.

### 3. Start a new session

The next time you start a Claude Code session and send your first message, the hook will automatically generate a name. You'll see it the next time you run:

```bash
claude --resume
```

## Configuration

### Changing the naming model

By default, the hook uses `sonnet` for name generation. You can change this by editing the `--model` flag in `auto-name-session.sh`:

```bash
--model haiku    # faster, cheaper
--model opus     # more creative names
```

### Disabling the prompt fragment

If you only want the AI-generated title without the prompt fragment, remove or comment out the fragment section (lines 67-72) in the script.

### Title-only mode (no AI call)

If you want to skip the AI call entirely and just use the first ~60 characters of your prompt as the session name, replace the naming section with:

```bash
NAME=$(printf '%s' "$FIRST_PROMPT" | tr '\n' ' ' | sed 's/  */ /g' | head -c 60)
if [[ ${#FIRST_PROMPT} -gt 60 ]]; then
    NAME="${NAME% *}..."
fi
```

## How It Avoids Recursion

The `claude -p` call used for name generation would itself trigger Stop hooks, creating infinite recursion. This is prevented by:

1. **Environment variable guard:** The naming call sets `CLAUDE_AUTO_NAMING=1`, and the script exits immediately when this variable is present
2. **One-shot guard:** The script checks for an existing `custom-title` entry in the transcript and skips if one exists
3. **`--no-session-persistence`:** The naming call doesn't create a persistent session, so it won't appear in the resume picker

## License

MIT
