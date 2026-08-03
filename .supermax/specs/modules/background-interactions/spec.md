---
title: CodeCompanion.nvim background interactions reverse specification
created: 2026-08-01
updated: 2026-08-01
type: behavior-spec
doc_role: reverse-spec
authority: draft
status: partial
target_disposition: narrowed-by-async-lifecycle-session-history-events-status
tags: [codecompanion, reverse-engineering, background, v18.7.0]
sources:
  - ~/.local/share/nvim/lazy/codecompanion.nvim@558518f8d78a44198cd428f6bf8bf48bfa38d76d
  - ../../baseline.md
confidence: medium
---

> **Target disposition:** Retain only background behavior required by title/history/status operations. Normative ownership belongs to `async-lifecycle`, `session-history`, and `events-status`; unrelated upstream background interactions are baseline-only.

## 1. Module contract and actors

The background subsystem performs non-blocking, non-chat HTTP LLM requests and attaches caller callbacks. A background instance owns a random numeric `id`, message seed, resolved HTTP adapter, and schema-derived settings. It is intended to fail silently from the user's perspective: implementation logs debug/error/warn messages rather than surfacing normal background failures in the chat UI.

Actors and boundaries:

- Caller: built-in action or user callback module, invokes `Background:ask`.
- Chat: owns callback registration, messages, title state, and `on_ready` dispatch.
- Background: resolves adapter, maps settings/roles, selects sync/async request path, parses response.
- HTTP client: builds/sends request and returns sync response/error or async request handle.
- Adapter: setup, schema, role mapping, parameter/body construction, response handler.
- Neovim scheduler/job: async execution and cancellation boundary.

## 2. Configuration contract

Baseline defaults are in `lua/codecompanion/config.lua:58-78` at the pinned commit:

```lua
interactions = {
  background = {
    adapter = { name = "copilot", model = "gpt-4.1" },
    chat = {
      callbacks = {
        on_ready = {
          actions = { "interactions.background.builtin.chat_make_title" },
          enabled = true,
        },
      },
      opts = { enabled = false },
    },
  },
}
```

Docs state background interactions are opt-in, may use a cheaper/different provider, and require explicit provider configuration (`doc/getting-started.md:88-105`, `doc/usage/chat-buffer/index.md:77-105`, `doc/codecompanion.txt:3104-3117`). Target background operations use only the four supported protocols and are owned by session/history/status features.

### Requirement BG-CFG-1 — general and per-event enablement

- GIVEN `config.interactions.background.chat` is absent, or `opts.enabled == false`
- WHEN a chat is initialized
- THEN no configured background chat callbacks are registered.
- GIVEN general background chat enablement is true
- WHEN each configured event has `enabled` truthy and a non-empty `actions` list
- THEN one callback is registered for that event.
- GIVEN event enablement is false or actions is absent
- THEN that event is not registered.

Trace: `lua/codecompanion/interactions/background/callbacks.lua:186-203`; registration call `lua/codecompanion/interactions/chat/init.lua:625`.

### Requirement BG-CFG-2 — adapter resolution and HTTP-only gate

- GIVEN an explicit already-resolved adapter
- WHEN `Background.new(args)` runs
- THEN it uses that adapter.
- GIVEN an adapter name/config or no adapter
- THEN it resolves the explicit value or `config.interactions.background.adapter`.
- IF no adapter resolves, the constructor logs debug and returns nil.
- IF the adapter type is not `http`, it logs a warning and returns nil.
- Otherwise it derives settings with `schema.get_default(adapter, args.settings)`, maps settings to parameters, and returns the instance.

Trace: `lua/codecompanion/interactions/background/init.lua:39-59`.

## 3. Request operations

### Requirement BG-ASK-1 — synchronous non-streaming request

- GIVEN a valid HTTP background instance
- WHEN `background:ask(messages, { method = "sync", silent = ... })` is called
- THEN it creates an HTTP client, deep-copies the message list, maps roles, sends a synchronous payload `{ messages = mapped_messages }`, and returns parsed adapter output plus nil error.
- The default parse handler is `parse_chat`; `opts.parse_handler` overrides it.
- HTTP errors return `nil, err` and are debug logged.
- `ask_sync` rejects a non-HTTP adapter with `{ message = "[background::init] ask_sync only supports HTTP adapters" }`.

