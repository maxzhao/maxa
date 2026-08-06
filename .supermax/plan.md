---
title: maxa Runtime 实施规划（执行计划）
created: 2026-08-03
updated: 2026-08-03
doc_role: implementation-plan
authority: draft
status: planning
sources:
  - specs/implementation-sequence.md
  - specs/validation-matrix.md
  - specs/module-disposition.md
  - specs/runtime-fixture-contract.md
  - specs/protocol-fixture-contract.md
  - specs/hook-replacement-map.md
tags: [supermax, plan, implementation, nvim-runtime]
---

# maxa Runtime 实施规划（当前由 SuperMax 开发环境管理实现）

## 目标

在本仓库（LazyVim/Neovim mother repository）内 greenfield 构建 maxa 运行时（实现路径 `lua/maxa/runtime/...`，由 SuperMax 开发环境管理），隔离于 `NVIM_APPNAME=nvim-maxa`；最终运行时的项目状态、配置、提示词、Skills、MCP 定义和历史必须使用目标项目的 `.maxa/`，不得依赖开发母仓库的 `.supermax/`。`.supermax/` 仅是本仓库的 Agent/知识/规格开发环境目录，不是交付运行时目录；最终替换 CodeCompanion/MCPHub，且不触碰 `~/.config/nvim`。

本文件是实施执行计划（以 TODO 组织），不是 TaskAdmin 进度；TaskAdmin 状态/进度按需另行建立。
规划输入以 `specs/` 为权威：四协议、Chat-only surface、自动工具执行、Actions/Commands 保留为规范约束。

## 规划原则

1. **横向基础结构先立骨架，贯穿全程**。事件总线、配置、schema、消息模型、状态机、消息循环是
   被纵向功能依赖的基础；第一批先搭最小可运行骨架，之后随每个纵向阶段逐步增全 case/字段/类型，
   不单独成层。
2. **纵向功能按依赖分层递进**，每层交付可运行、可操作、最好有 UI 体现的成果，不做半成品。
3. **验证与实现相伴递增（非 TDD 先行）**。每个行为级改动后跑最接近的相关验证
   （closest relevant validation）；回归测试在关键时刻（风险逻辑、边界、契约、状态变更、
   历史 bug、关键交互）按价值增量补，不作为开发驱动。代码改动而相关验证未跑 = 任务未完成。
   环境限制不能作为假设命令会失败的借口；除非不安全/不可能，必须真实运行验证。
4. **测试保障 + 晋级门收尾**。功能稳定后，以 `validation-matrix.md` 四组行为为基准补全可替换
   runtime 的测试；任一模块由 `partial` 晋级须其验证矩阵行具备可执行替换 runtime 测试
   （或显式接受的删除决定）。hook 测试只证明当前兼容，绝不作为替换通过。
5. **配置不作为独立体验层**。通过 provider/model 切换、prompt dump、历史操作被用户感受。

## 横向基础结构（贯穿全部阶段）

以下模块不单独占用阶段，而是"阶段 0 立骨架 + 随各阶段增全"：

- **events 事件总线**：类型化 event（event_id/sequence/订阅/派发/失败隔离/幂等）；随功能增全
  case 集合（lifecycle/request/stream/tool/mcp/skill/history/status）。
- **config 配置**：遵循 LazyVim 规则 —— 默认值统一在 `lua/maxa/init.lua` `M.defaults`（注释即文档），
  用户经 `lua/plugins/maxa.lua` `opts` 覆盖，`config.configure` 深合并 + fail-closed 校验（未知顶层键/
  协议枚举/能力矩阵/凭据只读 env）；`.maxa/state.yaml` 为唯一运行状态文件（正式名，非配置层）；
  扩展类内容遵循 CodeCompanion 文件约定（`.maxa/mcp/servers.yaml`、`.maxa/skills/`、`.maxa/system.md`、
  prompt 组合）；随功能增全字段（provider/orchestrator/history/ui/mcp/skills/status）。`.supermax/` 只承载本仓库开发治理资料。
- **schema 数据模型**：消息 content-part / usage / session / 错误码；随功能增全类型。
- **conversation 消息模型**：provider 中立角色/内容部件/context item/提交校验。
- **session + orchestrator 状态机/消息循环**：Session/Request/ToolBatch/View 实体、合法转型、
  submit-intent、continuation 决策、stop/cancel/watchdog。
- **tools/mcp/skills 运行时**：Tool registry、外部 MCP 生命周期、原生 MCP、Skill/SkillHook。

> 顺序依赖：阶段 0 骨架（含最小状态机的可运行 Chat）→ 阶段 1 协议适配 → 阶段 2 状态机完整化 →
> 阶段 3 工具/MCP/Skill → 阶段 4 历史/恢复 → 阶段 5 host/status/Action·Command 收口 →
> 阶段 6 兼容切换。横向栈在每个阶段随对应功能增全，不做独立层。

---

## 阶段 0 — 横向骨架 + 最小可运行 Chat（地基）

> 产出首个可运行成果：用 mock/echo provider 跑通的完整 Chat 闭环。这也把横向栈的壳立起来。

