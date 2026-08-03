---
kind: behavior-spec
authority: draft
status: partial
target_disposition: retained-and-redefined-by-chat-runtime-state-request-orchestrator-chat-ui-async-lifecycle
module: chat-lifecycle
baseline_commit: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
baseline_version: v18.7.0
scope: create/open/submit/stop/close chat, request state, buffer rendering, navigation, events, and errors
validation: partial
---

# CodeCompanion.nvim Chat Lifecycle and UI — Baseline Draft

## Authority and scope

This is a non-normative, baseline-only reverse specification for commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d` (`v18.7.0`). Target behavior is owned by `chat-runtime-state`, `request-orchestrator`, `chat-ui`, and `async-lifecycle`; CodeCompanion fields/callbacks are evidence only.

## Evidence boundary

### Inspected baseline chain

- Public command/API: `lua/codecompanion/commands.lua:118-166`; `lua/codecompanion/init.lua:118-182,226-310`.
- Chat construction/state/request lifecycle: `lua/codecompanion/interactions/chat/init.lua:405-629,1001-1180,1205-1275,1433-1515`.
- UI open/hide/navigation/rendering: `lua/codecompanion/interactions/chat/ui/init.lua:181-385,413-535`.
- Subscriber/automatic submission state: `lua/codecompanion/interactions/chat/subscribers.lua:1-145`.
- User-visible events and payload conventions: `doc/usage/events.md:1-92`; event names also in `doc/codecompanion.txt:4177-4183`.
- Chat display configuration: `lua/codecompanion/config.lua:890-975`.
- Tests inspected/inventoried: `tests/interactions/chat/test_chat.lua`, `test_subscribers.lua`, `ui/test_builder_state.lua`, plus chat test tree at the baseline commit.

### Baseline identity validation

- `git -C ~/.local/share/nvim/lazy/codecompanion.nvim rev-parse HEAD` → `558518f8d78a44198cd428f6bf8bf48bfa38d76d`.
- `git show -s --format='%H%n%cI' 558518...` → `558518f8d78a44198cd428f6bf8bf48bfa38d76d`, `2026-02-18T08:00:51Z`.
- `git show 558518...:version.txt` → `18.7.0`.

## State model

Observed retained state fields include `id` (random numeric chat identity), `bufnr`, `ui`, `messages`, `buffer_context`, `adapter`, `status`, `current_request`, `current_tool`, `cycle`, `header_line`, and callbacks/subscribers. New chats create an unlisted scratch buffer named `[CodeCompanion] <bufnr>`, attach Markdown parsing, register the buffer in global chat maps, resolve an adapter, and fire `ChatCreated`. Target identity/state ownership is redefined by `chat-runtime-state`.

The request guard is `current_request ~= nil`: a second `submit()` is ignored with a debug log. Request status is set from adapter stream results; observed values include success, error, and cancelling/stopped paths. `done()` clears `current_request`; if status is empty it resets rather than declaring completion.

## Requirements and scenarios

### R1 — Create a chat from API or command

The `CodeCompanionChat` command parses `key=value` parameters, recognizes `toggle`, `add`, and `refreshcache`, and joins remaining arguments as a user prompt. The retained Chat entry derives current-buffer context, resolves an optional supported provider and model/Command override, determines auto-submit when messages are supplied, installs rule callbacks, and constructs the Chat.

**GIVEN** no existing chat and a valid adapter/parser environment  
**WHEN** `CodeCompanion.chat()` is called, with or without an initial prompt  
**THEN** a chat buffer and state object are created, the UI is opened/rendered, and `CodeCompanionChatCreated` is emitted once for creation; an initial message causes auto-submit unless `auto_submit=false`.

**Failure/edge:** unknown adapter, unavailable parser, disabled code sending, invalid restore buffer, or missing chat produce a logged warning/error and no valid operation. Exact notification text and all initialization cleanup paths remain incomplete.

### R2 — Open and restore the UI

`UI:open()` is idempotent while visible. It resolves configured or per-open window options, supports `float`, `vertical`, `horizontal`, and buffer layouts, computes fractional/function dimensions, applies window options, restores a moved cursor or follows the end, configures folds, and emits `ChatOpened`. `restore(bufnr)` validates the buffer and focuses an already visible chat or opens a hidden one.

**GIVEN** a valid hidden chat  
**WHEN** open/restore is invoked  
**THEN** the chat becomes visible in the selected layout and emits `CodeCompanionChatOpened`.

**GIVEN** the chat is already visible  
**WHEN** `open()` is invoked  
**THEN** no second window is created.

**Configuration impact:** `display.chat.window`, `start_in_insert_mode`, `auto_scroll`, `sticky`, dimensions, border, relative, and window options affect visibility, mode, placement, and cursor behavior.

### R3 — Toggle, hide, and navigation

`CodeCompanion.toggle()` creates the last chat if absent; hides it if visible in the current/different tab; otherwise updates buffer context, closes the old visible window and reopens in the current tab with `toggled=true`. `UI:hide()` hides windows or switches to the alternate buffer according to layout and emits `ChatHidden`. `follow()` does nothing when hidden, manually positioned, or empty; otherwise it moves the cursor to the last rendered line.

**GIVEN** a visible chat  
**WHEN** toggle/hide is used  
**THEN** the chat is hidden and remains restorable without deleting its state.

**GIVEN** a hidden chat  
**WHEN** toggle/restore is used  
**THEN** it is reopened and focused in the current context.

**Gap:** complete keymap navigation, sticky-tab autocmd behavior, cursor movement tracking, and all window edge cases require deeper inspection.

### R4 — Render chat content

`UI:render(context, messages, opts)` creates user/LLM headers, skips system messages and invisible messages, inserts spacing on role transitions, renders message content split by newline, optionally shows settings, optionally inserts visual selection as a fenced block, writes buffer lines, renders separator/header extmarks, and follows the end. `force_header` and `stop_context_insertion` alter initial rendering. Reasoning/tool formatter behavior is only partially traced here.

**GIVEN** messages and optional visual context  
**WHEN** the UI renders  
**THEN** the buffer contains role headers and visible content in message order, with configured spacing/context behavior, while hidden/system messages are omitted from display.

**Configuration impact:** `show_settings`, `show_header_separator`, `separator`, `show_context`, `show_reasoning`, `fold_reasoning`, and `auto_scroll` affect output/formatting. `show_settings` requires YAML parser/configured adapter settings.

### R5 — Submit a request

`Chat:submit()` refuses concurrent submission, optionally invokes a callback, refreshes tools, parses the last user buffer message, checks context/images and variable/tool replacement, applies `prompt_decorator`, supports blank prompts, maps roles and tool schemas into a provider payload, locks the buffer/editing area, dispatches internal `on_submitted`, routes to the selected supported protocol adapter, and emits `ChatSubmitted` with buffer, id, and provider type.

**GIVEN** no request is active and a parseable user prompt exists  
**WHEN** submit is invoked  
**THEN** the prompt is added/synchronized to message state, a request handle is stored, the buffer is locked for the request, and the submission event is emitted.

**GIVEN** a request is active  
**WHEN** submit is invoked again  
**THEN** it is ignored and the existing request remains authoritative.

**GIVEN** no prompt and no prior user message  
**WHEN** submit is invoked  
**THEN** no request starts and a warning is logged.

### R6 — Process completion and errors

HTTP streaming parses tokens and chat chunks; successful chunks update status, accumulate output/reasoning/meta, and append visible LLM output. Error chunks log an error and complete. Client transport errors set error status and complete. `done()` clears the request, assembles output/reasoning, appends a final LLM message, labels sent items unless stopped, executes tool calls when present, otherwise unlocks/prepares the buffer, dispatches `on_completed`, and emits `ChatDone`.

**GIVEN** a successful response  
**WHEN** the adapter signals completion  
**THEN** accumulated output is committed to messages/UI and `ChatDone` is emitted.

**GIVEN** a transport or adapter error  
**WHEN** the error callback/chunk is received  
**THEN** error status is recorded, the error is logged, partial output is finalized through `done()`, and no success claim is made.

**Gap:** exact error buffer rendering, request-level `CodeCompanionRequest*` payload/timing and non-stream behavior are not fully inspected.

### R7 — Stop/cancel a request

`Chat:stop()` sets cancelling status, dispatches `on_cancelled`, emits `ChatStopped`, cancels a running tool and request when available, calls adapter exit handling, then schedules `done(..., {status="stopped"})`. Stopped requests avoid labeling sent items and terminate automatic subscribers through the cancellation callback.

**GIVEN** a request or tool is active  
**WHEN** stop is invoked  
**THEN** cancellation is attempted, cancellation state is observable, and the request is finalized as stopped.

**GIVEN** no active request  
**WHEN** stop is invoked  
**THEN** stop event/state transition still occurs; exact idempotency behavior needs test confirmation.

### R8 — Close and clean up

`Chat:close()` stops an active request, dispatches `on_closed`, clears edit tracking, clears last-chat references and global metadata, emits `ChatClosed`, clears adapter/model events, deletes the buffer, clears autocmds, and releases the chat object.

**GIVEN** a chat exists, optionally with an active request  
**WHEN** close is invoked  
**THEN** the request is stopped first, the chat is permanently removed, and `CodeCompanionChatClosed` is emitted.

**Failure/edge:** close during asynchronous cancellation and late callback ordering require further validation.

### R9 — Subscriber-driven continuation

Subscribers are queued with random IDs, can be unsubscribed, conditionally processed by cycle/order, can execute callbacks once/reuse, and may auto-submit after a configured delay. Auto-submit is suppressed when a request is active or the subscriber queue is stopped; cancellation sets the stopped flag.

**GIVEN** a qualifying subscriber with `auto_submit`  
**WHEN** the prior response completes  
**THEN** its callback runs and a deferred submit is scheduled unless stopped or a request is already active.

## Failure and boundary inventory

- Adapter resolution/parser initialization failure: logged; usable chat may not be returned.
- Duplicate submit: ignored.
- Empty prompt: warning, no request.
- Stream parse/transport failure: error status/log and completion path.
- Cancellation: request/tool cancellation is best-effort with protected calls.
- Close: destroys buffer and associated view metadata in the baseline; target session/view ownership is defined separately.
- External dependencies: Neovim windows/buffers/autocmds, Tree-sitter Markdown/YAML, provider clients, tools, timers, and event listeners.
- Concurrency: `current_request` guard, scheduled stop finalization, deferred subscriber submit. Idempotency is only partially evidenced.

## Observable events

Baseline event docs list `CodeCompanionChatCreated`, `Opened`, `Hidden`, `Closed`, `Submitted`, `Done`, and `Stopped`, plus adapter/model/clear/context/tool/request events. Chat source directly fires `ChatCreated`, `ChatOpened`, `ChatHidden`, `ChatSubmitted`, `ChatDone`, `ChatStopped`, and `ChatClosed`, which the event utility maps to User autocmd names. Documented payload examples include `bufnr`, `id`, `adapter`/`type`, and request status; per-event payload completeness remains a gap.

## Coverage matrix

| Surface | Normal | Actors | State/data | Failure/edge | External | Concurrency/idempotency | Validation | Status |
|---|---|---|---|---|---|---|---|---|
| create/API/command | covered | partial | covered | partial | partial | partial | static + tests inventoried | partial |
| open/hide/toggle/restore | covered | partial | covered | partial | covered | partial | static | partial |
| render/navigation | covered | partial | covered | partial | covered | partial | static + builder tests inventoried | partial |
| submit/state machine | covered | partial | covered | partial | partial | covered for duplicate guard | tests inventoried | partial |
| completion/errors | covered | n/a | covered | partial | partial | partial | static only | partial |
| stop/close | covered | n/a | covered | partial | covered | partial | static only | partial |
| events | partial | n/a | partial | missing | n/a | missing | docs + source | partial |

## UI, navigation, event, and tool-loop supplements

### R10 — Incremental UI builder and formatter state

`lua/codecompanion/interactions/chat/ui/builder.lua:142-365` appends streamed or direct buffer messages incrementally. It derives persistent formatting state, starts a new section when the role changes (or `force_role` is set), starts a new block when `opts.type` changes, selects the first formatter whose `can_handle` accepts the message, writes text at the end or `opts.insert_at`, and synchronizes role/type/reasoning state back to the chat. Buffer writes temporarily unlock the buffer, restore lock for non-user output, preserve cursor-follow state, and schedule tool/reasoning fold creation. `update_line()` rejects invalid/out-of-range 1-based lines and updates status icons when requested.

The baseline formatters are: standard LLM content (including `### Response` after reasoning), reasoning content (a `### Reasoning` section), and tools (status icons, optional fold metadata, and response transitions). These are selected by `MESSAGE_TYPES` rather than inferred solely from message role.

