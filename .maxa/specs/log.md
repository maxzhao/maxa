---
title: 规格维护日志
created: 2026-07-03
updated: 2026-10-14
type: log
tags: [specs/log, status/active]
sources:
  - specs/index.md
confidence: high
---

> **TLDR**: Append-only log for `specs/` source maintenance. Workspace links in dated records are historical inputs after the recorded physical cleanup, not current dependencies.

## 2026-10-14 — collapse buffer 处理中提示

- master/126 为 `/collapse` 复用现有 summary 输入占位/锁定/恢复 helper；fork buffer 显示 `⏳ 正在摘要...`，不新增 canonical 消息，不改摘要边界/热启动/保留政策。
- Fresh-runtime 实际注册命令：pending 文本可见且不可编辑，canonical/saved history 无提示；正常完成清理并恢复输入；显式 Chat stop 清理/保留原消息，延迟摘要不提交。既有 helper 检查 24 passed，语法/差异检查通过；transport-error/close-race 未注入。
- 正式 Session compression 的 buffer-only feedback 条款与直接用户说明收敛；历史输入 `changes/collapse-buffer-progress/` 提升后清理，详细证据在任务 TODO。

## 2026-10-14 — collapse 热启动前缀修复

- 用户实测暴露首次 collapse 从系统/规则之后开始，误摘要热启动。master/125 将起点延至完整 runtime-tagged warmup 段之后；共享摘要替换只重编号替换区，不给旧前缀补写元数据。其他压缩算法/后续摘要定位不变。
- Fresh-runtime actual 原历史副本：首次 [6..7]，完整 [1..5] 内容/角色/元数据/位置在内存及保存结果中严格相等；新增真实交流后的第二次 [7..8] 保留本次调用前完整前缀及旧摘要，原用户历史未动，输入区可编辑且无业务 auto-submit。正常交流提交触发的 cache 元数据/热启动刷新与 collapse 的保留比较分开记录；provider warmup 工具变体未诱发。
- 既有 fork/summary 检查 24 passed，语法/差异检查通过；正式 Session compression 规则及直接说明已收敛。历史输入 `changes/collapse-warmup-prefix/` 提升后清理；详细证据在 master/125 TODO。先前 foundation-only 验证未覆盖热启动，不作补验证主张。

## 2026-10-14 — compact_self mode 与增量 collapse 分离

- 用户确认仅移除 `compact_self.mode`、保留 `instructions`；配置交接流程不变，新增独立 `/collapse`。正式 owner：Session compression 的 instructions-only self 与增量 tail 规则、runtime chat commands 注册；直接提示/Hook/参考同步。
- master/124：工具/recovery/fork 局部检查、实际生成的系统提示词、fresh Neovim schema 与独立真实 Chat 两次注册命令通过。首轮保存 fork/关闭来源/摘要标记/前缀不变；第二轮从旧摘要之后开始，旧摘要与 Session 目录完整保留，输入区可编辑且无业务 auto-submit。存储/render 故障竞态未诱发，人工实现验收 not-run；未扩展测试体系。
- 历史输入 `changes/compact-self-collapse-slash/` 已验证提升并清理；详细命令与观察结果保留任务 TODO。用户既有 `.maxa/plan.md` 修改未动。

## 2026-10-13 — Backlot WSL 局域网监听收敛

- 用户明确改为 `0.0.0.0`；0.4.1 新项目 listener/identity/状态输出与说明已实现，内部控制仍走127.0.0.1，独立项目/PID守卫不变。无鉴权暴露警告保留，未改防火墙、转发、WSL模式或旧项目。
- master/123 主会话确认真实 `0.0.0.0` socket、项目归属及非loopback地址的实际 Chromium 页面，owned start/status/stop与compile通过；另一LAN设备可达未验证，正式owner保留该限制。
- 修改正式规则 `服务隔离`；历史输入 `changes/openmontage-backlot-lan/` 提升后清理。详细实际端口/命令只留任务TODO。

## 2026-10-13 — OpenMontage WSL 图片闭环收敛

- 用户明确要求完成剩余四项；master/123 原持久子会话完成真实生成图/编辑图的规范合成，0.4.0 final review 根据已批准 audio_promise 选择静音/转录适用性，同一缺音频源的 required-audio 目标仍 fail。
- warn 模式通过真实单次 uncertainty approval_scope 允许未确认计费继续；cap、pending、授权复用、重复 result 登记仍拒绝。未填零或声称数值预算保障。
- 一次实际 GenAI image_edit 及联合视觉 PASS、规范 manifest/event/cost、revise/abort/stale/pending 恢复路径、最终 1080p 静音片 review pass 与实际 Chromium 完整播放已验证。修改/终止使用实际当前范围预授权，未伪称独立手动按钮流程。
- 正式 owner：[OpenMontage 项目支持](./abilities/extensions/openmontage/project-support.md)。历史输入 `changes/openmontage-project-support/` 按已验证范围提升并清理，详细检查/产物由任务 TODO 拥有；WSL 外平台、TTS/video 及未选管线不扩展为验收义务。

## 2026-10-13 — OpenMontage WSL-only 清理

- 用户明确本接入仅运行于 WSL，当前 GenAI 只支持图片生成/编辑；其他 OS、TTS/video 不列为本轮验收缺口。master/123 沿用原子会话移除 `msvcrt` 与 Windows process flags，文档明确 WSL Linux。
- 0.3.1 新项目使用 fcntl/POSIX session/`/proc` 归属检查；实际新项目 Backlot start/status/stop 与 compile/catalog/help 通过，未修改旧项目、生成状态或其他 Maxa Windows 能力。范围外平台零验证；整体接入仍 review，不提前提升草案。

## 2026-10-13 — OpenMontage 核心接入交付审核

- master/123 沿用同一持久子会话完成 `abilities/openmontage/` 与项目接入；主 Agent 增加公开能力白名单，未改 Maxa 核心或 GenAI 接口。实际未知费用 schema 冲突在项目初始化适配，保留 cap 拒绝、无原生生成及无自动旧项目迁移。
- 主 Agent 观察真实 Chromium 看板/资料/批准后状态/项目隔离与合成片播放，并完成一次用户明确授权的真实 GenAI 单图交接；素材、事件及未知成本投影通过，未知计费后继续请求被阻止。
- generation-free 视觉合成片 final review 仍为 revise；未独立实测全部管线及 TTS/video/image_edit。草案与任务保留 review/未提升，细节见任务 TODO，不夸大为完整制作验收。

## 2026-10-13 — OpenMontage 接入实施授权

- 文档阶段之后用户通过 `ask` 明确选择 `authorize_openmontage_implementation`，解除仅文档限制；沿用 master/123，保持 GenAI-only、专用项目及已批准排除边界。
- 采用一个持久能力包实施子会话，主 Agent 负责整合/最终验收与规格收敛。草案未提前提升，未获得付费生成或独立 GenAI 增强授权。

## 2026-10-13 — OpenMontage 专用项目支持文档草案

- 用户确认专用项目管理、兼容制作功能与交互尽量保留、Backlot 项目隔离及维护排除 A/B；明确拒绝原生生成路由例外，所有生成仅用 GenAI，缺口由后续 GenAI 增强。
- master/123 仅书写 [提案与拟议规格](./changes/openmontage-project-support/index.md)，不安装、实施或提升；文档检查和待审核状态由任务 TODO 记录，运行/界面/付费接口验收 not-run。

## 2026-10-13 — 压缩命令退役命名收敛

- 用户确认 silent=配置式、rescue=交互式；替代此前保留旧slash的决定。master/122 退役旧mini-loop/救援工作区、专用prompt与授权旧测试，删除compact_handoff命令名；保留shared helpers及precise/history工具。
- 正式owner为Session compression及runtime chat commands；实际fresh reload后的rescue等待/用户选择与silent配置交接、补充输入及状态面板通过；shared截断/range/executor/授权规则检查通过。历史输入 `changes/retire-legacy-compaction/` 已提升并物理清理，详细证据留任务TODO。

## 2026-10-13 — 交接式压缩收敛

- master/122 完成新增命令、self两模式/活动自动路由、单表分档索引复制与LLM省略摘要；旧命令和precise/history工具保留，结束后的SubAgent自动覆盖兜底退役。
- 正式 owner：`abilities/base/session/session-compression.md`、`session-tools.md`、`abilities/base/subagent/subagent-runtime.md`，以及 runtime commands/history/lifecycle直接条款。真实 fresh-runtime配置/交互/同父self两模式/阈值选择/public handoff/取消通过；既有focused checks通过。provider context-limit故障及存储/窗口竞态未诱发，人工实施验收not-run，详细证据只在任务TODO。
- 历史输入 `changes/handoff-session-compaction/` 已提升并按协议清理；未把任务/草案关联写入正式契约。

## 2026-10-13 — 子代理询问附带前序正文收敛

- 用户批准父 Chat 临时入口完整展示既有合格前序正文，正文与提问间加入分隔线；仅三行 root prompt 拼接，不修改子 Chat 展示、参数/结果、Telegram topic/发送、FIFO 或阻塞等待资格。
- 正式 owner：`runtime/chat-builtins.md` 的 `Root ask predecessor context`；两处 no-duplication 边界收窄至 invoking Chat，保留 source-project 链接副本、前序筛选和临时清理。
- master/121 拥有实际基线、本地 Lua/既有 ask buffer 检查、完整重启和同一子会话的 root choice/回答回传/入口清理/无 canonical 正文副本证据。人工实施验收及独立 root HTTPS-link、取消/资格撤销观察 not-run；未新增测试代码或测试体系。
- 历史输入 `changes/child-ask-predecessor/` 已提升；详细执行证据只在任务 TODO，草案按协议物理清理。

## 2026-10-13 — Chat 通讯阶段期限收敛

- master/120 完成请求级有效进展 watchdog 与集中四阶段配置；连接纳入 curl 动态参数，默认 180 秒，`-1` 禁用本地控制但保留真实错误恢复。普通 Chat 移除冲突的 raw 连接/低速/总时限，不修改工具执行或辅助请求策略；独立 watchdog 重提链退役。
- 正式 owner：`runtime/lifecycle-and-message-injection.md` 的 adapter observation/request progress/once-only settlement；`runtime/plugin-entrypoints.md` 的阶段字段、显式旧配置兼容及 Chat curl policy。8 项 watchdog、4 项既有恢复、7 项 Responses/超时衔接检查通过；完整重启后的有效配置、Gemini handler 复用及实际 Responses 请求续跑通过。
- 真实上游故障、180 秒卡死及 live Gemini/Anthropic API 未诱发，自动化模拟范围保留；详细证据由任务 TODO 拥有。历史输入 `changes/centralize-chat-llm-timeouts/` 已提升，按协议清理。

## 2026-10-12 — 局域网本地文件链接收敛

- 用户确认的全局只读服务已实施：固定端口、PID/项目/允许目录登记、30 秒清理与逐请求存活检查；终轮/ask 的展示和 Telegram 副本自动转换，模型与历史正文保留本地路径。默认项目 `.maxa/`，沿用上传域名/TLS，无分享记录、过期机制、心跳或预览前端。
- 正式 owner：`runtime/chat-commands.md`（服务/投影及群组 `/tg_upload`），`runtime/chat-builtins.md`（ask），`runtime/plugin-entrypoints.md`（终轮/监听），`services/telegram-bridge.md`（投影后完整分段）。master/119 拥有聚焦 Node/Lua、真实多-Neovim生命周期、HTTPS Chromium、完整重启、实际终轮/历史重绘和 Telegram 投递证据；用户确认 topic 图片链接可打开。
- Child/root relay 和 HTML/formatted 内容未独立 live 观察，现有规则与限制保留；未增设 UI 测试或全项目测试。历史输入 `changes/lan-file-links/` 已提升并按协议清理，详细结果仅在任务 TODO。

## 2026-10-12 — 完成通知本地优先静默编辑收敛

- 用户确认本地继续输入只编辑原 TG 通知，没有新增提醒；编辑错误静默忽略，不补发、不重试、不打断对话。真实缺失消息路径返回失败且无 Chat 警告；前台通知抑制仍保留，用户确认 `ok` 未投递属于正常行为。
- 正式 owner：`runtime/plugin-entrypoints.md` 的 `Reply opportunity on a completion notice` 与 `services/telegram-bridge.md` 的 `Notification status edits are best-effort and non-disruptive`。master/118 拥有实施与聚焦检查、重启和交互证据；旧监听测试仍有新增消息断言，未经授权未改测试。待投递竞态/长分段状态编辑未独立 live 验证，正式 owner 保留限制。
- 历史输入 `changes/telegram-local-notice-edit/` 已提升并按协议删除；无剩余草案时一并移除 `changes/` 路由索引。

## 2026-10-12 — Ask 前序正文与 Telegram 完整发送收敛

- 仅转发 ask 紧邻前序的可见 LLM 正文，先完整正文后独立询问；用户/其他工具边界不向前搜旧回复。现有完成通知的摘要、截断和正文归一化删除，纯文本通知共用 <=3900 UTF-16 单位的无损顺序分段，部分投递不整体重放。
- 正式 owner：`runtime/chat-builtins.md` 的 `Ask relays only its immediately preceding visible LLM response`；`services/telegram-bridge.md` 的 `Plain Telegram notifications are complete and sequential`；`runtime/plugin-entrypoints.md` 的 `Completion notices retain the complete LLM response`。
- master/117 记录聚焦 Lua/语法/diff 检查、完整 Neovim 重启及真实客户端投递。用户确认工具前序 ask-only、LLM 正文在先询问在后、4513 字符含中文/emoji/编号/结束标记的两段通知完整；新 relay 故障/取消和完整 listener terminal-turn 未单独 live 验证，正式 owner 保留限制。
- 历史输入 `.maxa/specs/changes/ask-llm-telegram-full-delivery/` 已提升，按协议删除；详细实施与验证证据仅由任务 TODO 拥有。

## 2026-10-12 — 默认用途与命名 Preset 分离收敛

- `maxa.defaults` 的八类用途与任意命名 `maxa.presets` 分离；可见名称/类型/描述注入 Runtime。SubAgent/媒体统一公开 `preset`，视频上游档位为 `generation_preset`；不歧义旧配置与参数仍可兼容。
- Provider/adapter compact、summary 整块优先级、自动 compact、父 Chat 继承及项目/会话/持久化选择保留。部署 TTS/video 未声明能力的限制没有伪造修复。
- TaskAdmin master/116 记录聚焦配置/provider/Background/SubAgent/恢复/媒体/image/prompt 检查及完整重启后的真实目录、无网络拒绝、可见表格和 DeepSeek compact 优先证据。方案人工确认已通过；实施人工验收与付费上游可用性未执行。
- 正式 owner：`runtime/plugin-entrypoints.md`、`abilities/base/subagent/subagent-runtime.md`、`abilities/base/genai/native-mcp.md`。历史输入 `.maxa/specs/changes/defaults-presets/` 已提升，按当前协议清理；详细执行证据只在任务 TODO。

## 2026-10-12 — 安装引导代理参数收敛

- `install.sh` 仅通过 `--proxy <http(s) URL>` 选择代理；默认直连，忽略继承代理变量和项目配置。稳定 proxy owner、帮助、Justfile 安装说明和运行时网络指令同步，不再保留固定安装代理例外。
- master/115 记录 Bash syntax、既有 WSL installer 的隔离参数/环境/sudo 检查、prompt contract 和 diff 验证；无实际安装、sudo、Windows 目标或外部下载，人工实施验收 not-run。历史输入 `.maxa/specs/changes/installer-proxy-argument/` 已提升并删除。

## 2026-10-12 — env 默认来源与模型发现代理修复收敛

- `Gateway proxy policy is metadata-owned` 的默认地址来源改为 `"env"`；provider 未启用仍直连，显式 `false` 关闭共享代理。模型发现仅在直连时添加 bypass 参数，部署重复项删除。
- master/114 记录两个实际 discovery owner 的代理/直连参数回归、5 项代理、6 项初始化、环境检查及完整重启观察；现有 provider 路由不变。无付费请求，人工实施验收 not-run。历史输入 `.maxa/specs/changes/default-env-proxy-source/` 已提升并删除。

## 2026-10-12 — 声明式代理来源收敛

- `Gateway proxy policy is metadata-owned` 支持 `"env"`、自定义地址/函数、`false`/省略关闭；默认 `false`，关闭不查询环境。现有部署声明 `"env"`，provider 路由不变。
- master/113 记录 5 项来源/路由、6 项额度、6 项初始化、环境/default/syntax/diff 检查与完整重启观察。实际仍只有 openrouter/xsai/xuanjing 走代理；人工实施验收 not-run。历史输入 `.maxa/specs/changes/declarative-proxy-source/` 已提升并删除。

## 2026-10-12 — 显式代理地址集中化收敛

- `Gateway proxy policy is metadata-owned` 已合并至 `runtime/plugin-entrypoints.md`。地址来自进程环境/运行时 `.env`，不启用未配置的消费者；provider 路由、MCP opt-in 集合、脚本回退与安装引导例外保持不变。
- master/112 记录聚焦检查和完整 Neovim 重启后的实际路由/MCP 隔离证据；旧模型发现检查因用户 provider 子集缺少 gemini 而失败，不改变用户配置。无付费请求、安装、证书签发或人工实施验收。临时输入 `.maxa/specs/changes/centralize-opt-in-proxy/` 已提升并清理，以下草案记录只作为历史。

## 2026-10-12 — 显式代理地址集中化草案

- 用户批准 `.env` 为共享地址来源，要求保持现有代理/直连策略；master/112 拥有实施与验证。临时输入位于 `.maxa/specs/changes/centralize-opt-in-proxy/`，未验证前不替换稳定条款。

## 2026-10-11 — Creator 名称修复与 18 项基础能力分类

- 确认现行包与 Resource Scout guidance 使用 `ability-creator`；修复 Resource Scout 规格的旧 handoff 标识，保留实验性状态与原验证限制。当前 Blender 维护和路由规则引用同步更正；历史报告/capture/原任务中的旧名称保留。
- 按用户决定新增基础能力 `ability-creator`、`browser`、`agency-nexus`，基础名单共 18 项。Browser 完整规格迁到 `abilities/base/browser/`；11 项有独立规格，7 项的独立规格空白明确标注，未复制通用 package 或 Agency/SubAgent owner。browser-dogfood/browser-e2e 仍是扩展工作流。
- 当前索引、Browser 跨层 QA 链接、MCP Creator 的具体 Browser owner、派生来源及历史设计中的当前指针已协调；此前 15 项分类记录和 master/110 证据保持历史原貌。运行包、工具/权限、默认行为、连接和加载时机不变；master/111 拥有本轮映射及验证证据。

## 2026-10-11 — 基础/扩展能力与组件规格重分类

- 完整通读 71 个现有文件；能力规格分为 `abilities/base/` 与 `abilities/extensions/`，基础名单精确为用户指定的 15 项。10 项已有独立规格，neovim、prompt-engineering、spec-admin、winctl、wsl-windows 尚无独立正文，索引明确覆盖空白，不创建空规格。
- 通用 Ability/MCP 框架归 `runtime/`；Session 工具/压缩归基础 session，Chat history 仍归运行时。Browser、Blender 和独立专项工作流按扩展能力归类；GDA 归 `tools/gda/`，Godot 自动语言工具归 `runtime/godot-tooling/`，服务、Prompt 产物与 Obsidian 插件保留独立 owner。
- 重建当前分层索引和阅读顺序，修复当前正文/来源/派生导航引用；既有 56 份契约正文仅允许路径重定位，原规则、锚点、生命周期与验证限制不变。全部旧日志、原任务记录及历史输入路径保留；本条及当前索引取代旧历史映射的当前导航职责。运行包位置、默认行为与授权不变。
- TaskAdmin `master/110` 拥有逐文件输入/输出映射及本次验证证据；本次目录整理不重新认证文内历史 runtime/UI/API 验证。

## 2026-10-11 — Native JSON Artifact and Misc retirement

- User-requested removal deletes both Native services and the JSON Artifact Ability/protocol. Current Native inventory is `genai`, `session`, `subagent`; builtin string validation moves to its existing runtime helper without changing error messages. Current specifications/routes no longer depend on removed documents. Dated mixed validation records remain historical evidence, not current capability declarations.
- Local validation passed: `system_prompt_contract_spec.lua`, `ability_catalog_test.lua`, `project_admin_ability_spec.lua`, builtin `inventory_spec.lua`, changed Lua syntax/MCP JSON, helper behavior comparison with HEAD, `git diff --check`, weave byte budgets and removed-source link searches. Existing `call_tool_json_input_spec.lua` and `call_tool_async_cancel_spec.lua` fail because their Chat mocks omit `opts`; `tool_call_core_guard_test.lua` expects retired `ask_llm` blocking. All three also fail against HEAD; no unrelated repair is included.
- Full restart-resume passed. Fresh Neovim has exactly `genai`, `session`, `subagent`, ready MCPHub with neither retired service, no retired Ability resolution or generated JSON protocol, and loadable `kill`/`wait`/`keep`/`fire` definitions. Knowledge navigation validation is file-side only; no live Obsidian graph claim is made.

## 2026-10-11 — Tauri WDIO retirement

- User-requested retirement removes `mcp-servers/tauri-wdio/`, its project MCP registration and all `wdio-*` recipes. The removed External MCP spec no longer appears in current routing; Runtime setup guidance uses the generic project External Server owner. Browser/CDP/Tauri remains supported independently.
- Dated validation records mentioning the former Server remain historical evidence, not current configuration or implementation dependencies.
- Focused validation: `nvim --headless -u NONE -l tests/mcphub_live_backend_smoke.lua` passed using Browser MCP; `nvim --headless -u NONE -l tests/maxa_ai_setup_atomic_test.lua` passed all 6 checks. Recipe listing, MCP JSON and removal checks, changed-scope diff checks and Browser E2E setup syntax passed. After MCPHub restart, the Hub is ready and both live Server inventory and Ability resolution exclude the retired Server. Live Vault outlinks/backlinks for the affected desktop nodes resolve to remaining sources. Browser E2E still needs an external fixture supplied via `TAURI_APP_PATH`; actual UI tests were not rerun.

## 2026-10-10 — GenAI model-specific matte retirement

- User-authorized retirement is represented in [GenAI](genai/native-mcp.md): registration rule renamed from five media/matte tools to four media tools; dedicated external-matting rule, ownership/source/evidence claims removed. GenAI exposes no dedicated Replicate matte tool or forwarding alias; generic Replicate operations remain unchanged, without a new wrapper.
- TaskAdmin `master/109` owns 11 passed existing media checks, exact four-tool local registration, full Native restart, committed live GenAI catalog containing only the four remaining tools, and a no-cost `audio_speech` request rejected locally for missing TTS capability. No media dispatch, image upload or prediction occurred; no new human implementation-review pass is claimed.
- Historical input `.maxa/specs/changes/remove-genai-corridorkey/` and its routing-only parent are removed after verified rule promotion. Formal owners remain independent of operation identity; research records are labelled historical rather than erased.

## 2026-10-10 — Local HTTPS domain configuration convergence

- User-approved local `MAXA_CERT_DOMAIN` configuration is represented in [Chat commands](runtime/chat-commands.md), retaining `/upload starts one asynchronous trusted-HTTPS session`. Bundled upload and certificate management share process-env > selected `.env` precedence; missing domain retains loopback upload and errors before certificate operations. HTTPS identity validation, runtime-root certificate paths and no-downgrade behavior remain unchanged.
- TaskAdmin `master/108` owns passed Bash/Lua configuration checks, 12 existing Lua upload checks, 9 affected Node checks, and fresh-Neovim actual `/upload` HTTPS-page observation in real Chromium (HTTP 200, Dashboard visible, Cancel cleaned the session/placeholder). No certificate issuance/renewal, file upload or Chat submission occurred; no human implementation-review pass is claimed.
- Historical input `.maxa/specs/changes/configure-local-https-domain/` is deleted after verified rule convergence; its temporary routing-only parent is removed. Current navigation routes only to independent formal owners. Local domain values remain ignored; public code/current docs/tests no longer embed the personal deployment domain.

## 2026-10-10 — Ask reply rewind convergence

- User-approved re-answer behavior is represented in [Chat commands](runtime/chat-commands.md), retaining `Rewind/redo/summarize use manual messages only` and `Cursor rewind retains the selected message` identities. Successful input/choice replies enter rewind/redo/cursor selection, restore original draft and replace the matching canonical tool result on resend; notify/errors and manual-only summarize remain unchanged.
- TaskAdmin `master/107` owns 24 passed existing slash checks, changed-Lua syntax/diff checks and actual fresh-Neovim scratch `/rewind`, picker, `gr`, exact draft/content/provenance, paired history and provider continuation (`ok`). Another active Chat initially blocked restart; user restarted safely, then live checks passed. No new UI test suite or human implementation-review pass is claimed.
- Historical input `.maxa/specs/changes/ask-rewind-reanswer/` and its routing-only parent are deleted after verified promotion; current routing points only to independent formal owners.

## 2026-10-10 — GenAI media independence convergence

- User-approved behavior is represented in [GenAI](genai/native-mcp.md) (`Adapters are the only media service identities`, `Image calls use selected adapter capability mode`) and [Runtime](runtime/plugin-entrypoints.md) (`Provider owns adapters`, `Adapter declarations are the only media capability source`). Media names default to provider IDs when omitted; explicit persisted names remain. Same-name LLM connection inheritance and derived media publication are removed; legacy LLM-only overrides must move into media capabilities.
- TaskAdmin `master/106` owns passed focused provider/media tests, changed-Lua syntax, fresh-Neovim capability/provider resolution and actual picker observation, unchanged explicit-name continuity and no-cost Codex tool validation. Strict Ability lint retains 0 errors/2 pre-existing unrelated warnings; no new paid generation or human implementation-review pass is claimed.
- The promoted historical input `.maxa/specs/changes/genai-llm-independence/` and its temporary routing-only parent are deleted after rule convergence. Formal owners remain independently readable with preserved requirement anchors; current navigation no longer links those inputs.

## 2026-10-10 — Reviewed specs promoted without execution associations

- User confirmed human review passed for all 11 current changes: `namespace-ability-prompts`, `maxa-project-configuration`, `flatten-project-settings`, `simplify-project-metadata`, `unify-ability-management`, `rename-to-maxa`, `unify-runtime-version`, `flatten-maxa-runtime`, `remove-upstream-plugin-surfaces`, `english-maxa-panel`, `knowledge-weave`. All 26 deltas already had accepted stable merges; original implementation tasks `master/94`–`master/104` remain completed and unchanged.
- Full delta-to-owner comparison covered 71 named rule occurrences: 54 represented in current owners, 15 superseded by later reviewed rules and 2 removed with explicit replacements. Direct reconciliation repaired the stale `<leader>aa` command-entry rule, Chinese default-service labels, old MCP config/control-plane/policy statements and the missing unrelated-runtime-data deletion protection. Current source confirmed `<leader>aC` command entry, project/global selectors and English provenance labels; no runtime code changed.
- Formal contracts now retain behavior, source/stable-owner dependencies, expected acceptance and actual coverage limits, without implementation-task identities, task/change backlinks or historical change catalogs. TaskAdmin's own product behavior remains governed; its integration clause distinguishes temporary cached identity from task-independent formal specs. Detailed historic results remain in existing tasks/logs; previous failed/partial/not-run evidence is not relabeled by today's human review.
- The reviewed `.maxa/specs/changes/` tree (11 workspaces, 26 deltas and 74 files including routing indexes) is physically removed after coverage/reference convergence, without a durable archive copy. Current spec navigation no longer routes to it. Future Ability policy is a proposal only: `abilities/spec-admin/` remains unchanged.
- [TaskAdmin master/105](../tasks/master/task_105/todo.md) owns the exact 26-delta mapping, final static/consumer checks and recovery state for this cleanup. Git history and the original implementation tasks own prior execution evidence; deleted input paths in historical records are not live references.

## 2026-10-10 — Knowledge weave convergence

- [Accepted delta](changes/knowledge-weave/index.md) merged into [Project Vault](project-vault/project-vault.md); content ownership, generated budgets, user-triggered maintenance and complete old-area retirement are current behavior. Current direct TaskAdmin/trace references are repaired without changing their behavior.
- TaskAdmin `master/104`: Ability catalog, focused size/guarded-wrapper checks, 44 full content bodies, 63 frontmatter mappings, 18 small generated files and actual Obsidian links/backlinks/scoped search passed. New network and ordinary old-directory targets have no unresolved links; unrelated pre-existing graph issues not repaired. Human implementation review and old-source runtime/UI/API revalidation remain not-run.

## 2026-10-10 — Knowledge weave proposal

- [Knowledge weave delta](changes/knowledge-weave/index.md): user approved content-owner separation, generated topic/concept network and byte budgets; subsequently required complete old-area retirement without a compatibility router or dedicated archive.
- TaskAdmin `master/104` owns implementation, current-project migration and focused file/live retrieval evidence. Vault identity/schema/runtime and other projects remain unchanged.

## 2026-10-09 — English Maxa panel convergence

- [Accepted panel change](changes/english-maxa-panel/index.md) merged into [MCPHub](mcp/mcphub-runtime.md): built-in UI/selectors/confirmations are English; three-row option-4 MAXA logo has centered common-width alignment, muted base/accent ornaments and surrounding clearance; inline state/provenance colors reuse theme groups. External text/settings/policies and prior cleanup remain unchanged.
- TaskAdmin `master/103`: syntax/core loading and two fresh actual UI observations passed, including English P/D/H/L/? and filter/visibility/media selectors, safe cancellation, state highlights and title spacing. An observed paint-extmark accumulation defect was fixed at the shared draw owner; repeated Help count stayed equal after cross-page navigation. No new UI tests, artificial state/config mutation or full suite. Human implementation review not-run; proposal/delta accepted/merged/retained.

## 2026-10-09 — English Maxa panel proposal

- User requested English UI, selected compact half-block logo option 4 and requested state-aware colors. [Delta](changes/english-maxa-panel/index.md) replaces only panel presentation; external text, existing behavior/safeguards and prior cleanup remain.
- TaskAdmin `master/103` owns implementation and fresh actual panel/selector/color observation. Existing theme groups work; plain project/default status strings need inline highlight application. Draft until validation; design approval is not implementation review.

## 2026-10-09 — upstream plugin surface cleanup convergence

- [Accepted cleanup](changes/remove-upstream-plugin-surfaces/index.md) merged into [MCPHub](mcp/mcphub-runtime.md), [Maxa AI](runtime/maxa-ai.md) and [Chat commands](runtime/chat-commands.md). Coc/management service/unused directories/raw Config view are absent; MCPHub core, five Native capabilities, queries, definition management and creation UI/internal guide remain. Help is one Chinese Maxa usage page.
- TaskAdmin `master/102`: six focused checks, changed-Lua syntax/diff and fresh Native/core/authorized echo passed. Actual P/D/H/L/? navigation, Config absence, Chinese Help and P/D→Help refresh passed after two restart-resume cycles. One observed mapping restoration defect was fixed at the view-switch owner. Nonfatal slash-check prompt-discovery warning is recorded without claiming full discovery coverage; human implementation review remains not-run. Proposal/deltas accepted/merged/retained; historical evidence unchanged.

## 2026-10-09 — upstream plugin surface cleanup proposal

- User approved [cleanup](changes/remove-upstream-plugin-surfaces/index.md): remove coc, built-in management `mcphub`, `autoload/`, generated `test/`, inherited `doc/` and Config view; replace Help with Chinese Maxa usage. MCPHub core, `queries/`, five repository Native capabilities, management operations and creation UI/internal guide remain.
- TaskAdmin `master/102` owns implementation and focused/fresh-runtime actual panel verification. Three deltas remain draft until validation; scope approval is not human implementation review.

## 2026-10-09 — flattened Maxa runtime namespace

- [Accepted naming change](changes/flatten-maxa-runtime/index.md) merged into [Maxa AI](runtime/maxa-ai.md) and [MCPHub Runtime](mcp/mcphub-runtime.md). `lua/maxa/ai/` contents now live under `lua/maxa/`; canonical modules are `maxa`/`maxa.*`, without old-module aliases. Direct current references in 25 owner specs follow this mapping; historical evidence, commands/tools/config/globals/filetypes/events/log identities remain unchanged.
- TaskAdmin `master/101`: affected Lua syntax/diff, version 4/4, atomic setup 6/6, restart/hook boundaries and actual resource checks passed. Full restart restored caller Chat, ready runtime/Hub, zero old-module caches and authorized Native `misc:echo`. Two legacy supplementary tests retain pre-existing retired-command/unsupported-adapter failures; no full-suite or human implementation-review pass is claimed.

## 2026-10-09 — mother runtime version source

- [Version source change](changes/unify-runtime-version/index.md) is accepted/merged into [Maxa AI](runtime/maxa-ai.md) and [Project Vault](project-vault/project-vault.md), retained. Mother `.version` is the shared API/schema source; project metadata, upstream license provenance and older accepted-delta historical paths remain unchanged.
- TaskAdmin `master/100`: 16 focused version/schema/setup checks and fresh-Neovim API/source/schema observation passed. Supplementary legacy smoke passed its version assertion but is blocked by its pre-existing unsupported adapter fixture; no full-smoke pass is claimed. Human implementation review remains not-run.

## 2026-10-09 — maxa rename convergence

- [Accepted change](changes/rename-to-maxa/index.md) is merged into [AI runtime](runtime/maxa-ai.md), [Project Vault](project-vault/project-vault.md), [Session history](runtime/session-history.md) and [Telegram Bridge](services/telegram-bridge.md). Proposal/four deltas are `accepted`, `archive_state: retained`; current behavior resolves through `merged_to`. Other normalized stable texts retain their non-naming behavior, identities and historical evidence.
- TaskAdmin `master/99` owns passed renamed focused Lua/Bridge checks, affected asset builds, actual fresh-Neovim/tool/Bridge/Obsidian observations, recoverable writer-stop archival and the clean-session content/path gate. No credential values/private keys, Git history/objects or media pixels are claimed read or rewritten; preserved data remain recoverable. Human implementation review is `not-run`; design approval and historical verdicts are not promoted.

