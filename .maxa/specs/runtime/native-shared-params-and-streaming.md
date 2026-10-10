---
title: Native MCP 共享参数与流式 LLM Primitive 稳定规格
created: 2026-06-28
updated: 2026-10-09
type: source
doc_role: spec
authority: stable
status: stable
capability: native-mcp-shared-params-and-streaming
validation:
  specification: passed
  automated: partial
  live: not-run
  human: passed
sources:
  - lua/maxa/mcphub/native_servers/shared/params.lua
  - lua/maxa/mcphub/native_servers/shared/streaming_llm.lua
  - lua/maxa/mcphub/native_servers/shared/streaming_llm_test.lua
  - lua/maxa/mcphub/native_servers/subagent/tools/ask_llm.lua
  - lua/maxa/adapters/http/openai_responses.lua
confidence: high
---

## Scope and owners

Indirect primitives, not user-facing tools: `shared.params` normalizes JSON/MCP arguments; `shared.streaming_llm` owns adapter creation, SSE parsing, callbacks, timeout, retry and synchronous return over streaming HTTP. Imperatives express SHALL obligations; callers reuse this transport owner rather than duplicate internals.

Higher-level owners: [Chat Builtins](./chat-builtins.md), [Session Compression](../abilities/base/session/session-compression.md), [SubAgent Runtime](../abilities/base/subagent/subagent-runtime.md). Excluded: compact/summarize prompt construction, [Responses protocol](./openai-responses-adapter.md), GenAI provider-specific media streaming and adapter internals beyond observable helper behavior (not frozen here).

## Requirements

### Requirement: Shared params treats JSON null as absent

Treat `nil`/`vim.NIL` as absent for validation/defaults. `param_utils.normalize(req.params)` deep-copies tables, recursively converting `vim.NIL` to `nil`; non-tables yield `{}`. `param_utils.default(value, fallback)` returns fallback when absent.

### Requirement: Shared params provides consistent boolean and string validation

- `param_utils.boolean(value, default)`: absent → configured default; present → true only for literal `true`.
- `param_utils.required_string(value, name)`: nil/null, non-string or trim-empty → explicit `<name> is required` error.
- `optional_string`: default only when absent, not for arbitrary non-string values.

### Requirement: Streaming adapters are cloned and stream-enabled instead of reusing live chat adapters

Create a fresh Background adapter from Chat, resolved adapter, or adapter name/model/temperature; never mutate the live parent adapter. `create_streaming_adapter_from_chat(chat)` resolves name/model/temperature from Chat settings or adapter parameters. Set `opts.stream=true`; wrap setup to restore `opts.tools=true` afterward even if setup disabled tools. Missing required parent/name, unavailable Background support or unresolved adapter → explicit creation error.

### Requirement: Streaming request accumulates content chunks and parsed tool calls

`streaming_request(adapter, messages, opts, callback)` uses Maxa AI streaming HTTP; options include `tools`, `timeout`, `on_chunk_text`, `on_tool_calls`, `caller_chat`.

- Parse each SSE chunk through adapter `parse_chat`; append nonempty content deltas in order and pass each to optional `opts.on_chunk_text`.
- At completion, normalize tool calls to `{ id, name, input }`, decoding JSON string arguments when possible (decoded input is a table). Optional `opts.on_tool_calls` receives calls and content. Normalize empty final content to `nil`.

### Requirement: Streaming request enforces timeout and cancellation

Timeout is optional. Positive `opts.timeout` expiring before completion → cancel/shut down the active job if possible and callback with a timeout error.

### Requirement: Streaming retry behavior uses shared LLM error classification

Classify through shared `util.llm_error_handler`; retry only configured retryable classes within budget:

- Token limit → consume caller Chat's shared token-limit retry counter, notify, delay, retry.
- Retryable network/rate limit → delay/retry under configured policy.
- Non-retryable or exhausted → callback error `LLM request failed: ...`.

### Requirement: Synchronous wrapper preserves streaming transport

Without callback override, `streaming_request_sync` starts the same streaming request, waits with `vim.wait` up to request timeout + buffer, and returns content/error. Defaults: 120000 ms request timeout + 30000 ms wait buffer. Unobserved completion → timeout error; never substitute non-streaming HTTP.

## Evidence and acceptance

Frontmatter source map: `params.lua` → parameter rules; `streaming_llm.lua` / `streaming_llm_test.lua` → adapter/request implementation / fixture; `openai_responses.lua` → parsing; `ask_llm.lua` → listed SubAgent consumer. Current higher-level callers use `maxa.session`/Native handlers, not retired session-server/hooks.

Acceptance: current source citations, unambiguous null/default and adapter/request lifecycle, one transport owner, and streaming coverage distinguished from missing direct params tests. Existing checks:

```bash
nvim --headless -u NONE -c 'set rtp^=<PROJECT_ROOT>' -c 'lua require("maxa.mcphub.native_servers.shared.params"); require("maxa.mcphub.native_servers.shared.streaming_llm"); print("shared native primitives load OK")' -c 'qa!'
nvim --headless -u NONE -l lua/maxa/mcphub/native_servers/shared/streaming_llm_test.lua
```

- 2026-06-28: isolated module loads passed; then-current Responses streaming fixture passed four cases before behavior moved to canonical owners.
- 2026-09-15: historical `nvim --headless -u NONE -l lua/util/mcphub/shared/streaming_llm_test.lua` passed (`streaming_llm_test: OK`).
- Human specification review passed; automated remains `partial`, live `not-run`. Streaming has a maintained fixture; direct `params.lua` null/default/string tests are missing. Add direct coverage; caller behavior changes require rerunning compact/summarize/SubAgent streaming in disposable live sessions. Human review does not cover these gaps.

Retry ownership may move to a future error-recovery spec if shared normative detail warrants it. Brownfield/old ownership records are non-normative Git history; retired paths above are historical evidence, not current source locations.