### 实现
- [x] 建 `lua/maxa/runtime/{config,protocol,conversation,session,orchestrator,tools,mcp,skills,events,host/nvim,compat}` 目录 + import-guard（禁用 `codecompanion.*`/`mcphub.*`/`lua/util/hooks/*`）
- [x] events：类型化 event bus 最小模型（event_id/sequence/订阅/派发/失败隔离/幂等）
- [x] config：LazyVim opts 配置模型（`M.defaults` + opts 深合并 + fail-closed 校验：未知顶层键/协议枚举/能力矩阵/凭据只读 env）+ `.maxa/state.yaml` 运行状态读写；无 `.maxa/runtime.yaml` 配置层；禁止回退到母仓库 `.supermax/`
- [x] schema：消息 content-part / usage / session / 错误码 最小集合
- [x] mock/echo provider（可回放录制流，可注入 delay/error/cancel）
- [x] 最小 Chat 视图：打开、输入、流式渲染、stop/close、provider/model 切换 UI
- [x] 最小会话状态机 + 消息循环（submit→start→stream→complete）

### 伴随验证
- [x] 最接近验证：mock provider 驱动的流式往返、模型/provider 切换、stop/close 各跑通
- [x] minimum headless 冒烟（`NVIM_APPNAME=nvim-maxa nvim --headless`）

**本层 gate**：`:MaxaChat` 打开→输入→回车→看到流式回复→可 stop/close/切 model；无网络无 key 完整闭环。

---

## 阶段 1 — 真实四协议 + 消息模型增全

> 纵向：mock 换真实 provider。横向：消息模型/usage/配置/事件 case 增全。

### 实现
- [x] 消息模型扩展：system/project/context/image/reasoning/tool 全类型 + 提交校验（empty/context-only）
- [x] OpenAI Chat Completions 适配器（request/stream/tool/usage/cancel）
- [x] Anthropic Messages 适配器（system 分离、content-block、tool_use/result、thinking 保留）
- [x] OpenAI Responses 适配器（items、strict schema、tool-only stream）
- [x] Gemini native 适配器（`generateContent`/`streamGenerateContent`、functionCall/functionResponse；禁走 OpenAI 兼容端点）
- [x] config：provider 定义、capability（vision/tool/reasoning）、协议能力矩阵校验
- [x] events：RequestStarted/ResponseStarted/MessageDelta/ToolCall 事件case
- [x] schema：usage 归一（input/output/total/cache/reasoning，source/final）

### 伴随验证（回归测试在关键点按价值补）
- [x] 四协议适配器对录制 fixture 的往返/流式/tool/usage/error/cancel 各跑通（closest validation）
- [x] 协议 fixture 关键时刻：tool-arguments-fragmented、tool-only-completed、thinking-signature、safety-block
- [x] import-guard 确认：protocol 测试不加载 codecompanion/mcphub

**本层 gate**：至少真实串通一个 provider 完整往返；四协议 fixture 组（P-*）在你配置可用范围内通过。
**人工可审核条款（2026-08-04 补充）**：用户必须能**通过使用 maxa 本身**（`:MaxaChat` 内切换
provider 并对话）体验并确认真实 provider 能力（流式回复、reasoning 折叠、归一 usage 状态行），
headless 脚本验证不算人工可审核。此条款为阶段1 gate 必要条件。

> **阶段1 gate 声明（2026-08-04，已撤回）**：❌ 撤回。
> 撤回原因：运行时/协议层验证全部通过（fixtures=41、LIVE_OK、config 72/72、w8 OK），
> 但 **host UI 未接线真实 provider**——`:MaxaProvider` 只认识 mock/echo（`protocol.get` 协议名注册表），
> 用户无法在 UI 中体验真实三协议，不满足"人工可审核条款"，故 gate 判定为**未通过**。
> （技术证据保留：流式根因修复 = plenary.job 行分割交付 stdout，transport 流式路径补回 `"\n"`。）

> **阶段1 gate 重新声明（2026-08-05）**：✅ 通过。
> W10 补做完成（`.supermax/drafts/phase1-implementation-plan.md` §W10）：host `View:set_provider`
> 支持 config provider id（deepseek-chat/deepseek-responses/deepseek-anthropic）并经
> `config.resolve_provider` + adapter 绑定 + params 构造接入 orchestrator；runtime 装配层注入
> `.env` key；`:MaxaProvider` 五 provider 可用；openai_responses 补 `reasoning_text.delta` →
> reasoning_delta（真实流 4→27 事件，fixture 同步）。验证（主会话复跑）：`W10_UI_CHAIN_OK`
> （tests/w10/ui_chain.lua：三真实 provider 走 View 全链路，text part/usage/reasoning 折叠行/
> 终态一次/real adapter 绑定/mock 取消/import-guard）；test-protocol 41、test-protocol-unit 83、
> live LIVE_OK、config 72/72、w8 chain、smoke/lint/check 全绿。
>
> **人工实测步骤（用户按此在 UI 中复核确认）**：
> 1. `cd ~/maxa && just run`（或 `NVIM_APPNAME=nvim-maxa nvim`）
> 2. `:MaxaChat` 打开；`:MaxaProvider deepseek-chat` → header 显示 `provider=deepseek-chat model=deepseek-v4-flash`
> 3. 输入"Reply with exactly: OK"回车 → 真实流式回复逐字出现；状态行 busy → completed；回复区出现 `[reasoning N chars]` 折叠行与归一 usage（input/output/cached/reason tokens）
> 4. `:MaxaStop` 在回复中途触发一次 → `status: cancelled`（可选）
> 5. 重复步骤 2-3：`:MaxaProvider deepseek-responses`、`:MaxaProvider deepseek-anthropic` 各对话一条，确认均真实流式回复 + reasoning 折叠 + usage
> 6. `:MaxaProvider mock` 切回 → 无 key 也能用的本地闭环仍在；`:MaxaClose` 关闭
> 7. 全部符合预期 → 人工审核通过，阶段1 gate 成立

