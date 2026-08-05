---
title: OpenAI Responses API 官方参考
created: 2026-08-04
updated: 2026-08-04
type: protocol-reference
authority: official-source
source:
  - https://github.com/openai/openai-openapi/blob/main/openapi.yaml
  - https://github.com/openai/openai-openapi/blob/main/_autodocs/endpoints.md
usage: maxa 阶段1 OpenAI Responses 适配器实现/验收参考；字段与事件以本文件为准，实施时复查漂移
---

# OpenAI Responses API 参考

> Context7 于 2026-08-04 从 openai/openai-openapi 官方仓库抓取。用于 `openai_responses` 适配器。

## 请求（POST /v1/responses）

| 参数 | 说明 |
| --- | --- |
| `model` | 必填 |
| `instructions` | system/developer 消息；与 `previous_response_id` 同用时**不会**继承前次 instructions，必须重传 |
| `input` | 非 system 记录（message/function_call/function_call_output 等 input item） |
| `tools` | 函数工具（strict mode 递归归一化）；`store=false` 时不落盘 |
| `stream` | boolean |
| `reasoning` | 可选 reasoning 配置 |

Input item 形状：

- 消息：`{type:"message", role, content[]}`
- 工具调用：`{type:"function_call", id, call_id, name, arguments(string JSON)}`
- 工具结果：`{type:"function_call_output", call_id, output}`
- 图片：`{type:"input_image", image_url}`；相邻同 user 文本可共享一个 content 列表

输出 item：`output[]` 为 OutputItem 数组；reasoning item `{type:"reasoning", summary?, encrypted_content?}`。

## 流式事件（有序 SSE，含 sequence_number）

官方示例事件顺序：

```text
response.created → response.in_progress → response.output_item.added(status: in_progress)
→ ... → response.output_text.delta / response.content_part.done
→ response.output_item.done(status: completed) → response.completed
```

| 事件 | 说明 |
| --- | --- |
| `response.created` | 建立 response 身份 |
| `response.in_progress` | 进行中 |
| `response.output_item.added` / `.done` | output item 生命周期（含 function_call item） |
| `response.output_text.delta` | assistant 文本增量 |
| `response.reasoning_summary_text.delta` | reasoning 增量 |
| `response.completed` | 终态成功；可含完成的 function_call 而无文本（tool-only 合法）；usage 从该事件 response 读取 |
| `response.failed` | 终态失败（typed） |
| `response.incomplete` | 终态不完整（typed） |
| `event:error` | 传输层错误 |

`response.incomplete` 事件字段：`type`(=response.incomplete)、`response`(完整 Response 对象)、`sequence_number`。

Response 状态枚举：`queued`、`in_progress`、`completed`、`failed`、`cancelled`、`incomplete`。终态事件类型与内嵌 response.status 必须一致，否则协议错误。

## 目标适配器要点

- 工具调用可仅经流式事件返回（`response.output_item.done` / `response.function_call_arguments.done`），不出现于 `completed.response.output`——tool-only 响应必须能进入工具批处理
- `response.completed` 可能带 `output` 里的 function_call；文本与工具可共存
- 终态事件（error/failed/incomplete）优先于后续 EOF/exit 回调，不得被转成成功
- usage：从 completed response 读取（input/output/total）
- 严格 schema：`enforce_strictness` 递归归一化；空对象保持 `{}`（不得序列化为 `[]`）
