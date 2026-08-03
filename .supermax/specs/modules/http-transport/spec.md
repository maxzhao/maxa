---
title: CodeCompanion HTTP adapters/providers/transport 反推规格（v18.7.0）
created: 2026-08-01
updated: 2026-08-01
type: module
doc_role: reverse-spec
authority: draft
status: partial
target_disposition: narrowed-and-replaced-by-provider-contract-streaming-usage
tags: [codecompanion, reverse-engineering, http, adapters, providers, transport, v18.7.0]
sources:
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/adapters/init.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/adapters/http/init.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/http.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/adapters/http
  - ~/.local/share/nvim/lazy/codecompanion.nvim/tests/test_http.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/tests/adapters/test_adapters.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/tests/adapters/http
  - ~/.local/share/nvim/lazy/codecompanion.nvim/doc/configuration/adapters-http.md
  - ~/.local/share/nvim/lazy/codecompanion.nvim/doc/extending/adapters.md
   - ../../baseline.md
confidence: medium
---

> **Target disposition:** Target transport is limited to OpenAI Chat Completions, OpenAI Responses, Anthropic Messages and Gemini native API. All other provider/protocol details below are baseline-only evidence and MUST NOT create target implementation requirements. Normative behavior belongs to `provider-contract` and `streaming-usage`.

> **TLDR**: 在 pinned `558518f8d78a44198cd428f6bf8bf48bfa38d76d` (`v18.7.0`) 中，chat payload 进入 adapter resolution，再由 schema/handler 生成 JSON body，经 plenary.curl 异步或同步发送；generic transport 只传递 chunk/status/error，provider adapter 负责具体 JSON/SSE/tool/reasoning/token 语义。本文是证据型草案，不能作为独立运行时目标设计。

## 1. Scope, authority and baseline boundary

- **Authority**: `draft`; extraction of observed upstream behavior, not normative compatibility or target design.
- **Baseline**: `558518f8d78a44198cd428f6bf8bf48bfa38d76d` / `v18.7.0`; all requirements below refer to this commit unless explicitly marked gap.
- **Excluded**: SuperMax downstream adaptations, current/latest upstream behavior, and independent-runtime requirements.
- **Evidence priority**: baseline source and tests, then baseline schemas/docs, then explicit inference marked as gap.

### Baseline identity evidence

`lazy-lock.json:12` pins `codecompanion.nvim` to `558518f8d78a44198cd428f6bf8bf48bfa38d76d`. The checkout `~/.local/share/nvim/lazy/codecompanion.nvim` is clean and `HEAD` equals the commit; `version.txt` at that commit is `18.7.0`; commit metadata is `2026-02-18T08:00:51Z`, subject `chore(main): release 18.7.0 (#2744)`.

## 2. Behavior surfaces and entrypoints

| Surface | Baseline evidence | Coverage |
|---|---|---|
| Type and adapter resolution | `lua/codecompanion/adapters/init.lua:8-107`; `adapters/http/init.lua:234-350` | covered generic, partial edge tests |
| Schema/default/mapping | `adapters/http/init.lua:159-225`, `457-510`; `tests/adapters/test_adapters.lua:268-369` | covered generic, nested edge partial |
| Handler contract/compatibility | `adapters/http/init.lua:8-144`; tests `600-919` | covered mapping, mixed-format edges partial |
| Generic async transport | `http.lua:69-145`, `288-320` | source covered; lifecycle race tests missing |
| Generic sync transport | `http.lua:150-277` | source covered; stream contradiction remains |
| Provider adapters | `adapters/http/*.lua`, `copilot/*`, `ollama/*` | inventory and representative tests; per-field coverage partial |
| Stream/error/token boundary | `http.lua:218-288`, adapter response handlers | generic gate covered; consumer accumulation partial |
| Configuration/docs | `doc/configuration/adapters-http.md:17-248`; `doc/extending/adapters.md:39-189,268-270,538-618,665+` | read and traced |

## 3. Configuration → adapter resolution

### R-HTTP-001 Resolve adapter type before provider dispatch

**Target requirement**: provider selection SHALL validate an explicit protocol from the four supported values and reject unknown protocols before request construction. Upstream registry fallback behavior is removed.