---

## 阶段 1.5 — Chat UI 现代化（人工可审核观感，自阶段5 提前）

> 触发：2026-08-05 用户实测审核认为 Chat 界面与 CodeCompanion 相差太远（当前为阶段0
> 最小骨架）。差距清单：`.supermax/drafts/chat-ui-gap-analysis.md`（子代理探索产出，7 维度，
> 每项含 v18.7.0 源码证据 + maxa 现状 + 依赖分层 + 优先级）。本阶段把原阶段5 "Chat 视图完善"
> 中 **L0（不依赖底层）** 的部分提前；L3/L4 部分保留在原阶段。目标契约对齐
> `.supermax/specs/modules/chat-ui/spec.md`（status: partial，typed collapsible blocks /
> 增量 append / 布局 / lualine·spinner 渲染分离 / fixtures 规范）。

### 实现
- [x] 渲染层（chat-ui-render）——2026-08-05 完成：treesitter markdown 高亮 + header/分隔线 extmark + 消息结构（角色头/双空行/### Reasoning·Response）+ 增量 append + 自动滚动 + virtual text 占位（host/nvim/render.lua）：markdown treesitter 高亮 + header/分隔线 extmark（对照
  `ui/init.lua:512-539`、`chat/init.lua:465-473`）；消息结构（角色头/双空行间距，对照
  `builder.lua:232-243`）；流式**增量 append**（`nvim_buf_set_text` 末行追加）+ 自动滚动
  （`follow()` 语义）+ virtual text 占位——替换当前全量重写（`host/nvim` `_build_lines`）
- [x] 折叠交互（chat-ui-folds）——2026-08-05 完成：reasoning 真实 fold（foldexpr/foldtext/zo·zc）+ tool 行图标/状态色 + 稳定 ID；工具输出折叠待工具输出数据（阶段3 前置）：reasoning 真实 Neovim fold（foldtext + zo/zc，对照
  `folds.lua:253-317`）；tool 行图标与状态色（⏳/⚡/❌/✅，对照 `formatters/tools.lua` +
  `ui/icons.lua`）+ 工具输出折叠；**工具结果详情卡片待阶段3**（依赖真实工具运行时）
- [x] 输入层（chat-ui-input）——2026-08-05 完成：**一体式输入区**（对齐 CodeCompanion：无独立输入窗，chat buffer 尾部输入头+可编辑用户区；render_end 渲染边界 + render.apply 渲染区 diff；intro/visual 注入/输入历史/multiline 全适配单 buffer；多行输入 float 自适应增高）：输入区观感（intro virtual text / 占位 / 自动进入 insert，
  对照 `ui/init.lua:181-190,544-561`）；visual 选区注入 fenced codeblock（对照
  `ui/init.lua:491-499`）；输入历史导航；multiline 不受 3 行限制
