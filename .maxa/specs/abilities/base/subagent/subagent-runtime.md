---
title: SubAgent Native MCP Runtime 稳定规格
created: 2026-06-28
updated: 2026-10-13
type: source
doc_role: spec
authority: stable
status: stable
capability: subagent-runtime
validation:
  specification: passed
  automated: passed
  live: passed
  human: passed
sources:
  - prompts/system.md
  - prompts/soul.md
  - abilities/subagent/SYSTEM.md
  - abilities/subagent/SKILL.md
  - abilities/agency-nexus/SKILL.md
  - abilities/agency-nexus/agents/
  - lua/maxa/mcphub/native_servers/subagent/init.lua
  - lua/maxa/mcphub/native_servers/subagent/config.lua
  - lua/maxa/mcphub/native_servers/subagent/utils.lua
  - lua/maxa/mcphub/native_servers/subagent/async_cancel.lua
  - lua/maxa/mcphub/native_servers/subagent/fork_context.lua
  - lua/maxa/mcphub/native_servers/subagent/tools/
  - lua/maxa/mcphub/native_servers/shared/streaming_llm.lua
  - lua/maxa/lifecycle/chat_soft_stop.lua
confidence: high
---

## Purpose And Ownership

This owner governs bounded execution, forks, saved continuation, discussion and handoff under `lua/maxa/mcphub/native_servers/subagent/**`. Registration SHALL expose exactly `run_agent`, `fork_agent`, `resume_agent`, `handoff` and `multi_agent`; invocation requires a loaded catalog and exact Chat/workspace authorization. Maintained but unregistered tools remain unavailable. [Runtime Overview](../../../runtime/overview.md) owns shared Runtime/Soul meaning; [Chat Builtins](../../../runtime/chat-builtins.md) owns outer `call`/`multicall` async lifecycle. The retirement rule below owns `ask_llm` removal.

## Routing And Delegation

### Requirement: SubAgent tools require the SubAgent Ability gate

Before any SubAgent MCP tool, an Agent SHALL load `subagent`. This same-name composite MUST supply guidance, references and existing Native tools through one `merge: true` load, with no self dependency or `subagent-admin` compatibility entry. Agency Soul selection and multi_agent additionally require `agency-nexus`. Active instructions/source references MUST use the new name; historical records need not change. Tool addresses, schemas, delegation boundaries and companion conditions remain unchanged.

### Requirement: Task-specific child context preparation

- **Task-specific child context**: Before constructing run/resume/shared discussion messages, the main Agent MUST identify required Abilities/scenario references, project rules/specs/source evidence and settled decisions/constraints. Deliver the bounded goal's necessary context through structured tool_call loads and ordinary/context background; parent loading alone does not establish a fresh child's guidance/catalog/authorization, and unrelated material MUST NOT be preloaded.
- **Context delivery and continuity**: Root loading does not read all references. Resume MUST pass its capacity gate and add only missing/new context; fork MUST reuse inherited context without duplication; multi_agent MUST separate common background from participant-specific restrictions. The background-call and shared-discussion requirements govern preloads; context grants no additional scope/approval.
- **Executable context guidance**: The composite Skill MUST include concise new-run, resume-supplement and shared-discussion examples using `{role:"tool_call", name:"load", args:{target:...}}`, exact available references and bounded goals/return conditions. Reusable preparation sessions MAY preload and stop at readiness; they MUST NOT perform downstream work or create unrelated plans/artifacts.

### Requirement: Delegation is optional and independently bounded

The main session remains the default for implementation, continuous debugging and validation dependent on accumulated state. Delegate only independent, bounded, verifiable subproblems. Nested delegation SHALL be smaller, explicitly owned and have a stop condition; a child SHALL NOT pass through its assignment unchanged.

### Requirement: The main Agent verifies child output

Child conclusions are evidence, not completion. The main Agent SHALL inspect source/artifacts, reconcile scope and run applicable validation; cancelled/partial output SHALL NOT establish success.

### Requirement: Messages are pure task descriptions

Ordinary messages and fork goals SHALL state goal, scope, sources, constraints, stop condition and return format—not instructions to call SubAgent tools, command wrappers or invented expansion syntax. Preloads use supported context messages rather than repeated file bodies; `role="tool_call"` entries are structured runtime requests, not task text/slash commands.

