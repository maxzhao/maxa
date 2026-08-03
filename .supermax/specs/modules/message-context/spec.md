---
title: CodeCompanion 消息与上下文模型反推规格（v18.7.0）
created: 2026-08-01
updated: 2026-08-01
type: module
doc_role: reverse-spec
authority: draft
status: partial
target_disposition: retained-and-redefined-by-message-context-target-supermax-configuration
tags: [codecompanion, reverse-engineering, message-context, v18.7.0]
sources:
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/init.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/parser.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/context.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/variables/init.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/variables/buffer.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/rules/init.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/rules/helpers.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/rules/parsers/init.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/interactions/chat/rules/parsers/codecompanion.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/http.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/doc/usage/chat-buffer/variables.md
  - ~/.local/share/nvim/lazy/codecompanion.nvim/doc/usage/chat-buffer/slash-commands.md
  - ~/.local/share/nvim/lazy/codecompanion.nvim/doc/usage/chat-buffer/rules.md
  - ~/.local/share/nvim/lazy/codecompanion.nvim/tests/interactions/chat/test_variables.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/tests/interactions/chat/test_context.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/tests/interactions/chat/rules/test_rules.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/tests/interactions/chat/rules/parsers/test_codecompanion_parser.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/tests/interactions/chat/slash_commands/basic.lua
confidence: medium
---

> **Target disposition:** This file is upstream evidence. Normative behavior belongs to `message-context-target` and `supermax-configuration`; provider payload shapes and unsupported upstream surfaces are not target requirements.

> **TLDR**: v18.7.0 从 chat Markdown buffer 解析最后用户消息，按提交顺序移除可见 Context 块、解析并执行变量/工具、校验 Context 引用，然后把消息表经 adapter `map_roles` 映射为 `{messages, tools}` payload；HTTP client 再调用 adapter 的 `build_*` handlers 生成请求 body。该草案已覆盖主链，但 slash command 内置行为、所有 adapter message builders 与完整测试执行仍存在缺口。

## Scope and authority

- **Baseline**: `558518f8d78a44198cd428f6bf8bf48bfa38d76d` / `v18.7.0`; checkout HEAD verified to this commit.
- **In scope**: roles/messages, chat-buffer parsing, context insertion/removal, variables, rules, slash-command dispatch and context mutation, provider payload boundary and chat-buffer rendering.
- **Out of scope**: SuperMax downstream patches, latest-upstream behavior, independent-runtime target requirements.
- **Status**: `partial`; this is evidence-backed reverse extraction, not normative target design.

## Behavior model

### Message records and two outputs

A chat has a persistent `messages` stack and a separate visible buffer rendering. `Chat:add_message` creates `{role, content, reasoning?, opts, _meta}`; `tool_calls` is normalized to `message.tools.calls`; optional `context` is linked to the message; `_meta` receives an id, cycle and index. `add_buf_message` renders UI-only content and explicitly does not add to the LLM message stack. (`interactions/chat/init.lua:910-954`, `1520-1529`)

### Submit pipeline

1. `Chat:submit` rejects a concurrent request when `current_request` exists.
2. For normal submit, `parser.messages` parses the last user section from Markdown using Tree-sitter, joins content with blank lines, strips Context markup, trims, and returns nil for empty content.
3. The user message is inserted unless regenerating; configured prompt decorator may transform it.
4. `context:remove` removes the rendered Context block from the message content. `replace_vars_and_tools` resolves tagged tools and variables and removes their syntax. `check_images`, `check_context`, and synced-buffer refresh then mutate message/context state.
5. Payload is built as `adapter:map_roles(vim.deepcopy(self.messages))` plus registered tool schemas: `{ messages = ..., tools = ... }`.
6. HTTP submission maps settings and invokes HTTP client; request body is assembled from adapter `build_parameters`, `build_messages`, `build_tools`, `adapter.body`, and `build_body` using `vim.tbl_extend("keep", ...)`. (`init.lua:1093-1176`, `http.lua:312-325`)

### Context records and UI

Context items contain at least `id` and `source`, optionally `bufnr`, path/params and `opts.sync_all`, `opts.sync_diff`, `opts.visible`. `context:add` refuses absent context or disabled `display.chat.show_context`, defaults sync flags to false and visibility to configured context display, stores the item, optionally starts diff sync, then inserts a `> Context:` block beneath the latest user role or appends to an existing block. (`context.lua:111-173`)

