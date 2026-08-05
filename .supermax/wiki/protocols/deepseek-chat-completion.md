[跳到主要内容](#__docusaurus_skipToContent_fallback)

[![DeepSeek API 文档 Logo](https://cdn.deepseek.com/platform/favicon.png)![DeepSeek API 文档 Logo](https://cdn.deepseek.com/platform/favicon.png)

**DeepSeek API 文档**](/zh-cn/)

中文（中国）

* [English](/api/create-chat-completion)
* [中文（中国）](/zh-cn/api/create-chat-completion)

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
* Chat Completions API

# Chat Completions API

```
POST

## /chat/completions
```

根据输入的上下文，来让模型补全对话内容。

## Request[​](#request "Request的直接链接")

* application/json

### Body

**required**

**messages**

object[]

required

**Possible values:** `>= 1`

对话的消息列表。

* Array [

oneOf

+ System message
+ User message
+ Assistant message
+ Tool message

**content** stringrequired

system 消息的内容。

**role** stringrequired

**Possible values:** [`system`]

该消息的发起角色，其值为 `system`。

**name** string

可以选填的参与者的名称，为模型提供信息以区分相同角色的参与者。

**content** Text content (string)required

user 消息的内容。

**role** stringrequired

**Possible values:** [`user`]

该消息的发起角色，其值为 `user`。

**name** string

可以选填的参与者的名称，为模型提供信息以区分相同角色的参与者。

**content** stringnullablerequired

assistant 消息的内容。

**role** stringrequired

**Possible values:** [`assistant`]

该消息的发起角色，其值为 `assistant`。

**name** string

可以选填的参与者的名称，为模型提供信息以区分相同角色的参与者。

**prefix** bool

(Beta) 设置此参数为 true，来强制模型在其回答中以此 `assistant` 消息中提供的前缀内容开始。

您必须设置 `base_url="https://api.deepseek.com/beta"` 来使用此功能。

**reasoning\_content** stringnullable

(Beta) 用于思考模式下在[对话前缀续写](/zh-cn/guides/chat_prefix_completion)功能下，作为最后一条 assistant 思维链内容的输入。使用此功能时，`prefix` 参数必须设置为 `true`。

**role** stringrequired

**Possible values:** [`tool`]

该消息的发起角色，其值为 `tool`。

**content** Text content (string)required

tool 消息的内容。

**tool\_call\_id** stringrequired

此消息所响应的 tool call 的 ID。

* ]

**model** stringrequired

**Possible values:** [`deepseek-v4-flash`, `deepseek-v4-pro`]

使用的模型的 ID。

**thinking**

object

nullable

控制思考模式与非思考模式的转换

**type** string

**Possible values:** [`enabled`, `disabled`]

**Default value:** `enabled`

如果设为 `enabled`，则使用思考模式。如果设为 `disabled`，则使用非思考模式

**reasoning\_effort** string

**Possible values:** [`low`, `high`, `max`]

控制模型的推理强度。默认为 `high`。出于兼容考虑 `medium`、`xhigh` 会映射为 `high`。请注意，目前仅 `deepseek-v4-flash` 支持三个思考强度档位；`deepseek-v4-pro` 暂时只支持 `high`、`max` 两档（`low` 按 `high` 处理，`xhigh` 按 `max` 处理），预计 2026 年 8 月初支持三档。

**max\_tokens** integernullable

限制一次请求中模型生成 completion 的最大 token 数。输入 token 和输出 token 的总长度受模型的上下文长度的限制。取值范围与默认值详见[文档](/zh-cn/quick_start/pricing)。

**response\_format**

object

nullable

一个 object，指定模型必须输出的格式。

设置为 { "type": "json\_object" } 以启用 JSON 模式，该模式保证模型生成的消息是有效的 JSON。

**注意:** 使用 JSON 模式时，你还必须通过系统或用户消息指示模型生成 JSON。否则，模型可能会生成不断的空白字符，直到生成达到令牌限制，从而导致请求长时间运行并显得“卡住”。此外，如果 finish\_reason="length"，这表示生成超过了 max\_tokens 或对话超过了最大上下文长度，消息内容可能会被部分截断。

**type** string

**Possible values:** [`text`, `json_object`]

**Default value:** `text`

Must be one of `text` or `json_object`.

**stop**

object

**nullable**

一个 string 或最多包含 16 个 string 的 list，在遇到这些词时，API 将停止生成更多的 token。

oneOf

+ MOD1
+ MOD2

string

* Array [

string

* ]

**stream** booleannullable

如果设置为 True，将会以 SSE（server-sent events）的形式以流式发送消息增量。消息流以 `data: [DONE]` 结尾。

**stream\_options**

object

nullable

流式输出相关选项。只有在 `stream` 参数为 `true` 时，才可设置此参数。

**include\_usage** boolean

如果设置为 true，在流式消息最后的 `data: [DONE]` 之前将会传输一个额外的块。此块上的 usage 字段显示整个请求的 token 使用统计信息，而 choices 字段将始终是一个空数组。所有其他块也将包含一个 usage 字段，但其值为 null。

**temperature** numbernullable

**Possible values:** `<= 2`

**Default value:** `1`

采样温度，介于 0 和 2 之间。更高的值，如 0.8，会使输出更随机，而更低的值，如 0.2，会使其更加集中和确定。 我们通常建议可以更改这个值或者更改 `top_p`，但不建议同时对两者进行修改。

**top\_p** numbernullable

**Possible values:** `<= 1`

**Default value:** `1`

作为调节采样温度的替代方案，模型会考虑前 `top_p` 概率的 token 的结果。所以 0.1 就意味着只有包括在最高 10% 概率中的 token 会被考虑。 我们通常建议修改这个值或者更改 `temperature`，但不建议同时对两者进行修改。

**tools**

object[]

nullable

模型可能会调用的 tool 的列表。目前，仅支持 function 作为工具。使用此参数来提供以 JSON 作为输入参数的 function 列表。最多支持 128 个 function。

* Array [

**type** stringrequired

**Possible values:** [`function`]

tool 的类型。目前仅支持 function。

**function**

object

required

**description** string

function 的功能描述，供模型理解何时以及如何调用该 function。

**name** stringrequired

要调用的 function 名称。必须由 a-z、A-Z、0-9 字符组成，或包含下划线和连字符，最大长度为 64 个字符。

**parameters**

object

function 的输入参数，以 JSON Schema 对象描述。请参阅[Tool Calls 指南](/zh-cn/guides/tool_calls)获取示例，并参阅[JSON Schema 参考](https://json-schema.org/understanding-json-schema/)了解有关格式的文档。省略 `parameters` 会定义一个参数列表为空的 function。

**property name\*** any

function 的输入参数，以 JSON Schema 对象描述。请参阅[Tool Calls 指南](/zh-cn/guides/tool_calls)获取示例，并参阅[JSON Schema 参考](https://json-schema.org/understanding-json-schema/)了解有关格式的文档。省略 `parameters` 会定义一个参数列表为空的 function。

**strict** boolean

**Default value:** `false`

如果设置为 true，API 将在函数调用中使用 strict 模式，以确保输出始终符合函数的 JSON schema 定义。该功能为 Beta 功能，详细使用方式请参阅[Tool Calls 指南](/zh-cn/guides/tool_calls)

* ]

**tool\_choice**

object

**nullable**

控制模型调用 tool 的行为。

`none` 意味着模型不会调用任何 tool，而是生成一条消息。

`auto` 意味着模型可以选择生成一条消息或调用一个或多个 tool。

`required` 意味着模型必须调用一个或多个 tool。

通过 `{"type": "function", "function": {"name": "my_function"}}` 指定特定 tool，会强制模型调用该 tool。

当没有 tool 时，默认值为 `none`。如果有 tool 存在，默认值为 `auto`。

oneOf

+ ChatCompletionToolChoice
+ ChatCompletionNamedToolChoice

string

**Possible values:** [`none`, `auto`, `required`]

**type** stringrequired

**Possible values:** [`function`]

tool 的类型。目前，仅支持 `function`。

**function**

object

required

**name** stringrequired

要调用的函数名称。

**logprobs** booleannullable

是否返回所输出 token 的对数概率。如果为 true，则在 `message` 的 `content` 中返回每个输出 token 的对数概率。

**top\_logprobs** integernullable

**Possible values:** `<= 20`

一个介于 0 到 20 之间的整数 N，指定每个输出位置返回输出概率 top N 的 token，且返回这些 token 的对数概率。指定此参数时，logprobs 必须为 true。

**user\_id** nullable

您自定义的 user\_id，可选字符集为 [a-zA-Z0-9\-\_]，最大长度为 512。请不要在 user\_id 中包含用户隐私信息。

+ user\_id 可用于区分您业务侧的用户身份，以帮助我们进行内容安全处理。
+ user\_id 可用于 KVCache 缓存隔离，以进行隐私管理。
+ user\_id 可用于我们对您业务侧用户进行调度隔离。
+ 关于 user\_id 参数更详细的描述，请参考[限速与隔离](/zh-cn/quick_start/rate_limit)

**frequency\_penalty** deprecated

该参数已不再支持。传入该参数将不会产生任何效果。

**presence\_penalty** deprecated

该参数已不再支持。传入该参数将不会产生任何效果。

## Responses[​](#responses "Responses的直接链接")

* 200 (No streaming)
* 200 (Streaming)

OK, 返回一个 `chat completion` 对象。

* application/json

* Schema
* Example (from schema)
* Example

**Schema**

**id** stringrequired

该对话的唯一标识符。

**choices**

object[]

required

模型生成的 completion 的选择列表。

* Array [

**finish\_reason** stringrequired

**Possible values:** [`stop`, `length`, `content_filter`, `tool_calls`, `insufficient_system_resource`]

模型停止生成 token 的原因。

`stop`：模型自然停止生成，或遇到 `stop` 序列中列出的字符串。

`length` ：输出长度达到了模型上下文长度限制，或达到了 `max_tokens` 的限制。

`content_filter`：输出内容因触发过滤策略而被过滤。

`insufficient_system_resource`：系统推理资源不足，生成被打断。

**index** integerrequired

该 completion 在模型生成的 completion 的选择列表中的索引。

**message**

object

required

模型生成的 completion 消息。

**content** stringnullablerequired

该 completion 的内容。

**reasoning\_content** stringnullable

仅适用于思考模式。内容为 assistant 消息中在最终答案之前的推理内容。

**tool\_calls**

object[]

模型生成的 tool 调用，例如 function 调用。

* Array [

**id** stringrequired

tool 调用的 ID。

**type** stringrequired

**Possible values:** [`function`]

tool 的类型。目前仅支持 `function`。

**function**

object

required

模型调用的 function。

**name** stringrequired

模型调用的 function 名。

**arguments** stringrequired

要调用的 function 的参数，由模型生成，格式为 JSON。请注意，模型并不总是生成有效的 JSON，并且可能会臆造出你函数模式中未定义的参数。在调用函数之前，请在代码中验证这些参数。

* ]

**role** stringrequired

**Possible values:** [`assistant`]

生成这条消息的角色。

**logprobs**

object

nullable

required

该 choice 的对数概率信息。

**content**

object[]

nullable

required

一个包含输出 token 对数概率信息的列表。

* Array [

**token** stringrequired

输出的 token。

**logprob** numberrequired

该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。

**bytes** integer[]nullablerequired

一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。

**top\_logprobs**

object[]

required

一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。在罕见情况下，返回的 token 数量可能少于请求参数中指定的 `top_logprobs` 值。

* Array [

**token** stringrequired

输出的 token。

**logprob** numberrequired

该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。

**bytes** integer[]nullablerequired

一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。

* ]

* ]

**reasoning\_content**

object[]

nullable

一个包含输出 token 对数概率信息的列表。

* Array [

**token** stringrequired

输出的 token。

**logprob** numberrequired

该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。

**bytes** integer[]nullablerequired

一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。

**top\_logprobs**

object[]

required

一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。在罕见情况下，返回的 token 数量可能少于请求参数中指定的 `top_logprobs` 值。

* Array [

**token** stringrequired

输出的 token。

**logprob** numberrequired

该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。

**bytes** integer[]nullablerequired

一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。

* ]

* ]

* ]

**created** integerrequired

创建聊天完成时的 Unix 时间戳（以秒为单位）。

**model** stringrequired

生成该 completion 的模型名。

**system\_fingerprint** stringrequired

This fingerprint represents the backend configuration that the model runs with.

**object** stringrequired

**Possible values:** [`chat.completion`]

对象的类型, 其值为 `chat.completion`。

**usage**

object

该对话补全请求的用量信息。

**completion\_tokens** integerrequired

模型 completion 产生的 token 数。

**prompt\_tokens** integerrequired

用户 prompt 所包含的 token 数。该值等于 `prompt_cache_hit_tokens + prompt_cache_miss_tokens`

**prompt\_cache\_hit\_tokens** integerrequired

用户 prompt 中，命中上下文缓存的 token 数。

**prompt\_cache\_miss\_tokens** integerrequired

用户 prompt 中，未命中上下文缓存的 token 数。

**total\_tokens** integerrequired

该请求中，所有 token 的数量（prompt + completion）。

**completion\_tokens\_details**

object

completion tokens 的详细信息。

**reasoning\_tokens** integer

推理模型所产生的思维链 token 数量

```
{
  "id": "string",
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "content": "string",
        "reasoning_content": "string",
        "tool_calls": [
          {
            "id": "string",
            "type": "function",
            "function": {
              "name": "string",
              "arguments": "string"
            }
          }
        ],
        "role": "assistant"
      },
      "logprobs": {
        "content": [
          {
            "token": "string",
            "logprob": 0,
            "bytes": [
              0
            ],
            "top_logprobs": [
              {
                "token": "string",
                "logprob": 0,
                "bytes": [
                  0
                ]
              }
            ]
          }
        ],
        "reasoning_content": [
          {
            "token": "string",
            "logprob": 0,
            "bytes": [
              0
            ],
            "top_logprobs": [
              {
                "token": "string",
                "logprob": 0,
                "bytes": [
                  0
                ]
              }
            ]
          }
        ]
      }
    }
  ],
  "created": 0,
  "model": "string",
  "system_fingerprint": "string",
  "object": "chat.completion",
  "usage": {
    "completion_tokens": 0,
    "prompt_tokens": 0,
    "prompt_cache_hit_tokens": 0,
    "prompt_cache_miss_tokens": 0,
    "total_tokens": 0,
    "completion_tokens_details": {
      "reasoning_tokens": 0
    }
  }
}
```

```
{
  "id": "930c60df-bf64-41c9-a88e-3ec75f81e00e",
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "content": "Hello! How can I help you today?",
        "role": "assistant"
      }
    }
  ],
  "created": 1705651092,
  "model": "deepseek-v4-pro",
  "object": "chat.completion",
  "usage": {
    "completion_tokens": 10,
    "prompt_tokens": 16,
    "total_tokens": 26
  }
}
```

OK, 返回包含一系列 `chat completion chunk` 对象的流式输出。

* text/event-stream

* Schema
* Example (from schema)
* Example

**Schema**

* Array [

**id** stringrequired

该对话的唯一标识符。

**choices**

object[]

required

模型生成的 completion 的选择列表。

* Array [

**delta**

object

required

流式返回的一个 completion 增量。

**content** stringnullable

completion 增量的内容。

**reasoning\_content** stringnullable

仅适用于思考模式。内容为 assistant 消息中在最终答案之前的推理内容。

**role** string

**Possible values:** [`assistant`]

产生这条消息的角色。

**logprobs**

object

nullable

该 choice 的对数概率信息。

**content**

object[]

nullable

required

一个包含输出 token 对数概率信息的列表。

* Array [

**token** stringrequired

输出的 token。

**logprob** numberrequired

该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。

**bytes** integer[]nullablerequired

一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。

**top\_logprobs**

object[]

required

一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。在罕见情况下，返回的 token 数量可能少于请求参数中指定的 `top_logprobs` 值。

* Array [

**token** stringrequired

输出的 token。

**logprob** numberrequired

该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。

**bytes** integer[]nullablerequired

一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。

* ]

* ]

**reasoning\_content**

object[]

nullable

一个包含输出 token 对数概率信息的列表。

* Array [

**token** stringrequired

输出的 token。

**logprob** numberrequired

该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。

**bytes** integer[]nullablerequired

一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。

**top\_logprobs**

object[]

required

一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。在罕见情况下，返回的 token 数量可能少于请求参数中指定的 `top_logprobs` 值。

* Array [

**token** stringrequired

输出的 token。

**logprob** numberrequired

该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。

**bytes** integer[]nullablerequired

一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。

* ]

* ]

**finish\_reason** stringnullablerequired

**Possible values:** [`stop`, `length`, `content_filter`, `tool_calls`, `insufficient_system_resource`]

模型停止生成 token 的原因。

`stop`：模型自然停止生成，或遇到 `stop` 序列中列出的字符串。

`length` ：输出长度达到了模型上下文长度限制，或达到了 `max_tokens` 的限制。

`content_filter`：输出内容因触发过滤策略而被过滤。

`insufficient_system_resource`: 由于后端推理资源受限，请求被打断。

**index** integerrequired

该 completion 在模型生成的 completion 的选择列表中的索引。

* ]

**created** integerrequired

创建聊天完成时的 Unix 时间戳（以秒为单位）。流式响应的每个 chunk 的时间戳相同。

**model** stringrequired

生成该 completion 的模型名。

**system\_fingerprint** stringrequired

This fingerprint represents the backend configuration that the model runs with.

**object** stringrequired

**Possible values:** [`chat.completion.chunk`]

对象的类型, 其值为 `chat.completion.chunk`。

* ]

```
[
  {
    "id": "string",
    "choices": [
      {
        "delta": {
          "content": "string",
          "reasoning_content": "string",
          "role": "assistant"
        },
        "logprobs": {
          "content": [
            {
              "token": "string",
              "logprob": 0,
              "bytes": [
                0
              ],
              "top_logprobs": [
                {
                  "token": "string",
                  "logprob": 0,
                  "bytes": [
                    0
                  ]
                }
              ]
            }
          ],
          "reasoning_content": [
            {
              "token": "string",
              "logprob": 0,
              "bytes": [
                0
              ],
              "top_logprobs": [
                {
                  "token": "string",
                  "logprob": 0,
                  "bytes": [
                    0
                  ]
                }
              ]
            }
          ]
        },
        "finish_reason": "stop",
        "index": 0
      }
    ],
    "created": 0,
    "model": "string",
    "system_fingerprint": "string",
    "object": "chat.completion.chunk"
  }
]
```

```
data: {"id": "1f633d8bfc032625086f14113c411638", "choices": [{"index": 0, "delta": {"content": "", "role": "assistant"}, "finish_reason": null, "logprobs": null}], "created": 1718345013, "model": "deepseek-v4-pro", "system_fingerprint": "fp_a49d71b8a1", "object": "chat.completion.chunk", "usage": null}

data: {"choices": [{"delta": {"content": "Hello", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": "!", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": " How", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": " can", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": " I", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": " assist", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": " you", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": " today", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": "?", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}

data: {"choices": [{"delta": {"content": "", "role": null}, "finish_reason": "stop", "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-v4-pro", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1", "usage": {"completion_tokens": 9, "prompt_tokens": 17, "total_tokens": 26}}

data: [DONE]
```

Loading...

[上一页

使用 Anthropic API](/zh-cn/guides/anthropic_api)[下一页

Responses API](/zh-cn/api/create-response)

微信公众号

* ![WeChat QRcode](https://cdn.deepseek.com/official_account.jpg)

社区

* 邮箱
* [Discord](https://discord.gg/Tc7c45Zzu5)
* [Twitter](https://twitter.com/deepseek_ai)

更多

* [GitHub](https://github.com/deepseek-ai)

Copyright © 2026 DeepSeek, Inc.