- GIVEN no adapter argument, WHEN `adapters.resolve` runs, THEN it uses `config.interactions.chat.adapter`.
- GIVEN `adapter.type`, WHEN type is queried, THEN the explicit type wins.
- GIVEN a provider without a supported protocol, THEN configuration validation fails with no transport request.
- Evidence: `lua/codecompanion/adapters/init.lua:8-42`.

### R-HTTP-002 Resolve HTTP adapter forms

**Requirement**: HTTP resolution SHALL accept a resolved adapter table, `{name, model}` shorthand, a string preset, a function returning a config, or a plain table.

- String loading first tries `require("codecompanion.adapters.http." .. name)`, then `config.adapters.http[name]` (`adapters/http/init.lua:516-541`).
- `Adapter.extend` deep-copies base config and force-merges opts; absent config logs `Adapter not found`; missing type becomes `http`.
- `Adapter.resolve` reuses a table with Adapter metatable; shorthand recursively resolves by name and overrides schema model; plain tables are wrapped without preset merge; function configs execute immediately; legacy `handlers.resolve` executes before `set_model` (`:569-608`).
- `resolved` is metatable-based (`:610-618`); `make_safe` selects fields and excludes schema `model`, but is not guaranteed function-free (`:619-645`).

### R-HTTP-003 Apply schema defaults and mapping

**Requirement**: schema defaults SHALL produce configurable settings and map dot paths into adapter fields.

- `enabled(adapter)==false` skips a schema entry; function defaults execute with adapter (`:457-476`).
- `mapping` is a dot path; schema keys may themselves be dot paths, producing nested tables (`:480-510`).
- `set_model` records string default as `adapter.model.name`; table choices write choice opts; function defaults/choices are intentionally not executed there (`:543-563`).
- Docs: `doc/configuration/adapters-http.md:76-211`; `doc/extending/adapters.md:538-618`.

### R-HTTP-004 Preserve old and new handler contracts

**Requirement**: handlers SHALL support nested `lifecycle/request/response/tools` and legacy flat names.

- Presence of any lifecycle/request/response category selects new lookup and disables flat fallback (`adapters/http/init.lua:328-380`).
- Mappings include `build_parameters→form_parameters`, `build_messages→form_messages`, `build_tools→form_tools`, `build_body→set_body`, `parse_chat→chat_output`, `parse_inline→inline_output`, `parse_tokens→tokens`, `parse_meta→parse_message_meta`.
- `adapters.call_handler` routes HTTP handlers and passes adapter as first argument (`adapters/init.lua:93-107`; `tests/adapters/test_adapters.lua:600-919`).
- Docs describe lifecycle/request/response/tools and migration (`doc/extending/adapters.md:39-77,150-189,665+`).

## 4. Request schema and body formation

### R-HTTP-005 Build request body with adapter precedence

**Requirement**: generic request construction SHALL deep-copy the adapter per request, run setup/env replacement, and JSON-encode the merged provider body.

1. `Client:request` returns immediately to `adapter.opts.request(self,payload,actions,opts)` when a custom request function exists (`http.lua:159-167`); the custom function owns setup, transport, events and cleanup.
2. Otherwise copy adapter, call `setup`; `false` logs setup failure and aborts (`:170-177`).
3. Resolve environment values with `cmd_timeout`, then merge, in `vim.tbl_extend("keep")` order: `build_parameters(set_env_vars(parameters), messages)`, `build_messages`, `build_tools`, static `adapter.body`, `build_body(payload)` (`:178-191,312-325`). Earlier keys win.
4. Encode JSON and write a temporary `.json` body file (`:193-195`).

The chat-side boundary supplies mapped persistent messages and non-empty tool schemas; UI-only buffer records are not payload records. Evidence: `interactions/chat/init.lua:998-1176` and existing `modules/message-context/spec.md:R-MC-008`.

### R-HTTP-006 Apply curl and environment transport options

- Generic raw args: `--retry 3 --retry-delay 1 --keepalive-time 60 --connect-timeout 10`; streaming adds `--tcp-nodelay --no-buffer` (`http.lua:201-214`).
- Adapter `raw`, URL, headers are env-substituted (`:215-225`). Global HTTP opts provide `allow_insecure` and `proxy` (`config.adapters.http.opts`).
- Default method is POST; `adapter.opts.method:lower()` selects another injected static method; streaming sets `compressed = adapter.opts.compress or false` (`:267-294`).
- Body is sent by temp-file name. `cmd_timeout` is used for env command resolution; request `opts.timeout` reaches sync curl but exact async timeout semantics require more evidence.
- Docs: `doc/configuration/adapters-http.md:130-248`.