**GIVEN** a response arrives in multiple chunks with changing type  
**WHEN** `add_buf_message` is called for each chunk  
**THEN** the visible buffer preserves section/block boundaries, reasoning-to-response headings, tool status decoration, and persistent formatter state.

### R11 — Manual folds and fold summaries

`lua/codecompanion/interactions/chat/ui/folds.lua:27-319` forces manual folding for the chat window and stores fold summaries by buffer/start row. Tool and context folds receive inline icon extmarks; reasoning folds use a fold summary without an inline extmark. Tool fold summaries switch success/failure icon and highlight when configured failure words occur. Single-line tool output receives an icon extmark but no fold. Fold recreation clears the relevant namespace, removes the exact existing fold, recreates it, and restores the cursor. Cleanup removes stored summaries/namespaces.

**GIVEN** multi-line tool/context/reasoning output and enabled folding  
**WHEN** the builder schedules fold creation  
**THEN** the range is manually folded and `foldtext` renders the type-specific summary; disabled tool folding suppresses tool folds.

### R12 — Keymap navigation and autocmd behavior

Chat keymaps expose next/previous chat, next/previous message heading via Tree-sitter, adapter/model change, code folding, debug, system-prompt/rules controls, and file-under-cursor navigation. Approval controls are removed from target behavior. Next/previous chat hides the current UI and opens the cyclic adjacent buffer while preserving window options. The retained chat buffer autocmd chain updates recency on `BufEnter`, executes Chat input completion on `CompleteDone`, optionally shows schema diagnostics on `CursorMoved`, and validates settings on `InsertLeave`. UI autocmds track cursor movement and save cursor position on `WinLeave`; intro virtual text is cleared on `InsertEnter`.

