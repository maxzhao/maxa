# session 用户指南

`session` 用于让 Agent 管理 MaxaAI 会话生命周期：压缩当前上下文、查看 token 状态、查询历史会话、读取 `save_id`、恢复历史会话，以及排查自动压缩和历史保存/恢复问题。一次 `load(target="session")` 同时提供使用指导、参考文档、trace 导出脚本和 MCP 工具；无需分别加载指导包与服务。当前会话已明确授权立即压缩时，仍直接调用压缩工具，不为压缩本身先加载本能力。

## 旧入口迁移

`session-admin` 已直接重命名为 `session`，不保留兼容入口；现行 `@session:<tool>` 地址不变，脚本入口改为 `@session:/scripts/trace_visualize.py`，参考地址改为 `#session[target]`。已有会话若仍加载旧包，需先清理该会话的旧 Ability 上下文，再加载 `session`；仅重启并恢复历史不一定清除旧记录。本次不批量改写历史会话。

## 你可以这样问

### 压缩当前会话

- “压缩当前会话，保留当前任务目标和下一步计划。”
- “上下文太长了，帮我 collapse 一下。”
- “继续新阶段前先压缩已完成探索。”
- “收到 token 警告了，评估是否需要 destructive 压缩。”

### Token 和上下文状态

- “查看当前会话 token 使用率。”
- “判断当前上下文是否接近上限。”
- “查询当前会话消息数量、token、context status。”
- “为什么系统提示我要控制上下文？”

### 查询历史会话

- “列出最近的会话历史。”
- “找到包含某个关键词的历史会话。”
- “读取这个 `save_id` 的用户消息和工具错误。”
- “查一下上次任务失败在哪里。”

### 导出 Trace 可视化

- “把这个 trace 导出成 Obsidian Canvas 和 Markdown 总结。”
- “用 `root_trace_id` 生成 trace 可视化文件。”
- “把这个 `save_id` 的历史会话合成 trace 可视化。”
- “重新生成 trace visualization，允许覆盖旧文件。”

### 精确定位和压缩

- “定位某段消息在历史里的 index。”
- “只压缩某个分界点之后的尾部历史。”
- “先分析当前会话分区，再给出压缩方案。”
- “这个历史会话太大了，按范围压缩。”

### 恢复或续跑历史会话

- “基于这个 `save_id` 继续之前的工作。”
- “恢复上次会话，让子代理继续执行剩余步骤。”
- “比较两个历史 `save_id` 的结果并汇总结论。”

### 自动压缩和错误恢复排障

- “自动压缩为什么没有触发？”
- “token 超限后系统怎么救援？”
- “检查 compact rescue / compact_silent 行为。”
- “为新 adapter 增加 token limit 自动压缩支持。”

### 维护历史保存、恢复和 Picker

- “检查历史保存格式和恢复流程。”
- “排查会话 Picker 里缺少某个历史记录。”
- “维护 session status API 或历史扩展 API。”

## 交接式压缩

- `/compact_rescue`：完成交接准备、给出细分历史表，发送“保守”“平衡”或“激进”选择后继续。
- `/compact_silent`：按 `maxa.compaction.profile` 选档，默认 `balanced`。`compact_self` 仅传 `instructions`，与活动自动压缩复用此流程。
- `/collapse`：保存完整 fork 后关闭原会话，在 fork 中摘要最后一条 collapse 摘要之后的消息；首次从系统/规则及完整热启动段之后开始，热启动消息原样留在前缀中。处理期间 buffer 显示 `⏳ 正在摘要...`，完成或取消后恢复输入；提示不会保存到历史。完成后停留在 fork 等待输入，原历史保留。
- 保守保留所有非删除档；平衡保留平衡/激进档；激进仅保留激进档。省略原文中对下一步有帮助的信息由 LLM 自行摘要，旧历史不会删除。
- 旧 slash 算法与 `compact_handoff*` 命令名已退役；精确范围/历史压缩工具仍可独立使用。

## Agent 会做什么

- 当前会话压缩：直接用压缩工具，不为压缩本身加载大量文档。
- 历史查询：列出、搜索、分页读取或摘要化读取历史消息。
- 精确压缩：先定位 index 和结构分区，再执行 collapse 或 range compact。
- 历史续跑：确认目标 `save_id`，再加载子代理能力继续执行。
- Trace 可视化：生成 `.maxa/history/traces/<root_trace_id>/visualization/trace-overview.canvas` 与 `trace-summary.md`，必要时更新同步忽略规则。
- 排障/开发：按需读取维护参考，不默认加载全部实现细节。

## 能力覆盖

- 当前会话交接压缩与 `/collapse` 增量摘要。
- token 使用率、消息数量、context status 查询。
- 历史会话列表、摘要、消息读取、关键词搜索。
- 工具错误读取与失败原因定位。
- `save_id` 历史定位和续跑入口判断。
- `collapse_tail` / `compact_range` 精确压缩准备。
- 自动压缩、token limit 救援、网络重试和 rate limit 排障。
- 历史保存、恢复、Picker 和 session status API 维护。
- Session trace 的静态 Obsidian Canvas / Markdown 可视化导出。

## 资源覆盖

普通使用无需点名内部资源；Agent 会按需读取。维护/排障常用：

- `references/architecture.md`：组件、存储、压缩数据流、文件地图、测试、排障。
- `references/auto-compact.md`：自动压缩、错误恢复、adapter 检测、新 adapter 支持。
- `references/history-ext-api.md`：历史扩展 API、保存/恢复、Picker、事件、session status API。
- `SYSTEM.md`：加载技能前必须生效的最小上下文压缩规则。
- `scripts/trace_visualize.py`：把 recorded/synthesized trace 导出成 Obsidian Canvas 和 Markdown。
- `hooks/ChatSubmitted.lua`：用户直接提交新消息时的轻量 collapse 推荐检查。
- `hooks/ToolCallsCompleted.lua`：工具调用结束后的 token 阈值提醒。

## 建议补充的信息

- 是当前会话，还是历史 `save_id`。
- 目标是查询、压缩、恢复、排障还是开发维护。
- 必须保留的关键内容：用户目标、规则文档、已修改文件、当前错误、下一步计划。
- 是否已出现 token 警告、token 超限或自动压缩失败。
