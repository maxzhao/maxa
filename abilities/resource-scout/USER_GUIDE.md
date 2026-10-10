# resource-scout 用户指南

`resource-scout` 用于在自建 skill、接入 MCP Server 或写定制方案前，先搜索、比较、获取并评估已有资源。你只需说明目标、资源类型、约束和期望结果；Agent 会选择来源、给出候选和后续路线。

## 找现成 AgentSkill

适合想扩展 Agent 能力，但不确定是否已有可用 skill。

示例：

- “帮我找一个能做 React 性能优化的 skill。”
- “有没有现成技能可以生成 App Store 截图？”
- “做 API 文档维护前，先搜索合适的 AgentSkill。”
- “创建自定义 skill 前，帮我做一次资源侦察。”
- “找几个适合 Tauri E2E 测试的 skill，并比较优缺点。”

常用来源包括 ClawHub、skills.sh / `npx skills`、技能 marketplace、GitHub awesome 列表、可复用仓库和官方文档。

## 用 ClawHub 搜索或获取技能

适合自然语言语义搜索，或已知道 ClawHub 上的 skill 名称/slug。

示例：

- “用 ClawHub 搜索数据库迁移审查技能。”
- “ClawHub 上有没有 marketing automation skill？”
- “评估 ClawHub 搜到的前三个候选。”
- “我找到一个 ClawHub skill，帮我按当前环境规范安装和校验。”
- “更新一个来自 ClawHub 的 skill，但先检查本地改动。”

涉及安装、更新或改造时，Agent 会切换到当前 skill 规范：选择目标目录、迁移文件、清理临时副本、测试加载并运行校验。

## 用 npx skills / skills.sh 搜索和获取

适合搜索 skills.sh 生态，或通过 `npx skills` 获取公开技能并适配到 Neovim + MCPHub。

示例：

- “用 npx skills 搜索 playwright 相关技能。”
- “从 skills.sh 找一个文档生成 skill。”
- “这个 npx skills 包不错，获取后安装到当前环境。”
- “清理 npx skills 安装时产生的多余 agent 目录副本。”
- “用 npx skills 更新这个 skill，并重新应用本地适配。”

`npx skills` 只作为获取来源；最终结构、frontmatter、资源路径、脚本说明和加载测试仍按当前环境规范整理。

## 扩大资源搜索范围

适合做生态调研，或单一来源没有满意结果。

示例：

- “全面调研有哪些 marketplace 能找写作类 skill。”
- “从多个 skill 目录和 GitHub awesome 列表交叉验证。”
- “找维护较新、质量更高的候选，不只看排名。”
- “找跨 Claude、Codex、Copilot 都可能可用的 skill 资源。”
- “marketplace 找不到时，查可直接复用的 GitHub skill 仓库。”

## 搜索和评估 MCP Server

适合给 Agent 接入外部工具、服务、数据源或本地能力。

示例：

- “找一个适合连接 Notion 的 MCP Server。”
- “有没有现成 MCP Server 可以操作 PostgreSQL？”
- “搜索 GitHub / Glama / Smithery 上的 browser automation MCP。”
- “比较几个 MCP Server 的维护情况、权限风险、运行方式和配置复杂度。”
- “找到合适 MCP 后，按当前 Neovim MCPHub 环境安装并测试。”
- “更新一个 MCP Server，但先判断它是 Native 还是 External。”

Agent 会从官方 MCP 资源、Registry、Glama、mcpservers.org、PulseMCP、MCP.so、Smithery、MCP Market 和 GitHub awesome MCP 列表中找候选。安装/配置时会切换到 MCP 创建与配置规范。

## 评估候选是否值得采用

适合已有若干 skill 或 MCP 候选，需要排序和决策。

示例：

- “按适配成本、维护状态和功能覆盖评估这三个 skill。”
- “这个 MCP Server 需要哪些权限？有没有安全风险？”
- “这个 skill 结构是否适合当前 Neovim + MCPHub 环境？”
- “判断安装现成资源还是自己新建 skill 更划算。”
- “给出候选清单、推荐项、放弃理由和后续安装步骤。”

常见维度：能力匹配、维护状态、文档质量、资源结构、安装复杂度、权限/token/API key 风险、工具链兼容性、本地适配成本。

## 安装、测试、修复或更新 AgentSkill

适合搜索结束后，把某个 skill 纳入当前环境。

示例：

- “把这个 skill 安装成全局可用技能，并测试能否加载。”
- “把这个 skill 安装到当前项目专用目录。”
- “这个下载来的 skill 结构不规范，帮我修到当前规范。”
- “检查已安装 skill 的 frontmatter、资源引用和脚本说明。”
- “更新已安装 skill，但保留本地修改。”
- “安装后运行 skill 规范检查，并报告 warning。”

Agent 会处理目标目录选择、结构整理、获取残留清理、`load` 测试、skill 校验和必要修复。

## 没有合适资源时

示例：

- “找不到现成 skill 就直接说明，并建议是否新建。”
- “没有满意 MCP 的话，判断是否应该自己写一个。”
- “搜索不到现成方案时，给我最小自定义实现路线。”
- “先资源侦察；没有合适结果再加载对应 creator Ability 继续。”

Agent 会说明搜索范围、拒绝原因，并建议使用通用能力、创建自定义 AgentSkill，或开发/配置 MCP Server。

## 建议补充的信息

- 目标领域：前端、测试、DevOps、数据库、文档、代码审查、AI 数据处理等。
- 资源类型：AgentSkill、MCP Server，或两者都找。
- 安装目标：全局可用或当前项目专用。
- 约束：语言、平台、外网、API key、开源要求、权限边界。
- 输出：候选列表、推荐结论、安装步骤、风险评估或直接安装。
