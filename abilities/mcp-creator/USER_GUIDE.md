# mcp-creator 用户指南

mcp-creator 用于在 Neovim + MCPHub 中创建、维护和调试 MCP Server。你只需说明目标 server、要改的工具、期望行为、约束和验证方式；Agent 会选择 Native/External 路径、读取对应规范并处理重载。

## 快速说法

- “用 mcp-creator 创建一个 MCP Server。”
- “新增一个 Native MCP Server，用来操作 Neovim buffer。”
- “接入一个 External MCP Server。”
- “修改这个 MCP 工具的 schema / handler / result shape。”
- “改完 MCP Server 后应该 restart MCPHub 还是重启 Neovim？”
- “优化这个 server 的工具说明，减少 load 上下文。”

## 场景 1：创建 MCP Server

- “我想创建一个 MCP Server，功能是……请先判断 Native 还是 External。”
- “新增 Native MCP Server，读取当前 Neovim chat/buffer 状态。”
- “新增 External MCP Server，用 Node/Python 调第三方 API。”
- “创建本地 External Server，并补齐 MCPHub 配置和验证。”

## 场景 2：修改 Native Server

- “这个 Native MCP Server 的工具参数需要增加字段。”
- “修复 Native Server handler，并说明验证方式。”
- “新增/删除/重命名 Native Server 工具。”
- “修改 nativeMCPServers 配置后，按正确方式生效。”

Native Server 是 Neovim 进程内 Lua。修改后通常应先本地验证，再用 restart-resume 完整重启 Neovim、恢复当前 chat 并继续；不要只重启 MCPHub。

## 场景 3：修改仓库内建 MCPHub

- “修改 `lua/maxa/mcphub` 下的 MCPHub setup/state/UI。”
- “调整 MCPHub Native framework 或 registration。”
- “检查内建 MCPHub 的后端版本和启动错误。”
- “安装项目锁定的 MCPHub 后端。”

MCPHub core 是 Maxa AI 内建的 Neovim 进程内 Lua。修改 `lua/maxa/mcphub/**` 后也必须完整重启 Neovim；仅从 unchanged manifests 重装精确后端时可只重启 MCPHub。缺少后端时运行 `just mcphub-backend-install`。

## 场景 4：修改 External Server 或配置

- “External MCP Server 代码改完了，请重启 MCPHub 并继续验证。”
- “把这个第三方 npx/uvx/SSE server 配到 MCPHub。”
- “调整 mcpServers 的 env 或 disabled。”
- “External Server 连不上，请检查配置、日志和最小工具调用。”

External Server 或 `mcpServers` 配置通常通过 MCPHub 重启生效。

## 场景 5：优化 tool schema / 工具结果

- “这个工具 description 太长，压缩成适合 LLM 的说明。”
- “检查 inputSchema：required、enum、default、类型和参数说明是否清楚。”
- “把警告、示例、决策树从 schema 移到 Ability 文档。”
- “审查工具返回值是否塞入教程、next_action 或工作流说明。”
- “这个 server 工具太多，合并/改造成更适合 Agent 的接口。”
- “设计参数结构，避免模型误传参。”

## 场景 6：MCP 使用说明和描述优化

- “给这个 MCP Server 创建同名 Ability，并把使用决策写进 SKILL.md。”
- “实时工具描述太长，在 Ability 中配置独立覆盖文件，只保留精简描述。”
- “分离实时参数结构、描述覆盖和使用工作流，避免复制完整 schema。”

## 场景 7：Maxa AI Chat 集成

- “这个工具需要访问当前 Maxa AI Chat。”
- “工具调用后等本轮 LLM 完成再执行动作，怎么做？”
- “处理 chat 状态持久化，避免 save/restore 后丢失。”
- “判断 adapter 是否支持 token 统计，或维护模型 context window 映射。”

## 场景 8：ChatSubmitted hook / listener 冲突

- “排查 ChatSubmitted hook 为什么递归触发。”
- “设计不会和 chat listener 打架的 hook 边界。”
- “审查自动提交/监听逻辑是否会重复注入消息。”

## 场景 9：工具实现模式选择

- “这个 server 像 CRUD/配置管理，按合适模式组织工具。”
- “封装外部 API 或系统命令，参考现有模式实现。”
- “这个工具需要把文档注入当前会话上下文。”
- “多个工具有重复逻辑，请抽取 utils 并统一错误处理。”

## 场景 10：Native 模板与参考实现

- “MCPHub 官方 Native Server resource 读不到，用备用模板创建。”
- “生成 init.lua、tools/xxx.lua、utils.lua 基础骨架。”
- “参考 Chat builtins / session / winctl 的实现风格。”

## 自动触发示例

- “修改 `lua/maxa/mcphub` 下的内建 MCPHub runtime。”
- “修改 `lua/maxa/mcphub/native_servers` 下这个 Native Server。”
- “调整 `mcp-servers` 里的 External Server。”
- “改 MCPHub 的 `servers.json` 配置。”

## 资源能力

- Native Server 指南：创建、注册链路、Neovim 重启生效、测试和参考实现。
- External Server 指南：第三方包、本地项目、SSE 配置、MCPHub 重启与调试。
- Native 模板：server 入口、工具模块、utils 骨架。
- 工具模式：CRUD、外部 API、Neovim API、上下文注入、系统命令封装。
- Maxa AI Chat 模式：chat 对象访问、状态持久化、hook、adapter 能力检测。
- Chat listener 冲突：ChatSubmitted hook、自动提交、递归防护、监听边界。
- 所有权：Maxa AI 直接初始化 `lua/maxa/mcphub/**` 中的 MCPHub core；Native Server 位于 `lua/maxa/mcphub/native_servers/**`；精确后端通过 `just mcphub-backend-install` 安装。
- 重启脚本：`restart_mcphub.lua` 用于 External/连接/unchanged-manifest backend 刷新；`restart_nvim_resume.lua` 用于内建 MCPHub 或 Native Lua 变更后的完整 Neovim 重启与 chat 自动恢复。
- Hook：MCP 相关文件创建/修改时静默提醒 Agent 加载本技能。

## 提问时最好补充

- 创建还是修改 server；目标 server 名称。
- Native 还是 External；不确定时让 Agent 判断。
- 每个工具的输入、输出和副作用。
- 是否涉及 Maxa AI Chat、Neovim buffer/window、外部 API 或系统命令。
- 期望验证方式：静态检查、最小工具调用、重启 MCPHub、或重启 Neovim 后再验。

## MCPHub core 或 Native 修改后自动重启 Neovim

可这样说：

- “内建 MCPHub 或 Native MCP 改完后，用 tmux 自动重启 Neovim 并继续当前会话。”
- “用 restart_nvim_resume 测试完整重启恢复。”
- “不要只重启 MCPHub，完整重启 Neovim 后继续。”

该能力只支持 tmux。Agent 会保存当前 chat，重启 Neovim，恢复 LazyVim session，按当前 `save_id` 恢复会话，并在 MCPHub ready 后自动继续。
