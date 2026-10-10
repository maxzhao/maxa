# LLM-Facing Tool Interface Contract

MCP tools are LLM/Agent-facing contracts, not human CLI logs, debug streams, or arbitrary low-level APIs. `description`, `inputSchema`, parameters, result shape, and errors determine whether the Agent can choose the right tool, pass valid params, understand state, and continue.

## Core Questions

Each result should answer the minimum questions for its tool type:

1. Did this call succeed?
2. What key result was produced?
3. What state, file, chat, resource, or workflow stage changed?
4. What `path` / `id` / `save_id` / `attempt_id` / `task_id` / `bufnr` should be referenced later?
5. Are there TTL, truncation, async, cache, reload, or restart constraints?
6. If failed, how should the Agent fix params, narrow scope, reread, retry, or validate?

Return the smallest sufficient state delta and required semantic payload. A complete answer is not a debug transcript; preserve it when the owning tool requires completeness.

## Representation By Consumer

Design three separate surfaces: internal structured result/trace, actual LLM-visible payload after transport/wrappers, and UI presentation. Keep internal diagnostics needed for execution/history without publishing every field to the model. A UI fold or summary does not reduce canonical model input.

| Consumer/content | Representation |
| --- | --- |
| LLM-readable answer, document, search lines | Necessary short metadata header plus raw body; avoid JSON-encoding long prose with escaped newlines/quotes. |
| Repeated records or precise field relationships | Compact table or flat JSON, whichever preserves the relationships and is easiest to consume. |
| Machine parser, existing JSON API or outputSchema contract | Preserve the required structured format; do not substitute prose solely to reduce tokens. |
| State change/reference only | Minimal status/id/path facts; omit empty bodies and generic wrappers. |

Rules:

- Do not default to universal `success/data/meta` envelopes. Preserve status only when it distinguishes workflow state, partial/abnormal completion or recovery beyond transport success.
- Include each needed id/fact once. Do not echo inputs, defaults, inheritance/override flags, counts or timestamps unless they affect the next decision.
- For header/body output, define an unambiguous boundary and field meaning. Parse only the header; preserve body quotes, newlines, code and later separators exactly. Schema/UI/history consumers must migrate together; retain compatibility where required.
- Select output-volume policy by owning semantics, not format. Search/list may limit/page and expose truncation; complete SubAgent answers and existing output exemptions must remain complete, without truncation, automatic summarization or file-preview substitution.
- Keep errors on the actual error channel and preserve actionable cause, partial effects, recovery references and uncertainty. Internal success does not imply the user's goal or validation is complete.
- Inspect the final payload seen by the model through sync/async wrappers, not only the handler's table. Confirm UI extraction does not change canonical output or leak duplicate metadata into it.

## Layer Boundaries

| Layer | Owns | Must not own |
| --- | --- | --- |
| `description` / `inputSchema` | purpose, parameter passing, defaults, key side effects | workflow, decision tree, long examples, broad warnings |
| Tool result | facts from this call, state, side effects, key id/path/endpoint, necessary diagnostics | tutorials, generic advice, full logs, unrelated next-step guidance |
| same-named Ability `SKILL.md` / references | when to call, how to combine, how to interpret state/errors | dynamic facts from this call |

Normal success should not return `next_action`, “call xxx next”, generic workflow tutorials, or decision trees. Only workflow-state tools may return minimal mandatory next-step constraints.

Errors may include `errorType`, failed precondition, key path, log path, side-effect status, retryability, and correction hints; avoid long tutorials.

## General Rules

- Optimize for Agent state judgment; human readability is secondary.
- Keep results stable, structured, low-noise, and predictable.
- Do not echo large inputs already present in params: prompts, commands, heredocs, scripts, JSON, base64, full context, or logs.
- For large input identity, return bounded preview plus chars/lines/hash/path.
- Bound large search/list/log payloads through the owning limit/page/file contract; do not apply that policy to semantically complete answers or exempt outputs.
- Represent empty results explicitly: `<empty>`, `none`, `0 matches`.
- Error diagnostics should identify missing field, invalid enum/type, missing path, permission issue, log path, and retryability when relevant.
- Side-effect tools must state what happened; if nothing changed, state that.
- Async/TTL/cache/Native reload tools must state how far the call progressed and when/how effects become visible.

