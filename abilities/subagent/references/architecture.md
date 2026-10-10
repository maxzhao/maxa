# SubAgent Architecture Reference

Purpose: maintenance map for the `subagent` Native MCP Server. Use for implementation changes, schema updates, inheritance/debugging, token recovery, window behavior, and multi-agent internals.

## File Map

Config: `lua/maxa/presets.lua` resolves arbitrary named presets and separate role defaults; `lua/plugins/ai.lua` supplies deployment definitions. `native_servers/config.lua` retains provider-priority and compatibility accessors.

```text
lua/maxa/mcphub/native_servers/
├── config.lua                         # shared adapter presets
├── shared/streaming_llm.lua           # streaming LLM adapter creation, SSE accumulation, retry
└── subagent/
    ├── init.lua                       # Native server registration
    ├── config.lua                     # compatibility shim -> native_servers/config.lua
    ├── utils.lua                      # shared helpers and core policy
    ├── utils_test.lua
    └── tools/
        ├── run_agent.lua              # new inherited/independent Agent session
        ├── fork_agent.lua             # child Agent with full parent messages
        ├── resume_agent.lua           # restore save_id and continue
        ├── agent_executor.lua         # execution engine
        ├── agent_executor_spec.lua
        ├── token_recovery.lua         # token-limit recovery
        ├── window_manager.lua         # child window layout/control
        └── multi_agent/
            ├── multi_agent.lua        # MCP tool entry
            ├── coordinator.lua        # state machine, routing, phase 2
            ├── agent_chat.lua         # hidden per-agent Chat wrapper
            ├── display_adapter.lua    # visible display Chat adapter
            ├── handoff_tool.lua       # handoff schema/handler
            ├── mcp_handoff.lua        # direct HTTP bridge
            ├── session_manager.lua    # JSON session persistence
            ├── discussion_store.lua   # discussion summaries/history
            └── README.md
```

## Modification Entrypoints

| Need | Location |
| --- | --- |
| Add/change preset or role default | `lua/plugins/ai.lua` -> `opts.maxa.presets` / `opts.maxa.defaults`; resolver: `lua/maxa/presets.lua` |
| Tool parameter/schema/description | corresponding `tools/*.lua` `description` / `inputSchema`; this first-party server needs no Ability MCP description override |
| Soul/composition | `utils.lua` -> `validate_soul_params()` / `build_soul_system_prompt(config, ctx)` -> Runtime + Soul only |
| Goal/background | `prepare_background_messages()` preserves roles/preloads context; `append_sub_agent_tail()` appends final user goal |
| Inherit inference | `utils.lua` -> `infer_inherit_mode()` / `validate_inherit_exclusivity()` |
| Turn loop/completion | `agent_executor.lua` -> `execute()` |
| Window layout | `window_manager.lua` -> `setup_child_window()` |
| Token recovery | `token_recovery.lua` |
| Context inheritance | `utils.lua` -> `inherit_*` / `extract_*` helpers |
| Boundary/tail messages | `utils.lua` -> `append_sub_agent_tail()` / `append_stage_tail()` |
| multi_agent discussion | `multi_agent/coordinator.lua` |
| multi_agent hidden chats | `multi_agent/agent_chat.lua` |

## Troubleshooting Matrix

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Child no response | adapter config/model issue | `mcphub/config.lua` adapter/model constants |
| `fork_agent` fails | called outside Chat | `get_parent_chat(req, bufnr)` result |
| Tools unavailable | `tool_registry` not set | `apply_tools_override()` and `on_created` callback |
| Token limit exceeded | child/parent history too long | `token_recovery` result; `compact_full` / manual compact |
| Child window remains | cleanup callback chain broken | `on_complete` / `on_error` / window manager cleanup |
| Context missing | inherit not active or Soul override set | `infer_inherit_mode()`; `soul`; goals and tools do not select independent mode |
| Forked child executes parent task | fork boundary not recognized | appended user-role `[FORK BOUNDARY]` |
| inherit conflict error | `inherit=true` with Soul override | remove Soul override or set `inherit=false` |

