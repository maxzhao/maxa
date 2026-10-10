---
title: Maxa AI Chat Commands 行为规格
created: 2026-06-28
updated: 2026-10-14
type: source
doc_role: spec
authority: accepted
status: active
capability: chat-fragments-and-slash-commands
sources:
  - lua/plugins/ai.lua
  - lua/util/env.lua
  - lua/maxa/providers/completion/
  - lua/maxa/interactions/chat/slash_commands/
  - lua/maxa/session/chat_fragments/
  - lua/maxa/session/slash_commands/
  - lua/maxa/session/chat_upload/
  - lua/maxa/session/telegram_upload/
  - lua/util/maxa_drafts.lua
  - lua/util/maxa_specs.lua
  - lua/util/maxa_articles.lua
  - tools/chat-upload/
  - tools/tls-certificate/manage.sh
  - tools/telegram-bridge/
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
---

### Scope

Owns slash registration and command-visible mutations. Other owners: [compression algorithm](../abilities/base/session/session-compression.md), [history storage/trace state](./session-history.md), [lifecycle stop](./lifecycle-and-message-injection.md). Imperatives express SHALL; may/MAY stays optional. Result paths are project-relative, contained, existing regular files, never absolute/private paths.

### Registration and metadata

#### Requirement: Commands use current owned callbacks

Runtime defaults SHALL register through `maxa.session.*` callbacks: `collapse`, `compact_rescue`, `compact_silent`, `pick_session`, `pick_draft`, `pick_spec`, `pick_article`, `latest_draft`, `fork`, `scratch`, `save`, `merge`, `summarize`, `rewind`, `rewind_to`, `redo`, `save_fragment`, `insert_fragment`, `upload`, `tg_upload`, `trace_start`. Incremental `/collapse`, interactive rescue and configuration-selected silent follow [Session compression](../abilities/base/session/session-compression.md); former compact_handoff names and legacy slash algorithms are retired. Project startup may retain ordinary overrides. Retired `util.mcphub.cc_history` callbacks, Agent Loop and `pause_loop` SHALL remain absent. Mutations SHALL generate/interpret only canonical `session_*`/`_session_*` metadata, except the existing `collapse_summary` message tag used by incremental collapse; never restore `cc_history_*` fields.

#### Requirement: Text-producing slash commands replace their invocation token

Default/cmp/blink SHALL capture one canonical 0-based byte `{row,col}` anchor before deleting only the accepted slash token. Its range MUST match the token, stay on one line inside editable user input, and preserve prefix/suffix; mismatch fails without deletion. Tokens allow alphanumeric, underscore, colon and hyphen; completion preserves slash-through-acceptance-cursor text without consuming the suffix. cmp SHALL NOT clear the line. Picker/async output follows an invocation buffer extmark, not the later window cursor. Coc completion is removed.

Only explicit editable-text commands use this anchor: Markdown user expansion, date/path/skill pickers, MCP prompts and upload placeholders. Async commands create extmarks only when work starts and release them idempotently on success/cancel/error/close; non-text actions create none. Multiple outputs advance the anchor in source order. Invalid anchors fall back to the cursor only in the target Chat, otherwise existing tail append. Context blocks and compact/repeat/rewind/redo/summary/branch/merge keep specialized behavior. [Markdown Prompt format](../prompts/markdown-format.md) owns Markdown line breaks, insertion positions and user/llm semantics.

#### Requirement: Slash command identities are deterministic

Ordinary Markdown prompts SHALL register `/name`; Ability-owned Markdown prompts SHALL register only `/ability-name:name`, using the owning Ability identifier and unchanged frontmatter `name`. Do not publish an unprefixed Ability alias or apply different name validation/rewriting by source.

Menu labels SHALL be case-insensitively unique using the complete command identifier. Registered Lua names remain reserved even when hidden by enabled conditions; Markdown cannot replace them. Prompt priority for identical complete identifiers: project ordinary > project Ability > global ordinary > global Ability. A tie at the highest applicable priority suppresses that label and emits bounded source diagnostics, without lower-priority fallback. Active ordinary Prompt names match artifacts; `do_spec`/`modify_spec` MUST NOT expose `*_sped` misspellings. Different Ability prefixes and an ordinary unprefixed name may coexist; ordinary names containing colons still participate in the same complete-identifier collision rules.

