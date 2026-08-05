---
title: Anthropic Messages API 官方参考
created: 2026-08-04
updated: 2026-08-04
type: protocol-reference
authority: official-source
source:
  - https://github.com/anthropics/anthropic-sdk-typescript/blob/main/src/resources/messages/messages.ts
usage: maxa 阶段1 Anthropic Messages 适配器实现/验收参考；字段与事件以本文件为准，实施时复查漂移
---

# Anthropic Messages API 参考

> Context7 于 2026-08-04 从 anthropics/anthropic-sdk-typescript 官方 SDK 抓取。用于 `anthropic_messages` 适配器。

## 请求（POST /v1/messages）

`MessageCreateParamsBase` 必填字段：`max_tokens`、`messages`、`model`。
可选字段：`system`(string 或 TextBlockParam 数组)、`stream`、`stop_sequences`、`temperature`、`top_k`、`top_p`、`thinking`、`tool_choice`、`tools`、`cache_control`、`metadata`、`service_tier`。

消息 role：`user` / `assistant`（无独立 tool role；工具结果走 user 角色 tool_result block）。

## Content blocks

请求侧 ContentBlockParam 支持：`text`、`image`、`document`、`thinking`、`redacted_thinking`、`tool_use`、`tool_result`、`search_result`、server/web 工具结果等。

- `tool_use`：`{type:"tool_use", id, name, input(object)}`
- `tool_result`：`{type:"tool_result", tool_use_id, content, is_error?}`（user 角色内）
- `thinking`：`{type:"thinking", thinking, signature?}`（需配置 thinking 能力；redacted 变体无内容）

## 流式事件（SSE）

`RawMessageStreamEvent` 联合：

| 事件 | 字段要点 |
| --- | --- |
| `message_start` | `message{role, usage{input_tokens, output_tokens, cache_creation_input_tokens?, cache_read_input_tokens?}, stop_reason:null}`；建立初始 usage |
| `content_block_start` | `index`、`content_block`（text/thinking/tool_use 等；tool_use 含 id/name） |
| `content_block_delta` | `index`、`delta`（`text_delta.text` / `thinking_delta.thinking` / `signature_delta.signature` / `input_json_delta.partial_json`） |
| `content_block_stop` | `index` |
| `message_delta` | `delta{stop_reason}`、`usage{output_tokens}`（更新输出 usage） |
| `message_stop` | 结束 |
| `ping` | keepalive，不产出内容 |

## stop_reason 取值

`end_turn`、`max_tokens`（截断，须与完成区分）、`stop_sequence`、`tool_use`、`pause_turn`、`refusal`、`model_context_window_exceeded`。
流式模式下 `message_start` 中为 null，其余事件非 null。

## usage 字段

- `input_tokens`、`output_tokens`（必填）
- `cache_creation_input_tokens` / `cache_read_input_tokens`（nullable，存在时计入归一化 input/cache，不得重复计数）
- 归一化：input = input_tokens + cache_creation + cache_read（按供应商语义）；cache 字段单独保留

## 目标适配器要点

- system 消息 → `system` text blocks，从 `messages` 移除
- assistant tool 调用 → `tool_use` block（input 为解码后的 object）；工具结果 → user 角色 `tool_result`
- 相邻同 role 消息与 tool_result 合并，不丢失调用身份
- thinking/signature 仅在配置的模型/协议能力要求往返时保留
- 空 user 续写需显式非空占位符（目标配置决定）
- `partial_json` 按 content-block index 累积到对应工具 input
- 错误：HTTP ≥400 带错误体 → typed error；SDK 流错误/abort 为终态