Trace: `init.lua:61-83`; HTTP sync build/transport `lua/codecompanion/http.lua:166-277`.

### Requirement BG-ASK-2 — asynchronous request and parsed callback

- GIVEN a valid HTTP background instance
- WHEN `background:ask(messages, { on_done = callback, ... })` is called without `method = "sync"`
- THEN async mode is selected and missing `on_done` raises the assertion `on_done callback is required for ask_async`.
- The background deep-copies the adapter and forces `adapter.opts.stream = false` when `opts` exists, then deep-copies/maps messages into the payload.
- The supplied completion callback is wrapped: an absent response/body invokes the original callback with nil and metadata; a body is parsed using the selected handler and the parsed result is passed with metadata.
- The return value is the HTTP `RequestHandle`.

Trace: `init.lua:85-123`; request handle contract `lua/codecompanion/http.lua:61-164`.

### Requirement BG-ASK-3 — payload and adapter transformation

Background requests inherit adapter setup/schema/parameter/body construction and environment substitution from the HTTP client. The adapter role mapping occurs before HTTP construction; later HTTP construction invokes adapter handlers (`setup`, `build_parameters`, `build_messages`, `build_tools`, `build_body`) and adapter method/URL/header settings.

Trace: `init.lua:71-75,97-113`; `http.lua:177-239,302-350`.

## 4. Async state, callbacks, errors, cancellation

The HTTP handle has `id`, `job`, `cancel()`, and `status()`. Its states are `pending`, `streaming`, `success`, `error`, `cancelled` (`http.lua:61-68`). Background forces non-streaming on its copied adapter, so the normal background completion path is a non-streaming response. HTTP transport errors set `error` and call `on_error(err, meta)`. A non-streaming successful response sets `success` and calls `on_done(response, meta)`; an HTTP status >= 400 is not completed as success in `Client:send` and is handled by the lower request callback/error path.

Cancellation calls `job:shutdown()` inside `pcall`, sets `cancelled`, and returns true when a shutdown-capable job exists; otherwise returns false. No background-specific cancellation callback or chat state mutation is specified. A race between cancellation and a queued completion is not covered by baseline tests and must remain an open behavior question.

`silent` suppresses HTTP request start/finish events in the HTTP layer; it does not suppress background debug/error logging. Built-in title generation uses `silent = true`.

### Failure matrix

| Failure | Baseline outcome | Evidence |
| --- | --- | --- |
| adapter absent | constructor nil; debug log | `background/init.lua:45-52` |
| adapter non-HTTP | constructor nil; warning | `background/init.lua:54-55` |
| sync non-HTTP | nil + structured error | `background/init.lua:66-70` |
| sync transport/error | nil + `err`; debug log | `background/init.lua:76-79` |
| async missing `on_done` | assertion | `background/init.lua:90-92` |
| async response/body absent | caller gets nil, meta | `background/init.lua:104-107` |
| callback module missing | error log; no request | `callbacks.lua:156-160` |
| callback module lacks `request` | error log; no request | `callbacks.lua:161-163` |
| callback Background cannot initialize | debug log; scheduled action skipped | `callbacks.lua:164-172` |
| action request throws | protected; debug log | `callbacks.lua:173-180` |
| title result missing/error/empty | no title mutation | `chat_make_title.lua:230-241` |
| HTTP request cancellation | handle state becomes cancelled if shutdown exists | `http.lua:145-160` |

## 5. Chat callback operation

### Requirement BG-CB-1 — registration and dispatch

During chat construction, `register_chat_callbacks(self)` is called after built-in chat callbacks are installed and before `on_created` dispatch (`chat/init.lua:614-629`). For every enabled configured event with actions, the subsystem adds a chat callback. On dispatch, each action path is executed in list order; each action is independently scheduled with `vim.schedule`, so action request work does not block the dispatching thread.

Chat callback dispatch itself wraps each callback in `pcall` and logs callback errors silently (`chat/init.lua:651-668`). The background action wrapper separately protects `action.request` with `pcall` (`callbacks.lua:174-180`).

### Requirement BG-CB-2 — callback module resolution

For an action path, resolution tries (in order): `require("codecompanion." .. path)`, `require(path)`, then `loadfile(vim.fs.normalize(path))` and executes the loaded chunk. Failure to resolve is logged and stops that action only. This permits bundled module paths, user Lua module paths, and file paths.

Trace: `callbacks.lua:130-151`.