## Parent Chat Resolution

All child-agent tools use `utils.get_parent_chat(req, original_bufnr)`.

```text
get_parent_chat(req, original_bufnr)
├─ req.caller.maxa_ai.chat -> parent chat if available
└─ fallback buf_get_chat(original_bufnr) -> chat or nil
```

| Tool | Parent chat use |
| --- | --- |
| `run_agent` | inherit decision; parent adapter/system prompt/tools/context |
| `fork_agent` | required; deep-copies messages and tool_registry |
| `resume_agent` | not required; restores by `save_id` and restored tools |
| `multi_agent` | parent adapter; Phase 2 fork inheritance |

## Inherit And Independent Mode

`utils.infer_inherit_mode(params, has_parent_chat)` priority:

```text
1. explicit params.inherit
   ├─ inherit=true without parent -> false
   └─ otherwise use explicit value
2. any independent param -> false
   ├─ soul
   note: goal_prompt/messages do not affect mode; restrict_tools only limits tools
3. parent chat exists -> true
4. no parent chat -> false
```

`utils.validate_inherit_exclusivity(params, effective_inherit)` rejects `inherit=true` with `soul`. Compatibility-only `soul_prompt`/`soul_file` inputs follow the same rule. Goals/background/tools do not change inheritance or adapter selection; retired `instructions` is rejected before dispatch.

| Tool | Uses `infer_inherit_mode` |
| --- | --- |
| `run_agent` | yes |
| `multi_agent` agents | no; each is independent hidden Chat |
| `multi_agent.final_agent_config` | yes for Phase 2 `run` |

## Soul Parameters

| Param | Meaning | Notes |
| --- | --- | --- |
| `soul` | Exact Ability reference, explicit path, or complete inline Soul | references resolve first, paths second, inline text last; matched missing sources fail |
| `goal_prompt` | Current user goal | final user message, never part of system composition |

`utils.build_soul_system_prompt(config, ctx)` delegates to the one host composer without assignment/mode supplements:

```text
retired role source keys -> validation error
public soul -> exact #ability[/path] file (no resource activation), explicit path, or inline text
no explicit Soul -> project .maxa/soul.md, then .maxa/_meta.yaml maxa_ai.soul, else prompts/soul.md
legacy soul_prompt/soul_file -> compatibility-only old semantics
result -> common Runtime + selected Soul
```

Supported by `run_agent`, `multi_agent` agents, and `multi_agent.final_agent_config`; not supported by `fork_agent`.

## Recursion And Nested SubAgents

Source permits nested SubAgent use for real decomposition, but Chat metadata limits depth to prevent infinite pass-through delegation.

Entrypoints:

- `config.lua` -> `MAX_RECURSION_DEPTH` default `5`.
- `utils.lua` -> `get_chat_recursion_depth()` / `set_child_recursion_depth()` / `check_execution_allowed()`.
- `run_agent`, `fork_agent`, `resume_agent`, and `multi_agent` check depth before child creation and write `parent_depth + 1`.

Allowed: supervisor -> execution/repair/review children; explicit smaller subproblems; `save_id` resume. Forbidden: child passes the boundary task unchanged or nearly unchanged. At max depth, return error and report upward.

## Execution Pipeline

### `run_agent`

```text
handler
├─ validate params: required goal_prompt, optional background messages, Soul, tools, max_turns, mode
├─ parent_chat = utils.get_parent_chat(req, original_bufnr)
├─ use_inherit = utils.infer_inherit_mode(params, has_parent_chat)
├─ validate_inherit_exclusivity(params, use_inherit)
├─ context_items, regular_messages = extract_context_from_messages(messages)
├─ resolve Chat-owned project context before Soul selection
├─ build chat_messages
│  ├─ tagged base prompt: inherited complete composition or host-composed Runtime + Soul
│  ├─ inherited context as initial system-role preload
│  ├─ user context from role="context"
│  ├─ background user/assistant messages with roles preserved
│  └─ goal_prompt as final user message
├─ adapter = resolve_adapter_by_key(adapter_key, parent_chat, use_inherit)
├─ setup window manager + buffer context
├─ on_created callback
│  ├─ inherit -> nil until `inherit_tool_registry`
│  ├─ restrict_tools -> apply_tools_override(requested)
│  └─ default independent -> apply_tools_override({"Chat builtins"})
├─ Chat.new(ignore_system_prompt when custom prompt exists)
├─ inherit_tool_registry(parent_chat, chat) when inherit
└─ agent_executor.execute(...)
```

