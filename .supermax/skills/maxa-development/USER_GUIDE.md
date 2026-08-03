# maxa runtime 开发指南（用户手册）

用于指导 Agent 在已有的 maxa Phase-0 运行时骨架上，**增强或扩展横向功能点**时
遵循的纪律：优先复用 LazyVim 生态能力、保持既有契约不变、增量增强。

## 这个技能解决什么问题

后续阶段（真实协议适配、工具/MCP/Skill、历史持久化、spine 等）会在现有
`lua/maxa/runtime/**` 骨架上进行。本技能确保 Agent 在动手时：

- 不重复造轮子——凡是 LazyVim 生态已有能力（如 plenary、snacks、nvim 内建
  `vim.*`），一律复用；
- 不破坏契约——只增量加字段/事件/provider，不改动已定稿的接口与状态机；
- 每个改动都跑验证（`just smoke` + stylua + import-guard）。

## 如何使用

直接把下面这些目标交给 Agent 即可，它会按本技能操作：

- "新增一个真实 protocol adapter（OpenAI / Anthropic / Gemini）"
- "把 tools / MCP / skills 从占位实现出来"
- "加入历史持久化 / session 恢复"
- "新增一个 Chat 快捷键或命令"
- "遇到一个通用能力（YAML、浮窗、异步、路径…），先查 LazyVim 生态有没有"

Agent 收到后会：

1. 先读本技能，按「三个问题」判断是复用生态还是领域自写；
2. 查 `ecosystem-catalog.md` 的复用表，确认该设施对应的生态库；
3. 保持 `contracts-and-invariants.md` 里的契约（provider 接口、message 形状、
   事件总线、config fail-closed、状态机）；
4. 改动后运行 `just smoke` / `just lint` / `just fmt` / `just check` 验证。

## 你只需知道的两件事

- **能复用就不要自己写**：LazyVim 依赖树里的库（不限于当前启用的）都可以用。
- **改动必须可运行验证**：任何行为改动都要跑通最接近的既有验证，不能只写计划。

若你希望某个功能用某种固定方式实现（例如必须用某插件、或必须保持某项旧行为），
在需求里明确指出，Agent 会尊重你的约束。
