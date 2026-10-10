---
title: Telegram Bridge Service 行为规格
created: 2026-06-28
updated: 2026-10-12
type: source
doc_role: spec
authority: normative
status: active
accepted_at: 2026-09-30
capability: telegram-bridge-service
validation:
  automated: passed
  human: passed
review:
  human: passed
  evidence: user-declared-current-change-and-interaction-review-2026-09-30
sources:
  - tools/telegram-bridge/pyproject.toml
  - tools/telegram-bridge/src/telegram_bridge/app.py
  - tools/telegram-bridge/src/telegram_bridge/api.py
  - tools/telegram-bridge/src/telegram_bridge/bot.py
  - tools/telegram-bridge/src/telegram_bridge/config.py
  - tools/telegram-bridge/src/telegram_bridge/store.py
  - tools/telegram-bridge/src/telegram_bridge/queue.py
  - tools/telegram-bridge/src/telegram_bridge/registry.py
  - tools/telegram-bridge/src/telegram_bridge/security.py
  - tools/telegram-bridge/tests/
  - lua/maxa/session/telegram_bridge/client.lua
  - lua/maxa/interactions/chat/tools/builtin/runtime/ask.lua
  - prompts/system.md
  - justfile.md
  - user-review:2026-09-15
confidence: medium
---

> **TLDR**: Bridge owns Telegram Bot consumption, authenticated local APIs, persistent session/request/event state and Telegram/Chat `ask` arbitration. Routing is notify-only; binding controls and records are retired.

## Requirements

### Requirement: Bridge is a uv-managed authenticated service

Run/test through the service's uv project or declared `just` recipes, never system Python. Configuration comes from process/local-only environment inputs; tokens, owner/group IDs, passwords and API keys MUST be redacted, and repository artifacts MUST NOT contain secrets. When configured, `X-Maxa-Bridge-Token` protects local HTTP endpoints; missing/invalid credentials fail explicitly. HTTP header case-insensitivity remains unchanged.

### Requirement: Bridge owns Telegram update consumption

One Bridge process SHALL own `getUpdates` per configured Bot. Maxa Lua clients use authenticated Bridge HTTP and SHALL NOT poll Telegram directly. No Agent-facing direct-poll or Python Human Assist client remains.

### Requirement: Session state and events are persistent and scoped

Session identity is exact `(project_root, save_id)`. Heartbeats MUST record each open Chat's identity, running and notify-listening state. Session-topic identity MUST persist independently of binding, including migration of existing ask/notify topic records from the unbind era. Owner/group authorization MUST reject unmatched private text and foreign-group input; ordinary admission follows `Notify-only Telegram session input`.

Remove binding-only session control/status paths. An idempotent database migration MAY delete legacy Bridge `bindings` records but MUST NOT delete Telegram topics/messages, ask/notify topic records or waiting human-assist requests.

### Requirement: Notify-only Telegram session input

Ordinary configured-group text MAY reach only its ask/notify topic's exact session, with the configured owner authorized, that Chat open in a live nvim instance, completion listening enabled and no agent loop/request running. Waiting `ask` replies instead follow `Waiting interactions are race-safe and recoverable`.

| Stage/condition | Required result |
| --- | --- |
| Admitted at receipt | Bot MUST immediately acknowledge pending submission, not completed processing, and report any later nvim rejection. |
| Running, closed, stale, notify-inactive, or unknown/group-notification topic | Bot MUST explicitly reject (immediately when busy), never enqueue for a later loop. |
| nvim submission | MUST recheck live identity, listener activation and busy state; changed state rejects without replay after the loop. Valid idle input MUST submit to that Chat without disabling local input or silently losing an unsent local draft. |

Submissions MUST be serialized so simultaneous TG/local requests cannot overwrite one another.

### Requirement: Telegram command menu without binding

The configured-group menu MUST expose only `/ping`, `/sessions` and `/clean_tracked_topics`. `/ping` retains Bridge liveness behavior. In General:

- `/sessions` MUST list live nvim Chats read-only, showing running/notify-listening state but no binding status or attach/unbind buttons.
- `/clean_tracked_topics` MUST retain owner authorization and destructive confirmation. It MAY delete only known non-General session topics whose exact Chat is not open in a live nvim instance; it MUST preserve active Chat topics, skip unknown/system topics, and MUST NOT close or delete nvim Chats as part of legacy binding cleanup.