### Main-session handoff

`run_mode="handoff"` reuses run_agent message/configuration construction and branches before ordinary child execution. `session_handoff.lua` owns exact caller validation, strict required file/preload preparation, saved target read-back and acknowledgement. It accepts a main or an active persistent ordinary child with a live current parent/executor. It never copies old loaded context; fresh project rules are included before the user goal.

The ordinary `interactions/chat/tools/init.lua` ToolsFinished scheduled boundary consumes pending handoff before source auto-submit: settle context/results and reset, verify source history, then commit by type. Main transfer displays/closes the source and submits a new main with no delegated executor. Child transfer creates a sibling under the same current invocation parent, rebinds ask/hooks/display/cancel ownership, calls the invocation-local executor replacement and closes only the source child. The original run/fork/resume response remains pending until the successor finishes; `on_replaced` redirects tool result/error/cleanup to that Chat, and old deferred completions become inert. A finite turn budget is retained. Async cancellation uses the original registered handle's current-Chat accessor; ask relay retains its existing async wait identity.

Preparation failure preserves the caller; commit failure keeps it stopped with a visible blocker. `SYSTEM.md` owns explicit main/user message authorization and type preservation; `SKILL.md` owns file-backed single synchronous invocation and resume-driven migration. Child token decision exposes handoff at its existing final 300-second ask and injects a child-specific one-transfer instruction.

### Prompt-cache warmup

Only fresh-prefix `run_agent` child sessions support `warmup = "auto" | "force" | "disable"`. Do not set it unless explicitly requested or testing/debugging cache behavior.

Implementation:

- `utils.normalize_warmup_mode()` validates value.
- `utils.configure_chat_warmup(chat, mode, prefix_count, kind)` runs after chat/tool setup and before first submit.
- `prefix_count` must end at the fixed prefix, before real task messages/tails.
- `force` can cache non-default prefixes; `disable` skips; `auto` delegates to `session/default_session_cache.lua`.
- `fork_agent`, `resume_agent`, and `multi_agent` do not support warmup because they inherit or restore histories and would break provider cache prefixes.

### `fork_agent`

```text
handler
├─ require parent Chat
├─ deep-copy parent messages
├─ append user-role `[FORK BOUNDARY]` and fork task
├─ Chat.new(copied messages)
├─ inherit_tool_registry(parent, child)
├─ setup child window
└─ agent_executor.execute(...)
```

Batch fork calls roll back to before the tool-call message so all children see the same clean parent history.

### `resume_agent`

```text
handler
├─ load history by `save_id`
├─ deep-copy restored messages
├─ preload context from appended messages
├─ append role-preserving background and goal_prompt as final user message
├─ inherit restored tool_registry; `restrict_tools` only narrows
├─ setup child window
└─ agent_executor.execute(...)
```

Default `resume_mode="in_place"` writes to the original `save_id` and rejects execution if the session is already open. `new_chat` creates a separate resumed history.

## Message Structure

`utils.append_sub_agent_tail()` appends only the canonical user goal. `build_sub_agent_render_messages()` adds an assistant placeholder to a separate UI copy; it never enters the API transcript. Fork adds a preceding user-role `[FORK BOUNDARY]`; run/resume append the supplied goal directly.

## Execution Engine

`agent_executor.execute()` registers callbacks on the chat:

| Callback | Trigger | Behavior |
| --- | --- | --- |
| `on_completed` | LLM response completed | increment turn, check `max_turns`, continue on tool calls, finish on no tool calls |
| `on_cancelled` | request cancelled | distinguish interrupt vs hard cancel |
| `on_error` | request error | route to `on_agent_error` and token recovery |

