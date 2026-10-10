---
name: session
description: "Query, compact, and govern MaxaAI current and historical chat sessions, including token status, save_id lookup, recovery entrypoints, and auto-compaction troubleshooting."
compatibility: Requires Maxa Ability runtime.
---
# Session

Purpose: manage MaxaAI current and historical sessions: message queries, token/context status, context compaction, `save_id` lookup, history recovery entrypoints, and auto-compaction troubleshooting. This composite Ability supplies operational guidance, references, the trace exporter and existing Native MCP tools in one load.

## Context Layers

- Always-on rules: root `SYSTEM.md` contains only compression rules that must apply before Ability loading.
- This `SKILL.md`: operational routing for query, compact, restore, and troubleshoot tasks.
- References: implementation, storage, recovery, adapter, and API details; read only when the task needs them.
- Authorized-signal exception: when the current conversation explicitly authorizes immediate compaction, do not load this Ability first; invoke titled `run(scope="tool", command="@session:compact_self", args=<encoded JSON object string>)` directly with required preservation `instructions`, without `mode`.

## Load When

Use this Ability when the user asks to:

- compact the current session, govern context, inspect token usage, or handle token warnings;
- query chat history, read a `save_id`, locate messages, or inspect tool errors;
- resume or continue work from historical sessions;
- debug auto-compaction, compact rescue, save/restore, Picker, context status, or adapter support;
- export recorded or synthesized session traces into static Obsidian Canvas/Markdown visualization artifacts.

## Composite Ability

Load `session` once for guidance, package references, the trace exporter and session tools; no separate guidance/server load is required. The authorized immediate-compaction exception above remains unchanged:

```lua
load({ target = "session" })
```

Call tools through:

```lua
run({ title = "Inspect session", scope = "tool", command = "@session:<tool>", args = vim.json.encode({}) })
```

Default target is the current chat when supported. Cross-session operations require explicit `save_id`.

## Compaction Decision

Priority: preserve current task state > reduce token risk > remove irrelevant history.

| Situation | Default action |
| --- | --- |
| No explicit signal in the current conversation | Do not compact |
| System/runtime threshold signal recommends or requires compression | One `compact_self(instructions=...)` call |
| System/runtime explicitly directs compression now | One `compact_self(instructions=...)` call |
| User explicitly requests current-session compression | One `compact_self(instructions=...)` call |
| User invokes `/collapse` | Fork and summarize the incremental tail |
| LLM already exceeded context | `/compact_rescue` or automatic rescue |
| Non-current historical session requested by user | `compact_full(save_id=...)` |
| Exact range explicitly requested | Locate indices, then `collapse_tail` or `compact_range` |

Entry points:

- `compact_self` requires `instructions` only and uses the shared handoff workflow with `maxa.compaction.profile` (default `balanced`).
- `/collapse` saves a complete fork, closes the source and summarizes after the last `_meta.tag == "collapse_summary"`, or after the protected foundation and contiguous tagged cache warmup segment initially. Warmup originals stay in their prefix positions. Required context/tool records survive; the fork remains editable without auto-submit. It does not run the handoff planner.
- Precise `collapse_tail` and `compact_range` retain their independent tail/range semantics below.
- `rescue`: context-limit recovery path through slash command or automatic recovery.

Current-session quick compaction:

```lua
run({
  title = "Compact current session",
  scope = "tool",
  command = "@session:compact_self",
  args = vim.json.encode({
    instructions = "Preserve the latest user request, user goal, task constraints, rule documents, current plan, changed files, current errors, key decisions, and next steps. Compress completed exploration, repeated reads, and large logs.",
  }),
})
```

Rules:

- `instructions` is required; `compact_self` has no `mode` parameter.
- Do not compact without an explicit current-conversation signal. Agent estimates, stage changes, checks, and token queries do not qualify.
- Treat authorization as single-use; each later compression call requires a new signal.
- If compacting before handling the latest user request, preserve the latest user message.
- After compaction resumes, verify critical task facts survived; reload only missing context.

## Handoff Compression

`/compact_rescue` prepares handoff state, splits source history with probes, displays one interval/description/tier table and waits for a user message selecting 保守/平衡/激进. `/compact_silent`, `compact_self` and active automatic recovery share the same flow but receive a configuration-generated user selection after segmentation. The former `compact_handoff` / `compact_handoff_silent` names and legacy slash algorithms are retired; precise/history tools remain independent.

In the dedicated workspace, use `handoff_compact` phases `prepare`, `plan`, then `apply`. Preparation supplies handoff material, continuation goal and required real file/Ability/guidance preloads. Planning sends source intervals and tiers only, never original message bodies. `conservative` keeps conservative/balanced/aggressive; `balanced` keeps balanced/aggressive; `aggressive` keeps aggressive only; `delete` never copies original text. Probe and copying use the same source view.

After selection, inspect all omitted regions including delete; write useful information yourself into a handoff/summary file or concise summary parameter, otherwise omit it. Do not call a separate summary model or the old compression tools. Applying copies structurally complete original records and transfers after the settled tool batch; main remains main, ordinary child remains under the same current parent and budget. Old history survives. Failed/ended delegated invocations return errors and saved IDs without automatic compact_full overwrite.

`handoff_compact` is workspace-only; it is not an unrestricted cross-session history mutation tool. Preparation/segmentation is not permission to apply without the required selection message. Preserve safety/authorization, source task state and project scope.

