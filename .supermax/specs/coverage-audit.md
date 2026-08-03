---
title: CodeCompanion.nvim 反推行为覆盖审计
created: 2026-08-01
updated: 2026-08-02
doc_role: coverage-audit
authority: draft
status: blocked
tags: [codecompanion, reverse-engineering, coverage]
sources:
  - evidence-map.md
  - final-audit.md
  - https://github.com/olimorris/codecompanion.nvim/tree/558518f8d78a44198cd428f6bf8bf48bfa38d76d
confidence: high
---

> **TLDR**: pinned baseline modules remain partial evidence. SuperMax target modules and official four-protocol field/event sources now cover the selected runtime contract, but executable replacement fixtures—especially protocol adapters, MCP lifecycle, cancellation/late callbacks and persistence—still block acceptance/promotion.

## 2026-08-02 target-convergence addendum

- Added target disposition, hook replacement ownership and executable validation matrix.
- Added target modules for state/orchestration, four protocols, normalized messages/streams/tools, MCP/Skill, history, events/status, async lifecycle, target-project `.maxa/` configuration, Chat UI, Actions/Commands and migration; development `.supermax/` remains specification evidence only.
- Removed ACP and inline modules; workflow execution, approval/permission gates and standalone command-input Chat are explicitly non-target. Retained upstream specs now carry target-disposition boundaries.
- Corrected Gemini evidence: pinned CodeCompanion `gemini` uses Google's OpenAI-compatible endpoint and does not satisfy Gemini native requirements.
- Current hook/runtime tests provide evidence, not replacement-runtime acceptance. See `validation-matrix.md` and `hook-replacement-map.md`.
- Added detailed `protocol-fixture-contract.md`, `runtime-fixture-contract.md`, and `current-runtime-source-inventory.md`; specification-level scenario/schema coverage is substantially expanded, while executable replacement status remains absent.

## Scope

- Target: `specs/` 下当前全部模块及其跨模块行为链。
- Authority: baseline upstream only; all artifacts remain `authority: draft`。
- Excluded: independent-runtime target design, SuperMax downstream behavior, latest-upstream behavior as baseline requirements。

## Final status

- Overall: **blocked**。
- Completed modules: **none**。
- Partial retained modules: `bootstrap-configuration`, `chat-lifecycle`, `message-context`, `tools-agent-loop`, `http-transport`, `background-interactions`, `actions-extensions`, `events-integration`。
- Removed target modules: `acp-protocol`, `inline-assistant`; standalone Neovim command-input Chat mode and workflow runtime are removed, while Actions/Commands remain supported。
- Final report: [[final-audit]]。

## Module matrix

| Module | Chain | Operations/scenarios | Failure/edge | Config/deps | Concurrency/idempotency | Validation/source trace | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Bootstrap/config | broad | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| Chat lifecycle/UI | broad | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| Message/context | broad | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| Tools/agent loop | broad | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| HTTP transport | broad | covered | provider-partial | covered | partial/open | static passed; tests blocked | partial |
| ACP protocol | removed from target | n/a | n/a | n/a | n/a | deletion decision recorded | removed |
| Inline assistant | removed from target | n/a | n/a | n/a | n/a | deletion decision recorded | removed |
| Background | broad | covered | partial | covered | partial/open | static passed; tests blocked | partial |
| Actions/extensions | partial | covered | partial | partial | partial/open | static partial; tests blocked | partial |
| Events/integration | broad | covered | partial | covered | partial/open | static passed; tests not run | partial |

## SuperMax target-module matrix

