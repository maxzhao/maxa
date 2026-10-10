---
title: Godot Tooling 稳定规格模块索引
created: 2026-09-15
updated: 2026-09-15
type: index
doc_role: spec-index
authority: normative
status: active
sources:
  - user-acceptance:2026-09-15
confidence: high
---

> **TLDR**: 本模块拥有 Neovim 内 Godot 语言工具链；GDA CLI/runtime 规格由独立的 `specs/tools/gda/` 模块拥有。

# Godot Tooling Stable Specification Index

- [[specs/runtime/godot-tooling/language-tooling|Godot 自动语言工具链行为规格]] — GDScript project service、GDShader LSP/installer、Treesitter 与生命周期命令。

## Ownership Boundary

GDA 的 CLI、headless、authoring、live runtime、API/docs、Editor testing 与发布契约从 [[specs/tools/gda/index|GDA 稳定规格模块]] 进入；本模块不重复这些行为。