## 2026-10-08 — maxa rename proposal

- User approved [maxa rename](changes/rename-to-maxa/index.md): formal `maxa`, technical PascalCase `Maxa`, explicit four-spelling mapping, current-working-tree zero residue excluding Git history/media OCR, recoverable external archival of original old-name history/scratch sets, authorized local env-key-only migration and current-project-only registration/service cutover. Downstream projects/device registrations and unrelated behavior remain out of scope.
- TaskAdmin `master/99` owns the one future implementation and minimum evidence. Four draft deltas target Runtime identity, Project Vault, Session history and Telegram Bridge. This publication changes only task/change documents and routing; runtime/stable specs/settings remain unchanged. Design approval and pre-rename baseline checks are not renamed-runtime or human implementation acceptance.

## 2026-10-08 — Unified Ability Management convergence

- [Accepted change](changes/unify-ability-management/index.md) merged into Ability Package, MCPHub Runtime, Plugin Entrypoints and Project Vault owners. Global and project definitions use `abilities/mcp.json` and `.maxa/abilities/mcp.json`; Server JSON disabled is retired in favor of project Ability policy, with granular filters retained. Native sources remain nondeletable; approved old mcp-bridge definition removed.
- TaskAdmin `master/98` owns passed focused headless/real-backend checks and fresh-Neovim actual P/H interaction, including visibility/reset/filter/details, reverse-dependency denial, Native protection, cancellation-default confirmation and project-disabled start denial. Final suite picker display follow-up passed in fresh Neovim. Maintained packages were not deleted for validation; physical cleanup effects are not live evidence. Post-implementation human review remains not-run; design approval is not reported as implementation review.

## 2026-10-08 — Unified Ability Management proposal

- User accepted [ability management](changes/unify-ability-management/index.md): separate availability/visibility/source/connection, guarded physical deletion with reverse dependencies, project-owned MCP availability and global/project `abilities/mcp.json` locations. TaskAdmin `master/98` owns implementation, focused backend checks and fresh-Neovim interaction; stable merge remains pending that evidence. Native runtime sources are not panel-deletable; old prohibited `mcp-bridge` is removed rather than enabled.

## 2026-10-08 — Project metadata simplification convergence

- [Accepted change](changes/simplify-project-metadata/index.md) merges the fixed-root/version rule and baseline identity/provenance rule into [Project Vault](project-vault/project-vault.md). Current metadata/template use only `name`, `schema_version`, `created`, `syncthing_folder_id`, `abilities`; original current-project values remain. Readers have no former version-key fallback and no metadata-controlled Vault path; supported optional runtime settings remain.
- TaskAdmin `master/97`: 22 focused Vault/ownership/wrapper checks, 6 schema checks, 10 persistence checks and baseline assertions passed. Fresh Neovim PID `60014` reports schema `ok`, exactly five metadata keys and enabled Ability; read-only name/path/Folder ID unchanged. No cross-project rewrite, external registration change, forced scan, full Windows service integration or human implementation-review claim.

## 2026-10-08 — Project metadata simplification proposal

- User approved [metadata simplification](changes/simplify-project-metadata/index.md): retain `name`, `schema_version`, `created`, `syncthing_folder_id`, `abilities`; hard-remove the old version-key reader and derive the fixed Vault root from the selected project. Existing optional runtime settings and safety/ownership checks remain. TaskAdmin `master/97` owns implementation and focused/fresh-runtime validation; no other-project rewrite, external setup or forced scan.

## 2026-10-08 — Root project settings convergence

- [Accepted change](changes/flatten-project-settings/index.md) merges five metadata/defaults/Soul rule units into Runtime Plugin Entrypoints and SubAgent Runtime. Canonical settings are root fields in `_meta.yaml`; legacy wrapper reads are side-effect free, explicit edits migrate conservatively and reject field conflicts. Templates/guidance use root keys.
- TaskAdmin `master/96`: focused default persistence (10/10), catalog/load and Soul composition checks passed; fresh PID `53872` actual P/D/project-selector Ability/model/media save/clear wrote only root keys and restored migrated original choices. Current project's original state survives explicit migration; other projects/global settings untouched. No paid generation/new UI test code or human review claim.

## 2026-10-08 — Root project settings proposal

- User requested removing the redundant `maxa_ai` block from project `_meta.yaml`. [Change](changes/flatten-project-settings/index.md) proposes root `default_adapter`, `default_model`, `soul`, `abilities`, `genai`, preserving governance and project/global inheritance. TaskAdmin `master/96` owns implementation, explicit current-project migration and validation. Legacy reads do not write; explicit writes migrate without overwriting conflicts. Stable convergence awaits fresh actual interaction.

## 2026-10-07 — Maxa project configuration convergence

- [Accepted change](changes/maxa-project-configuration/index.md) merges 15 added/modified rule units into MCPHub Runtime, Ability Package, Runtime Plugin Entrypoints and GenAI Native MCP. `:MaxaConfig` replaces the old command without alias; P manages Ability/suites, separate D manages project defaults; `<leader>aA` is global and `<leader>aa` project. Project state reuses `_meta.yaml`; concise suite IDs have computed Title Case labels and reviewed real memberships, including effective MCP-only suite metadata.
- TaskAdmin `master/95` owns focused checks, actual fresh-Neovim overlap/partial/reenable and scoped model/media select/save/clear interaction, Hook registry correction and metadata restoration. Temporary project settings restored exactly; user-owned `lazy-lock.json` preserved. No paid generation/full-project suite or human implementation-review claim. Change retained as provenance.

## 2026-10-07 — Maxa project configuration proposal

- User approved documentation-only publication after source/spec exploration and discussion. [Change workspace](changes/maxa-project-configuration/index.md) records the sole `:MaxaConfig` entrypoint (no `:MCPHub` alias), project Ability/suite switches, existing `_meta.yaml` persistence and scoped LLM/media defaults with `<leader>aA` global / `<leader>aa` project selectors.
- TaskAdmin `master/95` owns one future implementation and its evidence. Four draft deltas target MCPHub Runtime, Ability Package, Runtime Plugin Entrypoints and GenAI Native MCP. Task is pending; runtime code, current project settings and stable requirements remain unchanged. Actual implementation/UI validation and human implementation review are not-run.

## 2026-10-07 — Ability Prompt namespace convergence

- [Accepted change](changes/namespace-ability-prompts/index.md) merged only the command-identity and raw-metadata clauses into `runtime/chat-commands.md` and `prompts/markdown-format.md`. TaskAdmin `master/94` records actual post-restart Chat/Blink acceptance, ordinary/Ability coexistence, raw `${item.name}`, no auto-send and cleanup of the user-authorized temporary Ability. Focused assertions passed with the recorded isolated headless discovery warning; actual configured discovery/expansion passed. Human review is `not-run`; no additional human acceptance gate was required. Change workspace retained as provenance.

## 2026-10-07 — Ability Prompt namespace proposal

- User approved `/ability-name:prompt-name` for Ability Markdown prompts, preserving raw metadata names and ordinary prompt commands without unprefixed Ability aliases. [Change workspace](changes/namespace-ability-prompts/index.md) owns two directly affected deltas; TaskAdmin `master/94` owns implementation and validation. Status: draft; real Ability prompt interaction is not yet verified. Stable owners remain unchanged pending convergence.

## 2026-10-07 — prepared-context whole-document rewrites

- Reused one READY SpecAdmin context through separate `resume_agent(new_chat)` branches for the remaining 57 documents. After the user's scheduling update, full target text was injected directly, each branch had only `write`, and parallel activity stayed at most five with no descendants. Complete rewrites yielded 55 revised files and two exact-baseline retentions; accepted Chat Builtins stayed unchanged. Per-file results/session identities and checks: [master/93 rewrite ledger](../tasks/master/task_093/serial-rewrite.md).
- Complete-file `o200k_base`: **121,574 → 114,818** for the 57 targets, saving **6,756 (5.56%)**. Including fixed Chat Builtins, current total is **131,384**; this phase reduces the full set by 4.89%. All-file metadata/rule/value/reference checks, 241 local links/anchors, 58 index routes, final hashes, existing consumer tests (6/6) and whitespace checks passed. Parent semantic checks were focused rather than an exhaustive reread of every pair; original behavior/evidence ownership and failed/partial/not-run facts remain. No new runtime/UI or universal LLM-equivalence claim.

## 2026-10-07 — whole-document rewrite control

- User requested a same-file check of reading/writing strategy. Original owner history confirms complete cursor reads through EOF followed mainly by local edits; the inspected low-yield case was not search-only reading. Revised SpecAdmin now requires complete-source context and complete-document replacement for optimization. The same saved owner read `runtime/chat-builtins.md` fully again, published one whole-file candidate, then made semantic corrections; parent independently verified the history and read baseline/result completely.
- Complete-file `o200k_base`: **18,851 → 16,566 tokens**, an additional **2,285 (12.12%)** saving. All 108 existing Requirement/named-rule identities, frontmatter, original inline literals and link destinations remain; other 57 specs are unchanged. Consumer suite 6/6 and scoped whitespace checks passed. Detailed equivalence/limits belong to [TaskAdmin master/93](../tasks/master/task_093/todo.md). This supports additional savings from whole-document reconstruction in this follow-up, not incomplete prior reading or universal maximum compression; no runtime/UI evidence was upgraded.

## 2026-10-07 — parent acceptance of scope-wide optimization

- Parent accepted [TaskAdmin master/93](../tasks/master/task_093/todo.md) after independently reproducing the complete-file totals below, checking all 58 frontmatters/retained rule identities/link destinations, comparing selected full contracts and reviewing regrouped clauses. The existing spec-consumer suite independently passed 6/6; scoped whitespace checks passed. Task may now complete. This is documented static/consumer acceptance, with the existing runtime/UI and broader equivalence limits retained.

## 2026-10-07 — complete-rule reconstruction

- Continued the same [TaskAdmin master/93](../tasks/master/task_093/todo.md) after parent review rejected first-pass depth: preserving every old heading/scenario was not a compatibility requirement. All 58 index-routed specs were re-evaluated under refreshed SpecAdmin guidance; 49 optimized, 9 retained with fact/consumer-based reasons. Requirement, Scenario, data and acceptance facts now share complete owning rules; 227 old Scenario headings were consolidated, while all 609 Requirement identities and required anchors remain. Scenario count is descriptive evidence, not an acceptance target.
- Complete-file `tiktoken` / `o200k_base`, including retained files: **157,640 original → 151,386 first pass → 140,425 final**. Incremental saving **10,961 (7.24%)**; cumulative **17,215 (10.92%)**. Original frontmatter, task associations, lifecycle and failed/partial/not-run evidence are unchanged.
- Static checks passed: bidirectional rule review, governed-literal equivalence, numerical-value sets, all 247 local-link occurrences and 58/58 index routes; whitespace checks passed. Existing spec-consumer suite passed 6/6. Actual discovery matches the unchanged baseline contract: 57 picker-visible specs plus one intentionally excluded `doc_role: tombstone`, `status: superseded` document. Initial expectation of 58 picker items was corrected rather than changing metadata or consumer code.
- Coordinator review restored two precise conditions after consolidation: query-ID requirements do not forbid other tools' established current-Chat fallback; configured incapable media is explicitly displayed unavailable. Remaining historical tensions are task-recorded, not silently resolved. No new runtime/UI or independent-reader evidence is claimed.
- Cancelled invocations' edits were preserved and original child save_ids resumed. After the shared-budget update, the coordinator used at most four active descendants with no nested delegation; all branches are terminal. Task status is `review` for the explicitly requested parent-session acceptance, not `done`.

## 2026-10-07 — all-formal-spec optimization

- Scope: all 58 formal specs routed through 13 module indexes; 28 optimized, 30 retained after complete review because their clauses already encode distinct conditions/evidence. [TaskAdmin master/93](../tasks/master/task_093/todo.md) owns the complete per-file inventory, measurements, semantic checks and residual issues; original implementation task associations remain unchanged.
- Current-worktree baseline (including prior compaction), complete-file `tiktoken` / `o200k_base`: **157,640 → 151,386 tokens**, saving **6,254 (3.97%)**, including every retained file. Shared premises, condition tables, compact scenarios and consolidated source mappings remove repetition without a behavior/lifecycle change.
- Static validation: all 58 frontmatters, heading identities/levels, explicit anchors and link targets preserved; numerical-value sets unchanged, literal representation exceptions reviewed. All 250 local-link occurrences across formal specs/module indexes resolved; 58/58 owner-index routes valid. Main Agent inspected actual changed artifacts; existing spec-consumer tests passed 6/6 and scoped whitespace checks passed. No new runtime/UI or independent-reader trial was claimed; historical failed/partial/not-run evidence stays unchanged.
- Retained baseline tensions include retired/current tool spellings, routing versus authorized reconnect wording, command/picker descriptions, and GDA precedence/path/timeout scenario applicability. These require separate behavior/source decisions, not silent correction during compaction; exact owners are recorded in the task.

## 2026-10-07 — LLM-oriented second-sample compaction

- Restructured [shared params/streaming](mcp/native-shared-params-and-streaming.md), [GDA live operations](gda/live-operations.md), [Browser MCP](external-mcp/browser.md) and [plugin entrypoints](runtime/plugin-entrypoints.md) as compact contracts: shared premises, condition tables and consolidated evidence replace repeated scenarios. Normative identities/anchors, lifecycle, current coverage gaps and implementation ownership are preserved; no new runtime behavior. TaskAdmin `master/92` owns structural convergence and detailed validation.
- Complete-file `o200k_base`: 16,215 → 11,417 tokens (−4,798; −29.6%); per-file reductions 43.7%, 42.4%, 39.6%, 19.3%. One independent no-tools/no-parent-context reader received only rewritten specs and 18 prewritten questions; main comparison against originals passed all selected cases, with the clarified preset premise rechecked separately. Existing unspecified details remained explicit, not invented. This bounded reading check and static preservation checks do not establish every-model equivalence or runtime validation.

## 2026-10-07 — four-spec editorial compaction

- User-requested meaning-preserving compression of [MCP schema/guidance](mcp/mcp-doc-cache-contracts.md), [Godot tooling](godot-tooling/language-tooling.md), [TaskAdmin core](taskadmin/core.md) and [Chat commands](runtime/chat-commands.md). Existing lifecycle, task associations, frontmatter, all 60 requirement headings, 3 compact rule names and 32 scenario headings remain unchanged; no new task/change workspace or behavior was introduced.
- `tiktoken` / `o200k_base`, complete files: 11,774 → 9,882 tokens (−1,892; −16.1%). Per-file reductions: 12.5%, 25.3%, 11.9%, 13.1%, respectively. This encoding is a reproducible comparison, not a claim about every model's tokenizer. Exact literals, numeric values and link destinations were retained; clause review preserved permissions, ownership, failure/rollback, ordering, optionality, acceptance and unrun scopes. No runtime behavior/test results changed.

## 2026-10-07 — reviewed changes promoted and cleared

- 用户确认本次全部 44 个 change 已通过人工审核，并要求提升为正式规格、物理清空 `.maxa/specs/changes/`。所有变更此前已 accepted/merged；本次保留 20 份正式 owner 的当前规范行为，记录本次 human review passed，删除 44 个 retained workspace 及目录内索引，不建立归档副本。批量生命周期归 TaskAdmin `master/91`；原 42 个实现任务 `master/49`–`master/90` 保留 canonical association、实现与详细验证证据。
- 本次人工规格审核不把历史 failed、partial、skipped、not-run 或未测量的模型行为改写为通过；自动/live 结果复用原任务。旧 delta 中被更名、移除或后继变更替换的规则不重新覆盖正式行为，特别是 run/multirun/multicall、模型选择、子会话交接与 wait 完成结果显示。
- 本节归属表及原任务取代已删除 workspace 的 live 路由。以下历史日志和原任务中的 change 文件路径/链接仅为 Git-history provenance，不是当前文件依赖；正式规格内旧 human not-run 记述保留原时点含义，由本次审核记录补充。
- 删除前 Git revision：`aa1e9a0ca95595f2bc819e66c25566089036b2d8`。可用 `git show aa1e9a0ca95595f2bc819e66c25566089036b2d8:.maxa/specs/changes/<change-id>/<file>` 恢复历史文本。

