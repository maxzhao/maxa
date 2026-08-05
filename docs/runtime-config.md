# maxa Runtime 配置参考（`.maxa/runtime.yaml`）

> 目标项目运行时配置位于各项目 `<project-root>/.maxa/runtime.yaml`。本文件是
> 完整字段参考：类型、必填性、默认值与功能描述。可复制的完整示例见
> [`runtime.yaml.example`](./runtime.yaml.example)。
>
> 约定：
> - `optional` 字段未配置时使用下表"默认值"列的运行时默认行为；`required` 缺失即配置错误（fail-closed）。
> - 凭据只按 **环境变量名** 引用（`api_key_env`），配置中写字面量密钥永远报错。
> - 未知顶层字段报错（fail-closed）；`extensions` 是唯一开放透传键。
> - 当前实现为阶段 1-2（四协议 + 会话状态机/自动工具循环）；标注"预留"的字段已通过 schema 校验但对应阶段尚未消费。

## 顶层字段

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `schema_version` | integer | ✅ | — | 配置格式版本，当前固定 `1`；缺失/不支持版本 fail-closed |
| `project_id` | string | ✅ | — | 项目标识（会话/历史归属作用域；阶段 4 起用于项目隔离） |
| `provider` | struct | 可选 | 无（见下） | 真实 provider 定义；不配置时本地 mock/echo 仍可用，`resolve_provider` 会报错 |
| `history` | struct | 可选 | 全部关闭（预留） | 会话历史/恢复（阶段 4 消费） |
| `orchestrator` | struct | 可选 | 见下表 | 编排器：工具并发/watchdog/context-stop（阶段 2 已消费） |
| `ui` | struct | 可选 | 见下表 | Chat 视图外观（layout/show_reasoning 已消费） |
| `skills` | struct | 可选 | 见下表 | Skill 开关（阶段 3 消费） |
| `mcp` | struct | 可选 | 见下表 | 外部/原生 MCP（阶段 3 消费） |
| `status` | struct | 可选 | 见下表 | 状态栏/lualine/billing（阶段 5 消费） |
| `extensions` | map | 可选 | 空 | 开放透传键（未知键不报错），供宿主/扩展消费 |

## `provider`

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `provider.default` | string | 可选 | 无 | 未显式指定 provider 时使用的定义 id；未设置且调用方未给 id 时报错 |
| `provider.definitions` | map | 可选 | 无 | provider 定义表（id → 定义）；块存在时必须非空 |

### `provider.definitions.<id>`

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `protocol` | enum | ✅ | — | `openai_chat` / `openai_responses` / `anthropic_messages` / `gemini`（四协议之一；不提供其他别名） |
| `base_url` | string | ✅ | — | API 端点；尾部斜杠自动归一 |
| `api_key_env` | string | 可选 | 无 | 环境变量**名**（禁字面量密钥）；运行时从该 env 读取，不落盘 |
| `model` | string | ✅ | — | 模型名（如 `deepseek-v4-flash`） |
| `context_window` | integer | 可选 | `128000` | 上下文窗口（tokens）。context-stop 的用量比例按此计算；未声明用 128K 假设 |
| `capabilities.vision` | boolean | 可选 | 协议默认 `false` | 是否支持图像输入 |
| `capabilities.tools` | boolean | 可选 | 协议默认 `true` | 是否支持工具调用（按协议矩阵，不可声明与协议冲突） |
| `capabilities.reasoning` | boolean | 可选 | 协议默认（见下） | 是否支持推理内容（openai_chat 默认 `false`，其余三协议默认 `true`） |
| `request.timeout_ms` | integer | 可选 | 无 | 单请求超时（毫秒） |
| `request.connect_timeout_ms` | integer | 可选 | 无 | 连接超时（毫秒） |
| `request.retries` | integer | 可选 | 无 | 传输层重试次数（≥0） |
| `request.proxy_env` | string | 可选 | 无 | 代理环境变量名（如 `HTTPS_PROXY`）；`null` 表示显式无代理 |