**GIVEN** a chat buffer is entered or left, or completion/settings events occur  
**WHEN** the relevant autocmd fires  
**THEN** chat recency, cursor tracking, Chat input Command execution and settings diagnostics are updated without changing message semantics.

### R13 — Event translation and payload

`lua/codecompanion/utils/init.lua:8-12` maps internal names to `User` autocmd patterns by prefixing `CodeCompanion`; payload is passed as `nvim_exec_autocmds(..., {data=opts})`. Direct lifecycle payloads are: Created `{bufnr, from_prompt_library, id}`, Opened/Hidden/Done/Stopped/Closed `{bufnr,id}`, Submitted `{bufnr,id,type}`. HTTP request events additionally carry request `id`, adapter `{name, formatted_name, model}`, and interaction context where supplied; `RequestFinished` carries status in the request path. Tool events carry `id`, `bufnr`, and tool/name fields. Event listener failures are delegated to Neovim autocmd execution; no plugin-level isolation guarantee was evidenced.

### R14 — Tool-loop boundary

`lua/codecompanion/interactions/chat/tools/orchestrator.lua:233-455` is baseline queue/event evidence. The target emits ToolBatch/ToolCall events around automatic execution, supports cancellation, records output/error, and advances according to `tool-runtime`. Approval/rejection UI is removed. Completion of all tools returns through the coordinator boundary before continuation is decided.

