---
title: DeepSeek API 协议概览（阶段1 真实 provider 验证）
created: 2026-08-04
updated: 2026-08-04
type: protocol-reference
authority: official-source
source:
  - https://api-docs.deepseek.com/zh-cn/api/create-chat-completion
  - https://api-docs.deepseek.com/zh-cn/api/create-response
  - https://api-docs.deepseek.com/zh-cn/guides/anthropic_api
usage: maxa 阶段1 真实 provider 两层验证（gate）使用；测试 token 从项目根 .env 的 DEEPSEEK_TEST_KEY 读取；模型 deepseek-v4-flash
---

# DeepSeek API 概览

> 2026-08-04 官方文档抓取整理。原始抓取文档：
> - `deepseek-chat-completion.md`（1051 行）
> - `deepseek-responses.md`（597 行）
> - `deepseek-anthropic-api.md`（220 行）

## 端点与 base_url

| 协议 | base_url | 端点 |
| --- | --- | --- |
| OpenAI Chat Completions | `https://api.deepseek.com`（beta 功能用 `/beta`） | `POST /chat/completions` |
| OpenAI Responses | `https://api.deepseek.com` | `POST /responses` |
| Anthropic API 兼容 | `https://api.deepseek.com/anthropic` | `POST /v1/messages` |
| Gemini | **不支持** | — |

认证：`Authorization: Bearer <DEEPSEEK_TEST_KEY>`；Anthropic 兼容端点用 `x-api-key`（`anthropic-version`/`anthropic-beta` 被忽略）。

## 模型

- `deepseek-v4-flash`：Responses API **仅支持此模型**；Anthropic 兼容端点不支持的模型名自动映射到它
- `deepseek-v4-pro`：仅 Chat Completions / Anthropic（claude-opus* 映射）
- 思考强度：flash 支持 low/medium/high 三档（默认 high）；pro 支持 high/max

## Chat Completions 行为（OpenAI 兼容）

- 流式 `chat.completion.chunk` SSE；final chunk（finish_reason 非 null）携带 `usage{prompt_tokens, completion_tokens, total_tokens}`
- reasoning 参数控制思考模式（参考官方 thinking_mode 指南）

## Responses API 行为（OpenAI Responses 兼容，含差异）

- **无状态**：服务端不存储响应/会话；多轮对话必须客户端在 `input` 回传完整历史
- 支持 input item：`message` / `function_call` / `function_call_output` / `reasoning` / `web_search_call`，其他类型忽略
- 角色：`user` / `assistant` / `system` / `developer`（developer 视同 system）
- **不支持图片/文件输入**：`input_image` 不报错但替换为占位文本
- `input` 与 `instructions` 至少传一个
- `reasoning`：`none` 关闭；`minimal/low`→low；`medium/high/xhigh`→high；`max`→max；不传默认开启
- 流式事件：最后事件为 `response.completed` / `response.incomplete` / `response.failed`（**无 `data: [DONE]`**）
- 工具：函数名 `^[a-zA-Z0-9_-]+$`、≤128 字符、全局唯一；额外支持服务端内置 `web_search` 工具

## Anthropic 兼容行为

- `POST https://api.deepseek.com/anthropic/v1/messages`（base_url 含 /anthropic）
- 模型映射：`claude-opus*` → `deepseek-v4-pro`；`claude-haiku*`/`claude-sonnet*` → `deepseek-v4-flash`；未知名 → flash
- 认证仅 `x-api-key`；anthropic-version/anthropic-beta 忽略（请求可省略）

## 阶段1 真实验证用途

- gate：真实串通 openai_chat / openai_responses / anthropic_messages 三个协议各一次完整往返
- 测试配置：临时 `.maxa/runtime.yaml` 声明 provider（base_url + `api_key_env: DEEPSEEK_TEST_KEY`），key 从项目根 `.env` 读取，不进仓库、不回显
- Gemini 协议仅本地 fixture 验证（deepseek 不支持）