### Requirement: SubAgent arbitrary Rules input is retired

`run_agent`/`resume_agent` schemas and validation SHALL reject new `role="context", type="rules"` messages before launch without reading arbitrary Rules-file paths. `file`, `symbols`, `url`, `image` remain independently usable; historical Rules messages MAY remain saved context but cannot enable the retired input.

## Soul And Composition Contract

### Requirement: One public Soul source parameter owns source selection

`run_agent` SHALL expose one optional `soul` string. Maintained multi_agent participant/final-agent schemas, parsers, errors, trace labels, instructions and examples SHALL use that same public name. Resolve in order:

1. Exact `#ability[/path]`: root-confined Ability file.
2. Explicit absolute, `~/`, `./` or `../` path: file; relative paths use the Chat-owned project root.
3. Other nonblank string: complete inline Soul.

Missing/unreadable/empty selected sources SHALL fail without fallback; matching reference/path syntax SHALL NOT become inline text. Message `role` and participant descriptive `role` are unchanged. Retired `role_*` source inputs (`role_file`/`role_prompt`) SHALL fail before dispatch. Internal-only `soul_prompt`/`soul_file` remain mutually exclusive with `soul`, preserve literal/file semantics and stay out of public schemas. Goals and retired `instructions` follow Tool Contracts, not Soul selection.

### Requirement: `run_agent` composes a Soul without replacing Runtime

The host SHALL compose common Runtime, exactly one effective Soul and target environment. A custom Soul replaces only Soul; execution/discussion instructions remain user background, not system supplements. Inheritance from separate initial Runtime/Soul messages SHALL preserve their effective composition and selected Soul without duplicating a default; legacy combined parents remain supported. Bare Soul SHALL NOT replace Runtime.

| Inputs | Effective behavior |
| --- | --- |
| Valid parent; no explicit `inherit` or Soul override | Inherit parent selected Soul, tools and loaded context. |
| Soul input; no explicit `inherit` | Independent mode with explicit Soul. |
| `inherit=false` | Independent mode with explicit or project/default Soul. |
| No parent and no override | Independent mode with project/default Soul. |
| Valid parent; effective `inherit=true` plus Soul | Reject conflict. |
| `inherit=true` without parent | Preserve inference to independent mode. |
| `restrict_tools` | Restrict actual tools only; no change to Soul/context/model inheritance inference. |
| `goal_prompt` / background `messages` | User input; no change to inheritance inference/system composition. |