`done()` captures streaming output; a normal response with no tool calls completes the child.

Response extraction priority:

1. `collected_output` from `done()` hook.
2. `extract_final_response(messages)` from newest assistant/llm message.
3. Chat buffer parse fallback.

## Context And Tool Inheritance

Context pipeline:

```text
parent chat
├─ extract_context_data() -> non-tool context items
├─ preload_inherited_context_to_messages(...): initial system-role context before user tasks
└─ on_created: register context metadata with context:add() without appending messages
```

Do not append inherited context in `on_created`: `context:add()` appends user messages after the task. Initial system-role preload avoids `ui:render` / `format_role(nil)` failures from invisible user messages and must stay before the first user message.

Tool pipeline:

```text
fork_agent -> inherit_tool_registry(): deep-copy schemas, in_use, flags
run_agent on_created:
├─ restrict_tools -> apply_tools_override(requested)
├─ inherit -> inherit later
└─ independent default -> apply_tools_override({"Chat builtins"})
```

`apply_tools_override()` edits `tool_registry` internals directly and expands groups such as `{"Chat builtins"}`. Do not call `context:add()` for tool overrides.

## Window Management

`run_agent`, `fork_agent` and `resume_agent` create headless Chats without changing windows/focus. Explicit child open/history/restore uses the existing Chat float; main history opens in the right sidebar and `}{` cycles only main Chats. Terminal cleanup closes only the child Chat/float. Registered `multi_agent` creates display/participant Chats headlessly with child identity, then uses its existing independent discussion Tab. Its display adapter clones a resolved parent/default provider adapter rather than introducing a provider.

`lua/maxa/session/agent_identity.lua` owns saved identity, live invocation ancestry, public parent/root/children/ancestor/tree queries and type-aware float options. History persists additive `_meta.agent`/dialogue time and compact index fields. In-place resume keeps historical identity while executing as a child. The Snacks history tree uses `h/l` navigation and `Ctrl+L` to retain flat browsing.

Keys:

| Key | Mode | Meaning |
| --- | --- | --- |
| `q` | Normal | hide the sidebar/float only; execution and Chat remain alive |
| `Ctrl+C` | Normal/Insert | interrupt active request/tools; retain Chat and child executor for manual continuation |
| `<leader>aq` / `Ctrl+Q` | Normal / Insert | exit Chat; confirm force exit if running, preserve unsaved-scratch confirmation |

These mappings have one owner in the ordinary Chat configuration/keymap callbacks; SubAgent setup does not overwrite them. Graceful `<leader>ax` still waits for the current operation/batch boundary and remains distinct from immediate interruption. Explicit child exit returns cancellation/closed state to its caller without deleting saved history.

Chat-local normal `gS` opens the SubAgent associated with the tool display under the cursor; it reuses live/temporary Chats or restores saved history in a float without re-execution. Other tools or unavailable sessions produce a bounded notice. Logical provenance and invocation/member identities select the child, not title/summary matching.

Headless creation bypasses automatic window opening and does not replace last-main selection; the old split/Tab managers remain only where maintained callers require them.

## Token Recovery

Token-limit detection matches case-insensitive strings such as `maximum context length`, `token limit exceeded`, `context_length_exceeded`, `too many tokens`, `context window`, `exceeds the model`, `input is too long`, and `prompt is too long`.

Recovery:

```text
run_agent token error
├─ if temporary/unsavable -> report unrecoverable
├─ compact_full overwrite child session
├─ read compacted messages
└─ return recovery info and compact_stats

fork_agent token error
├─ if parent save_id temporary/unsavable -> report unrecoverable
├─ compact_full overwrite parent session
└─ return parent_save_id and compact_stats

other tools -> report unsupported recovery and suggest manual compact
```

## Multi-Agent Subsystem

Architecture:

