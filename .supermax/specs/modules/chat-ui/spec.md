---
title: SuperMax Chat View and Input Surface
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/chat-lifecycle/spec.md
---

# Contract

Chat is the only conversational view. It renders normalized messages, tool projections, status, errors, context notices and dynamic project/provider/model introduction. It accepts user text, context attachments and Chat-owned Action/Command invocations.

The runtime MUST NOT require the Neovim command-input Chat mode as an alternative surface. `CodeCompanionCmd`-style separate command interaction is removed; this does not remove the Command abstraction or commands dispatched from Chat/actions.

## View lifecycle

A view can attach, detach, reattach and close independently of its session. Multi-line virtual text, buffer validity, input snapshots and asynchronous render callbacks are guarded by view generation. Dynamic intro content reflects project root, provider and model without becoming session source data.

Rendering failures are isolated from request execution and reported through spine/events. The view consumes snapshots/events; it does not infer orchestration state by reading CodeCompanion object internals.

## View model

A view owns `view_id`, `session_id`, generation, buffer/window handles, layout, cursor/input snapshot, render revision and disposable extmarks/timers/autocmds. Session messages and orchestration state are read-only inputs. One session may have zero or one primary editable Chat view; additional read-only projections require explicit support.

`hide` removes/focus-switches the window but keeps the view attachment. Buffer deletion detaches the view. `close view` disposes view resources but does not close the session. `close session` is a separate explicit Action that closes all views and owned runtime work. Reattach creates a new view generation and full snapshot render; late callbacks from an earlier generation are ignored.

## Rendering

- Render visible normalized user/assistant messages in order; hidden/system/project/provider records never leak unless a debug projection explicitly requests them.
- Reasoning, context and tool details use typed collapsible blocks with stable IDs.
- Streaming deltas append only to the matching render revision/message part. Re-render from snapshot is always possible and yields equivalent visible content.
- Dynamic intro/provider/model/project labels are projection metadata, not persisted conversation messages.
- Tool display Markdown/raw detail cannot mutate provider-facing or durable result content.
- Invalid/deleted buffers cause view detach/cleanup, not request failure.

## Input

The editable user region has one captured revision. Submit atomically captures visible text, selected context IDs, attachments and invoked inline Chat Commands, validates them through `message-context-target`, then marks that revision submitted. Text typed after capture belongs to the next revision.

Completion/pickers insert declared Action/Command/context references; they do not execute from stale view generations. Normal and visual entrypoints create/focus Chat and snapshot visual context. Provider/model selection changes session configuration only at a safe request boundary.

## Host integration

Layouts are `vertical`, `horizontal`, `float`, or current `buffer`. Keymaps/actions are registry entries, not hard-coded orchestration callbacks. Accessibility/plain-text fallback preserves all status/error/tool outcomes without relying solely on highlights/icons. Lualine/spinner consume spine separately; Chat rendering does not own global status.

View/input/render fixtures are normative in `../../runtime-fixture-contract.md`.

---

## 验证状态（2026-08-05，阶段 1.5 Chat UI 现代化）

> 本小节记录 host 实现证据；契约本身仍为 draft。按 AGENTS.md 门禁，模块保持
> `status: partial`，直至 validation-matrix 对应 fixture 行有可执行测试。

已落地实现与验证（全部 headless 可复跑，主会话 2026-08-05 全量回归绿）：

| 契约点 | 实现证据 | 验证 |
| --- | --- | --- |
| 增量 append + re-render equivalence | `host/nvim/render.lua` `apply`（prefix/suffix diff，`nvim_buf_set_text` 原位追加） | `tests/ui/render.lua` B（8 delta = 8 append，0 rewrite）+ A（快照等价） |
| 布局/layout（float 形态） | `View:open` snacks float 布局（chat + input） | 人工；layout 枚举在 config ui 块 |
| typed collapsible blocks with stable IDs | `### Reasoning` 真实 level-1 fold（`render.fold_bind`/`maxa_chat_foldexpr`/foldtext 摘要）；markers 带 `id`（reasoning:<n>/tool:<call_id>） | `tests/ui/render.lua` E（foldclosed/foldtextresult/zo·zc）+ `tests/ui/actions.lua` A |
| Keymaps/actions 为 registry entries | `M.KEYMAPS` + `View:_register_keymaps`（12 项，chat/input buffer-local） | `tests/ui/actions.lua` A/B/D |
| Lualine/spinner 渲染分离 | `host/nvim/status.lua`（只读 `View:projection` + `lualine_component` + 时钟派生 spinner 帧） | `tests/ui/status.lua` A/B/C |
| 输入区（一体式，无独立输入窗） | 单 chat buffer：输入头 + 用户区在渲染区之后（`_render_end` 边界，`render.apply` 渲染区 diff；`View:_init_input_area`/`_submit_from_input`/`_history_nav`/`_attach_selection`；多行输入 float 自适应） | `tests/ui/input.lua` A/B/C + `tests/ui/render.lua` A/B/E |
| ui.show_reasoning 配置接线 | LazyVim opts `ui.show_reasoning` 经 `config.configure` 合并校验 → `host.set_defaults`（默认值在 `lua/maxa/init.lua` `M.defaults.ui`） | `tests/ui/config.lua` A/B |

未落地（依赖后续阶段，plan.md 已标注）：工具输出折叠与结果详情卡片（阶段3 工具运行时）；
会话列表/切换（阶段4）；layout 非 float 形态与 input revision 完整化（阶段5 收口）。