Without explicit Soul, precedence is `.maxa/soul.md` → root `soul` in `.maxa/_meta.yaml` → shared `prompts/soul.md`; an existing invalid higher-priority source fails rather than falling through. Metadata legacy projection/migration follows the [Runtime owner](../../../runtime/plugin-entrypoints.md#requirement-project-configuration-reuses-existing-metadata). Adapter/model, titles, modes, recursion, cancellation and completion retain their separate contracts.

### Requirement: New-format fork and resume preserve complete composition

For sessions created under this contract, fork SHALL preserve effective parent Runtime/Soul, including separate initial messages, and inherited history without duplicate default injection. Resume SHALL restore saved effective composition, not current default Soul or bare Soul as the entire system prompt. Existing latest-boundary, read-only history, tool reconciliation and saved-identity behavior remain; no legacy conversion, transcript rewrite or prompt-version registry is implied.

### Requirement: Existing discussion and final-run sources share composition

multi_agent participants/final runs MUST use common composition and public `soul`. Final fork preserves effective parent composition; final run replaces Runtime/Soul together with inherited/selected composition, without duplicate default Soul. Host discussion rules remain user background/final goals, not system supplements.

### Requirement: Agency Souls use short exact references and retain complete content

`abilities/agency-nexus/agents/<division>/<role>.md` files are complete Souls; canonical references use `#agency-nexus:/agents/<division>/<role>.md`. Division directories avoid collisions; filenames omit redundant division prefixes. `ABILITY.yaml.exclude` hides `agents/` from the parent catalog but SHALL NOT prevent exact root-confined reads; old `assets/agents/` references have no aliases.

Selection through `soul` SHALL preserve identity, expertise, methods, communication character, cases, code/templates and tool preferences. Runtime/orchestration SHALL NOT automatically summarize/truncate/strip examples or impose arbitrary length targets. Examples confer neither authorization nor applicability of sample endpoints/metrics. Inline Soul is available, not a compulsory lossy conversion of a file.

### Requirement: Correct only incompatible Agency tool protocols

Agency materials SHALL use current Maxa tool names, Ability loading/addressing, schemas and authorization. Correct retired syntax at its owner while preserving professional workflow, examples and personality. Generic availability defers to Runtime; unrelated behavior changes require separate authorization.

## Tool Contracts

Invalid/missing title, messages, save id, Soul source, mode, adapter or restrictions MUST fail before unsafe execution where possible; the rules below define valid input. Setup/provider/tool errors preserve exactly-once completion and cleanup.

### Requirement: Current goal is the last user message

`run_agent`/`resume_agent` MUST require nonblank `goal_prompt`. Optional `messages` preserve user/assistant background roles and preload supported context/tool_call entries before the goal. Run, fork, resume, discussion turns and final execution MUST place the current goal as the final user message before dispatch, without changing system composition/inherit inference. Rendering-only placeholders MUST NOT enter the API transcript; backgrounds without tool_call entries retain existing order/behavior.

### Requirement: Explicit background tool calls

- **Explicit background tool calls**: `messages` MAY include `{role:"tool_call", name:<registered bare tool name>, args:<parameter object>}`. Both name/args are required; supplied results, IDs or authorization metadata MUST be rejected. Names are not limited to load; Ability actions remain nested through run(scope="tool").
- **Real ordered execution**: Runtime MUST execute in the target Chat under existing parameter validation, available-tool restrictions, approvals, Ability authorization and cancellation. Generate canonical assistant-call/tool-result pairs and commit deferred context before the next entry; dispatch the goal only after the ordered background completes. Preloading MUST NOT auto-submit model requests or consume LLM response turns.
- **Background failure boundary**: Failure/cancellation MUST stop later entries and model/goal dispatch, preserve actual completed/error history and discard uncommitted context. Late callbacks MUST NOT complete twice or mutate settled results; completed side effects are not rolled back.

### Requirement: Instructions input is retired

Child/discussion APIs MUST reject `instructions` before execution, never silently reinterpret it; migration guidance points ordinary/participant callers to `goal_prompt` and final configuration callers to `final_prompt`. Replacements follow common composition/final-goal rules.

### Requirement: Shared discussion background

Optional `multi_agent.messages` accepts user/assistant/context and structured tool_call entries. Before participant dispatch, the host MUST execute shared calls serially once in the Display/final Chat with caller-available tools and exact project context. Deep-copy the completed snapshot—including canonical call/result pairs and committed Ability context—to participants and Display/final Chat without replaying side effects; participant restrictions remain independent.

Persist/restore snapshot and task/final configuration for continuation. New messages append to existing background; only new calls execute. Final fork/run retain shared background and public discussion before final_prompt; private notes stay target-only. Participant goal_prompt defaults to task and ends every turn, including retries.

### Requirement: Discussion adapter presets match child presets

Participant/final-run `preset` MUST use run_agent's parent-aware named Chat resolver, including inherit-style settings overrides. Unknown/wrong-type names fail before dispatch; omission inherits parent, then `defaults.chat` without parent. Legacy `adapter` remains compatibility-only; conflicting selectors fail. Final fork preserves parent adapter/tools.

### Requirement: Handoff counts the current public contribution

After validating public speech, handoff to user MUST count that contribution toward min_rounds; rejected calls MUST NOT increment stored counts. Default min_rounds=1 permits the first valid contribution to finish. Missing-handoff retries request public text before the tool with current goal last. An unmet minimum suggests actual participants, or self when alone; exact-participant/private-note boundaries remain.

### Requirement: Optional execution controls are omitted by default

Absent user intent/task-semantic need, omit `inherit`, `preset`, `restrict_tools`, `soul`, `max_turns`, modes and `warmup`; required goals/identifiers are task inputs, optional `messages` background.

- `preset` explicitly selects an arbitrary named `type="chat"` configuration. Unknown/wrong-type names fail. Omission inherits source Chat or `defaults.chat` without source; resume omission preserves restored adapter/model. No `default_agent` registry entry is required; untyped legacy `default_agent` remains compatibility-only. Legacy `adapter` MAY select the same name; conflicting fields fail.
- `restrict_tools` is inheritance-neutral as above; it accepts registered bare first-party builtin names, not retired Chat tool-group names or their expansion. Ordinary individual names remain valid; Ability targets remain nested through `run(scope="tool")`.
- `warmup` is not a speed/token shortcut.

### Requirement: `run_agent` creates an autonomous child session

`run_agent` requires a concise title and the shared goal/background contract; `run_mode` defaults to `new_chat`.

| Mode | Execution |
| --- | --- |
| `new_chat`, `temporary` | Fresh child without full parent history; shared composition/inheritance, waiting/cancellation, results and cleanup apply. Temporary results have no resumable ID. |
| `handoff` | Fresh main or same-parent child successor selected from the exact caller's active execution type; preparation/transfer/completion follow the two sections below, not ordinary parent waiting. |

### Main-session handoff

The permission, caller, context, acknowledgement and preparation-failure rules below govern both handoff types; the safe main-switch rule governs main transfer, and Child-session handoff owns child replacement.

- **User-requested session handoff only**: Main transfer requires an explicit user request; child transfer requires an explicit user-message instruction from its main Agent or user. For suitable settled work/context migration, the main Agent SHALL issue that instruction through `resume_agent.goal_prompt` after the child's stage result/context_status rather than start a replacement `run_agent`. Token percentage, complexity, errors or ordinary continuation MUST NOT authorize self-transfer. Each instruction authorizes one transfer, not later handoffs/compression. `SYSTEM.md` owns permission/identity; `SKILL.md` workflow. No model-supplied authorization flag is introduced.
- **Type-preserving handoff caller**: Before target creation/preloads, validate the exact invoking Chat. Main callers retain independent-main transfer. A persistent ordinary run_agent/fork_agent/resume_agent child with active delegated executor and live current invocation parent MAY transfer to a sibling. Historical identity without active execution, temporary children and dedicated discussion/image controllers MUST fail without promotion. Missing exact caller MUST fail without current/last Chat guessing.
- **File-backed handoff context**: For substantial state, the Agent MUST write necessary goal/scope/permissions, decisions, modified paths, errors, exact validation and next action to semantic files under `.maxa/drafts/`; pass required files as `{role:"context", type:"file", path:...}` with a concise self-contained `goal_prompt`. One file suffices for small state; reference existing materials and preload known required Abilities/references through real tool_call entries. Do not create a preparation child or copy full history into giant arguments. Splitting files does not reduce model tokens; read non-required material on demand.
- **Fresh handoff context and authority**: Retain configured Runtime/Soul, model/tools and project context, not automatically old conversation or all loaded file/Ability bodies. Fresh project rules/guidance enter through normal rules or explicit preloads; required files MUST read fully/successfully without silent omission/truncation. Copied schemas do not establish committed Ability authorization. Ordinary inheritance is unchanged.
- **Prepared handoff acknowledgement**: Only after required files/preloads commit and the successor is recoverably saved, register transfer and return exactly two text facts: `status: handoff_scheduled` and `save_id: <new-save-id>`, without run_mode. This acknowledges preparation/scheduling, not completion or finished switching; the source does not wait for new-task final output.
- **Safe handoff execution boundary**: Settle real handoff output/context and the caller tool batch, prevent old automatic continuation, save old history, then switch/close the old Chat and submit the new main. It has no parent wait/cancel, child ask relay/progress, recursion/parent hook chain or agent_executor completion cleanup; it owns validation/delivery and remains open after final reply. Skill MUST use one standalone synchronous run, not multirun/async. Duplicate requests MUST NOT create multiple executing successors.
- **Handoff failure preservation**: Missing/unreadable/empty files, preload failure/cancellation, setup/save failure or caller batch/commit failure MUST identify the failed stage/item, retain old Chat/selection and prevent target dispatch/dual execution. Completed preload side effects are not rolled back. Post-transfer errors belong to the new main, not old-parent acceptance. Explicit nonzero `max_turns` MUST be rejected, not imposed or silently ignored as a delegated cap.

### Session-owned handoff compression

Authorized Session handoff compression MAY reuse internal verified prepare/commit from the real paused source; its temporary executor SHALL NOT impersonate a public caller. Public run_agent(handoff) validation/authorization remains unchanged. The successor keeps main or same-current-parent ordinary-child type; original waiting call, finite turn budget, cancellation/ask/display/cleanup ownership and single completion follow the active successor. Selected history and summaries follow the Session compression owner.

Activity must recover before executor termination. Ended/ineligible run/fork/resume errors SHALL return actual error and available saved IDs without automatic compact_full overwrite of child or parent history; explicit historical tools remain available under their own authorization.

### Child-session handoff

- **Same-parent successor**: Create a fresh persistent child under the source's current invocation parent/root/depth—not the source or restored historical parent. MUST NOT replace the main sidebar or promote either child; retain configured Runtime/Soul/model/tools using explicit files/preloads rather than full source history.
- **One delegated invocation across handoff**: Return `handoff_scheduled` only inside the source's call; settle its batch, verify histories, replace the executor's active Chat and close the source without resolving/cancelling the parent's pending run/fork/resume call. Only active-successor final result/error/cancellation resolves it, once. Final save_id/context_status identify the successor; original tool metadata remains.
- **Replacement lifecycle bindings**: Cancellation, ask ancestry, progress/context display, result extraction and cleanup MUST follow the active successor; old scheduled callbacks MUST NOT complete the parent call. A finite delegated turn budget continues without reset; parent cancellation during preparation prevents successor dispatch.
- **Child preparation failure**: Required file/preload/history failure MUST retain source child and parent invocation, prevent successor dispatch and identify the stage; completed side effects are not rolled back. Preparation/transfer are standalone synchronous in the child while any enclosing parent async invocation is retained.

### Requirement: `fork_agent` inherits the full parent state

With valid parent, title and focused `goal_prompt`, fork SHALL clean stale calls then inherit parent messages, composed base prompt, tools, loaded context, adapter/model, hooks and current registry. New-format composition/final-goal rules apply; tool restriction/temperature overrides are not accepted. `fork_mode` defaults to `new_chat`; temporary results have no resumable ID.

### Requirement: `resume_agent` continues saved history

Resume requires `save_id`; restore history, available adapter/model and composed Runtime/Soul, then apply shared goal/background and saved-composition rules. Reconcile runtime schemas in memory without rewriting stored transcripts.

- **Resume history versus execution**: Default `in_place` preserves saved type/parent/root/ID and fails if already open. `new_chat` creates a separate continuation/new child history node. Bind current execution to its current caller under Child interaction execution identity, independently of saved ancestry; restoration MUST NOT rehydrate live invocation subscriptions.

### Requirement: `handoff` routes discussion control

In an active discussion, handoff transfers to a named participant or `user`; unknown targets fail. Its private message is a concise routing note, not a replacement for visible analysis. Registering `handoff` does not itself register `multi_agent`.

### Requirement: Registered discussions remain bounded

Registered multi_agent MUST preserve named participants, role/Soul inputs, round/message limits, private routing and final fork/run phase. Early handoff cannot bypass min_rounds; this repair adds no phase-aware cancellation guarantee.

- **Discussion Chat adapter and ownership**: Display MUST reuse resolved parent/default adapter without bypassing provider checks. Create display/participant Chats headlessly with child identity and caller project context before the existing independent Tab displays them; do not replace the selected main Chat. Nil/failed creation MUST return an actionable error, not index nil or execute a final task after setup failure.
- **Discussion-local handoff**: Every participant, including `restrict_tools=[]`, MUST receive working local handoff using exact invoking participant context, public-before-handoff and private-target behavior, without mutating global Chat tool config. Native handoff outside an active participant MUST fail rather than borrow another Chat's context.
- **Final adapter transition and return**: Final fork/run MUST synchronize adapter-dependent Chat UI/settings/tools with the resolved execution adapter, return actual final output, preserve save/session IDs and restore the caller while leaving its main Chat alive.

### Requirement: Results are recoverable and bounded

Synchronous/async wrappers MUST preserve the same LLM text; internal structured results/trace retain their fields.

| Result | Model-visible projection |
| --- | --- |
| Ordinary run/fork/resume | Minimal metadata before first exact `---`, then complete unmodified final answer. Resumable `save_id` appears once; temporary calls have no resumable identity/ID. `context` reports percent/used/limit/source or `context: unavailable`. Keep non-completed `finish_reason`; emit `source_save_id` only when different from final `save_id`. Omit natural completed/config defaults, goal, counts, byte sizes and inheritance/override flags. |
| multi_agent | `session_id`, applicable final `save_id`, complete final answer. |
| Session handoff preparation | Only the prepared acknowledgement above, for main and child transfers. |
| Discussion handoff | Status, complete new public entries and necessary private note; no `last_agent` or duplicate fixed ending advice. |
| Token recovery / error | Recovery state/IDs/reason / existing tool-error semantics. |

The `@subagent:*` exemption and full required prose MUST NOT be truncated, summarized or replaced by file previews. Exclude unbounded transcripts and secrets, not complete required answers.

- **SubAgent result display compatibility**: Tool-owned UI MUST parse only pre-separator metadata and fold the unmodified answer. Body JSON/headers/code/later separators are not metadata. Historical JSON results remain displayable without rewriting canonical history.

## Child Identity And Display

- **Headless delegated execution**: Ordinary run/fork/resume MUST create children without windows/Tabs, focus changes or main-sidebar replacement; progress/answer views, ask relay, inheritance, cancellation and public results remain. Only explicit run_agent handoff switches main selection at its prepared safe boundary, never during preparation.
- **Explicit child display**: Project-owned opening/restoration of an executing or historically identified child MUST use a Chat float independent of the main sidebar. Hiding it MUST NOT stop execution; terminal cleanup MUST NOT close unrelated main windows.
- **Public agent identity**: Session helpers MUST expose main/subagent identity and live/saved parent/root/children/ancestor/tree relationships independently of trace. Live invocation references stay session-local; legacy depth compatibility remains.
- **Retire ask_llm implementation**: `ask_llm` MUST remain unavailable; remove its implementation and exclusive active configuration/instructions while preserving shared streaming and historical trace readability.

## Tool-owned answer and live detail

- **SubAgent owns answer presentation**: 三个 Chat-backed 工具必须以 SubAgent 本地 display/helper 提取成功回答并折叠；公共 renderer 不解析 `content`，不按 `subagent__*` 分类。wrapper 保持现行 execution identity/title；公开结果和 canonical 消息不变，共享提取 helper 归 SubAgent。
- **Handoff owns local presentation**: handoff 可以用无角色 Markdown/message 块呈现原有分隔、发送/收到的 routing note，不显示通用 spinner；owning tool 提取内容。显示不得转移控制权、绕过 active discussion 校验或隐藏工具错误。
- **One live subordinate tool row**: 父调用仍运行且有 UI 句柄时，三个工具必须在其正下方显示 child 最近开始工具的实际单行摘要：三个空格后 `└─ ` 加摘要；连接符/子行弱化，父摘要不变。首个工具前无详情；child 继续模型响应时保留最近摘要；不附工具正文、回答、输入或后代 detail。
- **Latest-started tool precedence**: 开始时选为 latest，spinner/完成/错误原地刷新；较早工具的迟到完成/错误不得覆盖新工具。child buffer 隐藏或工具窗口变化不停止更新，也不得为显示聚焦窗口。
- **Explicit parent-call routing**: 绑定捕获的 `req.ui` 与现有 call/member 上下文，禁止同父 Chat 不同 SubAgent/member 串写。摘要取自 child display owner 的实际通知；不扫描 buffer、重执行/解析工具或增加轮询/计时器。
- **Transient detail teardown**: 父调用成功、失败、取消或 owning Chat 关闭时停止订阅并移除详情；幂等终止后拒绝迟到更新。最终只留父摘要/回答及可序列化右侧上下文装饰，不保存 live detail；恢复不得重启 child/观察请求。异步提交/wait 另遵下条。
- **Async SubAgent active wait binding**: 异步提交返回后不得更新原行正文/详情/结果/状态/耗时；仅右侧装饰可按 [Async submission decoration exception](../../../runtime/chat-builtins.md#tool-owned-display-interface) 跟随原子任务。活跃 `wait(mode=wait)` 可以通过原调用的 task-private 可解除 sink 转发原 SubAgent 摘要、右侧装饰和最新 child 摘要，保持 latest-started 与显式路由；只呈现 wait 下原工具及其单层详情两层缩进，不扩后代树。SubAgent 提供呈现，wait 不提取 content。wait 结束/返回/超时/取消/关闭必须移除活动显示及详情，不持久化/恢复源执行快照；终端纯结果仅按 Chat Builtins 的 Wait-owned terminal result fold 委托且默认折叠。保留 canonical 结果/错误及原 SubAgent/registry 取消语义；源任务终止清理订阅并拒绝迟到更新。try 不附活动原工具显示，仅可复用已完成纯结果。
- **Live SubAgent context decoration**: run/fork/resume MUST use the exact child Chat's latest available usage/model context limit: `◔ N%`, estimated `◔ ~N%`, or unavailable `◔ —`. Sync calls, original async submission/member rows and active wait mirrors use one style. Updates MUST be event-driven and window-independent, without claiming unavailable provider streaming accuracy. Completion/error/cancellation detach usage observers and freeze decoration; restored history MUST NOT restart execution/subscriptions. multi_agent aggregation is excluded.

### Child interaction execution identity

- **Execution-local child interaction ancestry**: Before dispatch, run/fork/resume MUST bind the executing child to the exact invoking parent/root and applicable async wrapper identity. Nested execution ancestry is independent of semantic inheritance, visibility, temporary persistence and trace activation; resume binds the current invocation, not historical parent. Missing exact parent leaves original interaction unchanged—never guess from current/last Chat. Bindings are session-local; history cannot restore live subscriptions.
- **Child ask relay ownership**: Child `ask` retains original parameters/result and Chat/Telegram behavior. [Chat Builtins](../../../runtime/chat-builtins.md#child-ask-root-relay) owns top-level entrance eligibility, FIFO, arbitration and restoration. Ancestor completion/cancellation/close MUST end relay eligibility without routing into another execution.

## Recursion And Boundaries

### Requirement: Child-agent recursion is bounded

Depth uses `_subagent_recursion_depth`; child-creating tools fail at `MAX_RECURSION_DEPTH = 5`. Identity helpers preserve this live compatibility boundary; `ask_llm` retirement permits no execution path.

### Requirement: The latest boundary separates inherited history from the child task

History before the latest recognized fork/agent/resume/multi-agent boundary is read-only. The child SHALL execute only the following assignment, not the parent's unfinished actions.

## Cooperative Cancellation

### Requirement: Chat-backed child tools register cancellation handles

Run/fork/resume inside asynchronous `call`/`multicall` SHALL register invocation-local cancellation handles after child creation and before scheduled first submit. Apply already-requested cancellation immediately, preventing first dispatch where possible.

### Requirement: Active child work stops at a safe boundary

During a request/tool batch, cancellation SHALL request Chat soft stop without corrupting call/result pairs. Begun work may drain; side effects are not rolled back. No new automatic model turn begins after the boundary. Outer async cancellation is immediate/terminal; late callbacks cannot overwrite it.

### Requirement: Parallel wrapper cancellation suppresses pending calls

Cancelling `multicall` requests cooperative cancellation of started children and prevents unscheduled calls. Non-cancellable work may finish, but terminal outer tasks ignore its result.

## Validation Evidence And Risk

These dated checks retain their original scope and historical human-review limits; wording changes do not establish new runtime evidence.

Fresh-runtime Session handoff compaction passed actual collapse/destructive child transfers through the original waiting resume call, current-parent sibling identity, selected-history tool pairs and source history retention. Existing executor replacement-budget checks and actual cancellation during preparation passed; public child handoff still returned the successor through the original call. Real provider context-limit faults and storage/window failure races were not induced; human implementation review not-run.

| Behavior group | Established evidence and retained limits |
| --- | --- |
| Composite Ability | Actual composite load exposes unchanged tools/references and guidance. Focused catalog/loader checks and generated Runtime verify identity/dependency/gate; all three context examples pass schema/reference checks. Human review and measured model-selection behavior not-run. Old loaded histories need caller-context cleanup before retiring the identifier; other saved sessions are not rewritten. |
| Ordered background calls | Actual focused pipeline and fresh-Neovim run/resume/discussion entrypoints establish ordered pairs, loading, once-only shared side effects and failure boundaries. Pre-existing supplementary-test gaps remain; human review not-run. |
| Main-session handoff | Focused preloads/helpers and actual fresh-Neovim two-file/time-preload handoff, old closure/history, new-main reply/continuation, missing-file preservation, then-current child rejection and ordinary delegation passed. Injected storage/window failure and cancellation races were not simulated; static permission checks do not prove all model behavior. |
| Child-session handoff | After full restarts, actual resume message → file/preload → sibling transfer → successor choice/final result plus original-invocation cancellation/safe cleanup passed. Existing executor/token checks and generated Runtime passed. Real Telegram request creation used Chat choice, not a Telegram button click; human review not-run. |
| Result projection | Exact 14448-byte projection/legacy inputs, fresh sync/async results and actual run/multi_agent answer-fold expansion passed. Actual two-participant discussion completed with the new final result; human review not-run. |
| Headless session identity | Focused/fresh-runtime headless and identity evidence has retained limits; source includes `lua/maxa/ai/session/agent_identity.lua` and the three tool owners. That change left multi_agent unchanged; later restoration is documented below. |
| Context indicator | Existing focused checks and fresh-Neovim original async row, sync resume, independent 7%/6% members, narrow windows, active-wait timeout/terminal teardown and restored history passed; human review not-run. |
| Tool presentation | Actual original/child summaries, hidden-child updates, serial member routing, terminal/late-write rejection, answer-fold expansion/restoration and async-wait continuation passed. Existing handoff registered-context boundary remained; no dormant discussion tool was enabled. Human implementation review not-run. |
| Root ask relay | Actual run/resume/fork and depth-2 child asks passed exact-root routing, including outer async-wait eligibility. Cancellation/Telegram coverage remains limited within the recorded scope. |

**2026-09-22 Soul/composition evidence**: Focused suites passed unified Soul naming, explicit-null old-key rejection, Ability/path/text resolution, project Soul precedence, inheritance/restrictions, final child/API message composition, fork/resume/current dump, dormant discussion/final builders, recursion, cancellation and wrapper scheduling. Full restart exposed only public `soul`, retained exactly four then-registered tools, omitted hidden Agency roles from the catalog, exactly loaded `#agency-nexus:/agents/design/brand-guardian.md`, and returned `SHORT_SOUL_OK` from a temporary role-backed child. Automated validation passed; post-change human implementation review was not separately run. This evidence claimed neither live multi_agent availability nor phase-aware cancellation. Unrelated baseline `resume_agent_spec.lua` failures reproduced against HEAD-era utilities remain separately owned.

**Registered discussion restoration**: Existing token-decision, Lua syntax/diff checks, two full restarts and actual two-role final run/fork calls passed adapter/child ownership, handoff-only restrictions, private-target isolation, Runtime/Soul transition, final output and caller restoration. Attempted `soul_prompt_integration_spec.lua` final-phase check failed because its older mock lacks current Chat methods; actual final Chat composition was directly verified. Tests/mocks were not modified. Human implementation review not-run; phase-aware cancellation and session-resume redesign remain outside that repair.

## Source Trace

- Registration/schema: `lua/maxa/mcphub/native_servers/subagent/init.lua`.
- Validation/composition: `config.lua`, `utils.lua`, `fork_context.lua`.
- Tools: `lua/maxa/mcphub/native_servers/subagent/tools/`.
- Cancellation: `async_cancel.lua`, `shared/streaming_llm.lua`, `maxa.lifecycle.chat_soft_stop`.
- Operational rules/Souls: `abilities/subagent/`, `abilities/agency-nexus/`.