## Query Tools

| Goal | Tool |
| --- | --- |
| Session structure, token, role counts, tags, context status | `get_session_stats` |
| Token/context pressure wrapper | `get_session_status` |
| List historical sessions | `list_chats` |
| Session summary | `get_chat_summary` |
| Read messages by role/page | `get_messages` |
| Search message content/tool data | `search_messages` |
| Loaded abilities/context files/servers | `get_loaded_items` |
| Tool errors | `get_messages(role="tool_error")` |
| Locate indices or structural partitions | `probe_messages` |
| Single message detail | `get_message` |

Common `get_messages.role`: `user`, `assistant`, `system`, `tool`, `conversation`, `tool_error`.

For large histories, page, search, or summarize. Do not load entire histories by default.

## Precise Compaction

### `collapse_tail`

Use for cache-friendly tail summarization:

1. Locate boundary with `probe_messages` or `search_messages`.
2. Inspect structural facts with `scan_collapse_candidates`.
3. Call `collapse_tail` for `collapse_start_index..last`.

### `compact_range`

Use for destructive multi-range processing:

1. Call `probe_messages(include_partitions=true, include_context_status=true)`.
2. Define each `start_index`, `end_index`, and `action`.
3. Sort ranges by ascending `start_index`; do not overlap.
4. For current sessions, first confirm destructive conditions are satisfied.

`scan_collapse_candidates` returns structured facts only; it is not a message reader.

## History Recovery

Use `session` for history discovery: `list_chats`, `get_chat_summary`, `get_messages`, `search_messages`.

When a child/agent should continue from historical `save_id`, load `subagent` and follow its `resume_agent` rules. This Ability only decides when to switch from history inspection to SubAgent recovery. Do not rewrite SubAgent parameter rules here.

Do not change adapter, model, or tool restrictions unless the user requests it or task boundaries require it.

## Trace Visualization Script

Use the Ability-local script to export a recorded or synthesized session trace into static Obsidian Vault artifacts.

After loading `session`, call its script through the catalog. The executor owns the renamed package's uv project. Substitute concrete project/trace identifiers; args are not shell-expanded.

```yaml
# Help
- run:
    title: "Inspect trace exporter help"
    scope: tool
    command: "@session:/scripts/trace_visualize.py"
    args: ["--help"]
# Recorded trace by root_trace_id
- run:
    title: "Export recorded trace"
    scope: tool
    command: "@session:/scripts/trace_visualize.py"
    args: ["--project-root", "<PROJECT_ROOT>", "--root-trace-id", "<ROOT_TRACE_ID>", "--json"]
# Saved chat fallback: recorded trace or synthesized saved-chat history
- run:
    title: "Export saved chat trace"
    scope: tool
    command: "@session:/scripts/trace_visualize.py"
    args: ["--project-root", "<PROJECT_ROOT>", "--save-id", "<SAVE_ID>", "--json"]
# Replace existing generated files only when intended
- run:
    title: "Replace generated trace visualization"
    scope: tool
    command: "@session:/scripts/trace_visualize.py"
    args: ["--project-root", "<PROJECT_ROOT>", "--root-trace-id", "<ROOT_TRACE_ID>", "--overwrite", "--json"]
```

Outputs:

- Default directory: `.maxa/history/traces/<root_trace_id>/visualization/`.
- Files: `trace-overview.canvas` and `trace-summary.md`.
- Existing files are not overwritten unless `--overwrite` is set.
- The script updates shared `.maxa/.stignore-shared` (falling back to legacy `.maxa/.stignore`) with narrow include rules so generated visualization files can sync while raw `.maxa/history/**` remains ignored.
- `--json` returns generated paths, counts, warnings, validation status, and stignore status.

## Auto-Compaction And Recovery

- `hooks/ToolCallsCompleted.lua`: injects token threshold reminders from session status.
- `hooks/ChatSubmitted.lua`: only does lightweight collapse recommendation checks for direct user submissions; it does not handle repeat, auto-submit, or tool-result submissions.
- Read `references/auto-compact.md` for automatic compaction, retry, rate limit, invalid signature, and adapter-detection details.

## Constraints

- Do not load large session-management docs for ordinary compaction.
- Do not use `compact_full` on the current session; use `compact_self`, `compact_range`, or slash commands.
- Do not compact without an explicit current-conversation authorization signal.
- Do not treat task completion, stage changes, context estimates, token queries, or recommendation checks as authorization.
- Do not call `collapse_tail` or `compact_range` before locating indices.
- Do not pass overlapping or unordered ranges.
- Filter, page, or summarize large logs, histories, and tool outputs.

## Errors

| Error | Response |
| --- | --- |
| `No current session found` | Provide `save_id` or call inside a chat session |
| `ranges must be ordered` | Sort ranges by ascending `start_index` |
| `marker not found` | Adjust marker text, role, or occurrence |
| `Response size exceeds limit` | Use `skip` / `take`, or `mode="summary"` |

## References

Use `read` or `load` with the cataloged `#session[/references/...]` address; do not resolve these paths against the project directory.

- `references/architecture.md`: components, storage format, compression data flow, file map, testing, troubleshooting.
- `references/auto-compact.md`: automatic compaction, error recovery, adapter detection, adapter support.
- `references/history-ext-api.md`: session history API, save/restore flow, Picker, events, session status API.
- `scripts/trace_visualize.py`: static session trace exporter for Obsidian Canvas and Markdown.

