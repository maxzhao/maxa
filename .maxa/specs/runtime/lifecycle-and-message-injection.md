---
title: Runtime Lifecycle 与 Message Injection 行为规格
created: 2026-06-28
updated: 2026-10-13
type: source
doc_role: spec
authority: accepted
status: active
capability: runtime-hooks-and-message-injection
sources:
  - lua/maxa/lifecycle/
  - lua/maxa/adapters/
  - lua/maxa/interactions/chat/
  - lua/util/ability_hooks/
  - abilities/*/hooks/
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
---

### Ownership

- `lua/maxa/lifecycle/`: Chat lifecycle, safe stop, context/token decisions, watchdog and trace lifecycle.
- Adapter/Chat/tool/session owners directly implement request/response/display/persistence; no central vendor patch sequence dependency.
- `lua/util/ability_hooks/`: cross-capability event discovery, effective-root overlay, filter, render, batch, scope and injection; definitions: `abilities/*/hooks/`.

### Core lifecycle requirements

#### Requirement: Lifecycle uses canonical identities

AI User autocmds SHALL use `MaxaAI*`; preserve payload semantics except separately accepted changes. Adapter, Chat UI, tool execution/display, response, retry, stop and session trace behavior SHALL reside in direct owners. Setup SHALL be idempotent: no duplicate wrappers/autocmds/listeners/registrations.

#### Requirement: Adapter normalizes protocol events

The adapter SHALL normalize official Responses function-argument wire events to `MaxaAIToolCallArgumentsStarted|Delta|Done` for spinner/status/hooks. Watchdog SHALL consume adapter-owned semantic output/phase observations, never parse wire events itself. Temporary non-expired tool-result images MAY append as ephemeral `input_image` to following user content in the next Responses request; skip TTL-expired/missing-base64 images. `function_call_output.output` stays string; image parts MUST NOT enter persistent history. Wire owner: [OpenAI Responses adapter](./openai-responses-adapter.md).

#### Requirement: Chat watchdog observes effective request progress

Monitor each dispatched Chat HTTP request until completion/error/cancellation/close, independently of visibility. New text/reasoning/tool arguments and genuine one-time phase transitions refresh the baseline; heartbeat, empty/repeated metadata, usage-only updates, rendering and local tool events do not. First effective output, response idle and tool-argument idle use the independent [centralized configuration](./plugin-entrypoints.md#requirement-chat-stage-timeout-configuration-is-centralized). No total response duration cap or competing per-tool timer. Argument completion returns to response-idle protection; `is_active` means actual request activity.

#### Requirement: Chat communication timeout settles once

Idle expiry cancels only its HTTP job and reports a classified timeout containing request identity, phase, idle duration, limit and last progress. No extra threshold-length warning wait, partial tool execution or user-stop outcome. Late chunks/errors/completion cannot affect subsequent requests or captured recovery state. Real HTTP/curl/SSE errors remain visible even when local stages are disabled. Reuse existing adapter-dependent bounded recovery and stop/exhaustion semantics; no independent watchdog auto-submit chain or retry budget. Tools and auxiliary request deadlines remain locally owned.

### Safe-stop family

#### Requirement: Soft stop drains the current operation

During an LLM request, tool execution or automatic continuation, Chat-local `<leader>ax` SHALL toggle graceful stop:

1. Do not call hard `Chat:stop()` or cancel the current request/tool/job.
2. Drain the response and complete tool-call batch with paired calls/results.
3. Suppress provider continuation/retry/Repeat at the next auto-submit boundary.
4. Return to editable/manual-resumable state; manual submit works normally.

A second press before that boundary clears the pending stop; idle invocation only notifies no active work, arming nothing. Soft stop MUST NOT reference/restore/depend on retired Agent Loop/`pause_loop`; hard stop `<C-c>` remains separate.

#### Requirement: Context-limit stop is one-shot

Chat-local `<leader>aX` SHALL arm/cancel one per-Chat context stop: accept absolute `0..100` or relative `+N` percentage points; reject empty/non-numeric/negative/out-of-range input, absolute below current ratio, relative target above 100, or unavailable token/context window. Compare unrounded `maxa.session.token_usage` ratio.

At/reaching target, clear the listener: busy requests existing soft stop; ready finishes immediately. Close/cancel/user cancellation clears state. Setup SHALL order `chat_soft_stop` before `chat_context_limit_stop`, with idempotent `Chat:submit`, `Chat:tools_done` and ready/close wrappers.

### 95% token decision

**Threshold-wide contract**: Per-Chat runtime-only decision/finishing state is never history-restored; close/delete/cancel/normal exit performs bounded cleanup. Prompt/compression/injection failure leaves existing Chats stopped and manually resumable; destroyed Chats receive no late actions. Hidden image-analysis children use independent `max_steps`, not this flow. Runtime SHALL NOT launch Human Assist Python scripts or parse JSONL process output.

**Shared actions**:
- Authorized `compact` alone invokes [Session compression](../abilities/base/session/session-compression.md), once after safe stop; successful handoff submits only the successor, installing no finish budget. The dedicated compaction executor is excluded from threshold decision recursion.
- Finish instructions grant no new scope/approval/compression authorization.
- Eligible `handoff` uses a one-transfer user instruction, one-shot continuation and one standalone synchronous `run_agent(run_mode="handoff")`; no compression/future-transfer authorization. Main/child eligibility, preparation and completion differ below.
- Both asks use `🛑 中断当前会话` → `interrupt`, `🗜️ 压缩并继续` → `compact`, and, only when eligible, `🔀 交接到新会话继续` → `handoff`.

**Exhaustion boundary**: Primary request eight without natural completion SHALL NOT hard-cancel an executing tool. At the next safe boundary (safe tool boundary for SubAgent), cancel queued/new calls before side effects with paired cancellation results, then apply the ordinary/child transition.

#### Requirement: Runtime owns one threshold decision

At the synchronous completed-tool pre boundary, runtime SHALL compute warning usage from `_session_status.tokens` and model limits: prefer model warning threshold and rounded `floor((used/limit)*100+0.5)`; fall back to `tokens.percent`. Computable `>=95` starts one decision and requests soft stop without a Chat message. No duplicate above-threshold decision/prompt; rearm only after an inactive below-95 observation and new crossing.

#### Requirement: Ordinary Chat waits for an explicit three-choice decision

Ordinary Chat SHALL use its ask coordinator with `mode="choice"`, `timeout=0` and exact caller identity. Notice states token usage/warning limit/percent and button or direct Telegram/same-Chat reply options. Waiting intercepts manual input but permits required tool-finalization auto-submit to reach safe stop. After safe stop, apply the exact result once:

- `尽快收尾` → `token 超限了，需要尽快收尾`, classified as `finish`: enter the primary eight-request budget.
- `compact`: shared action; `interrupt`: retain manually resumable latch.
- `handoff`: eligible persistent main only, never child/unsavable Chats. Revalidate main identity; append user's explicit one-transfer request. Direct the Agent to load subagent and prepare necessary `.maxa/drafts/` state/file messages and real preloads before the shared action. Runtime MUST NOT auto-transfer full history; successor main owns verification/delivery.
- Legacy exact `continue`: compatibility continuation without new instruction.
- Every other nonblank result, including Telegram button output unwrapped from `用户选择了"<value>"`: verbatim next user instruction via one-shot continuation. Never infer finish/compression from arbitrary text.

Transport/config/protocol failure, timeout, cancellation and empty/malformed results SHALL fail closed. Late/duplicate results and close/cancel races MUST NOT resume/inject/reapply. Free text applies only here; child transfer and strict choices belong to the final SubAgent decision.

#### Requirement: Primary finish uses an eight-request budget

Ordinary exact `finish` and a Chat with `_subagent_recursion_depth > 0` SHALL append this Agent-visible runtime-origin instruction once after the threshold safe boundary, without overwriting user draft input:

```text
当前会话已达到 token 风险阈值。不要回复或确认本条通知，请立即收尾，不再扩展工作范围；完成必要验证，说明结果与未完成事项，然后结束本次执行。最多剩余 8 轮。不得自行调用压缩工具或发起会话压缩；本通知不授权压缩，只有用户明确选择“压缩并继续”才允许运行时执行压缩。
```

Runtime SHALL release the stop latch and schedule one automatic submit under the threshold-wide rules. Count actual target-Chat model dispatches after finish entry, including separately dispatched retries; exclude blocked submits, polling, tools/tool multiplicity and pre-finish requests. Natural final response by round eight completes normally. HTTP finishing SHALL disable curl-internal retry per request, count separately dispatched host recovery and restore adapter request settings.

#### Requirement: Exhausted ordinary finish interrupts directly

After the exhaustion boundary, runtime SHALL set `interrupt`, retaining a manually resumable latch. No request nine, emergency instruction, another ask or compression.

#### Requirement: Exhausted SubAgent gets a hidden three-request emergency finish

After the exhaustion boundary, runtime SHALL append this hidden user instruction once and resume automatically:

```text
Token 已耗尽，请立即收尾。不得自行调用压缩工具或发起会话压缩；本通知不授权压缩，只有用户明确选择“压缩并继续”才允许运行时执行压缩。
```

The instruction SHALL NOT disclose the internal budget: at most 3 further requests, counted by Primary finish's actual-dispatch rules. Cancel every emergency-stage tool request with protocol-complete results; cancelled batches MAY auto-continue only within budget. Natural final response completes immediately.

#### Requirement: Exhausted SubAgent automatic finish asks for a decision

If emergency request three still does not finish, runtime SHALL stop at the safe boundary and use existing Chat/Telegram ask: `mode="choice"`, timeout 300; notice `5 分钟内未选择，将自动中断当前会话。` Accept only:

- `interrupt`: terminate SubAgent routing through the existing completion guard, without another model request.
- `compact`: shared action.
- `handoff`: eligible persistent ordinary delegated child only, never temporary/dedicated children. Revalidate active child executor/live parent; append child-specific draft-file/real-preload preparation instruction; use shared handoff without completing the parent invocation. [SubAgent runtime](../abilities/base/subagent/subagent-runtime.md#child-session-handoff) owns same-parent replacement/completion.

Normal timeout maps to `interrupt`; other ask failures/unknown free text fail closed.

### AbilityHook runtime

Invalid/unreadable hooks, render/filter exceptions, unresolvable Chat or invalid metadata SHALL skip with bounded notification, not crash setup. Pending tool results always precede injection.

#### Requirement: AbilityHook replaces SkillHook

The active framework SHALL use only Ability identities: `lua/util/ability_hooks/`, Vim `User` prefix `AbilityHook`, `<ability>/hooks/`, on-load event `AbilityLoaded`, payload `ability_name`, Ability-named context metadata/diagnostics. Active `SkillHook`, `SkillLoaded`, `skill_name`, `lua/util/skill_hooks/` and compatibility mirroring SHALL be absent; old transcripts remain historical only.

Unchanged load emits no `AbilityLoaded`; changed successful revision replaces that Chat's effective on-load registrations and emits once after commit. Failed preparation retains prior registrations; post-commit handler errors do not roll back the revision.

#### Requirement: AbilityHook discovery follows Ability composition

Startup discovery SHALL use the catalog's effective Skill roots/highest-layer merge decision without loading instructions or activating MCP. Higher-precedence hooks own identical relative paths; nonconflicting lower files remain. Invalid/ambiguous higher definitions fail without fallback. MCP sources add no filesystem hooks; resource `exclude` does not disable discovery.

Only `load: startup` installs at startup; validated/prepared `load: on_load` definitions publish only at Ability commit. Session/cascade/global scope, filtering, ordering, batching, once/ephemeral behavior and tool-pair safety remain unchanged. Restore uses committed roots/valid identities, not fresh current-cwd scanning. Changed hooks preserve once state for unchanged logical identities; failed refresh preserves registrations and once state.

#### Requirement: Ability system fragments are generated from effective Skill roots

Root `SYSTEM.md` fragments SHALL use effective Ability roots: project-over-global same-path precedence, one effective root fragment, existing slot/priority rules, no source activation. MCP-only Abilities install no filesystem fragment. Generated text uses Ability Gate and unified `load` terminology.

#### Requirement: Hook definitions are constrained

Event name derives from `<ability>/hooks/{EventName}.md|.lua`; both formats for one effective Ability/event are invalid. Markdown parses frontmatter plus `## user`/`## llm`; `## system` and missing/unknown roles fail. Lua returns `render(ctx)`, optional filter/options, no static `prompts`. Supported values: `load=startup|on_load`, `scope=global|session|cascade`, `inject_at=pre|post`.

