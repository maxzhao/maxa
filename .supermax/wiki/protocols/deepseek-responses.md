[跳到主要内容](#__docusaurus_skipToContent_fallback)

[![DeepSeek API 文档 Logo](https://cdn.deepseek.com/platform/favicon.png)![DeepSeek API 文档 Logo](https://cdn.deepseek.com/platform/favicon.png)

**DeepSeek API 文档**](/zh-cn/)

中文（中国）

* [English](/api/create-response)
* [中文（中国）](/zh-cn/api/create-response)

[DeepSeek Platform](https://platform.deepseek.com/)

* [快速开始](/zh-cn/)

  + [首次调用 API](/zh-cn/)
  + [模型 & 价格](/zh-cn/quick_start/pricing)
  + [Token 用量计算](/zh-cn/quick_start/token_usage)
  + [限速与隔离](/zh-cn/quick_start/rate_limit)
  + [错误码](/zh-cn/quick_start/error_codes)
  + [接入 Agent 工具](/zh-cn/quick_start/agent_integrations/claude_code)
* [API 指南](/zh-cn/guides/thinking_mode)

  + [思考模式](/zh-cn/guides/thinking_mode)
  + [多轮对话](/zh-cn/guides/multi_round_chat)
  + [对话前缀续写（Beta）](/zh-cn/guides/chat_prefix_completion)
  + [FIM 补全（Beta）](/zh-cn/guides/fim_completion)
  + [JSON Output](/zh-cn/guides/json_mode)
  + [Tool Calls](/zh-cn/guides/tool_calls)
  + [上下文硬盘缓存](/zh-cn/guides/kv_cache)
  + [使用 Responses API](/zh-cn/guides/responses_api)
  + [使用 Anthropic API](/zh-cn/guides/anthropic_api)
* [API 文档](/zh-cn/api/create-chat-completion)

  + [Chat Completions API](/zh-cn/api/create-chat-completion)
  + [Responses API](/zh-cn/api/create-response)
  + [FIM 补全 API（Beta）](/zh-cn/api/create-completion)
  + [获取模型列表](/zh-cn/api/list-models)
  + [查询余额](/zh-cn/api/get-user-balance)
* [新闻](/zh-cn/news/news260424)
* [其它资源](https://github.com/deepseek-ai/awesome-deepseek-integration/tree/main)
* [常见问题](https://static.deepseek.com/faq/index.html?lang=zh#/category/4)
* [更新日志](/zh-cn/updates)

* API 文档
* Responses API

# Responses API

```
POST

## /responses
```

以 OpenAI Responses API 格式创建模型响应。

该 API 是**无状态**的：服务端不存储响应与会话。多轮对话需要客户端在每次请求的 `input` 中回传完整对话历史。详细说明（含完整的参数兼容性表）请参考 [Responses API 指南](/zh-cn/guides/responses_api)。

## Request[​](#request "Request的直接链接")

* application/json

### Body

**required**

**model** stringrequired

**Possible values:** [`deepseek-v4-flash`]

使用的模型的 ID。Responses API 目前仅支持 `deepseek-v4-flash`，暂不支持 `deepseek-v4-pro`。

**input**

object

**nullable**

模型的输入。既可以传纯字符串（视作一条 `user` 消息），也可以传输入 item 列表。

支持的输入 item 类型为 `message` / `function_call` / `function_call_output` / `reasoning` / `web_search_call`，其他类型会被忽略。消息角色支持 `user` / `assistant` / `system` / `developer`（`developer` 视同 `system`）。不支持图片、文件输入（`input_image` 内容块不会报错，但会被替换为占位文本）。

`input` 与 `instructions` 至少传一个。

oneOf

+ Text input
+ Input item list

string

* Array [

**type** string

**Possible values:** [`message`, `function_call`, `function_call_output`, `reasoning`, `web_search_call`]

输入 item 的类型。对于 `message` item，如果传了 `role`，此字段可省略。

**role** string

**Possible values:** [`user`, `assistant`, `system`, `developer`]

用于 `message` item。消息作者的角色。`developer` 视同 `system`。

**content**

用于 `message` item 时为消息内容，可以是纯字符串或 `input_text` / `output_text` 内容块列表。用于 `reasoning` item 时为 `reasoning_text` 内容块列表。

**call\_id** string

用于 `function_call` / `function_call_output` item。将函数调用与其结果配对的 ID。必须非空且唯一，且每个 `function_call` 必须有对应的 `function_call_output`。

**name** string

用于 `function_call` item。要调用的函数的名称。

**arguments** string

用于 `function_call` item。调用函数的入参，格式为 JSON。

**output** string

用于 `function_call_output` item。函数调用的结果。

* ]

**instructions** stringnullable

系统级指令，作为模型上下文中的第一条 system 消息。

**reasoning**

object

nullable

思考模式配置。

**effort** string

**Possible values:** [`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`]

控制思考模式开关与思考强度。`none` 关闭思考模式；`minimal` / `low` 开启思考模式，思考强度为 `low`；`medium` / `high` / `xhigh` 开启思考模式，思考强度为 `high`；`max` 开启思考模式，思考强度为 `max`。不传时使用模型默认的思考行为（默认开启）。

**max\_output\_tokens** integernullable

响应可生成的 token 数上限，包含可见的输出 token 与思维链 token。

**stream** booleannullable

如果设置为 `true`，响应将以语义化的流式 SSE 事件返回。最后一个事件是 `response.completed` / `response.incomplete` / `response.failed`（没有 `data: [DONE]` 消息）。完整事件列表请参考 [Responses API 指南](/guides/responses_api#streaming)。

**temperature** numbernullable

**Possible values:** `<= 2`

**Default value:** `1`

采样温度，介于 0 和 2 之间。更高的值（如 0.8）会使输出更随机，而更低的值（如 0.2）会使其更加集中和确定。思考模式下不生效。

**top\_p** numbernullable

**Possible values:** `<= 1`

**Default value:** `1`

作为调节采样温度的替代方案，即核采样。思考模式下不生效。

**text**

object

nullable

文本输出配置。

**format**

object

输出格式。`{"type": "text"}`（默认）为纯文本输出；`{"type": "json_object"}` 为 JSON 模式；`{"type": "json_schema", "name": ..., "schema": ...}` 为结构化输出，输出符合给定的 JSON Schema。

**type** string

**Possible values:** [`text`, `json_object`, `json_schema`]

**Default value:** `text`

**name** string

schema 的名称。`type` 为 `json_schema` 时必填。

**schema** object

输出必须符合的 JSON Schema。`type` 为 `json_schema` 时必填。

**tools**

object[]

nullable

模型可能会调用的工具的列表。函数名必须非空、不超过 128 个字符、匹配 `^[a-zA-Z0-9_-]+$`，且所有工具的名称必须唯一。除 `function` 外，还支持内置的 `web_search` 工具（服务端执行），其他内置工具类型会被忽略。详情请参考 [Responses API 指南](/zh-cn/guides/responses_api)。

* Array [

**type** stringrequired

**Possible values:** [`function`, `web_search`, `web_search_2025_08_26`]

工具的类型。

**name** string

用于 `function` 工具。函数的名称。必须非空、不超过 128 个字符、匹配 `^[a-zA-Z0-9_-]+$`，且所有工具的名称必须唯一。

**description** string

用于 `function` 工具。函数功能的描述，供模型理解何时以及如何调用该函数。

**parameters**

object

function 的输入参数，以 JSON Schema 对象描述。请参阅[Tool Calls 指南](/zh-cn/guides/tool_calls)获取示例，并参阅[JSON Schema 参考](https://json-schema.org/understanding-json-schema/)了解有关格式的文档。省略 `parameters` 会定义一个参数列表为空的 function。

**property name\*** any

function 的输入参数，以 JSON Schema 对象描述。请参阅[Tool Calls 指南](/zh-cn/guides/tool_calls)获取示例，并参阅[JSON Schema 参考](https://json-schema.org/understanding-json-schema/)了解有关格式的文档。省略 `parameters` 会定义一个参数列表为空的 function。

* ]

**tool\_choice**

object

**nullable**

控制模型调用工具的行为。

`none` 意味着模型不会调用任何工具，而是生成一条消息。

`auto`（默认）意味着模型可以选择生成一条消息或调用一个或多个工具。

`required` 意味着模型必须调用一个或多个工具。

通过 `{"type": "function", "name": "my_function"}` 指定特定工具，会强制模型调用该工具。

通过 `{"type": "web_search"}`（或 `{"type": "web_search_2025_08_26"}`）可强制模型执行联网搜索；此时 `tools` 中必须包含 `web_search` 工具，否则返回 `400` 错误。

oneOf

+ Tool choice mode
+ Named tool choice

string

**Possible values:** [`none`, `auto`, `required`]

**type** stringrequired

**Possible values:** [`function`, `web_search`, `web_search_2025_08_26`]

**name** string

The name of the function to call. Required when `type` is `function`.

**top\_logprobs** integernullable

**Possible values:** `<= 20`

一个介于 0 到 20 之间的整数 N，指定每个输出位置返回输出概率 top N 的 token，且返回这些 token 的对数概率。

**user** stringnullable

自定义终端用户标识，字符集为 [a-zA-Z0-9\-\_]，最大长度为 512。请勿在其中包含用户隐私信息。

+ 可用于区分您业务侧的用户身份，以帮助我们进行内容安全审核；也可用于 KVCache 隔离与调度隔离。详情请参考[限速与用户隔离](/quick_start/rate_limit)

## Responses[​](#responses "Responses的直接链接")

* 200 (No streaming)
* 200 (Streaming)

OK, 返回一个 `response` 对象。

* application/json

* Schema
* Example (from schema)
* Example

**Schema**

**id** stringrequired

该响应的唯一标识符。

**object** stringrequired

**Possible values:** [`response`]

object 的类型，其值恒为 `response`。

**created\_at** integerrequired

标志响应创建时间的 Unix 时间戳（以秒为单位）。

**status** stringrequired

**Possible values:** [`in_progress`, `completed`, `incomplete`, `failed`]

响应的状态。

**error** objectnullable

响应失败时的错误对象，包含 `code` 和 `message` 字段。

**incomplete\_details**

object

nullable

响应不完整的原因详情。`reason` 字段可能为 `max_output_tokens` 或 `content_filter`。

**reason** string

**Possible values:** [`max_output_tokens`, `content_filter`]

**model** stringrequired

生成该响应的模型。

**output**

object[]

required

模型生成的输出 item 列表。思考模式下，思维链以 `reasoning` item 的形式在 `message` item 之前返回。函数调用以 `function_call` item 返回，服务端联网搜索动作以 `web_search_call` item 返回。

* Array [

**type** string

**Possible values:** [`message`, `reasoning`, `function_call`, `web_search_call`]

输出 item 的类型。

**id** string

输出 item 的唯一 ID。

**status** string

**Possible values:** [`in_progress`, `completed`, `incomplete`]

输出 item 的状态。

**role** string

**Possible values:** [`assistant`]

用于 `message` item。其值恒为 `assistant`。

**content**

object[]

用于 `message` item 时为 `output_text` 内容块列表。用于 `reasoning` item 时为 `reasoning_text` 内容块列表，以明文承载思维链内容。

* Array [

**type** string

**Possible values:** [`output_text`, `reasoning_text`]

**text** string

* ]

**call\_id** string

用于 `function_call` item。将函数调用结果回传给 API 时使用的标识符。

**name** string

用于 `function_call` item。要调用的函数的名称。

**arguments** string

用于 `function_call` item。模型生成的调用函数的入参，格式为 JSON。请注意，模型并不总是生成有效的 JSON，且可能会虚构出您的函数模式中未定义的参数。在调用函数之前，请在您的代码中验证这些入参是否有效。

**action** object

用于 `web_search_call` item。描述服务端执行的搜索动作（`search` / `open_page` / `find_in_page`）的对象。

* ]

**usage**

object

该响应的 token 用量统计信息。

**input\_tokens** integerrequired

输入 token 数。

**input\_tokens\_details**

object

输入 token 的细分信息。

**cached\_tokens** integer

命中上下文缓存的输入 token 数。参考[上下文硬盘缓存](/guides/kv_cache)。

**output\_tokens** integerrequired

输出 token 数。

**output\_tokens\_details**

object

输出 token 的细分信息。

**reasoning\_tokens** integer

模型生成的思维链 token 数。

**total\_tokens** integerrequired

该请求使用的 token 总数（输入 + 输出）。

```
{
  "id": "string",
  "object": "response",
  "created_at": 0,
  "status": "in_progress",
  "error": {},
  "incomplete_details": {
    "reason": "max_output_tokens"
  },
  "model": "string",
  "output": [
    {
      "type": "message",
      "id": "string",
      "status": "in_progress",
      "role": "assistant",
      "content": [
        {
          "type": "output_text",
          "text": "string"
        }
      ],
      "call_id": "string",
      "name": "string",
      "arguments": "string",
      "action": {}
    }
  ],
  "usage": {
    "input_tokens": 0,
    "input_tokens_details": {
      "cached_tokens": 0
    },
    "output_tokens": 0,
    "output_tokens_details": {
      "reasoning_tokens": 0
    },
    "total_tokens": 0
  }
}
```

```
{
  "id": "24778070-1c36-4ae0-a4bd-870afc7fc13e",
  "object": "response",
  "created_at": 1753000000,
  "status": "completed",
  "model": "deepseek-v4-flash",
  "output": [
    {
      "type": "reasoning",
      "id": "rs_1",
      "status": "completed",
      "content": [
        {
          "type": "reasoning_text",
          "text": "The user greets me. I should reply politely."
        }
      ],
      "summary": []
    },
    {
      "type": "message",
      "id": "msg_1",
      "status": "completed",
      "role": "assistant",
      "content": [
        {
          "type": "output_text",
          "text": "Hello! How can I help you today?",
          "annotations": []
        }
      ]
    }
  ],
  "usage": {
    "input_tokens": 22,
    "input_tokens_details": { "cached_tokens": 0 },
    "output_tokens": 29,
    "output_tokens_details": { "reasoning_tokens": 27 },
    "total_tokens": 51
  },
  "store": false,
  "parallel_tool_calls": true,
  "previous_response_id": null,
  "error": null,
  "incomplete_details": null
}
```

OK, 返回语义化的流式 SSE 事件序列。每个事件带有表示事件类型的 `event` 字段和递增的 `sequence_number`。最后一个事件是 `response.completed` / `response.incomplete` / `response.failed`（没有 `data: [DONE]` 消息）。完整事件列表请参考 [Responses API 指南](/zh-cn/guides/responses_api#streaming)。

* text/event-stream

* Schema
* Example (from schema)
* Example

**Schema**

* Array [

object

* ]

```
[
  {}
]
```

```
event: response.created
data: {"type": "response.created", "sequence_number": 0, "response": {"id": "...", "object": "response", "status": "in_progress", ...}}

event: response.output_item.added
data: {"type": "response.output_item.added", "sequence_number": 2, "output_index": 0, "item": {"type": "reasoning", ...}}

event: response.reasoning_text.delta
data: {"type": "response.reasoning_text.delta", "sequence_number": 4, "item_id": "rs_1", "output_index": 0, "content_index": 0, "delta": "The user"}

event: response.output_item.added
data: {"type": "response.output_item.added", "sequence_number": 9, "output_index": 1, "item": {"type": "message", "role": "assistant", ...}}

event: response.output_text.delta
data: {"type": "response.output_text.delta", "sequence_number": 11, "item_id": "msg_1", "output_index": 1, "content_index": 0, "delta": "Hello"}

event: response.completed
data: {"type": "response.completed", "sequence_number": 20, "response": {"id": "...", "object": "response", "status": "completed", "usage": {...}, ...}}
```

Loading...

[上一页

Chat Completions API](/zh-cn/api/create-chat-completion)[下一页

FIM 补全 API（Beta）](/zh-cn/api/create-completion)

微信公众号

* ![WeChat QRcode](https://cdn.deepseek.com/official_account.jpg)

社区

* 邮箱
* [Discord](https://discord.gg/Tc7c45Zzu5)
* [Twitter](https://twitter.com/deepseek_ai)

更多

* [GitHub](https://github.com/deepseek-ai)

Copyright © 2026 DeepSeek, Inc.
