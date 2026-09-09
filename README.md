# Claude Session Namer

> **RETIRED 2026-09-09 — superseded by Claude Code's native session titling.**
> Claude Code **2.1.266** natively generates clean, conversation-aware session
> titles (`generateSessionTitle`) and writes them to the `--resume` picker, the
> local session view, and the desktop / `claude.ai/code` UI. That is strictly
> better than this tool's first-prompt titles, and this tool's `custom-title`
> override actually *degraded* the `--resume` picker by hiding the native title.
> The Stop hook has been removed from `~/.claude/settings.json`; the code is kept
> here only as a record of the investigation (see `notes/bridge-recon.md` and
> `context.md`). Do not re-enable it on 2.1.266+.

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
4. **Writes a deterministic first-prompt name immediately** (before the slow model call)
5. Calls `claude -p --model sonnet` to generate a concise 2-5 word title
6. **Upgrades** the name to `"AI Title — prompt fragment..."` as a `custom-title` entry
7. **Pushes the name to the desktop UI over the bridge** so Remote Control shows it too

The hook runs **asynchronously** so it never blocks your session.

### Two display surfaces read two different name stores

Claude Code shows session names in two places, and they read *different* sources:

- **The `--resume` picker** builds its title from typed transcript entries
  (`custom-title` / `ai-title`) via the CLI's internal title resolver. Steps 4-6
  feed this surface.
- **The desktop UI (Remote Control)** shows the name each `claude` process
  advertises over its **bridge** (the `claude.ai/code` connection). That name is
  held in memory, set once at launch to a derived slug (e.g. `npeza-f4`, prefix
  from `--remote-control-session-name-prefix`, default hostname), and **never**
  upgraded from the transcript title. Editing local files (`~/.claude/sessions/…`)
  does not reach it — the process advertises from memory, not from disk.

So a session is nicely named in `--resume` yet still shows `npeza-f4` in the
desktop. Step 7 fixes that with **`bridge-rename.py`**, which posts the same
`rename_session` control request the desktop's own "Rename" uses, to the session's
event stream:

```
POST https://api.anthropic.com/v1/code/sessions/<cse_id>/events
Authorization: Bearer <claudeAiOauth.accessToken>
{ "session_id":"<cse_id>", "events":[{ "payload":{
    "type":"control_request", "request_id":"<uuid>",
    "request":{ "subtype":"rename_session", "title":"<title>" } } }] }
```

The live session receives it over its SSE stream, renames itself, and
re-advertises — so the desktop updates. The local `bridgeSessionId` (`session_XXX`)
maps to the API's `cse_XXX` by prefix swap. The call is best-effort: a missing or
expired token, or being offline, is a quiet no-op that never blocks the hook.

> Reverse-engineered from the `SessionsV2Client` in claude 2.1.220; it uses the
> undocumented `/v1/code/sessions/…` API and may break on Claude Code updates.
> See `notes/bridge-recon.md` for the full protocol map.

To retro-name sessions already running when you install this, run
`./bridge-rename.py --all` once — it renames every live bridged interactive
session from the titles cached in `~/.claude/session-names/`.

### Why write the deterministic name first?

The model call takes a few seconds. Two things used to leave sessions unnamed:

- **The model call comes back empty** (usage cap, stale auth, model unavailable, or the 30s hook timeout). The old code exited without writing anything, and a one-shot `claude -p` job gets only one Stop — so it stayed on its `hostname-random-slug` fallback forever.
- **A short-lived `claude -p` process exits before the model call returns**, tearing the async hook down with it. Interactive sessions stay alive long enough; headless jobs do not.

Writing the deterministic first-prompt name *before* the model call guarantees a name exists in both cases; the model-generated name then upgrades it when it arrives.

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