## Parameter Contract

`description` and `inputSchema` are parameter guidance, not full manuals.

- Use clear, non-overlapping parameter names.
- Keep schema property descriptions to one sentence: purpose, default, or key constraint.
- For large/deep JSON, use artifacts through native file parameters or target-supported chunking instead of re-emitting large ordinary parameters. `run`/`multicall` offer no JSON injection; if the target has no suitable input, report the unsupported handoff rather than invent an injection interface.
- Put tool selection, workflow, and prohibitions in the same-named Ability's `SKILL.md` or references. Use `ABILITY.yaml.mcp.overrides` only for root-confined tool/parameter description overrides.
- Document side effects in tool or parameter descriptions when params trigger them.

## Result Contract By Tool Type

### Query

For list/search/get/stats/probe. Include source/scope, match count/total, key items, pagination/truncation/sort/filter, and reference ids/paths/ranges. Do not dump full databases, histories, or logs.

### State Change

For write/delete/move/compact/commit/fire. Include success, changed object, side-effect summary, new path/id/status, and whether validation/refresh/restart is factually required. Do not echo large written content; return chars/hash/path when needed.

### Context Injection

For `load`, include injected object, source, dedupe/force-reload state, TTL/persist/compression behavior, and follow-up reference method. If full content was injected as context, do not repeat it in the normal tool result. Treat `analyze` separately: ordered processing facts precede a separator and the complete raw final answer; do not attach parent pixels or prescribe image TTL handling.

### File Read

May return content, but enforce size limits, line/range metadata, oversized stats, truncation/TTL/persist notes, and actionable next read range.

### Execution

For shell, Windows command, Lua, remote tool proxy, external execution. Include status, exit/error, cwd/env deltas, bounded stdout/stderr or summary. Long commands, scripts, JSON params, and outputs must be bounded; command text already exists in tool call params.

### Media / Binary

Include path or URL, MIME/type/format/size, preview/downscale state, and how to load/view. Do not return base64 or binary body by default.

### Workflow Guidance

For guard, handoff, and state-machine tools. This is one of the few result types allowed to instruct the Agent. Include only current attempt/session/workflow id, stage, required next tool or stop condition, prohibitions, and minimal format constraints. Do not use this style for ordinary query/status/start tools.

### Subagent / Orchestration

For `run_agent`, `fork_agent`, `multi_agent`, workflows. Return the complete required final answer with minimal continuation metadata (save_id, relevant context usage, abnormal finish/recovery state); omit task/config echoes and duplicate ids/counts. Prefer metadata plus raw prose over a JSON string body for LLM consumption. Preserve existing output exemptions. Do not dump child history or inherited context. Verification/blockers belong in the actual answer when relevant, not a fixed tutorial appended to every success.

## Tool Count And Abstraction

Avoid one tool per Agent micro-step.

Priority:

1. Improve existing tool semantics, params, and result shape.
2. Put usage rules, state interpretation, and exception flows in Ability/reference docs; use MCP docs only when requested or already maintained.
3. Add a tool only when responsibility is stable, cannot fit existing tools, and reduces Agent choice burden.

For `start/status/stop`, connection, and managed external resources:

- `start`: may prepare and smoke-test; return minimal facts.
- `status`: return factual state, not a tutorial.
- `stop`: return cleanup result and ownership; server shutdown should best-effort clean managed resources.
- Document when/how to call and interpret states outside tool results.

## Error Result Design

Errors should include:

- failed field or precondition;
- safe summary of received type/value;
- expected format;
- retryability;
- correction direction or diagnostic clue;
- preview + stats + log path for oversized errors.

## Checklist

- [ ] Result alone lets the Agent judge success/failure.
- [ ] Later references such as path/id/save_id/attempt_id are present.
- [ ] Side effects, async, TTL, truncation, or reload limits are explicit.
- [ ] Large inputs are not fully echoed.
- [ ] Output-volume policy matches the owning tool; complete/exempt answers remain complete.
- [ ] Actual LLM payload, internal result and UI have distinct responsibilities; representation follows the consumer, not a universal wrapper.
- [ ] Errors are actionable.
- [ ] Results avoid unrelated tutorials and debug noise.
- [ ] Result shape matches tool type, not another tool's convention.