### Requirement BG-CB-3 — per-event action execution

On event dispatch, the registered callback logs action count/event, then schedules each action. Each scheduled action creates a new Background using the configured background adapter and calls `action.request(background, chat)`. Successful action return is debug logged; return values are not propagated.

Trace: `callbacks.lua:156-203`.

## 6. Built-in title generation

### Requirement BG-TITLE-1 — trigger and idempotency

When the chat reaches `ready_chat_buffer` after a non-auto-submit cycle and dispatches `on_ready`, the configured title action may run (`chat/init.lua:230-244`). `chat_make_title.request` returns immediately if `chat.title` is already non-empty. Otherwise it starts an async silent background request.

Trace: `chat/init.lua:233-242`; `chat_make_title.lua:243-279`.

### Requirement BG-TITLE-2 — title request input

The title request sends two messages:

1. A system instruction requiring a concise title, max 50 characters, core user intent, raw text only, and no quotation marks/markdown/prefixes.
2. A user message containing `<conversation>...</conversation>` and formatted chat messages.

Formatting emits `## <role>\n<content>` joined by blank lines. Messages tagged `_meta.tag == "rules"` or `"system_prompt_from_config"` are omitted. Image-tagged messages become `[Image content omitted]`. Untagged content is included verbatim.

Trace: `chat_make_title.lua:209-228,250-264`.

### Requirement BG-TITLE-3 — title result and state effect

`on_done(result)` returns nil for nil/error-status results. Otherwise it reads `result.output.content`, trims surrounding whitespace and one optional matching quote boundary via the baseline pattern, and returns nil for empty output. On a non-empty title, the request callback calls `chat:set_title(title)`. It emits no chat message; only chat title state changes, with a debug log. The source contains a TODO to remove the callback from the chat buffer, so callback persistence/removal is unresolved in this baseline.

Trace: `chat_make_title.lua:230-241,265-279`.

## 7. Concurrency and lifecycle

- Multiple enabled actions for one event are scheduled independently and may overlap.
- Each action receives a distinct Background instance; no deduplication, queue, lock, or generation check is present.
- Title idempotency is checked before request creation only. Concurrent title requests can therefore race if the title remains empty until completion.
- A late title callback can mutate a chat after close unless the HTTP/job lifecycle or `set_title` adds protection elsewhere; this module does not check chat validity. This is an evidence-based open risk, not a confirmed user-visible outcome.
- Background instances are not stored by callback registration; handles are not retained by the built-in title action, so caller-level cancellation is unavailable there.

## 8. External dependencies and data constraints

Required runtime dependencies include Neovim `vim.deepcopy`, `vim.schedule`, `vim.fs.normalize`, adapter resolver/schema/handler APIs, HTTP client transport, configured HTTP endpoint/credentials, and chat callback/title APIs. Sync transport uses temporary JSON body files and curl-like request options including retry `3`, retry delay `1`, keepalive `60`, connect timeout `10`; exact adapter/network behavior remains delegated to `http.lua` and adapter handlers.

Message inputs are tables with role/content fields as consumed by adapter role mapping and title formatting. The title prompt says max 50 characters, but baseline code does not enforce that limit after receiving output.

## 9. Validation evidence

### Identity/static validation — passed

Commands and results:

```text
rg -n '"codecompanion.nvim"' lazy-lock.json
=> lazy-lock.json:12 commit 558518f8d78a44198cd428f6bf8bf48bfa38d76d

GIT_PAGER=cat git -C ~/.local/share/nvim/lazy/codecompanion.nvim rev-parse HEAD
=> 558518f8d78a44198cd428f6bf8bf48bfa38d76d

GIT_PAGER=cat git -C ~/.local/share/nvim/lazy/codecompanion.nvim show 558518f8d78a44198cd428f6bf8bf48bfa38d76d:version.txt
=> 18.7.0

GIT_PAGER=cat git -C ~/.local/share/nvim/lazy/codecompanion.nvim show -s --format='%H%n%cI%n%D' 558518f8d78a44198cd428f6bf8bf48bfa38d76d
=> 558518f8d78a44198cd428f6bf8bf48bfa38d76d
=> 2026-02-18T08:00:51Z
=> HEAD, tag: v18.7.0
```

### Upstream test validation — blocked

Attempted:

```text
cd ~/.local/share/nvim/lazy/codecompanion.nvim
make FILE=tests/interactions/background/test_background.lua test_file
```