Visible context is UI metadata, not itself the submitted content: `context:remove` strips the Markdown context block before provider processing, while the context-linked message records remain in `self.messages`. `check_context` reconciles IDs present in the buffer with `context_items` and removes stale linked messages and tool schemas. (`context.lua:176-204`; `init.lua:1315-1401`)

After an LLM response, `context:render` re-adds visible items; hidden items are omitted. `fold_context` controls folding. `refresh_context` keeps only message-referenced context and re-renders. (`context.lua:230-289`; `init.lua:1403-1428`)

### Variables

Syntax is `#{name}`, display-target syntax `#{name:target}`, and optional params `#{name}{params}` / `#{name:target}{params}`. Configured variables are scanned; display-target and regular occurrences are recorded without duplicating target matches. `parse` checks `opts.contains_code` against `config.can_send_code`, obtains params only when `opts.has_params`, resolves a configured callback/module (or default user callback), and returns true when any instance was found. `replace` removes non-buffer variable syntax; the buffer variable replaces syntax with a file/buffer description after adding actual context message data. (`variables/init.lua:9-29`, `83-151`, `153-211`)

The built-in buffer variable selects the current context buffer by default, or exact name/relative/short path for a display target; it accepts only `all` or `diff` params. It adds a hidden user message linked to formatted buffer context; `all` suppresses a separate context item and `diff`/normal creates a context item with sync flags. Invalid target/param warns and does not add context. (`variables/buffer.lua:26-49`, `58-113`)

Custom variables use their configured callback through the user variable module, add a hidden user message tagged `variable`, and link a `<var>name</var>` context item. (`variables/user.lua:17-32`)

### Rules

A Rules instance takes `name`, `files`, optional group/file parser and opts. `collect_files` normalizes and de-duplicates literal files/directories, glob matches, and table specs that scan directories with patterns; missing/invalid paths warn or are skipped. `read_files` reads regular files and attaches file-level parser selection. `parse_files` applies file-level parser before group parser; parser errors fall back to original file content. (`rules/init.lua:29-45`, `47-195`; `rules/parsers/init.lua:70-108`)

`add_to_chat` adds parsed rule content as context. A parsed `system_prompt` becomes a hidden system message; user content becomes a hidden user message linked by `<rules>path</rules>`. Included files from parser metadata are recursively added as rules file/buffer context. Duplicate context IDs are not re-added. (`rules/helpers.lua:138-219`)

The built-in CodeCompanion parser extracts a `## System Prompt` section into `system_prompt`, removes `@path` lines from it, and treats other sections as user content while collecting unique `@path` references in metadata. Empty/unparseable content falls back to empty/original content. (`rules/parsers/codecompanion.lua:12-111`)

Rules picker listing filters disabled rules, optional hidden presets, and failed `enabled(chat)` predicates; nested groups flatten to `parent/child` names while inheriting parser/opts/description. Chat autoload resolves string/table/function declarations into on-created callbacks and warns for unknown groups. (`rules/helpers.lua:11-135`)

### Slash-command entry and mutation

Completion inserts a slash command item; `CompleteDone` removes the typed word and invokes `completion.slash_commands_execute`, which dispatches through `SlashCommands:execute`. Function callbacks run directly; string callbacks resolve first as `codecompanion.<callback>`, then user module path, then file path. An optional `enabled(chat)` gate can stop execution with a warning. Otherwise the callback object is instantiated with Chat/config/context and `:execute`d. (`slash_commands/init.lua:5-33`, `60-92`; `interactions/chat/init.lua:277-288`)

Baseline built-ins and observed message/buffer effects:

| Command | Behavior at `builtin/<name>.lua` | Message/context effect |
|---|---|---|
| `/buffer` | Picker/current-buffer selection; formats buffer with line numbers; honors `contains_code`, `default_params`, `sync_all`/`sync_diff`. | Hidden user `add_message`, then Context item unless all-sync. |
| `/file` | Picker/path selection; formats file; optional description; honors code gate and sync options. | Hidden user message tagged `file`, then file Context unless all-sync. |
| `/fetch` | URL choice prompts for URL or cached URL; clones adapter, uses fetch setup/callback, adds `<attachment url="...">...</attachment>` as a hidden user message and `<url>...` Context, then optionally prompts to cache response. Cache may be bypassed or auto-restored. Empty URL/cancel is no-op; missing cache warns; fetch/status errors log. | Hidden user/context payload; no direct visible message except notification. (`builtin/fetch.lua:60-85`, `312-390`, `405-455`) |
| `/symbols` | LSP symbol picker/query and selected file symbol description. | Hidden user message plus `symbols` Context ID; no direct visible message. |
| `/quickfix` | Reads quickfix entries, groups by file/proximity/symbol and formats diagnostic context. | One hidden user message and Context item per processed file. |
| `/rules` | Picker selects configured rules; invokes rules config insertion for selected group(s). | Rule system/user hidden messages and `<rules>...</rules>` Context via Rules helper. |
| `/terminal` | Reads `_G.codecompanion_last_terminal`; tracks prior line count and reads only new output after prompt offset. Adds a hidden user message containing a fenced terminal-output block and notifies. Missing terminal or invalid buffer warns/errors; no separate Context item. (`builtin/terminal.lua:26-64`) |
| `/image` | Picker/path/image selection; adapter `enabled` requires image-capable adapter; calls `Chat:add_image_message`. | Hidden image user message with image context and visible Context entry according to image helper. |
| `/help` | Selects a help tag, reads vimdoc, applies code gate, and for files over the maximum line count prompts whether to trim before adding a formatted hidden user message with tag/path and `<help>tag</help>` Context. | Hidden help context payload plus notification; cancel preserves state. (`builtin/help.lua:60-125`, `send_output`) |
| `/compact` | Confirms via `vim.ui.select({"Yes","No"})`; on Yes sends an async background request containing `<message role="...">...</message>` for user/assistant messages only. On result, renders a summary with `add_buf_message`, then keeps system messages and tagged variable/rules/file user messages while removing LLM and ordinary user messages. Errors are logged; No/cancel does nothing. | Summary is UI-only; retained context messages remain in future payload. (`builtin/compact.lua:99-176`) |
| `/now` | Adds current date/time string directly to buffer. | UI-only `add_buf_message`, never provider payload. (`builtin/now.lua:17-19`) |

The public `SlashCommands.context` helper maps `file`, `buffer`, `symbols`, and `url` to built-ins. A file already open as a buffer is routed to buffer output; file/symbols/url output is silent and adds context/message state. (`slash_commands/init.lua:94-151`). Exact picker UI and asynchronous callback branches remain evidence gaps.

### LSP and viewport variables

`#{lsp}` obtains diagnostics for `Chat.buffer_context.bufnr`, includes severity, LSP message, filetype-tagged fenced code and numbered diagnostic lines, then adds a hidden user message tagged `variable`; it does not add a separate Context item. Diagnostic ranges are inclusive from `lnum` through `end_lnum`, and severity values 1–4 map to `ERROR`, `WARNING`, `INFORMATION`, `HINT`. `#{viewport}` obtains visible editor lines, formats them with `format_viewport_for_llm`, and adds a hidden user message tagged `variable`, also without a separate Context item. (`variables/lsp.lua:17-58`; `variables/viewport.lua:17-35`). Empty diagnostics produce an empty hidden message; exact empty-viewport and unavailable-buffer behavior remain untested.

Picker boundaries: Chat input completion removes the completed word before dispatch; callback selection may be cancelled without mutation. Retained built-ins using `vim.ui.select` treat nil selection as no-op; `/compact` requires explicit `Yes`, while `/help` and `/fetch` have explicit trim/cache choices. (`interactions/chat/init.lua:277-288`; retained compact/help/fetch implementations).

### Rules/parser test-backed observations

The baseline test inventory includes `tests/interactions/chat/test_context.lua`, `tests/interactions/chat/rules/test_rules.lua`, `tests/interactions/chat/rules/parsers/test_parsers.lua`, `test_codecompanion_parser.lua`, and `test_claude_parser.lua`. Static inspection confirms tests assert context IDs, duplicate handling, path normalization, parser outputs, included-file metadata and rules message insertion; test execution was blocked before MiniTest by dependency setup. These are evidence locations, not passing validation.

## Operational requirements and scenarios

### R-MC-001 Parse and submit the last user message

**Requirement**: The system SHALL parse the latest user Markdown section, strip context markup, trim/join content, and insert it into the persistent message stack before constructing payload.

- GIVEN a chat buffer with a user role and content
- WHEN `Chat:submit()` runs without `regenerate`
- THEN one user message is inserted, then context/variable/tool processing occurs before `adapter:map_roles`.
- GIVEN only a context block or no user content
- WHEN submit runs and no prior user messages exist
- THEN it warns `No messages to submit` and does not send a request.
- Evidence: `interactions/chat/parser.lua:69-96`; `interactions/chat/init.lua:1093-1161`.

