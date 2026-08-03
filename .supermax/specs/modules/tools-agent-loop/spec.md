---
title: CodeCompanion.nvim v18.7.0 tools and agent loop reverse specification
created: 2026-08-01
updated: 2026-08-01
type: spec
doc_role: reverse-spec
authority: draft
status: partial
target_disposition: retained-and-redefined-by-tool-runtime-request-orchestrator-mcp-skill-runtime
baseline_commit: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
version: v18.7.0
scope: upstream-only
confidence: medium
validation:
  checkout: passed
  static_trace: passed
  upstream_tests: blocked
---

> Draft upstream evidence only. Target behavior belongs to `tool-runtime`, `request-orchestrator`, and `mcp-skill-runtime`. Approval/rejection UI is removed; automatic execution, typed failure/cancel and batch completion are normative.

## 1. Boundary and state model

The upstream loop is per Chat and provides evidence for schema loading, normalized call queues, command execution, success/error/cancel, batch completion, and continuation. Its approval/rejection states are removed from the target. Target state ownership and terminal semantics belong to `tool-runtime` and `request-orchestrator`.

Source trace: `lua/codecompanion/interactions/chat/tools/init.lua:44-45,186-217,228-317,422-436`; `lua/codecompanion/interactions/chat/tools/orchestrator.lua:337-356,471-477`; `lua/codecompanion/interactions/chat/init.lua:1181-1265`; `lua/codecompanion/interactions/chat/subscribers.lua:231-349`.

## 2. Requirements and scenarios

### R1 — Tool discovery, registration, and schema

The system SHALL discover inline `<tool>name</tool>` and `<group>name</group>` markers in a user message. Parsing SHALL add each enabled tool once to the chat registry; groups SHALL add their configured tools and may collapse visible context. A registered client tool adds context, optional system prompt, and its schema; an adapter tool contributes a schema with `name`, `description`, and `_meta.adapter_tool=true`. Tool-specific system prompts and the aggregate tool system prompt are inserted as hidden system messages. `Chat:submit` SHALL include registry schemas as the `tools` payload field only when non-empty.

**GIVEN** an enabled configured tool or group marker in a user message  
**WHEN** the message is parsed  
**THEN** the registry contains its schema, context is linked by `<tool>…</tool>` or `<group>…</group>`, and replacement removes the marker using configured/group replacement text.

Source: `tool_registry.lua:33-169`; `tools/init.lua:98-187`; `chat/init.lua:1120-1160`; `doc/usage/chat-buffer/tools.md:22-29,242-312`.

### R2 — Adapter selection and model tool-call normalization

The system SHALL pass configured schemas through adapter-specific request formatting and SHALL normalize provider responses to tool calls before execution. The canonical execution shape is a list whose item has `id`, `type`, and `function={name, arguments}`; adapter-specific handlers may repair streaming fragments, concatenate malformed Gemini arguments, merge Copilot messages, or map Responses API `function_call` items. `Chat:done` SHALL add the assistant tool-call message invisibly and call `Tools:execute` only after `format_calls` returns a value.

**GIVEN** a completed response containing provider tool-call data  
**WHEN** `Chat:done` handles it  
**THEN** adapter `format_calls` is applied, a hidden assistant message stores normalized calls, and execution begins; no normalized calls means normal chat completion.

Source: `chat/init.lua:1185-1265`; `adapters/http/init.lua:45-70`; `adapters/http/openai.lua:118-155,229-280,350-367`; `anthropic.lua:256-275,552-584`; `gemini.lua:8-52,136-175`; `openai_responses.lua:204-223,355-422,524-535`; `copilot/init.lua:207-215`.

### R3 — Resolution and malformed calls

Each call SHALL resolve by name from the adapter-filtered configuration, deep-copy the resolved definition, attach `name`, original `function_call`, decoded `args`, merged options, and environment substitutions. Empty string arguments are treated as `{}`. Invalid JSON SHALL produce a tool-result error message, set error status, fire `ToolsFinished`, and stop preparing that batch. Unknown or unresolvable tools SHALL insert an explanatory result naming available tools and finish.

**GIVEN** an unknown tool or invalid JSON arguments  
**WHEN** preparation runs  
**THEN** no command executes; the chat receives an error result and the loop reaches `ToolsFinished`.

Source: `tools/init.lua:59-159,282-320`; `adapters/http/*` normalization handlers.

### R4 — Automatic execution boundary

After schema and argument validation, the target orchestrator SHALL execute every eligible tool automatically. It SHALL NOT expose approval caches, allow/reject prompts, YOLO mode, command confirmation, or authorization timeouts. Policy violations are typed validation/runtime failures, not user-approval requests.

**GIVEN** a validated tool call
**WHEN** it becomes current
**THEN** execution starts without an approval UI; explicit cancellation remains available through runtime cancellation ownership.

### R5 — Sequential command execution and asynchronous callbacks

The orchestrator SHALL execute calls FIFO and each tool's `cmds` chain sequentially. A command may be a function (sync return or callback) or a shell command converted to a function and run through `vim.system`; Windows uses `cmd.exe`, other platforms use the configured shell. A runner SHALL ignore duplicate completion callbacks after the first result. Success advances to the next command or next queued call; errors finalize the current call and continue the queue.

**GIVEN** a queued tool with multiple commands or an asynchronous callback  
**WHEN** one command succeeds  
**THEN** its output becomes the next command's input; after the chain, the next queued call starts; repeated callback completion has no second effect.

Source: `runtime/queue.lua:267-351`; `runtime/runner.lua:375-468`; `orchestrator.lua:270-334,482-500,582-671`; `doc/extending/tools.md:118-257,324-397`.