| Change ID | Original TaskAdmin owner | Stable owners (relative to `.maxa/specs/`) |
| --- | --- | --- |
| `ability-builtin-extensions` | `master/49` | [skills/package-and-authoring.md](skills/package-and-authoring.md), [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `neovim-symbol-provider-filter` | `master/49` | [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `neovim-symbols-on-demand` | `master/49` | [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `neovim-lsp-readonly` | `master/50` | [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `scoped-run-preparation` | `master/51` | [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `unify-run-windows` | `master/52` | [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `unify-run-dispatch` | `master/53` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [runtime/openai-responses-adapter.md](runtime/openai-responses-adapter.md), [runtime/image-analysis.md](runtime/image-analysis.md) |
| `local-tool-validation` | `master/54` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [runtime/openai-responses-adapter.md](runtime/openai-responses-adapter.md) |
| `decouple-ability-file-references` | `master/55` | [skills/package-and-authoring.md](skills/package-and-authoring.md), [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `unify-ability-content-references` | `master/56` | [skills/package-and-authoring.md](skills/package-and-authoring.md), [runtime/chat-builtins.md](runtime/chat-builtins.md), [mcp/mcphub-runtime.md](mcp/mcphub-runtime.md) |
| `flatten-ability-identities` | `master/57` | [skills/package-and-authoring.md](skills/package-and-authoring.md), [runtime/lifecycle-and-message-injection.md](runtime/lifecycle-and-message-injection.md), [runtime/maxa-ai.md](runtime/maxa-ai.md), [mcp/mcphub-runtime.md](mcp/mcphub-runtime.md), [genai/native-mcp.md](genai/native-mcp.md) |
| `show-run-execution-target` | `master/58` | [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `search-text-regex` | `master/59` | [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `tool-owned-display` | `master/60` | [runtime/chat-builtins.md](runtime/chat-builtins.md) |
| `unify-tool-presentation` | `master/61` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [mcp/mcphub-runtime.md](mcp/mcphub-runtime.md), [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |
| `proxy-all-tool-presentations` | `master/62` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [mcp/mcphub-runtime.md](mcp/mcphub-runtime.md) |
| `relay-subagent-ask-to-root` | `master/63` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |
| `subagent-headless-session-tree` | `master/64` | [mcp/subagent-runtime.md](mcp/subagent-runtime.md), [runtime/session-history.md](runtime/session-history.md) |
| `wait-transient-presentation` | `master/65` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |
| `restore-multi-agent-runtime` | `master/66` | [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |
| `chat-load-slash-command` | `master/67` | [runtime/chat-commands.md](runtime/chat-commands.md) |
| `native-mcp-completion` | `master/68` | [runtime/maxa-ai.md](runtime/maxa-ai.md) |
| `align-load-content-completion` | `master/69` | [runtime/maxa-ai.md](runtime/maxa-ai.md), [runtime/chat-commands.md](runtime/chat-commands.md) |
| `subagent-goal-context` | `master/70` | [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |
| `subagent-background-tool-calls` | `master/71` | [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |
| `unify-subagent-ability` | `master/72` | [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |
| `unify-session-ability` | `master/73` | [runtime/session-tools.md](runtime/session-tools.md), [runtime/session-compression.md](runtime/session-compression.md) |
| `evolve-browser-abilities` | `master/74` | [external-mcp/browser.md](external-mcp/browser.md), [skills/browser-dogfood.md](skills/browser-dogfood.md), [skills/browser-e2e.md](skills/browser-e2e.md) |
| `fixed-slash-prompt-discovery` | `master/75` | [runtime/chat-commands.md](runtime/chat-commands.md), [skills/package-and-authoring.md](skills/package-and-authoring.md), [runtime/plugin-entrypoints.md](runtime/plugin-entrypoints.md), [prompts/commands.md](prompts/commands.md), [prompts/markdown-format.md](prompts/markdown-format.md) |
| `chat-only-markdown-prompts` | `master/76` | [prompts/markdown-format.md](prompts/markdown-format.md), [runtime/maxa-ai.md](runtime/maxa-ai.md), [runtime/plugin-entrypoints.md](runtime/plugin-entrypoints.md), [runtime/chat-commands.md](runtime/chat-commands.md), [prompts/commands.md](prompts/commands.md) |
| `subagent-context-indicator` | `master/77` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |
| `markdown-prompt-luasnip` | `master/78` | [prompts/markdown-format.md](prompts/markdown-format.md) |
| `run-agent-session-handoff` | `master/79` | [mcp/subagent-runtime.md](mcp/subagent-runtime.md), [runtime/session-history.md](runtime/session-history.md) |
| `token-threshold-session-handoff` | `master/80` | [runtime/lifecycle-and-message-injection.md](runtime/lifecycle-and-message-injection.md) |
| `chat-message-inspector` | `master/81` | [runtime/maxa-ai.md](runtime/maxa-ai.md), [runtime/plugin-entrypoints.md](runtime/plugin-entrypoints.md) |
| `chat-inspector-fold-layout` | `master/82` | [runtime/maxa-ai.md](runtime/maxa-ai.md) |
| `chat-inspector-navigation` | `master/83` | [runtime/maxa-ai.md](runtime/maxa-ai.md) |
| `unify-model-selection` | `master/84` | [runtime/plugin-entrypoints.md](runtime/plugin-entrypoints.md), [genai/native-mcp.md](genai/native-mcp.md) |
| `reconnect-authorized-mcp-tools` | `master/85` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [mcp/mcphub-runtime.md](mcp/mcphub-runtime.md), [runtime/session-history.md](runtime/session-history.md) |
| `subagent-session-handoff` | `master/86` | [mcp/subagent-runtime.md](mcp/subagent-runtime.md), [runtime/lifecycle-and-message-injection.md](runtime/lifecycle-and-message-injection.md) |
| `subagent-llm-result-format` | `master/87` | [mcp/subagent-runtime.md](mcp/subagent-runtime.md), [mcp/mcp-creator-workflow.md](mcp/mcp-creator-workflow.md), [skills/package-and-authoring.md](skills/package-and-authoring.md) |
| `builtin-llm-results` | `master/88` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [runtime/image-analysis.md](runtime/image-analysis.md) |
| `multicall-native-batch` | `master/89` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [runtime/image-analysis.md](runtime/image-analysis.md) |
| `restore-tool-result-folds` | `master/90` | [runtime/chat-builtins.md](runtime/chat-builtins.md), [mcp/subagent-runtime.md](mcp/subagent-runtime.md) |

## 2026-10-07 — customized wait results accepted

- User confirmed the revised completed display. [restore-tool-result-folds](./changes/restore-tool-result-folds/index.md) accepted/retained and merged into Chat Builtins and the directly affected SubAgent active-wait rule. The completed wait group reuses only the target's pure result ToolView; source execution/live detail remain transient. TaskAdmin `master/90` owns focused and fresh actual UI/consume/history evidence. Automated and scoped human validation passed.

## 2026-10-07 — wait customized result review

- [restore-tool-result-folds](./changes/restore-tool-result-folds/index.md) now delegates the completed target-owned ToolView under a collapsed wait group without retaining source execution state. Fresh actual SubAgent blocking/try/consume/fold expansion/history checks passed; `master/90` records evidence. The revision remains draft and the task enters review pending the user's requested visual confirmation; stable owners are not merged yet.

## 2026-10-07 — wait target-result presentation correction

- User observation clarified that completed wait must reuse the target's customized result display and remain folded; raw protocol payload folding is insufficient. [restore-tool-result-folds](./changes/restore-tool-result-folds/index.md) returns to draft under the same `master/90`, with a directly affected SubAgent delta. Only final pure result presentation may be retained, not source execution snapshots or live detail. Stable owners remain unchanged until fresh validation.

## 2026-10-07 — wait-owned result fold convergence

- [restore-tool-result-folds](./changes/restore-tool-result-folds/index.md) accepted/retained and merged into `runtime/chat-builtins.md`. Wait folds its canonical returned text without preserving source presentation; existing batch/member custom views and running-open/terminal-closed policy remain unchanged.
- TaskAdmin `master/90` owns focused checks and fresh actual pending/terminal/consume/member/history fold evidence. Human implementation review not-run.

## 2026-10-07 — wait-owned result fold draft

- [restore-tool-result-folds](./changes/restore-tool-result-folds/index.md), linked to `master/90`, records the user's choice to fold only wait's returned text. Existing original-tool transient teardown and running-open/terminal-closed member composition remain unchanged. Stable specs are unchanged pending actual Chat validation.

## 2026-10-06 — multicall convergence

- [multicall-native-batch](./changes/multicall-native-batch/index.md) accepted/retained and merged into `runtime/chat-builtins.md` and the directly affected hidden-child rule in `runtime/image-analysis.md`. Optional runs exactly matches multirun; closed history is declaration-without-runs plus flat runtime-authored calls/real results. Sequence stop/continue, independent member async and existing shared Tool Display are retained; multirun source unchanged.
- TaskAdmin `master/89` owns focused checks, full restarts, actual runs/native sequence/async-wait/preflight/cancellation/provider replay and live/terminal/restored display evidence. Running-history redraw was repaired/rechecked after restart; existing stale fixture/format checks remain failed and excluded from passing evidence. Human review not-run; signed-history expansion without proven adapter support remains fail-closed.

## 2026-10-07 — multicall runs strategy revision

- Pending convergence for in-progress `master/89`: user replaced native-only/no-runs/no-history-expansion with optional runs exactly matching multirun's schema. Single-call runs execute real members and close into declaration-without-runs plus flat runtime-authored paired calls/results; independent member async, sequence stop/continue and shared Tool Display remain. Stable specs unchanged; draft evidence remains task-owned.

## 2026-10-06 — multicall Tool Display supplement

- [multicall-native-batch](./changes/multicall-native-batch/index.md), linked to pending `master/89`, now requires Tool Display exactly identical to multirun. Delta owns presentation parity; plan/TODO route shared display reuse and actual running/terminal/restored comparison. Document-only update; implementation remains pending, proposal/delta remain draft with automated/human not-run, stable specs unchanged.

## 2026-10-06 — multicall native batch draft

- [multicall-native-batch](./changes/multicall-native-batch/index.md) linked to pending `master/89`; user approved new experimental first-position declaration, native member pairs and sequence-only on_error stop/continue (default stop). multirun stays unchanged, no batch async. This operation creates executable task/spec documents and transfers the main session only; implementation requires later explicit execution authorization.

## 2026-10-06 — Builtin LLM results convergence

- `builtin-llm-results` accepted/retained and merged into `runtime/chat-builtins.md` and `runtime/image-analysis.md`: successful wait raw passthrough, compact run/kill facts, read TTL before source separator and ordered image facts/raw answer; local load/edit/fire/error wording aligned. multirun member JSON/receipts, internal registry, execute/cancel/cursor semantics and output exemptions unchanged.
- TaskAdmin `master/88` owns focused async/read/TTL/load/analyze checks, full restart, actual wait/timeout/kill, canonical TTL defer/keep source preservation, existing-image analyze and generated Runtime. No UI test runner/full suite; Windows transport and broader controller matrix not re-exercised. Human review not-run.

## 2026-10-06 — Builtin LLM results draft

- [builtin-llm-results](./changes/builtin-llm-results/index.md) linked to `master/88`; user approved wait raw success passthrough, read TTL header and scoped builtin output cleanup. multirun structure/receipt and execution/lifetime/output-exemption semantics unchanged.

## 2026-10-06 — SubAgent LLM result format convergence

- `subagent-llm-result-format` accepted/retained and merged into `mcp/subagent-runtime.md`, `mcp/mcp-creator-workflow.md` and `skills/package-and-authoring.md`: metadata+complete raw answers, internal structured trace unchanged, legacy display compatibility and conditional shared output-authoring route. `@subagent:*` exemption unchanged; no new output limit or general result framework.
- TaskAdmin `master/87` owns 14448-byte exact projection/legacy checks, syntax/lint, complete restart, actual sync/async and two-participant final output plus real answer-fold expansion. Human review and measured future-Agent guidance behavior not-run; no UI tests or full suite added.

## 2026-10-06 — SubAgent LLM result format draft

- [subagent-llm-result-format](./changes/subagent-llm-result-format/index.md) linked to `master/87`; user approved metadata+complete prose without output-limit changes, internal structured trace preservation, historical UI compatibility and scoped mcp-creator/ability-creator output-authoring guidance.

## 2026-10-06 — SubAgent session handoff convergence

- `subagent-session-handoff` accepted/retained and merged into `mcp/subagent-runtime.md` and `runtime/lifecycle-and-message-injection.md`: main/user message-driven sibling replacement, uninterrupted original delegated call, successor result/cancel/interaction ownership and final token handoff choice. Main transfer and 8+3 finish/timeout defaults retained.
- TaskAdmin `master/86` owns focused executor/token checks, generated Runtime, full restarts and actual resume/choice/final-result/cancellation cleanup. Token decision used supplied warning usage/exhausted-budget state; Chat choice selected a real Chat/Telegram request. Human review and Telegram button click not-run; no UI test runner or full-project suite added.

## 2026-10-06 — SubAgent session handoff draft

- [subagent-session-handoff](./changes/subagent-session-handoff/index.md) linked to `master/86`; user approved main/user message-driven child handoff, same current parent and uninterrupted delegated invocation. Existing main transfer, 8+3 token finish and timeout behavior retained; stable owners remain unchanged pending relevant checks and actual interaction.

## 2026-10-06 — Authorized MCP tool reconnect convergence

- `reconnect-authorized-mcp-tools` accepted/retained and merged into `runtime/chat-builtins.md`, `mcp/mcphub-runtime.md` and `runtime/session-history.md`: actual already-authorized tool calls connect and await a disconnected source without a fresh Ability load; target resolution/preflight, history restoration and resource reads remain passive. Public run description and Ability system fragment aligned.
- TaskAdmin `master/85` owns focused dispatch/batch and transport checks, actual generated-fragment validation, zero-error package lint and real restart/resume `run_agent` success with unchanged revision/catalog. Supplementary prompt suite reaches an unrelated legacy Soul-reference failure; scoped prompt evidence passed. Human implementation review not-run; ordinary load repair excluded.

## 2026-10-06 — Authorized MCP tool reconnect draft

- [reconnect-authorized-mcp-tools](./changes/reconnect-authorized-mcp-tools/index.md) linked to `master/85`; user approved execution-time connection for already authorized tools. Preflight, history restoration and resource reads stay passive; ordinary load repair excluded. Stable owners remain unchanged pending focused checks and real restart/resume.

## 2026-10-06 — Unified model selection convergence

- `unify-model-selection` accepted/retained and merged into `runtime/plugin-entrypoints.md` and `genai/native-mcp.md`: two four-type current-value pickers, global/session separation, exact-caller media overrides and explicit-parameter precedence. Existing project LLM defaults and callable selector APIs remain supported.
- TaskAdmin `master/84` owns 75 passing existing focused cases, Lua syntax/format checks, full restart, actual menu/key/session set-clear observations, real Chat isolation and saved/compaction metadata retention. Global defaults unchanged and temporary validation Chat/overrides cleared. No UI test code authored; paid generation and human implementation review not-run.

## 2026-10-06 — Unified model selection draft

- [unify-model-selection](./changes/unify-model-selection/index.md) linked to `master/84`; user approved current-session/global four-type selectors and added visible current selections on the first screen. Existing project LLM defaults and explicit media parameters remain supported; stable owners unchanged pending focused and actual fresh-runtime validation.

## 2026-10-06 — Inspector navigation convergence

- `chat-inspector-navigation` accepted/retained and merged into `runtime/maxa-ai.md`: inherited hjkl browsing, LocalLeader-prefixed formats and inspector-local Ctrl+h/l directional/boundary/zoom controls; Tab pane mapping removed.
- TaskAdmin `master/83` owns scoped Lua checks and fresh actual affected-key interaction; no global navigation edit, dependency, unrelated test or UI test code. Human implementation review not-run.

## 2026-10-06 — Inspector navigation draft

- [chat-inspector-navigation](./changes/chat-inspector-navigation/index.md) linked to `master/83`; user authorized immediate narrow fix for conflicting `j` format mapping and inspector-local Ctrl+h/l navigation. Global tmux mappings unchanged; actual affected UI check pending.

## 2026-10-06 — Inspector fold/layout convergence

- `chat-inspector-fold-layout` accepted/retained and merged into `runtime/maxa-ai.md`: >500-character input folds, current/all controls, horizontal keyboard resize and current-pane inspector-area zoom.
- TaskAdmin `master/82` owns focused Lua/format checks and actual fresh-runtime fold/resize/either-pane zoom/format/view/hidden-cleanup observations. Geometry uses existing Snacks layout; format type remains buffer-owned and mappings rebind after pane reopen. No new UI test code/dependency; human implementation review not-run.

## 2026-10-06 — Inspector fold/layout draft

- [chat-inspector-fold-layout](./changes/chat-inspector-fold-layout/index.md) linked to TaskAdmin `master/82`; user approved >500-character input-value folds, current/all controls, left/right panes, keyboard width adjustment and current-pane zoom within inspector bounds. Stable owner remains unchanged pending actual UI validation.

## 2026-10-06 — Chat message inspector convergence

- `chat-message-inspector` accepted/retained and merged into `runtime/maxa-ai.md` and `runtime/plugin-entrypoints.md`: read-only `gi` ordinary output/tool input-output, member-local batches, generic format switching; original media picker moved to `gI`, `gd` unchanged.
- TaskAdmin `master/81` owns syntax/format checks and actual fresh-runtime ordinary/tool/member/parent/picker/close observations. Independent format buffers resolve observed readonly/ftplugin warnings; paired close restores caller focus and cleans buffers. No new UI test code/dependency; human implementation review not-run.

## 2026-10-06 — Chat message inspector draft

- [chat-message-inspector](./changes/chat-message-inspector/index.md) linked to TaskAdmin `master/81`; approved design adds read-only cursor-local content inspection and paired tool input/output, member-local batch scope and Markdown/text/JSON switching; existing media picker migrates `gi` → `gI`.
- Implementation/actual UI validation pending; stable owners remain unchanged until convergence. User approval covers design, not implementation review.

## 2026-10-05 — Token阈值交接选项收敛

- `token-threshold-session-handoff` accepted/retained并合并 `runtime/lifecycle-and-message-injection.md`：eligible持久main增加第四项，选择后safe-stop注入本次明确交接要求，一次继续由Agent草稿/file消息交给新main；其他选择和子流程保持。
- TaskAdmin `master/80` 持有获授权既有断言维护后的19/19、完整重启及实际Alt+4/明确指令/草稿/新主标记/旧历史证据。阈值检查用已有runtime入口输入，不是provider窗口压力测试；未新增UI runner，验证Chat/草稿已清理，当前工作Chat未交接；human实现审查not-run。

## 2026-10-05 — Token阈值交接选项草案

- [token-threshold-session-handoff](./changes/token-threshold-session-handoff/index.md) 关联 `master/80`；用户要求主阈值ask新增“交接到新会话继续”，选择转为明确用户指令，复用现有run_agent主交接；阈值、其他选择和子流程不变。
- 用户另行授权最小既有测试断言维护与可丢弃主Chat实际选择/交接验证；当前等待完整重启后的交互验收。

## 2026-10-05 — run_agent 主会话交接收敛

- `run-agent-session-handoff` accepted/retained；显式用户要求、main-only、严格文件/真实预加载、tool batch安全移交与独立主身份/历史保留合并到 `mcp/subagent-runtime.md`、`runtime/session-history.md`。
- TaskAdmin `master/79` 持有聚焦预加载/helper、Lua/lint/生成Runtime、完整重启及实际两文件/time预加载交接、新主继续、缺失文件保留、子拒绝和普通委派证据；无新增UI测试/runner。存储/窗口注入故障、取消竞态及整体人工实现审查未执行；可丢弃Chats/草稿已清理，历史证据保留。

## 2026-10-05 — run_agent 主会话交接草案

- [run-agent-session-handoff](./changes/run-agent-session-handoff/index.md) 关联 TaskAdmin `master/79`；用户确认新增 `run_mode="handoff"`、仅明确要求时使用、分文件草稿消息交接和安全切换，并追加子会话必须明确报错且不得提升。
- 已发布 plan/TODO、proposal和 SubAgent/session-history两份 delta；任务 `pending`，规格 `draft`，行为验收 `not-run`。本次只写文档，未修改代码、Ability运行时指引或稳定规格，未触发实际交接。

## 2026-10-05 — Markdown LuaSnip 收敛

- `markdown-prompt-luasnip` accepted/retained，metadata/标量替换、可选完整 LSP 模板、四种位置与 Chat 交互/失败回滚合并到 `prompts/markdown-format.md`。TaskAdmin `master/78` 持有实际 Blink 接受、字段/镜像/变换/选项/字面数据、Select 发送、退出/重绘和普通目录保持的证据；human review not-run。临时 prompt/Chat 已清理。

## 2026-10-05 — Markdown LuaSnip 草案

- [markdown-prompt-luasnip](./changes/markdown-prompt-luasnip/proposal.md) 关联 `master/78`；用户确认显式 snip、完整 LSP/LuaSnip 原生交互和 user-only 边界，默认文本行为不变。

## 2026-10-04 — Chat-only Markdown 提示词收敛

- `chat-only-markdown-prompts` accepted/retained，最小 name/description/context/insert、四种位置、纯标量替换、Actions/API/配置退出和 Chat refresh 合并到 prompts/markdown-format.md、runtime/maxa-ai.md、runtime/plugin-entrypoints.md；chat-commands.md 与 commands.md 直接引用同步。
- TaskAdmin `master/76` 持有 parser/slash/setup 检查、28 个原名/原正文比较、用户完成重启后的实际 Blink 四种位置/光标/无自动提交、user/llm 历史与草稿、安全占位符及刷新证据。临时文件/Chat/全局状态已清理；human review not-run。其他并行 worktree 变更保留，未纳入本任务。

## 2026-10-04 — 子代理上下文显示收敛

- `subagent-context-indicator` accepted/retained；可选右侧 ToolView、事件驱动比例、原异步提交装饰例外合并到 runtime/chat-builtins.md 与 mcp/subagent-runtime.md。
- TaskAdmin `master/77` 持有既有 19/19 display、wait 检查、完整重启及真实 sync/async/member(7%/6%)、窄窗、wait timeout/terminal 清理和历史恢复证据；human review not-run。工具参数/结果与左侧提交语义未变。

## 2026-10-04 — 子代理上下文显示草案

- [subagent-context-indicator](./changes/subagent-context-indicator/index.md) 关联 `master/77`；用户确认 sync/async 统一右侧 `◔ N%`，包含原异步提交行；仅扩展显示装饰，保留 canonical 结果和 transient wait。

## 2026-10-04 — Chat-only Markdown 提示词草案

- 用户审查 28 个 active prompt 后批准：最小 YAML、inline/split/next_line/append、逐项位置设置、Actions/旧创建入口退出、同目录 Lua 展开删除而保留纯数据占位符。
- [chat-only-markdown-prompts](./changes/chat-only-markdown-prompts/index.md) 关联 `master/76`；必要的既有测试维护和临时真实交互输入已获授权，正文／deprecated history 不改。

## 2026-10-04 — 固定 slash 提示词来源收敛

- `fixed-slash-prompt-discovery` accepted/retained；固定普通/Ability 目录、Lua 回调保留名称、同级冲突跳过、项目缓存和声明式非激活发布合并到 runtime/chat-commands.md、runtime/plugin-entrypoints.md、skills/package-and-authoring.md、prompts/commands.md；markdown-format.md 清理已删除 builtin source trace。
- TaskAdmin `master/75` 持有 parser/slash/schema、完整重启、实际 Blink 菜单接受与文本插入、项目隔离、优先级、重名通知、prompts:false 与 disabled MCP 证据。用户授权的临时验证文件及 Chat 已清理；human review not-run。Standalone 未初始化 MCP 配置的 Ability 发现告警已明确记录，不影响已配置真实运行时验收。

## 2026-10-04 — 固定 slash 提示词来源草案

- 用户批准固定目录、Lua 回调保留名称、项目/全局普通及 Ability 提示词优先级、同级冲突跳过和现有禁用策略。
- [fixed-slash-prompt-discovery](./changes/fixed-slash-prompt-discovery/index.md) 关联 TaskAdmin `master/75`；proposal/deltas 为 draft，稳定规格尚未变更；实施与验证证据由任务 TODO 持有。

## 2026-10-04 — Browser 能力与 QA／E2E 演进收敛

- `evolve-browser-abilities` accepted/retained；统一 browser Ability/MCP 身份，独立 browser-dogfood/browser-e2e 与兼容 BrowserTest/TauriTest 生命周期收敛到 external-mcp/browser.md、skills/browser-dogfood.md、skills/browser-e2e.md；当前索引／直接调用方同步，历史记录保留。
- TaskAdmin `master/74` 持有 focused、实际生成 Runtime、完整 Neovim＋外部 MCPHub 重载、138-tool composite、新 workflow catalogs、真实 Chromium 页面点击/ref 刷新/截图、managed/external/partial-start cleanup、Tauri basic-interaction 4 项及应用信息 IPC 证据。额外 standard 远程预热超时、legacy Tauri bridge PID 输出限制保留；human/model-behavior review not-run。

## 2026-10-04 — Browser 能力与 QA／E2E 演进草案

- 用户在代码／稳定规格探索后批准：`tauri-playwright` Ability/MCP 更名为 `browser`；两个独立工作流演进为 `browser-dogfood`、`browser-e2e`，支持网站／CDP／Tauri 场景并保留 Tauri helper 接口。
- [evolve-browser-abilities](./changes/evolve-browser-abilities/index.md) 关联 TaskAdmin `master/74`；已发布 plan/TODO、proposal 和三个 delta，任务 pending、变更 draft。当前仅文档书写；未修改运行时代码、Ability 或稳定规格，未执行未来验收。

## 2026-10-04 — 统一 Session Ability 收敛

- unify-session-ability accepted/retained；同名 composite session 的指导、references、trace exporter 和 Native tools 单次加载收敛到 runtime/session-tools.md；compression 与 overview/project-vault 直接 source/caller 路由同步。
- TaskAdmin master/73 持有 catalog/loader、policy/hooks、exporter 5 项、0-error Ability lint、实际 Runtime 生成、完整 Neovim 重启和只读 list_chats 成功证据。未执行压缩或向用户数据导出 trace；private warning-state keys、disabled hooks、历史 generator/fixtures 保留。Human/model-behavior review not-run。

## 2026-10-04 — 统一 Session Ability 草案

- 用户要求按 SubAgent 同样规则直接重命名 session-admin 为同名 composite session，不保留旧入口；指导、references、trace exporter 和 Native tools 单次加载。
- [unify-session-ability](./changes/unify-session-ability/index.md) 关联 TaskAdmin master/73；保持压缩显式授权、single-use/destructive、disabled hooks 和脚本行为，不批量改写历史。

## 2026-10-04 — 统一 SubAgent Ability 收敛

- `unify-subagent-ability` accepted/retained；`subagent` 同名 composite 单次加载、task-specific 子代理上下文准备及三个示例增量合并到 `mcp/subagent-runtime.md`，直接 source/caller 引用同步；不保留旧别名、不改写历史。
- TaskAdmin `master/72` 持有 catalog/loader、0-error Ability lint、实际生成 Runtime 与真实 composite load 证据；完整 prompt 回归在无关旧 Soul 引用处失败，相关新 gate/table 通过直接 builder 验证。旧 loaded revision 造成的迁移阻塞已用 caller-only 现有清理 helper 处理；其它旧会话仍按迁移说明清理后加载新入口。Human/model-behavior review not-run。

## 2026-10-04 — 统一 SubAgent Ability 草案

- 用户批准 `subagent-admin` 直接重命名为同名 composite `subagent`，不保留旧入口；一次 load 提供指导、references 与 Native 工具。
- [unify-subagent-ability](./changes/unify-subagent-ability/index.md) 关联 TaskAdmin `master/72`；补充主代理 task-specific 上下文准备、root/reference 加载区别及 run/resume/shared 示例，不改变工具接口。

## 2026-10-04 — 通用子代理背景工具调用收敛

- `subagent-background-tool-calls` accepted/retained，真实注册工具串行预执行、成对消息与上下文提交、失败/取消停止及一次性共享副作用增量合并到 `mcp/subagent-runtime.md`。
- TaskAdmin `master/71` 持有 focused、完整 Neovim 重启、actual run/resume/multi_agent 与保存历史配对/一次性 edit 的证据；原有两个补充历史测试环境错误保留，未扩展修复。Human review not-run。

## 2026-10-04 — 通用子代理背景工具调用草案

- 用户批准 `messages` 的通用 `tool_call` + `name` + `args`，不限定 load、不是 slash command；真实调用由运行时执行并补全成对历史，多代理共享调用只执行一次。
- [subagent-background-tool-calls](./changes/subagent-background-tool-calls/index.md) 关联 TaskAdmin `master/71`；稳定 owner 在必要验证前保持不变，详细执行证据由任务持有。

## 2026-10-04 — 子代理目标与共享背景收敛

- `subagent-goal-context` accepted/retained；goal-last 用户消息、共享讨论背景/persistence、父会话 preset 解析以及用户追加批准的 handoff 计数/重试修复，增量合并到 `mcp/subagent-runtime.md`。
- TaskAdmin `master/70` 持有聚焦结构检查、Lua syntax/diff、两次完整 Neovim 重启、真实 run/resume、discussion final-run/final-fork 和实际历史顺序/私信隔离证据；单代理修复后一次 handoff、零错误。旧 resume registry 断言 6 项失败保留，未扩展修复；human review not-run。

## 2026-10-04 — 子代理目标与共享背景草案

- 用户批准 `goal_prompt` 立即必填、淘汰 `instructions` 系统注入，并统一讨论背景与 adapter preset 解析；[subagent-goal-context](./changes/subagent-goal-context/index.md) 关联 TaskAdmin `master/70`。
- 稳定 owner 暂不改；聚焦检查、完整重启和真实子代理证据由关联任务持有。

## 2026-10-04 — 内容发现对齐收敛

- `align-load-content-completion` accepted/retained；# 公开 Markdown、/load Native 文本资源及确认后的真实前置 Ability load，增量合并到 Maxa AI / Chat Commands。External、scripts、浏览副作用和实际授权规则保持。
- TaskAdmin `master/69` 持有现有 focused/syntax/diff、完整重启和 actual 未加载 Markdown 插入、Native Picker 浏览/确认、两组真实 load call/result、资源上下文及输入保留证据。临时 unsavable Chat 清理、caller UI 恢复；automated passed/human review not-run。无新增 tests/fixtures/mocks 或全套件。

## 2026-10-04 — 内容发现对齐草案

- 用户批准立即实施 # 公开 Markdown 与 /load Native 文本资源发现；[align-load-content-completion](./changes/align-load-content-completion/index.md) 关联 TaskAdmin `master/69`。浏览只读，确认资源选择才执行真实 Ability/resource load 队列。

## 2026-10-04 — Native MCP 补全收敛

- `native-mcp-completion` accepted/retained；Native concrete 工具/资源免 load 文本补全例外增量合并至 Maxa AI，调用/读取授权、External 和 package scripts/files 保持现状。
- TaskAdmin `master/68` 持有现有聚焦/syntax/diff、两次完整重启、actual Blink 菜单与选择、实际 Native disable-policy 过滤和 /load 后去重证据；修正观察到的 auto-paired `]` 重复插入。临时 Chat/策略与本地配置格式已清理，caller UI 和 misc disconnected 状态已恢复。
- automated passed/human review not-run；未新增或修改 UI tests/mocks/fixtures，未跑全套件。隐藏过滤由代码/既有发现规则核对，未另造隐藏 Ability；其他补全 provider 的行为通过共用目录与现有聚焦检查保留。

## 2026-10-04 — Native MCP 补全草案

- 用户批准 Native 工具/资源免 load 即可文本补全；External、package 文件/脚本、实际调用/读取授权保持不变。[native-mcp-completion](./changes/native-mcp-completion/index.md) 关联 TaskAdmin `master/68`。
- stable owner 未改；实现和实际 Chat 菜单证据由关联任务所有，不新增 UI 测试代码。

## 2026-10-04 — load slash command 收敛

- `chat-load-slash-command` accepted/retained；三条新增行为规则合并到 Chat Commands，保留既有 `/file`、`/pick_ability` 和 `load` schema/defaults。
- TaskAdmin `master/67` 持有加载检查、syntax/diff、两次完整重启、actual completion/Picker 多选、Skill/引用/资源、输入保留、取消/去重及实际 save/restore 证据。异步资源 callback 加入现有 cancel bridge 防止取消后迟到注入；实测中断在资源提交后、队列收尾前，未制造未返回回调的时延场景。
- automated passed/human review not-run；旧 insertion mock 缺 `write_text` 的失败保持任务记录，未改 tests/mocks 或新增 UI runner。临时验证 Chat/history 已清理，用户已有 `.maxa/plan.md` 修改保留。

## 2026-10-04 — load slash command 草案

- 用户在源码/规格探索后批准 `/load` 的最小范围：能力、公开 Markdown 引用及当前 Chat 已授权 MCP 文本资源，多选执行真实 load 并保留输入；[chat-load-slash-command](./changes/chat-load-slash-command/index.md) 关联 TaskAdmin `master/67`。
- 稳定规格未改；实施与实际 Picker/消息顺序/草稿交互证据由该任务所有，不新增 UI 测试框架。

## 2026-10-04 — multi_agent 运行时恢复收敛

- `restore-multi-agent-runtime` accepted/retained；注册/组合及三条接入规则增量合并至 SubAgent Runtime，Ability 中直接受影响的 dormant 说明同步；用户已有注册修改保留。
- TaskAdmin `master/66` 持有 token-decision/syntax/diff、两次完整重启、actual final run/fork、讨论局部工具/child 身份、私信目标隔离、最终 prompt/adapter 一致性和 caller 恢复证据。正常结束不再发取消错误通知。
- `soul_prompt_integration_spec.lua` 尝试失败在缺少当前 Chat 方法的旧 final mock；未改 tests/mocks，composition 由真实 Chat 验证。automated passed 指所选行为检查，human review not-run；无全套件、新 UI runner、取消/恢复架构扩展。

## 2026-10-04 — multi_agent 运行时恢复草案

- 用户在根因讨论后同意最小兼容性修复；`restore-multi-agent-runtime` draft 关联 TaskAdmin `master/66`，保留已有注册及独立 Tab，修复 Chat/adapter、局部 handoff 和最终执行。
- stable owner 未改；实际 run/fork 与 caller 恢复验证待执行，不新增 UI 测试框架或扩大其他 SubAgent 范围。

## 2026-10-03 — wait 临时呈现收敛

- `wait-transient-presentation` accepted/retained；覆盖 Chat Builtins active-wait 与 SubAgent 对应规则，wait 结束解绑并移除原工具呈现，不再保存/恢复 source 终态快照；canonical 结果/错误与 async 语义保持。
- TaskAdmin `master/65` 持有 display 19/19、async-result、syntax/diff、完整重启、actual pending/terminal/same-history 与用户报告旧 wait provenance 证据。用户引用的旧状态文本不删除；无新增 UI tests、全套件或 source 取消改造。

## 2026-10-03 — 主 Chat 侧边位置更正

- 用户澄清主 Chat 应使用右侧而非左侧；在同一 TaskAdmin `master/64` 内修正历史打开/已有窗口定位/关闭候选入口，子代理无头与浮窗逻辑不变。
- 三文件 syntax/diff 检查及完整重启后的 actual history visible-main reuse、hidden-main reopening 均为右侧；受影响 stable/delta/Ability reference 已同步。此前左侧观察保留为历史证据，不再代表当前行为。

## 2026-10-03 — 无头子代理与层级历史收敛

- `subagent-headless-session-tree` accepted/retained，新增身份/显示/历史规则及 ask_llm 退休规则已增量合并至 SubAgent Runtime 和 Session History；multi_agent 源码与独立 Tab 未改。
- TaskAdmin `master/64` 持有 focused helper/cancel/syntax、两次完整重启、actual run/fork/resume/nested child、无头与 float hide/cleanup、main-only cycling、tree/flat shortcut/search/navigation、main-left reopening 和 legacy dialogue fallback 保持证据。主会话完成代码，复用同一个只读 reviewer；依赖异步结果均无限等待。
- automated passed/human implementation review not-run；旧 index 未批量重建，未知旧记录独立可访问；其他 picker backend 未作完整交互矩阵，dormant multi_agent/Telegram 既有行为未另行实测。无新增 UI 测试框架、全项目套件或独立报告。

## 2026-10-03 — 无头子代理与层级历史草案

- 用户确认无头/浮窗执行、主侧边导航、树/平切换及 in-place 历史/执行身份分离；[subagent-headless-session-tree](./changes/subagent-headless-session-tree/index.md) 关联 TaskAdmin `master/64`。
- proposal/deltas draft，稳定 owner 未改；实施与实际交互验证由该任务记录，multi_agent 保持不变。

## 2026-10-03 — 子代理 ask 顶层透传收敛

- `relay-subagent-ask-to-root` accepted/retained，四条 Chat Builtins 与两条 SubAgent 执行身份规则已增量合并至稳定 owner；公开 ask/wait/SubAgent schemas/results 不变，Telegram service 未改。
- TaskAdmin `master/63` 持有既有 focused checks、full restart、actual同步root回复、async try隔离/timeout解绑/choice重挂、FIFO run/resume/fork、depth-2祖先门控及source入口回复证据。停止root Chat的检查中断Agent turn，原ask后来自身超时；已明确该既有stop边界，不重复扰动主会话。
- automated passed/human implementation review not-run；实际Telegram回复和unsent-draft交互未另行执行，限制保留任务记录。无新UI测试/runner、全套件、外部服务或独立报告。

## 2026-10-03 — 子代理 ask 顶层透传草案

- 用户批准保持原 child Chat/Telegram、first-valid arbitration、eligible-request FIFO 和 blocking wait-only async 入口；[relay-subagent-ask-to-root](./changes/relay-subagent-ask-to-root/index.md) 关联 TaskAdmin `master/63`。
- 当前 proposal/deltas draft；stable owner 未改，implementation/live validation 待执行。实际 source-only child ask 已观察，详细证据由任务记录；不新增 UI 测试或 Telegram 服务改造。

## 2026-10-03 — 完整代理显示与独立批次成员收敛

- `proxy-all-tool-presentations` accepted/retained；三个 MODIFIED 和三个 ADDED 批次规则、用户追加的纯title foldtext规则增量合并至 Chat Builtins，Native local `interactive` 投影隔离补充至 MCPHub owner；不修复无关旧 inventory/ask/call 文本。
- TaskAdmin `master/62`持有focused checks、full restart、实际typed成员+SubAgent同步运行/自然终态、async blocking wait完整挂载/解绑、交互预拒绝与parent input denial、历史exact owner/嵌套fold/canonical来源/空行证据；以前失败观察保留，最终fresh通过结果取代其未完成状态。用户要求删除额外勾选/空格和inlineicon已通过actualfoldtext/marks验证。
- `validation.automated: passed`、整体`human: not-run`；方案同意和图标请求非全实现人工审阅。任务metadata/done由main最终检查后处理；无新增UI测试/runner、全套件或独立报告。

## 2026-10-03 — 工具自有视图、SubAgent 详情与 active wait 收敛

- `unify-tool-presentation` 已 accepted/retained 并增量合并至 Chat Builtins、MCPHub、SubAgent 三个稳定 owner：ToolView/call-scoped UI、Native local callback/wire 隔离、最新 child 摘要、active blocking wait 的原视图/回答接续与 try 隔离。只替换五条原显示规则并加入本变更规则，不修复旧 inventory/ask 参数或旧 inherited-call 文本。
- TaskAdmin `master/61` 持有既有 focused checks、full restart、实际 ask/input/取消、direct/wrapped/batch/delete/answer folds、hidden child、serial sibling 路由、历史恢复/canonical 来源、TTL/Artifact 和 active wait 终态/超时/stop 解绑证据。stop 的 queued suppression 由既有 queue-guard 检查支持；没有将单 wait 实测冒称为含 queued 后继的实际场景。
- `validation.automated: passed`；整体 `human: not-run`，用户实际确认仅限 ask 视觉和 Ctrl+C 取消。旧 ask_test 删除前 `1 passed, 15 failed` 与子会话收到的用户删除授权保留在 TODO，不改写为父会话全实现验收。metadata/done 由主会话在检查收敛 diff 后处理；无新 report/UI suite。

## 2026-10-02 — builtin 工具自有展示方法实施与收敛

- `tool-owned-display` 五条 added rules 合并至 Chat Builtins；15 个 ordinary builtin 在 owning definition 提供 display 方法，公共 renderer 保留 UI/status/TTL；run/multirun 使用原始参数委托，兼容入口薄转发。保留 master/59 的 text/regex/all 与 glob patterns，不改变 schema、执行标题继承或历史消息。
- TaskAdmin `master/60` 持有 display 19/19、直接影响的 image-preparation 22/22、Lua syntax/scoped diff、full Neovim restart-resume、实际 direct/wrapped/batch 摘要以及 live/restored delete fold 原生展开/关闭证据。解决展示解析的 eager execution dependency；普通 delete 历史恢复统一到既有语义 fold owner。
- 主会话完成全部代码与验证；同一个只读子代理 baseline 后 resume diff 复核，未写代码。proposal/delta accepted/retained，human implementation review not-run，无新增 UI 测试代码或全项目套件。

## 2026-10-02 — Search text/regex 实施与规格收敛

- `search-text-regex` 已合并至 Chat Builtins：显式 `text`／`regex`、旧字段拒绝、所有 Neovim 搜索场景的 Rust regex、未知 workspace 候选覆盖及 queryless 位置查询；保留原扩展／输出／只读边界。
- TaskAdmin `master/59` 持有三项聚焦检查、full restart-resume、实际文件/LSP/位置调用与可见 Chat 单行摘要证据。正则进程参与现有 10 秒期限／取消／stale-source；proposal/delta accepted/retained，human implementation review not-run，无新增 UI 测试代码或全量套件。

## 2026-10-02 — builtin 工具自有展示方法草案

- 用户确认 15 个普通摘要 builtin 的 `display(args, ctx)` 迁移范围：工具自有摘要和 delete/multirun 语义折叠，公共 renderer 保留状态/TTL/UI 生命周期；ask、MCP/Ability protocol 与 legacy 清理不纳入。保留原始成员参数和最新无批次标题注入规则。
- [tool-owned-display](./changes/tool-owned-display/index.md) 发布 proposal/delta 与 TaskAdmin `master/60` plan/TODO，状态 pending，依赖 `master/59` 的 search 参数/摘要收敛。当前只完成文档，未修改实现或 stable owner；implementation automated/human not-run，未来最小验收以既有 focused check 和 actual fresh Chat 为准。

## 2026-10-02 — multirun 无标题成员展示修正收敛

- TaskAdmin `master/58` 最新修正已合并至 Title-owned execution display：仅显式成员标题参与 title display；省略/null 使用自身命令或目标工具参数摘要，执行层标题继承不变。前一版 inherited-display 契约由本次用户澄清取代。
- 删除 display-only title 注入，保留共享历史 fold 重建；既有 19 项 display 检查、scoped diff、full restart-resume 与实际 Chat live/restored 命令/read/search/显式标题观察通过。proposal/delta accepted/retained，human implementation review not-run，无新增测试或无关代码修改。

## 2026-10-02 — multirun 无标题成员展示修正草案

- 用户澄清执行层批次标题继承不得进入成员展示；省略/null 成员标题使用自身工具参数或命令摘要，显式标题保持 target/title。TaskAdmin `master/58` 复用，删除 display-only title 注入，保留 shared history fold 重建。
- 既有 19 项 display 检查与 scoped diff 通过；proposal/delta draft，重启后 actual Chat 验证与稳定 owner 收敛待执行。执行/schema/byte accounting 未改动。

## 2026-10-02 — Search text/regex 与 Neovim 扩展草案

- 用户确认删除 `patterns`／`literal`、文件与所有 Neovim 搜索场景支持统一 regex，以及位置查询省略筛选、删除星号哨兵；项目／语言正则仅过滤 LSP 返回候选，完整性未知。
- [search-text-regex](./changes/search-text-regex/index.md) 关联 TaskAdmin `master/59`；本轮仅发布可执行 plan/TODO、proposal/delta 与路由索引。任务 pending，规格 draft，implementation validation not-run；未修改运行时代码或稳定规格。

## 2026-10-02 — multirun 有效标题展示后续收敛

- TaskAdmin `master/58` 后续修正已合并至 Chat Builtins 的 Title-owned execution display：成员显式标题优先，省略/null 继承批次标题，通过普通 run formatter 展示；历史 batch fold 从 canonical call/result 重建，原始参数与字节统计不变。
- 既有 19 项 display 检查、history syntax/scoped diff 通过；用户手动重启后，实际可见 Chat 验证了 shell/builtin/Ability/extension 继承、显式标题优先及旧批次恢复。自动 restart-resume 因其他运行中 Chat 安全拒绝，未强制退出；proposal/delta accepted/retained，human implementation review not-run，无新增 UI 测试代码。

## 2026-10-02 — multirun 有效标题展示后续草案

- 用户批准省略/null 成员标题继承批次标题，显式标题优先，继续复用 run target formatter；原始参数与字节统计不改写。
- 复用 TaskAdmin `master/58`；共享 batch fold owner 从 canonical call/result 重建历史摘要，既有 19 项 display 检查与 history syntax/scoped diff 通过。actual fresh Chat 验证与 revised delta 收敛待执行，proposal/delta draft。

## 2026-10-02 — run 执行目标展示实施与收敛

- `show-run-execution-target` 合并至 Chat Builtins 两条 run display requirements；共享 formatter 有标题时保留 scope/command 身份，无标题与 multirun 外层不变。
- TaskAdmin `master/58` 持有既有 19 项 display 检查、scoped diff、full Neovim restart-resume、实际可见 Chat shell/win/builtin/Ability action/extension、历史恢复与显式/无标题 batch 成员证据。未新增 UI 测试代码，human implementation review not-run；proposal/delta accepted/retained。

## 2026-10-02 — run 执行目标展示草案

- 用户批准有标题时显示执行目标：shell/win 使用 scope，tool 使用完整 command，扩展使用 scope；无标题与 multirun 外层展示不变。
- [show-run-execution-target](./changes/show-run-execution-target/index.md) 关联 TaskAdmin `master/58`；仅修改共享 display 分支，保留 schema/dispatch/native results。proposal/delta draft，实际 Chat 验证与稳定 owner 收敛待执行。

## 2026-10-02 — 扁平 Ability 契约清理实施与收敛

- `flatten-ability-identities` 已合并到 package、lifecycle、AI completion、MCP identity 与 GenAI 五个稳定 owner；只保留扁平包名，恢复时忽略无效名称，删除失效图像工作流契约。
- TaskAdmin `master/57` 持有六项聚焦检查、full Neovim restart-resume、生成提示词、正常加载/非法名称拒绝、真实 Blink 菜单/插入/无隐式加载及受 Git 跟踪内容的清理验证。GenAI 媒体工具未改动，无付费调用；human implementation review not-run，proposal/deltas accepted/retained。

## 2026-10-02 — 扁平 Ability 契约清理草案

- 用户批准统一扁平包名、删除通用运行时旧分支及工作树相关说明，并清除已删除图像能力的失效规格引用；不保留兼容入口，不改写 Git/Chat history。
- [flatten-ability-identities](./changes/flatten-ability-identities/index.md) 关联 TaskAdmin `master/57`，范围为 package/runtime/GenAI 三份 delta 与直接相关文档；验证及稳定 owner 收敛尚未执行。

## 2026-10-02 — Ability 统一内容引用实施与收敛

- `unify-ability-content-references` 已合并至 Ability Package、Chat Builtins 和 MCPHub 稳定 owner：统一 `#ability[target]`，文件优先、仅真正缺失时回退已授权原始资源标识；包根权限错误不伪装成缺失，`@` 动作不变，旧引用语法不保留。
- TaskAdmin `master/56` 持有聚焦检查、一个文档子代理及同会话复核、full Neovim restart-resume、真实 Blink 菜单/插入/正文保护和 GVE `sb-gve` 加载/安全发现/原生 HTML 文本读取证据。无 UI 测试代码、第三方/业务配置修改或 MCP Apps 渲染；human implementation review not-run，proposal/deltas accepted/retained。

## 2026-10-02 — Ability 统一内容引用草案

- 用户选定 `#ability[target]`，不暴露来源类型、不加引号/别名；`/` 开头先查当前包文件，仅真正缺失时回退到该 Ability 已授权的原始资源标识；其他文件错误不回退。第三方标识原样保留，旧 `#` 语法不兼容。
- [unify-ability-content-references](./changes/unify-ability-content-references/index.md) 发布 proposal 与 Ability Package/Chat Builtins/MCPHub 三份 delta，关联 TaskAdmin `master/56` pending。本轮仅文档，源代码与稳定规格未修改；implementation automated/human not-run，实际补全与 Storybook 集成待任务执行验证。

## 2026-10-02 — Ability 文件引用实现与稳定规格收敛

- `decouple-ability-file-references` 合并至 `skills/package-and-authoring.md` 和 `runtime/chat-builtins.md`：共享目标路径解析不扫描整包，不依赖展示目录或 Chat revision；控制/runtime/排除文件可精确寻址，保留 owning-root confinement 和当前包覆盖。
- TaskAdmin `master/55` 持有聚焦检查、full Neovim restart-resume 和真实未加载文件 read/load/ready=false、原始 SYSTEM.md 读取、未加载动作/resource 拒绝证据。既有综合提示旧 `pty=true` 断言失败未扩大修复，受影响语义由 Soul 集成和生成提示检查覆盖；human not-run，proposal/deltas accepted/retained。

## 2026-10-02 — Ability 文件引用解耦草案

- [decouple-ability-file-references](./changes/decouple-ability-file-references/index.md) 分离物理文件寻址、资源展示和动作授权；`#` 文件允许精确访问控制/runtime 文件，无需已加载 revision，保留 owning-root confinement。
- TaskAdmin `master/55` 持有实施与最小验证；proposal/deltas draft，automated/human not-run，未覆盖稳定规格。

## 2026-10-02 — 无标题目标工具显示修正

- 用户要求无title的tool-mode run复用目标tool display，不再显示run·tool；共享display分发只复用旧call的目标formatter，有标题及非tool scope不变，batch成员自动使用同入口。
- TaskAdmin master/54后续修正已通过syntax/scoped diff、full restart及实际Chat展开read路径/search模式摘要与显式title观察，delta合并runtime/chat-builtins；human not-run，无新增UI测试或独立formatter。

## 2026-10-02 — 本地校验与可选参数收敛

- `local-tool-validation` 已增量合并至 runtime/chat-builtins 与 openai-responses-adapter：共享raw递归校验覆盖直接/member/decoded目标，builtin校验→prepare恰好一次→extension/handler；全部标准Responses function strict=false，source required/constraints保留，DeepSeek不发送不支持字段。
- multirun新label输入/成员结果移除，按输入顺序关联，成员复用普通run formatter；可选字段直接省略，不补null。TaskAdmin master/54持有local检查、full restart-resume及真实省略参数/目标类型拒绝/实际Chat成员显示证据；human implementation review not-run，无UI测试代码或全项目套件。
- proposal/deltas accepted/retained；第三方required契约不放宽，unsupported assertion/regex/ref明确拒绝，校验模块不宣称完整JSONSchema支持。

## 2026-10-02 — 统一执行实施与稳定规格收敛

- `unify-run-dispatch` 实施并增量合并至 runtime/chat-builtins、openai-responses-adapter、image-analysis：17个公开 builtin、run tool scope/必填title、multirun成员可选title/序列并行/单批次async推断，call/multicall及包装JSON注入退休；授权/进程/旧历史边界保留。
- TaskAdmin `master/53` 持有聚焦检查、full Neovim restart-resume、真实脚本/MCP/Shell/Windows、异步序列/取消及一次analyze的证据。实际恢复Chat可见标题与32个未改写的旧调用；human implementation review not-run。一个子会话只读定位后resume迁移活跃Ability/提示，主会话完成代码集成/验证；无UI测试代码、无全项目套件。
- proposal/deltas accepted/retained；先单独完成Ability load再使用目标，同批sequence不授权pending revision；原生无文件输入目标没有包装JSON注入替代。静默压缩未触发，避免把工具迁移变成未经授权的会话压缩。

## 2026-10-02 — 统一 run 分发与 multirun 调度草案

- 用户确认 scope=tool、移除包装 json_patches、独立必填 title/批次子项可选 title、parallel/sequence、外层 async 三态推断与单批次生命周期、禁止嵌套目标及旧名硬切换。
- [unify-run-dispatch](./changes/unify-run-dispatch/index.md) 发布 proposal 与 Chat Builtins/Responses/Image Analysis 三份 delta；关联 TaskAdmin `master/53` pending，无依赖/工作区绑定。本轮仅文档，未修改 runtime、共享提示/Ability 或稳定规格，implementation automated/human 均 not-run；具体实现路径和最小检查由任务 plan/TODO 持有。

## 2026-10-01 — Windows run 实施与稳定规格收敛

- `unify-run-windows` 已实现并合并至 `runtime/chat-builtins.md`：公开 builtin 18 个，winrun retired；Windows cmd/native argv、async/detach、cwd 和 service deadline/cancellation 使用单一 run 入口。TaskAdmin `master/52` 持有双仓库增量修改、子代理协作与详细验证证据。
- 定向 headless/metadata 检查、两次 fresh-Neovim 公开调用及真实 Windows argv/cwd/async/timeout/取消输出/脱离启动通过；Windows search/glob 消费方及生成路由保持可用。GUI 自动观察因现有 winctl-server 缺少 win32gui 受阻，用户确认记事本正确打开目标文件；随后仅关闭本次测试窗口。human passed 限于该 GUI 确认，不追溯改写为完整代码人工审阅。
- 既有无关 `pty=true` prompt 断言失败及 registry baseline drift 已记录，不扩大修复；proposal/delta accepted/retained，当前行为由 stable owner 持有。

## 2026-10-01 — Windows 执行并入 run 草案

- 用户确认 `run(scope="win")`：缺省 args 使用 Windows cmd.exe，数组 args 原生传输；opts 只保留 async/detach，GUI 用原生启动；移除公开 winrun，UNC 仅原生模式支持、cmd-string 显式拒绝。
- [[specs/changes/unify-run-windows/index|unify-run-windows]] proposal/delta 已发布为 draft，linked TaskAdmin `master/52` 为 pending；本轮仅授权文档，未修改 runtime/Windows bridge 或覆盖稳定 owner，implementation automated/human validation 均为 not-run。根因、现有双仓库修改保护和未来最小检查由 task plan/TODO 持有。

## 2026-10-01 — Scoped run 验证与规格收敛

- [[specs/changes/scoped-run-preparation/proposal|Scoped run preparation]] 的前置处理、公共参数/Shell 执行及摘要规则已合并至 [[specs/runtime/chat-builtins|Chat Builtins]]；accepted、automated passed、human not-run，原工作区保留。TaskAdmin `master/51` 持有定向检查、fresh-Neovim 实际直接/包装调用、strict schema 与可见 Chat 摘要证据。
- 未实现 DAP 消费方、scope registry 或其他 builtin 迁移；旧顶层 Shell options 保持 handler 兼容，具体扩展不进入 `run` 描述。

## 2026-10-01 — Scoped run 与 builtin preparation

- [[specs/changes/scoped-run-preparation/proposal|Scoped run preparation]] 关联 TaskAdmin `master/51`，定义可选前置处理、公共参数解码、Shell 双模式及旧 options 兼容；具体扩展消费方不进入 builtin 描述。定向检查已通过，fresh-runtime/实际摘要尚待验证；保持 draft，暂未覆盖稳定 owner。详细证据仅记入任务 TODO。

## 2026-10-01 — Neovim LSP 只读能力验收收敛

- [[specs/changes/neovim-lsp-readonly/proposal|Read-only Neovim LSP]] 已实现导航/引用、按 provider 归属的 hover、带 `current|stale|unknown` 的诊断和一层 incoming/outgoing 关系，合并至 [[specs/runtime/chat-builtins|Chat Builtins]]。接口库存/参数结构、符号和默认文件行为保持兼容；无源码写能力。
- 定向 consumer/read/dispatch/Ability 检查及 fresh-Neovim vtsls 实际请求通过；顺序 completion 和并发隐藏 buffer 生命周期问题已修复并验证，用户 buffer、源码和窗口保持不变。TaskAdmin `master/50` 持有详细证据；accepted、automated passed、human not-run，工作区原路径保留。空/无版本诊断仍为 unknown，不宣称项目无错误。

## 2026-09-30 — Neovim LSP 只读能力规格

- 先核对项目代码、稳定规格、知识索引与 Neovim LSP 接口，再与用户确认只读范围；[[specs/changes/neovim-lsp-readonly/proposal|Read-only Neovim LSP]] 定义导航/引用、Hover、文件及已知项目诊断、一层调入/调出关系，排除 Rename 和其他写能力。
- TaskAdmin `master/50` 关联完整 proposal/delta，状态 pending；规格 draft、runtime validation not-run。当前只发布文档并做结构/语义检查，未修改代码、实施能力或覆盖稳定规格；没有过渡阶段/兼容别名。

## 2026-09-30 — Neovim 多 LSP 符号能力筛选修正

- [[specs/changes/neovim-symbol-provider-filter/proposal|Symbol provider filter]] 修复 `tailwindcss` 阻止 `vtsls` 文件符号查询的问题：按请求方法筛选支持的 provider，跳过不支持者，无可用 provider 时才报错，输出只列实际查询来源。
- 聚焦混合/全部不支持的文件与工作区用例通过；实际 builtin 扩展对 `foundation.js` 返回 vtsls 符号。精确 consumer 规则已合并至 [[specs/runtime/chat-builtins|Chat Builtins]]；TaskAdmin `master/49` 持有证据，变更 accepted/automated passed/human not-run。早先“任意不支持即失败”记录保留为历史，不再作为现行行为。

## 2026-09-30 — Neovim 符号查询按需启动后续修正

- [[specs/changes/neovim-symbols-on-demand/proposal|On-demand Neovim symbols]] 已按用户确认的冒号 scope 规则实现项目、语言、相对/绝对文件查询，并在扩展内启动/复用已有配置的 LSP。只替换 [[specs/runtime/chat-builtins|Chat Builtins]] 的 consumer 规则，通用扩展框架未变；复用 TaskAdmin `master/49` 持有后续证据。
- 聚焦 consumer 检查、独立 Neovim 真实冷启动、实际语言/文件查询，以及 `dockerls` 不支持工作区符号时明确错误均通过。冷启动工作区结果为零只证明启动/协议请求成功，不证明索引完整；无需人工打开文件或显示窗口。变更 accepted、automated passed、human not-run，原路径保留。

## 2026-09-30 — Ability builtin 扩展验收收敛

- [[specs/changes/ability-builtin-extensions/proposal|Ability builtin extensions]] 已通过聚焦自动检查、fresh-Neovim 的实际 `load`/LSP 符号搜索及默认 ripgrep 搜索；两份 delta 合并至 [[specs/skills/package-and-authoring|Ability Package]] 和 [[specs/runtime/chat-builtins|Chat Builtins]]。TaskAdmin `master/49` 持有检查、位置抽查与重启证据。
- change 状态为 accepted、`validation.automated: passed`、`validation.human: not-run`，原路径逻辑归档保留。安装审查指导仅做静态核对，未执行第三方安装；现有稳定 owner 的人工验收字段保持历史基线含义，不冒充本次人工审核。

## 2026-09-30 — Ability builtin 扩展变更

- 新建 [[specs/changes/ability-builtin-extensions/proposal|Ability builtin extensions]]，由 TaskAdmin `master/49` 拥有实现与验证。权限声明、固定 Lua 入口、Chat 内 load 激活、脚本动态匹配及 Neovim LSP 示例进入两份 delta；验证完成前保持 draft，不覆盖稳定规格。

## 2026-09-30 — 15 个已人工审核变更提升与物理清理

- 用户明确声明当时全部 15 个 change 已通过人工审核，并另行确认 `telegram-notify-only-chat-input` 待验收的实际完成通知、空闲 TG 输入/即时回执、本地草稿保留与本地抢先 TG 提示均通过。此确认补齐 TaskAdmin `master/44` 的人工交互验收；其既有自动检查和重启证据保持原范围，不冒充本次重新执行的 UI 验证。
- 14 个 change 已有稳定合并；notify-only Telegram 后继变更的两份 delta 现合并至 [[specs/services/telegram-bridge|Telegram Bridge Service]] 和 [[specs/runtime/plugin-entrypoints|Runtime Plugin Entrypoints]]，替换旧绑定/排队/监听互斥行为，保留 exact identity、授权、ask 仲裁、非破坏性迁移与失败边界。Bridge owner 晋升为 `authority: normative`、`status: active`。
- 批量清理任务 `master/48` 拥有入口/引用核对与用户授权的物理删除；原任务继续拥有行为实现证据，`master/44` 在正式合并后完成。没有建立重复归档、重跑历史测试或删除 Telegram 话题/消息。

| Change ID | 正式 owner（相对 `specs/`） | 原 TaskAdmin |
| --- | --- | --- |
| `remove-visible-chat-context` | `runtime/chat-commands.md` | `master/31` |
| `ask-unbound-session-topics` | `services/telegram-bridge.md`；旧绑定路由由 notify-only 后继规则替换 | `master/33` |
| `route-completion-notify-to-session-topic` | `services/telegram-bridge.md`、`runtime/plugin-entrypoints.md`；绑定互斥由后继规则替换 | `master/34` |
| `defer-rewind-history-save` | `runtime/chat-commands.md`；manual-user `gr` 语义由后继规则替换 | `master/35` |
| `add-chat-search-glob-tools` | `runtime/chat-builtins.md`；旧 `cancel`/参数形态由后继规则替换 | `master/36` |
| `search-glob-tool-display` | `runtime/chat-builtins.md` | `master/37` |
| `search-glob-parameter-variants` | `runtime/chat-builtins.md` | `master/39` |
| `rename-chat-cancel-to-kill` | `runtime/chat-builtins.md`、`runtime/image-analysis.md` | `master/40` |
| `add-kill-tool-display-title` | `runtime/chat-builtins.md` | `master/41` |
| `bounded-read-cursor` | `runtime/chat-builtins.md` | `master/42` |
| `cursor-rewind-user-edit` | `runtime/chat-commands.md` | `master/43` |
| `telegram-notify-only-chat-input` | `services/telegram-bridge.md`、`runtime/plugin-entrypoints.md` | `master/44` |
| `simplify-chat-builtin-results` | `runtime/chat-builtins.md` | `master/45` |
| `recover-background-chat-folds` | `runtime/chat-builtins.md` | `master/46` |
| `taskadmin-current-tag-boundary` | `taskadmin/core.md` | `master/47` |

- `.maxa/specs/changes/` 全目录按用户要求物理删除；规范入口只路由正式 owner。下方既有日志和原任务中的 proposal/delta 路径保留为事件发生时的历史身份，不是有效文件入口；通过对应 Git history、上表与原任务证据恢复，不要求重建目录。
- 先前其他范围的 `failed`、`not-run`、`partial` 保持原记录；本次人工审核不扩大其自动或 live 覆盖范围。清理的聚焦规则/关联/引用和 diff 检查由 `master/48` TODO 持有。

## 2026-09-30 — TaskAdmin 当前 tag 边界收敛
- [[specs/changes/taskadmin-current-tag-boundary/proposal|taskadmin-current-tag-boundary]] 经独立 owning-uv 隔离环境中的 28 项 TaskAdmin 用例、Ability 重载、受影响 CLI 帮助和包级 lint，通过并合并至 [[specs/taskadmin/core|TaskAdmin 核心]]；TaskAdmin `master/47` 持有具体证据及原有 pytest 环境故障记录。人工实施审核未运行；外部环境正确性和直接文件写入拦截不在本次保证范围内。

## 2026-09-30 — TaskAdmin 当前 tag 边界草案
- [[specs/changes/taskadmin-current-tag-boundary/proposal|taskadmin-current-tag-boundary]] 关联 TaskAdmin `master/47`；普通任务写入和执行限定当前 tag，保留跨 tag 查询、显式管理与迁移，移除外部环境依赖；任务标题继续允许重复，稳定规格待聚焦验证后收敛。

## 2026-09-30 — 后台 Chat 工具折叠恢复收敛
- [[specs/changes/recover-background-chat-folds/proposal|recover-background-chat-folds]] 经重启后的真实隐藏完成、跨 Tab、不抢焦点、展开/关闭、原生 buffer/分屏关联和历史恢复观察及现有聚焦检查通过，合并到 [[specs/runtime/chat-builtins|Chat Builtins]]；TaskAdmin `master/46` 持有详细证据，人工审核未运行。

## 2026-09-30 — 后台 Chat 工具折叠恢复草案
- [[specs/changes/recover-background-chat-folds/proposal|recover-background-chat-folds]] 关联 TaskAdmin `master/46`；以原生窗口事件恢复后台生成的工具折叠，保留工具接口和历史格式，稳定规格待实际交互验证后收敛。

## 2026-09-30 — Chat 内置工具结果精简收敛
- [[specs/changes/simplify-chat-builtin-results/proposal|simplify-chat-builtin-results]] 经聚焦 Neovim 检查与重启后直接/包装调用核验，增量合并到 [[specs/runtime/chat-builtins|Chat Builtins]]；TaskAdmin `master/45` 持有具体验证及前后输出对照，人工审核未运行。

## 2026-09-30 — Chat 内置工具结果精简草案
- [[specs/changes/simplify-chat-builtin-results/proposal|simplify-chat-builtin-results]] 关联 TaskAdmin `master/45`；拟精简命令、Lua、嵌套调用溢出与文件操作工具的 Agent 可见结果，保留错误状态、部分删除身份和日志可取回性。

## 2026-09-29 — 光标回退用户消息收敛
- [[specs/changes/cursor-rewind-user-edit/proposal|cursor-rewind-user-edit]] 经 Neovim 重启后的隔离 Chat 实际 `gr` 交互（用户消息、非用户消息、取消）与聚焦 Lua 检查通过，合并到 [[specs/runtime/chat-commands|Chat commands]]；TaskAdmin `master/43` 记录具体验证，人工审核未运行。

## 2026-09-29 — 光标回退用户消息草案
- [[specs/changes/cursor-rewind-user-edit/proposal|cursor-rewind-user-edit]] 关联 TaskAdmin `master/43`；拟让 `gr` 对人工用户消息复用 `/rewind` 编辑语义，非人工消息与 `@ask` 工具结果保留原有行为。

## 2026-09-29 — Chat read 有界续读收敛
- [[specs/changes/bounded-read-cursor/proposal|bounded-read-cursor]] 的聚焦 Neovim 检查、重启后的工具注册、直接与包装调用已通过；增量合并到 [[specs/runtime/chat-builtins|Chat Builtins]]，TaskAdmin `master/42` 保存详细证据，人工审核未运行。

## 2026-09-29 — Chat read 有界续读草案
- [[specs/changes/bounded-read-cursor/proposal|bounded-read-cursor]] 与增量关联 TaskAdmin `master/42`；20k 有界响应、所有策略 cursor、临时策略不允许正数 `end_line`，实施和验证待进行。

## 2026-09-29 — kill 展示标题收敛
- [[specs/changes/add-kill-tool-display-title/proposal|add-kill-tool-display-title]] 经新 Neovim 中的直接/包装 `kill` 调用、缺失/空白标题拒绝与 Chat 展示观察，合并到 [[specs/runtime/chat-builtins|Chat Builtins]]；历史无标题调用仍显示为 `kill`，具体证据见 TaskAdmin `master/41`。

## 2026-09-29 — Chat 异步取消工具更名收敛
- [[specs/changes/rename-chat-cancel-to-kill/proposal|rename-chat-cancel-to-kill]] 经清单、恢复与异步取消聚焦检查，以及重启后的直接/嵌套 `kill` 调用核验，合并到 [[specs/runtime/chat-builtins|Chat Builtins]]；图像分析包装器引用已同步，TaskAdmin `master/40` 持有具体验证结果。旧 `cancel` 不保留别名。

## 2026-09-29 — search/glob 参数多形态收敛
- [[specs/changes/search-glob-parameter-variants/proposal|search-glob-parameter-variants]] 经聚焦 Lua 检查、新 Neovim 中的实际 `search`/`glob` 调用、Responses strict schema 核对及 Chat 显示观察，合并到 [[specs/runtime/chat-builtins|Chat Builtins]]；TaskAdmin `master/39` 持有具体检查与既有通配符差异记录。

## 2026-09-28 — 完成通知会话话题路由收敛
- [[specs/changes/route-completion-notify-to-session-topic/proposal|route-completion-notify-to-session-topic]] 经新 Neovim 中的真实 Chat 监听回调、Bridge notify HTTP 200、未绑定 ask-only 话题状态核对及用户群组话题目视确认，合并到 [[specs/services/telegram-bridge|Telegram Bridge Service]] 与 [[specs/runtime/plugin-entrypoints|Runtime Plugin Entrypoints]]；TaskAdmin `master/34` 持有具体检查与旧 Lua 测试失败记录。

## 2026-09-28 — 完成通知会话话题路由草案
- [[specs/changes/route-completion-notify-to-session-topic/proposal|route-completion-notify-to-session-topic]] 关联 TaskAdmin `master/34`，拟让完成监听通过精确 Chat 身份复用 ask-only 群组话题；保持监听与绑定互斥、前台抑制及无身份时不私聊。实施与验证待进行。

## 2026-09-28 — 未绑定 Chat 的 ask 群组话题收敛
- [[specs/changes/ask-unbound-session-topics/proposal|ask-unbound-session-topics]] 经聚焦 Bridge/Lua 检查、服务和 Neovim 重启、真实 `ask` notify 投递及未绑定/ask-only 持久状态核对，合并到 [[specs/services/telegram-bridge|Telegram Bridge Service]]；TaskAdmin `master/33` 持有具体证据，Telegram 客户端人工查看未运行。

## 2026-09-28 — 未绑定 Chat 的 ask 群组话题草案
- [[specs/changes/ask-unbound-session-topics/proposal|ask-unbound-session-topics]] 与 Telegram Bridge 增量关联 TaskAdmin `master/33`；用户确认 ask 不再在缺少身份或话题失败时转发私聊，持续完成通知仍走原有私聊路径。实施与验证待完成。

## 2026-09-27 — 移除 Chat 可编辑 Context 清单收敛
- [[specs/changes/remove-visible-chat-context/proposal|remove-visible-chat-context]] 经真实 Chat 重启恢复观察、规则消息/17 工具注册核对、聚焦 Lua 检查合并到 [[specs/runtime/chat-commands|Chat commands]]；TaskAdmin `master/31` 持有证据。Telegram 旧测试仍断言已退休的可见块，故该旧断言失败；新输入区的 Telegram 草稿观察无 Context 块，人工审核未运行。

## 2026-09-27 — 移除 Chat 可编辑 Context 清单草案
- [[specs/changes/remove-visible-chat-context/proposal|remove-visible-chat-context]] 和 `chat-input-context` 增量关联 TaskAdmin `master/31`；内部规则消息、默认工具 schema 与附件元数据保持，实施与验证待进行。
## 2026-09-25 — 固定项目规则与 Soul 切换收敛
- [[specs/changes/fixed-project-rules-and-chat-souls/proposal|fixed-project-rules-and-chat-souls]] 经聚焦检查与真实 Chat `/souls` 交互、提交验证，四份增量已合并到 [[specs/runtime/maxa-ai|Maxa AI]]、[[specs/runtime/plugin-entrypoints|Plugin entrypoints]]、[[specs/runtime/chat-commands|Chat commands]]、[[specs/mcp/subagent-runtime|SubAgent runtime]]；TaskAdmin `master/29` 持有检查证据，人工审核未运行。

## 2026-09-25 — 固定项目规则与 Soul 切换草案
- [[specs/changes/fixed-project-rules-and-chat-souls/proposal|fixed-project-rules-and-chat-souls]] 与四份 delta 已关联 TaskAdmin `master/29`；用户确认同时移除 SubAgent 任意 Rules 输入。仅发布待实施文档，代码、运行时验证与稳定规格收敛尚未开始。

## 2026-09-25 — Lazy opts 与命名 preset 收敛
- [[specs/changes/lazy-opts-named-presets/proposal|lazy-opts-named-presets]] 经聚焦检查和 fresh Neovim 恢复验证，增量已合并到 [[specs/runtime/plugin-entrypoints|Plugin entrypoints]]；TaskAdmin `master/28` 记录证据，未发起付费标题请求或人工验收。

## 2026-09-25 — Lazy opts 与命名 preset 草案
- [[specs/changes/lazy-opts-named-presets/proposal|lazy-opts-named-presets]] 与 runtime 增量已关联 TaskAdmin `master/28`，提出单一最终配置源和按名称解析；尚未实施、验证或合并稳定规格。

## 2026-09-25 — Provider 所属代理收敛
- [[specs/changes/provider-scoped-proxy/proposal|provider-scoped-proxy]] 通过聚焦 Lua 检查和完整 Neovim 重启后的代理/服务注册检查，三份增量已合并到 [[specs/runtime/plugin-entrypoints|Plugin entrypoints]]、[[specs/runtime/maxa-ai|Maxa AI]] 和 [[specs/genai/native-mcp|GenAI Native MCP]]；TaskAdmin `master/27` 记录实际验证，未发起付费上游请求或人工实施验收。

## 2026-09-25 — Provider 所属代理草案
- [[specs/changes/provider-scoped-proxy/proposal|provider-scoped-proxy]] 与三份增量规格关联 TaskAdmin `master/27`，提出仅从 provider 声明服务、保留当前有效代理配置，并按每次请求解析动态代理；仅完成文档，未实施、未验证、未合并稳定规格。

## 2026-09-24 — MCPHub 内建启动收敛
- [[specs/changes/integrate-mcphub-into-maxa-ai/proposal|MCPHub 内建启动]] 已通过聚焦检查及完整 Neovim 重启后的管理/Native Ability 调用，合并至 [[specs/mcp/mcphub-runtime|MCPHub runtime]]、[[specs/runtime/maxa-ai|Maxa AI]]、[[specs/runtime/plugin-entrypoints|Plugin entrypoints]]；TaskAdmin `master/24` 记录验证，人工运行时验收未运行。
## 2026-09-24 — MCPHub 内建启动草案
- [[specs/changes/integrate-mcphub-into-maxa-ai/proposal|MCPHub 内建启动]] 及三份增量规格已拟定，TaskAdmin `master/24` 排队；尚未实施/验证，稳定规格不变。

## 2026-09-24 — Provider model recovery accepted

- [[specs/changes/provider-model-recovery/proposal|Provider model recovery]] merged into [[specs/runtime/plugin-entrypoints|Runtime plugin entrypoints]] after focused tests and fresh-Neovim adapter resolution. TaskAdmin `master/23` owns results; real upstream model support remains unverified.

## 2026-09-24 — Provider model recovery drafted

- [[specs/changes/provider-model-recovery/proposal|Provider model recovery]] updates discovery and grouped billing semantics under TaskAdmin `master/23`; stable merge awaits fresh-process verification.

## 2026-09-24 — Provider-owned adapter configuration accepted

- [[specs/changes/provider-owned-adapters/proposal|Provider-owned adapter change]] passed focused Lua checks and fresh-Neovim provider/GenAI registration inspection; deltas merged into [[specs/runtime/plugin-entrypoints|Runtime plugin entrypoints]] and [[specs/genai/native-mcp|GenAI Native MCP]]. TaskAdmin `master/22` owns the check results. No live external API call was used as acceptance evidence.

## 2026-09-24 — Provider-owned adapter configuration draft

- [[specs/changes/provider-owned-adapters/proposal|Provider-owned adapter proposal]] and its runtime/GenAI deltas record provider-owned, adapter-facing target configuration with user-declared static model fallback and code-owned protocol extensions. TaskAdmin `master/22` owns future execution; implementation and stable-spec convergence have not run.

## 2026-09-23 — Background preset default accepted

- [[specs/changes/background-preset-default/proposal|Background preset delta]] merged into [[specs/runtime/plugin-entrypoints|runtime entrypoints]] after focused Lua validation and a fresh Neovim check of `my_oai` / `gpt-6-sol` / `temperature=0.0`. TaskAdmin `master/20` owns the implementation and validation evidence; human review remains `not-run`.

## 2026-09-23 — Maxa Lua configuration implemented and merged

- Linked [[specs/changes/unify-ai-lua-config/proposal|change]] passed focused preset/SubAgent/GenAI/lifecycle and upload Lua/Node validation; fresh Neovim restart loaded the updated MCP `run_agent` schema without a fixed preset enum. Accepted deltas merged into [[specs/runtime/plugin-entrypoints|runtime entrypoints]], [[specs/runtime/chat-commands|chat commands]], [[specs/genai/native-mcp|GenAI]] and [[specs/mcp/subagent-runtime|SubAgent]]; TaskAdmin `master/19` owns detailed evidence. Human implementation review remains `not-run`.

## 2026-09-23 — Maxa Lua configuration change drafted

- Documented [[specs/changes/unify-ai-lua-config/proposal|single Lua defaults owner, deployment overrides, extensible preset semantics and loopback upload]] with linked runtime and upload deltas under TaskAdmin `master/19`. The current stable specs remain authoritative until implementation validation and convergence; human validation is `not-run`.

## 2026-09-23 — Git Workspace model context implemented and accepted

- Implemented [[specs/changes/expose-git-workspace-model-context/proposal|path-addressed Git Workspace model context]]: schema-v1 configs may declare explicit `main|child` identity/responsibility, detection adds only exact matches, and generated prompts render XML-safe context only for a matched current project path.
- The generated system-prompt contract passed; the isolated Git Workspace suite passed 14 tests; Ability lint completed with zero errors and two unrelated existing routing warnings; `git diff --check` passed.
- Accepted deltas merged into [[specs/skills/git-workspace|Git Workspace Workflow]] and [[specs/runtime/plugin-entrypoints|Runtime Plugin Entrypoints]]. TaskAdmin `master/17` owns detailed evidence; human implementation review remains `not-run`.

## 2026-09-23 — Git Workspace model context change drafted

- Documented [[specs/changes/expose-git-workspace-model-context/proposal|the draft Git Workspace model-context change]] and its `git-workspace-mode` / `runtime-system-prompt` deltas under TaskAdmin `master/17`.
- The user-approved behavior identifies the current workspace only by an exact normalized absolute-path match in the current checkout's `.maxa/workspaces.yml`; matched `main`/`child` definitions expose name and responsibility, while every other state emits no workspace tag.
- Publication is documentation only: implementation, automated validation, stable-spec merge and human acceptance remain `not-run`.

## 2026-09-22 — Ability catalog default filtering implemented and accepted

- Implemented [[specs/changes/ability-catalog-default-filtering/proposal|centralized Ability catalog filtering]] with strict `ABILITY.yaml.include`, explicit precedence, default-hidden exact reads and unchanged executor authority.
- Public reference audit decreased from 258 to 218; focused catalog/load/session/completion/prompt checks and a fresh configured Neovim catalog check passed. Full live MCPHub integration was unavailable with `MCPHub instance unavailable` and is non-gating for this non-transport change.
- Accepted delta merged into [[specs/skills/package-and-authoring|the stable Ability package owner]]; TaskAdmin `master/15` records detailed implementation and validation evidence. Human implementation review remains `not-run`.

## 2026-09-22 — Ability catalog default filtering drafted

- Documented [[specs/changes/ability-catalog-default-filtering/proposal|the draft Ability catalog filtering change]] and its `ability-package` delta under TaskAdmin `master/15`.
- The agreed behavior hides default-filtered ordinary package files from catalog disclosure and completion while preserving root-confined exact reads; strict `ABILITY.yaml.include` promotes intentional exceptions without granting execution.
- Publication is documentation only: implementation, automated validation and stable-spec merge remain `not-run`.

## 2026-09-22 — MCP-backed Ability discovery implemented and validated

- Implemented [[specs/changes/unify-mcp-ability-discovery/index|metadata-driven Ability disclosure]] and removed the entire static MCP section plus MCPHub host mention from `prompts/system.md`. The Ability-owned pre-load fragment preserves exact-Chat authorization and administrator prohibition; Soul was unchanged.
- Six focused headless checks passed. Ability lint reported zero errors and two unrelated existing routing warnings. Fresh-Neovim checks confirmed four configured full rows, hidden disabled entries, retained composite visibility, one source-access fragment with either Soul, and no connection/configuration changes during generation.
- TaskAdmin `master/12` records detailed evidence and is ready for review. Its draft remains unmerged pending the predecessor `master/9` stable convergence; no human implementation acceptance or model-routing benchmark is claimed.

## 2026-09-22 — MCP-backed Ability discovery follow-up documented

- User approved unified Ability disclosure with config `description`, optional `triggers`, safe self-description fallback and administrator-disabled MCP-only entries hidden; additionally required the entire `MCP-backed Abilities` section and other MCP-specific text to leave authored `prompts/system.md`.
- Created [[specs/changes/unify-mcp-ability-discovery/index|the draft change workspace]] and linked TaskAdmin `master/12` with executable plan/TODO. Necessary pre-load authorization constraints remain assigned to an Ability-owned fragment; generated Ability context may still describe MCP sources.
- Publication is documentation only: implementation, fresh-runtime checks and stable-spec acceptance have not run. Existing catalog/visibility baseline checks passed during exploration; they do not validate the proposed behavior. No runtime/prompt/config source was changed by this publication.

## 2026-09-22 — Default engineering preferences assigned to Soul

- Following a full Runtime prompt reread and user approval, moved compatibility/incremental-change preference, minimum-sufficient implementation method and regression-test selection strategy into default Soul. Shared-contract/portability constraints, safety, scope and mandatory validation/evidence remain common Runtime.
- Updated the owning delta and TaskAdmin `master/11` map/TODO. Default/custom ownership regression, current-composer checks and original-content conservation passed; no runtime code or additional child session was needed.
- Original body coverage remains complete, now compared through 159 clause checks after splitting the mixed public-contract paragraph; all nine fragments are unchanged. Combined source is 19,370 bytes and fixed-catalog generated output is 41,165 bytes, only two bytes above the preceding reviewed version. Final acceptance remains pending.

## 2026-09-22 — Chat heading format assigned to common Runtime

- User review clarified that the H1/H2 prohibition and H3 starting level are Maxa Chat presentation requirements for every Soul. Moved the existing rule verbatim from default Soul to Runtime's Shared Response Contract.
- Updated the owning system-prompt delta and TaskAdmin `master/11` content map/TODO. Default/custom-Soul regression and current-composer checks passed; all 155 original body units and nine fragment hashes remain preserved.
- The move adds only one separating newline: source total 19,368 bytes; fixed-catalog generated prompt 41,163 bytes. No Lua/MCP changes or historical prompt rewriting were introduced; final acceptance remains pending.

## 2026-09-22 — Soul / Runtime implementation validated, awaiting acceptance

- Implemented [[specs/changes/split-system-prompt-soul-runtime/index|split-system-prompt-soul-runtime]] in the main session with one reused read-only reviewer. Common Runtime, selected Soul, `soul_*` inputs, project Soul, child/final-run composition and default/current dump now follow the deltas; dormant tools remain unregistered.
- Conserved 155 original body text units and all nine Ability fragment hashes. Main-source total changed 18,751 → 19,367 bytes; fixed-catalog generated output 40,539 → 41,162 bytes (+623, approximately 1.54%). Agency asset examples/methods/preferences are unchanged.
- Focused prompt/catalog/parameter/inheritance/integration/plugin checks, syntax and Ability lint passed. Full Neovim restart exposed the new live schema; one read-only temporary custom-Soul smoke and actual current-Chat dump checks passed.
- The existing resume suite retains seven identical baseline failures, separately documented in TaskAdmin `master/11`; they are not claimed as passing or repaired outside this change.
- Proposed `validation.automated` is `passed` for the changed scope, `validation.human` remains `not-run`. Task is ready for review; change remains draft and stable owners are not merged before final acceptance.

## 2026-09-22 — Soul / Runtime split draft published

- Added [[specs/changes/split-system-prompt-soul-runtime/index|split-system-prompt-soul-runtime]] after scoped source/Vault/spec exploration and explicit user confirmation; linked TaskAdmin `master/11` owns the implementation plan, TODO and original-content partition map.
- Two deltas define mandatory common Runtime, replaceable default/project/custom Soul, hard-renamed `soul_*` parameters, instructions-only composition, new-format fork/resume, and default/current Chat prompt inspection. Whole-system project overrides and old parameter aliases have no compatibility path.
- Preserved Agency case studies, examples, methods and tool preferences; only incompatible tool protocols and compulsory source condensation/example-dropping instructions are targeted. Existing dormant multi-agent sources are aligned without re-enabling registration.
- Default-prompt conservation is a hard requirement: complete clauses, exceptions and fragment content, with controlled source/generated UTF-8 byte comparisons and no arbitrary threshold or unexplained material drift.
- This operation writes documentation only. Runtime/prompt/Ability sources and stable specs are unchanged; implementation and final human behavior validation remain `not-run`. Document-only checks are recorded in the linked TODO, not relabeled as implementation acceptance.

## 2026-09-21 — Ability feasibility findings incorporated into the draft

- Revised [[specs/changes/unify-ability-runtime/index|unify-ability-runtime]] after the user authorized the evidence-backed review corrections; reused TaskAdmin `master/9` rather than creating another implementation owner.
- Clarified strict YAML errors/escaping, explicit field inheritance/replacement/clearing, file shadowing without fallback, external-process versus current-Neovim execution, closed MCP address grammar, Chat-owned revision atomicity and latest complete catalog-bearing result retention.
- Preserved MCPHub's Chat-independent transport ownership; added external resource-catalog preflight and explicit new/legacy history recovery policy without rewriting transcripts or reviving retired identities. Same-name `genai` dependency migration now uses composition, not a self-edge.
- Updated the proposal, four owning deltas, change index, linked plan/TODO and migration guide; the Project Vault delta's existing behavior is retained. Added the session-history stable owner to the declared future convergence scope.
- This is documentation-only draft repair. Runtime and stable specs remain unchanged; new-runtime automated/human validation stays `not-run`. Scoped document-check results and the earlier runtime-baseline probes are recorded separately in the linked TODO, not promoted to behavior acceptance.

## 2026-09-21 — Unified Ability runtime specification published

- Added draft [[specs/changes/unify-ability-runtime/index|unify-ability-runtime]] after scoped Vault/spec/source exploration, Agent Skills primary-spec verification, executable YAML/token feasibility probes and explicit user confirmation.
- Target behavior is one breaking Ability surface: standard Agent Skill packages plus optional `ABILITY.yaml`, MCP-backed or explicitly composite Abilities, Ability-only dependencies, one `load` builtin, mechanical `@ability:target` / `#ability:target` addressing, regex executor rules and compact complete tool catalogs.
- Added five deltas for Ability runtime, Chat builtins, MCPHub runtime, AbilityHook lifecycle and Project Vault ownership. The Agent migration guide is linked from TaskAdmin `master/9`.
- Current work is documentation-only. Runtime source and stable specs are unchanged; implementation, automated runtime validation and final human specification/behavior validation remain `not-run`. The user's explicit confirmation owns the recorded design decisions and authorized publication, not final lifecycle acceptance.

## 2026-09-20 — Project-safe MCP access/input mentions accepted and converged

- User explicitly accepted [[specs/changes/simplify-mcp-access-and-input-mentions/proposal|simplify-mcp-access-and-input-mentions]] after implementation、focused/fresh/live validation and behavior clarification。Proposal plus five deltas are `status: accepted`，automated/human validation `passed` and `archive_state: retained`；linked TaskAdmin task: `master/3`。
- Merged the accepted contract into [[specs/mcp/mcphub-runtime|MCPHub Runtime]]、[[specs/runtime/chat-builtins|Chat Builtins]]、[[specs/runtime/maxa-ai|Maxa AI]]、[[specs/runtime/plugin-entrypoints|Runtime Plugin Entrypoints]] and [[specs/runtime/session-history|Session History]]。
- Stable behavior now has one process-global MCPHub UI Hub plus explicit-cwd project-keyed Chat transport；`load_server` owns provenance-bound exact-Chat authorization/catalogs，`call`/`multicall` own authorized namespaced dispatch，and `@/#` remain side-effect-free literal completion。No dynamic MCP registration bridge、submit-time marker parser、resource/prompt/slash injection or compatibility path remains。
- Final evidence includes project transport/authorization/completion and adjacent regression suites、independent repair/re-review `PASS`、two fresh restart-resume cycles、live authorized/unauthorized/restored calls、completion-catalog smoke、raw-config data-minimization inspection and scoped/full diff checks。

## 2026-09-20 — Project-safe MCP access/input mentions implemented and automated validation passed

- Implemented draft [[specs/changes/simplify-mcp-access-and-input-mentions/proposal|simplify-mcp-access-and-input-mentions]]: removed the Maxa MCP registration bridge and submit-time marker runtime，retained exactly 19 Chat builtins，and added explicit-cwd project-keyed MCP transport with workspace-provenance authorization、catalog-based unique namespaced dispatch and atomic load-context persistence。
- Added one shared literal mention catalog across default/cmp/blink/coc/native completion。Configured Server names are read-only exact-project facts；loaded tools/resources require provenance-valid `load_server` authorization；Skill visibility/resource exclusion remains shared with `load_skill`。
- Focused automation passed for workspace port/identity/lease lifecycle、dead-PID/recycled-port isolation、remote `server_url`、disabled capabilities、waiter failures、authorization/provenance/transfer/restore、resource-only load、ambiguous names、literal submission and provider parity。A durable implementation session and one reused review/repair session were used；final review returned `PASS`。
- Two full Neovim restart-resume cycles passed。Fresh runtime reported MCPHub `setup_state=completed`、Hub ready、exactly 19 builtins and no loaded bridge；live `misc__echo` passed before and after restore，unauthorized `time__get_current_time` failed with `load_server` guidance，and completion exposed `@misc`/`@misc__echo` but not unloaded `@time__get_current_time`。Provenance/catalog output contained no raw Server config/env values。
- Change remains `status: draft` with `validation.automated: passed` / `validation.human: not-run` pending user acceptance and stable-owner merge。Linked TaskAdmin task: `master/3`。

## 2026-09-20 — MCP access/input mention change gained project-safe routing

- Revised draft [[specs/changes/simplify-mcp-access-and-input-mentions/proposal|simplify-mcp-access-and-input-mentions]] after exact-caller context、MCPHub Lua state/workspace routing、pinned backend capability behavior、history autosave ordering and namespaced parser ambiguity were inspected.
- The target now keeps the process-global MCPHub UI Hub while adding explicit-cwd project-keyed Chat transport、workspace provenance on `mcp:server:*` authorization、catalog-based unique `<server>__<tool>` resolution、cross-project transfer reauthorization and atomic authorization/catalog flush before autosave.
- Executable design evidence passed：two simultaneous workspace backend processes exposed the same Server name but returned distinct tool/resource results，and global→project same-name config override matched the backend. Resource/tool catalogs are now explicitly MCPHub-currently-reported metadata；the change does not claim backend pagination/error provenance or fork pinned `mcp-hub@4.2.1`.
- Linked TaskAdmin task: `master/3`. Runtime code and stable specs remain unchanged；implementation validation is `not-run` pending separate authorization.

## 2026-09-18 — Token 阈值用户收尾指令已实现并收敛

- Accepted retained change [[specs/changes/accept-token-threshold-user-instructions/proposal|accept-token-threshold-user-instructions]] and merged its ordinary-Chat threshold behavior into [[specs/runtime/lifecycle-and-message-injection|Runtime Lifecycle And Message Injection]]。
- Runtime now exposes `尽快收尾` → `token 超限了，需要尽快收尾`，accepts any other nonblank Telegram/same-Chat text as the exact next user instruction after safe stop，and preserves legacy `continue`、`interrupt`、failure/rearm behavior and strict final SubAgent `interrupt|compact` routing。
- Automated validation passed：`chat_token_threshold_decision_test.lua`（17 tests）、`chat_token_threshold_integration_test.lua`（8 checks）and scoped `git diff --check`。The user confirmed the target behavior and authorized implementation；linked TaskAdmin task：`master/4`。

## 2026-09-18 — Token 阈值用户收尾指令变更已起草

- Added draft change [[specs/changes/accept-token-threshold-user-instructions/proposal|accept-token-threshold-user-instructions]] after ordinary threshold lifecycle、generic ask coordinator、focused tests、stable owner and accepted historical changes were explored and the user confirmed the behavior.
- Target ordinary Telegram choice is `尽快收尾` → `token 超限了，需要尽快收尾`；any other nonblank Telegram or same-Chat text becomes the exact next user instruction after the existing safe-stop boundary。`interrupt`、legacy exact `continue`、failure handling、rearm and SubAgent `8 + 3` / final `interrupt|compact` behavior remain bounded as specified.
- Linked TaskAdmin task: `master/4`。Runtime code and stable specs are unchanged；implementation validation is `not-run`.

## 2026-09-18 — Persistent Chat completion notification accepted and converged

- Accepted retained change [[specs/changes/persist-chat-completion-notifications/proposal|persist-chat-completion-notifications]] and merged persistent lifetime、current-tab Buffer observation、tmux client/window gating、cancel deduplication、stale callback invalidation、lualine and binding boundaries into [[specs/runtime/plugin-entrypoints|Runtime Plugin Entrypoints]] and [[specs/services/telegram-bridge|Telegram Bridge Service]]。
- Automated validation passed：focused listener/status/binding suite、affected Lua syntax、stale wording scan、`git diff --check`、full Neovim restart-resume、fresh runtime toggle/lualine smoke and live tmux pane/client-window signal match。
- Human validation passed：the user enabled listening、closed the tmux client and confirmed the owner-private Telegram completion notification arrived。Workspace lifecycle is `status: accepted`，automated/human validation `passed`，`archive_state: retained`；linked TaskAdmin task：`master/2`。

## 2026-09-18 — Persistent Chat completion notification implemented

- Implemented [[specs/changes/persist-chat-completion-notifications/proposal|persist-chat-completion-notifications]] in the Chat-local listener owner with asynchronous tmux window/client observation、current-tab Buffer visibility、activation-generation stale callback guards and cancelled-turn deduplication。Listener state remains runtime-only and private/unbound Telegram delivery and binding exclusion are unchanged。
- Updated local/remote Telegram attach-block wording and extended the existing focused regression for consecutive turns、foreground/background、unfocused split、hidden tabpage、tmux shown/hidden/failure、cancel+completed deduplication、manual disable and Chat close。
- Automated validation passed：affected Lua syntax、`nvim --headless -u NONE -l tests/util_maxa_ai_notify_telegram_state_spec.lua`、stale one-shot wording scan and `git diff --check`。Change remains `status: draft` / `validation.human: not-run` pending Neovim reload and manual behavior acceptance；stable owners remain unchanged。
- Linked TaskAdmin task: `master/2`。

## 2026-09-18 — Persistent Chat completion notification specified

- Added draft change [[specs/changes/persist-chat-completion-notifications/proposal|persist-chat-completion-notifications]] after listener、lualine、Chat lifecycle、Telegram binding、focused tests、stable specs、retained accepted evidence and tmux signal exploration plus explicit user agreement.
- Target behavior keeps one runtime-only Chat-local listener active until manual disable or Chat close。A Buffer shown in any window of the current tabpage counts as foreground；outside tmux that suppresses Telegram directly，while tmux additionally requires a connected client displaying the Neovim pane's exact window。Unproven observation sends conservatively。
- `Chat:stop()` ends only the current turn and does not disable listening；the cancel plus stopped/error completion sequence must produce at most one notification decision。Existing owner-private/unbound delivery、binding exclusion、icons and no-history-persistence behavior remain unchanged。
- Linked TaskAdmin task: `master/2`。Runtime code and stable specs are unchanged；baseline `nvim --headless -u NONE -l tests/util_maxa_ai_notify_telegram_state_spec.lua` passed，implementation validation remains `not-run`。

## 2026-09-17 — Workflow support retired and converged

- Accepted retained change [[specs/changes/remove-workflow-support/proposal|remove-workflow-support]] and merged its deltas into the SubAgent、Prompt Library、skill routing and session-history stable owners.
- Deleted SubAgent `run_workflow`、Prompt Library staged Workflow runtime/prompts、Workflow-only Chat subscribers and the complete `workflow-nexus` package；ordinary command prompts and remaining SubAgent tools stay active.
- Validation passed：focused Lua tests、active-reference/artifact checks、strict skill lint（35 skills，0 errors/warnings）、generated system prompt contract、module load、static inventory and fresh Neovim `subagent` inventory（`run_agent`、`fork_agent`、`resume_agent`、`handoff`）。Linked TaskAdmin task：`master/1`。

## 2026-09-17 — Workflow support retirement specified

- Added draft change [[specs/changes/remove-workflow-support/proposal|remove-workflow-support]] after runtime、skill、prompt-library、test and stable-spec exploration plus explicit user selection of full removal.
- Target behavior hard-removes SubAgent `run_workflow`、Prompt Library staged Workflow support and `workflow-nexus` without compatibility shims；ordinary command prompts、remaining SubAgent tools、generic process terminology and historical evidence stay in scope of their current owners.
- Linked TaskAdmin task: `master/1`. Runtime code and stable specs are unchanged；automated validation is `not-run` until implementation.

## 2026-09-17 — TaskAdmin workspace and SpecAdmin ownership refactor implemented

- Implemented [[specs/changes/refactor-taskadmin-workspace-and-specadmin-ownership/proposal|refactor-taskadmin-workspace-and-specadmin-ownership]] through TaskAdmin Python core、Task Browser、Git Workspace binding、TaskAdmin/SpecAdmin Skills、active prompts、stable specs and active knowledge routes。
- Hard reset completed：`.maxa/tasks/` now contains only empty `master` state/tag metadata；all tracked old task hierarchy and TaskAdmin `.maxa/handoff/` data were deleted without migration or compatibility readers。
- Validation passed：TaskAdmin 14、Task Browser 15、Git Workspace 10、`load_skill` 12、skill utils 6、visibility index、generated prompt contract、strict Skill lint、Python/Lua syntax、retired/stale scans、Vault title checks、scoped diff check and fresh configured Neovim `TASK_BROWSER_RUNTIME_OK`。
- One durable SubAgent audit session was reused for readiness、implementation review and repair review；tag traversal、ID `>=1000`、move rollback and lifecycle findings were repaired。Interactive Browser visual validation and final human acceptance remain `not-run`；change stays `status: draft` / `archive_state: pending-review`。

## 2026-09-17 — TaskAdmin workspace and SpecAdmin ownership refactor specified

- Added draft change [[specs/changes/refactor-taskadmin-workspace-and-specadmin-ownership/proposal|refactor-taskadmin-workspace-and-specadmin-ownership]] after TaskAdmin/SpecAdmin Skill、runtime、Browser、Git Workspace、prompt、task-data、knowledge and stable-spec exploration plus explicit user agreement.
- Target TaskAdmin is a single-level task workspace with integer IDs、`_meta.yaml`、`plan.md`、`todo.md` and optional linked documents；all parent/subtask、legacy migration、TaskAdmin-specific SubAgent/fork/handoff behavior and existing task data are removed without compatibility.
- Target SpecAdmin depends on TaskAdmin and owns proposal/delta/stable-spec/lifecycle only；implementation plans、TODO and detailed validation move to exactly one linked TaskAdmin task. Read-only spec analysis does not create tasks.
- This change retains `design.md` and `tasks.md` as the one bootstrap exception because the target TaskAdmin foundation does not yet exist. Runtime code、skills、stable specs and task data are unchanged；automated validation is not run.

## 2026-09-16 — MCPHub Marketplace removed and project config localized

- Removed Marketplace UI/state/API、remote Registry initialization and cache behavior while retaining local server configuration、lifecycle、OAuth、Workspace、SSE and capability proxying。
- Default project MCP configuration moved from `.mcphub/servers.json` to `.maxa/mcp.json`；`.vscode/mcp.json` and `.cursor/mcp.json` remain compatible，and `/mcp.json` is now a shared Syncthing exclusion。
- Exact `mcp-hub@4.2.1` remains pinned and receives a deterministic post-install patch instead of a full backend fork。Focused tests、fresh Neovim、explicit backend restart、Marketplace `404` and live Native MCP dispatch passed。

## 2026-09-16 — Token threshold routing by session type accepted

- Accepted [[specs/changes/route-token-threshold-by-session-type/proposal|route-token-threshold-by-session-type]] and merged it into [[specs/runtime/lifecycle-and-message-injection|Runtime Lifecycle 与 Message Injection 行为规格]]。
- Ordinary Chat now waits indefinitely for `continue|interrupt` without a model-visible warning or finish budget。SubAgent automatically uses 8 finish requests，then hidden `Token 已耗尽，请立即收尾。` with 3 internal requests；remaining/new tools are cancelled with paired results，then `interrupt|compact` waits 300 seconds and defaults to interrupt。
- Validation passed：threshold decision 15/15、real Chat/HTTP integration 8/8、orchestrator queue/tool cancellation 11/11、SubAgent completion guard、multi-agent terminal routing and retry recovery。No live provider or destructive Telegram transport test was run。
- Workspace lifecycle is `status: accepted`，automated/human validation `passed`，`archive_state: retained`。

## 2026-09-16 — Programmatic approval, edit review, and built-in Neovim MCP removal converged

- User-directed runtime behavior removes Chat/MCPHub tool approval caches、permission prompts、auto-approval config/UI/events/caller flags；builtin `ask` remains the explicit Human Assist channel，and destructive Hub-management confirmations remain scoped to user-invoked UI actions。
- Removed edit tracking、accept/reject/revert UI、Super Diff、Diff providers/config/keymaps and `mini.diff` dependency。Validated Chat file tools continue applying their effects directly and return ordinary bounded results。
- Removed the complete built-in `lua/mcphub/native/neovim/**` tool/resource/prompt server and its committed configuration；core retains the `mcphub` management Native server and composition retains five `lua/util/mcphub/**` capability servers。
- Converged [[specs/runtime/maxa-ai|Maxa AI]]、[[specs/runtime/plugin-entrypoints|Runtime Plugin Entrypoints]]、[[specs/runtime/overview|Runtime Overview]]、[[specs/mcp/mcphub-runtime|MCPHub Runtime]] and [[specs/mcp/mcp-creator-workflow|MCP Creator Workflow]]。Current first-party Chat inventory is exactly 19；the MCPHub source boundary is exactly 53 Lua files。
- Validation passed：focused Chat/MCPHub suites、Lua/JSON/static checks、Skill lint、help tags、two full restart-resume cycles、fresh runtime state (`setup_state=completed`, connected, no Neovim server/approval fields) and live `misc__echo` without a permission prompt。No separate change workspace was created because the already user-directed and validated implementation was converged directly into active stable owners。

## 2026-09-16 — invalid_call hard removal accepted and merged

- Implemented and accepted [[specs/changes/remove-invalid-call-tool/proposal|remove-invalid-call-tool]]: `invalid_call` is absent from the exact 19-tool inventory, default schemas, direct/nested resolver surface, Responses strict-schema exceptions, output policy and compact executor; restored registries remove its stale identity without rewriting messages.
- Chat-owned validation now preserves adapter-produced canonical calls, returns paired `rejected_before_execution` results for replayable failures, uses Anthropic `is_error=true`, and appends hidden model-visible corrections for unreplayable calls. Resolver errors and mixed batches continue in canonical order through one completion boundary.
- Diagnostic evidence preserves decodable structure with 250-character scalar excerpts and a 1000-character total snapshot; undecodable input shares the total budget across parse reason/count/raw prefix/marker, and RFC 3629-invalid bytes become bounded ASCII diagnostics. Full rejected payloads do not re-enter `ToolCallError` or `ToolCallsCompleted`.
- OpenAI Responses streamed/non-streamed partial function calls now reach Chat validation instead of being dropped or converted directly to terminal request errors; incomplete calls never execute target handlers.
- Focused validator/history/orchestrator/lifecycle/adapter/inventory/registry/schema/display/compact/setup regressions passed; the reused SubAgent reviewer returned final `PASS`. Fresh Neovim restart-resume confirmed 19 live tools, no restored `invalid_call` schema/in-use state, and unchanged runtime rejection classification. No paid/live provider request was run.
- Merged accepted behavior into [[specs/runtime/chat-builtins|Chat Builtins]] and [[specs/runtime/openai-responses-adapter|OpenAI Responses Adapter]]; workspace lifecycle is `status: accepted`, automated/human validation `passed`, `archive_state: retained`.

## 2026-09-16 — invalid_call hard-removal specification

- Added draft change workspace [[specs/changes/remove-invalid-call-tool/proposal|remove-invalid-call-tool]] after builtin/runtime/adapter/stable-spec exploration, official OpenAI/Anthropic/Gemini protocol review, and explicit user agreement.
- Final proposed contract removes `invalid_call` from schemas, inventory, resolver, nested dispatch and compact/Responses special cases. Replayable validation failures keep the original call identity/provider metadata and receive a direct `rejected_before_execution` result; structurally unreplayable calls become hidden model-visible corrections without a fake tool.
- Parameter evidence preserves decodable structure while limiting each scalar excerpt to 250 Unicode characters and the complete parameter snapshot to 1000 Unicode characters; undecodable input uses a bounded raw prefix, parse reason and received length. Full large arguments are not re-injected.
- Restore/resume/fork/compression reconciliation removes stored `invalid_call` schemas without rewriting messages. The user explicitly chose complete schema removal over old-session provider cache continuity and accepts a possible first-request cache miss.
- Delivery is specification-only: proposal, design, implementation checklist and `chat-tool-call-validation` delta exist; runtime code and stable specifications are unchanged, automated/human implementation validation remain `not-run`.

## 2026-09-15 — Human Assist to builtin ask accepted and merged

- User explicitly approved final human review and requested committing all changes. `migrate-human-assist-to-ask` is `status: accepted` with automated/human validation `passed` and `archive_state: retained`.
- Merged accepted behavior into Chat builtins, lifecycle/message injection, runtime overview, plugin entrypoint, Maxa AI and Telegram Bridge stable owners；changes/index now reports no active change.
- Canonical inventory is exactly 20 bare Chat builtins with `ask` at position 2. `ask` owns `notify|input|choice`, Chat/TG first-response-wins, raw Chat input, plain-text results, assistant/user render-only display, per-Chat isolation and batch-safe cancellation.
- Removed the complete `skills/human-assist/` package and all active Skill/script callers. Token threshold decisions use the shared ask coordinator；one-shot completion notification uses the Lua Bridge client.
- Validation passed: ask 16 + real Builder buffer、display 10、tool batch 4、threshold 21 + integration 8、soft-stop 7、Telegram Bridge 92、inventory/registry/prompt/history/Skill lint、fresh restart-resume and `git diff --check`.
- Live checks passed Chat+Telegram notify、Telegram-button choice and Chat-text input. Telegram-unavailable → Chat fallback passed focused automation but was not run as a destructive live transport test；the user explicitly accepted this residual risk.

## 2026-09-15 — Draft Human Assist to builtin ask change

- Created active change workspace [[specs/changes/migrate-human-assist-to-ask/proposal|migrate-human-assist-to-ask]] with proposal, technical design, implementation checklist, and `chat-ask` delta spec; no runtime implementation or stable-spec merge was performed.
- User-confirmed contract: Telegram button results use stable `value`; choice accepts arbitrary Telegram text; Telegram transport failure leaves Chat input available; notify succeeds when Chat display succeeds even if Telegram delivery fails.
- Proposed boundary: exactly 20 canonical Chat builtins including `ask`; Telegram-capable `notify|input|choice` schema without `allow_free_text`; Chat/TG first-response-wins; plain-text result contract; assistant/user visual styles without forged transcript roles; hard removal of `skills/human-assist` after active callers migrate.
- Validation state remains `automated: not-run`, `human: not-run` for implementation behavior. The change remains `status: draft` and stable specs remain authoritative.

## 2026-09-15 — Final stable-spec promotion and permanent change-workspace deletion

- Independent reviewer result: `PASS，可执行永久删除`.
- Permanently deleted all 42 reviewed change workspaces: 249 Markdown files totaling 1,694,548 bytes. No `archive/` and no workspace copy was created; proposal/design/tasks/delta/validation history remains recoverable only through Git history.
- Stable current behavior is routed through 13 coarse modules. Stable-owner coverage was verified for every final non-superseded delta before deletion; superseded behavior was not reintroduced.
- Human specification review for all 42 workspaces is `passed` by explicit user declaration. Existing automated/live/platform/visual/environment results remain exactly `passed`, `partial`, `failed`, or `not-run` in their stable owners; no unrun or failed check was relabeled as passed.
- [[specs/changes/index|Spec Changes]] is retained only as the future active-change entrypoint and reports no active changes. [[specs/index|Stable Specifications]] records the completed promotion and permanent-deletion lifecycle boundary.

## 2026-09-15 — report/search_skill hard removal and final-text analysis convergence
- Accepted and retained `remove-report-and-search-skill` (Git history only) after user-confirmed contract decisions, implementation/spec convergence, focused and extended automation, strict skill lint, active-source absence scans, and fresh configured Neovim validation.
- Current public inventory is exactly 19 bare Chat builtins. Both removed names have no schema, resolver, nested-call translation, output policy, capture path, or dedicated display behavior; restored runtime registries delete their stale identities without rewriting saved messages.
- `analyze` now completes from the current tool-free nonempty child assistant text. Regular requests remain capped by `max_steps`; the first tool-free empty response receives exactly one correction for a total of at most `max_steps + 1`; a second empty response fails `FINAL_RESPONSE_REQUIRED`.
- Generated skill metadata now appends exact `visibility=search` `skill_name` identifiers and excludes hidden skills. Explicitly requested indexed identifiers load directly with `load_skill`; fuzzy skill search is removed.
- Updated current builtin, file/command, routing, skill-package, runtime, AI-runtime, plugin-entrypoint, and image-analysis specs. The former report-tool change is `superseded`; the older image-analysis draft now routes completion ownership to the accepted final-text change. No compatibility layer was added.
- Validation passed: inventory/schema/restore/nested-call checks; image-analysis 16 + controller 14 + real Chat integration 1; prompt/index generation; `load_skill` 12/12; skill utilities 6/6; strict lint over 37 skills; runtime/setup/SubAgent regressions; Lua parse; fresh configured 19-tool inventory; scoped `git diff --check`.

## 2026-09-15 — OpenAI Responses protocol ownership specification
- Added and accepted `consolidate-openai-responses-protocol` (Git history only) after source/spec exploration, official OpenAI and DeepSeek documentation review, implementation, independent review/repair verification, and explicit human acceptance through the current session's human-assist choice.
- Created stable owner [[specs/runtime/openai-responses-adapter|OpenAI Responses 标准 Adapter 与 DeepSeek 显式扩展规格]] and updated adjacent stable runtime, plugin-entrypoint, lifecycle/message-injection, and session/history/UI specs only at their direct ownership boundaries.
- `lua/maxa/ai/adapters/http/openai_responses.lua` is the sole official protocol owner; documented DeepSeek stateless/plaintext-reasoning/request/tool differences apply only through explicit `openai_responses_extensions/deepseek.extend(base_factory)` composition. No provider switch, registry, middleware framework, automatic discovery, transition layer, historical message repair, or DeepSeek strict-equivalence claim was introduced.
- Validation passed: focused adapter/decorator/recovery and adjacent regressions, independent repair probes, Lua/static owner checks, scoped diff checks, and fresh full-configuration headless Neovim handler/schema inspection.
- Live validation passed for configured `my_oai` / `gpt-6-astra` standard Responses function-call continuation and `deepseek` / `deepseek-v4-pro` plaintext-reasoning function-call continuation. The standard smoke was not direct `api.openai.com`; no secrets or request payloads were recorded.
- Stable merge and lifecycle convergence completed: change artifacts are `status: accepted`, `accepted_at: 2026-09-15`, validation passed, `merged_to` names the five stable specs, and `archive_state: retained` keeps the workspace logically archived in place.

## 2026-09-15 — Maxa Chat builtin short-name acceptance and convergence
- Accepted and retained `rename-chat-builtins-to-short-names` (Git history only) after implementation/spec convergence, focused automation, reused SubAgent review/re-review, full Neovim restart-resume, live direct/nested/async/cancel/image/MCP smoke, persisted-registry reconciliation checks, and explicit human acceptance.
- Exact replacements: `read_file`→`read`, `write_file`→`write`, `edit_file`→`edit`, `move_item`→`move`, `delete_items`→`delete`, `cancel_async_task`→`cancel`, `get_async_result`→`wait`, `keep_tool_result`→`keep`, `execute_lua`→`lua`, `fire_event`→`fire`, `analyze_image`→`analyze`, `execute_command`→`execute`, `call_tool`→`call`, and `call_tools_parallel`→`multicall`.
- Boundary: no aliases, transition, fallback, or old-name translation; the other 7 public names and all tool semantics remain unchanged; private Lua filenames/helpers may retain old words. Restore/compression/resume reconcile only runtime registries—removing exactly the 14 retired names, installing all current builtins, preserving unknown/custom/namespaced tools—and do not rewrite saved files or stored messages.

## 2026-09-14 — Maxa Chat builtin tool acceptance and convergence
- Accepted and retained `promote-mcpx-to-chat-builtins` (Git history only) after exact 21-tool inventory/default registration, focused migration regressions, independent final re-review `Pass`, three full Neovim restart-resume passes, final live direct/nested/image/cancellation smoke, scoped artifact checks, and explicit human acceptance.
- Merged accepted behavior into [[specs/runtime/chat-builtins|Maxa Chat 内建工具层行为规格]], [[specs/runtime/chat-builtins|Maxa Chat 文件、命令与事件内建工具规格]], and affected runtime, MCPHub, entrypoint, hook, routing, Skill, SubAgent, session, prompt, GenAI, and Native shared specs.
- Current public contract: exactly 21 always-available bare Chat builtins; no legacy 11-tool set, first-party Native tool server/group/prefix, aliases, or history rewrites. `call_tool` and `call_tools_parallel` dispatch bare builtins or namespaced MCP targets; remaining Native servers are `genai`, `json_artifact`, `misc`, `session`, and `subagent`.
- Full `git diff --check` remains affected only by pre-existing/user-owned trailing whitespace in `.maxa/plan.md`; the scoped check excluding that file passed.

## 2026-09-14 — Maxa AI capability cleanup convergence
- Converged [[specs/runtime/maxa-ai|Maxa AI 内建运行时规格]] with the user-confirmed hard cleanup: `:Maxa` now owns Chat; only `:Maxa`, `:MaxaActions`, and `:MaxaHistory` remain; ACP, independent Inline, Cmd, listed unused HTTP presets, Jina/Tavily integrations and Copilot-only behavior are removed without aliases or transition stages.
- Retained HTTP ownership covers `anthropic`, `openai`, `gemini`, shared HTTP infrastructure, `openai_compatible` / `openai_responses`, configured protocol-based gateways, Chat inline diff/Super Diff, Actions, History, session and MCPHub. `.github/copilot-instructions.md` rule discovery remains intentionally unrelated to the removed adapter.
- Automated convergence evidence: 308 active AI Lua files parsed; runtime smoke, setup atomic, adapter/default-adapter, Responses, lifecycle, session/history and error-classification tests passed; active-source absence scans and `git diff --check` passed. The frozen cleanup TODO records exact commands and outcomes.
- Accepted historical evidence under `specs/changes/internalize-maxa-ai-runtime/**` remains unchanged.

## 2026-09-13 — MCPHub internal runtime acceptance and convergence
- Accepted and retained `internalize-mcphub-runtime` (Git history only) after implementation/spec reconciliation, 12 focused headless test groups, independent final re-review `Pass`, full Neovim restart-resume, `:MCPHub` UI smoke, six Native servers, loaded Maxa AI bridge, live `session__*` calls, and explicit human-assist acceptance.
- Created [[specs/mcp/mcphub-runtime|MCPHub 内建运行时规格]] and merged accepted deltas into [[specs/runtime/overview|Maxa Runtime 总体行为规格]], [[specs/runtime/plugin-entrypoints|Runtime Plugin Entrypoints 行为规格]], [[specs/runtime/maxa-ai|Maxa AI 内建运行时规格]], and [[specs/mcp/mcp-creator-workflow|MCP Creator Workflow 行为草案规格]].
- Canonical ownership is repository `lua/mcphub/**` at locked baseline `7cd5db330f41b7bae02b2d6202218a061c3ebc1f`; `maxa.ai.integrations.mcphub` remains the sole AI bridge, while npm `mcp-hub@4.2.1` remains an exact project-local external dependency. No transition/compatibility layer, backend source fork, upstream-sync subsystem, or unrelated redesign was introduced.
- All 16 change artifacts now record `status: accepted`, `accepted_at: 2026-09-13`, automated/human validation passed, exact stable `merged_to` targets, and `archive_state: retained`.

## 2026-09-13 — Maxa AI stable specification human promotion
- Explicit human review promoted the eight stable Maxa AI/runtime/session specifications to the consistent reviewed state `authority: accepted`, `status: active`; the already accepted `internalize-maxa-ai-runtime` change lifecycle remains unchanged.

## 2026-09-13 — Maxa AI internal runtime acceptance and stable-spec convergence
- Accepted and retained `internalize-maxa-ai-runtime` (Git history only) after implementation/spec reconciliation, focused automation, independent re-review, full Neovim restart-resume, live Native `session` invocation, required UI entrypoints, and a real provider response returning exactly `MAXA_AI_STREAM_OK`.
- Created [[specs/runtime/maxa-ai|Maxa AI 内建运行时规格]], merged accepted deltas into the overall runtime, plugin entrypoint, lifecycle/message injection, compression and Chat slash-command specs, and renamed the stable history/query capabilities to [[specs/runtime/session-history|Maxa AI 会话历史与 UI 规格]] and [[specs/runtime/session-tools|Session 查询与探测工具规格]].
- Canonical stable operational ownership is `lua/maxa/ai/**` plus the thin `lua/util/mcphub/session/init.lua` adapter; public identities are `maxa.ai.*`, `MaxaAI*`, `maxa_ai`, `session`, and `session__*`, with no compatibility aliases or metadata translation.
- File-side convergence validation covers lifecycle/frontmatter consistency, wikilink resolution, absent renamed stable paths, existing source paths, canonical stable operational scans, title/frontmatter lint, document-size policy, and `git diff --check`. Live Obsidian graph validation was not performed.

## 2026-09-13 — GDA runtime API and fixed offline docs specification
- Added `add-gda-api-and-offline-docs` (Git history only) after local GDA/Blender interface, stable-spec and official Godot source exploration plus explicit user confirmation.
- The complete target uses the selected engine's `--dump-extension-api` for project-independent public runtime metadata and `docs get/search/read` over the full pinned English Godot 4.7 RST corpus at `godot-docs` commit `4b404adc7c3a4eb7b5392bed8833cdc52f164338`.
- Explicit exclusions: project `class_name`/plugins/GDExtensions, translations, API invocation, online fallback/update, persistent cache, compatibility/transition aliases, general native-flag passthrough and unrelated test/framework work.
- Proposal, design, focused implementation checklist, delta and recursive indexes are draft. `add-gda-api-and-offline-docs` (Git history only) passed; runtime implementation/validation and stable merge were not performed.

## 2026-09-10 — Token threshold restart and live expiry verification

- Full Neovim restart-resume activated the final threshold/soft-stop/recovery implementation. Fresh-process inspection confirmed six lifecycle autocmds, public stop-owner/continuation APIs, no restored active decisions, and a successful force-reloaded Native `cc_history` read-only call.
- Post-restart regressions passed: threshold 19, real-host isolated integration 7, soft-stop 7, retry 4, plus the surrounding hook/compression checks. Syntax, targeted formatting, spec lifecycle/reference checks, and `git diff --check` passed.
- A second real Telegram three-choice prompt expired at Bridge `elapsed=300` with `error="timeout"` and script exit 1, complementing the prior real `finish` click. End-to-end model finishing behavior and complete human acceptance remain pending; change lifecycle is draft / pending-human-validation, not stable-merged.

## 2026-09-10 — Token threshold finishing implementation and focused validation

- Main session implemented the revised `add-token-threshold-human-decision` (Git history only) with one reused read-only child reviewer. Changes cover bounded finishing, JSONL/expiry, request-local curl retry control, safe-stop boundary/owner semantics, recovery integration, and cancellation/close/compact-delay gates.
- Focused validation passed: threshold 19, real-host isolated integration 7, soft-stop 7, retry 4; existing hook/compression regressions, Bridge 91, and human-assist 18 also passed. The implementation checklist records commands and acceptance gaps.
- Real Telegram returned `finish`; that early click means actual 300-second expiry was not exercised. Fresh-Neovim activation and full live acceptance remain pending; stable specs were not merged.

## 2026-09-10 — Token threshold default finishing specification revision

- Revised `add-token-threshold-human-decision` (Git history only), design, implementation checklist, and runtime/Telegram/compression deltas after code/spec exploration and explicit Telegram approval for specification authoring only.
- The target contract replaces the prior two-button/infinite-wait/unconditional-no-message policy: three choices, 300-second normal expiry selecting finish, one finishing instruction, and at most eight actual target-chat model requests including retries. Round-eight tools drain safely; request nine is prohibited; no hard tool cancellation or generic default-choice framework is introduced.
- The existing five-test threshold baseline passed during feasibility inspection. Revised implementation and live model/Telegram acceptance remain unvalidated; runtime source, disabled hooks, and stable specs were not changed or falsely promoted. See the workspace verification matrix and remaining implementation checklist.

## 2026-09-09 — Primary-checkout Vault implementation and focused validation

- Implemented `primary-checkout-vault-ownership` (Git history only) in the shared ProjectAdmin scripts, Obsidian graph/health/setup entrypoints, skill references/templates, and isolated tests after explicit implementation authorization. One read-only child review session was reused; main session owned implementation and repairs.
- `primary-checkout-vault-ownership` (Git history only) records 30 ProjectAdmin tests, 10 workspace tests, strict skill lint, shell/help checks, real Windows directory-identity fixtures, and primary Obsidian/WSL Syncthing read-only checks. No live registration, scan, installation, or downstream repair occurred.
- Change remains draft: full Windows Syncthing/human workflow acceptance is unverified; broad capability specs were not falsely promoted or merged.

## 2026-09-09 — Primary-checkout project Vault ownership specification

- Added `primary-checkout-vault-ownership` (Git history only) after mother-repository source/spec exploration, feasibility discussion, and explicit user scope approval.
- Defined one universal Git primary-checkout external-owner rule, linked-Worktree file-only workflows, independent non-Git projects, fail-closed unresolved ownership, explicit setup, no silent retargeting, and guarded graph/health entrypoints.
- Delivery is specification-only: proposal, normative delta, design/verification matrix, and future implementation checklist. Shared skills/scripts, live registrations, downstream files, and existing broad capability specs remain unchanged; runtime validation and acceptance are not run.

## 2026-09-04 — Token threshold Telegram decision specification

- Added draft workspace `add-token-threshold-human-decision` (Git history only) with design, implementation checklist, and deltas for runtime hooks, Telegram Bridge, and session compression after code/spec exploration and explicit user agreement.
- Selected one clean contract: a new runtime hook observes the 95% `ToolCallsCompleted` pre boundary without injecting messages, reuses soft stop to preserve tool-result integrity, blocks all submits while `prompt.py --timeout 0` waits, and routes Telegram `interrupt` or `compact` decisions.
- Compression directly calls `compact_silent.do_compact(..., { auto_submit=true })`; interrupt retains a manual-resumable soft stop. Chat close/cancel and normal Neovim exit explicitly cancel the Bridge request and remove Telegram controls.
- Existing disabled `skills/session-admin/hooks/ToolCallsCompleted.lua` and `ChatSubmitted.lua` remain outside the change. Implementation and validation have not run.

## 2026-09-03 — GDA real Editor test specification
- Added draft workspace `add-gda-editor-test` (Git history only) with design, implementation checklist, and `gda-editor-testing` delta after GDA source/stable-spec review, Godot official CLI/EditorPlugin/SplitContainer documentation review, explicit user agreement, and a disposable official Godot `4.7.2-stable` prototype.
- Selected one clean `gda editor test TEST_SCRIPT` contract: GDA-owned bridge plugin, disposable current-source project copy, project-authored `@tool RefCounted.run(EditorInterface)` test, async frame waits, strict artifact protocol, typed assertions/measurements, exact failures, total timeout, process cleanup, and failed-only workspace retention.
- Explicitly excluded source-project mutation, caller-authored bridge plugins, `plugin.cfg` public input, stdout/stderr result parsing, native flag passthrough, `script run` fallback, compatibility aliases, interactive/attached Editor sessions, screenshots, DPI/pixel/mouse claims, and replacement of human visual review.
- Prototype discovered the real Panda Balancing Dock with `editor_hint:true` and measured Diagnostics `48px`, Results `64px`, Candidate Preview `90px` inside a `289×520` Dock, proving both feasibility and the reported layout defect.
- Implementation now passes official Editor E2E, Editor/runner focused validation (`49 passed`), bounded-xdist broad GDA validation (`2273 passed, 6 skipped, 1 xfailed`), Ruff/format/Pyright, strict skill checks, and Panda real Editor dogfood. Repaired Panda geometry uses a `21px` theme line height and measures Diagnostics `48px`, Results `357px`, Preview `90px`; increasing Preview allocation to `120px` reduces Results to `327px`. Status remains draft pending visible Editor/DPI/mouse human acceptance and stable merge.

## 2026-09-01 — Neovim Godot automatic language tooling specification

- Accepted [[specs/godot-tooling/language-tooling|Godot 自动语言工具链行为规格]] as the normative active contract after project exploration, proxy-backed source research, implementation, repeated SubAgent review/repair, automated validation, full Neovim restart, current-process runtime smoke, and explicit user acceptance.
- The accepted runtime owns one independent headless Godot/GDScript LSP service per canonical `project.godot` root per Neovim, dynamic non-`6005` ports, `gdvm`-safe process-group cleanup, keep-alive until explicit stop or Neovim exit, bounded recovery, and project-scoped status/restart/stop commands.
- `.gdshader`/`.gdshaderinc` use pinned `gdshader-lsp-cpp v0.3.2 --stdio`, explicit versioned SHA-256 installation through `:GodotToolsInstall`, and pinned GDShader Treesitter parsing without implicit download or headless Godot launch.
- Validation passed for Lua syntax/core/POSIX/full-runtime checks; official Godot 4.7.2 completion/hover/definition/diagnostics; restart/stop/double-restart/clean exit; one-Neovim multi-project, two-Neovim same-project, external-Godot isolation; pinned GDShader completion/hover/definition/include/diagnostics; installer checksum/mode repair; and post-restart current-process activation/cleanup.
- Per explicit user request, the completed change workspace was physically removed after stable merge instead of retained as logical archive context. This log and the normative spec preserve the durable decision and validation trace.

## 2026-08-30 — GDA Live explicit sequence window and same-callback snapshot specification

- Added draft workspace `add-gda-live-sequence-window-and-snapshot` (Git history only) with design, implementation checklist, and `gda-live-operations` delta after GDA source, harness, tests, ADR, stable-spec, and skill review plus explicit user agreement.
- Selected one clean `input sequence` contract with required total `frames`, no-input tail frames on the already-selected process/physics clock, and no wait event, optional inference, alias, or compatibility path.
- Selected `gda game snapshot` for ordered unique exact runtime node/property reads in one harness process-frame callback, shared filtered-`game get` property semantics, all-or-nothing failures, and once-captured process/physics frame evidence.
- Explicitly excluded conditions, assertions, retries, search selectors, relative paths, writes, timelines, workflow/gameplay semantics, partial success, and cross-session identity.
- Status remains draft; implementation and validation have not started, so no stable `gda-live-operations` spec has been created or merged.

## 2026-08-30 — GDA structured params files and native JSON property values specification

- Added draft workspace `unify-gda-structured-input-values` (Git history only) with design, implementation checklist, and `gda-structured-input` plus `gda-property-values` deltas after GDA source/ADR/spec/schema/test review, feasibility analysis, and explicit user agreement.
- Selected inline-only `--params-json`, central `--params-file <PATH|->`, native JSON property values, direct `--value-json`, descriptor-only target typing, and exact `{resource_path}` Resource reference objects.
- Explicitly excluded compatibility aliases, transition parsers, scene-specific file options, `@file` magic, caller type tags, bare Resource paths, nested JSON strings, and dual value grammars.
- Implementation and convergence completed: central params sources, strict duplicate-key/UTF-8 acquisition, native JSON models/codecs, `--value-json`, project `class_name` Resource assignment, nullable headless Objects, typed-container atomic validation, Scene Apply/live integration, ADRs, schemas/help, bundled/global skills, related Scene Apply draft, and both stable specs were aligned.
- Validation passed for the feature path: non-E2E `1697 passed, 2 skipped`; broad official Godot setters/apply/live `220 passed, 1 xfailed` plus stale strict-typed expectations repaired and `5 passed`; focused official Godot `29 passed, 1 xfailed`; contract/schema/error/mirror/harness/skill `310 passed`; Ruff, format, Pyright, strict skill lint, diff check, Panda Adventure artifact-path dogfood, and independent final review passed. Full-suite residuals are recorded as unrelated GDVM isolated-HOME and existing script-abort timing blockers.

## 2026-08-30 — GDA single Godot validation baseline specification

- Added draft workspace `set-gda-single-godot-baseline` (Git history only) with design, implementation checklist, and `gda-engine-compatibility` delta after GDA source, test, skill, ADR, spec, index, and command-guidance exploration plus explicit user agreement.
- Fixed the only maintained and tested guarantee as official `Godot 4.7.2-stable` with GDScript and native Godot content. C#, Mono/.NET, GDExtension, other language platforms, release channels, and engine versions are outside the guarantee.
- Defined compatibility-neutral runtime behavior: alternate engines and mixed-language projects remain executable without rejection, warning, scanning, fallback, or compatibility verdict; factual version reporting such as `gda info` remains allowed.
- Required complete removal of minimum-version and split headless/live policy, public version-gate errors/schema metadata, supported-engine matrices, transition paths, and obsolete compatibility narratives from current GDA-owned tracked artifacts. Git remains the history source.
- Implementation and convergence completed: runtime/schema/error version policy was removed; recipes, tests, skills, ADRs, stable specs, execution-context guidance, and retained Agent-facing records were aligned; change artifacts are accepted and retained in place.
- Validation passed: non-E2E `1688 passed, 2 skipped`; official `4.7.2-stable` broad headless `502 passed, 4 skipped, 1 xfailed`; serial daemon `31 passed`; Node `107 passed`; focused info/mixed-language/daemon `35 passed`; Ruff check/format, Pyright, strict skill lint, harness/skill checks, `git diff --check`, scoped cleanup search, and independent review passed.

## 2026-08-30 — GDA descriptor-driven property addressing specification

- Added draft workspace `generalize-gda-property-addressing` (Git history only) with design, implementation checklist, and `gda-property-values` delta after GDA source/spec/ADR/test review, Godot official documentation/source review, Godot 4.7.2 feasibility probes, and explicit user agreement.
- Replaced the proposed storage-only/individual-policy model with one exact `get_property_list()` descriptor authority: descriptor metadata defines existence, eligibility, type, and Resource class; undeclared names are rejected before setter invocation even when `_set()` is permissive.
- Defined authored success as candidate pack/save/reload plus same-name canonical read-back before atomic commit, covering both dynamic storage activation and persistence through different authoritative fields; live writes use the same descriptor/coercion rules but retain runtime-only observed `verified`.
- Fixed non-goals: no property/class/prefix registry, theme/Control/Node3D addressing implementation branches, arbitrary unknown-name trial assignment, raw `set_indexed()` public surface, transition policy, or compatibility resolution order. Existing semantic rules such as Node3D scale validation and dedicated `script attach` ownership remain orthogonal.
- Convergence completed: stable `.maxa/specs/gda-property-values/spec.md` merged the accepted delta; all change artifacts are `status: accepted`, `validation.automated: passed`, `validation.human: passed`, and `archive_state: retained`.
- Validation evidence: full non-E2E `1687 passed, 2 skipped`; official Godot 4.7.2 isolated Node E2E `107 passed`; broader maintained-baseline headless checks and serial daemon `31 passed`; Ruff/format/Pyright, harness/skill sync, strict skill lint, independent review, and Panda Adventure authoring/validate/preflight dogfood passed.
- One synthetic scene-apply dynamic-descriptor drift fixture is a strict XFAIL because supported Godot builds trigger a signal-11 callback crash; Node/Resource drift rollback and normal scene-apply paths pass and no candidate commit occurs.

## 2026-08-30 — GDA single-scene transactional authoring specification

- Added draft workspace `add-gda-scene-apply` (Git history only) with technical design, implementation checklist, and `gda-scene-authoring` delta spec after GDA source/ADR/test review, Godot documentation checks, temporary-project feasibility experiments, and explicit user agreement.
- Defined `gda scene apply` for exactly one existing `PackedScene`: strict ordered `add|set|remove|duplicate|move|attach_script|connect_signal|disconnect_signal` operations share save-free primitives with standalone commands, stop at first failure, and commit once through existing staleness/preload/re-anchor/atomic-save/cleanup guards.
- Fixed the ownership boundary: external scripts/resources/instanced scenes must already exist and remain outside the transaction; no cross-file transaction, complete scene-tree JSON DSL, symbolic workflow language, file-backed JSON input, or live mutation is included.
- Retained `script run` unchanged. Agent guidance work is limited to canonical `--params-json -` transport for multiline/large inputs and synchronous `root.free()` before `quit()` for caller-owned temporary trees; no leak-log suppression or new diagnostic ABI is proposed.
- Follow-up design review promoted the complete params object to the public versioned Scene Apply Document. Agents may construct and directly submit it through `--params-json -`; GDA owns validation/execution only and explicitly does not own `batch begin`, temporary IDs, command recording, draft storage, locks, expiry, recovery, or cancellation.
- Feasibility review found the maintained baseline's GDScript API has no portable atomic no-replace commit, so user approval narrowed document v1 to existing scenes only. New scenes remain owned by `gda scene create`; `mode`, `root_type`, and `root_name` are strict-invalid apply fields, avoiding a TOCTOU-based no-clobber claim.
- Implemented the Python command/schema/typed-result surface, ADR-0042, strict GDScript document validation, eight shared save-free mutation primitives, one-load/one-save apply orchestration, indexed failure context, focused E2E and reusable skill guidance. Independent SubAgent review rejected an initial handler-interception implementation; repairs restored true primitive ownership, add-name/error-order parity, move no-op behavior, and direct-dispatch strictness.
- Validation passed: official Godot 4.7.2 `29` focused apply/direct-dispatch E2E; `1687 passed, 2 skipped` non-E2E; Ruff check/format, Pyright, strict skill lint, diff check; representative CSG apply returned ordered typed results and passed `scene validate` (`valid: true`) plus `scene preflight` (`started: true`, `status: ready`). Standalone broad acceptance, stable-spec merge, and lifecycle acceptance remain pending.

## 2026-08-27 — Telegram Chat upload implementation and automated validation

- Implemented dedicated no-timeout Chat Upload persistence/API/reply dispatch in Telegram Bridge, streamed single-file Bot API download into `.maxa/upload/<session-id>/`, and `/tg_upload` Chat controller/registration with exact temporary guidance, lock, long-poll, path-first replacement, and close/exit cancellation.
- Added strict owner/chat/topic/reply matching, pure text plus eight supported attachment mappings, 20 MB declared/observed limits, recoverable invalid replies, atomic no-clobber collision publication, staged cleanup, strict non-symlink upload/session containment, and interrupted-download restart convergence.
- Added focused Bridge and Lua regression coverage. Initial `just telegram-bridge-test` passed with 80 tests; `/tg_upload` headless tests passed; existing `/upload` suite passed 10/0; module/client load, registration inspection, and `git diff --check` passed.
- Real photo/document replies revealed that aiogram `Bot.download_file()` defaults to rewinding file-like destinations, while the bounded streaming writer intentionally lacks `seek()`. Set `seek=False`, added an aiogram-shaped adapter contract test, reran the full Bridge suite with 81 passing tests, and restarted the Bridge with a successful delayed health check.
- Added Telegram `message.location` as a successful no-file reply, formatted exactly as `纬度：<latitude>` then `经度：<longitude>` after numeric/range validation; venue name, address, geocoding, and map links remain excluded. Full Bridge validation passed with 87 tests, followed by Bridge restart and health check.
- Fixed live location placeholder convergence: multiline Bridge text is now split into individual buffer lines before replacing the one-line guidance, and placeholder state is cleared only after a successful edit. Added a regression asserting coordinates replace rather than coexist with the guidance; `/tg_upload`, `/upload`, Bridge, and diff validation passed.
- Fixed a post-restart/new-Chat create race that returned HTTP 409 `caller chat is not active primary`: `/tg_upload` now completes an exact Bridge heartbeat before request creation. Lua error reporting now surfaces decoded FastAPI `detail` before stderr/HTTP fallback, eliminating blank create-failure notifications; focused Lua/syntax/diff validation passed.
- Repeated 409s revealed a restored `save_id` could remain open in multiple live Neovim instances, with an older instance retaining legacy primary election. Chat Upload creation now accepts the exact requesting instance when that exact Chat is live/open, rather than requiring session-primary ownership; routing remains session-bound. Added duplicate-instance regression coverage, passed 88 Bridge tests plus Lua checks, and restarted/health-checked the Bridge.
- Independent SubAgent review identified global `VimLeavePre`, publication race, realpath/symlink containment, and restart-recovery gaps; all were repaired and revalidated.
- Restarted Telegram Bridge and verified `/v1/health`; fully restarted Neovim and confirmed live controller/client loading plus `/tg_upload` callback with `contains_code = false`.
- Live unbound/private text-only smoke passed in a disposable Chat: Telegram received the reply target, the Chat showed the exact locked guidance, owner reply `ok` completed the request, and the guidance was replaced with `ok` without auto-submit.
- Workspace remains draft pending bound-topic file/caption, representative media, invalid-reply recovery, Chat/Neovim cancellation, and Bridge-restart live validation.

## 2026-08-27 — Telegram Chat upload workflow specification

- Added draft workspace `add-telegram-chat-upload-workflow` (Git history only) with technical design, implementation checklist, and `telegram-chat-upload-workflow` delta spec after repository/Telegram Bot API feasibility analysis and explicit user agreement.
- Defined `/tg_upload` as a dedicated no-timeout Telegram Bridge request rather than a timed Human Assist input: exact non-detached caller binding routes to its topic, otherwise owner private chat; the first exact owner reply completes once.
- Recorded accepted payload scope: pure text or one `document`, largest `photo`, `video`, `audio`, `voice`, `video_note`, `animation`, or `sticker`; no media groups/multiple files; official cloud Bot API download maximum is 20 MB.
- Defined shared storage and Chat convergence: stream attachments to `.maxa/upload/<session-id>/`; lock behind an exact temporary instruction; resolve with relative path before caption/text without auto-submit; Chat close or Neovim exit cancels waiting while finalized files remain.
- Updated [[specs/index]] and `changes` workspaces (Git history only). Implementation, automated validation, Bridge/Neovim restart, and private/bound-topic live validation remain not run.

## 2026-08-19 — GenAI capabilities moved to adapter specification

- Added draft workspace `move-genai-capabilities-to-adapters` (Git history only) with design, implementation checklist, and deltas for `genai-native-mcp` and `runtime-plugin-entrypoints` after feasibility analysis and explicit user agreement.
- Defined GenAI as the owner of global image/TTS/video defaults and independent per-medium default adapters; concrete gateway adapters explicitly own capability mode, endpoints, request policy, limits, credentials, and optional adapter-specific defaults.
- Confirmed clean replacement semantics: media tools use optional `adapter`, Chat `gia` becomes `gi`, Chat `gip` is removed, `<leader>cxia` remains, and no provider parser, aliases, old persistence readers, or inferred capabilities are allowed.
- Marked `add-genai-multimodal-provider` (Git history only) superseded and retained its successful implementation/runtime validation as historical evidence.
- Implemented the replacement and passed 120 focused Lua cases, syntax, strict skill lint, three Native restart-resume cycles, forced live schemas, registry/keymap/picker inspection, gateway proxy metadata/policy checks, and local capability rejection smokes; stable-spec merge and lifecycle acceptance remain pending.

## 2026-08-19 — GenAI unified multimodal provider draft

- Added draft workspace `add-genai-multimodal-provider` (Git history only) with technical design, implementation checklist, and `genai-native-mcp` delta spec after feasibility analysis and user agreement.
- Recorded the final configuration model: one service provider with optional `image`/`tts`/`video` capability blocks; absent means unsupported, present defaults enabled, and `enabled=false` means disabled; image protocol is selected by `mode=codex|compatible` rather than separate provider identity.
- Recorded new tools and confirmed public fields: `audio_speech` requires `input`; `video_generate` requires `prompt`, owns create/poll/content download, and accepts `reference_image_paths` with default maximum seven.
- Recorded Infinite Canvas wire requirements: compatible Images needs without strict byte reproduction, binary `/audio/speech`, and video multipart `input_reference[]`/`resolution_name`/`preset` with `seconds=1..20`.
- The specification intentionally excludes migration aliases or old/new provider-config compatibility. Implementation, automated validation, Native restart/schema checks, and final human contract review remain pending.

## 2026-08-19 — GenAI unified multimodal provider implementation

- Implemented one service-provider record with optional `image`/`tts`/`video` capabilities, `enabled` state semantics, shared API-root/credential resolution, and `image.mode=codex|compatible` dispatch; removed old protocol-as-provider identities and renamed runtime default-provider UI/state modules.
- Added Native `audio_speech` and `video_generate`. TTS saves validated binary audio locally; video performs Infinite Canvas-compatible multipart create, nonblocking poll, URL/content retrieval, cancellation-safe completion, and local file save.
- Corrected compatible Images behavior: non-stream default, configurable repeated `image`/mask fields, default `max_n=15`, and `data`/`images`/`results` plus compatible envelope parsing.
- Updated GenAI skill, SYSTEM fragment, user guide, preflight, provider development, and provider-specific image guidance.
- Validation passed: 111 focused GenAI cases, 4 shared config cases, Lua syntax, strict skill lint, `git diff --check`, four full Native restart-resume cycles, forced live schema reload, and no-cost local rejection smokes. Real upstream TTS/video calls were skipped; final human contract acceptance and stable-spec merge remain pending.

## 2026-07-24 — load_image target-long-edge resize accepted

- Added and accepted `replace-load-image-preview-with-resize` (Git history only) with proposal, technical design, implementation checklist, and delta specs merged into [[specs/runtime/chat-builtins|mcpx 文件、命令与事件工具行为草案规格]] and [[specs/genai/native-mcp|GenAI Native MCP 行为草案规格]].
- Implemented the user-approved breaking contract: removed `preview`; added optional integer `target_long_edge` (`1..8000`) and `resize_mode=upscale_only|downscale_only|always` defaulting to `downscale_only`; crop precedes proportional resize; equal target is a no-op; mode without target is inert.
- Validation passed: 15 focused `load_image` cases, wrapper regressions, Lua syntax, strict skill lint, stale active-call searches, and `git diff --check`; full Native restart/live schema exposed the exact new contract; runtime fixtures passed upscale, downscale, no-op, and crop-before-resize with actual output dimensions. Workspace is logically archived in place.

## 2026-07-11 — GenAI image slicing workflow draft

- Added draft SpecAdmin change workspace `add-genai-image-slicing-workflow` (Git history only) with proposal, design, implementation checklist, and `genai-native-mcp` delta spec.
- Recorded user-confirmed constraints: `genai__image_edit` directly draws protocol-color bbox borders; one-pixel size drift and tolerant rectangle repair are allowed; touching/intersection/overlap/nesting are blocked; extraction uses the untouched source with transparent four-side padding; annotation stops after three attempts per batch.
- Updated [[specs/index]] and `changes` workspaces (Git history only). Implementation and automated validation later passed; a real GenAI-generated source plus three size-unspecified `image_edit` attempts demonstrated tolerant partial bbox recovery but failed full-batch exact-color evidence, so live extraction and stable merge remain blocked.

## 2026-07-11 — Human Assist private/bound routing accepted

- Accepted and retained `route-human-assist-to-private-or-bound-topic` (Git history only) after implementation/spec convergence; merged the deltas into [[specs/services/telegram-bridge|Telegram Bridge Service 行为草案规格]] and [[specs/runtime/chat-builtins|mcpx 文件、命令与事件工具行为草案规格]].
- Implemented private default routing at `MAXA_TELEGRAM_OWNER_USER_ID`, exact non-detached caller-session bound-topic override, explicit missing-owner failure, known stale-topic recovery/private fallback, owner-only destination authorization, and non-disclosing result contracts.
- Added exact child-only `MAXA_CODECOMPANION_PROJECT_ROOT` / `MAXA_CODECOMPANION_SAVE_ID` propagation from `req.caller.codecompanion.chat`, including restored-chat buffer fallback through a shared identity resolver; listener invocation explicitly clears both variables.
- Validation passed: Telegram Bridge 57 pytest cases, human-assist 15 unittests, focused Lua suites, strict skill lint, `git diff --check`, Bridge restart/health, and Native Neovim restart-resume. Human/live private prompt/input, bound prompt/input, detach fallback, unmatched private-text isolation, and one-shot listener private delivery passed; destructive stale-topic smoke was skipped and covered by tests.

## 2026-07-10 — Human Assist private/bound routing draft

- Added draft workspace `route-human-assist-to-private-or-bound-topic` (Git history only) with proposal, technical design, implementation checklist, and delta specs for `telegram-bridge-service` and `mcpx-file-command-tools`.
- Recorded user-confirmed routing: `notify.py`, `prompt.py`, and `input.py` default to Bot private chat at `MAXA_TELEGRAM_OWNER_USER_ID`; only the exact caller session's non-detached binding uses its Telegram topic; one-shot listener notifications remain private.
- Recorded failure behavior: missing owner ID is an explicit pre-send error; stale bound-topic recovery failure silently falls back to private chat without destination/fallback metadata for the LLM; unknown send failures do not trigger duplicate private delivery.
- Designed exact caller identity propagation from `req.caller.codecompanion.chat` through child-only `MAXA_CODECOMPANION_PROJECT_ROOT` / `MAXA_CODECOMPANION_SAVE_ID`, with no LLM-supplied routing fields or latest-chat fallback.
- Updated [[specs/index]] and `changes` workspaces (Git history only) for Agent reachability; implementation and validation remain not run pending human spec review.

## 2026-07-10 — GenAI requested-size and actual-output draft

- Added draft workspace `replace-genai-size-controls-with-requested-size` (Git history only) with proposal, design, implementation checklist, and `genai-native-mcp` delta spec.
- Recorded intentional removal of public `size`, `aspect`, and `ratio` without aliases; replacement field is request-only `requested_size` and saved files must report actual dimensions/formats.
- Recorded prompt openness: natural-language canvas/orientation/ratio composition remains allowed; only machine mapping and hidden aspect injection are removed.
- Implemented `requested_size`, legacy-field rejection, exact prompt forwarding, PNG/JPEG/WebP metadata inspection, actual-size/format warnings, and transparent arbitrary-source preflight.
- Reconciled conflicting fixed-matrix/ratio/aspect requirements in `align-genai-fhl-responses` and `add-genai-transparent-channel-workflow`; both remain draft until current validation and stable convergence complete.
- Full Native restart/schema reload passed; live calls reported `auto -> 1672x941`, `1536x1024 -> 1254x1254 mismatched`, and `3840x2160 -> 1254x1254 mismatched`, with `file`/ImageMagick independently matching tool metadata.
- Human contract review passed: `Requested size` is distinct from actual file facts, mismatch warnings are explicit, natural-language `16:9` remains accepted, arbitrary `1254x1254` transparent preflight is allowed, and >1-pixel output mismatch blocks; Human Assist returned `accept` for the presented behavior.
- Merged accepted requested-size behavior into [[specs/genai/native-mcp|GenAI Native MCP 行为草案规格]], marked the change accepted with automated/human validation passed, and retained the workspace in place.
- Updated [[specs/index]] and `changes` workspaces (Git history only) for Agent reachability.

## 2026-07-10 — Telegram Bridge single-consumer human-assist convergence

- Updated `specs/telegram-bridge-service/spec.md` and the `maxa-runtime` child contract to make Telegram Bridge the sole default Telegram `getUpdates` consumer; `human-assist` notify/prompt/input scripts are Bridge HTTP clients, while explicit `--direct` remains compatibility/debug-only and must not run with Bridge for the same Bot.
- Added Bridge-managed human-assist API, SQLite request lifecycle, callback/reply routing, first-response atomicity, pre-send request registration, timeout closure, original-message button cleanup, topic recovery, and response photo download requirements; updated `specs/index.md` routing text.
- Validation evidence: Telegram Bridge compileall + 51 pytest cases passed; human-assist 11 unittests passed; skill lint reported 0 errors/warnings; Bridge restart and `/v1/health` passed; live prompt smoke succeeded on the first click in 3 seconds with no new `getUpdates` conflict and with original-message status/button cleanup.
- Stable specs remain `authority: draft` / `status: experimental`; live input text/image and photo prompt/notification smokes remain future promotion coverage.

## 2026-07-10 — compact_self request-prefix contract sync

- Updated `specs/session-compression/spec.md` to require both `compact_self` modes to inherit the parent request's actual `prompt_cache_key`, preserve top-level `instructions`, retain the transformed parent `input` as an exact prefix, transmit equal parent tool schemas, and inherit adapter/model/request settings while enforcing mode-specific tools locally.
- Clarified that `compact_self` preserves the parent message sequence during planning and cleans runtime-control/token-warning artifacts only after successful replacement; rescue/non-self normalization and truncation remain independent.
- Recorded automated evidence (`compact_silent_smoke_test.lua` 9/9, related session suites 17/17, `git diff --check`) and post-restart final-body equality for both modes. Provider-side cache admission or reported cache hits remain outside the guarantee and pending end-to-end evidence.

## 2026-07-10 — GenAI transparent-channel workflow draft

- Added draft SpecAdmin change workspace `.maxa/specs/changes/add-genai-transparent-channel-workflow/` after feasibility analysis and explicit user confirmation of canonical-input RGB, inverse-white recovery, runtime-latest CorridorKey, OpenCV Despeckle, and one-pixel resampling decisions.
- Added proposal, design, implementation checklist, and `genai-native-mcp` delta spec covering strict verified-size preflight, generated-derivative dimension reports, checker/chroma/white/Alpha Hint prompts, Replicate Files/Predictions lifecycle, transparent composition, visual repair gates, and compatibility with existing GenAI tools.
- Added supporting research at [[research/genai-transparent-channel-corridorkey|GenAI 透明通道恢复与 CorridorKey Replicate 接口调研]] and updated `specs/index.md` plus `specs/changes/index.md`.
- Implemented uv-managed transparent image operations, async runtime-latest Replicate CorridorKey Native MCP tool, GenAI prompt/workflow guidance, and tests. Automated validation passed: Python 13; CorridorKey Lua 7; existing GenAI suites 21/16/14/30; strict skill lint 0 errors/warnings; deterministic one-pixel alignment/RGBA review smoke passed.
- Native MCP full restart-resume and forced schema reload passed; the runtime exposed all three GenAI tools and local smokes confirmed missing-file, invalid-range, missing-credential, and blocked-dimension errors. Live Replicate prediction, integrated GenAI derivative generation, and human visual acceptance remain pending; `REPLICATE_API_TOKEN` was absent from the current process, so no external paid live call was attempted.

## 2026-07-09 — Chat context limit stop draft and implementation
- Added draft SpecAdmin change workspace `.maxa/specs/changes/add-chat-context-limit-stop/` for a CodeCompanion Chat command that arms a one-shot context-usage limit and reuses soft-stop safe boundaries when reached.
- Implemented chat-local `<leader>aX` keymap, `util.hooks.chat_context_limit_stop`, and shared hook registration after `chat_soft_stop`. Input accepts absolute `0..100` or relative `+N`; active listener/prompt toggles cancel without reopening input; reached limits are one-shot and delegate stopping to soft-stop boundaries.
- Automated validation passed: `luac -p lua/plugins/ai.lua lua/util/hooks/init.lua lua/util/hooks/chat_context_limit_stop.lua lua/util/hooks/chat_context_limit_stop_test.lua`; `nvim --headless -u NONE -l lua/util/hooks/chat_context_limit_stop_test.lua` (10 passed); `nvim --headless -u NONE -l lua/util/hooks/chat_soft_stop_test.lua` (5 passed).
- Post-restart runtime smoke passed after `mcp-creator` Neovim restart-resume: current process has both `chat_soft_stop` and `chat_context_limit_stop` Chat patches installed, and `+10` parsing produced target ratio `0.35` from current ratio `0.25`.
- Historical note: full interactive Agent Loop/tool-call smoke was not run; Agent Loop/`pause_loop` is now removed and this is not a current validation gap.
## 2026-07-09 — mcpx async cancel to SubAgent accepted
- User confirmed the spec is complete: `规格已确认完成`.
- Merged accepted delta behavior from `.maxa/specs/changes/propagate-mcpx-async-cancel-to-subagents/` into stable draft specs:
  - `specs/mcpx-tool-layer/spec.md`
  - `specs/subagent-delegation/spec.md`
  - `specs/subagent-workflow-runtime/spec.md`
- Marked the change workspace `status: accepted`, `accepted_at: 2026-07-09`, `validation.automated: passed`, `validation.human: passed`, and `archive_state: retained`.
## 2026-07-09 — mcpx async cancel to SubAgent implementation
- Added draft SpecAdmin change workspace `.maxa/specs/changes/propagate-mcpx-async-cancel-to-subagents/` before implementation.
- Implemented cooperative cancellation propagation from `mcpx__cancel_async_task` through async `mcpx__call_tool` / `mcpx__call_tools_parallel` wrappers into registered SubAgent child handles.
- Added `mcpx` async cancellation bridge, SubAgent async cancel helper, wrapper cancellers, chat-backed child registration, executor/workflow cancellation boundary checks, and cancellable `streaming_llm.streaming_request()` handle for `ask_llm`.
- Automated validation passed; Native MCP restart-resume and `mcpx`/`subagent` schema reload passed. User requested a second mcp-creator restart/test cycle; second restart-resume, schema reload, and post-restart regression tests also passed. Actual runtime cancellation smoke passed for wrapped `subagent__run_agent` and async `mcpx__call_tools_parallel`: cancelled outer tasks stayed terminal after waits, and the parallel sentinel call was not scheduled after cancellation.
## 2026-07-09 — Image detail and load_image injection spec sync
- Synchronized stable draft specs with current image-input behavior: `mcpx__load_image.detail` defaults to `original`; `genai__image_edit.detail` defaults to `original`; both allow `low`, `high`, `original`, and `auto` where applicable.
- Updated `specs/runtime-hooks-and-message-injection/spec.md` to require OpenAI Responses `mcpx__load_image` payloads to attach to the next user message, keep `function_call_output.output` as a string, and skip TTL-expired/missing-base64 images.
- Validation evidence recorded from current implementation tests: `adapter_form_messages_load_image_test.lua`, `load_image_spec.lua`, `image_responses_provider_test.lua`, `call_tool_json_input_spec.lua`, and `call_tools_parallel_spec.lua`.
## 2026-07-09 — Chat soft stop draft and implementation
- Added draft SpecAdmin change workspace `.maxa/specs/changes/add-chat-soft-stop/` for CodeCompanion Chat soft stop after the current response/tool batch.
- Implemented chat-local `<leader>ax` keymap, `util.hooks.chat_soft_stop`, and shared hook registration. Soft stop requests do not cancel active work; they suppress the next auto-submit continuation. The former Agent Loop deactivation behavior is historical because Agent Loop is removed.
- Automated validation passed: `luac -p lua/plugins/ai.lua lua/util/hooks/init.lua lua/util/hooks/chat_soft_stop.lua lua/util/hooks/chat_soft_stop_test.lua`; `nvim --headless -u NONE -l lua/util/hooks/chat_soft_stop_test.lua` (5 passed).
- Historical validation note: the former interactive Agent Loop scenario was not run before that runtime was removed; current soft-stop validation no longer depends on Agent Loop.
## 2026-07-09 — Anthropic Messages gateway adapter draft and implementation
- Added draft SpecAdmin change workspace `.maxa/specs/changes/add-anthropic-messages-gateway-adapter/` covering protocol dispatch for the existing `make_openai_responses_adapter(opts)` gateway factory.
- Implemented `lua/plugins/ai.lua` support for `opts.protocol = "anthropic_messages"` while preserving default OpenAI Responses behavior for existing factory call sites.
- Added live `xuanjing_anthropic` factory-based adapter targeting `https://sub.chatgptallinone.xyz/v1/messages` with sub2api quota metadata and Anthropic table/string model schema safety.
- Automated validation passed: `luac -p lua/plugins/ai.lua`; `nvim --headless -l /tmp/ai_gateway_adapter_smoke.lua` used an isolated empty env file and verified OpenAI Responses adapter construction, Anthropic Messages adapter construction, sub2api/newapi quota normalization, and Anthropic model-choice replacement semantics without live `/models` access. Post-restart isolated-env smoke in restored Neovim verified `xuanjing_anthropic` fallback choices do not include CodeCompanion official `claude-sonnet-4-6` / `claude-opus-4-6`.
- Stable spec merge/accepted status remains deferred until delta is merged into `specs/runtime-plugin-entrypoints/spec.md` or explicitly accepted as retained draft trace.
## 2026-07-08 — GenAI FHL Responses alignment implementation
- Implemented `.maxa/specs/changes/align-genai-fhl-responses/` draft change for `codex_proxy_image`: `text_model`/tool `model` separation, fixed Responses metadata, prompt/aspect `instructions`, verified 2K ratio matrix, disabled-ratio validation, partial image defaults, and provider-local retry classification.
- Extracted shared `lua/util/mcphub/genai/image/size_policy.lua`; both `openai_responses_image_generation` and `openai_compatible` now use the same `aspect` / `ratio` / verified-2K `size` policy.
- Updated `genai__image_generate` / `genai__image_edit` schemas with optional `text_model`, `aspect`, and `ratio`; updated `skills/genai/SKILL.md` and `skills/genai/references/preflight.md` accordingly.
- Automated validation passed: `image_provider_test.lua` 14/0, `image_generate_test.lua` 21/0, `image_edit_test.lua` 16/0, `image_responses_provider_test.lua` 29/0.
- Native MCP restart/schema smoke passed after restart-resume: reloaded `genai` schema exposes `text_model`, `aspect`, and `ratio`; no-cost disabled-ratio handler smoke returned the expected local validation error before network/image generation.
- User live functionality test passed on 2026-07-08: user reported `已测试，功能正常`.
- Stable spec merge/accepted status remains deferred until delta is merged into `specs/genai-native-mcp/spec.md` or explicitly accepted as retained draft trace.
## 2026-07-08 — GenAI FHL Responses alignment draft
- Added draft SpecAdmin change workspace `.maxa/specs/changes/align-genai-fhl-responses/` for aligning `codex_proxy_image` Responses request construction with verified FHL Codex implementation.
- Scope covers `text_model`/tool `model` separation, fixed request metadata, top-level prompt instructions, 2K ratio matrix, disabled-ratio validation, partial image defaults, provider-local retry classification, tool schemas, and `skills/genai` docs.
- Explicit boundary: full cross-call adaptive concurrency downgrade remains out of scope until a batch/queue layer exists.
## 2026-07-07 — Session trace visualization v1 implementation validation
- Implemented `skills/session-admin/scripts/trace_visualize.py` with `skills/session-admin/pyproject.toml` and `skills/session-admin/tests/test_trace_visualize.py`; updated `session-admin` skill docs to expose the script.
- The exporter writes `.maxa/history/traces/<root_trace_id>/visualization/trace-overview.canvas` and `trace-summary.md`, fails without `--overwrite` on conflicts, and updates `.maxa/.stignore` with narrow visualization include exceptions while keeping raw history ignored.
- Automated validation passed: `uv run --project skills/session-admin python skills/session-admin/tests/test_trace_visualize.py` (5 passed), `trace_visualize.py --help`, and live export smoke for recorded trace `20260707_040353_451_000022_g3gcjt` with Canvas/edge/Markdown validation passed.
- Workspace remains draft with `validation.automated: passed`, `validation.human: not-run`, `archive_state: pending-review`; stable spec merge/accepted status is deferred pending independent review or human Obsidian rendering acceptance.
## 2026-07-07 — Session trace visualization sync visibility refinement
- Refined `.maxa/specs/changes/add-trace-visualization-v1/` to require Obsidian visibility and Syncthing synchronization for generated `history/traces/<root_trace_id>/visualization/` artifacts.
- Recorded current evidence: `.maxa/.stignore` ignores raw `/history` and `/history/**`; implementation must add narrow include exceptions for visualization outputs without syncing raw trace/runtime history.
## 2026-07-07 — Draft/spec/article picker mtime ordering
- Updated `specs/chat-fragments-and-slash-commands/spec.md` to require draft, spec, and article picker helper listings to order eligible entries by descending file modification time with deterministic tie-breaks.
- Updated stable spec row contract to display `[SPEC <status>]`, using `[SPEC unknown]` when frontmatter status is absent.
- Automated validation passed: `nvim --headless -l lua/util/maxa_drafts_test.lua`, `nvim --headless -l lua/util/maxa_specs_test.lua`, and `nvim --headless -l lua/util/maxa_articles_test.lua`.

## 2026-07-07 — Session trace visualization v1 draft
- Added draft SpecAdmin change workspace `.maxa/specs/changes/add-trace-visualization-v1/` for static Obsidian Vault visualization export of session trace lineage.
- Scope confirmed with user: v1 generates JSON Canvas and a program-generated Markdown summary under trace artifact directories; no Obsidian plugin or interactive JavaScript UI in v1.
- Exploration recorded: current `cc_history__get_trace`/`session_trace` data supports span/action/archive visualization; JSON Canvas is the Vault-native graph surface; Markdown summary is the generated textual index/detail page; Mermaid was considered but excluded from v1 after user clarification, while Cytoscape/React Flow/ELK remain v2 candidates.
## 2026-07-07 — Session trace lineage post-restart smoke
- After Neovim restart-resume, TaskAdmin `master/24.6` confirmed live `cc_history` MCP schema includes `get_trace`; recorded and synthesized `cc_history__get_trace` calls returned bounded output.
- Live smoke executed `/trace_start` on the restored task chat and exercised disposable traced fork/scratch/merge/fragment, SubAgent trace helper persistent/temporary events, `ask_llm.completed`, and compression archive/applied query paths.
- Workspace remains draft with `validation.automated: passed`, `validation.human: not-run`, `archive_state: pending-review`; stable spec merge/accepted status is deferred pending independent review or explicit acceptance.
## 2026-07-07 — Session trace lineage automated validation and initial restart blocker
- TaskAdmin `master/24.6` ran aggregate automated validation for `.maxa/specs/changes/add-session-trace-lineage/`; focused Lua/headless checks passed for trace storage, lifecycle hooks, slash/fragment lineage, SubAgent propagation, compression archives, compact workflows, and module registration.
- Native restart-resume was initially blocked by safety precondition because another CodeCompanion chat was active; this blocker was later cleared by main-session restart-resume and post-restart smoke.
## 2026-07-06 — Session trace lineage draft

- Added draft SpecAdmin change workspace `.maxa/specs/changes/add-session-trace-lineage/` for explicit `/trace_start` lineage tracing across root/fork/scratch/SubAgent/resumed sessions, temporary child results, fragment insertion, merge actions, and compression archives.
- Captured user-confirmed requirements: root trace id equals main `save_id`; resumed histories continue the same trace; all tracked sessions record user prompt / Agent final reply / Agent error; `ask_llm` and `multi_agent` are tool-only trace events; `run_workflow` is out of scope.
- Updated `specs/index.md` and `specs/changes/index.md`; implementation and validation remain not run.

## 2026-07-05 — Save scratch slash command accepted

- Added and accepted SpecAdmin change workspace `.maxa/specs/changes/add-save-scratch-slash-command/` for `/save` scratch promotion semantics.
- Implemented `/save` so only the current `/scratch` temporary chat is promoted to a normal saved history session by replacing the unsavable scratch `save_id`, clearing scratch identity metadata, saving through the existing history extension, and letting existing auto-save handle later messages.
- Automated validation passed; user live review confirmed the feature works normally after the history API fallback fix.
- Updated `specs/index.md` and `specs/changes/index.md`; workspace remains retained in place as accepted trace context.

## 2026-07-04 — Optional Git workspace mode implementation
- Added `git-workspace` global skill with uv Python script for local single-user Git worktree workspace initialization, detection, creation, sync, status, check, cleanup, and TaskAdmin binding resolution.
- Added stable draft spec `specs/git-workspace-mode/spec.md`; updated `specs/index.md` and `specs/taskadmin-lifecycle/spec.md` for workspace binding checks.
- Updated TaskAdmin frontmatter/tag metadata support for flat `workspace: <name>` bindings; main task overrides tag and subtasks inherit parent main task binding.
- Automated validation passed; human acceptance remains pending, so `add-optional-git-workspace-mode` change workspace stays draft.

## 2026-07-04 — Obsidian DeepSeek translate plugin draft

- Added draft spec `specs/obsidian-deepseek-translate-plugin/spec.md` for a new Obsidian plugin that reuses `.maxa/translate-cache`, matches Neovim `buffer_translate.lua` SHA-256 key generation, and calls DeepSeek only on cache miss.
- Updated `specs/index.md` and `specs/maxa-runtime/spec.md` reachability links.
- User confirmed result display behavior: open in a fixed right-side split and reuse one translation result page; user also confirmed selection translation is unsupported and not future scope.

## 2026-07-04 — Draft change human review

- Recorded user-confirmed human spec review for `add-codecompanion-chat-fragments` and `spec-admin-taskadmin-integration` change workspaces.
- Kept both workspaces in `status: draft`; review pass does not replace implementation validation, manual interactive smoke testing, stable spec merge, or archive convergence gates.
- Updated `specs/changes/index.md` review notes for discoverability.

## 2026-07-03 — Picker slash command acceptance

- Accepted `add-pick-spec-slash-command` and `add-pick-article-slash-command` after user live validation in restarted Neovim confirmed both implementations meet requirements.
- Updated change lifecycle frontmatter, `specs/changes/index.md`, and validation records with `human: passed`, `automated: passed`, and `archive_state: retained`.

## 2026-07-03 — Pick article slash command implementation

- Implemented `/pick_article` registration, picker wrapper, and `util.maxa_articles` discovery/preview helper.
- Added `lua/util/maxa_articles_test.lua`; headless validation passed with 5 passed, 0 failed.
- Merged implemented behavior into `specs/chat-fragments-and-slash-commands/spec.md`; live Snacks picker validation remains pending before archive acceptance.

## 2026-07-03 — Pick article slash command draft

- Added draft SpecAdmin change workspace `.maxa/specs/changes/add-pick-article-slash-command/` for `/pick_article` article picker semantics.
- Updated `specs/index.md` and `specs/changes/index.md` so the draft change is discoverable.

## 2026-07-03 — Pick spec slash command implementation

- Implemented `/pick_spec` registration, picker wrapper, and `util.maxa_specs` discovery/preview helper.
- Added `lua/util/maxa_specs_test.lua`; headless validation passed with 4 passed, 0 failed.
- Merged implemented behavior into `specs/chat-fragments-and-slash-commands/spec.md`; live Snacks picker validation remains pending before archive acceptance.

## 2026-07-03 — Pick spec slash command draft

- Added draft SpecAdmin change workspace `.maxa/specs/changes/add-pick-spec-slash-command/` for `/pick_spec` picker semantics.
- Updated `specs/index.md` and `specs/changes/index.md` so the draft change is discoverable.

## 2026-07-03 — Index/log initialization

- Ensured `specs/index.md` and `specs/log.md` exist for root-level directory governance.

## 2026-08-27 — Chat upload workflow specification convergence

- Reconciled `add-chat-upload-workflow` proposal, design, and delta spec with the implemented trusted HTTPS/shared-certificate architecture, temporary Chat URL lifecycle, browser terminal UX, Uppy capabilities 1–19, public URL SSRF controls, current limits, and latest validation evidence.
- Updated root/change indexes to route future Agents to the current `dev.maxlena.com` contract rather than the retired HTTP/native-capture design.
- Workspace remains draft because target desktop/mobile media, screen/audio, image processing, URL import, refresh/removal, and Chat-close human validation is still pending.

## 2026-08-27 — Chat upload workflow implementation and automated validation

- Implemented `tools/chat-upload/` Node/Uppy service, `lua/util/codecompanion/chat_upload/` controller, `/upload` registration, and current/reusable Git/Obsidian/Syncthing upload-zone governance.
- Node build/check and 16 tests passed; Lua upload-controller suite passed with 10 tests; strict skill lint, JSON/static ignore checks, and `git diff --check` passed.
- After full Neovim restart, live runtime registration and a disposable private-LAN CLI/HTTP/Chat Submit flow passed, including dynamic URL, Chat lock/unlock, upload, terminal JSONL, and exact relative-path insertion.
- Fixed the real-browser Uppy 4 upload-event mismatch reported during live validation (`upload` emits `(uploadID, files)`, not an object with `fileIDs`), rebuilt the bundle, and added static regression coverage.
- Fixed the pinned `@uppy/xhr-upload` 4.4.2 response callback contract: `getResponseData` receives `XMLHttpRequest`, so response parsing now reads `response`/`responseText` instead of applying `JSON.parse` to the XHR object; stable HTTP errors remain preserved.
- Browser Submit/Cancel now waits for a successful terminal response, attempts `window.close()` without confirmation, and falls back to a control-free Chinese terminal page when browser policy blocks closing.
- The Chat now inserts a temporary `请使用这个地址上传文件：<URL>` line after service readiness; Submit replaces that exact line with relative paths, while Cancel, failure, and Chat close remove it.
- Added project-root shared Let's Encrypt certificate management for `dev.maxlena.com` through interactive Cloudflare DNS-01 recipes; Token input is hidden and ephemeral, while stable certificate paths remain Git-ignored.
- Upload service now requires the valid shared certificate, serves `https://dev.maxlena.com:<dynamic-port>/`, and exposes Uppy Webcam plus Audio inside Dashboard; custom capture inputs were removed.
- Expanded requested inputs 1–19: Webcam audio-only/device selection/recording length, Screen Capture with browser-provided screen/window/tab and audio choices, Image Editor, client image Compressor, and a streamed public-URL importer with redirect-aware SSRF guards; cloud/remote providers 20–29 remain excluded.
- Added automatic OS/browser light/dark theme matching through Dashboard `theme: "auto"`, `color-scheme`, semantic CSS variables, and `prefers-color-scheme`.
- Change remains draft pending real desktop/mobile HTTPS validation for Webcam/Audio permissions and recording plus refresh/removal UX, Cancel, and Chat-close behavior.

## 2026-08-29 — GDA Node3D transform property specification accepted
- Implemented one `node get/set` and `game get/set` command family with structured `Vector3`, named-vector `Basis`, complete `Transform3D`, local-only Node3D addressable properties, `transform` as the sole persisted authority, strict duplicate-key/finite/scale validation, and headless/live parity.
- Validation converged for the capability: non-E2E `1670 passed, 2 skipped`; maintained-baseline focused Node3D, schema/help/skill/static checks, and a GDA-only official Godot 4.7.2 3D authoring smoke passed. Current broad acceptance is owned by the latest GDA validation record.
- Merged accepted behavior to `specs/gda-property-values/spec.md`; retained `specs/changes/add-gda-node3d-transform-properties/` in place as accepted trace context and updated indexes.

## 2026-08-27 — load_image content detection and input normalization accepted
- Implemented decoded-content format identification, direct PNG/JPEG/WebP/single-frame GIF loading, 8-bit sRGB PNG normalization for other single-frame rasters, and explicit multi-image/PDF/SVG rejection.
- Automated validation passed: `load_image_spec.lua` 25/25, adapter injection 3/3, wrapper regressions, module load, stale extension-decision search, and `git diff --check`.
- Full Native restart-resume and live payload smokes passed. User authorized the active vision model to perform human acceptance; it accurately described both the arbitrary-extension JPEG photograph and normalized BMP gradient. Stable `mcpx-file-command-tools` requirements were merged and the change was accepted in place.

## 2026-08-27 — load_image content detection and input normalization specification
- Added draft SpecAdmin change workspace `specs/changes/normalize-load-image-input-format/` with proposal, technical design, implementation checklist, and `mcpx-file-command-tools` delta spec.
- Recorded user-approved behavior: content-only format detection; direct single-frame PNG/JPEG/WebP/GIF; other decodable single-frame rasters normalized to 8-bit sRGB PNG; multi-image, PDF, and SVG rejection; unchanged adapter scope and no compatibility path.
- Updated `specs/index.md` and `specs/changes/index.md`; implementation, automated validation, Native restart, live visual smokes, stable-spec merge, and lifecycle acceptance remain pending.

## 2026-08-27 — Chat upload workflow specification

- Added draft SpecAdmin change workspace `specs/changes/add-chat-upload-workflow/` with proposal, technical design, implementation checklist, and `chat-upload-workflow` delta spec.
- Recorded user-approved `/upload` behavior: dynamic LAN endpoint, Uppy multi-file page, completed native media capture, per-session persistence and refresh recovery, Chat lock, explicit Submit/Cancel, retained files, `2 GiB` per-file and `10 GiB` per-session limits, and plain project-relative path insertion.
- Updated `specs/index.md` and `specs/changes/index.md`; implementation, automated validation, Neovim reload, and desktop/mobile LAN live validation remain pending.

## 2026-08-03 — Project-scoped CodeCompanion defaults draft
- Added draft change workspace `specs/changes/add-project-codecompanion-defaults/` with proposal, design, implementation checklist, and runtime entrypoint delta spec.
- Recorded user-approved Global/Project picker scope switching, scope-local clear actions, project metadata storage, and per-new-Chat source-project resolution.
- Updated `specs/index.md` and `specs/changes/index.md`; implementation and validation remain pending.

## 2026-08-03 — Project-scoped CodeCompanion defaults implementation
- Implemented scoped global/project persistence, conservative `.maxa/_meta.yaml` owned-block editing, clear operations, and project > global > shared resolution.
- Added per-new-Chat source-project adapter injection while preserving explicit/restored adapters, plus Global/Project `<Tab>` picker switching and scope-local synthetic clear actions.
- Added focused state, hook, and UI headless tests: 13 passed, 0 failed; modified Lua files passed load checks and `git diff --check` passed.
- Live Neovim picker/two-project/restore smoke and stable-spec merge remain pending, so the change workspace stays draft.

## 2026-08-31 — GDA ADR/change convergence into stable specifications
- Promoted all implemented and user-validated GDA change deltas into stable normative specs, including `gda-scene-authoring` and `gda-live-operations`.
- Converted accepted ADR-owned behavior into stable specs for CLI/headless contracts, live runtime, project authoring, and quality/release; stable specs are now the sole current GDA behavior authority.
- Removed ADR/change path provenance from stable specs so they remain self-contained after cleanup; source traces now point to user acceptance and owning code/tests.
- Deleted GDA ADR documents and GDA change workspaces after stable-spec/index convergence; repository source comments may retain historical ADR labels as non-authoritative implementation annotations.
- Validation passed: stable-spec structure/path/reference checks, `git diff --check`, and focused GDA descriptor/schema/skill synchronization regression (`uv run python -m pytest -n 4 --dist worksteal ...`) with 130 passed in 4.65s after `uv sync --dev` restored the project development environment.

## 2026-09-07 — Project-local Neovim session specification
- Added `add-project-nvim-sessions` (Git history only) after source exploration and explicit user approval of global-cwd ownership. Proposal/design/checklist/delta define project-scoped APIs, branch slots, failures, and validation; no migration or global fallback.
- Specification only; runtime code unchanged, automated/manual implementation validation not run; stable specs not merged.

## 2026-09-07 — Project-local Neovim session implementation
- Implemented `add-project-nvim-sessions` (Git history only) with one durable implementation child, main-owned wiring and independent source/test verification.
- Focused persistence round-trip/failure tests, real LazyVim callbacks/restart-bootstrap wiring tests, formatting and diff checks passed. Human interaction and Windows replacement checks remain pending; draft retained without stable merge.


## 2026-09-07 — Temporary image analysis replacement specification
- Added `replace-load-image-with-analysis` (Git history only) after implementation exploration and user agreement: full inherited tools, fixed-prompt delegation prohibition, hard local model-request budget and report-only completion.
- Proposal/design/checklist/delta define no-window unsavable fork, image preparation reuse, parent isolation and one-release load_image removal. Specification only; runtime code unchanged, implementation tests not run, stable specs not merged.

## 2026-09-09 — GDA minimal project creation, resource discovery, and inline specification

- Added `add-gda-project-bootstrap-and-script-inline` (Git history only) after source/stable-spec exploration, feasibility analysis, and explicit user agreement on all three target boundaries.
- Defined two owning deltas: no-engine minimal project creation and .tres-only file listing; local execution metadata and full-source inline execution with existing script-run policy, unique managed entries, and explicit cleanup failure precedence.
- Delivery is specification-only: proposal, design/acceptance matrix, future checklist, recursive indexes, and validation record. No runtime code or active stable specification was changed; target behavior and final contract acceptance remain unvalidated.
- No transition or compatibility layer, project/game framework, binary resource catalog, automatic import, REPL, sandbox, side-effect rollback, or background cleanup service was added.


## 2026-09-09 — GDA three-command implementation and acceptance evidence

- Implemented `add-gda-project-bootstrap-and-script-inline` (Git history only) in the main session after explicit user authorization. One read-only reviewer was resumed for implementation review and repair verification; no child wrote source.
- Added local project create, file-only resource list, and full-source script inline through existing descriptors/recipes, with bounded shared owned-entry cleanup. Fixed reviewer findings for empty paths, excluded malformed root links, and identity-acquisition failure.
- Final Linux checks: 1792 non-E2E passed, 2 skipped; 113 official Godot 4.7.2-stable related E2E passed; 104 final focused/schema/skill cases passed; Ruff/format/Pyright/strict skill lint/diff checks passed. Exact evidence and existing warning are in the validation record.
- Workspace remains draft pending final human and macOS/Windows acceptance; active stable specs are not merged. No compatibility layer, new framework, unapproved feature, or real user game mutation.


## 2026-09-09 — GDA resource file discovery includes binary resources

- Applied the user-approved discovery amendment to `add-gda-project-bootstrap-and-script-inline` (Git history only): include .tres and .res case-insensitively; discovery remains engine-free and content-free, with existing traversal/error/output behavior.
- Resource create/get/set/delete remain .tres-only; no scene/source-asset/subresource catalog or binary editor was added. Delta/design/proposal/checklist, indexes, schema/help and bundled/global guidance were reconciled.
- Red proof: two listing failures before the change. Final focused/schema/skill/resource/E2E checks: 87 passed, including a real Godot-saved .res and unchanged get refusal. Full non-E2E: 1793 passed, 2 skipped, one existing fork warning; Ruff/format/Pyright/strict skill/diff checks passed.

## 2026-09-12 — Blender CLI inspection and documentation specification
- Added `extend-blender-cli-agent-inspection` (Git history only) after repository/knowledge/source exploration and explicit user scope agreement: runtime API lookup, pinned offline docs, saved-scene/object/dependency/file inspection, executor hardening and explicit saved-output verification.
- Proposal/design/checklist/delta and recursive indexes define one CLI-only implementation; no MCP/Live, dual backend, automatic docs updates, transition layer, storage/rollback system or benchmark framework. Existing exploratory Live idea remains unchanged and non-authoritative.
- Specification validation passed: targeted note title check (`uv run --project skills/obsidian python skills/obsidian/scripts/note_titles.py --vault .maxa/specs/changes/extend-blender-cli-agent-inspection --issues-only --format json`); file-side YAML/lifecycle/source-path/wikilink/index/size/whitespace checks; all seven requirement IDs referenced by the checklist; scoped Git diff check.
- Runtime code and skill guidance are unchanged; implementation/automated behavior/manual acceptance remain not-run, workspace stays draft, no stable spec merge or TaskAdmin operation. Validation is file-side only, not live Obsidian graph evidence.

## 2026-09-12 — Blender CLI implementation and independent verification
- Implemented `extend-blender-cli-agent-inspection` (Git history only) after explicit authorization, with one durable implementation session reused for repair and one independent reviewer reused for re-review. Main owns specification state and independently reran final validation.
- Added runtime API lookup, fixed offline API/manual snapshot, structured scene/object/library/file inspection, shared dependency verification, hardened one-shot execution and host-computed explicit saved-output checks; aligned existing help and skill guidance. No MCP/Live, dual backend, transition/service/framework or unrelated tests.
- Initial green tests missed three reproduced boundaries: camera-background ImageUser sequence offsets, faithful API string whitespace, and valid multi-MiB base64 frames. All repaired and independently reverified. Final main acceptance: 11 host tests + 9 Blender 5.2.1 inspection groups + 35 smoke checks, no failures/skips; Node syntax, targeted skill lint and scoped diff checks passed.
- Exact evidence, changed paths, limits and resumable child IDs are in `extend-blender-cli-agent-inspection` (Git history only). Workspace remains draft pending final human contract acceptance and stable merge; no TaskAdmin operations or Git commit.
## 2026-09-14 — mcpx promotion to Maxa Chat builtins specification
- Added `promote-mcpx-to-chat-builtins` (Git history only) after source/spec exploration and explicit user confirmation.
- The proposal/design/checklist/delta define one hard cut: migrate the current 21 `mcpx` tools into always-available bare-name Maxa Chat builtins, delete the 11 legacy builtins, remove the `mcpx` Native MCP server/group/prefix, and keep other MCP servers behind `server__tool` dispatch.
- No transition aliases, compatibility `req/res` shell, dual registration, history rewrite, generic tool framework, or unrelated MCP/Chat redesign is allowed.
- Delivery is specification-only. Runtime code, stable specs and historical accepted evidence are unchanged; implementation and runtime validation remain not-run.
## 2026-09-15 — Stable specification modularization and delta convergence

- Scope: completed the approved phase-two migration after full-text audit of all 310 Markdown files formerly under `specs/`; all 42 current change workspaces contributed only their final non-superseded behavior.
- Structure: replaced singleton top-level capability directories with 13 coarse modules routed by [[specs/index|the stable specification index]]: Runtime, MCP, External MCP, GDA, Godot Tooling, GenAI, Blender, Project Vault, TaskAdmin, AgentSkills, Prompts, Obsidian Plugins, and Services.
- GDA: consolidated every former `gda-*` stable directory under [[specs/gda/index|GDA]]; kept Neovim language tooling under [[specs/godot-tooling/index|Godot Tooling]].
- Convergence: repaired root-Vault path corruption, the 19/21 Chat builtin conflict, explicit compression authorization, final GenAI adapter ownership, image-analysis supersession, current source traces, and retired runtime names.
- Canonical builtin owner: [[specs/runtime/chat-builtins|Chat Builtins]] defines exactly 19 current names. Earlier dated log entries describing 21 tools, `execute`, `report`, `search_skill`, or public `mcpx__*` identities are superseded migration snapshots, not current behavior.
- Review: the user recorded human specification review as passed for every change on 2026-09-15. Automated, live, platform, visual, and environment evidence remains exactly `passed`, `partial`, `failed`, or `not-run` in the owning stable specification; no missing check was promoted to passed.
- Provenance: stable specifications do not depend on change-workspace links. Historical change identifiers are non-normative and recoverable from Git history.
- Retired artifact: removed the obsolete `bootstrap-promotion-review-plan.md`; its pre-promotion decisions remain recoverable from Git history and current validation limits live in the owning module specs.
- Phase boundary: `.maxa/specs/changes/` remains byte-for-byte untouched for phase-two acceptance. Permanent workspace deletion is deferred to the separately authorized final phase.
## 2026-09-17 — load_server-only MCP 与纯输入 mention 规格
- 在检查 MCPHub bridge、`load_server`/`call`、history restore、`@/#` runtime、所有 completion provider、Skill discovery 与 stable owners 后，用户确认完整 hard-cut 目标。
- 新增 `simplify-mcp-access-and-input-mentions` proposal 与五个 delta specs；关联唯一 TaskAdmin `master/3`。目标保留 MCPHub core，只以 exact-Chat `load_server` 授权和 namespaced `call`/`multicall` 提供 Agent MCP 访问。
- `@` 只补全 exact Chat non-MCP Tools 与可披露 Skills；`#` 只补全可披露 Skill resources。选择结果保持 literal `@name`/`#skill/path`，提交不解析、不替换、不产生 Tool/Skill/context/MCP 副作用。
- 明确删除 Maxa MCP bridge、MCP resources/prompts/slash registration、`#buffer/#lsp/#viewport` 展开、旧 brace markers 及全部 transition/compatibility behavior。
- File-side validation passed：六个 change artifacts 的 frontmatter/task identity/lifecycle、五个 delta 的 requirement/scenario presence、index/log routing、TaskAdmin `master/3` resolution 与 `git diff --check` 均通过。

## 2026-09-19 — 扩展 literal mention 的 MCP 名称、工具与资源目录
- 按用户澄清修订 `simplify-mcp-access-and-input-mentions` proposal、五个 delta specs 与 TaskAdmin `master/3`：`@` 现在补全全部 effective configured MCP Server 名称，即使 Server 未载入；只有 exact-Chat loaded Server 才额外披露 `@server__tool`。
- `#` 保留原有 Skill resource 补全，并增加 exact-Chat loaded Server 通过 `resources/list` 公开的 concrete resource metadata；未载入 Server、resource templates 与 resource content 不进入 MCP resource 候选。
- 新增独立 `mcp:server:<server>` exact-Chat 授权事实；`mcp:tools:<server>` 与 `mcp:resources:<server>` 仅作为持久化 completion catalogs，不能单独授权 dispatch/restore。
- 所有 MCP mention 仍为 literal text：选择或提交 `@server`、`@server__tool`、`#server/<resource-uri>` 不自动载入 Server、调用 Tool 或读取 Resource；Maxa MCP bridge 仍按原 proposal 删除。
- 当前仅发布规格与 TaskAdmin plan/TODO；runtime code 和 stable specs 未修改，implementation/automated runtime validation/fresh Neovim validation 均为 `not-run`，等待单独实施授权。

## 2026-09-19 — 主代理完成监听全局默认规格
- 在检查 listener、Chat 创建/历史恢复、SubAgent/helper 构造后标记、配置 owner、binding 互斥、focused tests、快捷键占用与稳定规格后，用户确认新增全局监听默认值。
- 新增 `add-global-completion-listener-default` proposal 与 `runtime-completion-notifications` delta；关联唯一 TaskAdmin `master/5`。共享配置 `interactions.chat.opts.notify_when_done_default` 默认 `false`，`lua/plugins/ai.lua` 不覆盖。
- 约定 `<leader>aN` 只切换当前 Neovim 进程中未来新建/恢复 eligible 主代理 Chat 的默认；已加载 Chat 的手动状态、当前 Chat `<leader>an`、SubAgent/隐藏图像分析/rescue helper 均不受影响。
- 监听状态和快捷切换值均不写入历史或其他 durable store；历史恢复每次使用当前有效默认值创建新 runtime state，不恢复旧 Chat 状态。
- 当前仅完成探索、TaskAdmin 创建与 draft spec 发布；runtime code、stable specs 和 runtime validation 均未修改/未运行。`<leader>aN` 的源码扫描与 configured headless `maparg()` 占用检查通过。

## 2026-09-19 — 主代理完成监听全局默认实现
- TaskAdmin `master/5` 实现 shared `interactions.chat.opts.notify_when_done_default=false`、listener-owned process default、scheduled `MaxaAIChatCreated` 初始化及 global normal-mode `<leader>aN`；`lua/plugins/ai.lua` 未覆盖配置默认值。
- 初始化只处理 future eligible 主代理 Chat；正深度 SubAgent、隐藏图像分析、rescue helper 被排除。全局切换不修改已加载 Chat，history metadata 仍不保存/恢复监听状态。
- 自动启用复用现有 Telegram binding 检查并保持 silent success；exact Chat liveness guard 阻止关闭/替换后的异步激活。既有 `<leader>an`、persistent listener、foreground/tmux、deduplication、binding 与 lualine 行为保持不变。
- Validation passed：affected `luac -p`；`tests/util_maxa_ai_notify_telegram_state_spec.lua`；`tests/maxa_ai_setup_atomic_test.lua` 6/6；configured default/keymap smoke；global diff/trailing-whitespace checks。
- Change 继续保持 `status: draft`；`validation.automated: passed`、`validation.human: not-run`。Stable owner 尚未合并，等待人类验收。

## 2026-09-19 — 主代理完成监听全局默认验收与收敛
- 用户在 reload/future-Chat 验收提示后明确选择“验收通过”；`add-global-completion-listener-default` proposal/delta 更新为 `status: accepted`、automated/human `passed`、`archive_state: retained`。
- Delta 已合并到 `.maxa/specs/runtime/plugin-entrypoints.md`：公共配置默认 `false`、`lua/plugins/ai.lua` 不覆盖、process-local `<leader>aN`、future-only eligible 主代理初始化、helper 排除、history non-persistence 与 binding/liveness guards 现在由稳定规格所有。
- Change index 已从 Active 移入 Accepted Retained；TaskAdmin `master/5` 在最终引用、lifecycle、stable merge 与 whitespace/diff 验证通过后完成。

## 2026-09-20 — MCP Server 显式激活与管理员禁用 draft
- 在核对 pinned `mcp-hub@4.2.1`、Lua Hub/project transport/config manager、Native Server、Chat `load_server`/dispatch/history/completion、现有测试和稳定规格后，确认当前 backend startup、history restore 与 authorized dispatch 会自动 ensure，且 start/stop 会持久化 Server-level `disabled`。
- 用户确认目标状态：MCPHub ready 时零 capability Server 连接；`load_server` 是 Agent/Chat 唯一激活入口；同 workspace 多 Chat 分离授权但共享连接；历史恢复不连接，authorized disconnected `call` 明确要求重新 `load_server`。
- 用户确认 effective `disabled=true` 为管理员禁止：从所有 MCP `@/#` 候选隐藏，阻止 load/call/multicall/UI/backend start；watched policy 禁用立即断开 active External Server；runtime 永不修改该字段。Project-local Native policy 不得全局破坏其他允许 workspace。
- 新增 `make-mcp-server-activation-explicit` proposal 与五个 delta specs，关联唯一 TaskAdmin `master/6`。当前仅完成文档发布；implementation、automated runtime validation 与 human validation 均为 `not-run`。

## 2026-09-20 — MCP Server 显式激活实现与自动验证
- 扩展 repository-pinned `mcp-hub@4.2.1` 确定性补丁：Maxa opt-in backend 只注册 Server，不自动连接；start/stop runtime-only；watched config 重建完整 connection/event forwarding，只重连此前 connected 且当前允许的 Server；start 完成后复核 policy 与 connection identity。Runtime 启动执行同一 fail-closed `--check`。
- Lua runtime 新增 exact-workspace side-effect-free `inspect_server`，移除 lifecycle config enable/write；history restore 不 ensure，namespaced dispatch 仅在 authorized+allowed+connected 时调用。Repository capability Native 初始 disconnected，MCPHub management control plane 保持 connected，UI start/stop 不授予 Chat 权限或改写 policy。
- Completion 过滤 effective `disabled=true` 的 Server/tool/resource；`load_server` 保留 first-load atomic context、same-Chat reconnect dedup 与 unchanged force-reload dedup。Disabled load 返回 owning config remedy。
- Focused MCPHub/Chat suites、live External start/stop/watched-disable、config-byte invariance、deterministic patch check 与 independent SubAgent re-review 通过。第一次 full restart 暴露 same-version legacy backend reuse，随后增加 backend health activation identity 及 process-global/project transport replacement；第二次 full restart 后所有 capability Servers disconnected，management control plane connected。
- Fresh runtime live 验证通过：restored authorized disconnected `subagent` call 明确要求 `load_server` 且不激活；重复 `load_server(subagent)` 仅 reconnect；`time` first load/call、runtime stop、disconnected call、repeat reconnect 通过；global config SHA-256 在 load/stop/reconnect/disabled reject 前后保持 `422f90e00e73003b6ee3744454de866de58bfea41b8988fa92ed63891af51431`；`mcp-bridge disabled=true` 不出现在 completion 且 load 被拒绝。
- Change 仍为 `status: draft`，automated validation 更新为 `passed`，human validation `not-run`；等待用户验收后 merge stable owners 并完成 TaskAdmin `master/6`。

## 2026-09-20 — MCP Server 显式激活验收与收敛
- 用户在 focused automation、两次 full restart-resume、fresh restored/External/disabled/config-hash 证据后明确选择“验收通过”。`make-mcp-server-activation-explicit` proposal 与五个 delta specs 更新为 `status: accepted`、automated/human `passed`、`archive_state: retained`。
- Delta 已合并到稳定 owners：`.maxa/specs/mcp/mcphub-runtime.md`、`.maxa/specs/runtime/chat-builtins.md`、`.maxa/specs/runtime/session-history.md`、`.maxa/specs/runtime/plugin-entrypoints.md`、`.maxa/specs/runtime/maxa-ai.md`。
- Stable behavior 现在明确区分 configured、exact-Chat authorized 与 runtime connected；`load_server` 是 Agent/Chat 唯一激活入口；history/dispatch 不自动连接；administrator `disabled=true` 隐藏并阻断 MCP 能力且 runtime 不改写配置；same-workspace Chats 分离授权并共享连接。
- Change index 已从 Active 移入 Accepted Retained；TaskAdmin `master/6` 在最终 lifecycle/reference/diff validation 后完成。

## 2026-09-21 — Wait 工具必填显示标题 draft
- 在核对 `wait` schema/handler、async registry、nested builtin dispatch、canonical Tool Display、focused tests、system prompt 与稳定 Runtime Chat Builtins 规格后，根因确认为 `wait` 缺少 `title` 参数且 formatter 仅为 `multicall` 读取标题；async registry 本身无缺陷。
- 用户明确选择将 `title` 设为必填非空字符串，与 `multicall.title` 保持相同的显示语义；标题只用于 pending/completed/restored Tool Display，不改变 `async_id` 查询、等待、timeout、consume 或 result payload。
- 新增 `add-wait-display-title` proposal 与 `runtime-chat-builtins` delta，关联唯一 TaskAdmin `master/7`。旧 title-less transcript 保留裸 `wait` 渲染兼容，但新的 direct/nested 调用必须拒绝缺失或空白标题。
- 当前仅完成探索、TaskAdmin 创建与 draft spec 发布；runtime code、stable spec、automated runtime validation 与 human validation 均未修改或运行，等待单独实施授权。

## 2026-09-21 — Wait 工具必填显示标题实现与自动验证
- `wait` schema 现将 `title` 与 `async_id` 同列为 required；handler 使用共享 required-string 校验封闭 nested builtin 绕过，async registry 和 result payload 未修改。Canonical formatter 对 `multicall|wait` 复用标题展示，并为旧 title-less transcript 保留裸名 fallback。
- 四个 async producer 的 follow-up message 与 `prompts/system.md` image-analysis 示例已改为传入简短标题；focused handler/display、call/multicall async、generated system-prompt contract 与 `git diff --check` 全部通过。
- Full Neovim restart-resume 后，当前 Chat 的 live `wait` schema 要求 `title`；async `run` → `wait(title="Verify wait title display", mode="wait", consume=true)` 成功并显示标题，nested `call(tool="wait")` 缺少标题时返回 `wait: title parameter is required. Please provide a valid value.`。
- Change 保持 `status: draft`；`validation.automated: passed`、`validation.human: not-run`。稳定规格尚未合并，等待人类验收。

## 2026-09-21 — Wait 工具必填显示标题验收与收敛
- 用户在 focused automation、full Neovim restart-resume、live active schema/display smoke 与 nested rejection 证据后明确选择“验收通过”。`add-wait-display-title` proposal/delta 更新为 `status: accepted`、automated/human `passed`、`archive_state: retained`。
- Delta 已合并到 `.maxa/specs/runtime/chat-builtins.md`：`wait` 要求 `async_id` 与简短非空 `title`，direct/nested 校验一致，标题仅影响 pending/completed/restored display，旧 title-less transcript 仅保留裸名渲染兼容。
- `.maxa/specs/runtime/image-analysis.md` 的异步 polling 示例已同步传入 `title` 与 `async_id`；change index 已移入 Accepted Retained，关联 TaskAdmin `master/7` 等待最终引用/diff 验证后完成。

## 2026-09-21 — Current change workspaces promoted and physically removed

- 用户明确声明 `.maxa/specs/changes/` 下全部 current changes 已通过人工审核，并要求晋升为正式 stable specs 后清理整个 changes 目录；该指令明确覆盖 SpecAdmin 默认的 `archive_state: retained` 原地保留行为。
- 十个既有 accepted changes 已完成 stable-owner 合并；`refactor-taskadmin-workspace-and-specadmin-ownership` 的 automated evidence 已于 2026-09-17 通过，当前用户声明补齐 final human change review。其 delta 已由 `.maxa/specs/taskadmin/core.md`、`.maxa/specs/taskadmin/browser-ui.md`、`.maxa/specs/skills/git-workspace.md` 与 `.maxa/specs/runtime/request-routing-and-skill-gate.md` 持有。
- TaskAdmin core、TaskAdmin Browser 与 Git Workspace stable owners 从 `authority: draft` / `status: experimental` 晋升为 `authority: accepted` / `status: active`；既有 automated evidence 保留，未声称新增独立 interactive Browser 或 live workspace creation/cleanup run。Request Routing owner 已是 accepted/active，保持不变。
- 永久删除的 11 个 change IDs：`accept-token-threshold-user-instructions`、`add-global-completion-listener-default`、`add-wait-display-title`、`make-mcp-server-activation-explicit`、`migrate-human-assist-to-ask`、`persist-chat-completion-notifications`、`refactor-taskadmin-workspace-and-specadmin-ownership`、`remove-invalid-call-tool`、`remove-workflow-support`、`route-token-threshold-by-session-type`、`simplify-mcp-access-and-input-mentions`。
- 未创建 `archive/` 或 retained workspace 副本；proposal、legacy design/tasks、delta 与 workspace-local lifecycle 仅通过 Git history 追溯。当前规范行为只从 stable module owners 读取；本次批量 lifecycle/cleanup 由 TaskAdmin `master/8` 记录。

## 2026-09-21 — Ability-owned MCP description overrides

- `unify-ability-runtime` draft removes the central `prompts/abilities/` cache/guidance surface. Live allowed MCP schemas remain structural authority; a same-named composite Ability may explicitly declare one root-confined `mcp.overrides` file containing only changed tool and parameter descriptions.
- The previous complete Sentry cache was already stale against the live Server (`cached=21`, `live=9`) and blocked loading. It is replaced by `abilities/sentry/` with package-owned guidance and nine concise live-name description overrides; implementation and focused validation remain owned by TaskAdmin `master/9`.
- A live `DumpSystemPrompt` audit retained only explicit standard/external Agent Skill terms and removed stale runtime `skill` ownership, local-resource, creator-routing and decision-tree wording from the generated prompt and its active instruction/template owners.
- The follow-up tracked-source audit removed retired dependency fields, `.maxa/skills` ignore paths, dead Skill-frontmatter parsing, Maxa Skill package/self-reference wording and Skill-named uv project identities. Explicit standard/external Agent Skill sources and pre-cut compatibility evidence remain unchanged.

## 2026-09-22 — Lua、fire 与 delete Tool Display draft

- 核对 builtin schema/handler、nested dispatch、canonical Tool Display、fold restore、focused tests 与稳定 Chat Builtins 规格后，根因确认为：`lua` 无 `title` schema/handler contract；formatter 未读取 `lua.title` 或 `fire.event`；delete 虽有单路径/数量摘要，但 fold 管线仅服务 SubAgent 与 `multicall`。
- 用户同意：新 `lua` 调用要求非空 display-only `title`，历史 title-less 调用保留裸 `lua`；`fire` 显示事件名；单路径 delete 保持 inline，多路径按请求数量折叠，展开最多 10 条，余量显示为 `… and N more items`。
- 创建 `improve-builtin-tool-display` proposal、`runtime-chat-builtins` delta 与唯一 TaskAdmin `master/10`。为避免与正在收敛同一稳定 owner 的 `unify-ability-runtime` 冲突，`master/10` 依赖 `master/9`。
- 当前仅完成探索、用户设计确认、TaskAdmin 创建与 draft spec 发布；runtime source、stable spec、automated implementation validation 与 human behavior validation 均未修改或运行，等待依赖完成及单独实施授权。

## 2026-09-22 — Lua、fire 与 delete Tool Display 实现及 headless 验证

- 用户随后明确要求立即实施并保持聚焦；`master/10` 的 runtime sequencing dependency 已移除。实现仅修改独立的 builtin schema/display owners，稳定 Chat Builtins 合并仍等待 `master/9` 的重叠收敛解决。
- `lua` 现要求 display-only 非空 `title`，schema 与 handler 同时校验；canonical formatter 显示 `lua "<title>"` 与 `fire <event>`，并保留历史无字段调用的裸名 fallback。
- 多路径 `delete` 现在从调用参数确定性生成 bounded fold：折叠标题继续使用请求数量，展开最多 10 条格式化路径并显示精确余量；direct/wrapped、live/restored 共用同一生成逻辑，不解析结果文本且未修改删除 handler。
- `execute_lua_spec`、17 项 Tool Display tests、builtin inventory 与 `git diff --check` 已通过。Full Neovim restart/resume 和 live schema/display smoke 尚待执行；draft change 尚未进入 human acceptance 或 stable merge。

## 2026-09-22 — Lua、fire 与 delete Tool Display fresh-runtime 验证

- Full Neovim restart/resume 已恢复同一 history-backed Chat；active `lua` schema 的 required fields 为 `title`、`code`，当前进程 formatter 返回 `lua "Inspect runtime"`、`fire TaskPhaseChanged`、单路径 `delete one.txt` 与多路径 `delete (2 items)`。
- Live 多项删除 smoke 创建两个 `.maxa/tmp/tool-display-smoke-*.tmp` 文件后通过 direct `delete` 成功清理，fold body 为两条有序路径且未留下 smoke 文件。`fire TaskPhaseChanged` 同时验证了事件名展示与完整 TaskAdmin lifecycle payload。
- Proposal/delta 更新为 automated `passed`、human `not-run`，TaskAdmin `master/10` 进入 review。等待人工行为验收；stable Chat Builtins merge 与最终完成仍等待 `master/9` 的重叠收敛解决。

## 2026-09-22 — Lua、fire 与 delete Tool Display 人工验收

- 用户在 focused automation、full Neovim restart/resume、active schema/formatter inspection 与 live multi-delete smoke 证据后明确选择“验收通过”；proposal/delta 的 human validation 更新为 `passed`。
- Change 继续保持 `status: draft`，TaskAdmin `master/10` 继续保持 `review`：`master/9` 尚在 review 且拥有同一稳定 Chat Builtins owner，当前不进行竞态 stable merge，也不虚假触发 TaskCompleted。
- 后续仅需在 `master/9` 收敛后重读 `.maxa/specs/runtime/chat-builtins.md`，合并本 delta、更新 lifecycle/index/log，并完成 `master/10`；已验证 runtime code 无需重复实现。

## 2026-09-22 — 主会话 Token 收尾预算 draft

- 根因确认：稳定生命周期规格和 `chat_token_threshold_decision.lua` 明确将普通主会话的 `尽快收尾` payload 当作自由文本 `continue`，因此不进入现有八请求 `begin_finish()` 预算；现有 silent compact 分支已可复用，无需修改 generic `ask`、Telegram Bridge 或压缩算法。
- 用户确认普通主会话初始决策应提供 `尽快收尾`、`压缩并继续`、`中断`；选择收尾后最多八次实际模型请求，自然完成则正常结束，预算耗尽则在安全边界直接中断并保持可手动恢复，不进入三轮 emergency、不再询问或执行压缩。SubAgent 保留现有 `8 + 3` 与最终显式 compact 流程。
- 用户同时要求主会话与子代理的 primary/emergency 收尾注入都明确禁止 Agent 自主调用压缩工具；只有用户明确选择 `压缩并继续` 才授权该 threshold 流程执行压缩。
- 创建 `enforce-main-chat-token-finish-budget` proposal、`runtime-lifecycle` delta 与唯一 TaskAdmin `master/13`。当前仅完成探索、用户方案确认、TaskAdmin 创建及 draft spec 发布；runtime source、stable specs 和 implementation validation 均未修改，等待后续实施。

## 2026-09-22 — 主会话 Token 收尾预算实现与自动验证

- `chat_token_threshold_decision.lua` 现将普通 `尽快收尾` payload 映射到共享 primary finish 状态，初始决策增加显式 `compact`，普通主会话按实际 dispatch 计数最多八轮；耗尽时取消 queued/new tool side effects、保留配对结果并直接中断，不进入 emergency、final ask 或 compression。SubAgent `8 + 3` 与最终 `interrupt|compact` 流程保持不变。
- Primary 与 SubAgent emergency 注入均明确禁止 Agent 自主调用压缩工具或发起压缩，并保留只有用户明确选择 `压缩并继续` 才授权该 threshold 压缩分支的边界。
- Focused unit suite 通过 `19 tests passed`；installed Chat/HTTP suite 在修正测试 helper 的 Lua `and nil or` 主会话构造错误后通过 `9 integration checks passed`；orchestrator queue guard 通过 `11 passed, 0 failed`；`git diff --check` 通过。Generic `ask`、Telegram Bridge 与 compression internals 未修改。
- Proposal/delta 的 automated validation 更新为 `passed`、human implementation acceptance 保持 `not-run`；稳定规格尚未合并，TaskAdmin `master/13` 等待人工实现验收。

## 2026-09-22 — 主会话 Token 收尾预算验收与收敛

- 用户在 focused unit/integration/orchestrator evidence 与行为摘要后明确选择“验收并完成”；`enforce-main-chat-token-finish-budget` proposal/delta 更新为 `status: accepted`、automated/human `passed`、`archive_state: retained`。
- Delta 已合并到 `.maxa/specs/runtime/lifecycle-and-message-injection.md` 与 `.maxa/specs/runtime/session-compression.md`：普通初始三选项、共享八请求计数、普通耗尽直接安全中断、SubAgent `8 + 3`、显式 compact 授权与所有 runtime finish message 禁止自主压缩均成为稳定行为。
- Change index 已移入 Accepted Retained；TaskAdmin `master/13` 在最终引用、测试与 diff validation 后完成。

## 2026-09-22 — Current Ability/Soul changes promoted and physically removed
- 用户明确声明 `.maxa/specs/changes/` 中全部现存规格已经通过人工验收，并要求晋升为正式规格后物理清理整个目录；该指令覆盖 accepted workspace 默认 `archive_state: retained` 行为，不创建 `archive/` 或其他副本。
- 按重叠 owner 依赖顺序先收敛 `unify-ability-runtime`，再收敛 `improve-builtin-tool-display`、`split-system-prompt-soul-runtime` 与 `unify-mcp-ability-discovery`；已 accepted 的 `enforce-main-chat-token-finish-budget` stable merge 保持不变。
- `unify-ability-runtime` 现由 `specs/skills/package-and-authoring.md`、`specs/runtime/request-routing-and-skill-gate.md`、`specs/runtime/chat-builtins.md`、`specs/runtime/lifecycle-and-message-injection.md`、`specs/runtime/session-history.md`、`specs/mcp/{mcphub-runtime,mcp-creator-workflow,mcp-doc-cache-contracts}.md` 与 `specs/project-vault/project-vault.md` 持有：Ability 是唯一 public capability，17-tool inventory、统一 `load`、机械 `@`/`#` 地址、AbilityHook、protected catalog lifecycle、project-local `.maxa/abilities/` 与 live-schema/package-owned MCP guidance 成为稳定合同。
- `improve-builtin-tool-display` 已合并到 `specs/runtime/chat-builtins.md`：required display-only `lua.title`、`fire <event>` 与 bounded multi-path delete fold 成为稳定行为。
- `split-system-prompt-soul-runtime` 已合并到 `specs/runtime/{overview,plugin-entrypoints}.md` 与 `specs/mcp/subagent-runtime.md`：common Runtime + exactly one Soul、project/explicit Soul precedence、truthful default/current dump、`soul_*` hard cut、new-format fork/resume preservation 与完整 Agency Soul consumption 成为稳定合同。
- `unify-mcp-ability-discovery` 已合并到 Ability package/routing/MCPHub owners：MCP-only optional `description`/`triggers`、described/name-only/disabled disclosure、zero-side-effect discovery、MCP-free authored `prompts/system.md` 与 Ability-owned pre-load rules 成为稳定行为。
- Linked TaskAdmin evidence：`master/9`、`master/10`、`master/11`、`master/12` 完成最终 stable convergence；`master/13` 保持此前已完成状态。所有已删除 proposal/delta/index 仅通过 Git history、本 log 与 linked TaskAdmin workspace 追溯。

## 2026-09-22 — Agency Soul 短路径与统一参数收敛

- 用户确认 Agency 角色采用 `abilities/agency-nexus/agents/<division>/<role>.md`，保留 division 防重名并移除 `assets/agents` 与冗余文件名前缀；旧 exact paths 不提供 alias。
- 46 个 imported role bodies 原样迁移；`agents/` 继续通过 `ABILITY.yaml.exclude` 隐藏于 parent catalog，同时精确 `#agency-nexus:/agents/...` 引用保持可读。
- `specs/mcp/subagent-runtime.md` 同步当前单一 public `soul` 参数、Ability/path/text 解析顺序、项目默认 Soul precedence、hidden exact-reference 与 Agency 短路径合同。
- Catalog/file audit、focused Neovim tests、Ability lint、live exact load、temporary `run_agent` (`SHORT_SOUL_OK`) 与 `git diff --check` 通过；human implementation review 为 `not-run`。
- Change `short-agency-soul-paths` accepted/retained；TaskAdmin owner 为 `master/14`。
## 2026-09-23 — Chat 消息冻结与工具/Rules 系统消息收敛草案
- 用户确认切换 adapter/model 时允许更新 UI、请求设置和元数据，但 `chat.messages` 不得变化；单工具注册保留，工具及 Rules 不得注入系统消息，工具组能力移除。
- 创建 linked TaskAdmin `master/18`，draft proposal `.maxa/specs/changes/immutable-chat-system-messages/proposal.md` 及 chat-runtime delta；当时仅记录目标行为，代码未修改，自动/人工验证均为 `not-run`，稳定规格待实现和验证后收敛。
## 2026-09-23 — Chat 消息冻结与工具/Rules 系统消息收敛
- Chat adapter/model 切换保持消息队列不变；单工具仍可注册但不注入系统消息，工具组名称与汇总提示词禁用；Rules 历史 `## System Prompt` 文本降为普通上下文。保存的历史消息不改写。
- `master/18` 的 focused Chat、tool inventory、Rules、Soul/system prompt contract、SubAgent inherit/utils 和 ordering tests 通过；旧 `tests/mcphub/maxa_ai/tools/fork_agent_spec.lua` 在与改动无关的 `.run` 旧接口处失败，记录于 TaskAdmin TODO；人工验收 `not-run`。
- `immutable-chat-system-messages` accepted/retained，delta 合并至 `specs/runtime/{maxa-ai,plugin-entrypoints}.md` 与 `specs/mcp/subagent-runtime.md`；自动验证 `passed`，人工验证 `not-run`。

## 2026-09-25 — 现存 accepted changes 晋升确认与物理清理

- 用户确认 `.maxa/specs/changes/` 中的规则变更全部通过人工审核，并要求正式化、清理目录。14 个 proposal/delta 原已 `accepted`，`merged_to` 稳定 owner 均存在，关联 TaskAdmin 计划可解析且任务已完成；本次沿用已收敛的稳定规则，不重复实现/验证，也不将此前 `human: not-run` 的实现验证追溯性改写为通过。显式删除请求覆盖 `archive_state: retained` 默认值；proposal、delta、changes 索引与日志均由 Git history 保存，不另建副本。
- 已删除 ID 与稳定 owner／原 TaskAdmin：
  - `ability-catalog-default-filtering` → `skills/package-and-authoring.md` (`master/15`); `short-agency-soul-paths` → `mcp/subagent-runtime.md` (`master/14`).
  - `background-preset-default` (`master/20`), `lazy-opts-named-presets` (`master/28`), `provider-model-recovery` (`master/23`) → `runtime/plugin-entrypoints.md`.
  - `expose-git-workspace-model-context` → `skills/git-workspace.md`, `runtime/plugin-entrypoints.md` (`master/17`); `sync-workspace-taskadmin-tags` → `skills/git-workspace.md` (`master/26`).
  - `fixed-project-rules-and-chat-souls` → `runtime/{maxa-ai,plugin-entrypoints,chat-commands}.md`, `mcp/subagent-runtime.md` (`master/29`).
  - `immutable-chat-system-messages` → `runtime/{maxa-ai,plugin-entrypoints}.md`, `mcp/subagent-runtime.md` (`master/18`).
  - `integrate-mcphub-into-maxa-ai` → `mcp/mcphub-runtime.md`, `runtime/{maxa-ai,plugin-entrypoints}.md` (`master/24`).
  - `provider-owned-adapters` → `runtime/plugin-entrypoints.md`, `genai/native-mcp.md` (`master/22`); `provider-scoped-proxy` → `runtime/{plugin-entrypoints,maxa-ai}.md`, `genai/native-mcp.md` (`master/27`).
  - `unify-ai-lua-config` → `runtime/{plugin-entrypoints,chat-commands}.md`, `genai/native-mcp.md`, `mcp/subagent-runtime.md` (`master/19`).
  - `warn-repeated-expired-read` → `runtime/chat-builtins.md` (`master/21`).
- 根索引不再路由已删除的 `changes/`；稳定规格的活动 `sources`/链接改为源码或 Git/TaskAdmin 历史追溯。此次清理证据由 TaskAdmin `master/30` 保存。
- 2026-09-28：`defer-rewind-history-save` 经实际已保存 Chat 的回退/关闭重开/新消息提交路径验证，接受并合并到 `runtime/chat-commands.md`；TaskAdmin `master/35` 负责实现与详细证据，change workspace 保留。
## 2026-09-28 — Chat search/glob 内置工具草案
- 用户确认 `scope` 字符串解析、`@xxx` 已安装 Ability、文件型 `search`、目录型 `glob`、数组模式、`no_ignore`、不限条数与超大输出临时文件，并选择覆盖主要 `rg` 用法；仅授权文档定稿，尚未授权代码实施。
- `add-chat-search-glob-tools` proposal/delta 保持 `draft`，TaskAdmin `master/36` 负责文档及详细检查；当时稳定的 17-tool owner 和当前工具注册不变，待实施/验证后再收敛。
## 2026-09-29 — Chat search/glob 实施及稳定规格收敛
- 用户随后授权在主会话实施并合理使用子代理；子代理只读核对 Ability 解析与 Windows 桥接，主会话实现两个 Chat 内置工具及共用的跨系统 `rg` 路由、过滤和大结果临时文件。
- `master/36` 记录 focused inventory/restore/schema checks、WSL/Windows 实际调用、文件/Ability scope、ignore/hidden 独立性及结果溢出读取。`add-chat-search-glob-tools` proposal/delta accepted/retained，合并至 `runtime/chat-builtins.md`；自动验证通过，人工实施验收 `not-run`。
## 2026-09-29 — search/glob 单行 Tool Display
- 实际 Chat 中直接与 `call` 包装的 `search`/`glob` 只显示工具名，根因是 `display.lua:format_tool_detail` 缺少对应参数摘要分支；已有流程不显示结果正文，也没有搜索专属折叠。
- `master/37` 增加首模式、额外模式数量、scope 与 `search.output=files` 的单行摘要。重启后在实际 Chat 核对直接/包装调用、空 glob 模式、多模式及默认 scope；focused display suite 18 项通过。`search-glob-tool-display` accepted/retained，合并至 `runtime/chat-builtins.md`，自动验证通过、人工实施审阅 `not-run`。
## 2026-09-29 — Telegram notify-only 会话输入草案
- 用户同意以 notify 监听取代绑定：空闲 Chat 可接收本地/TG 输入；运行中普通 TG 输入立即拒绝，`@ask` 仍可响应；TG 仅保留 `/ping`、`/sessions`、`/clean_tracked_topics`；旧 Bridge binding 记录仅从数据库清理，不删除 TG 主题或消息。
- 创建 linked TaskAdmin `master/44` 及 `telegram-notify-only-chat-input` proposal/两份 delta；本轮仅完成文档，代码、自动验证与人工交互均未执行，稳定规格未覆盖草案，等待后续单独授权实施。

## 2026-10-03 — 工具自定义显示与 SubAgent 实时父子详情草案
- 用户在代码/规格/知识探索后确认最小方案：工具生成内容，Chat 提供调用级 show/input/detail；Native 保留本地定义与不透明句柄，父调用下以 `└─` 实时展示最新 child 工具摘要。无需旧显示接口兼容，不增加组件树、多层详情、活动历史或异步后台回填。
- 创建 TaskAdmin `master/61` 及 `unify-tool-presentation` draft proposal/三份 delta，分别关联 Chat Builtins、MCPHub runtime 和 SubAgent runtime；具体实施步骤与验收命令仅在任务 plan/TODO。
- 本轮仅文档；运行时代码、公开 schema 与稳定规格正文未变。实施自动/人工验证均为 `not-run`；等待后续明确执行请求。

## 2026-10-03 — 活跃 blocking wait 工具显示接续草案扩展
- 用户在同一 `master/61` 追加授权：仅 `wait(mode=wait)` 接续原 async run/shell/multirun 的工具自有视图、原摘要及既有单层 child detail，并接收原终态 blocks/folds；`mode=try` 不附快照/订阅。两层固定缩进不构成通用树，不回填原提交行、不重执行工具。
- 扩展已有 proposal、Chat/SubAgent deltas、计划与索引；既有 JSON/consume/timeout=0/session-local terminal/cancellation 保持。详细代码/检查与后续实际 wait 证据只归任务 TODO；稳定规格不改，扩展仍为 draft 待 fresh runtime 验收。

## 2026-10-03 — 完整代理目标显示与批次运行态草案
- 用户确认 run/multirun 完整代理所有目标显示，multirun 全成员独立实时更新、运行展开/全部终态后折叠，async blocking wait 复用同一显示，批次预拒绝交互工具。
- 创建 linked TaskAdmin `master/62` 与 `proxy-all-tool-presentations` draft proposal/delta；现有 single-winner/文本压平/fixed-wait 约束待实现验证后替换，不提前覆盖稳定规格。