### R-MC-002 Preserve hidden message state while separating UI output

**Requirement**: The system SHALL distinguish `add_message` records sent to the LLM from `add_buf_message` UI-only records; message visibility is controlled by `opts.visible` and does not imply exclusion from payload.

- GIVEN a hidden context/system/variable message
- WHEN payload is built
- THEN it remains in `self.messages` and is passed to `map_roles`.
- GIVEN a UI-only response/tool rendering
- WHEN payload is built
- THEN it is absent because it was only added through `add_buf_message`.
- Evidence: `init.lua:910-954`, `1520-1529`.

### R-MC-003 Add, strip, render and reconcile context

**Requirement**: Context IDs SHALL link context items, visible Markdown entries, and context-bearing messages; submission SHALL strip visible entries and reconciliation SHALL remove stale IDs.

- GIVEN `show_context=true` and a context item
- WHEN `context:add` runs
- THEN the item is stored and rendered under `> Context:` beneath the user role, subject to visibility.
- GIVEN the user manually removes a rendered context ID
- WHEN `check_context` runs
- THEN linked messages, context items and related tool schemas are removed.
- GIVEN a response completed
- WHEN context renders
- THEN visible items return and hidden ones remain absent.
- Evidence: `context.lua:74-109`, `136-204`, `230-289`; `init.lua:1315-1401`.

### R-MC-004 Resolve variables at submit time

**Requirement**: Variable syntax SHALL be detected and resolved at submit time; resolved content SHALL enter hidden message/context state and syntax SHALL be removed or replaced with a buffer description.

- GIVEN `#{buffer}` or `#{buffer:target}{diff|all}`
- WHEN submit processes the user message
- THEN buffer content is added as hidden context and the original token is replaced by a descriptive file/buffer string; sync semantics follow the parameter.
- GIVEN an invalid buffer target or parameter
- WHEN variable resolution runs
- THEN it warns and does not add corresponding context.
- GIVEN a code-containing variable while code sending is disabled
- WHEN parsing runs
- THEN resolution is skipped with a warning.
- Evidence: `variables/init.lua:153-211`; `variables/buffer.lua:58-159`; `init.lua:986-996`.

### R-MC-005 Resolve custom variables

**Requirement**: A configured custom variable SHALL call its configured callback and add its output as a hidden user message linked to a `<var>name</var>` context ID.

- GIVEN `#{custom}` and a configured callback
- WHEN submit processes variables
- THEN callback output is added as hidden user content and token syntax is removed.
- GIVEN callback/module resolution fails
- WHEN parsing runs
- THEN the resolver logs the failure path; exact thrown-error propagation is not fully covered.
- Evidence: `variables/init.lua:37-69`, `153-189`; `variables/user.lua:17-32`.

### R-MC-006 Process rules into system/user context

**Requirement**: Rules SHALL collect, parse, de-duplicate and add file content to the chat; parser-produced system prompt becomes a hidden system message and remaining content becomes hidden user context.

- GIVEN a valid rules group with literal, directory, glob or table file specs
- WHEN `Rules:make` runs
- THEN normalized unique files are read, parsed, and linked to context IDs.
- GIVEN a CodeCompanion rules file with `## System Prompt` and `@file` lines
- WHEN parsed
- THEN system text is separated, `@file` references are collected, and non-system content remains user context.
- GIVEN missing paths or parser errors
- WHEN processing runs
- THEN paths are skipped/warned and parser failure falls back to original file content.
- Evidence: `rules/init.lua:47-235`; `rules/helpers.lua:142-219`; `rules/parsers/init.lua:74-108`; `rules/parsers/codecompanion.lua:42-109`.

### R-MC-007 Dispatch slash commands

**Requirement**: Slash commands SHALL resolve callbacks from function, built-in module, user module, or file path, apply `enabled` checks, and execute with Chat/config/context.

- GIVEN a completion item with a function callback
- WHEN execution occurs
- THEN callback receives the chat.
- GIVEN a disabled command
- WHEN execution occurs
- THEN it warns and does not instantiate/execute.
- GIVEN an unresolved callback
- WHEN execution occurs
- THEN it logs `Slash command not found` and stops.
- Evidence: `slash_commands/init.lua:5-33`, `60-92`; `init.lua:277-288`.

### R-MC-008 Build provider payload

