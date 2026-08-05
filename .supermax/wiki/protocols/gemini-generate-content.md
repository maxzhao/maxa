---
title: Gemini native API 官方参考（generateContent / streamGenerateContent）
created: 2026-08-04
updated: 2026-08-04
type: protocol-reference
authority: official-source
source:
  - https://ai.google.dev/api/generate-content
usage: maxa 阶段1 Gemini native 适配器实现/验收参考；禁止使用 OpenAI 兼容端点 /v1beta/openai/chat/completions
---

# Gemini native API 参考

> Context7 于 2026-08-04 从 ai.google.dev 官方文档抓取。maxa 目标 Gemini 适配器 MUST 使用 native 端点。

## 端点

- 非流式：`POST https://generativelanguage.googleapis.com/v1beta/{model=models/*}:generateContent`
- 流式：`POST /v1beta/models/{model}:streamGenerateContent`（SSE 分块）

## 请求体

| 字段 | 说明 |
| --- | --- |
| `contents` | 必填；`Content{role, parts[]}` 数组（多轮对话历史 + 最新请求） |
| `tools` | 可选；`Tool[]`，支持 `functionDeclarations[]`（name/description/parameters 或 parametersJsonSchema）与 `codeExecution` |
| `toolConfig` | 可选；function calling 配置 |
| `safetySettings` | 可选；HARM_CATEGORY_HATE_SPEECH / SEXUALLY_EXPLICIT / DANGEROUS_CONTENT / HARASSMENT / CIVIC_INTEGRITY |
| `systemInstruction` | 可选；目前仅 text |
| `generationConfig` | 可选；生成配置 |
| `cachedContent` | 可选；`cachedContents/{id}` |
| `serviceTier` | 可选枚举 |
| `store` | 可选；日志行为 |

Part 数据联合成员（目标支持）：`text`、`inlineData{mimeType, data(base64)}`、`fileData`、`functionCall{id?, name, args(object)}`、`functionResponse{id?, name, response(object)}`。一个 Part 恰好一个成员。

## 响应（GenerateContentResponse）

| 字段 | 说明 |
| --- | --- |
| `candidates[]` | `Candidate{content{parts[], role:"model"}, finishReason, safetyRatings[], index}` |
| `promptFeedback` | `{blockReason?, safetyRatings[]}`；blockReason 表示 prompt 被阻止、无 candidates |
| `usageMetadata` | 见下 |
| `modelVersion` / `responseId` / `modelStatus` | 输出元数据 |

- API 要么返回全部请求的 candidates，要么一个都不返回（问题在 prompt 时查 promptFeedback）
- 空 candidates 且无 block feedback = 显式 `empty-candidates` 协议结果，不是静默成功

## usageMetadata

```json
{
  "promptTokenCount": 0, "cachedContentTokenCount": 0, "candidatesTokenCount": 0,
  "toolUsePromptTokenCount": 0, "thoughtsTokenCount": 0, "totalTokenCount": 0,
  "promptTokensDetails": [], "cacheTokensDetails": [], "candidatesTokensDetails": [],
  "toolUsePromptTokensDetails": [], "serviceTier": ""
}
```

## 目标适配器要点

- 归一化：`candidates[].content.parts[]` 按 candidate/part ordinal 映射 text/functionCall；finishReason/safetyRatings 保留到终态元数据
- `functionCall` 无 `id` 时运行时生成稳定 ID（`id_source="synthetic"`），后续 functionResponse 按运行时 ID/name/ordinal 配对
- streamGenerateContent 每个 SSE 响应包独立处理；可累加 parts/finish/usage；重复累计字段按 response/candidate/part 身份去重
- promptFeedback.blockReason = typed provider failure（非空内容成功）
- 流错误/解码错误/safety 终止/取消/迟到包 → typed 归一结果，恰好一个终态事件
- 目标从不使用 `/v1beta/openai/chat/completions`（pinned CodeCompanion `gemini.lua` 是 OpenAI 兼容实现，仅作反面证据）