MCP prompts use invocation context: user-only text inserts at the anchor; ordered user/assistant text becomes visible committed history, preserving the draft. System messages or assistant text without preceding user text fail without partial insertion. Globally unique names use `/mcp:<prompt>`; cross-server duplicates use `/mcp:<server>:<prompt>`, never silently overwrite.

### Explicit user loading

- **Explicit slash loading**: Idle-Chat /load MUST offer searchable multi-selection of non-hidden Abilities, their public Markdown references, allowed registered Native concrete textual resources before load, and External concrete textual resources from exact-Chat/workspace-authorized ready revisions. Reuse the shared # content catalog and textual MIME filter. Browsing MUST NOT activate sources/load content or expose hidden/disabled Native sources, disabled Native resources, templates, scripts or arbitrary knowledge/task paths.
- **Slash load history and draft**: Confirmation executes the existing load builtin in selection order. A pre-load Native resource first requires a real Ability load, at most once, unless already earlier in the queue. Every prerequisite/target retains a paired assistant tool-call/result, followed by deferred instructions/context before editable input; IDs, catalog/context metadata, dependencies, hooks and deduplication remain valid through display/save/restore. Preserve unsent text; never auto-submit or insert literal @load.
- **Slash load failure boundary**: Busy/invalid Chats refuse loading; execution blocks submission. Picker cancellation leaves history unchanged. Execution errors retain real paired errors without failed-root authorization. Cancellation/destruction discards uncommitted root work and releases the operation; prior committed dependencies follow the existing load contract.

Observed load workflow: actual completion/Picker multi-selection, package/resource loading, draft preservation, cancellation, ready/unchanged deduplication and save/restore passed; checks/cancellation timing limits remain within the recorded scope. [Chat Builtins](./chat-builtins.md) owns load authorization/transactions.

Observed content completion: fresh actual unloaded Native resource Picker, read-only browsing, prerequisite/resource pairs and draft preservation passed. Extension human review was not-run then; prior stable review was user-declared passed.

### Session Soul selection

#### Requirement: `/souls` selects an Agency Soul for this Chat

Choices SHALL be complete Markdown role files from resolved `agency-nexus` `agents/<division>/`, addressed through root-confined exact `#agency-nexus:/agents/<division>/<role>.md`. Other Ability files, arbitrary paths, inline text and provider/model selections are excluded. Missing/disabled Ability or invalid/unreadable/empty file fails visibly without Chat mutation.

#### Requirement: `/souls` replaces only the effective Soul

Idle selection SHALL replace only the tagged Soul in the initial system prefix, preserving Runtime, project context, dialogue and adapter/model; subsequent requests use it. Cancellation/errors/in-flight requests leave messages unchanged. Restored distinct Soul messages remain replaceable. Legacy combined defaults MAY split only at recognizable Runtime/Soul boundaries; unidentifiable custom prompts fail explicitly without mutation.

#### Requirement: Generic Rules commands are absent

New Chats SHALL omit `/rules`, `gM` Rules clearing and the Rules action picker. Ordinary explicit file context remains allowed; retired commands cannot activate arbitrary files as project rules.

#### Requirement: Chat input has no editable Context list

New/restored/continued Chats SHALL neither generate editable `> Context:` lists nor interpret input edits as enabling/disabling rules, attachments or schemas. Project rules stay independently loaded hidden context, tools registered schemas, and explicit file/buffer/quickfix attachments hidden messages/internal metadata. Historical context structures remain usable without recreating the list.

### Chat fragments

#### Requirement: Fragments are project-local versioned JSON

Store Git-trackable runtime/context artifacts, not wiki notes, in `.maxa/fragments/`: `<project>/.maxa/fragments/<fragment-id>.json`, schema version `1`, fields `schema_version`, `id`, `title`, `description`, `created_at`, `source_chat`, `source_session`, `tags`, `messages`. Default ID is UTC timestamp + slugified title; explicit ID may override. Before insertion, reject unreadable/invalid JSON, non-object, unsupported schema or non-array `messages`.

#### Requirement: `/save_fragment` saves selected copied messages