**Requirement**: The system SHALL deep-copy message state, map roles through the selected adapter, include registered tool schemas when non-empty, and build HTTP body through adapter handlers.

- GIVEN persistent messages with hidden context/system/variable records
- WHEN submit occurs
- THEN mapped payload includes those records; UI-only records do not.
- GIVEN HTTP adapter settings and payload
- WHEN HTTP client sends
- THEN body composition invokes `build_parameters`, `build_messages`, `build_tools`, static body and `build_body`, preserving earlier keys under `tbl_extend("keep")`.
- GIVEN concurrent `current_request`
- WHEN submit occurs
- THEN no second request starts.
- Evidence: `init.lua:998-1176`; `http.lua:166-199`, `312-325`.

## Configuration impact

- `interactions.chat.roles` determines role recognition and message roles.
- `interactions.chat.variables` defines variable names/callbacks and `opts.has_params` / `contains_code` behavior.
- `interactions.chat.slash_commands` controls completion/keymaps and callback configuration.
- `rules`, `rules.parsers`, `rules.opts.chat.enabled/autoload/show_presets/default_params` control rules discovery and insertion.
- `display.chat.show_context`, `fold_context`, `icons`, and `show_settings` affect rendering/diagnostics, not the fundamental hidden message payload.
- `interactions.chat.opts.system_prompt`, `ignore_system_prompt`, `blank_prompt`, and `prompt_decorator` affect system/user message construction.
- `map_roles`, schema mapping, `build_*` handlers, streaming mode, and custom request function determine provider-specific payload/body. Shared role mapping delegates to `utils.adapters.map_roles`; the OpenAI Responses baseline builder separates system messages into `instructions`, converts remaining messages to `input`, preserves reasoning items, handles image-tagged messages when vision is enabled, and transforms tool schemas into `{ tools = ... }` with strict schema conversion. (`adapters/shared.lua:7-12`; `adapters/http/openai_responses.lua:123-...`, `247-...`).

### Additional non-Responses adapter payload difference

Anthropic's baseline `form_messages` removes system messages from the regular array and returns them as structured `system` text blocks; filters message keys to `content`, `role`, `reasoning`, and `tools`; converts ordinary string content to text-block arrays; removes image messages when vision is disabled or converts them to base64 image source blocks when enabled; converts `tool` role to `user` Anthropic `tool_result` blocks and converts assistant tool calls into content blocks. Empty user content becomes `<prompt></prompt>`. Its `form_tools` transforms schemas with `to_anthropic` and adds adapter-native available tools. (`adapters/http/anthropic.lua:153-260`, `380-407`). This differs from OpenAI Responses' `instructions` plus `input` shape and strict tool transformation.

## Failure and edge inventory

- Missing Markdown/YAML Tree-sitter parser prevents normal chat initialization or settings parsing.
- Empty user content / context-only submission warns and does not send absent prior user messages.
- Duplicate context IDs are ignored by rules/context paths; stale IDs are removed by `check_context`.
- Missing rules paths, invalid directory specs, missing parser files and parser factory/errors are warned/logged; parser errors preserve original content.
- Invalid buffer variable target/params warn; code-containing variables can be skipped by config.
- Unknown slash callback, disabled slash command, missing provider, and callback errors are logged/warned; exact UI notification semantics need test confirmation.
- A second submit during an active request is ignored.
- Provider body behavior varies by adapter and is not fully enumerated here.

## Verification plan and evidence

### Identity verification (passed)

Exact command:
`GIT_PAGER=cat git -C ~/.local/share/nvim/lazy/codecompanion.nvim status --short --branch; GIT_PAGER=cat git -C ~/.local/share/nvim/lazy/codecompanion.nvim show -s --format='%H%n%cI%n%s' 558518f8d78a44198cd428f6bf8bf48bfa38d76d; GIT_PAGER=cat git -C ~/.local/share/nvim/lazy/codecompanion.nvim show 558518f8d78a44198cd428f6bf8bf48bfa38d76d:version.txt; rg -n --color=never 'codecompanion.nvim' lazy-lock.json`

