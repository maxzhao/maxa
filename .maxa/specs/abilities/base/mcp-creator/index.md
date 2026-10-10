---
title: MCP Creator 基础能力规格入口
created: 2026-10-11
updated: 2026-10-11
type: index
status: active
---

> **TLDR**: 本能力拥有 MCP 开发/维护、LLM-facing 契约和 reload 流程，不拥有所有 MCP 服务的产品行为。

- [MCP Creator workflow](./mcp-creator-workflow.md) — Native/External 选型、schema/result、验证、Lua 全重启与外部进程/backend 重启。

Hub/transport、live schema authority 和通用 streaming primitive 属于运行时；各能力或独立服务保留自己的接口 owner。
