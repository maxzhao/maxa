---
title: CodeCompanion.nvim 完整规格反推执行计划
created: 2026-08-01
updated: 2026-08-01
type: plan
doc_role: reverse-spec-plan
authority: draft
status: active
tags: [codecompanion, reverse-engineering, plan]
sources:
  - baseline.md
  - evidence-map.md
       confidence: medium
---

> **TLDR**: 先对锁定版本逐模块完成可验证的行为反推，再调查 SuperMax 偏差和最新上游差异，最后才建立独立运行时的目标规格。

## Goal

产出覆盖 CodeCompanion.nvim `v18.7.0` 用户可观察行为及必要内部状态契约的完整反推规格，并为独立 Agent/Chat 运行时提供事实输入；不复制上游架构，不提前定义目标实现。

## Non-Goals

- 不在反推阶段修改 CodeCompanion.nvim 或 SuperMax 运行时代码。
- 不把文件、函数、路由或配置键清单当作完成的规格。
- 不把最新上游行为混入锁定版本。
- 不在本目录发布 SuperMax 的规范性目标规格。

## Ordered Workstreams

1. **Foundation**: bootstrap/configuration, public commands/API, event model, core message/context types.
2. **Chat core**: lifecycle/UI, submission/request state machine, context/messages, tools and agent loop.
3. **Transport**: HTTP adapters/providers, streaming/error/token behavior, ACP process/session protocol.
4. **Editor interactions**: inline assistant, actions/prompt library, background interactions.
5. **Extensibility**: extensions, parsers, UI customization and integration contracts.
6. **Downstream delta**: map SuperMax patches/extensions against extracted baseline requirements.
7. **Latest-upstream delta**: inspect behavior changes from baseline to pinned comparison commit; update the comparison point only explicitly.
8. **Final audit**: resolve overlaps/conflicts, verify cross-module flows, record remaining unknowns.
9. **Target-spec handoff**: create a separate independent-runtime specification workspace only after explicit behavior-selection decisions.

## Per-Module Procedure

1. Declare behavior surfaces and coverage dimensions.
2. Inspect complete behavior chains: entrypoint → handler/state logic → transport/tool/storage boundary → schema/config constraints → tests/docs.
3. Write operation-level `authority: draft` requirements with GIVEN/WHEN/THEN scenarios.
4. Record failures, cancellation, disabled settings, empty/unsupported inputs, retries/races and external failures when evidenced.
5. Cite baseline commit paths and symbols near each requirement.
6. Run closest upstream tests or a reproducible manual check; record exact result.
7. Audit behavior coverage; mark `partial` if any core chain remains uninspected.
8. Add a distinct latest-upstream delta section only after baseline behavior is stable.
9. Add a distinct SuperMax adaptation mapping only after upstream behavior is stable.

## Artifact Convention

```text
specs/
├── index.md
├── baseline.md
├── evidence-map.md
├── extraction-plan.md
├── coverage-audit.md
├── final-audit.md
├── log.md
├── modules/<module>/spec.md          # create when deep extraction starts
├── downstream/<module>-delta.md      # SuperMax adaptation evidence
└── upstream-deltas/<range>.md         # version-separated upstream differences
```

Nested directories require their own routing `index.md` when created.

## Module Completion Gate

A module is complete only if:

- behavior requirements and scenarios cover every declared operation;
- entrypoint, logic, state/data constraints, boundary integrations, tests/config/docs were inspected;
- failures and observable outcomes are explicit;
- source traces identify the baseline commit and paths;
- validation/review status is recorded;
- behavior coverage audit has no unacknowledged core gap.

## Final Completion Gate

- Every module in `evidence-map.md` is complete or explicitly excluded with rationale.
- Cross-module submission, streaming, tool-loop, cancellation, error, event and editor-mutation flows are audited end to end.
- SuperMax adaptation deltas are classified as defect workaround, compatibility shim, product requirement, or obsolete behavior.
- Latest-upstream deltas are version-separated and reviewed for relevance.
- No artifact claims normative authority.
- Independent-runtime target specification remains a separate, explicit next phase.

## Validation Strategy

- Identity: verify `lazy-lock.json`, upstream commit, tag and `version.txt`.
- Static trace: confirm every cited baseline path exists at the pinned commit.
- Behavioral validation: run closest existing upstream tests for each module; use headless/manual checks when tests do not cover observable behavior.
- Artifact lint: verify frontmatter, links, indexes, source traces and coverage statuses.
- Cross-check: compare extracted behavior with SuperMax hooks only after baseline extraction, never as a substitute.
