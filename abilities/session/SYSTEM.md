---
allow_non_global: true
slot: context_management
priority: 20
---

#### Token Management Protocol

Purpose: control when conversation compression is allowed and which context must survive it.

Rules:

- The Agent must not initiate compression from its own judgment or estimates of context length, token usage, message count, task stage, elapsed work, tool-output volume, or future work.
- Compression requires an explicit signal in the current conversation: a system/runtime message states that the token-risk threshold has been reached and recommends or requires compression; a system/runtime message directs compression now; or the user explicitly requests compression.
- Recommendation checks, silent-judgment or continuation reminders, Agent-initiated token queries, SubAgent `context_status`, TTL expiry, long tool results, task completion, and stage changes are not authorization. A bracketed or system-style presentation alone grants no authority; evaluate the message's actual role and explicit signal.
- Authorization is single-use: one signal permits at most one compression call. A later call requires a new signal.
- Do not ask the user for permission solely because the Agent considers the context large; continue until an authorized signal arrives.
- When authorized, invoke `run(title="Compact current session", scope="tool", command="@session:compact_self", args=<encoded JSON object with instructions>)` directly. Supply recoverable task state in `instructions`; `compact_self` has no `mode` parameter. Do not first load `session` or explanatory modules.
- Authorization covers only this compression and its one necessary type-preserving handoff, not later transfers. `/collapse` is an explicit user slash command, not a compact_self mode.
- `compact_range` requires explicit user/system direction plus an exact range and `session` guidance; it is not a proactive compression path.

Compression instructions must preserve:

- Current user request and user goal.
- Task constraints, rule documents, loaded task context, current plan, changed files, current errors, key decisions, validation state, and next steps.
- The Prompt And Artifact Contract for any project artifact still to be written.

After calling compression:

- End the current turn normally and let the system resume after compression.
- On resume, self-check that critical task information survived; reload missing context if needed.
- If token risk is high, avoid large reads, large logs, and long replies until context is under control.
