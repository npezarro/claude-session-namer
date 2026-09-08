# Claude Code bridge / Remote-Control naming — recon (CC 2.1.220)

## Why the desktop showed slugs
Two independent name pipelines:
1. `--resume` picker + local file views: parse transcript JSONL (`FVs`/`NVs`) for
   `custom-title`/`ai-title`, resolve via `hKt()`. The session-namer feeds this.
2. Desktop = **Remote Control**: each `claude` process advertises its own `name`
   **in memory** over the **bridge** (websocket). Set once at launch to the
   derived slug (prefix from `--remote-control-session-name-prefix`, default
   hostname → `npeza-`). Changed ONLY by a `rename_session` control request
   handled by the CLI's `onRenameSession` callback (what the app's Rename uses).
Editing `~/.claude/sessions/<pid>.json` on disk does NOT reach the desktop — the
process advertises from memory, not by re-reading the file. Confirmed: a live
process preserved an external file edit but never advertised it.

## rename_session control request (SDK/bridge)
Schema: `{ "subtype":"rename_session", "title": <string> }` — "Sets the
user-facing title for the current session." Wrapped:
`{ "type":"control_request", "request_id":"<id>", "request":{...} }`
Sibling subtypes: set_model, set_permission_mode, set_max_thinking_tokens,
set_color, interrupt, mcp_*, file_suggestions, get_usage, get_context_usage.
Handler `bkd()` logs `[bridge:repl] Inbound control_request subtype=rename_session`
and replies `{type:"control_response",response:{subtype:"success"|"error",request_id}}`.

## Bridge transport
- URL selector `I3_()`:
    USE_LOCAL_OAUTH || LOCAL_BRIDGE   -> ws://localhost:8765
    USE_STAGING_OAUTH                 -> wss://bridge-staging.claudeusercontent.com
    else                              -> wss://bridge.claudeusercontent.com
- Paths seen: /v2/ccr-sessions/ , /v2/ccr-sessions/-/chat-project ,
  /v2/session_ingress/mcp/ws/ , /v2/session_ingress/shttp/mcp/ , /v1/code/
- Auth: OAuth bearer, refreshed per session (`bridge_token_refreshed`,
  `bridge_token_refresh_no_oauth`). Scopes: user:projects:read, user:projects:write.
- Env: LOCAL_BRIDGE, USE_LOCAL_OAUTH, USE_STAGING_OAUTH, CLAUDE_CODE_FORCE_BRIDGE,
  CLAUDE_CODE_BRIDGE_SESSION_ID, CLAUDE_CODE_REMOTE_SESSION_ID.
- Ingress parser `_kd` ignores echoes by uuid; sequences via bridgeLastSeq.

## Plan
Force a throwaway session onto ws://localhost:8765, capture the HTTP upgrade
(auth header + routing path) and the initialize/advertise frames + the exact
rename_session message a "desktop" peer sends. Then build a client that talks to
the prod relay with the account OAuth and routes rename_session to a bridgeSessionId.
Test locally against a throwaway session (verify its onRenameSession fires) before
touching real sessions.