Copy messages; offer row/preview/multi-select/delete-from-copy UI; collect title/description/tags; save selected full JSON-serializable structures without changing source Chat. Cancellation/empty title/empty selection aborts without partial file.

#### Requirement: `/insert_fragment` appends safely

Idle Chat only: deep-copy, refresh present ids/timestamps/index, add `_meta.inserted_at`/`_meta.inserted_from_fragment`, synchronize tool references, render and save history when available. Render failure restores the original snapshot. Active tracing emits `fragment.inserted` with id/path/range/count; inserted messages do not automatically become natural-turn events.

### Branch, scratch and editing

#### Requirement: `/fork` creates persistent copied branch

Copy messages, adapter/settings, tool registry, context items, cycle and protected-prefix metadata into a savable Chat with editable/hidden-tail setup. Tracked parents create a child span and `fork.created` event.

#### Requirement: `/scratch` creates unsaved temporary branch

Use `history_core.make_unsavable_save_id("scratch")`; retain canonical parent IDs, fork start, creation time and in-memory parent reference. Closing requires explicit uppercase `Y`; without confirmation UI, cancel close. Tracked scratch retains trace membership and emits `scratch.created`.

#### Requirement: `/save` promotes only current idle scratch

Promotion SHALL:

1. Snapshot identity/metadata/parent reference.
2. Generate a regular save id.
3. Remove `_meta.session_scratch`/`_session_scratch_parent_chat`.
4. Write scalar `_meta.session_saved_from_scratch` provenance.
5. Save through current history API; verify load when available.
6. Preserve trace span; when tracked, set `promoted_scratch` role and emit `scratch.saved`.

Non-scratch/busy Chat rejects without mutation. Persistence/verification failure restores scratch identity. Promotion ends scratch close/merge semantics; later standard lifecycle events auto-save.

#### Requirement: `/merge` appends scratch-only tail to open parent

Require an open parent and messages after fork start; otherwise fail without mutation. Merge context, append new messages, render/save parent, close scratch and focus parent. Tracked merge emits `scratch.merged` with source/parent spans, fork index, range/count.

#### Requirement: Rewind/redo/summarize use manual messages only

Manual user messages exclude hidden, metadata-tagged, context-linked and wrapped runtime-control messages. Rewind/redo also recognize successful completed `ask(input|choice)` replies by matching canonical call/result identity, including a synchronous tool-mode `run` wrapper; notify/error/cancel/timeout results are excluded. `/summarize` remains manual-only. Busy Chats reject these mutations and cursor rewind.

**Rewind persistence barrier** applies to `/rewind`, `/rewind_to` and `gr`: automatic/manual saves MUST preserve prior saved history until successful dispatch of new manual input or a revised ask reply. Cancelled/blocked submission cannot persist the branch; closing/reopening before dispatch restores prior history.

- `/rewind`: select latest eligible user interaction; `/rewind_to` lists/selects these newest first. Manual input is removed onward and restored to the draft. Ask reply keeps its question, matching canonical call/result and necessary sibling results, removes later history and restores the original reply as editable draft instead of a completed response bubble. Context/protected prefix follow retained history.
- Resending an ask draft replaces the matching `tool` result/presentation without an extra user message or tool execution, then continues the model. Empty/whitespace-only reply remains editable; malformed or changed target rejects before dispatch. Canonical roles and retained tool-call/result pairing remain valid.
- `/redo`: apply the same rewind then schedule normal submit; successful dispatch makes the branch normally saveable.
- `/summarize`: select manual-input-to-tail range, produce Chinese summary with compact adapter, retry once if empty, replace range with a `session_manual_summary` message, render/save. A second empty result restores edit area and errors.

#### Requirement: Cursor rewind retains the selected message

Under the rewind persistence barrier, confirmed `gr` on manual input SHALL remove it and all later messages, restore text to the draft and enter editing like `/rewind`; confirmation states its removal. On an eligible ask reply, use the same re-answer semantics as `/rewind`, with confirmation distinguishing reply replacement from manual-input removal. On other messages, retain selected message and all results needed to complete retained tool-call batches, remove later messages and clear draft. Keep default-No confirmation, target identity recheck and busy rejection.

### Path insertion