#### Requirement: Events and filters are deterministic

Events SHALL be Vim `User` autocmds `AbilityHook{EventName}`. Async `fire` marks post phase; synchronous pre fire flushes the exact target Chat before return. Preserve caller data; may add `bufnr`/`_session_status`.

Filters AND fields/conditions; within a condition: `|` OR, `!` negation, `prefix:` prefix, `pattern:` Lua pattern, `*` existence. Ambiguous negated OR fails that hook with bounded warning.

#### Requirement: `fire` dispatches defined AbilityHook events

`fire` SHALL accept an event name without `AbilityHook`, inject framework-owned `bufnr`, and dispatch only defined AbilityHook events; retain complete-payload validation, exact invoking Chat-buffer injection, sync/async phases and bounded errors. Undefined retired SkillHook-only names fail normally. External-process scripts retain structured script-event forwarding, with no direct current-Neovim access.

#### Requirement: Injection is scoped and ordering-safe

Injection requires a resolvable Maxa AI Chat; scope precedes filter/render. Lua render context contains event/data/bufnr/chat id/hook path/Ability root, not raw Chat. Same-tick output batches by Chat, merges roles `user -> llm`, separates same-role bodies with a divider and defers injection while tool results are pending. Pre ToolCallsCompleted injection precedes auto-submit; post hooks run later.