### Requirement: Ask delivery uses session group topics

Builtin `ask` MUST derive session identity from the invoking Chat and create/reuse its persisted group topic independently of binding; concurrent/repeated asks MUST reuse it. Identity/destination MUST NOT come from latest Chat/current buffer, `.env` identity, a group notification topic, an LLM-selected destination or a guessed primary instance. Missing topics follow `Session-topic recovery avoids duplicate delivery`.

Notify and eligible ordinary TG text MAY reuse the topic without explicit attach. Replies still require `MAXA_TELEGRAM_OWNER_USER_ID`.

### Requirement: Session-topic recovery avoids duplicate delivery

Bridge MUST recreate a known stale/missing session topic, persist its exact session association and retry delivery once without duplication. Apply these delivery boundaries:

| Caller/condition | Required result |
| --- | --- |
| Builtin `ask`: missing caller identity, configured group or usable topic, including failed recovery | Fail TG delivery, retain the Chat-side response path; MUST NOT fall back privately. |
| Per-Chat listener: unavailable identity/group/topic | MUST NOT send privately. |
| Legacy Bridge notify without explicit session-topic intent | Retain owner-private delivery. |
| Other legacy non-ask callers | MAY retain existing private fallback where applicable. |

Unknown/delivery-ambiguous failures MUST NOT produce duplicate private delivery. Agent-facing responses MUST NOT expose destination/fallback IDs or route metadata.

### Requirement: Waiting interactions are race-safe and recoverable

- **Creation**: Notify returns its message result without a waiting row. Prompt/input accept validated caller-generated request IDs, persist the actual destination before exposing buttons/reply targets, and attach the Telegram message ID after send; send failure removes incomplete state.
- **Admission**: Choice accepts authorized button callbacks or nonblank replies; input requires nonblank text or a photo. Empty/unsupported replies do not complete. Authorized builtin `ask` button, text, input-photo and upload replies MUST retain owner/group controls and the first-valid/atomic completion route even during an agent loop; they MUST NOT become ordinary Chat text.
- **Completion**: Telegram buttons/text, input-mode photos and the authenticated Chat completion endpoint share atomic `pending -> completed`. Terminal results record internal source `telegram|chat`; duplicate/late responses return or observe terminal state without mutation. Chat completion closes/edits the Telegram message and removes controls. Completed input photos may be downloaded through the authenticated file endpoint.
- **Cancellation**: Before creation, reserve the request ID so late creation fails closed; after creation, close the message.
- **Timeout**: Prompt/input expires with `error: timeout` and attempts to close/edit the original message and remove controls.

Stable statuses are `pending`, `completed`, `expired` and `cancelled`.

### Requirement: Notification status edits are best-effort and non-disruptive

An authenticated plain notification edit MUST use the existing cached exact `(project_root, save_id)` session-topic association and Bridge-configured destination, never caller-selected Telegram destination IDs. Do not create/recover topics, send a replacement/private message or retry. Telegram edit errors/timeouts are unsuccessful no-op results; Lua also ignores transport, schema/version and synchronous invocation errors without notification or conversation interruption. Preserve existing notify API responses; the Lua success callback MAY additionally supply the last successfully delivered segment's message ID/text as runtime-only receipt. Listener usage follows [Reply opportunity on a completion notice](../runtime/plugin-entrypoints.md#requirement-reply-opportunity-on-a-completion-notice).

On 2026-10-12 the user confirmed the existing notification was edited without another alert; the real missing-message API path returned unsuccessful without a Chat warning. Pending-send race, deleted-topic and version-mismatch cases were not independently observed live.

### Requirement: Plain Telegram notifications are complete and sequential