All four commands below insert repository-relative paths only, never bodies. Draft/article ordering is descending mtime with a path tie-break: ascending for drafts (using nanosecond mtime when available), deterministic for articles.

#### Requirement: Draft commands insert paths only

`/latest_draft`/`/pick_draft` select `.maxa/drafts` paths.

#### Requirement: `/pick_spec` exposes lifecycle without blocking trace selection

Discover stable direct Markdown specs and change proposals/deltas; preview lifecycle guidance and insert the selected path. Stable labels: `[SPEC <status>]`; missing/malformed frontmatter: `unknown`, still selectable. Accepted/superseded history routes to current/replacement paths when present. No root/items: notify, create no directory.

#### Requirement: `/pick_article` uses source-layer roots

Roots: `.maxa/reports`, `.maxa/ideas`, `.maxa/rules`, `.maxa/research`. Retain `[REPORT|IDEA|RULE|RESEARCH]` and category-relative nested paths; exclude `index.md`/`log.md` at all depths.

### HTTPS upload

**Shared `/upload` and `/tg_upload` contract**: `contains_code=false`; `.maxa/upload/` is Git/Obsidian/Syncthing-ignored runtime data, no knowledge index/log. State MUST NOT reuse `current_request`, `current_tool` or LLM status. Lock only invoking Chat. Success replaces unchanged placeholders without Chat submission; changed placeholders use safe normal insertion fallback, never deleting unrelated edits. Returned files obey Scope's path contract.

#### Requirement: `/upload` starts one asynchronous trusted-HTTPS session

Use `maxa.session.chat_upload.slash_command`; reject invalid/busy/duplicate Chat. Default `chat_upload.hostname=127.0.0.1` allows HTTP only on literal IPv4 `127.0.0.1`, displaying `http://127.0.0.1:<port>/session/<cryptographic-token>/`; no private default-route discovery/domain certificate required. Reject HTTP bind to `0.0.0.0` or any other network address.

The bundled deployment config and shared certificate manager SHALL resolve `MAXA_CERT_DOMAIN` from nonempty process environment, then the selected local environment file: nonempty `MAXA_ENV_FILE`, otherwise the Maxa runtime root `.env`. Domain values are plain configuration data with optional surrounding quotes, not executable shell content. Missing/empty domain leaves bundled upload on the loopback default; certificate `status|renew|paths` fail clearly before certificate work, while help remains available. Public examples contain no personal deployment-domain default. Explicit `chat_upload.hostname` / CLI `--hostname` remain supported.

Explicit non-loopback DNS hostnames require private default-route and matching TLS certificate validation before dynamic-port IPv4 `0.0.0.0` binding; report `https://<hostname>:<port>/session/<cryptographic-token>/`. No remote HTTP or HTTPS-to-HTTP fallback. Lua rejects `ready` scheme/host/bind/port/token mismatches. Remote certs: `certificates/<hostname>/{fullchain,privkey}.pem`; missing/invalid/hostname-mismatch/key-pair failures must precede stale Chat lock. `just tls-cert-status|renew|paths` keep Cloudflare tokens hidden, temporary `0600`, deleted on exit; public certs `0644`, private keys `0600`. Token prompts use the configured domain rather than a fixed parent domain.

#### Requirement: Upload service owns contained streaming storage

Each invocation owns `.maxa/upload/<session-id>/` and atomic `.manifest.json`. Stream uploads/imports through partial files, serialize mutations, never overwrite (suffix `-2`, `-3`); limit each file to `2 GiB`, completed+reserved session storage to `10 GiB`. Submit/Cancel terminalize at most once; completed files survive either. Refresh restores only completed records; remove failed partials where possible.

Token-scoped same-origin API: page/state/file upload/public URL import/file removal/submit/cancel. Statuses: unknown path/token `404`, invalid `400`, terminal conflict `409`, limit `413`, unexpected `500`. Flush terminal response before shutdown.

#### Requirement: Upload UI is local and bounded

Locally bundled Uppy provides local files/multiple/drag-drop/paste/preview; Webcam picture/video/audio, Audio, source selection/duration; browser-supported screen/window/tab capture/screenshot/audio; Image Editor, Compressor and guarded public URL import. No runtime CDN, Companion, OAuth, WebDAV, cloud-provider or AI-provider extensions.

