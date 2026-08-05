[跳到主要内容](#__docusaurus_skipToContent_fallback)

[![DeepSeek API 文档 Logo](https://cdn.deepseek.com/platform/favicon.png)![DeepSeek API 文档 Logo](https://cdn.deepseek.com/platform/favicon.png)

**DeepSeek API 文档**](/zh-cn/)

中文（中国）

* [English](/guides/anthropic_api)
* [中文（中国）](/zh-cn/guides/anthropic_api)

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
* [新闻](/zh-cn/news/news260424)
* [其它资源](https://github.com/deepseek-ai/awesome-deepseek-integration/tree/main)
* [常见问题](https://static.deepseek.com/faq/index.html?lang=zh#/category/4)
* [更新日志](/zh-cn/updates)

* API 指南
* 使用 Anthropic API

本页总览

# 使用 Anthropic API

为了满足大家对 Anthropic API 生态的使用需求，我们的 API 新增了对 Anthropic API 格式的支持，其 `base_url` 为 `https://api.deepseek.com/anthropic`。

通过简单的配置，即可将 DeepSeek 的能力，接入到 Anthropic API 生态中。

---

## 将 DeepSeek 模型接入 Claude Code[​](#将-deepseek-模型接入-claude-code "将 DeepSeek 模型接入 Claude Code的直接链接")

请参考[接入 Claude Code](/zh-cn/quick_start/agent_integrations/claude_code)

## 通过 Anthropic API 调用 DeepSeek 模型[​](#通过-anthropic-api-调用-deepseek-模型 "通过 Anthropic API 调用 DeepSeek 模型的直接链接")

1. 安装 Anthropic SDK

```
pip install anthropic
```

2. 配置环境变量

```
export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
export ANTHROPIC_API_KEY=${YOUR_API_KEY}
```

3. 调用 API

```
import anthropic

client = anthropic.Anthropic()

message = client.messages.create(
    model="deepseek-v4-pro",
    max_tokens=1000,
    system="You are a helpful assistant.",
    messages=[
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": "Hi, how are you?"
                }
            ]
        }
    ]
)
print(message.content)
```

**注意**：当您给 DeepSeek 的 Anthropic API 传入不支持的模型名时，API 后端会自动将其映射到 `deepseek-v4-flash` 模型。

---

## Anthropic 模型映射[​](#anthropic-模型映射 "Anthropic 模型映射的直接链接")

您在使用 Anthropic API 时，我们会对您传入的 claude 模型名进行映射：

* claude-opus 开头的模型，会映射到 deepseek-v4-pro
* claude-haiku、claude-sonnet 开头的模型，会映射到 deepseek-v4-flash

通过这样的映射，您在使用新版 Claude Desktop APP 的 developer 模式时，可以绕过 APP 对模型名的限制，只需改动 base\_url 和 api\_key，即可在其中接入 DeepSeek 模型。

---

## Anthropic API 兼容性细节[​](#anthropic-api-兼容性细节 "Anthropic API 兼容性细节的直接链接")

本小节罗列了 DeepSeek API 对 Anthropic API 的兼容性细节。Anthropic API 完整格式定义，请参考 [Anthropic 官方 API 手册](https://platform.claude.com/docs/en/api/python/beta/messages/create)。

### HTTP Header[​](#http-header "HTTP Header的直接链接")

| Field | Support Status |
| --- | --- |
| anthropic-beta | Ignored |
| anthropic-version | Ignored |
| x-api-key | Fully Supported |

### Simple Fields[​](#simple-fields "Simple Fields的直接链接")

| Field | Support Status |
| --- | --- |
| model | Use DeepSeek Model Instead |
| max\_tokens | Fully Supported |
| container | Ignored |
| mcp\_servers | Ignored |
| metadata | `user_id` is supported, others are ignored Please refer to [Rate Limit & Isolation](/zh-cn/quick_start/rate_limit) for more information about `user_id` parameter. |
| service\_tier | Ignored |
| stop\_sequences | Fully Supported |
| stream | Fully Supported |
| system | Fully Supported |
| temperature | Fully Supported (range [0.0 ~ 2.0]) |
| thinking | Supported (`budget_tokens` is ignored) |
| output\_config | Only `effort` is supported |
| top\_k | Ignored |
| top\_p | Fully Supported |

### Tool Fields[​](#tool-fields "Tool Fields的直接链接")

#### tools[​](#tools "tools的直接链接")

| Field | Support Status |
| --- | --- |
| name | Fully Supported |
| input\_schema | Fully Supported |
| description | Fully Supported |
| cache\_control | Ignored |

#### tool\_choice[​](#tool_choice "tool_choice的直接链接")

| Value | Support Status |
| --- | --- |
| none | Fully Supported |
| auto | Supported (`disable_parallel_tool_use` is ignored) |
| any | Supported (`disable_parallel_tool_use` is ignored) |
| tool | Supported (`disable_parallel_tool_use` is ignored) |

### Message Fields[​](#message-fields "Message Fields的直接链接")

| Field | Variant | Sub-Field | Support Status |
| --- | --- | --- | --- |
| content | string |  | Fully Supported |
| array, type="text" | text | Fully Supported |
| cache\_control | Ignored |
| citations | Ignored |
| array, type="image" |  | Not Supported |
| array, type = "document" |  | Not Supported |
| array, type = "search\_result" |  | Not Supported |
| array, type = "thinking" |  | Supported |
| array, type="redacted\_thinking" |  | Not Supported |
| array, type = "tool\_use" | id | Fully Supported |
| input | Fully Supported |
| name | Fully Supported |
| cache\_control | Ignored |
| array, type = "tool\_result" | tool\_use\_id | Fully Supported |
| content | Fully Supported |
| cache\_control | Ignored |
| is\_error | Ignored |
| array, type = "server\_tool\_use" |  | Supported |
| array, type = "web\_search\_tool\_result" |  | Supported |
| array, type = "code\_execution\_tool\_result" |  | Not Supported |
| array, type = "mcp\_tool\_use" |  | Not Supported |
| array, type = "mcp\_tool\_result" |  | Not Supported |
| array, type = "container\_upload" |  | Not Supported |

[上一页

使用 Responses API](/zh-cn/guides/responses_api)[下一页

Chat Completions API](/zh-cn/api/create-chat-completion)

* [将 DeepSeek 模型接入 Claude Code](#将-deepseek-模型接入-claude-code)
* [通过 Anthropic API 调用 DeepSeek 模型](#通过-anthropic-api-调用-deepseek-模型)
* [Anthropic 模型映射](#anthropic-模型映射)
* [Anthropic API 兼容性细节](#anthropic-api-兼容性细节)
  + [HTTP Header](#http-header)
  + [Simple Fields](#simple-fields)
  + [Tool Fields](#tool-fields)
  + [Message Fields](#message-fields)

微信公众号

* ![WeChat QRcode](https://cdn.deepseek.com/official_account.jpg)

社区

* 邮箱
* [Discord](https://discord.gg/Tc7c45Zzu5)
* [Twitter](https://twitter.com/deepseek_ai)

更多

* [GitHub](https://github.com/deepseek-ai)

Copyright © 2026 DeepSeek, Inc.
