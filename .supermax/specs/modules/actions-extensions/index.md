---
title: CodeCompanion actions/extensions 反推模块索引
created: 2026-08-01
updated: 2026-08-01
type: index
doc_role: reverse-spec-module-index
authority: draft
status: partial
baseline_commit: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
baseline_version: v18.7.0
tags: [specs/codecompanion-reverse-spec, actions, prompt-library, extensions, parsers, ui]
---

> 本目录只保存 upstream CodeCompanion.nvim pinned baseline 的事实型反推草案；不包含 SuperMax downstream、latest-upstream 或目标设计。

## Documents

- `spec.md`：操作级行为需求、场景、状态/失败/配置/依赖、验证与 source trace。

## Scope

覆盖 action palette 与 prompt library 的 discovery、visibility selection、Markdown/YAML/Tree-sitter 解析、placeholder expansion、interaction dispatch；extension resolve/validation/load/register/exports；rules parser contract；以及由 User autocmd 事件驱动的外部 UI customization。当前标记 `partial`：未能完成可运行测试套件，部分入口调用链和 UI examples 仍需后续补证。

## Evidence Boundary

- 唯一行为基线：`olimorris/codecompanion.nvim@558518f8d78a44198cd428f6bf8bf48bfa38d76d` (`version.txt=18.7.0`)。
- checkout：`~/.local/share/nvim/lazy/codecompanion.nvim`，HEAD 为 detached exact baseline，工作树状态输出为 `## HEAD (no branch)`。
- 不将本目录内容视为规范性目标需求；任何未由 baseline source/test/doc 支持的内容标为 gap 或 inference。