## R15 — Remaining high-value boundary findings

### Complete baseline chat keymap inventory

Baseline public Chat mappings include options/completion/send/regenerate/close/stop/clear, codeblock/yank, buffer sync, Chat/header navigation, provider change, folds/debug, system prompt/rules, file navigation and provider statistics. Target mapping ownership belongs to `chat-ui` and `actions-commands-target`; approval/permission/yolo controls and ACP permission mappings are removed.

### Request/error/stop/close static validation

The executable upstream test command remains blocked by dependency bootstrap, but baseline static validation confirms: HTTP request events are fired at start, first stream chunk, and finish; HTTP stream errors set error status and call the callback (`lua/codecompanion/http.lua:380-470`). `Chat:_submit_http()` suppresses late transport errors when status is cancelling, sets `STATUS_ERROR`, logs, and enters `done()` (`chat/init.lua:1065-1092`). `Chat:stop()` sets `cancelling`, emits `ChatStopped`, cancels tool/request best-effort, then schedules stopped completion; `Chat:close()` stops active work, emits `ChatClosed`, removes metadata, deletes the buffer, and clears autocmds. No baseline test proves event ordering or duplicate callbacks.

### Cross-provider tool continuation

Provider-independent continuation meets at `Chat:done()`: formatted provider tool calls are inserted as invisible LLM messages and passed to `self.tools:execute`; the tools coordinator emits lifecycle events and, after the queue is exhausted, fires `ToolsFinished` (`chat/init.lua:1228-1271`; `tools/orchestrator.lua:233-455`; `tools/init.lua:300-325`). The target replaces callback/subscriber ambiguity with one `request-orchestrator` continuation decision after persisted tool-batch completion.

