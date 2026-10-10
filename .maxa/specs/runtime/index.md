---
title: 运行时基础规格与依赖入口
created: 2026-09-15
updated: 2026-10-11
type: index
doc_role: index
status: active
---

> **TLDR**: 先读宿主与能力加载基础，再进入 Chat/protocol、生命周期和编辑器集成；这些公共机制不由单项能力拥有。

## 1. 运行时与组合

- [Runtime overview](./overview.md) — Runtime/Soul、authority、能力层、验证与 owner 分工。
- [Maxa AI](./maxa-ai.md) — repository-owned maxa runtime、HTTP Chat、命令/历史接入与公共身份。
- [Plugin entrypoints](./plugin-entrypoints.md) — provider/defaults、系统提示组合、媒体 wiring、MCPHub 与编辑器持久化。

## 2. 能力与 MCP 基础

- [Ability package and authoring](./package-and-authoring.md) — identity、discovery、overlay、executor、原子加载/catalog、地址 grammar、管理与 authoring。
- [Request routing and Ability Gate](./request-routing-and-skill-gate.md) — 请求分类、首次加载、精确 Chat disclosure 与 TaskAdmin 边界。
- [MCPHub runtime](./mcphub-runtime.md) — Hub/setup/backend、project-keyed transport、授权与连接分离、面板及 Native 框架。
- [MCP schema and guidance](./mcp-doc-cache-contracts.md) — live schema authority、包内 description overrides、Ability guidance 与退役中央 cache。
- [Native shared params and streaming](./native-shared-params-and-streaming.md) — null/default 参数与可复用 streaming/retry/cancel primitive；不是独立用户工具。

## 3. Chat 与协议

- [Chat builtins](./chat-builtins.md) — bare builtin inventory、标题化 run/批处理、Ability dispatch、async/TTL、交互及 Tool Display/fold 的详细 owner。
- [Chat commands](./chat-commands.md) — slash identity、fragments、branch/scratch、rewind、upload、PID 局域网文件访问与 trace 入口。
- [OpenAI Responses adapter](./openai-responses-adapter.md) — Chat/LLM wire、事件归一化与显式 provider extension；不同于 GenAI 媒体 driver。
- [Image analysis](./image-analysis.md) — analyze 联合有序图片与隔离 hidden child；不是普通 SubAgent 会话。

## 4. 生命周期与编辑器

- [Lifecycle and message injection](./lifecycle-and-message-injection.md) — events、safe stop、token decision、budget 与通用 AbilityHook engine。
- [Session history](./session-history.md) — Chat 存储、恢复、history UI、transfer transaction、trace membership 与 cache；session 能力只消费这些机制。
- [[specs/runtime/godot-tooling/index|Godot editor tooling]] — 自动 GDScript/GDShader language tooling；不属于 GDA CLI 或 neovim Ability 的只读查询工具。

## 退役边界

- [Copilot Proxy retirement](./copilot-proxy-retirement.md) — 保留禁止恢复旧 Proxy/Agent Loop 的 tombstone；现行 gateway/quota owner 为 plugin entrypoints。

SubAgent、Session 工具/压缩和 MCP Creator 工作流从能力分类进入；移动规格不改变 Runtime 的 always-on 授权、安全或加载边界。