URL import accepts credential-free `http|https` only. Validate every DNS result/redirect as public; pin validated address, preserving Host/SNI. Reject private/loopback/link-local/CGNAT/multicast/unspecified/documentation/benchmark/reserved ranges. Limits: 5 redirects, 30-second timeout, 8 KiB JSON body; reuse streaming limits.

#### Requirement: Upload placeholder and Chat lock converge

Valid `ready` inserts exact `请使用这个地址上传文件：<URL>` line, records row/text and acquires the shared Chat lock. Submit + terminal event + exit 0 completes with validated paths, one per line. Cancel/error/close removes only the unchanged placeholder. Every terminal path unlocks and clears process/hooks/state idempotently under the shared contract.

### Telegram upload

#### Requirement: `/tg_upload` creates a durable no-timeout Bridge request

Use `maxa.session.telegram_upload.slash_command`. Require idle valid Chat, project root, stable save id, healthy registered Bridge instance, and no active `/upload` or `/tg_upload` for this Chat; shared upload constraints apply.

Bridge alone consumes Bot updates. Persist request before sending reply-target message; create/reuse the exact Chat's configured group topic using the existing session-topic recovery policy. Failed recovery MUST NOT fall back privately. Expose bounded create/poll/cancel state without credentials, destination ids, Telegram URLs or absolute paths. Requests never expire; bounded HTTP long polls implement infinite logical waiting.

#### Requirement: Exact first valid owner reply wins

Require configured owner, persisted chat/topic, exact `reply_to_message.message_id`, pending state and no media group. First valid reply terminalizes atomically; duplicates cannot restart download/change result. Wrong user/destination/target leaves pending and continues unrelated Bot behavior without disclosure.

Valid terminal input: nonempty pure text, validated location, or exactly one `document|photo|video|audio|voice|video_note|animation|sticker` with optional caption. Select largest photo. Location: exact `纬度：<latitude>\n经度：<longitude>`, standard ranges, no venue/address/map link. Media groups, multiple/unsupported payloads and recoverable download/size failures produce bounded Telegram errors and remain pending.

#### Requirement: Telegram attachments stream safely

Capture filename/MIME/size/kind before `getFile`; stream at most `20*1024*1024` bytes through staged files into `.maxa/upload/<session-id>/`. Sanitize names/extensions, avoid overwrite, finalize atomically, return only verified project-relative paths. Declared/observed limit or network/storage/containment failure removes partial data. Finalized files survive completion/cancellation/Chat close/exit and later insertion failure.

#### Requirement: Telegram placeholder resolves path before text

After create succeeds, insert exact standalone `请在 Telegram 中回复 Bot 发出的上传消息；可发送一个文件或纯文字。`, stop insert mode, lock Chat and poll. Under shared placeholder semantics, completion inserts path then nonempty text/caption, or text alone. Close/delete/normal exit cancel idempotently, stop polling, clean state/remove placeholder/unlock; Bridge liveness cleanup owns abnormal caller loss/restart recovery.

### LAN file access

#### Requirement: Local file links use a shared PID-owned read-only service

On an eligible user-facing local Markdown destination, ensure one host/user/PID-namespace service is ready on configurable fixed `maxa.file_links.port` (default `43128`), register current Neovim PID and exact Chat project with `maxa.file_links.allowed_roots` (default `{ ".maxa" }`), then publish the URL. Relative roots and paths resolve from the invoking Chat's project, not process cwd. Reuse `chat_upload.hostname` and its existing loopback HTTP / remote trusted-HTTPS policy; never downgrade certificate failures or choose random replacement ports. Concurrent starters reuse the verified service; unrelated port occupants fail clearly.

Registration is idempotent and many-to-many, replacing only that PID/project's roots. Every 30 seconds remove dead PID associations and exit when empty. Every file request immediately requires a live project-associated PID whose roots contain the real file. The daemon survives its spawning Neovim while another registration remains; Chat close alone does not revoke a living process. New daemon registry is empty.

URLs contain deterministic project/root keys and encoded relative paths, not absolute filesystem paths, PIDs, Chat ids or expiring tokens. Unchanged links recover after the same project/roots re-register. Serve regular files via GET/HEAD, inline for supported browser formats and downloadable otherwise; no directory browsing or mutation. Registry/readiness endpoints are loopback-only. Reject traversal and realpath/symlink escape at conversion and request time.