## 5. Transport lifecycle and state machine

### R-HTTP-007 Async state and callback contract

`Client:send` returns `{id, job, cancel, status}`. Initial status is `pending`; stream data sets `streaming`; successful non-stream response sets `success`; error callback sets `error`; cancel calls `job:shutdown()` and sets `cancelled` (`http.lua:69-145`). IDs are `tostring(math.random(10000000))` and are not guaranteed unique.

- Stream chunks call `on_chunk(raw_chunk, meta)`; successful stream completion schedules `on_done(nil, meta)` on next tick.
- Non-stream success calls `on_done(response_table, meta)`; status `>=400` is ignored by the wrapper, after lower transport layer has emitted data/error behavior.
- If an error arrives, `on_error(err,meta)` runs and deferred stream `on_done` is suppressed by `had_error`.
- `send` decides streaming from `adapter.opts.stream`, not `opts.stream` (`:89-124`).

### R-HTTP-008 Generic request lifecycle and events

The default request path invokes adapter lifecycle handlers around plenary curl (`http.lua:228-265,294-319`): final callback schedules parsing of non-stream data, calls `on_exit`, `teardown`, `actions.done`, then classifies HTTP status/stream error, emits `RequestFinished`, removes body file according to log level, and emits optional user event. Curl `on_error` calls action callback and `RequestFinished` but skips `on_exit`, `teardown`, done and cleanup (`:257-265`).

`RequestStarted` is emitted after curl job creation and adapter metadata assignment (`:296-305`); first stream callback emits `RequestStreaming` (`:267-288`). `silent` suppresses these events and optional user event. Event details: `doc/usage/events.md:9-42`.

### R-HTTP-009 Sync behavior

`send_sync` repeats deep-copy/setup/env/body/temp-file/curl setup, catches curl errors with `pcall`, maps HTTP `>=400` to `{message,stderr,status}`, always runs `on_exit`, `teardown`, `RequestFinished` and cleanup on normal curl completion (`http.lua:150-277`). The intended stream rejection is commented out (`:152-155`); a streaming adapter can therefore be sent synchronously despite the comment.

### R-HTTP-010 Cancellation and concurrency

Each request owns a body file and curl job; no global queue, lock, registry or concurrency limit is present. Adapter deep-copy reduces env mutation conflicts, but handlers/closures can share state. Cancellation does not set a guard against already queued callbacks, so late chunks/errors/completion may overwrite `cancelled`; transport/setup failures may return no cancellable job. Chat layer independently prevents a second submit while `current_request` exists. Evidence: `http.lua:69-145,159-320`; `interactions/chat/init.lua:1093-1100`.

## 6. Stream parsing, responses, tokens and errors

### R-HTTP-011 Generic stream boundary

Generic transport does not parse provider content. It forwards non-empty chunks to adapter consumers and only suppresses chunks whose beginning matches `^%s*{"error"` or `^%s*{"type"%s*:%s*"error"` (`http.lua:267-288`). An error chunk becomes final `{message="Request failed", stderr=<last error body>}` when final data is nil (`:240-246`). Other SSE wrappers, `data:` prefixes, arrays, plain-text errors and non-leading errors are not recognized.

#### Fragmentation boundary (static verification)

The transport passes each `plenary.curl` stream callback through unchanged; it has no cross-callback buffer, SSE delimiter scanner, incremental JSON decoder, or UTF-8 reassembly (`http.lua:267-288`). Provider fixtures demonstrate semantic accumulation across already-delimited chunks (not arbitrary byte fragmentation). Ollama's JSON-line path likewise has no transport-level repair for a split JSON token or UTF-8 sequence. Consequently, arbitrary fragmentation support is **source-only unknown**: no real curl stream or synthetic callback-fragmentation test was executed. The stream-error prefix check can also miss a prefix split across callbacks or wrapped in `data:`.

#### Callback race and exception boundary (static verification)

