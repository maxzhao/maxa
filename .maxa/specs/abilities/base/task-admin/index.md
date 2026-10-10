---
title: TaskAdmin 稳定规格索引
created: 2026-09-15
updated: 2026-09-21
type: index
status: active
tags: [specs/taskadmin, status/active]
sources:
  - .maxa/specs/abilities/base/task-admin/core.md
  - .maxa/specs/abilities/base/task-admin/browser-ui.md
confidence: high
---

> **TLDR**: TaskAdmin 核心拥有单层任务工作区、plan/TODO/metadata/lifecycle；Neovim Browser 只读导航和展示，不成为第二套状态源。

## 稳定规格

- [[specs/abilities/base/task-admin/core|TaskAdmin 核心行为规格]] — 单层 task workspace、plan/TODO、integer dependency、tag、lifecycle、SpecAdmin integration 与可选 workspace binding。
- [[specs/abilities/base/task-admin/browser-ui|TaskAdmin Browser UI 行为规格]] — peer-task commands、picker、plan/TODO navigation、tag 与 lualine 展示。

## Boundary

TaskAdmin 核心是任务状态权威；Browser 仅导航和展示。Git workspace 的创建/清理算法由 [[specs/abilities/base/git-workspace/git-workspace|Git Workspace Workflow]]拥有。