- [x] 操作面（chat-ui-actions）——2026-08-05 完成：keymap 注册表 M.KEYMAPS（send/stop/close/clear/]]·[[/帮助/ga，替代裸 Ex 入口，命令保留兼容）+ provider/model 交互选择器（无参命令触发；M.ROOT resolve 修复）+ `:MaxaDemo` 演示会话（mock 注入 reasoning+tool_call+usage，离线验收折叠/图标/状态行；修复 lazy cmd 占位与 setup guard 交互）：keymap 注册表（send/stop/close/clear/provider/model/
  regenerate…，替代裸 Ex 命令入口）；provider/model 交互选择器（对照 `ga` 交互，适配
  W10.2 真实 provider 解析）
- [x] 状态层（chat-ui-status）——2026-08-05 完成：host/nvim/status.lua lualine/spinner/usage 只读投影（View:projection，渲染分离契约）：lualine + spinner + usage 投影（只读 spine，事件驱动；
  对齐 chat-ui spec 渲染分离契约）
- [x] config：maxa setup 接线 LazyVim opts ui.show_reasoning + ui.layout（默认值在 `M.defaults.ui`）→ host 默认（layout 默认 vertical=右侧半屏分屏，horizontal=底部/float=半宽浮窗可配；headless 断言）

### 伴随验证
- [x] headless 渲染断言（2026-08-05 主会话复跑全绿）：tests/ui/render.lua（markdown extmark/增量 append/follow/virtual text/fold 交互）+ input.lua（intro/历史/visual 注入）+ actions.lua（keymap/导航/选择器/帮助）+ status.lua（投影/spinner/lualine）+ config.lua（ui 接线）
- [ ] 人工验收锚点（待用户 UI 实测确认）：对照 `chat-ui-modernization-plan.md` §5 清单
  （P0 九项：markdown 高亮/消息结构/流式观感/reasoning 折叠/工具行图标/操作 keymap/输入区
  观感/输入历史·选区/provider 选择器）
- [x] 回归（2026-08-05 主会话复跑）：tests/w8/chain.lua、tests/w10/ui_chain.lua、just smoke/lint/check、test-protocol(41)、test-protocol-unit(16+67)、test-config(72) 全绿；import-guard 无违禁

**本层 gate**：P0 差距点全部在 UI 中人工可审核（用户对照清单实测确认）；既有验证全绿。

---

## 阶段 2 — 完整会话状态机 + 自动工具循环

> 纵向：AgentLoop 与连续能力。横向：事件/配置继续增强（stop/context/续跑 case）。
> 实施：`.supermax/drafts/phase2-implementation-plan.md` + `phase2-todo.md`（W1-W8 子代理实施，主会话逐波验证）。

### 实现
- [x] Session/Request/ToolBatch/View 显式实体 + 合法转型 reducer（每转型 owner/event/reason/idempotency）——`session/init.lua`（状态全集对齐 chat-runtime-state、`transition()` 数据驱动转型表、终端 CAS、generation、兼容层）
- [x] submit 幂等：manual/automatic/regenerate/restore/retry——intent_id 重放返回既有决策（`replay_result`）、retry_of 链、`truncate_after_last_user`、`Session:restore`
- [x] continuation 决策表 + 持久续 key；tool 结果持久化后再续——`orchestrator/decide.lua`（8 条件优先级）、`session.loop.decisions` 同 key 拒绝重复决策、tool_result 先于 barrier/续跑
- [x] stop / soft_stop / context-stop / watchdog（预算可配置、手动提交重置、重试耗尽终端错误）——cancel/stop/soft_stop 三操作分离 + `orchestrator/watchdog.lua`（clock 驱动、工具执行排除、max_retries 默认 3、耗尽单次终端 failed）
- [x] stale callback/generation 拒绝；async 所有权与取消传播——provider/tool/watchdog/view 全路径 id+generation+terminal+shutdown 守卫；view detach/close/nvim-exit/double-cleanup
- [x] config：orchestrator（tool_concurrency/watchdog/context_stop）——schema → 运行时消费（默认 tool_concurrency=1、watchdog{false,180000,3}、context_stop{false}）
- [x] events：ToolBatchFinished/ContinuationDecided/stopped/failed——tool_batch.{started,draining,finished}/tool_call.finished/continuation.decided/watchdog.retry/chat.soft_stop_{requested,completed}/session.transition_rejected（additive）

### 伴随验证
- [x] 状态/编排/异步行（R-STATE-*）：manual submit、duplicate submit、tool continuation、soft-stop（stream+tools）、context-limit（busy/idle）、watchdog（retry/exhausted）、terminal-race、restore-agent-loop——`tests/state/` 32 fixture（含 async 组 6 项）全绿
- [x] 时刻关键：terminal-race（首个终端转换胜出）、restore-agent-loop（无重复续跑/记录）——`tests/state/{terminal-race,restore-agent-loop}.lua` 断言

**本层 gate**：含工具调用的自动续跑 + soft-stop 操作成功；R-STATE 行为经注入确定性时钟跑通。

> **阶段2 gate 声明（2026-08-05）**：✅ 技术验证通过（人工可审核条款待用户 UI 实测）。
> 技术证据（主会话逐波复验全绿）：`just test-state` 32/32（R-STATE 状态/编排/异步全套，fake clock 注入确定性时间）；
> smoke、w8 chain、w10 ui_chain（三真实 provider 链路）、ui 五套、test-protocol(41)、test-protocol-unit(16+67)、
> test-config(72)、lint、`git diff --check` 全部通过；import-guard 无违禁。
> 关键行为：含工具调用的自动续跑（tool-continuation/continuation-once：结果持久化先于续跑、每批恰一次 continuation）、
> soft-stop（soft-stop-stream/soft-stop-tools：drain 后抑制续跑、toggle 关闭、不取消 provider）、context-stop（busy 一次性/idle 阻断）、
> watchdog（有界重试 3 次每重试新 generation、手动提交重置、耗尽单次终端 failed + Chat 解锁）、terminal-race 首个终端胜出、
> restore-agent-loop 无重复续跑。UI 入口已就绪：`:MaxaSoftStop`、`<C-s>`/`gs`（soft-stop）、`:MaxaStop`（hard cancel）、
> 状态投影 \"status: soft-stop requested\"。
>
> **人工实测步骤（用户按此在 UI 中复核确认）**：
> 1. `cd ~/maxa && just run`（或 `NVIM_APPNAME=nvim-maxa nvim`）
> 2. `:MaxaChat` 打开；`:MaxaProvider deepseek-chat`（或 mock）
> 3. 输入要求工具调用的提示词（真实 provider 如 deepseek 支持工具时）→ 观察自动续跑：工具结果后模型自动继续，无需手动回车
> 4. 回复中途按 `<C-s>`（insert 模式）或 `gs`（normal 模式）/ `:MaxaSoftStop` → 当前回复/工具批自然完成后状态行出现 "status: soft-stop requested"，且不再自动续跑
> 5. `:MaxaContextStop 10`（或 `+5`）→ 通知 "armed at 10%"；继续对话，上下文用量（本地估算或真实 usage 快照）达到阈值后自动 soft-stop（状态行 "soft-stop requested"）；`:MaxaContextStop off` 解除
> 6. `:MaxaStop` 仍为立即取消（hard cancel）；`:MaxaProvider mock` 可离线复核（mock 注入工具调用 + soft-stop/context-stop 流程）
> 7. 全部符合预期 → 人工审核通过，阶段2 gate 成立（headless 证据见上）
> 配置参考：`lua/maxa/init.lua` `M.defaults`（默认值 + 注释即文档；无独立 docs 配置文档，`docs/` 已移除）
**本层 gate**：含工具调用的自动续跑 + soft-stop 操作成功；R-STATE 行为经注入确定性时钟跑通。

---

## 阶段 3 — Tool / MCP / Skill 运行时

> 纵向：真实工具与外部能力。横向：工具/服务器事件与配置字段增全。

### 实现
- [x] Tool registry：schema 归一、自动执行（无 approval gate，显式产品策略）、批量 barrier 一次
- [x] async task 所有权/cancel/poll + TTL(result) 生命周期（discard/defer/keep/persist）
- [x] 外部 MCP stdio 进程生命周期（start/stop/restart/reload、capability revision、config diff）
- [x] 原生 MCP 原语注册机制（通用注册 API `register(def)` + 动态保留 ID，注册即保留；**不内置业务原语名**，具体原语由实现它们的阶段注册；移除 `misc` 桶，显式诊断原语 `diagnostics/echo`）
- [x] Skill 发现/依赖/project-over-global 覆盖 + SkillHook（load/scope/filter/pre/post/once/cascade/restore）
- [x] config：`.maxa/mcp/servers.yaml`、skill 开关；开发仓库 `.supermax/` 不得作为运行时配置源
- [x] events：ToolCallStarted/Finished、MCP server-state、SkillHook 事件

### 伴随验证
- [x] 工具行（T-*）：invalid-json、missing-required-field、automatic-sync-success、automatic-failure、
  async-success/cancel-late、parallel-barrier、display-projection、ttl-result
  （注：display-projection 中图标/折叠/状态色 L0 部分在阶段1.5 chat-ui-folds 落地；本条验证
  完整结果详情投影，依赖本阶段真实工具运行时）
- [x] MCP 行（T-006/007 + mcp/*）：config-valid/invalid、external-start-ready/fail、request-timeout、stop、
  restart-concurrent、config-reload、native-register/duplicate/enable-disable
- [x] Skill 行（T-008/009/010 + skill/*）：project-overrides-global、dependency-order、startup/on-load/cascade、
  pre-submit、post-observer、once-restore、filter、lua-hook-failure
- [x] 时刻关键：parallel-barrier（ToolBatchFinished 一次）、async-cancel-late-result（迟到成功不覆盖取消）

> **阶段3 gate 声明（2026-08-05）**：✅ 技术验证通过（人工可审核条款待用户 UI 实测）。
> **2026-08-05 真实路径修正（W1/W2）**：补运行时装配链（runtime/assemble：tool_registry +
> MCP registry/apply_config + skills discover/loader 注入 host 默认视图）与请求 tools 填充
> （orchestrator 按 provider capability 调用 adapter `form_tools`，wire 名 = id 编码
> `server-tool`，executor 经 provider_tool_ids 反查回 registry id——OpenAI/Anthropic/Gemini
> 实测拒绝含 `/` 的工具名）；`:MaxaDemo` 演示命令与相关代码已移除（真实对话可完成测试）。
> 测试：tests/tools/assemble.lua（装配链）、request-tools.lua（请求 tools 断言 + 四协议
> form_tools 形状）、gate.lua 增真实装配链与请求构造断言；w10 内容断言放宽（模型可能调用
> 工具或偶发空流，plumbing 断言保持严格）。
>
> 技术证据（主会话逐波复验全绿）：`just test-gate` P3_GATE_OK——外部 MCP（真实 node stdio
> 进程 tests/mcp/fixtures/stdio_server.mjs，initialize→initialized→tools/list→tools/call 全握手）
> 与 demo Skill（skills/demo-echo，tools/echo.lua 工具注册）从发现（.maxa/mcp/servers.yaml）→
> 注册（fixture-echo/echo + demo-echo/echo）→调用（真实 JSON-RPC 往返）→结果持久化（tool 消息
> 先于 barrier）→host 投影（✅ 状态行、### Tool: 折叠、foldtext 含真实结果）→barrier 恰一次 →
> 自动续跑（continuation.decided 恰一次）；全程无 `.supermax` 路径、无 HTTP transport、import-guard
> 干净。工具 12/12（T-*：invalid-json/missing-required/automatic-sync/automatic-failure/async-success/
> async-cancel-late-result/parallel-barrier/display-projection/ttl-result）、MCP 12/12（mcp/* 全行 +
> native-register/duplicate/enable-disable/nvim-exit）、Skill 12/12（project-overrides/dependency-order/
> startup/on-load/cascade/pre-submit/post-observer/once-restore/filter/lua-hook-failure）、test-state
> 33/33、test-config、test-protocol 41、test-protocol-unit 16+67、ui 五套、w8/w10 链全绿。
> gate 暴露并修复：W3 mcp/server.lua run 闭包 task.complete 参数错误（批处理悬挂）——集成测试价值。
> 事件：mcp.server_state + skill.hook_registered/fired/failed/restored（additive，events-status envelope）。
>
> **人工实测步骤（用户按此在 UI 中复核确认；2026-08-05 修正为真实路径——W1 运行时装配链 + W2 移除 MaxaDemo 后，真实对话即可触发工具执行）**：
> 1. 前置：仓库根创建 `.maxa/mcp/servers.yaml`，示例：
>    ```yaml
>    schema_version: 1
>    servers:
>      fixture-echo:
>        enabled: true
>        transport: stdio
>        command: node
>        args: ["/home/maxzhao/maxa/tests/mcp/fixtures/stdio_server.mjs"]
>        cwd: "/home/maxzhao/maxa"
>        request_timeout_ms: 10000
>        startup_timeout_ms: 10000
>    ```
> 2. `cd ~/maxa && just run`（或 `NVIM_APPNAME=nvim-maxa nvim`）；`:MaxaChat` 打开；
>    `:MaxaProvider deepseek-chat`（真实模型）。运行时装配（runtime.assemble）自动读取
>    servers.yaml 启动外部 MCP 进程、发现并加载 skills/demo-echo，工具注册进 tool registry
>    并随真实 provider 请求携带工具 schema。
> 3. 输入引导使用工具的提示词（如"请使用 echo 工具把 hello 返回给我"）→ 真实模型读到
>    请求中携带的工具 schema（wire 名 `fixture-echo-echo` / `demo-echo-echo`）后自主发起调用
>    → 观察：工具行状态图标（⚡→✅）、`### Tool:` 结果折叠（zo/zc 展开、foldtext 含真实结果）、
>    结果后模型自动续跑、状态行 busy→completed + usage。
> 4. 反向检验：注释/改名 servers.yaml 后重启 → Chat 仍可用（MCP 缺席容错，工具调用转为
>    标准 unknown-tool 错误）；`.supermax/` 全程不参与。
> 5. 全部符合预期 → 人工审核通过，阶段3 gate 成立（headless 证据见上）。
> 配置参考：`lua/maxa/init.lua` `M.defaults` `mcp`/`skills` 字段（servers_file/roots 开关）。
>

**本层 gate**：一个外部 MCP + 一个 Skill 从发现→注册→调用→结果展示的操作链路通。

---

## 阶段 4 — 会话历史与重启恢复

> 纵向：持久化。横向：事件/配置补历史 case，消息模型引入 context/persistence 记录。

### 实现
- [x] `.maxa/history` schema_version=1 + 原子写/index 重建（saved-index-stale 处理）；不得写入 `.supermax/history`
- [x] 旧 `refs`→`context_items` 迁移（backup + corrupt 隔离、未知高版本 fail-closed）
- [x] save/list/open/fork/scratch/merge/transfer/rewind/redo/title/compact/trace
- [x] restart 恢复（absent view、不可用 MCP 容错、orphan tool 修复）
- [x] config：history（auto_save/continue_last/title_provider/expiration_days）
- [x] events：trace/turn 去重、恢复事件、compaction 归档事件

### 伴随验证
- [x] 历史行（H-*）：create/save/open、write-failure、index-rebuild、legacy-refs-migration、fork、scratch、
  merge-transfer、rewind-redo、compact、trace-dedup、title-late-callback
- [x] 时刻关键：write-failure（不报伪 saved）、rewind-redo（redo 提交一次）、trace-dedup（natural turn 一次）

**本层 gate**：保存→关闭→重开恢复闭环；原子写/迁移/并发注入 race 各验证。

> **阶段4 gate 声明（2026-08-06）**：✅ 技术验证通过（人工可审核条款待用户 UI 实测）。
> 实施（`.supermax/drafts/phase4-implementation-plan.md` + `phase4-todo.md`，W1-W5 子代理实施 + 主会话逐波复验）：
> W1 存储层（`history/{storage,ids,migrate,init}.lua`：原子写=同目录临时文件+rename、saved-index-stale 会话保留可重建、
> generation 守卫拒绝 stale 覆盖、index read-modify-write 串行、legacy refs→context_items 迁移 .bak 保留原件、
> corrupt 隔离不删除、schema_version>1 fail-closed）；W2 服务+操作族（save/list/open/fork/scratch/merge/transfer/
> rewind/redo/title + title.lua generation 守卫 + auto_save listen/dispose）；W3 trace（trace.lua 1119 行纯库：
> manifest/events.jsonl/index、append_event dedupe_key 去重、rebuild_index、membership、natural-turn 去重、
> backfill 幂等、read/synthesize/find、archive 前置能力；服务层 start_trace/trace_read/backfill/record_turn；
> events 追加 4 个 additive trace 名）；W4-A compact+恢复（compact.lua 纯策略：protected prefix/compute_protected_boundary/
> build_summary_prompt 8 段结构；Service:compact TRACE ORDER archive→applied→save、overwrite 保 id / new 生成 compact_
> 前缀 + provenance、summary 失败零落盘；restore_bundle 全量 bundle；events 追加 6 个 additive history 名）；W4-B
> host/assemble/config 接线（defaults.history 补全 + check_history_block fail-closed；assemble asm.history 非阻塞 +
> teardown dispose；host :MaxaSave/:MaxaHistory、View:close close-save 先于 session 销毁、view_durable_snapshot 组合
> 公开 API、continue_last + _restoring 防递归、restore_chat 恢复流（close 旧 view → 新 view → provider 绑定 →
> restore_agent_loop 孤儿修复 → bind+bind_trace 同 save_id 续写）；plugins cmd 列表；.gitignore 追加 .maxa/history/）。
> 技术证据（主会话复验全绿）：`just test-history` 21/21（create-save-open/write-failure/index-rebuild/legacy-refs-migration/
> concurrent-save/fork/scratch/merge-transfer/rewind-redo/title-late-callback/trace-dedup/trace-backfill/trace-fork-membership/
> trace-read/compact/restart-recovery/history-operation-close/host-commands/auto-save/config-history/restore-end-to-end）；
> smoke、test-state 33/33、test-config、test-protocol 41、test-protocol-unit 16+67、test-tools、test-mcp 12/12、
> test-skills 12/12、test-gate P3_GATE_OK、ui 五套、w8/w10 链、lint、`git diff --check` 全部通过；import-guard 无违禁。
> 关键行为：原子写（临时文件+rename，注入失败点）、saved-index-stale（会话保留可 rebuild、绝不伪报 saved）、
> legacy 迁移（refs→context_items 一次、.bak 备份、corrupt 隔离、v2 fail-closed）、同会话 generation 串行 +
> index read-modify-write 不丢条目、fork parent lineage + membership 新 span、scratch unsavable 零落盘、merge 精确
> 范围 + provenance、transfer move 目标提交后删源、rewind truncate_after_last_user + gen+1、redo 恢复消息恰一次提交
> （W4 集成）、title-late-callback generation 守卫、trace natural-turn 一次 + untracked 零写入、compact protected
> prefix + 归档先于新 generation、restart 恢复（restore_agent_loop 孤儿修复 + 无自动续跑、provider 不可用保持 mock
> 容错）、close-save 保证保存→关闭→重开同 save_id 连续性。`.maxa/history/` 已入 .gitignore（运行时数据不入库）。
>
> **人工实测步骤（用户按此在 UI 中复核确认；2026-08-06 配置已预置，只需操作）**：
> 1. 配置已预置：`lua/plugins/maxa.lua` `opts` 已启用 `history = { enabled = true }`
>    （auto_save 默认 true；continue_last 保持默认 false —— `:MaxaChat` 总是打开新会话；
>    title_provider 默认 "auto"，LLM 不可用时回退首条用户消息；
>    经真实 opts + setup 合并 headless 验证：`HISTORY_CFG_OK enabled=true continue_last=false`）；
>    `cd ~/maxa && just run`
> 2. `:MaxaChat` 打开**新会话**；`:MaxaProvider mock`；输入几条消息（含一次 stop/error 可选）→ 每次回复完成自动落盘
>    （`ls .maxa/history/chats/` 出现 `<save_id>.json`，`index.json` 有条目；`.supermax/history` 无新写入）
> 3. `:MaxaSave` 手动保存一次 → notify "saved <save_id>"
> 4. `:MaxaClose` 关闭 → 重开 `:MaxaChat` → 这是**新的空会话**（continue_last 默认 false）；
>    `:MaxaHistory` 选择最近条目 → **立即打开该历史会话**（消息/标题/usage 完整恢复），再次输入
>    可继续对话且保存到**同一 save_id**
> 5. `:MaxaHistory` 列表按时间倒序（title · model · N msgs · 相对时间）；选择旧会话 → 立即切换打开
>    （当前会话 close 前自动保存）；**再次选择当前正打开的会话 → no-op**（notify "already the
>    active session"，会话不变）；`:MaxaChat` 再开仍是新会话
> 6. `:MaxaHistory 关键词` 过滤；`history.expiration_days = 30` 时重启后过期会话被清理（可选）
> 7. 反向检验：`history = { enabled = false }` 时 `:MaxaSave`/`:MaxaHistory` 提示 history disabled，
>    Chat 正常可用；mock/真实 provider 均可
> 8. 全部符合预期 → 人工审核通过，阶段4 gate 成立（headless 证据见上）
>
> > **2026-08-06 行为修复（用户实测反馈）**：`:MaxaHistory` 选择历史后**立即打开窗口**
> > （restore_chat 由 `_render` 改为 `v:open()`）；选择当前已打开的会话 → no-op；
> > `:MaxaChat` 在 continue_last 未设置/false 时**总是打开新会话**（当前默认视图先
> > close-save 再新建）；预置配置 continue_last 改回默认 false。验证：tests/history 22/22
> > （新增 history-commands-behavior.lua：restore 开窗/同会话 no-op/:MaxaChat 新会话/
> > 无 view 新建）、ui 五套/w8/w10/smoke/test-state/lint/check 全绿。
> >
> > **2026-08-06 尾部消息整理（MaxaHistory 打开历史会话后的输入整理规则）**：
> > `M._normalize_restored_tail`（host，纯函数）：① 确保最后一条不是未完成 tool call——
> > 尾部 assistant 消息的孤儿 tool_call parts 移除，纯 tool-call 消息整条删除（循环至
> > 尾部不再是 tool-call 形态；中间历史孤儿仍由 restore_agent_loop 注入 cancelled 修复）；
> > ② 尾部连续空内容用户消息合并为一个空用户消息；③ 整理后最后一条是用户消息 →
> > 从消息列表移除、文本预填输入缓冲（回车即重发继续对话），否则输入缓冲为空。
> > restore_chat 在 restore_agent_loop 前整理消息、open 后 `_set_input_text` 预填。
> > 验证：tests/history 23/23（新增 history-tail-normalize.lua：text+tool_call 保留文本、
> > 纯 tool-call 删除并提升前序 user、完整工具回合保留、尾部 user 移除并预填、
> > 连续空 user 合并、restore 集成输入缓冲含预填文本）、ui 五套/w8/w10/smoke/test-state/
> > lint/check 全绿。

---

## 阶段 5 — 事件/spine/状态/Action·Command 收口

> 纵向：面向用户的完整状态与操作面。横向：把各阶段积累事件 case 收束为 spine。

### 实现
- [ ] 事件总线完善：sequence/idempotency、transactional reducer、isolated observer、event_id 重放无副作用
- [ ] 不可变 spine reducer + 可选 billing/quota 投影（失败不影响 Chat）
- [ ] Chat 视图完善：attach/hide/reattach/close、snapshot 渲染、input revision 完整化、context/attachment 选择、安全切 provider/model（注：渲染/折叠/输入/操作/状态中 L0 部分已提前至阶段1.5，本条为剩余收口项）
- [ ] lualine + spinner 投影（只读 spine，不查 CodeCompanion 内部）
- [ ] Action/Command registry + palette/keymap + 内置操作族（history/compact/stop/provider/rewind/fork/health…）
- [ ] 可选消费者移植（翻译/Telegram/状态面板）；TaskBrowser 作为外部 spine consumer 保持独立
- [ ] config：ui（layout/start_in_insert/spinner_delay/status/lualine/billing）

### 伴随验证
- [ ] 状态/配置行（S-001/002、C-*）：spine snapshot、lualine 刷新、prompt 组合（fallback/override/slot/schema_version）
- [ ] host/status/action/command fixture + closest headless Neovim 集成测试
- [ ] 时刻关键：lualine 只读 spine、spinner 对 deleted view 安全、action 失败不锁死 Chat

**本层 gate**：状态栏正确反映请求/工具/终止态；Action/Command 面板可触发核心操作；spine 只读投影成立。

---

## 阶段 6 — 兼容切换与去依赖（交付落地）

> 横向：compat facade 收尾。逐 hook 迁移，仅当对应替换行为通过后撤除。

### 实现
- [ ] target-shaped compat facade + usage metrics（不暴露 CodeCompanion 对象、不记 secret）
- [ ] 现有 `ai.lua` 入口改指 target 接口
- [ ] 逐 hook 迁移（仅当 `hook-replacement-map.md` 对应 target 有通过替换验证后撤除）
- [ ] 移除 legacy display-history、直达 CodeCompanion utility、MCPHub polling/restart patch
- [ ] 仓库无 `codecompanion`/`mcphub` import 后，无兼容插件在 `nvim-maxa` 启动跑通全功能

### 伴随验证
- [ ] 无依赖启动 + 生成 prompt dump + 四协议 + runtime + headless 全套
- [ ] import/reference 全仓搜索确认无残留（除文档/迁移 reader/显式外部包）
- [ ] `migration-compatibility` 与 `hook-replacement-map.md` 全部删除标准通过

**本层 gate**：去依赖启动 + 关键操作链路在无依赖环境跑通；`~/.config/nvim` 不受影响。

---

## 测试保障 + 晋级门（收尾）

> 功能稳定后，统一以 `validation-matrix.md` 四组行为为基准补全可替换 runtime 测试。非 TDD 先行，
> 但每个阶段已随实现跑 closest validation；此处为最终的替换 runtime 测试完备与晋级门。

- [ ] 协议四组（P-OAI / P-RESP / P-ANTH / P-GEM）全部可执行；Gemini 必须 native，非 OpenAI 兼容端点
- [ ] 运行时状态/编排/异步组（R-STATE-* / async-*）
- [ ] 工具/MCP/Skill 组（T-*）
- [ ] 历史/状态/配置组（H-* / S-* / C-*）
- [ ] import-guard：替换测试与 runtime 全程不加载 `codecompanion.*`/`mcphub.*`/`lua/util/hooks/*`
- [ ] 任一模块 `partial→complete` 晋级须其 validation-matrix 行有可执行替换 runtime 测试
     （或显式接受的删除决定）；hook 测试不计数

## 依赖与并行

- 阶段 0 立骨架（含最小状态机的可运行 Chat）→ 阶段 1 四协议（适配器可并行）→
  阶段 2 状态机（串行，依赖协议与消息模型）→ 阶段 3 工具/MCP/Skill（工具 registry 先，MCP 与 Skill 后可并行）→
  阶段 4 历史（可与 3/5 部分交叉，迁移串行）→ 阶段 5 收口 host/status/Action → 阶段 6 切换（串行按 owner 组）。
- 横向栈（events/config/schema/conversation/state/orchestrator）在每阶段随对应功能增全，不做独立层。

## 注意事项 / 阻塞项

- 当前仓库 `lua/` 仅 LazyVim harness（5 个 lua 文件），specs 引用的 `ai.lua`/hooks/mcphub 源码不在此仓库，
  作为上游行为证据引用；runtime 必须 greenfield。开发期可读取本仓库 `.supermax/` 中的规则/规格，但运行时不得把它当作项目配置、提示词或历史，也不得读取/写入 `~/.config/nvim`；最终项目边界固定为 `.maxa/`。
- 官方协议证据（OpenAI/Anthropic/Gemini）已在 `protocol-fixture-contract.md` 记录，实施/验收时须复查漂移。
- 不做 TDD 先行；每个行为级改动后必须跑 closest validation，验证不过不算完成。