#### Requirement: Injected messages are recoverable Ability context

Hooks MAY be hidden/once/ephemeral. Injected messages SHALL carry Ability-owned event/path metadata; merged messages preserve effective hook paths/merge marker. Once state restores from new-format AbilityHook metadata/tombstones; unchanged identities do not rerun after restart. Legacy SkillHook state SHALL NOT register AbilityHook handlers or synthesize once state. Ephemeral messages remove/replace after the next response, preserving once semantics.

#### Requirement: Lifecycle payloads are bounded

ToolCallsCompleted payload SHALL include identifiers, mode/count/times, requested calls, normalized outputs, decoded arguments when possible and nested bare multicall details when detectable. Response-start emits once per request; retry/terminal events expose bounded relevant metadata. Tool display line/extmark state stays buffer-local; transient line positions MUST NOT enter history.

#### Requirement: Hard-cut restore quarantines legacy capability state without rewriting history

Pre-cut Chat restore SHALL install the current 17-builtin registry and regenerate the current composed prompt without rewriting stored messages/old tool names. In-memory model projection SHALL exclude structured legacy Skill/MCP instructions, catalogs, guidance and hook injections, including retired package-root `context_file` records, from active capability context; preserve ordinary user/task/spec history and valid tool-call/result pairing.

Legacy once state/loader results/mentions/connection facts authorize nothing. Restore SHALL NOT auto-load/connect/translate authorization/replay events. Explicit new `load` establishes Ability-owned state. New-format readiness requires exact provenance plus protected complete catalog result; missing associations require reload. Storage remains unchanged.

