# ability-creator 用户指南

`ability-creator` 用于创建、维护、导入、审查和改进 Maxa Ability，并保持标准 Agent Skill 源格式兼容。你只需描述目标；Agent 会按规范处理 `SKILL.md`、`ABILITY.yaml`、`USER_GUIDE.md`、`references/`、`scripts/`、`assets/`、`SYSTEM.md` 和 AbilityHook。

## 常用触发说法

- “帮我创建一个新的 Ability，用来处理网页抓取工作流。”
- “修改这个 Ability 的 `SKILL.md` 和 `ABILITY.yaml`，让 description 和 triggers 更符合规范。”
- “审查这个 Ability 的触发词是否太宽泛，是否和其他 Ability 冲突。”
- “用 prompt-engineering 规范审查这个 Ability，并修掉不符合受众和提示词契约的地方。”
- “补齐这个 Ability 的 `USER_GUIDE.md`，按用户场景举例并覆盖所有能力入口。”
- “给这个 mandatory Ability 增加根目录 `SYSTEM.md`，把最小路由规则插入系统提示词。”
- “检查这个 Ability 的 hooks 写法是否正确。”
- “把这个本地 Ability 的 `SKILL.md` 改成 Claude Code、Cursor、Codex 都能理解的通用 Agent Skill 源。”

## 新建或重构 Ability

适合从零创建或重新组织 Neovim + MCPHub Ability。

示例：

- “创建一个 Ability，用户说‘分析 Sentry 问题’时加载，能力是调查错误、定位根因、提出修复方案。”
- “我需要一个项目级 Ability，用来规范 Tauri E2E 测试流程。”
- “帮我设计目录结构：需要脚本、参考资料和模板资源。”
- “根据这些使用例子反推 description、triggers 和正文说明。”

## 从已完成工作沉淀 Ability

适合把成功路径、踩坑经验、工具组合或脚本逻辑沉淀为可复用 Ability。

示例：

- “刚才这套排查流程很有价值，请沉淀成一个项目级 Ability。”
- “把这次解决问题的成功路径整理成全局 Ability，但不要写入本项目临时路径。”
- “根据失败尝试和最终方案写一个 Ability，重点保留坑点和验证方式。”
- “这次流程里反复写的脚本逻辑以后还会用，请抽成 Ability 资源并补充 Agent 使用说明。”

## 导入外部 skill

适合把 Hermes、Claude、agentskills.io、GitHub 或其他项目中的 Agent Skill 改造成 Maxa Ability。

示例：

- “完整读取这个 Hermes Agent Skill，然后导入为 Maxa Ability，去掉 Hermes 运行时假设。”
- “把这个 Claude/Cursor 用的 Agent Skill 改造成本项目可用的 Maxa Ability。”
- “从这个外部 Agent Skill 借鉴能力，但标准 frontmatter 和 `ABILITY.yaml` 必须分别符合对应规范。”
- “导入前先检查安全风险：密钥、外传、提示词注入、危险命令和绝对路径。”

## 更新已有 Ability

适合真实使用后发现触发不准、流程过时、资源组织不合理、脚本输出不稳定或用户指南缺场景。

示例：

- “这个 Ability 经常误触发，请诊断原因并做最小化修改。”
- “Agent 使用这个 Ability 时总是忘记读某份参考资料，请改进资源路由。”
- “这个 Ability 是从外部导入的，还有兼容性问题，请按 Maxa 规范修复。”
- “根据这次使用反馈更新 Ability，同时同步 `USER_GUIDE.md` 和 lint 验证。”

## 修改或审查 `SKILL.md`

适合维护 Agent 执行说明、frontmatter、触发质量、渐进披露、资源引用和路径规范。

示例：

- “审查这个 `SKILL.md` 是否符合 ability-creator 规范。”
- “把 description 改成英文能力/适用场景，不要把触发语句写进去。”
- “优化 triggers：保留高信号短语，避免太宽泛。”
- “检查 frontmatter 是否只包含允许字段。”
- “这个 Ability 使用前必须先加载其他 Ability，请声明依赖并检查循环依赖风险。”
- “检查正文有没有绝对路径或用户专属路径，改成相对 Ability package 根目录路径。”
- “检查跨 Ability 引用是否只写目标 Ability name 和升级条件，不硬编码对方内部路径。”
- “这个 Ability 内容太长，请按渐进披露原则拆到参考资料里，`SKILL.md` 只保留核心流程。”

