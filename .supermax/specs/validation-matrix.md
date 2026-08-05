---
title: maxa Target Runtime Validation Matrix
created: 2026-08-02
updated: 2026-08-02
doc_role: validation-plan
authority: draft
status: partial
sources:
  - modules/provider-contract/spec.md
  - modules/chat-runtime-state/spec.md
  - modules/request-orchestrator/spec.md
  - modules/tool-runtime/spec.md
  - modules/session-history/spec.md
  - hook-replacement-map.md
---

# Purpose

Define executable fixtures required before the target runtime can replace CodeCompanion. Current hook tests may satisfy evidence columns but never count as replacement-runtime passes.

## Protocol fixtures

| ID | Protocol | Fixture | Required assertions | Current evidence | Replacement status |
| --- | --- | --- | --- | --- | --- |
| P-OAI-001 | OpenAI Chat Completions | text-only streamed completion | normalized start/delta/completed order; assistant message; usage | pinned OpenAI adapter source | not implemented |
| P-OAI-002 | OpenAI Chat Completions | fragmented streamed `tool_calls[].function.arguments` | stable call ID/index; exact JSON accumulation; one tool batch | pinned OpenAI adapter source | not implemented |
| P-OAI-003 | OpenAI Chat Completions | tool result continuation | call/result pairing; one follow-up request; no approval gate | current tool-loop evidence | not implemented |
| P-OAI-004 | OpenAI Chat Completions | HTTP/status/SSE malformed error | typed provider failure; terminal event once; Chat unlocked | upstream/adapter evidence | not implemented |
| P-RESP-001 | OpenAI Responses | text stream | response item/delta normalization; finish/usage | current adapter/hooks | not implemented |
| P-RESP-002 | OpenAI Responses | tool-call-only stream without final output item | tool batch executes despite no text; arguments preserved | current hook test | current evidence passed; replacement absent |
| P-RESP-003 | OpenAI Responses | `event:error`, `response.failed`, `response.incomplete` | typed error; no duplicate completion | hook test: 4 passed | current evidence passed; replacement absent |
| P-RESP-004 | OpenAI Responses | strict nested tool schema and empty objects | recursive object normalization; `{}` remains object; deterministic order | `adapter_form_tools.lua` | replacement absent |
| P-ANTH-001 | Anthropic Messages | text content-block stream | normalized deltas; system separation; usage | gateway/upstream adapter | not implemented |
| P-ANTH-002 | Anthropic Messages | `tool_use` and `tool_result` blocks | stable IDs; adjacent result handling; continuation once | message/tool hook evidence | not implemented |
| P-ANTH-003 | Anthropic Messages | thinking/reasoning round retention | configured recent-turn retention; signatures preserved/removed by policy | `adapter_form_messages.lua` | not implemented |
| P-ANTH-004 | Anthropic Messages | provider error/cancel | typed failure/cancel and late-delta rejection | source-only | not implemented |
| P-GEM-001 | Gemini native | text `streamGenerateContent` response | `candidates[].content.parts[].text` normalization; finish/usage | none; new target | not implemented |
| P-GEM-002 | Gemini native | `functionCall` / `functionResponse` | normalized tool call/result pairing and continuation | none; new target | not implemented |
| P-GEM-003 | Gemini native | `systemInstruction`, multimodal parts and tool declarations | correct native request shape; no OpenAI-compatible fields | none; new target | not implemented |
| P-GEM-004 | Gemini native | safety/block/error/empty candidate | typed terminal reason; no false success; Chat returns ready/error | none; new target | not implemented |

## Runtime state and orchestration fixtures