### Event listener failure isolation

`utils.fire()` directly calls `nvim_exec_autocmds("User", {pattern=..., data=...})` with no `pcall` or per-listener isolation (`lua/codecompanion/utils/init.lua:8-12`). The event docs expose User autocmd consumption and payloads (`doc/usage/events.md:10-92`). Thus listener failure isolation is delegated to Neovim's autocmd execution semantics; the plugin does not guarantee that one failing listener cannot affect the caller. This is observed behavior, not a recommendation.

## Revised coverage gaps / unresolved questions

1. No executable lifecycle test passed: dependency bootstrap failed for `mini.nvim` with `OpenSSL SSL_read ... unexpected eof while reading`.
2. Supported-provider process/stream exit racing with `Chat:stop()` or `Chat:close()` requires duplicate callback/event tests.
3. The public/private keymap inventory is complete for the baseline default configuration, but user overrides and disabled-keymap filtering are not covered.
4. Cross-provider tool continuation is only statically traced; supported protocol tool-call re-submit lacks an end-to-end replacement fixture.
5. Event listener failure propagation depends on Neovim `nvim_exec_autocmds` runtime behavior and was not executed in a passing test.

## Validation plan
## Validation plan
- Baseline identity/static checks completed against checkout HEAD `558518f8d78a44198cd428f6bf8bf48bfa38d76d`; cited paths were inspected at that commit.
- Keymap exports and default configured lhs mappings were enumerated from `lua/codecompanion/interactions/chat/keymaps/init.lua` and `lua/codecompanion/config.lua:486-683`.
- Request/error/stop/close, provider exit, tool continuation, and event-listener behavior were statically traced through the cited baseline source.
- Re-run `FILE=tests/interactions/chat/test_chat.lua make test_file`, `test_subscribers.lua`, and `ui/test_builder_state.lua` when `deps/mini.nvim` is available; current attempt is blocked by the recorded clone error.
- Keep latest-upstream and SuperMax adaptation work in separate artifacts; do not amend this baseline section with either.

## Source trace

All source traces above refer to `olimorris/codecompanion.nvim` at `558518f8d78a44198cd428f6bf8bf48bfa38d76d` (`v18.7.0`). No latest-upstream or downstream patch evidence was used as behavior authority.