## 路由准确性与按需加载

适合描述或触发太宽、简单请求加载多个无关手册、路由表里塞入完整工作流等问题。

示例：

- “用明确匹配、无关请求和相近 Ability 的例子检查触发，不要因为普通词与 Ability 同名就加载。”
- “检查当前宿主到底会不会截断描述，不要直接套用 Codex 或其他宿主的预算。”
- “根文件只保留用途、边界和场景路由；详细步骤放入对应手册，共享操作只保留一份。”
- “不要把手册移走后又要求所有场景全部加载；简单语音请求不应读取切片流程。”
- “迁移规则时检查首次动作前的加载时机，以及实际角色文件、模板和脚本输出是否仍带旧指令。”

篇幅只能帮助发现候选问题，不是删除技术细节的依据。真实工具协议、安全约束和验收要求必须保留。通用自主执行、澄清、审批和完成语义由 `prompt-engineering` 负责，避免两个 Ability 各维护一套规则。

## 组织资源与脚本入口

适合整理 `references/`、脚本、模板、静态资源以及 `include` / `exclude`。

示例：

- “检查 `references/`：哪些是主路径，哪些只是 setup 或低频维护资料。”
- “这个 Ability 本身就是指导开发的，请把开发主流程放在 `references/` 根目录，而不是误放进 `references/development/`。”
- “检查所有资源文件是否都被 `SKILL.md` 引用，并在用户指南中有对应场景。”
- “这个 Ability 带脚本，请补充脚本文档，让 Agent 不读源码也知道何时运行、怎么传参、怎么看帮助。”
- “检查 `exclude` 是否错误隐藏了 Agent 必须发现的脚本入口。”
- “这个特殊数据文件默认不会显示，请用 `include` 公开它，但不要赋予脚本执行权限。”
- “审查脚本输出是否适合 Agent 使用：成功返回事实，异常返回诊断，不输出长教程。”
- “这个脚本输出太像人类日志，请改成稳定的 `--json` 或单行协议。”

## 编写或补齐 `USER_GUIDE.md`

适合让 Ability 面向用户可发现、可理解、可提问。`USER_GUIDE.md` 必须在 Ability 根目录，用中文用户语言覆盖可触发能力和工作流。

示例：

- “为这个 Ability 创建根目录 `USER_GUIDE.md`，用用户能直接复制的提问示例来写。”
- “检查现有 `USER_GUIDE.md` 是否覆盖了 `SKILL.md` 里暴露的脚本、参考资料、模板和 hook 能力。”
- “把这份用户指南从内部路径说明改成用户场景说明。”

## 编写或审查 `SYSTEM.md`

适合让规则在普通 Ability Gate 前生效。`SYSTEM.md` 放在 Ability 根目录，按 `slot` 插入主系统提示词，并按 `priority` 排序。

示例：

- “为这个 mandatory protocol Ability 创建 `SYSTEM.md`，只写最小触发和加载规则。”
- “这个 Ability 是 `visibility: search`，但需要插入系统提示词，请加 `allow_non_global: true`。”
- “这个规则属于执行协议，请把 `slot` 设为 `execution`，并设置合适的 `priority`。”
- “检查这个 `SYSTEM.md` 是否误用了 AbilityHook 字段，或声明了不存在的 slot。”
- “审查哪些规则适合放进 `SYSTEM.md`，哪些应留在 `SKILL.md` 或 references。”
- “检查主提示词与 Ability 片段是否重复维护完整协议，并验证项目覆盖、包装模板和非全局 Ability 的实际展开结果。”

只有必须在 Ability 加载前生效的约束才进入常驻片段；迁出时不能把安全、身份或所有权边界降为可选提示。

## AbilityHook 编写和审查

适合创建或检查 `hooks/` 事件监听文件，确保事件名、Markdown/Lua 格式、过滤条件、消息角色、静默模式和 payload 符合规范。

示例：