| ID | Scenario | Required assertions | Current evidence |
| --- | --- | --- | --- |
| R-STATE-001 | manual Chat submission | one user turn; submit/request/response events ordered; ready/completed terminal | trace lifecycle tests |
| R-STATE-002 | automatic continuation after tools | persisted results before continuation; one provider request | tool batch hook test |
| R-STATE-003 | soft stop during stream/tools | current work drains; callback/reset runs; continuation suppressed | soft-stop tests: 5 passed |
| R-STATE-004 | context-limit boundary | absolute/relative target; one-shot stop; unavailable usage fails closed | context tests: 10 passed |
| R-STATE-005 | watchdog retry exhaustion | bounded/configured retries; manual submit resets; terminal error once | watchdog tests: 2 passed |
| R-STATE-006 | hard cancel | provider and child tools receive cancellation; late events rejected | source-only gap |
| R-STATE-007 | view buffer deleted | view detaches; session state survives; callbacks do not touch invalid buffer | buffer-guard source/tests needed |
| R-STATE-008 | Chat close / Neovim exit | owned async tasks cancelled; timers/handles closed; cleanup idempotent | async hook evidence |
| R-STATE-009 | restored AgentLoop | state reconstructed; orphan tool call repaired; no duplicate user trace | source-only gap |
| R-STATE-010 | duplicate terminal callbacks | exactly one terminal event/trace/status transition | partial trace tests |
| R-CHATUI-001 | streaming incremental render | N deltas append-only (no rewrite jitter), re-render equivalence | tests/ui/render.lua B/A: UI_RENDER_OK |
| R-CHATUI-002 | typed collapsible reasoning block | real fold closed by default, foldtext summary, zo/zc interactive | tests/ui/render.lua E: UI_RENDER_OK |
| R-CHATUI-003 | status/input/actions projection | busy spinner + usage projection; input history recall; visual attach; keymap registry | tests/ui/status.lua+input.lua+actions.lua: UI_STATUS_OK/UI_INPUT_OK/UI_ACTIONS_OK |

## Tool/MCP/Skill fixtures

| ID | Scenario | Required assertions |
| --- | --- | --- |
| T-001 | malformed JSON or missing required fields | standard invalid-call result participates in batch and continuation |
| T-002 | successful synchronous tool | running/succeeded events, result persistence and display projection separated |
| T-003 | failed tool | typed failure result; automatic continuation policy explicit; no approval prompt |
| T-004 | asynchronous tool | owner scope, status polling, cancellation propagation and TTL lifecycle |
| T-005 | parallel/batch tools | declared concurrency/order policy; completion barrier fires once |
| T-006 | external MCP start/stop/restart | server state transitions, timeout/error, project environment and event update |
| T-007 | native MCP registration | schema validation, duplicate registration idempotency/error, tool/resource/prompt exposure |
| T-008 | Skill global/project collision | project Skill overrides same-name global Skill |
| T-009 | Skill startup/on-load/session/cascade | registration scope, parent inheritance, once state and history restore |
| T-010 | SkillHook pre/post | synchronous pre injection precedes request composition; post observer cannot mutate sent request |

## History, status and configuration fixtures

| ID | Scenario | Required assertions |
| --- | --- | --- |
| H-001 | save/open/list/search | stable project-scoped identity and index/chat persistence |
| H-002 | fork/scratch/save/merge | parent lineage, unsavable scratch boundary, exact merge range and close behavior |
| H-003 | rewind/redo | selected/manual user boundary restored; redo submits exactly once |
| H-004 | compaction | protected prefix, archive trace, replacement messages and recovery remain consistent |
| H-005 | trace lifecycle | visible manual user/assistant/error turns; de-duplication; untracked session writes nothing |
| S-001 | status/spine | request/warmup/running counts, provider/model, token/context, notification and terminal state derive from runtime snapshot |
| S-002 | lualine | projection refreshes on state events and never queries CodeCompanion internals |
| C-001 | project prompt absent | runtime `prompts/system.md` fallback selected |
| C-002 | `.maxa/system.md` override | `<system_prompt>` and declared placeholders expand deterministically; development `.supermax/` is ignored |
| C-003 | Skill system slots | declared slots render; unknown nonempty slot is a composition error |
| C-004 | schema version mismatch | exact status classification and declared Chat/runtime policy; no cross-project or mother-repository `.supermax` fallback |

## Completion gate

A module may move from `partial` only when every applicable fixture has an executable replacement-runtime test or an explicitly accepted removal decision. Configuration/history/Skill/MCP acceptance additionally requires a fixture target project rooted at `.maxa/` to pass while the development `.supermax/` is absent or inaccessible. Provider acceptance requires all four protocol rows, including Gemini native fixtures; testing CodeCompanion's OpenAI-compatible `gemini` adapter does not satisfy Gemini native requirements.