Result: passed; detached HEAD and exact commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d`, version `18.7.0`, lock entry matches.

### Closest upstream tests (blocked)

Attempted exact command:
`set -o pipefail; for f in tests/interactions/chat/test_variables.lua tests/interactions/chat/test_context.lua tests/interactions/chat/rules/test_rules.lua tests/interactions/chat/rules/parsers/test_parsers.lua tests/interactions/chat/rules/parsers/test_codecompanion_parser.lua tests/interactions/chat/slash_commands/basic.lua; do FILE="$f" make test_file || exit $?; done`

Result: blocked by dependency recipe attempting network clone of `deps/panvimdoc`; command exceeded 300s and was killed (exit 143). The first attempted test did not reach MiniTest. Do not claim test pass.

### Static validation: passed

Exact command:
`for f in lua/codecompanion/interactions/chat/slash_commands/builtin/*.lua lua/codecompanion/interactions/chat/variables/{lsp,viewport}.lua lua/codecompanion/interactions/chat/rules/{init,helpers}.lua lua/codecompanion/interactions/chat/rules/parsers/*.lua lua/codecompanion/adapters/shared.lua lua/codecompanion/adapters/http/init.lua lua/codecompanion/adapters/http/openai_responses.lua; do luac -p "$f" || exit $?; done; echo 'luac syntax: passed'`

Result: `luac syntax: passed`.

Source trace was extended at the pinned checkout for all 13 built-in slash-command files, `variables/lsp.lua`, `variables/viewport.lua`, rules/parser implementations and tests, shared role mapping, representative OpenAI Responses payload transformation, and Anthropic payload transformation. Full source chain remains incomplete for asynchronous picker branches, several command-specific tests, and Gemini/OpenAI-compatible post-processing.

## Coverage matrix

| Area | Entry/parse | Mutation/state | UI | Provider payload | Tests/docs | Status |
|---|---|---|---|---|---|---|
| Messages/submit | covered | covered | partial | covered at generic boundary | partial | partial |
| Context | covered | covered | covered | covered via linked messages | test path read only | partial |
| Variables | covered | covered | partial | generic boundary | docs/test path identified | partial |
| Rules | covered | covered | partial | generic boundary | docs/test path identified | partial |
| Slash commands | dispatch covered | context helper covered | partial | indirect | built-in/test incomplete | partial |
| Provider body | generic HTTP composition covered | n/a | n/a | adapter-specific incomplete | tests incomplete | partial |

## Coverage gaps / unresolved questions

- 1. Run direct Command-specific tests and mocked picker/fetch/background branches; source traces cover the retained synchronous behavior of `/compact`, `/fetch`, `/help`, and `/terminal`.
- 2. Establish explicit empty-diagnostic/empty-viewport and unavailable-buffer contracts for `lsp`/`viewport` through tests; current source trace covers their normal mutation behavior.
- 3. Run context/rules/parser/slash/variable tests after dependency setup without changing the pinned checkout.
- 4. Trace additional adapter-specific builders beyond Anthropic; OpenAI Responses and Anthropic are now covered, while Gemini/OpenAI-compatible post-processing remains incomplete.
5. Trace chat UI builder rendering for hidden/visible message options and context folds.
6. Verify system-prompt initialization/update/toggle interactions with rules system prompts and adapter changes.
7. Verify `check_images`, buffer diff sync, tool parsing, and context reconciliation interactions with direct tests.

## Source trace

- Entrypoint/state machine: `lua/codecompanion/interactions/chat/init.lua` (`Chat.new`, `submit`, `add_message`, `replace_vars_and_tools`, `check_context`).
- Parser: `lua/codecompanion/interactions/chat/parser.lua` (`messages`, `settings`, `images`).
- Context: `lua/codecompanion/interactions/chat/context.lua`.
- Variables: `lua/codecompanion/interactions/chat/variables/init.lua`, `buffer.lua`, `user.lua`.
- Rules: `lua/codecompanion/interactions/chat/rules/init.lua`, `helpers.lua`, `parsers/init.lua`, `parsers/codecompanion.lua`.
- Slash dispatch: `lua/codecompanion/interactions/chat/slash_commands/init.lua`; completion hook: `lua/codecompanion/interactions/chat/init.lua:277-288`.
- Provider boundary: `lua/codecompanion/interactions/chat/init.lua:1158-1176`; `lua/codecompanion/http.lua:186-199`, `312-325`.
- Documentation: `doc/usage/chat-buffer/{variables,slash-commands,rules}.md`.
- Tests: `tests/interactions/chat/{test_variables.lua,test_context.lua,rules/*,slash_commands/basic.lua}`.

## Review status

- Reviewable artifact exists: yes.
- Module status: `partial`.
- No latest-upstream or SuperMax behavior included.
- No target-runtime design included.