### Validation

#### Evidence retained

- Request watchdog: focused configuration/progress/phase/disable/curl-argument/late-callback cases and timeout-to-single-network-retry integration passed; full Neovim restart loaded effective defaults and ordinary Responses requests completed, with watchdog inactive during local tools. Gemini reuses the OpenAI semantic observation handler. Real provider outages, 180-second stalls and live Gemini/Anthropic requests were not induced; timeout/phase coverage is focused simulated evidence.
- Core lifecycle/Chat/tool/adapter: aggregate final-owner suites passed.
- AbilityHook: overlay, disabled-definition, load-event, injection/restore and legacy-quarantine focused suites passed; no active runtime SkillHook compatibility surface.
- Safe stops: soft-stop 7/7; context-limit 10/10.
- Token flow: threshold decision 19/19; installed real Chat/HTTP 9/9; orchestrator queue/tool cancellation 11/11; soft-stop coverage above; SubAgent completion guard, multi-agent terminal routing and retry recovery passed. Covers ordinary finish/compact, eight-request direct interruption, manual resume, unchanged SubAgent `8 + 3` and no-autonomous-compression messages.
- Prior accepted ask coordinator/raw Chat input, Telegram Bridge 92-test suite, restart-resume, live Telegram-button and Chat-text choices passed; generic `timeout=0`/300-second timeout contracts unchanged.
- Main handoff: explicit threshold-choice handoff: existing 19/19 checks and fresh-Neovim actual four-choice/Alt+4, explicit instruction, Agent-created draft/file message, old closure/new main marker and saved histories passed. Disposable Chat used the existing runtime check entrypoint, not provider-window consumption; no new UI runner/framework.
- Child handoff: explicit child transfer: existing 19 checks, actual final decision/Chat selection, Telegram request creation, injected child instruction and sibling handoff passed. Used supplied warning usage/exhausted-budget position, not provider-window consumption; per-change human review and Telegram button click were `not-run`.
- Human specification review passed: explicit declarations 2026-09-15, 2026-09-16, 2026-09-22 and 2026-10-07.

#### Unrun/limited evidence

- Standalone soft-stop/context-limit live Chat smokes: recommended, not recorded completed; focused headless evidence only.
- Live ordinary-Chat three-choice waiting/compact continuation, real-provider main eight-request exhaustion, real-provider SubAgent `8 + 3` finishing and final timeout interrupt/compact continuation: not run; focused headless/installed Chat/HTTP wrapper evidence only.
- Telegram-unavailable → Chat fallback: focused automation passed; destructive live transport test not run.
- Permanent state: focused automated `passed`; listed live end-to-end matrices `not-run`; human specification review `passed`.

### Source trace

Lifecycle/AbilityHook paths: Ownership above; Chat/tool: `lua/maxa/interactions/chat/`. Parent: [Runtime overview](./overview.md). Historical changes: `add-chat-soft-stop`, `add-chat-context-limit-stop`, `add-token-threshold-human-decision`, `migrate-human-assist-to-ask`, `route-token-threshold-by-session-type`; handoff deltas/tasks: Evidence retained.
