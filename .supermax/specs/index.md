---
title: CodeCompanion.nvim 规格反推索引
created: 2026-08-01
updated: 2026-08-02
type: index
authority: draft
status: blocked
tags: [specs/codecompanion-reverse-spec, reverse-engineering, status/active]
sources:
  - lazy-lock.json
  - baseline.md
  - coverage-audit.md
  - final-audit.md
  - https://github.com/olimorris/codecompanion.nvim
confidence: high
---

> **TLDR**: This directory started as an evidence-based CodeCompanion `v18.7.0` reverse spec and is now being upgraded in place into a draft SuperMax target specification. It retains supported CodeCompanion concepts, removes unsupported upstream surfaces, and records unresolved source/behavior validation gaps.

## Ownership Boundary

本目录位于开发母仓库的 `.supermax/specs/`，保存上游事实、目标规格草案、覆盖审计、删除决策和迁移输入。
所有文件均为 `authority: draft`，不得作为已接受稳定规格；当前阶段只在本目录内删除、修改和新增。
`.supermax/` 是开发环境的 Agent/知识/规格目录，不是最终运行时项目目录；目标运行时必须使用目标项目的 `.maxa/`，不得依赖本目录或母仓库 `.supermax/`。
唯一 upstream 行为基线为 `558518f8d78a44198cd428f6bf8bf48bfa38d76d`（`v18.7.0`）；latest-upstream 只作比较证据。SuperMax downstream 行为可以进入 target modules，但必须标明来源和目标性质。

## Reading Order

1. [[baseline|反推基线]] — 版本、证据优先级和可复现边界。
2. [[evidence-map|证据地图]] — upstream 模块入口与行为链入口。
3. [[extraction-plan|反推执行计划]] — baseline 模块完成门槛与验证策略。
4. [[coverage-audit|行为覆盖审计]] — upstream 模块矩阵、阻塞项和下一步。
5. [[final-audit|最终跨模块审计]] — upstream message→chat→transport→tools→events 行为链。
6. [[modules/target-scope/spec|目标范围与删除项]] — 四协议、Chat-only surface、保留 Actions/Commands 与删除项。
7. `modules/*-target/spec.md` — SuperMax 目标状态机、编排器、provider、工具、历史、状态、配置和宿主模块。
8. [[module-disposition|Module target disposition]] — retained/redefined/baseline-only/removed classification.
9. [[hook-replacement-map|Hook replacement map]] — current patches to target owners and retirement gates.
10. [[validation-matrix|Target runtime validation matrix]] — runtime-wide acceptance scenarios.
11. [[protocol-fixture-contract|Four-protocol fixture contract]] — request/stream/tool/usage/error fixture schemas and completion gates.
12. [[runtime-fixture-contract|Runtime replacement fixture contract]] — state, cancellation, tools, MCP/Skill, persistence, status/UI/configuration acceptance fixtures.
13. [[current-runtime-source-inventory|Current runtime source inventory]] — behavior-bearing source families and target ownership.
14. [[implementation-sequence|Replacement runtime implementation sequence]] — dependency-ordered implementation and cutover gates.
15. `downstream/index.md` — 当前 SuperMax 代码对 upstream 行为的适配与目标决策。
16. [[log|维护日志]] — 基线、目录和目标规格变化。

## Module Status

Retained upstream modules remain `status: partial`: `bootstrap-configuration`, `chat-lifecycle`, `message-context`, `tools-agent-loop`, `http-transport`, `background-interactions`, `actions-extensions`, `events-integration`.

Removed from target scope: ACP protocol and inline assistant. The standalone Neovim command-input Chat surface and workflow runtime are also removed; Actions and Commands remain supported through `modules/actions-extensions/` and `modules/actions-commands-target/`.

New target modules currently `status: partial`: `target-scope`, `chat-runtime-state`, `request-orchestrator`, `provider-contract`, `message-context-target`, `streaming-usage`, `tool-runtime`, `session-history`, `events-status`, `async-lifecycle`, `supermax-configuration`, `chat-ui`, `actions-commands-target`, `mcp-skill-runtime`, `migration-compatibility`.

Completed modules: none. The final audit found no confirmed baseline fact contradiction; unresolved gaps are validation, race, provider/builtin breadth, downstream/latest delta, and one index metadata issue documented in `coverage-audit.md` and `final-audit.md`.

## Promotion Boundary

目标规格完成前，本目录内容仍是 draft。完成后，目标模块将作为重写框架的实现输入；upstream-only 事实、删除项和兼容层决策必须保持可追溯。不得在验证前声称代码/规格已收敛。
