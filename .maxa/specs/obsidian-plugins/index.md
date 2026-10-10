---
title: Obsidian Plugins 稳定规格索引
created: 2026-09-15
updated: 2026-09-15
type: index
status: active
tags: [specs/obsidian-plugins, status/active]
sources:
  - obsidian-plugins/
confidence: high
---

> **TLDR**: 本模块按自维护源码 package 分文件描述 Obsidian 插件行为；Project Vault、发布和分发治理由 Project Vault 模块拥有。

## Workflow Plugins

- [[specs/obsidian-plugins/grab-note|Grab Note Feedback]] — Markdown/Canvas feedback capture and pending queue publication.
- [[specs/obsidian-plugins/deepseek-translate|DeepSeek Translate]] — full-document cache-compatible translation.
- [[specs/obsidian-plugins/todoseq-card-board|TODOseq Card Board]] — Markdown task parsing, board UI, ports, and source write-back.

## Utility Plugins

- [[specs/obsidian-plugins/semantic-graph-labels|Semantic Graph Labels]] — semantic graph labels without path renames.
- [[specs/obsidian-plugins/sync-conflict-resolver|Sync Conflict Resolver]] — Syncthing conflict review and merge choice.
- [[specs/obsidian-plugins/disable-unresolved-link|Disable Unresolved Link]] — confirmation before missing-note creation.

## Boundary

Plugin build/publish/distribution and Vault destination policy follow [[specs/abilities/base/project-admin/project-vault|Project Vault Governance]]. This module owns plugin runtime behavior by source package only.