User-facing final/eligible pre-ask Markdown text MAY replace local destinations under the [file-link contract](../runtime/chat-commands.md#requirement-local-markdown-link-projection-preserves-canonical-content) before notification segmentation. Lua Bridge-client plain-text notifications MUST preserve every resulting character and send ordered segments of at most 3900 UTF-16 code units through the existing notify endpoint, preserving exact caller context/topic and delivery options. Never split a Unicode scalar, summarize or truncate. Success requires successful delivery of every segment; first failure stops remaining segments and marks partial delivery internally so higher-level retries cannot replay already-sent segments. Ambiguous failures MUST NOT be blindly replayed. Existing formatted/photo notification paths and direct Bridge schemas remain unchanged.

On 2026-10-12 the actual Lua client delivered a 4513-character plain notification in two segments; user inspection confirmed continuous numbering, Chinese, non-BMP emoji and end marker without truncation or duplication. Partial/ambiguous-send recovery was not separately exercised live.

### Requirement: Listener notifications reuse session group topics without binding

The runtime-only per-Chat listener MUST use its exact session's group topic with session-topic route intent, sharing builtin `ask`'s topic and recovery/fallback policy. It MUST NOT invoke LLM-facing `ask` or persist activation state. Activation permits ordinary TG input only under `Notify-only Telegram session input`; group-scoped notification fallback topics remain separate from Chat-associated topics.

[Runtime Plugin Entrypoints](../runtime/plugin-entrypoints.md) owns listener terminal delivery, bounded safe retry and runtime-only lifecycle.

### Requirement: Polling and diagnostics degrade safely

Transient Telegram/network/proxy polling failures are logged with redaction and retried with bounded exponential backoff while the local API remains available. Unknown configuration/send failures stay explicit.

### Requirement: Current-project maxa naming migration

- **Coordinated Bridge naming cut**: Client/server authentication header, `MAXA_TELEGRAM_*`/`MAXA_ENV_FILE` configuration, `maxa-telegram-bridge` CLI, `maxa-telegram-bridge.service` and `maxa` state/log namespaces MUST be updated together under the runtime naming mapping. No permanent old-name aliases remain. Rename local env keys only within the user's authorization, preserving and never displaying credential values. Rebuild affected editable-install entry metadata with the declared uv runtime and preserve pinned dependency versions.

- **Single-consumer data-preserving service switch**: Stop the old Bridge before starting the new one. Preserve configured Bot/group/owner values, SQLite and exact `(project_root, save_id)` session/topic identities; do not create a second Telegram update consumer or reset/delete topics, pending requests or unrelated database records to achieve the rename. If service/configuration startup fails, report the exact blocker and preserve recoverability.

All retained Bridge clauses use the new naming, including owner variable `MAXA_TELEGRAM_OWNER_USER_ID`; authorization, routing, first-response arbitration, delivery recovery and existing destructive confirmations otherwise remain unchanged.

## Validation And Review State

Actual TG/nvim interaction MUST demonstrate `Notify-only Telegram session input` and `Telegram command menu without binding`, including the preserved waiting-interaction `ask` reply route. Migration MUST remove only legacy binding records, preserving topics, ask/notify identity and pending human-assist requests.

On 2026-09-30 the user confirmed all current changes passed human review and separately confirmed the previously pending completion-notification, idle TG submission/receipt, local-draft preservation and local-first TG notice interactions passed. Focused Bridge/Lua checks and restart evidence remain valid; acceptance does not claim a new Agent-run UI session.

Historical results retain their original scope/time; retired binding/private-listener cases are not current behavior:

- **Bridge/ask checks**: 92 Bridge tests passed, covering caller request IDs, conditional Chat completion, cancel-before-create, authorized choice text, input photo, empty/unsupported reply rejection, late responses, routing and message closure. Lua ask/caller tests, strict skill lint, Bridge restart/health and full Neovim restart-resume passed.
- **Ask-only routing**: Focused Bridge/Lua ask checks passed. After Bridge/Neovim restarts, live builtin `ask` notify returned delivered; the current unbound Chat had one persisted ask topic and no binding. Human Telegram-client inspection was not run.
- **Group listener**: After a fresh Neovim restart, an unobserved completion sent Bridge notify (HTTP 200); the ask-only topic remained unbound and the user confirmed its group-topic listener message. The task retains details and the stale supplementary Lua test error.
- **Other live checks**: Prior private/bound routing scenarios plus Chat+Telegram notify, Telegram-button choice and Chat-text input passed; Bridge health passed after restart.
- **Persistent listener automation**: Consecutive-turn, foreground/background, split/tabpage, tmux, cancel deduplication, disable/close stale-callback and binding-exclusion cases passed without Bridge protocol changes. Full Neovim restart-resume passed runtime toggle/lualine checks; on 2026-09-18 the user detached the tmux client and confirmed owner-private Telegram delivery.
- **Human specification review**: Passed by explicit declarations on 2026-09-15 and 2026-09-18.
- **Not run**: Destructive live stale-topic recovery, fresh image reply/photo flow and live Telegram-unavailable → Chat fallback. These prior coverage limits remain; they are not evidence against the user-accepted notify-only change.