- “为这个 Ability 写一个 Markdown hook：修改 abilities 目录文件时，静默加载 ability-creator 和 prompt-engineering。”
- “为这个 Ability 写一个 Lua hook：根据事件 data 动态判断是否注入提醒。”
- “检查同一个 Ability 里是否同时存在 `hooks/EventName.md` 和 `hooks/EventName.lua`。”
- “审查这个 hook 是否使用了正确的 user / llm / system 角色。”
- “这个 hook 是辅助型的，请改成静默模式，完成后不要打断原任务。”
- “检查 hook 消息结构有没有 llm→user 边界。”
- “检查需要触发事件的脚本是否使用 stderr `__FIRE_EVENT__` 协议。”

## 创建跨 IDE/Agent 的通用 skill

适合把能力打包成 Claude Code、Codex、Cursor、Aider、Gemini CLI 或 MCP 客户端可用的通用说明，而不是只服务本地 Neovim/MCPHub 路由。

示例：

- “把这个本地 AgentSkill 改造成 Claude Code、Cursor 和 Codex 都能用的通用 skill。”
- “为这个 MCP 能力写通用 skill 文件，包括 `SKILL.md`、`AGENTS.md`、`CLAUDE.md` 和 Cursor 规则。”
- “检查通用 Agent Skill 源是否泄露本地项目路径、内部任务系统或作者环境。”
- “把可移植 Agent Skill 的说明改成英文，并从使用者 Agent 的视角来写。”

## 脚本校验和 lint

本 Ability 自带校验脚本，可检查标准 `SKILL.md` frontmatter、Ability description/triggers、`USER_GUIDE.md`、非代码文档大小、Python runtime 规则和触发词冲突等问题。

示例：

- “运行 ability-creator 的 lint，检查当前项目和全局 Abilities。”
- “用严格模式检查所有 Ability，把 warning 也当作失败。”
- “额外检查这个自定义 Ability 目录，看看有没有触发词冲突。”
- “lint 报了 description、triggers 或文档大小问题，请按规范修复。”

静态 lint 不证明请求意图匹配或模型执行效果。Agent 会按变更风险选择相关场景，分别报告静态结构、实际加载/工具集成和模型行为证据；不会为每次措辞修改强制跑完整矩阵或新增固定测试轮次。

常见检查内容：

- `description` 是否是英文能力/适用场景，而不是触发词或负面边界。
- `triggers` 是否存在、过宽、重复或与其他 Ability 冲突。
- `ABILITY.yaml` 的 `visibility`、`triggers`、`dependencies`、`include`、`exclude`、`executors`、`mcp` 与标准 `SKILL.md` frontmatter 是否合法。
- 根目录 `USER_GUIDE.md` 是否存在且非空。
- 除 `SKILL.md` 外的非代码文档是否超过当前规范限制。
- Agent 示例是否优先使用 `load`、`#ability[target]` 读取和 `@ability:...` 调用，且文件路径或资源原始标识符确实有效。
- Python 脚本是否通过有 title 的 `run(scope="tool")`、已编目 command 和字面数组 args 交给所属 uv executor 执行，且具有 uv 项目文件；手动维护命令是否保留相同 uv 运行时。

## 本 Ability 覆盖范围

- Ability 结构：`SKILL.md`、`ABILITY.yaml`、`USER_GUIDE.md`、`SYSTEM.md`、`hooks/`、`scripts/`、`references/`、`assets/`。
- 参考资料：用户发起的 Ability 沉淀/更新与外部 Agent Skill 导入流程、Ability 路由与渐进式披露、portable universal skill 指南、`SYSTEM.md` 片段指南、AbilityHook 指南。
- 脚本：标准 Agent Skill frontmatter、Ability trigger、USER_GUIDE、文档大小、Python runtime 基础 lint。
- 资源可见性：`visibility`、`include`、`exclude`、脚本入口暴露、隐藏低信号实现文件。
- 依赖声明：`dependencies`、同名 `merge`、自动加载、会话去重、循环依赖风险。

## 提问时建议补充

- 你要新建、沉淀、导入、修改、审查还是迁移 Ability。
- Ability 是否包含本地 Neovim/MCPHub 扩展，或其 `SKILL.md` 是否需要保持跨 Agent 源格式兼容。
- 用户会用哪些自然语言触发它。
- 是否需要脚本、参考资料、模板、资源文件、`SYSTEM.md` 或 hook。
- 希望直接改文件、只给方案，还是同时运行校验。
- 是否需要同步按 `prompt-engineering` 检查受众、结构、上下文边界、失败处理和验证方式。
