---
title: CodeCompanion.nvim 最终跨模块行为覆盖审计
created: 2026-08-01
updated: 2026-08-02
type: audit
doc_role: final-cross-module-audit
authority: draft
status: blocked
tags: [codecompanion, reverse-engineering, final-audit, coverage]
sources:
  - baseline.md
  - evidence-map.md
  - extraction-plan.md
  - coverage-audit.md
  - modules/
confidence: high
---

> **TLDR**: baseline reverse extraction remains partial evidence. SuperMax target contracts are now drafted and dispositioned, but replacement implementation fixtures and acceptance evidence remain blocked; no promotion or CodeCompanion removal claim is made.

## 2026-08-02 target audit addendum

The original sections below remain baseline audit evidence. Target authority is now split across `module-disposition.md`, target modules, `hook-replacement-map.md`, and `validation-matrix.md`.

- Only OpenAI Chat Completions, OpenAI Responses, Anthropic Messages and Gemini native API are normative.
- ACP, inline assistant, workflow execution, approval/permission gates and standalone command-input Chat are removed; Actions and Commands remain runtime capabilities on the Chat surface.
- MCP, Skill, history/trace/compaction, target-project `.maxa/` prompt/configuration, spine/lualine and LazyVim host integration are target core subsystems. The development mother repository's `.supermax/` remains evidence/governance only.
- Existing hook tests validate current compatibility behavior only. Replacement fixtures remain the acceptance gate.
- Official OpenAI API/OpenAPI, Anthropic SDK and Gemini API sources were retrieved through Context7 on 2026-08-02; core four-protocol field/event evidence is no longer blocked.

## Audit boundary

- 唯一行为基线：`olimorris/codecompanion.nvim@558518f8d78a44198cd428f6bf8bf48bfa38d76d`（`v18.7.0`）。
- 审计对象：本工作区基础文档与 `modules/*/{index.md,spec.md}` 的当前全部内容。
- 本文只审计反推覆盖，不定义 SuperMax downstream、latest-upstream 或独立运行时目标行为。
- 未修改任何模块规格正文；本轮发现的是覆盖/元数据/验证缺口，不是足以改写模块事实正文的明确事实错误。

## Module completion gate

| Module | 完整行为链 | 操作级需求/场景 | 失败/边界 | 配置/依赖 | 并发/idempotency | 验证/source trace | Final status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bootstrap-configuration | broad/partial | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| chat-lifecycle | broad/partial | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| message-context | broad/partial | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| tools-agent-loop | broad/partial | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| http-transport | broad/partial | covered | partial by provider | covered | partial/open | static passed; tests blocked | partial |
| acp-protocol | removed from target | n/a | n/a | n/a | n/a | deletion decision recorded | removed |
| inline-assistant | removed from target | n/a | n/a | n/a | n/a | deletion decision recorded | removed |
| background-interactions | broad/partial | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| actions-extensions | partial | covered | partial | partial | partial/open | static partial; tests blocked | partial |
| events-integration | broad/partial | covered | partial | covered | partial/open | static passed; tests not run | partial |

**Completed modules:** none. “Broad” means the declared core source chain is traceable; it does not satisfy the completion gate while dynamic validation or acknowledged core gaps remain.

## End-to-end chain audit

### 1. Message → chat state

`message-context` owns buffer parsing, persistent/hidden/UI-only message separation, context/rules/variables/slash mutation and generic payload input. `chat-lifecycle` owns submit guards, request state, render/finalize/stop/close. Their boundary is consistent: UI-only `add_buf_message` does not enter provider payload; hidden `add_message` records may enter it. Remaining gaps are system-prompt/rules changes across adapter changes, image/context reconciliation, and direct tests for context-only/empty submissions.

### 2. Chat → transport