#### Requirement: Local Markdown link projection preserves canonical content

Convert existing allowed inline link/image and used reference destinations, including absolute paths and `file://` targets. Preserve labels/titles/syntax and all other text; external URLs, bare paths, code spans/fences, unused references, missing/disallowed files and HTML ask content remain unchanged. Only display/send copies change: model/history bodies and tool inputs/results retain local destinations. Re-render eligible presentation using the restored Chat's project. Launch/registration failure preserves local links with a bounded warning, without interrupting conversation or ask arbitration.

Implementation owners: `lua/maxa/session/file_links/` and `tools/chat-upload/src/file_links_{cli,server}.mjs`; Chat/ask/Telegram consumers own message eligibility. Focused backend API/lifecycle checks plus actual multi-Neovim lifetime, trusted-HTTPS browser image, terminal Chat/redraw and user-confirmed ask-topic links establish these boundaries. Root-relay link projection and formatted/HTML exceptions were not independently observed live.

### Trace activation and lineage actions

#### Requirement: `/trace_start` activates one root trace

Only explicit `/trace_start` enables tracing. Require a regular savable save id; immutable root trace id equals it. Create/reuse storage, persist `_meta.session_trace` root membership, idempotently backfill recoverable user/final-assistant/error turns and emit `trace.started`/`trace.backfilled`. [Session history](./session-history.md)/[Session tools](../abilities/base/session/session-tools.md) own storage/reads. Fork/scratch/save/merge/fragment propagate membership/action events only when tracing is active; inactive behavior is unchanged.

### Validation

#### Evidence retained

- 2026-10-10: actual post-restart scratch Chat verified `/rewind`, `/rewind_to` selection, `gr` confirmation, exact original draft, edited canonical tool-result replacement without an extra user message, paired retained calls/results and successful model continuation. Existing slash helper checks and changed-Lua syntax passed; new human implementation review not-run.

- 2026-10-07: Ability Markdown namespace change passed actual post-restart Chat/Blink completion and expansion using a user-authorized temporary Ability, preserving ordinary `/ask`, raw `${item.name}` and no auto-send; fixture removed. Existing parser/slash checks passed their assertions; the isolated headless slash check emitted an Ability-discovery warning, not reproduced in the actual configured path. human review of this change is not-run.

- 2026-09-30 user review passed for visible-context removal, deferred rewind saving and cursor-rewind user edits.
- Final-owner slash/fragment/fork/save/rewind/summary/compression suites passed aggregate validation; `/save` and cross-session behavior had historical live checks.
- Focused slash anchors, Default/cmp/blink/coc separator-token handling, UTF-8 insertion, ordered outputs, visible Markdown/MCP history, duplicate-server identity, async cleanup and upload placeholders passed. Fresh configured restart-resume UTF-8 `/now` prefix-replacement smoke passed.
- HTTPS Node suite 30 passed; Lua controller 10 passed; TLS/registration/Submit/Cancel smokes recorded.
- Telegram Bridge suite reached 88 passed; upload Lua, private text/location fixes, restart/health and unbound-private live smoke passed.
- Trace lineage tests and post-restart `session__get_trace` smoke covered slash actions/bounded query.
- User specification review passed.

#### Unrun/limited validation retained

- Fragment interactive picker smoke incomplete in original checklist.
- HTTPS desktop/mobile capture, refresh/removal, separate Cancel and active-close matrix not fully run across devices.
- Telegram bound-topic file+caption, representative media, invalid-reply recovery, close/exit timing and restart-while-pending unrun live.
- Trace GUI/manual fork reopen and full recursive SubAgent/multi-agent loops intentionally unrun.
- Overall live workflows remain `partial` with these device/Telegram/trace gaps; human specification review is `passed`.

### Source trace

- Registration: `lua/plugins/ai.lua`; commands/fragments: `lua/maxa/session/slash_commands/`, `chat_fragments/`.
- Controllers: `lua/maxa/session/chat_upload/`, `telegram_upload/`; services: `tools/chat-upload/`, `tools/tls-certificate/`, `tools/telegram-bridge/`.
