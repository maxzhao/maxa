---
title: CodeCompanion.nvim events and public integration reverse specification
kind: module-spec
authority: draft
status: partial
target_disposition: retained-and-redefined-by-events-status
module: events-integration
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
version: v18.7.0
sources:
  - ~/.local/share/nvim/lazy/codecompanion.nvim
  - lua/codecompanion/utils/init.lua
  - lua/codecompanion/interactions/chat/init.lua
  - lua/codecompanion/interactions/chat/ui/init.lua
  - lua/codecompanion/http.lua
  - lua/codecompanion/interactions/chat/tools/init.lua
  - lua/codecompanion/interactions/chat/tools/orchestrator.lua
  - lua/codecompanion/interactions/chat/tool_registry.lua
  - lua/codecompanion/providers/completion/init.lua
  - lua/codecompanion/interactions/chat/helpers/wait.lua
  - tests/interactions/chat/helpers/test_wait.lua
  - Makefile
---

> **Target disposition:** This file is upstream event evidence. Normative target events belong to `events-status`. ACP, inline/diff interaction, approval waiting, and standalone `CodeCompanionCmd` behavior are removed and must not become target requirements.

# CodeCompanion.nvim events and public integration reverse specification

## Authority and scope

This is an evidence-backed brownfield extraction, not a target design. All behavior below is constrained to commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d`; current SuperMax hooks and latest upstream are excluded.

## R1 — Event registration and dispatch bridge

**Requirement:** The public integration boundary SHALL expose User autocmds named by prefixing the supplied event with `CodeCompanion`. `utils.fire(event, opts?)` SHALL default `opts` to `{}` and synchronously call `vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanion" .. event, data = opts })`.

**GIVEN** a loaded `codecompanion.utils` module and an event string `E`
**WHEN** `utils.fire(E, payload)` executes
**THEN** Neovim receives one `User` autocmd dispatch with pattern `CodeCompanion..E` and `event.data == payload`.