| Target module | Primary evidence | Status / blocking gap |
| --- | --- | --- |
| `target-scope` | user decisions; `ai.lua` interaction config | drafted; Actions/Commands retained and standalone command-input Chat removed |
| `chat-runtime-state` | chat hooks; baseline chat lifecycle | contract drafted; executable transition/race/recovery fixtures absent |
| `request-orchestrator` | soft stop, watchdog, context-limit, agent-loop hooks | contract/decision table drafted; executable scheduler/retry fixtures absent |
| `provider-contract` | `ai.lua:351-668`; adapters/hooks; official OpenAI/Anthropic/Gemini sources | field/event contract verified; replacement implementations/fixtures absent |
| `message-context-target` | `GenerateSystemPrompt`; message hooks | normalized records/context/submission contract drafted; executable fixtures absent |
| `streaming-usage` | Responses streaming/token hooks; status sources | partial; all four protocol event/usage fixtures absent |
| `tool-runtime` | tool execution/display/completion hooks | definition/batch/concurrency/TTL/failure contract drafted; executable fixtures absent |
| `session-history` | `cc_history`, local history extension, trace hooks | schema v1/atomic persistence/migration contract drafted; executable fixtures absent |
| `events-status` | lifecycle hooks; status/lualine modules | event envelope/order/spine reduction drafted; executable fixtures absent |
| `async-lifecycle` | buffer guard, async cancel, watchdog | partial; cancellation/late-callback probes absent |
| `supermax-configuration` | `ai.lua`, `GenerateSystemPrompt`, schema check | runtime/MCP/prompt schemas drafted; executable validation incomplete |
| `chat-ui` | chat UI/input hooks | view/input/render/host contract drafted; executable detach/reattach fixtures absent |
| `actions-commands-target` | retained action extension evidence; `ai.lua` mappings | partial; inventory drafted, replacement fixtures absent |
| `mcp-skill-runtime` | `mcphub`, SkillHook sources | lifecycle/discovery/SkillHook contract and fixture matrix drafted; executable fixtures absent |
| `migration-compatibility` | hook replacement map | partial; no replacement implementation has passed retirement gates |

## Cross-module audit

- **message → chat:** persistent hidden messages and UI-only buffer output are consistently separated; context/rules/variables/slash mutations feed chat submission. Open: image/context reconciliation and empty/context-only direct tests.
- **chat → transport:** chat owns request state and mapped payload input; supported protocol adapters own provider body/stream lifecycle. ACP is removed. Open: provider-specific builders, custom request bypass, status ordering and callback races.
- **transport → tools:** supported protocol adapter call normalization enters the FIFO tool orchestration; normalized results return to Chat continuation. No ACP path exists in the target. No end-to-end proof.
- **tools → events:** tool start/finish events and `ToolsFinished` continuation are traced; duplicate terminal callbacks and automatic-execution cancellation races remain untested.
- **events → editor:** `utils.fire` synchronously dispatches `User` autocmds; target Chat/provider/tools/actions payloads require a central event contract. Listener failure propagation and teardown ordering remain unknown.
- **editor interaction:** Actions/Commands dispatch, background title callbacks and Chat UI rendering have distinct owners; inline mutation/diff is removed. Late callbacks and buffer-deletion races remain open.

## Overlap/conflict result

No confirmed baseline fact contradiction was found. Public command/API, payload composition, tool handoff and event emission are intentionally cross-referenced with ownership split by stage. One unresolved ownership wording tension remains: chat lifecycle describes continuation through callbacks/subscribers, while tools-agent-loop details the `ToolsFinished` autocmd policy; treat tools-agent-loop as the detailed continuation trace until source review closes it.

## Blocking findings

1. Closest upstream tests have no passing result. Primary exact blocker: `scripts/minimal_init.lua:7: module 'mini.test' not found`; other dependency setup attempts timed out cloning `deps/panvimdoc`/`mini.nvim` and ended `exit 143`.
2. Supported-provider HTTP/native, background and Chat stop/close teardown races are source-only/untested; ACP/inline are removed from target scope.
3. Provider-specific HTTP contracts, built-in tools, action providers/prompts, and asynchronous picker/slash branches are incomplete.
4. User autocmd throwing-listener behavior and duplicate terminal event suppression are unvalidated.
5. Replacement-runtime implementation does not yet exist, so no hook retirement or target-spec promotion claim is valid.
6. Latest-upstream evidence remains separate and partial; it does not change the selected target surface.

## Required work

- [ ] Restore baseline test dependencies without changing pinned checkout; execute focused tests for every module.
- [ ] Run focused headless probes for event listener failures, repeated setup, supported-provider cancellation, late background/view callbacks and tool continuation.
- [ ] Finish provider/builtin/action-picker source traces and validation.
- [x] Repair message-context index authority/status metadata.
- [ ] Complete only target-relevant downstream/latest evidence gaps without reintroducing removed behavior.
- [ ] Rerun final cross-module audit before any promotion claim.

## Validation record

- Identity/static evidence: passed and recorded in module specs; baseline is exact commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d`, version `18.7.0`.
- Source traces: broad static coverage exists for all listed modules; not equivalent to runtime validation.
- Automated behavioral validation: blocked/not run as documented above.
- Final conclusion: blocked; no module or workspace completion claim.
