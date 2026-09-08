# context.md

## Last Updated
2026-09-08 -- FleetView registry mirror (names now show in the Desktop UI, not just --resume)

## FleetView / Desktop UI fix (2026-09-08): mirror the name into the pid registry
**Symptom:** every session was named in the `--resume` picker but the Desktop UI
(FleetView) still showed the derived slug `npeza-XX` for all of them — except the
one session that had been renamed by hand.

**Root cause:** the two surfaces read *different* name stores.
- `--resume` builds its title from the transcript's typed `custom-title` /
  `ai-title` entries (the CLI's `hKt()` resolver: `agentName || customTitle ||
  aiTitle || summary || firstPrompt || sessionId[:8]`). Steps 4-6 feed this.
- FleetView renders the `name` field of the per-process registry file
  `~/.claude/sessions/<pid>.json`. For an interactive session that field is set
  ONCE at startup to a derived slug (`name: "npeza-f4", nameSource: "derived"`)
  and is never upgraded from the transcript title. The only built-in path that
  changes it is the in-app "Rename session" action, which sets `name` and drops
  `nameSource` (that is why the one hand-renamed session showed correctly).

Confirmed by disassembling the 2.1.220 binary: the registry writer
(`iHt`/`x_e`), the derived-slug default, and `hKt()` for the picker are all
present and independent; nothing copies `customTitle`/`aiTitle` into the registry
`name`.

**Fix:** `update_registry_name()` replicates the in-app rename — for the live pid
file(s) whose `sessionId` matches, set `name` to our title and drop `nameSource`.
Interactive status updates merge-preserve the field (`iHt` does read-modify-write
and status writes only pass status keys), so it persists for the process life.
Overwrite rule: replace a `derived` slug, re-assert our own title, or fill an
empty name; never touch a manual rename (`nameSource` absent) or a bg-job auto
name (`nameSource: "auto"`). Called from both the re-assert branch and the
finalize step. Atomic `os.replace` shrinks the clobber window vs Claude's own
writer; a rare lost write self-heals on the next Stop.

`backfill-registry-names.sh` retro-fixes sessions that were already running at
install time by copying `~/.claude/session-names/<sid>` titles into the registry.

## Prior update
2026-09-08 -- Deterministic-first-then-upgrade (close the coverage gap)

## Current State
- Public repo, fully functional
- Single bash script (`auto-name-session.sh`) that runs as a Claude Code Stop hook
- Generates AI-powered session names using `claude -p --model sonnet`
- Format: "AI Title — prompt fragment..." (or just the fragment when the model call is unavailable)
- Caches generated name at `~/.claude/session-names/<session_id>` so `claude -p` runs once per session
- Appends `{type:"ai-title", ...}` on EVERY Stop (beats Claude Code's own ai-title for the live header) and `{type:"custom-title", ...}` once (resume picker fallback / Remote Control's highest-priority display tier)
- No dependencies beyond Python 3, Bash, and Claude Code CLI

## Coverage fix (2026-09-08): deterministic-first-then-upgrade
The original design called the model FIRST and only wrote a title on success. Two
gaps left sessions stuck on their `<hostname>-<random-slug>` fallback in the
`--resume` picker and the Remote Control UI:
1. **Model call empty** (usage cap, stale auth, model unavailable, 30s hook
   timeout) → old code did `exit 0`, writing no title at all. A one-shot `-p`
   job gets exactly one Stop, so it stayed unnamed forever.
2. **Async hook torn down with a short-lived `claude -p` process** before the
   multi-second model call returned. Interactive sessions stay alive long enough;
   headless `-p` jobs (the Discord bridge dispatches these) exit immediately, so
   the naming call was killed mid-flight. Measured: in one project 142/152
   headless sessions had NO title record; only 10 (interactive) did.

Fix: write a deterministic first-prompt name (`append_ai_title`) BEFORE the model
call, then UPGRADE it via `finalize_title` (custom-title + ai-title) once the
model name arrives. If the process dies in between, the deterministic ai-title
already persisted. If the model call is empty, the deterministic name stands.
Verified in a sandbox across: model-succeeds, model-empty, and SIGKILL-after-early-write.

Residual gap (not fixable by a Stop hook alone): a session killed BEFORE it ever
emits a Stop with a first user prompt. For any automated dispatcher that shells
out to `claude -p`, the cleaner path is to name at dispatch time with the
`-n "<title>"` flag, because a wrapped headless prompt often leads with a fixed
preamble rather than the actual request — so both the fragment and the model
"Topic:" are low-quality for those jobs.

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
