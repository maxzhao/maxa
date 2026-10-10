---
title: 基础与扩展能力规格入口
created: 2026-09-15
updated: 2026-10-11
type: index
status: active
sources: [specs/abilities/base/index.md, specs/abilities/extensions/index.md]
confidence: high
---

> **TLDR**: 能力规格按基础/扩展两类存放；类别只表示本项目的规格归属，不改变 Ability loader、权限或默认行为。

## 阅读顺序

1. [[specs/abilities/base/index|基础能力]] — 环境/浏览器与内容工具、能力工程、项目治理、会话/角色协作及经验反馈。
2. [[specs/abilities/extensions/index|扩展能力]] — 基于基础 browser 的 QA/E2E、Blender 与生产错误修复等专项能力。

## 精确分类

基础能力固定为：`ability-creator`、`agency-nexus`、`browser`、`genai`、`git-workspace`、`mcp-creator`、`neovim`、`project-admin`、`prompt-engineering`、`resource-scout`、`self-improvement`、`session`、`spec-admin`、`subagent`、`task-admin`、`web-fetch`、`winctl`、`wsl-windows`。其他 Ability 均为扩展能力。

基础/扩展子索引只收录现有独立规格，并显式标注覆盖空白；不根据 Ability 名单生成空规格或提升 experimental/partial/not-run 状态。

## 非能力 owner

通用 package/discovery/loading/authoring、Gate、MCPHub/schema/streaming 属于运行时规格；GDA CLI 属于独立工具规格。目录分类不把宿主机制变成某项 Ability 的加载后规则，也不移动仓库根 `abilities/<name>/` 或项目 `.maxa/abilities/<name>/` 运行包。基础分类不意味着自动加载能力或连接其服务。