Final and stream callbacks are scheduled (`http.lua:240-288`), while successful streaming completion is deferred to the next tick and suppressed only when `had_error` is set (`http.lua:69-145`). There is no explicit once-guard, generation token, cancellation fence, or callback lock. Source establishes intended ordering, but cancel/final same-tick ordering, late stream after final, duplicate final callbacks, and exceptions raised by `on_done`, `on_exit`, `teardown`, or user callbacks remain **source-only unknown**; no representative race/exception fixture was executed.

### R-HTTP-012 Tokens belong to provider handlers

Transport neither invokes `parse_tokens` nor aggregates usage. The contract is `response.parse_tokens` or legacy `handlers.tokens`, returning `number|nil` (`adapters/http/init.lua:392-416`). Provider-specific `on_exit`, response parsers and consumers define prompt/completion/total semantics. Therefore a transport-only implementation MUST NOT generalize token field names from one provider.

### R-HTTP-013 Error ordering is observable

For non-stream HTTP status `>=400`, plenary final callback can first invoke normal data callback, then actions error callback; `tests/test_http.lua:162-191` fixes this ordering. `Client:send` filters the status-error data and receives later error. Transport errors differ: they skip teardown/on_exit/done/cleanup while still firing `RequestFinished` (`http.lua:257-265`).

Provider parser examples (baseline source):

- Anthropic: `adapters/http/anthropic.lua:...` and `tests/adapters/http/test_anthropic.lua` cover event-stream content/reasoning/tool-use, message delta/stop and usage.
- OpenAI: `openai.lua` + `test_openai.lua` cover `choices[].delta`, finish reason, tools and usage.
- OpenAI Responses: `openai_responses.lua` + `test_openai_responses.lua` cover typed SSE output/reasoning/function-call items and usage.
- Ollama: `ollama/init.lua` + `test_ollama.lua` cover JSON-line-like stream/reasoning/tool outputs.
- DeepSeek/Gemini/Mistral: respective adapter/test pairs cover OpenAI-like streams plus provider reasoning/tool variants.

Exact provider parser coverage remains partial and must not be generalized beyond cited adapter.

## 7. Provider inventory and capability boundaries

| Provider/adapter | Baseline role and evidence | Tests at baseline | Known gap |
|---|---|---|---|
| `anthropic` | Native messages, system/content blocks, thinking, tools, SSE | `test_anthropic.lua`, fixtures | provider error/usage variants |
| `openai` | Chat Completions, SSE delta, tools, usage | `test_openai.lua`, fixtures | malformed/parallel tool/error variants |
| `openai_responses` | Responses items, typed SSE, reasoning/function calls, `store=false` | `test_openai_responses.lua`, fixtures | complex multi-round state/non-function tools |
| `deepseek` | OpenAI-like body/stream with reasoning parameters | `test_deepseek.lua` | special restrictions/errors |
| `gemini` | OpenAI-compatible endpoint with thought signatures/reasoning | `test_gemini.lua` | native error/usage/multimodal |
| `mistral` | provider schema, OpenAI-like stream, thinking/tools | `test_mistral.lua` | provider error/multiple choices |
| `ollama` | local/remote OpenAI-like endpoint, reasoning/think, model discovery | `test_ollama.lua` | auth/discovery failures/version drift |
| `copilot` | dynamic token/models/stats and OpenAI-like request | `tests/adapters/http/copilot/test_{copilot,models,stats}.lua` | token refresh races/retry/quota boundaries |
| `azure_openai` | Azure deployment wrapper over OpenAI mapping | no dedicated adapter test | URL/api-version/auth/error |
| `githubmodels` | GitHub Models OpenAI-compatible | no dedicated test | auth/model capabilities/rate limits |
| `huggingface` | model discovery/cache plus OpenAI-compatible inference | no dedicated adapter test | discovery/cache/provider routing/errors |
| `novita` | model list and OpenAI-compatible completion | model fixture only | completion/tools/auth/error/usage |
| `xai` | OpenAI-compatible chat completion | no dedicated test | xAI-specific fields/errors/tools |
| `openai_compatible` | custom URL/header/model reusing OpenAI handlers | no dedicated test | compatibility variance |
| `jina` | GET reader/fetch, non-LLM content | no dedicated test | auth/robots/timeout/content errors |
| `tavily` | POST search JSON, non-stream result | output fixture only | auth/empty results/API errors |