HTTP/native selection/build/send is split consistently between `chat-lifecycle`, `message-context`, and `http-transport`: chat provides mapped messages/settings/tools; transport/adapters execute protocol-specific body/stream lifecycle. The target removes the ACP handler/session path. Remaining gaps: provider-specific builders beyond representative families, custom request bypass semantics, non-stream/status-error ordering, and cancellation/final callback races.

### 3. Transport → tools → continuation

For supported providers, adapter call normalization enters the FIFO tool coordinator; results return as normalized tool-result messages; the tool-batch policy schedules at most the intended follow-up submit under the request guard. The target has no ACP continuation path. No end-to-end fixture yet proves provider re-submit, duplicate terminal callback suppression, or cancellation/exit behavior.

### 4. Events across the chain

All modules agree that `utils.fire(event,payload)` synchronously prefixes `CodeCompanion` and dispatches a `User` autocmd without local `pcall`. The target replaces distributed Chat/provider/tools/action payloads with a central event schema. `events-integration` remains upstream timing evidence; target `events-status` owns the new contract. Remaining gaps: throwing-listener propagation, duplicate setup/listener registration, teardown races, and a complete terminal sequence matrix.

### 5. Editor interaction

Actions own discovery/template expansion and dispatch into runtime interactions. Background owns non-chat provider callbacks/title mutation. Chat UI owns Chat buffer rendering/navigation. Inline editor mutation/diff behavior is removed from target scope. Remaining gaps: scheduled mutation after buffer deletion, late background title after Chat close, picker/provider branches and extension/parser failure isolation.

## Overlap and conflict findings

- **Acceptable overlap:** public Action/Command/API appears in bootstrap, events, Chat and actions. Bootstrap owns registration/argument dispatch; destination modules own interaction semantics; events owns emitted integration signals. Inline is removed from target scope.
- **Acceptable overlap:** generic payload composition appears in message-context and HTTP transport. Message-context owns records entering payload; HTTP owns adapter/body/transport mapping.
- **Acceptable overlap:** tool boundaries appear in chat lifecycle and tools-agent-loop. Chat owns handoff/finalization; tools owns automatic execution/result/continuation.
- **Potential wording tension, not a proven fact conflict:** chat lifecycle says `ToolsFinished` continuation may come from callbacks/subscribers, while tools-agent-loop specifies its autocmd continuation policy. Read together, the latter is the detailed owner; no module text was changed.
- **No baseline/latest/downstream contamination found** in module authority statements.

## Blocking items

1. No module has a passing closest upstream behavioral test run. Most attempts fail at `scripts/minimal_init.lua:7: module 'mini.test' not found`; some dependency recipes time out cloning `deps/panvimdoc`/`mini.nvim` (`exit 143`).
2. Cross-module cancellation and teardown races remain unvalidated: supported-provider cancel/final/late chunk, Chat/view detach versus stop/close, and background title callback versus close. ACP and inline are removed from target scope.
3. Provider and builtin domain coverage is incomplete: every HTTP provider field/error/usage contract, all built-in tools, all action providers/prompts, and asynchronous slash/picker branches are not fully traced/tested.
4. Event listener failure propagation and duplicate terminal-event suppression are source-only unknowns.
5. The message-context index metadata gap was repaired on 2026-08-02.
6. Replacement-runtime tests remain absent; target acceptance and hook/dependency retirement are therefore blocked.

## Next steps

1. Restore baseline test dependencies without changing the pinned source, then run each module’s exact listed focused tests and record pass/fail.
2. Add focused headless probes for listener failure, duplicate setup, supported-provider cancellation races, late background/view callbacks, and tool-loop continuation.
3. Complete provider/builtin/action-picker evidence gaps and update each module status only after its own completion gate passes.
4. Implement and run the replacement-runtime matrix before changing any target module to accepted/complete.
5. Complete target-relevant evidence gaps without restoring removed upstream behavior; then rerun this audit.

## Static validation record

The final validation commands and exact results are recorded in `coverage-audit.md`. This audit’s conclusion is `blocked`; no behavioral test pass or completed module is claimed.