Observed exact blocker:

```text
E5113: Error while calling lua chunk: .../codecompanion.nvim/scripts/minimal_init.lua:7: module 'mini.test' not found:
no field package.preload['mini.test']
no file './mini/test.lua'
no file '/home/linuxbrew/.linuxbrew/share/luajit-2.1/mini/test.lua'
no file '/usr/local/share/lua/5.1/mini/test.lua'
no file '/usr/local/share/lua/5.1/mini/test/init.lua'
no file '/home/linuxbrew/.linuxbrew/share/lua/5.1/mini/test.lua'
no file '/home/linuxbrew/.linuxbrew/share/lua/5.1/mini/test/init.lua'
no file './mini/test.so'
no file '/usr/local/lib/lua/5.1/mini/test.so'
no file '/home/linuxbrew/.linuxbrew/lib/lua/5.1/mini/test.so'
no file '/usr/local/lib/lua/5.1/loadall.lua'
no file '/home/linuxbrew/.linuxbrew/lib/lua/5.1/loadall.lua'
no file './mini.so'
no file '/usr/local/lib/lua/5.1/mini.so'
no file '/home/linuxbrew/.linuxbrew/lib/lua/5.1/mini.so'
no file '/usr/local/lib/lua/5.1/loadall.so'
E5108: Error executing command: attempt to index global 'MiniTest' (a nil value)
```

The command was terminated by the session timeout after Neovim reported the dependency error; no test pass is claimed. Relevant baseline tests inspected: `tests/interactions/background/test_background.lua` (sync success/error, async success), `test_callbacks.lua` (enabled/disabled registration), `catalog/test_chat_make_title.lua` (formatting and result parsing). The inspected tests do not cover cancellation, callback module loading/execution failures, title request integration, races, or external transport.

## 10. Coverage audit and open gaps

| Dimension | Status | Evidence/gap |
| --- | --- | --- |
| Entrypoints and operations | covered | `background/init.lua`, callbacks, title action |
| Normal request behavior | covered statically; partial dynamically | background tests inspected; runner blocked |
| Configuration/disabled behavior | covered | config + callback tests/docs |
| State/data effects | partial | title setter traced; HTTP state traced; end-to-end title not tested |
| Failures | partial | source branches traced; many runtime branches untested |
| Cancellation | partial | HTTP handle traced; no background-specific cancellation test |
| External dependency behavior | partial | HTTP and adapter boundary traced; no live/mock suite execution |
| Concurrency/idempotency | partial/open | scheduling and title guard traced; races untested |
| Docs alignment | covered | getting-started/chat-buffer/vim help traced |
| Validation | blocked | missing `mini.test` exact error above |

Open questions are deliberately retained: whether HTTP status >=400 reaches background `on_error` through all adapter/request paths; whether `chat:set_title` rejects invalid/closed buffers; whether scheduled callbacks can run after cancellation; whether title callback registration is removed elsewhere; and whether prompt max-length is enforced by any adapter.

## 11. Source trace index (pinned baseline)

- `lua/codecompanion/interactions/background/init.lua:1-125` — constructor, sync/async ask, parse and logging.
- `lua/codecompanion/interactions/background/callbacks.lua:1-204` — path resolution, registration, scheduled action execution.
- `lua/codecompanion/interactions/background/builtin/chat_make_title.lua:1-281` — formatting, title prompt, result parse, title mutation.
- `lua/codecompanion/interactions/chat/init.lua:230-244` — `on_ready` trigger; `590-629` — callback setup/registration; `637-668` — callback dispatch isolation.
- `lua/codecompanion/http.lua:61-164` — async RequestHandle states/callbacks/cancel; `166-277` — sync request; `283-475` — transport callback/error lifecycle.
- `lua/codecompanion/config.lua:58-78` — background defaults.
- `doc/getting-started.md:88-105` — adapter/config semantics.
- `doc/usage/chat-buffer/index.md:77-105` — title setup and opt-in docs.
- `doc/codecompanion.txt:300-345,3104-3117` — Vim help background overview/config/title docs.
- `tests/interactions/background/test_background.lua:1-104` — sync/async tests.
- `tests/interactions/background/test_callbacks.lua:1-75` — registration tests.
- `tests/interactions/background/catalog/test_chat_make_title.lua:1-38` — format/result tests.
