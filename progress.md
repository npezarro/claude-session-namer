# progress.md

## 2026-09-08 (FleetView registry mirror)
- Diagnosed why named sessions showed in `--resume` but not the Desktop UI:
  the picker reads transcript `custom-title`/`ai-title`; FleetView reads the
  `name` field of `~/.claude/sessions/<pid>.json`, which stays a derived slug
  (`npeza-XX`, `nameSource:"derived"`) for interactive sessions.
- Added `update_registry_name()` to the hook — mirrors the title into the live
  pid registry (set `name`, drop `nameSource`), matching Claude's own rename.
  Safe overwrite rule verified with a 6-case unit test.
- Added `backfill-registry-names.sh` to retro-fix already-open sessions from the
  `~/.claude/session-names/` cache.

## 2026-05-31
- `09b881a` Persist title across turns by writing ai-title every Stop
  - Diagnosed: Claude Code appends its own `ai-title` per Stop, overwriting the live header
  - Removed one-shot `custom-title` guard
  - Added sidecar cache at `~/.claude/session-names/<sid>` so `claude -p` runs once
  - Appends `ai-title` every Stop; still writes `custom-title` once for resume picker
- Cache self-prune: `find ~/.claude/session-names -mtime +30 -delete` runs inline every Stop, closes the unbounded-growth open item

## 2026-05-24
- `6f8916c` Initial commit: auto-name-session.sh, README.md, LICENSE
- Published as public repo at https://github.com/npezarro/claude-session-namer