Source inventory: `lua/codecompanion/adapters/http/{anthropic,azure_openai,deepseek,gemini,githubmodels,huggingface,jina,mistral,novita,openai,openai_compatible,openai_responses,tavily,xai}.lua`, `copilot/{init,get_models,stats,token}.lua`, `ollama/{init,get_models}.lua`. Provider registration/config is documented in `doc/configuration/adapters-http.md` and code in `codecompanion/config.lua`.

## 8. User scenarios and failure configurations

### Normal scenarios

1. **Configured chat request**: configured adapter/model resolves; hidden system/context/user messages and tool schemas become provider body; curl POST sends JSON; stream chunks are parsed by provider; final assistant/tool state is emitted.
2. **Non-stream request**: provider returns complete JSON; `on_exit` and provider response handler consume usage/output; `on_done` receives response table.
3. **Custom provider**: user supplies URL/headers/parameters/schema mappings or `opts.request`; custom request owns all lifecycle behavior.
4. **Provider-specific endpoint**: Anthropic, Responses, Ollama, Copilot or search/fetch adapter applies its own body/parser rather than generic assumptions.
5. **Concurrent chats**: independent HTTP jobs can coexist; a single chat rejects a second submit while `current_request` is present.

### Failure configurations and external failures

- Unknown adapter name or missing preset: log `Adapter not found`, no valid request adapter.
- `setup` returns false: request aborts before body/curl; error cleanup behavior is caller-visible and needs direct test.
- Missing env/API key, malformed URL/header/raw: env replacement or curl/provider failure; exact user notification varies by path.
- HTTP `>=400`: normal data may arrive before error; stream error prefix is withheld and final error becomes `Request failed`.
- Curl/transport error: action error and `RequestFinished`; no teardown/on_exit/done/cleanup in generic async path.
- Retry/代理/TLS 时序：源码只静态确认 raw defaults 为 `--retry 3 --retry-delay 1 --keepalive-time 60 --connect-timeout 10`，以及全局 `proxy`/`allow_insecure` 透传（`http.lua:201-225`）；未执行 curl、代理、TLS、DNS、timeout 或 retry，故退避间隔、重试触发条件、POST 重放时序、代理握手及证书失败表现均为 **source-only unknown**。不得声称 retry 可保证幂等或代理/TLS 兼容。
- Provider malformed JSON/SSE, empty stream, auth/model/rate-limit/quota failure: adapter consumer behavior is provider-specific; generic transport only sees chunks/status.
- Invalid handler shape: nested/new-format detection can suppress flat fallback; missing handler returns nil.
- Missing schema default/unsupported model choice: model convenience fields may be empty while request still depends on provider schema.
- Sync streaming configuration: despite comment, stream rejection is disabled and request proceeds as ordinary sync curl.
- Custom request function: no generic retry, body temp-file, event, cleanup or lifecycle guarantees unless custom code supplies them.

## 9. External dependencies and resource boundaries

- Neovim `vim.json`, `vim.deepcopy`, `vim.schedule`, `vim.schedule_wrap`, temp file APIs.
- `plenary.curl` for GET/POST jobs and shutdown.
- `plenary.path` for request body files.
- Provider APIs: Anthropic, OpenAI/Responses, Azure, DeepSeek, Gemini, Mistral, Ollama, GitHub Models, Hugging Face, Novita, xAI, Copilot, Jina, Tavily.
- Optional env command resolution uses configured `cmd_timeout`; proxy/insecure are global HTTP settings.
- Provider-specific dynamic model/token/stats requests exist for Ollama, Copilot, Hugging Face and Novita.

## 10. Validation and evidence status

### Passed

- Identity: `rg -n --color=never '"codecompanion.nvim"' lazy-lock.json`; `GIT_PAGER=cat git -C ~/.local/share/nvim/lazy/codecompanion.nvim cat-file -t 558518f8d78a44198cd428f6bf8bf48bfa38d76d`; `git show -s --format='%H%n%cI%n%s' ...`; `git show ...:version.txt` — passed, exact commit/version.
- Clean baseline checkout: `GIT_PAGER=cat git -C ~/.local/share/nvim/lazy/codecompanion.nvim status --porcelain=v1 -uno` — passed, zero tracked modifications.
- Static source inventory and symbol trace: `rg --files`, `rg -n` over pinned HTTP source/tests/docs — passed.
- Lua syntax for generic transport/adapter files: `luac -p` run individually for `lua/codecompanion/http.lua`, `lua/codecompanion/adapters/init.lua`, and `lua/codecompanion/adapters/http/init.lua` — passed.