**GIVEN** `opts == nil`
**WHEN** `utils.fire(E)` executes
**THEN** the dispatched data is a new empty table (the function's `opts = opts or {}` behavior).

Trace: `lua/codecompanion/utils/init.lua:7-12` at baseline.

## R2 — Event payload transport and failure boundary

**Requirement:** Payloads are arbitrary Lua tables supplied by each caller; there is no central schema validation, serialization, result, or return-value contract. The dispatch call is not wrapped by `pcall` in `utils.fire`.

**GIVEN** a User autocmd listener matching the pattern
**WHEN** the listener raises an error
**THEN** this module provides no local listener-isolation guarantee; exact Neovim propagation and impact on sibling listeners require runtime validation.

**Status:** source-confirmed for absence of isolation; runtime failure behavior is an open validation gap, not an inferred success/failure claim.

Trace: `lua/codecompanion/utils/init.lua:7-12`.

## R3 — Chat lifecycle event timing

The following synchronous emissions are source-confirmed:

| Event | Payload | Timing |
| --- | --- | --- |
| `CodeCompanionChatAdapter` | `{ adapter = safe_adapter, bufnr, id }` | chat initialization after adapter resolution; also adapter changes and close with `adapter=nil` |
| `CodeCompanionChatModel` | `{ adapter = safe_adapter, model, bufnr, id }` | chat initialization/model update; close emits `{ model=nil, id, bufnr }` |
| `CodeCompanionChatCreated` | `{ bufnr, from_prompt_library, id }` | after `dispatch("on_created")`, before optional `auto_submit` |
| `CodeCompanionChatOpened` | `{ bufnr, id }` | UI open completes setup/folds/cursor handling |
| `CodeCompanionChatHidden` | `{ bufnr, id }` | UI hide command/API completes |
| `CodeCompanionChatSubmitted` | `{ bufnr, id, type=adapter.type }` | after dispatching `on_submitted` and starting provider submission |
| `CodeCompanionChatDone` | `{ bufnr, id }` | after response is made ready and `on_completed` is dispatched |
| `CodeCompanionChatStopped` | `{ bufnr, id }` | at start of `Chat:stop`, before cancellation handles are invoked |
| `CodeCompanionChatClosed` | `{ bufnr, id }` | after close dispatch callback and edit cleanup, before adapter/model nil events |
| `CodeCompanionChatCleared` | `{ bufnr, id }` | clear operation completion path |

**GIVEN** `chat:close()` has an active request
**WHEN** close executes
**THEN** it first calls `stop()`, then emits close and clears adapter/model integrations.

Traces: `lua/codecompanion/interactions/chat/init.lua:481-489, 629, 686, 724, 1175, 1271, 1446, 1492-1494, 1616`; `lua/codecompanion/interactions/chat/ui/init.lua:313,341`.

## R4 — Request and streaming event timing

**Baseline evidence:** HTTP transports emit request events with transport-specific options. Non-silent requests emit `RequestStarted` before the request method and `RequestFinished` after adapter `on_exit`/`teardown`; streaming paths emit `RequestStreaming` for chunks and finish on terminal paths. Target protocol adapters map these boundaries into typed events.

**GIVEN** HTTP `opts.silent` is false/nil
**WHEN** request starts and later exits
**THEN** `CodeCompanionRequestStarted` precedes the method call and `CodeCompanionRequestFinished` follows adapter cleanup.

**GIVEN** a streaming transport callback
**WHEN** a chunk is processed
**THEN** `CodeCompanionRequestStreaming` is emitted with the transport options; terminal success/error/cancel paths emit `RequestFinished` where source path specifies it.

HTTP initial payload includes `{ id=tostring(math.random(10000000)), adapter={name, formatted_name, model} }`; later streaming options may contain adapter/request-specific fields. User-configured `self.user_args.event` is fired through the same bridge on supported HTTP paths.

Trace: `lua/codecompanion/http.lua:235-280,394-466`.

## R5 — Tool and Chat edit integration events

| Event | Payload / state | Trace |
| --- | --- | --- |
| `CodeCompanionToolsStarted` / `ToolsFinished` | `{id?, bufnr}` | `interactions/chat/tools/init.lua:86,140,310,319` |
| `CodeCompanionToolStarted` | `{id, tool=name, bufnr}` | `tools/orchestrator.lua:345` |
| `CodeCompanionToolFinished` | `{id, name=tool.name, bufnr}` | `tools/orchestrator.lua:427` |
| `CodeCompanionChatToolAdded` | `{bufnr=chat.bufnr,id=chat.id,tool}` | `tool_registry.lua:109` |
| `CodeCompanionCodeCompanionEditRegistered` | edit tracker payload | `interactions/chat/edit_tracker.lua:474,542` |

The edit event name is notable: `utils.fire("CodeCompanionEditRegistered", ...)` becomes `CodeCompanionCodeCompanionEditRegistered`; this is source behavior, not normalized here.

## R6 — Internal listeners are ordinary User autocmds

**Baseline evidence:** Internal integration components register `User` autocmds with patterns and callback predicates, commonly filtering `args.data.bufnr`, `id`, or `session_id`. Retained examples include tool configuration refresh on `ChatModel` and completion adapter cache on `ChatAdapter`/`ChatModel`. Target listeners consume typed runtime events and isolate failures.

**GIVEN** an event has a nonmatching buffer/session/id
**WHEN** an internal listener runs
**THEN** it returns without changing that component's state.

**GIVEN** `wait.for_decision(id, events, callback)` is active
**WHEN** a matching User event arrives with `event.data.id == id`
**THEN** it calls the callback once, reports acceptance iff `event.match == events[1]`, includes `{accepted,event,data}`, and clears its autocmd group. Wrong IDs are ignored. Timeout produces `{accepted=false, timeout=true}`.

Trace: `interactions/chat/helpers/wait.lua:15-72`; `tests/interactions/chat/helpers/test_wait.lua:45-170`; retained tool/completion listener paths listed above. Approval-decision waiting is baseline-only because target tools execute automatically.

## R7 — Public Lua and command boundary

**Baseline evidence:** `require("codecompanion")` exposes setup, Chat, prompt/add and extension helpers. Target compatibility retains only APIs required by Chat, Actions/Commands and extensions during migration; inline helpers are removed.

`CodeCompanion.setup(opts?)` is baseline setup evidence. Target migration retains Chat, Actions and History entrypoints and removes the standalone `CodeCompanionCmd` conversational entry; target Commands remain runtime operations rather than that interaction mode.

**GIVEN** setup receives options
**WHEN** setup runs
**THEN** command definitions are registered and configuration/completion/logging initialization is attempted; completion-provider load failure is warned and does not use a hard error path.

Trace: `lua/codecompanion/init.lua:22-109,370-420`; `lua/codecompanion/commands.lua:35,122,251,262`.

## Configuration

- Event consumers configure ordinary Neovim `User` autocmds and match exact `CodeCompanion...` patterns or wildcards such as `CodeCompanionTools*`.
- `utils.fire` has no event registry or enable/disable setting.
- HTTP request events are suppressed by `opts.silent`; chat lifecycle events have no equivalent global suppression in the traced call sites.
- `wait.for_decision` timeout defaults to `config.interactions.chat.opts.wait_timeout`, otherwise `30000` ms.
- Commands are registered during `CodeCompanion.setup`, not by the event bridge itself.

## State, ordering, concurrency, and idempotency

- Dispatch is synchronous at the `utils.fire` boundary; transport callbacks, `vim.schedule`, and `vim.defer_fn` introduce asynchronous interleavings. Target events isolate listener failures and reject stale callbacks by runtime identity.
- Chat creation emits creation before `auto_submit`; stop emits before cancellation; close emits close before adapter/model nil notifications.
- `wait.for_decision` uses `decision_made` to make callback/cleanup one-shot across decision and timeout races.
- No central event queue, sequence number, replay, deduplication, or idempotency guarantee is evidenced.

## Failure and edge behavior

- No `pcall` surrounds `utils.fire`; listener-error isolation is not guaranteed by this wrapper.
- `utils.fire` accepts arbitrary event strings, including names that already contain `CodeCompanion`.
- Missing payload becomes `{}`; payload fields are not normalized.
- A silent HTTP request suppresses standard request start/finish events.
- Source does not establish whether a throwing User autocmd aborts sibling listeners or transport callback execution; this remains a runtime gap.

## Validation and evidence

### Executed

- Baseline identity: `git -C ~/.local/share/nvim/lazy/codecompanion.nvim rev-parse HEAD` returned `558518f8d78a44198cd428f6bf8bf48bfa38d76d`; `git show -s` returned release `18.7.0`, commit time `2026-02-18T08:00:51Z`.
- Static trace: `rg -n 'utils\\.fire\\(' lua/codecompanion` inventoried retained Chat, HTTP, tool, edit-tracking and completion call sites. Removed interaction event families are excluded from target requirements.
- Existing focused test source read: `tests/interactions/chat/helpers/test_wait.lua` covers matching/wrong-id/timeout/cleanup behavior using `nvim_exec_autocmds("User", {pattern,data})`.

### Blocked / not run

- `make test` was not run. The baseline `Makefile:test` depends on `deps` cloning external repositories (`deps/plenary.nvim`, `deps/nvim-treesitter`, `deps/mini.nvim`, `deps/panvimdoc`), and this extraction did not establish a network-backed test environment. Therefore no automated test result is claimed.
- Listener throwing/failure isolation has no dedicated baseline test found in the inspected tests; runtime behavior remains unverified.

## Behavior coverage audit

| Dimension | Status | Evidence / gap |
| --- | --- | --- |
| Normal event dispatch | covered | `utils.fire`; all direct call-site families inventoried |
| Payload/state effects | partial | payloads and key internal consumers traced; no central schema exists |
| Failure/edge | partial | silent requests, nil payload, wrong IDs, timeout traced; throwing listener unverified |
| External dependency | partial | Neovim User autocmd API and transport callbacks traced |
| Concurrency/idempotency | partial | schedule/defer and one-shot decision cleanup traced; cross-transport races untested |
| Public Lua/command boundary | partial | exports and setup registration traced; all command callback semantics not fully read |
| Validation | partial | focused test source read; full suite not run |

## Open gaps

1. Execute the baseline test suite in a checkout with all Makefile dependencies available.
2. Add/run a focused Neovim probe for a throwing User autocmd and sibling-listener behavior; do not infer isolation from source absence.
3. Read every retained Command callback and all four supported protocol terminal branches to produce a complete event sequence matrix.
4. Validate duplicate registration/repeated setup behavior and event behavior during teardown.

## Source trace index

- Event bridge: `lua/codecompanion/utils/init.lua:7-12`.
- Chat lifecycle: `lua/codecompanion/interactions/chat/init.lua:481-489,629,686,724,1175,1271,1446,1492-1494,1616`.
- UI: `lua/codecompanion/interactions/chat/ui/init.lua:313,341`.
- HTTP: `lua/codecompanion/http.lua:235-280,394-466`.
- Tool system/orchestrator/registry: `lua/codecompanion/interactions/chat/tools/init.lua:86,140,203-245,310,319`; `tools/orchestrator.lua:235,345,427`; `tool_registry.lua:109`.
- Diff providers: `lua/codecompanion/providers/diff/{split,mini_diff,inline}.lua`.
- Chat edit tracking: `interactions/chat/edit_tracker.lua:474,542`; only behavior retained by `chat-ui` remains applicable.
- Decision listener: `lua/codecompanion/interactions/chat/helpers/wait.lua:15-72`; tests `tests/interactions/chat/helpers/test_wait.lua:45-170`.
- Public Lua/setup: `lua/codecompanion/init.lua:22-109,370-420`; commands `lua/codecompanion/commands.lua:35,122,251,262`.