### R6 — Result insertion and provider-specific response

A tool result SHALL be formatted by the adapter's `format_response`, include the provider call identity, and be inserted into chat history as a tool-role response. If an existing result has the same tool-call ID, content SHALL be appended rather than creating another result. User-visible output is separately rendered; an empty `for_user` suppresses buffer output while retaining LLM history. Tool handlers may customize success, error, rejection, and cancellation messages.

**GIVEN** a tool result with call ID `id`  
**WHEN** `Chat:add_tool_output` runs  
**THEN** the adapter-specific tool response is inserted/merged by `id`, and the optional user-facing message is rendered according to `for_user`.

Source: `chat/init.lua:1549-1585`; `orchestrator.lua:262-268,394-468`; `adapters/http/openai.lua:357-367`; `anthropic.lua:572-584`; `openai_responses.lua:524-535`.

### R7 — Continuation and termination

After ToolBatch completion, the target orchestrator SHALL persist every result before choosing exactly one continuation: one automatic provider request, a user-ready boundary, or a terminal failure/cancel. Continuation is independent of approval state and is owned by `request-orchestrator`.

**GIVEN** all calls finish successfully or with error  
**WHEN** `ToolsFinished` is observed  
**THEN** the configured continuation policy determines one follow-up model request or a ready unlocked chat; automatic submission is deferred/scheduled and is not duplicated while a request exists.

Source: `tools/init.lua:228-275,422-436`; `chat/init.lua:1120-1185`; `subscribers.lua:304-349`.

### R8 — Stop/cancel and race handling

A user stop SHALL suppress automatic continuation. Hard cancellation SHALL propagate to the current tool and owned pending work, reject late callbacks by request/batch identity, persist cancellation results where applicable, and emit one batch terminal event.

**GIVEN** cancellation occurs while tools remain queued
**WHEN** cancellation is requested
**THEN** owned cancellation handlers run, no later queued command executes, and the batch terminates once.

Source: `orchestrator.lua:442-455,546-580`; `chat/init.lua:1185-1215`; `subscribers.lua:326-349`.

## 3. Failure and edge behavior

- Missing config, resolution failure, unknown name, invalid JSON, command non-zero exit, thrown handler, cancellation, and missing provider response formatter have distinct typed error paths; the target continuation policy explicitly decides whether remaining calls continue.
- Shell output strips ANSI sequences; non-zero shell output combines stderr then stdout. Command flags update `chat.tool_registry.flags` based on exit code (`orchestrator.lua:289-334`).
- Tool output handlers are protected with `pcall`; handler failure may add an internal-error tool result and execution continues.
- `use_handlers_once` permits successive calls of the same tool to reuse the command handler chain without re-running setup (`runtime/runner.lua:407-417`).
- Registry filtering is adapter-sensitive and refreshes on `CodeCompanionChatModel`; adapter tools take precedence over built-ins (`filter.lua:643-698`).

## 4. Concurrency, ordering, and external dependencies

- Tool calls are ordered FIFO; commands within a call are ordered. Async callbacks return control to the runner and are serialized by the completion guard.
- No approval UI is scheduled. Shell commands depend on `vim.system`, platform shell behavior, and filesystem/network/builtin tool dependencies.
- Continuation is scheduled with `vim.schedule` and subscriber auto-submit uses `vim.defer_fn`; `current_request` prevents duplicate subscriber submission.
- Provider correctness depends on adapter request/stream parsers and `format_calls`/`format_response`; missing handlers are observable failures.
- This module does not evidence parallel tool execution or a loop iteration cap; termination is event/configuration driven.

## 5. Validation evidence

### Checkout identity

Passed:

```text
git -C ~/.local/share/nvim/lazy/codecompanion.nvim status --short --branch
# ## HEAD (no branch)
git -C ~/.local/share/nvim/lazy/codecompanion.nvim show -s --format='%H%n%cI%n%D' HEAD
# 558518f8d78a44198cd428f6bf8bf48bfa38d76d
# 2026-02-18T08:00:51Z
# HEAD, tag: v18.7.0
git -C ~/.local/share/nvim/lazy/codecompanion.nvim show HEAD:version.txt
# 18.7.0
```

### Static evidence

Passed: cited source files, tests, and docs exist in the pinned checkout; source symbols and line ranges were inspected. Adapter test fixtures include OpenAI, Anthropic, Gemini, DeepSeek, Ollama, Mistral, Copilot, and OpenAI Responses tool-call variants.

### Upstream tests

Blocked, exact command and error:

```text
make test_file FILE=tests/interactions/chat/tools/test_tools.lua
```

The command printed `Testing File...` and invoked:

```text
nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run_file('tests/interactions/chat/tools/test_tools.lua')"
```

Neovim failed in `scripts/minimal_init.lua:7` with:

```text
E5113: Error while calling lua chunk: .../codecompanion.nvim/scripts/minimal_init.lua:7: module 'mini.test' not found
```

The subsequent `MiniTest` nil error occurred and the process was terminated after the 120-second command timeout. `deps/mini.nvim` is absent. No test pass claim is made.

## 6. Coverage gaps / non-claims

- Full execution of tool runtime and adapter tests was not completed due to missing `deps/mini.nvim`.
- All built-in tools were not individually behavior-traced; this document specifies the common loop, not each builtin's domain contract.
- Every adapter's streaming edge cases and exact provider payloads require individual test execution and deeper source reading.
- Provider-request cancellation, Chat close and late-callback suppression require `request-orchestrator` and `async-lifecycle` replacement fixtures.
- No latest-upstream or SuperMax downstream evidence is included.