### Attempted / blocked

Closest upstream tests were not run to completion. The repository test recipe attempted a network clone of `deps/panvimdoc`, exceeded the 300-second timeout and was killed (`exit 143`) before MiniTest. Do not claim HTTP tests passed. No network fetch or checkout change was used for evidence.

### Evidence paths

- Generic transport: `~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/http.lua:1-321`.
- Adapter type routing: `lua/codecompanion/adapters/init.lua:8-107`.
- HTTP resolve/schema/handlers: `lua/codecompanion/adapters/http/init.lua:8-144,153-225,234-350,356-378`.
- Generic tests: `tests/test_http.lua:85-287`; adapter tests: `tests/adapters/test_adapters.lua:241-919`.
- Provider tests: `tests/adapters/http/test_{anthropic,deepseek,gemini,mistral,ollama,openai,openai_responses}.lua`; Copilot tests under `tests/adapters/http/copilot/`.
- Configuration docs: `doc/configuration/adapters-http.md:17-248`; extension contracts: `doc/extending/adapters.md:39-189,268-270,538-618,665+`.
- Existing module conventions: `modules/message-context/index.md`, `modules/message-context/spec.md`.

## 11. Behavior coverage audit

| Dimension | Status | Evidence/gap |
|---|---|---|
| Normal request/response | partial-covered | generic lifecycle and major provider fixtures inspected |
| Configuration/resolution | covered generic | adapter tests and source inspected |
| Data/schema/payload | partial | generic merge plus representative providers; all fields not traced |
| Failure/edge | partial | setup/status/stream/curl paths inspected; malformed/provider errors thin |
| External dependencies | covered inventory | plenary/Neovim/provider boundaries recorded |
| Concurrency/idempotency | partial | independent jobs and chat gate observed; race tests absent |
| Cancellation/cleanup | gap/partial | shutdown path observed; late callbacks and transport-error cleanup untested |
| Tools/reasoning/multimodal | partial | major provider fixtures; all capability variants not traced |
| Tokens/usage | partial | handler contract and provider fixtures; generic aggregation absent by design |
- `Validation`: blocked | static/identity passed; closest tests blocked by network dependency setup |

### High-value static fixture verification (completed)

- Confirmed pinned baseline contains representative HTTP adapter suites and fixtures for Anthropic, DeepSeek, Gemini, Mistral, Ollama, OpenAI, OpenAI Responses, plus Copilot sub-suites; inspected test names/assertion paths rather than treating file presence as execution evidence.
- Confirmed fixture coverage demonstrates provider-delimited stream chunks, streamed tool-argument accumulation, reasoning/thinking and usage shapes for major families; it does **not** demonstrate arbitrary callback-byte fragmentation, callback race/exception behavior, or retry/proxy/TLS timing.
- No real external provider call was made. No fixture was modified.

### Explicit source-only unknowns after static verification

- Arbitrary SSE/JSONL fragmentation, split UTF-8/JSON tokens, and split stream-error prefixes.
- Cancel versus final/late-stream ordering, duplicate callbacks, and callback exception containment.
- Curl retry trigger/backoff/POST replay timing, proxy negotiation, TLS verification/insecure behavior, DNS/connect timeout behavior.
- Full fixture execution and parser compatibility, because declared test dependencies were unavailable or setup timed out.

**Module completion**: `partial`; source coverage is broad, behavior coverage is not complete. No promotion/acceptance claim.

## 12. Explicit gaps and next work

1. Read every provider source plus relevant per-provider fixture/output and cite exact symbols/lines rather than relying on inventory summaries.
2. Run HTTP tests in an environment with dependencies already available; if blocked, record exact command/error and preserve `not-run` status.
3. Add tests or source traces for cancellation races, duplicate callbacks, temp-file cleanup, event ordering, custom request bypass, proxy/insecure/timeout, unknown methods and schema edge paths.
4. Verify all provider-specific error body, usage/token, image/reasoning/tool-call behavior; do not generalize OpenAI semantics.
5. Trace chat-to-HTTP cross-module flow for empty/context-only submits, hidden messages, tool loop continuation, adapter changes and system-prompt/rules state.
6. Update `../../coverage-audit.md` only after review; this module remains partial and must not claim global completion.
