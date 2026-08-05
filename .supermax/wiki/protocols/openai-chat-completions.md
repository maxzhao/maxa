---
title: OpenAI Chat Completions API 官方参考
created: 2026-08-04
updated: 2026-08-04
type: protocol-reference
authority: official-source
source:
  - https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
  - https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
  - https://github.com/openai/openai-openapi
usage: maxa 阶段1 OpenAI Chat Completions 适配器实现/验收参考；字段与事件以本文件为准，实施时复查漂移
---

# OpenAI Chat Completions API 参考

> Context7 于 2026-08-04 从上述官方来源抓取。用于 `openai_chat` 适配器 request/stream/tool/usage/error 映射。

## 请求（POST /v1/chat/completions）

核心参数：

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `model` | string | 必填 |
| `messages` | array | 必填；`{role, content}`，role ∈ developer/system/user/assistant/tool |
| `stream` | boolean | 流式响应；`stream_options.include_usage=true` 时最终 chunk 带 usage |
| `stream_options` | object | `{include_usage, include_obfuscation}`；仅 stream=true 时可设 |
| `tools` | array | 函数工具声明（非空才发送；空则省略字段） |
| `tool_choice` | string\|object | none/auto/required/具体 tool 定义 |
| `temperature` / `top_p` / `stop` / `user` | — | 采样参数；`user` 已弃用，改用 `prompt_cache_key` |

工具声明形状（function tools）：

```json
{
  "type": "function",
  "function": { "name": "...", "description": "...", "parameters": { "type": "object", "properties": {}, "required": [] } }
}
```

消息内 assistant 工具调用：`message.tool_calls[]` 含 `id`、`type`、`function{name, arguments(string JSON)}`。
工具结果：`{role:"tool", tool_call_id, content}`。

## 流式响应（chat.completion.chunk）

- `id` / `object`(=chat.completion.chunk) / `created` / `model` / `system_fingerprint`
- `choices[]`：`index`、`delta{role?, content?, tool_calls[]?}`、`finish_reason`
- `usage`：仅 `stream_options.include_usage=true` 时在**最终 chunk**（可无 choices）出现

usage 字段：

| 字段 | 说明 |
| --- | --- |
| `prompt_tokens` | 输入 token |
| `completion_tokens` | 输出 token |
| `total_tokens` | 合计 |
| `completion_tokens_details` | 输出明细（含 reasoning_tokens 等） |
| `prompt_tokens_details` | 输入明细（cached_tokens 等） |

## 非流式响应

- `choices[].message{role, content, tool_calls[]?}` + `choices[].finish_reason`
- 顶层 `usage{prompt_tokens, completion_tokens, total_tokens}`

## finish_reason 取值

`stop`、`length`、`tool_calls`、`content_filter`、`function_call`（legacy）。

## 流式工具调用片段规则

- `choices[].delta.tool_calls[]` 按 `index` 标识同一调用；后续片段只追加 `function.arguments`（字符串拼接）
- 工具参数是 UTF-8 字符串，只在工具边界解码为 JSON
- `id` 缺失时目标适配器生成合成 ID 并标记 `id_source="synthetic"`

## 目标适配器归一化映射要点

- 请求：normalized message → `messages[]`；tool_call → `tool_calls[]`（只含 id/type/function）；tool_result → tool role；image → `image_url` content part（`data:<mime>;base64,<data>`）
- 流：`choices[].delta` → assistant delta；usage-only chunk（无 choices）只更新 usage 不产出内容
- `[DONE]` 或 EOF 不是完成本身；若存在更早的 typed failure，以 failure 为准
- 错误：HTTP ≥400 归一为 typed error（authentication/rate_limited/quota/network/protocol 等）
