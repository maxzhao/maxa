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
- **config 配置**：项目根绑定、`.maxa/runtime.yaml` 不可变快照、校验/脱敏/凭据只读 env、
-  `.maxa/mcp/servers.yaml`、prompt 组合；随功能增全字段（provider/orchestrator/history/ui/mcp/skills/status）。`.supermax/` 只承载本仓库开发治理资料。
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
- [x] config：项目根绑定 + `.maxa/runtime.yaml` 读取/不可变快照（未知字段报错、凭据只读 env）；禁止回退到母仓库 `.supermax/`
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
- [x] config：maxa setup 接线 .maxa/runtime.yaml ui.show_reasoning + ui.layout → host 默认（layout 默认 vertical=右侧半屏分屏，horizontal=底部/float=半宽浮窗可配；headless 断言）

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

### 实现
- [ ] Session/Request/ToolBatch/View 显式实体 + 合法转型 reducer（每转型 owner/event/reason/idempotency）
- [ ] submit 幂等：manual/automatic/regenerate/restore/retry
- [ ] continuation 决策表 + 持久续 key；tool 结果持久化后再续
- [ ] stop / soft_stop / context-stop / watchdog（预算可配置、手动提交重置、重试耗尽终端错误）
- [ ] stale callback/generation 拒绝；async 所有权与取消传播
- [ ] config：orchestrator（tool_concurrency/watchdog/context_stop）
- [ ] events：ToolBatchFinished/ContinuationDecided/stopped/failed

### 伴随验证
- [ ] 状态/编排/异步行（R-STATE-*）：manual submit、duplicate submit、tool continuation、soft-stop（stream+tools）、
  context-limit（busy/idle）、watchdog（retry/exhausted）、terminal-race、restore-agent-loop
- [ ] 时刻关键：terminal-race（首个终端转换胜出）、restore-agent-loop（无重复续跑/记录）

**本层 gate**：含工具调用的自动续跑 + soft-stop 操作成功；R-STATE 行为经注入确定性时钟跑通。

---

## 阶段 3 — Tool / MCP / Skill 运行时

> 纵向：真实工具与外部能力。横向：工具/服务器事件与配置字段增全。

### 实现
- [ ] Tool registry：schema 归一、自动执行（无 approval gate，显式产品策略）、批量 barrier 一次
- [ ] async task 所有权/cancel/poll + TTL(result) 生命周期（discard/defer/keep/persist）
- [ ] 外部 MCP stdio 进程生命周期（start/stop/restart/reload、capability revision、config diff）
- [ ] 原生 MCP 原语注册（mcpx/cc_history/genai/json_artifact/subagent；移除 `misc` 桶）
- [ ] Skill 发现/依赖/project-over-global 覆盖 + SkillHook（load/scope/filter/pre/post/once/cascade/restore）
- [ ] config：`.maxa/mcp/servers.yaml`、skill 开关；开发仓库 `.supermax/` 不得作为运行时配置源
- [ ] events：ToolCallStarted/Finished、MCP server-state、SkillHook 事件

### 伴随验证
- [ ] 工具行（T-*）：invalid-json、missing-required-field、automatic-sync-success、automatic-failure、
  async-success/cancel-late、parallel-barrier、display-projection、ttl-result
  （注：display-projection 中图标/折叠/状态色 L0 部分在阶段1.5 chat-ui-folds 落地；本条验证
  完整结果详情投影，依赖本阶段真实工具运行时）
- [ ] MCP 行（T-006/007 + mcp/*）：config-valid/invalid、external-start-ready/fail、request-timeout、stop、
  restart-concurrent、config-reload、native-register/duplicate/enable-disable
- [ ] Skill 行（T-008/009/010 + skill/*）：project-overrides-global、dependency-order、startup/on-load/cascade、
  pre-submit、post-observer、once-restore、filter、lua-hook-failure
- [ ] 时刻关键：parallel-barrier（ToolBatchFinished 一次）、async-cancel-late-result（迟到成功不覆盖取消）

**本层 gate**：一个外部 MCP + 一个 Skill 从发现→注册→调用→结果展示的操作链路通。

---

## 阶段 4 — 会话历史与重启恢复

> 纵向：持久化。横向：事件/配置补历史 case，消息模型引入 context/persistence 记录。

### 实现
- [ ] `.maxa/history` schema_version=1 + 原子写/index 重建（saved-index-stale 处理）；不得写入 `.supermax/history`
- [ ] 旧 `refs`→`context_items` 迁移（backup + corrupt 隔离、未知高版本 fail-closed）
- [ ] save/list/open/fork/scratch/merge/transfer/rewind/redo/title/compact/trace
- [ ] restart 恢复（absent view、不可用 MCP 容错、orphan tool 修复）
- [ ] config：history（auto_save/continue_last/title_provider/expiration_days）
- [ ] events：trace/turn 去重、恢复事件、compaction 归档事件

### 伴随验证
- [ ] 历史行（H-*）：create/save/open、write-failure、index-rebuild、legacy-refs-migration、fork、scratch、
  merge-transfer、rewind-redo、compact、trace-dedup、title-late-callback
- [ ] 时刻关键：write-failure（不报伪 saved）、rewind-redo（redo 提交一次）、trace-dedup（natural turn 一次）

**本层 gate**：保存→关闭→重开恢复闭环；原子写/迁移/并发注入 race 各验证。

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
