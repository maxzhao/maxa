---
title: Maxa 规格分类与阅读入口
created: 2026-04-24
updated: 2026-10-13
type: index
doc_role: spec-index
status: active
tags: [knowledge/sources, knowledge/source-index, status/active]
sources:
  - specs/runtime/index.md
  - specs/abilities/index.md
  - specs/tools/index.md
  - specs/prompts/index.md
  - specs/services/index.md
  - specs/obsidian-plugins/index.md
confidence: high
---

> **TLDR**: 按实际契约归属分类；先理解运行时，再选择基础/扩展能力或独立组件，每项行为只有一个正式 owner。

## 建议阅读顺序

| 顺序 | 入口 | 何时读取与归属 |
| --- | --- | --- |
| 1 | [运行时基础](./runtime/index.md) | Runtime/Soul、AI/Chat、Ability package/Gate、MCPHub/shared primitives、session history 和编辑器集成；不依赖加载某项能力才生效。 |
| 2 | [能力规格](./abilities/index.md) | 先基础能力，再扩展能力；按 Ability identity 存放工作流和复合工具契约。 |
| 3 | [独立工具](./tools/index.md) | CLI/协议拥有独立契约，被能力消费但不因此转移 owner；当前为 GDA。 |
| 4 | [Prompt 产物契约](./prompts/index.md) | 共享 Markdown Prompt grammar、插入/发现与 command library；不是 prompt-engineering 方法规格。 |
| 5 | [独立服务](./services/index.md) | Telegram Bridge、Request Dump Proxy 自有协议、状态与授权。 |
| 6 | [Obsidian 插件](./obsidian-plugins/index.md) | 按源码 package 查询插件运行行为；分发治理由 project-admin 拥有。 |

这是理解顺序，不是执行依赖或强制 Ability 加载顺序；按问题选择 owner，无需通读全部规格。

## 待验证变更

- [待验证变更](./changes/index.md)

## 分类边界

- 能力只分基础/扩展两类；基础名单由能力索引列明，其他 Ability 均为扩展。仅移动规格，不改变运行包发现路径、默认启用或工具授权。
- 通用运行时、独立工具、Prompt 产物、服务和插件不因调用/依赖某项能力就归入该能力。混合文件保留完整正文及其主要 owner，不重复拆造契约。
- 索引路由直接子索引或直属文件；正式规格保留行为、状态、锚点及实际证据限制，维护历史由 [[specs/log|规格日志]]拥有。旧日志中的路径是事件发生时的历史位置，不是当前导航。
