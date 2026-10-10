---
title: Project Vault 稳定规格索引
created: 2026-09-15
updated: 2026-09-22
type: index
status: active
tags: [specs/project-vault, status/active]
sources:
  - .maxa/specs/abilities/base/project-admin/project-vault.md
confidence: high
---

> **TLDR**: 本模块是 `.maxa/` 布局、ProjectAdmin 操作、项目知识治理与外部 Vault 所有权的唯一稳定规格入口。

## 稳定规格

- [[specs/abilities/base/project-admin/project-vault|Project Vault 布局、所有权与治理规格]] — 读取 `.maxa/` 固定根路径、五项基线元数据与 `schema_version`、渐进索引、知识写入、optional `.maxa/abilities/` runtime zone、primary-checkout 外部操作和项目本地 Obsidian 插件分发契约。

## Ownership

- 本模块拥有 Vault layout、checkout ownership、index/log、content/weave/workspace zone 与 ProjectAdmin/Obsidian 边界。
- TaskAdmin 文件语义由 [[specs/abilities/base/task-admin/index|TaskAdmin 模块]]拥有；插件运行时由 [[specs/obsidian-plugins/index|Obsidian Plugins 模块]]拥有。