```text
MultiAgentCoordinator
├─ agents: { name -> AgentChat }
├─ display_chat: headlessly created child, shown in independent Tab with DisplayAdapter
├─ discussion_store: summaries/history
├─ session_manager: JSON persistence
└─ discussion-local HandoffTool -> native handoff handler -> Coordinator
```

Phases:

| Phase | Meaning |
| --- | --- |
| 1 Discussion | hidden Agents discuss and route with Handoff Tool |
| 2 Execution | `final_agent` executes from discussion context |

`final_agent="fork"`: inherits parent adapter/tools and uses Display Chat messages as context. `final_agent="run"`: uses `final_agent_config` with run_agent-style inherit/role/adapter/restrict_tools semantics.

Agent config shape:

```lua
{
  name = "Agent Name",           -- required; handoff target
  role = "One-line role",        -- required display/role summary
  soul = "#ability[/path.md]",   -- optional WHO; also accepts explicit paths or inline text
    goal_prompt = "...",           -- optional current goal; defaults to shared task
  preset = "main",              -- optional configured chat preset; nil inherits parent adapter
  icon = "🔒",                   -- optional display icon
  restrict_tools = {...},        -- optional; [] leaves handoff only
}
```

Discussion flow:

1. Coordinator loads optional shared `messages` once and copies the snapshot into each participant and Display/final Chat; persistence retains the snapshot and task/final configuration.
2. Lazy participants receive Runtime + Soul, shared background and user-role discussion protocol. Every turn appends round/public/private background before `goal_prompt` (default `task`); final execution appends `final_prompt` last. Adapter presets use the common parent-aware resolver.
3. Agent calls Handoff Tool with `target` and private `message`.
4. Text reply is shared; private message goes only to target.
5. Repeat until `handoff("user")`, `max_rounds`, or `max_messages`.
6. Start Phase 2 execution.

Finish sequence: set `_is_finishing`, stop Agent HTTP/autocmds, collect pending completions, close tab early, restore parent window, resolve pending handoffs, deferred chatmap removal, deferred cleanup fallback, persist session, call `on_complete`, install completion timeout listeners.

Modules:

| Module | Responsibility |
| --- | --- |
| `coordinator.lua` | state machine, rounds, scheduling, termination, Phase 2 |
| `agent_chat.lua` | hidden Chat, role prompt, handoff detection |
| `display_adapter.lua` | visible current-agent display |
| `handoff_tool.lua` | `target` + `message` schema/handler |
| `mcp_handoff.lua` | native handler with exact participant Chat context; outside-discussion calls fail |
| `session_manager.lua` | JSON persistence and `id` resume |
| `discussion_store.lua` | summary/history management |

## LLM Result Projection

`subagent/result_format.lua` owns the model-visible text and header parsing. Internal executor results and traces retain structured `context_status` and execution/config fields. `ask_llm` remains retired.

Ordinary run/fork/resume example:

```text
save_id: 1780506194
context: 5% (14803/300000; actual)
---
Complete original final answer, including Markdown and code.
```

- Parse only metadata before the first exact `\n---\n`; the remainder is opaque complete answer text. No output limit, escaping, summarization or file-preview substitution is introduced; `@subagent:*` stays exempt.
- `save_id` occurs once and identifies the active final child; temporary calls omit it. `context` retains percent/used/limit/source or `unavailable`. Natural completion/config defaults, goal echoes, message/byte counts and inheritance/override flags stay internal. `finish_reason` appears only for non-completed termination; `source_save_id` only when distinct from final ID.
- multi_agent projects `session_id`, applicable final `save_id` and complete Phase 2 answer. Handoff preparation projects `status: handoff_scheduled` and successor ID; discussion handoff projects status plus complete new public entries and required private notes, without inferred last_agent or fixed ending tutorials.
- Tool errors keep their existing error channel; token-recovery replies project recovery state/IDs/reason. Local presentation supports both this text and legacy JSON results without rewriting history.
- Returned context is advisory. Use `save_id` with `@session:get_session_status` for fresh structured status; follow the Skill capacity/migration gate before continuation. High usage does not authorize compression or self-initiated handoff.