## `orchestrator`（阶段 2 已消费）

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `orchestrator.tool_concurrency` | integer | 可选 | `1` | 工具批并发数；当前实现仍按顺序执行（>1 仅解析，阶段 3 激活） |
| `orchestrator.watchdog.enabled` | boolean | 可选 | `false` | 请求卡死看护：无消息/无进展超时后按预算自动重试或终止 |
| `orchestrator.watchdog.timeout_ms` | integer | 可选 | `180000` | 无进展观察窗口（毫秒） |
| `orchestrator.watchdog.max_retries` | integer | 可选 | `3` | 看护自动重试预算；手动提交重置；耗尽后单次终端失败并解锁 Chat |
| `orchestrator.context_stop.enabled` | boolean | 可选 | `false` | 上下文用量阈值自动刹车（一次性） |
| `orchestrator.context_stop.target` | number/string | 可选 | 无 | 触发阈值：绝对 `70` 或 `"70%"`，相对 `"+10"`（当前用量 +10%）；usage 不可用时 fail-closed 不触发 |

## `ui`

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `ui.layout` | enum | 可选 | `vertical` | 布局：`vertical`（右侧半屏分屏）/ `horizontal`（底部）/ `float`（半宽浮窗）/ `buffer` |
| `ui.show_reasoning` | boolean | 可选 | `false` | 是否显示推理折叠行（`### Reasoning` + 字数） |
| `ui.start_in_insert_mode` | boolean | 可选 | `true`（预留） | 打开 Chat 是否自动进入 insert 模式（schema 已校验，阶段 5 收口） |
| `ui.spinner_delay_ms` | integer | 可选 | 见 status 实现（预留） | spinner 出现延迟（毫秒；schema 已校验，阶段 5 收口） |
| `ui.fold_reasoning` | boolean | 可选 | `true`（预留） | 推理块是否默认真实折叠（schema 已校验，阶段 5 收口） |

## `skills`（阶段 3 消费）

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `skills.global_enabled` | boolean | 可选 | `true`（预留） | 全局 Skill 启用开关 |
| `skills.project_enabled` | boolean | 可选 | `true`（预留） | 项目 Skill 启用开关（project 覆盖 global） |

## `mcp`（阶段 3 消费）

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `mcp.project_servers` | boolean | 可选 | `true`（预留） | 是否加载项目 `.maxa/mcp/servers.yaml` |
| `mcp.request_timeout_ms` | integer | 可选 | 无（预留） | MCP 请求超时（毫秒） |
| `mcp.auto_start` | boolean | 可选 | `true`（预留） | 启动时自动拉起外部服务器 |

## `status`（阶段 5 消费）

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `status.lualine` | boolean | 可选 | `true`（预留） | 是否向 lualine 投影运行状态（只读 spine） |
| `status.billing` | boolean | 可选 | `false`（预留） | 是否启用账单/quota 投影 |

## `history`（阶段 4 消费）

| 字段 | 类型 | 必填 | 默认值 | 功能描述 |
| --- | --- | --- | --- | --- |
| `history.enabled` | boolean | 可选 | `false`（预留） | 历史持久化总开关 |
| `history.auto_save` | boolean | 可选 | `false`（预留） | 自动保存会话 |
| `history.continue_last_session` | boolean | 可选 | `false`（预留） | 启动恢复上次会话 |
| `history.title_provider` | string | 可选 | 无（预留） | 标题生成方式（模型/本地） |
| `history.expiration_days` | integer | 可选 | 无（预留） | 历史保留天数 |

## 相关运行时行为（默认 usage 与 context-stop）

- context-stop 的用量来源：优先取最近一次 provider `usage_updated` 快照（input+output tokens），
  无快照时用消息栈本地估算（约 4 字符/token，确定性）；窗口取 `provider.definitions.<id>.context_window` 或 128000。
- `:MaxaContextStop <percent|+N|off>`：arm 一次性 context-stop（`70` / `"70%"` 绝对、`"+10"` 相对、`off` 解除）。
  busy 达到阈值 → 当前回合自然结束后停止自动续跑（状态行 `status: soft-stop requested`）；idle 达到阈值 → 阻断下一次自动续跑。
