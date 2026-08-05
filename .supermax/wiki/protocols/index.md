---
title: 官方协议参考索引
created: 2026-08-04
updated: 2026-08-04
type: index
authority: official-source
usage: maxa 阶段1 四协议适配器实现/验收的开发参考；协议字段以各文档为准，实施时复查官方漂移
---

# 官方协议参考

> 2026-08-04 抓取整理的官方协议文档，用于 maxa 阶段1 适配器开发与 fixture 验收对照。
> Context7 来源为官方仓库/文档（openai-openapi、anthropic-sdk-typescript、ai.google.dev、developers.openai.com）；
> DeepSeek 来源为官方 api-docs.deepseek.com（中文）。

## 四协议官方参考

| 文档 | 协议 | 用途 |
| --- | --- | --- |
| [[openai-chat-completions]] | OpenAI Chat Completions | request/stream/tool/usage/finish 映射 |
| [[openai-responses]] | OpenAI Responses | items/SSE 事件序/终态/tool-only 流 |
| [[anthropic-messages]] | Anthropic Messages | system 分离/content-block/tool_use/tool_result/thinking/usage |
| [[gemini-generate-content]] | Gemini native | generateContent/streamGenerateContent/parts/usageMetadata |
| [[deepseek]] | DeepSeek（真实验证） | 三协议端点差异、模型、测试 key 约定 |

## 原始抓取文档（DeepSeek）

- `deepseek-chat-completion.md` — Chat Completions API 官方文档（含流式示例、thinking 参数）
- `deepseek-responses.md` — Responses API 官方文档（input item 类型、reasoning、流式终态）
- `deepseek-anthropic-api.md` — Anthropic API 兼容指南（base_url、模型映射、头部兼容性）

## 与规格的关系

- 字段级验收契约：`.supermax/specs/protocol-fixture-contract.md`（四协议 fixture 场景与断言）
- 协议能力矩阵：`.supermax/specs/modules/provider-contract/spec.md`
- 本目录为官方原始证据；specs 为目标行为契约；两者冲突时以官方当前文档复查后更新契约
