---
name: subagent
description: "Select and configure SubAgent MCP execution, prepare task-specific child context, and manage forks, saved-session continuation, multi-agent discussions, tool restrictions, and reusable delegation workflows."
compatibility: Requires Maxa Ability runtime.
---
# SubAgent

Purpose: choose and configure SubAgent execution and prepare sufficient task-specific child context. This composite Ability supplies usage guidance, package references and Native MCP tools in one load; live tool schemas own parameter types/enums, and the system fragment owns pre-load hard rules and child-boundary behavior.

## Tool Map

| Tool | Use |
| --- | --- |
| `run_agent` | Fresh delegated child by default; explicit `run_mode="handoff"` replaces a main or ordinary child session on an authorized message. |
| `fork_agent` | Child Agent with full parent conversation history. |
| `resume_agent` | Restore `save_id`, append messages, continue. |
| `multi_agent` | Role-based discussion and handoff. Requires `agency-nexus`. |
| `handoff` | Internal multi_agent control transfer tool. |

Automatic behavior: token-limit recovery/compaction and child lifecycle management. Chat-backed children run headlessly; explicit display uses a float independent of the main sidebar. History opens as an agent tree (`h/l` navigation, `Ctrl+L` tree/flat toggle); sidebar `}{` visits main Chats only. In-place resume preserves historical ownership while executing as a child.

The loaded `subagent` catalog is authoritative for availability. `ask_llm` is retired. Registered `multi_agent` uses an independent discussion Tab, headlessly created participant Chats and discussion-local handoff; ordinary child tools retain their headless/float behavior.

Before using SubAgent tools, load this composite Ability once; no separate guidance/server load is required:

```yaml
load:
  target: "subagent"
```

## Main-Session Handoff

The system fragment owns permission and type preservation. This main-only workflow transfers ownership; it is not delegated work and does not use the child-session reuse or parent acceptance gates below. Only proceed after the user explicitly requests this handoff; ordinary “continue”, token pressure or errors are not that request. A Chat currently executing as a child uses Child-Session Handoff instead, including a saved main resumed as a child.

1. Preserve the current goal, scope/non-goals, permissions, fixed decisions, modified paths, errors, exact validation results and next action in necessary files under `.maxa/drafts/`. Use one file when sufficient; split larger state by semantic unit and provide an entry file. Reference existing rules/specs/source instead of copying their bodies. Do not include secrets or make temporary state a shared rule.
2. Pass the required drafts with `{role:"context", type:"file", path:...}` messages. Preload known required Abilities and selected guidance using real `tool_call` loads. Handoff retains Runtime/Soul, adapter/model and tools as configured, but does not copy old loaded files/Ability context or conversation; copied tools do not establish fresh Ability authorization. File messages load their full content, so include only necessary material and leave other references for on-demand reading.
3. Invoke `@subagent:run_agent` once through a standalone synchronous `run`, with `run_mode:"handoff"`, a task-specific title and a self-contained `goal_prompt`. Do not use `multicall`, async wrappers, a preparation child, fork, or resume of the old history. Omit nonzero `max_turns`; the new main has the normal Chat lifecycle, not a delegated turn cap.
4. Runtime validates the exact main caller and required files/preloads, saves the new main and returns `status:"handoff_scheduled"` with its `save_id`. This acknowledgement means preparation and switching are scheduled, not that the task is complete. Runtime settles the old tool batch, preserves old history, closes the old Chat and displays/submits the new main. Do not wait for the new task result or add parent-side acceptance.
5. Preparation failure preserves the old Chat and reports the failed item; already completed preload side effects are not rolled back. A later commit failure leaves the old Chat stopped with a visible blocker. The new main verifies the handoff against actual files/worktree and continues execution, validation and delivery directly to the user; it remains open after its final reply. This request does not authorize another handoff.

Example after substituting the actual draft path and current goal:

```yaml
run:
  title: "Transfer the user-requested main session"
  scope: tool
  command: "@subagent:run_agent"
  args: '{"title":"Continue the current implementation","run_mode":"handoff","messages":[{"role":"context","type":"file","path":".maxa/drafts/current-handoff.md"}],"goal_prompt":"Continue the authorized implementation using the handoff file. Verify actual changed paths and recorded checks, preserve scope and decisions, finish the remaining work and deliver directly to the user. Do not initiate another handoff."}'
```

Session's authorized handoff compression reuses the internal type-preserving transfer without invoking public run_agent(handoff) from the temporary planner. It retains the same active-child parent, cancellation and turn budget. Already-ended ordinary child errors return saved IDs without automatically overwriting child or parent history with compact_full; use explicit history tools only under separate authorization.

## Child-Session Handoff

An active persistent child owned by ordinary `run_agent`, `fork_agent` or `resume_agent` may transfer only after an explicit user-message instruction from its main Agent or user. The main Agent issues this instruction through `resume_agent.goal_prompt` after a stage result; the child's token decision may inject it after the user selects handoff. Percentage alone is not permission. Temporary children, restored history without an active delegated executor and dedicated discussion/image controllers cannot transfer.

1. Prepare necessary draft files and real Ability/reference preloads as in Main-Session Handoff steps 1–2; retain the original delegated scope, permissions, worktree/validation state and next action.
2. Invoke one standalone synchronous `run` targeting `@subagent:run_agent` with `run_mode:"handoff"`, the prepared messages and a self-contained continuation goal. Do not set nonzero `max_turns` or delegate to a grandchild. State that the successor verifies current artifacts, finishes the bounded work and returns its result to the same parent; this instruction grants no later transfer.
3. Runtime saves a fresh sibling child, returns `handoff_scheduled` inside the old child, and replaces its execution Chat at the settled tool boundary. The parent's existing delegated call stays pending; cancellation, ask relay, progress and completion follow the successor. Its finite turn budget does not reset. New history has the current invocation parent, not the source's saved historical parent.
4. The parent receives the successor's final result and `save_id` through the original run/fork/resume call and applies normal acceptance. Track the returned successor as the domain owner; the source is retired. Preparation failure leaves the source and parent invocation available and does not roll back completed preloads.

## Tool Selection

For ordinary delegation, first decide whether an existing child session already owns the task domain. Tool selection is session-first, not phase-first:

```text
Need delegation?
├─ Simple/continuous work belongs in main session -> main Agent executes directly
├─ Relevant saved child session exists
│  ├─ continuity useful + capacity sufficient      -> resume_agent
│  ├─ capacity only fits a bounded small follow-up -> resume_agent for that follow-up only
│  └─ settled context suitable for migration        -> resume_agent with one explicit child-handoff instruction
├─ No relevant saved child session exists
│  ├─ one durable implementation/research domain   -> run_agent once, then resume_agent
│  ├─ no tools needed                              -> main Agent or a bounded run_agent
│  ├─ full current conversation is essential       -> fork_agent after size check
│  ├─ reusable base for true branch fan-out         -> run_agent loader, then resume_agent(new_chat)
│  └─ role discussion                              -> multi_agent + agency-nexus
└─ Truly independent parallel branches             -> parallel SubAgent calls after overlap check
```

`run_agent` creates a new history and pays the context-loading cost again. Use it for the first session in a durable domain or a truly unrelated domain—not for the next phase of related work. Prefer message-driven Child-Session Handoff for a suitable existing domain; direct replacement is a fallback when the source cannot execute handoff.

Delegate only independent, bounded, verifiable subproblems. Keep core implementation/debugging/validation in the main session when it depends on accumulated context.

## Reasonable Delegation Protocol

Apply this protocol whenever the user asks to "use SubAgents reasonably", delegates a substantial engineering task, or leaves delegation strategy to the main Agent.

### Main-session ownership

The main Agent owns the goal, architecture and interface decisions, cross-module integration, continuous debugging, conflict resolution, final validation, and completion claim. SubAgents provide bounded work products; they do not take turns owning one continuous implementation chain.

Prefer main-session execution when work:

- depends on accumulated implementation state or repeated error-driven repair;
- crosses modules whose interfaces are still changing;
- requires modifying and validating the same files repeatedly;
- is a small follow-up the main Agent can verify directly;
- is the final integration or release-validation loop.

Good delegation targets are independently reviewable and verifiable: read-only investigation, schema/migration work with a closed boundary, a pure reducer, compile-time contracts, isolated tests, enumeration, or an independent review.

### Session continuity is the default

Use the fewest durable child sessions that can safely complete the work. For one cohesive engineering change, default to **one implementation session** across discovery, schema/contracts, service integration, UI integration, focused validation, and repair when those stages share specifications, interfaces, or a changing worktree. Different directories or technical layers do not by themselves justify new sessions.

After every `run_agent` or `resume_agent` result:

1. record `save_id`, domain, changed paths, validation state, and latest returned `context` usage (or structured `context_status` from session queries);
2. classify it as `resume-safe`, `small-followup-only`, or `retire` for the next known step;
3. before creating any related implementation session, test whether this saved session can continue;
4. use `resume_agent` when continuity is useful and capacity is sufficient.

A new `run_agent` for related work requires at least one explicit reason:

- no saved session has relevant domain/worktree context;
- the prior owning session is `retire` after the capacity gate;
- the new task is genuinely independent, uses non-overlapping ownership, and does not need prior decisions or diffs;
- deliberate role separation is needed, such as one independent reviewer after implementation stabilizes.

Do not use fresh sessions merely because work moves from schema to service, Workflow, UI, tests, repair, or re-review. Do not split a dependency chain into successive fresh Agents such as design -> implementation -> repair -> review repair. Resume the owning session or keep the chain in the main session.

### Run/resume gate

Apply this gate before every `resume_agent` **and before every new `run_agent` after the first child has been created for a task**:

1. Inventory relevant returned `save_id` values and their domains.
2. Read the latest returned `context` usage or queried `context_status` for the best-matching session. If stale or unavailable, load `session` and inspect that saved session.
3. Estimate the next task's exploration, implementation, validation, and expected output size.
4. Prefer the session with useful decisions, loaded context, and worktree knowledge when it has clearly sufficient headroom.
5. Classify it as `resume-safe`, `small-followup-only`, or `retire`. This is task-relative, not a universal percentage threshold.
6. Call `resume_agent` for `resume-safe` or a fitting bounded `small-followup-only` task.
7. If settled work/context can be transferred and the source can still prepare necessary files, use `resume_agent` with an explicit one-time Child-Session Handoff instruction and bounded continuation goal. Do not mark it retired before that preparation. Track the returned successor `save_id` as the new domain owner and retire the source.
8. Create a replacement `run_agent` only when the source cannot execute handoff or another explicit reason under **Session continuity is the default** applies; supply a compact handoff and record why source-driven transfer/reuse was unavailable.

High token use alone does not require retirement when the next task is small and continuity value is high. Low token use strongly favors resume for related work but does not override a genuinely unrelated scope.

A compact handoff contains only the goal, scope/non-goals, frozen decisions, relevant paths, changed files, current errors, validation state, and paths not to re-explore. Do not copy the full old conversation. `resume_mode="new_chat"` still restores historical context and does not reduce its context cost. `fork_agent` also inherits full history and is not a context-saving strategy.

Retired sessions remain history/evidence sources and MUST NOT receive more execution work. Prefer `session` queries over resuming a retired session merely to recover its conclusion.

### Serial-first execution

Default to one child at a time for implementation work. After each child completes:

1. inspect its actual diff/output and scope compliance;
2. run or verify the closest relevant checks in the main session;
3. reconcile findings and interfaces;
4. decide whether the next step belongs to the same domain;
5. if related and the capacity gate passes, resume the same `save_id`; only otherwise justify a new child.

Use synchronous execution when practical. If an explicit user instruction requires serial execution and indefinite waiting, do not launch the next child until the current child reaches a terminal result; use the supported wait path with no wait timeout when asynchronous execution is necessary.

Parallel children are allowed only when tasks are truly independent, interfaces are frozen, file/write scopes do not overlap, and neither result is an input to the other. Apply the shared concurrency budget below before every start/resume/fork, including separate async calls. The main Agent and another child MUST NOT edit the same ownership area concurrently.

Before parallel implementation, map shared hotspots such as registries, enums, dispatch tables, generated/public schemas, dependency manifests, and shared test fixtures. Give each hotspot one owner for the wave; other children report needed edits instead of modifying it. Establish a required shared contract or foundation serially before dependent branches fan out. Worktree isolation defers integration conflicts; it does not remove semantic or public-contract conflicts.

### Reviewer continuity

Prefer one saved reviewer session for initial review and subsequent re-reviews. Resume it after repairs while capacity permits so it can distinguish unresolved findings from resolved ones. Retire and hand off to a new reviewer when the capacity gate fails.

### Mandatory child task contract

Every delegated task states:

- goal and expected deliverable;
- allowed scope and explicit non-goals;
- stop condition;
- required validation;
- return contract: conclusions or changed paths, exact validation, blockers, and unresolved risks.

Do not delegate vague instructions such as "continue the whole task". A child may delegate again only for a smaller independent subproblem under the Child-Agent Boundary.

### Main-Agent acceptance gate

A child report is not completion evidence. The main Agent MUST inspect actual artifacts or source, check for out-of-scope changes, verify delegated claims with project checks, and reconcile code/spec/task state before relying on the result.

Track each returned `save_id` with its domain and current reuse state (`resume-safe`, `small-followup-only`, or `retire`) using returned `context` usage or queried `context_status`. This registry is also the new-session gate: do not call `run_agent` again for related work without checking it. If a child fails or is interrupted, resume the same session when the capacity gate passes; if migration is suitable and the source can prepare it, request Child-Session Handoff through resume. Start a replacement child from a compact handoff only when source-driven transfer is unavailable, and retire the source.

## Shared Concurrency Budget

The entire delegated tree under one top-level Chat MUST have at most **5 active SubAgents** at a time. A delegated coordinator still executing or waiting for descendants occupies one slot; nested delegation shares the same budget. This cap governs Agent scheduling, including concurrent `multi_agent` execution, while ordinary tool batches retain their own tool limits.

Before starting/resuming/forking work, account for active invocations and outstanding descendant allocations. A child receives an explicit share of the remaining slots before nesting; without an allocated share it executes its bounded work directly. For example, one active delegated coordinator leaves at most four slots for all its descendants together.

Reserve a slot through actual completion or confirmed cancellation cleanup. An async submission receipt, wait timeout or stop request alone does not free it. Track async IDs/save_ids and start the next queued work only after capacity becomes available. Separate calls and concurrent batches use this same ledger.

## Parallel Child Agents

Use titled `multicall(mode="parallel")` for independent `@subagent:run_agent`, `@subagent:fork_agent`, or `@subagent:resume_agent` requests. Set explicit `max_concurrency` to the available allocation, from 1 through 5; schedule excess work in bounded waves. Each member has `scope="tool"`, target `command`, and encoded JSON object `args`; no member `label` exists. Normally omit member `title`; keep any target-required child title inside `args`. The declaration returns closure facts; each child response remains a separate full member output, not a nested aggregate.

With member `opts.async`, invocation submission finishes before the child does. The batch's `max_concurrency` therefore limits submissions only; submit at most the available child slots in each wave and wait for actual terminal results before submitting replacements.

Requirements:

- Apply the Serial-first and capacity-gate rules above before choosing parallel execution.
- Each child task has goal, scope, non-goals, stop condition, validation, expected return format, concise dynamic `title` when required, and an explicit remaining-slot allocation when nested delegation is permitted.
- Child prompts are Agent-facing artifacts: conclusion, key evidence, paths/symbols, validation, blockers, `save_id` when useful.
- Preserve exact paths, line references, commands, errors, tool/API names, task ids, `save_id`, and validation results.
- Main Agent reviews and integrates every child result; delegation output is not proof until verified.
- Integrate parallel implementation serially in dependency order. After each integration, rerun applicable contract, generated-surface, and real integration checks before rebasing or accepting followers; a clean merge is not validation evidence.
- Do not distort architecture merely to make branches disjoint. Serialize a legitimate shared-owner edit instead of duplicating a deep module or public authority.
- If only one synthesized conclusion is needed and branch results need not be preserved, prefer `multi_agent` or main-session analysis.

## Context Preparation Sessions

Use when the user asks to create a reusable loaded child context for later SubAgents, such as “context preparation session”, “prepare a save_id for later agents”, or “load the required knowledge first, then branch tasks from it”.

Flow:

1. Base loader: call `run_agent` to create a normal saved child session.
2. Prepare required Abilities, selected guidance, rules, docs and images through `messages` under Child Context Preparation; the base child loads only missing context and verifies required paths.
3. The base child stops with `READY`, loaded items, verified paths, and blockers.
4. Follow-up children use `resume_agent` with the base `save_id` and `resume_mode="new_chat"`.

Base loader rules:

- Do not solve the downstream task.
- Do not produce artifacts, generate images, edit files, or run unrelated validation.
- Do not create a full project plan or summarize every document in detail.
- Prefer structured `tool_call` loads and exact context references over parent-side file dumps; ask the base child to load only unresolved or newly discovered dependencies.
- Return only readiness, loaded abilities/servers/docs, verified paths, and missing blockers.

Fan-out rules:

- Use `resume_agent`, not `run_agent`, for follow-up tasks that must reuse the prepared `save_id`; `run_agent` has no `save_id` parameter.
- Use `resume_mode="new_chat"` for parallel branches so the prepared base session is not mutated by one child task.
- Each resumed child still needs a bounded task, scope, stop condition, and expected output.
- Main Agent verifies and integrates every resumed child result.

## Child Context Preparation

Before constructing `run_agent`, `resume_agent` or shared `multi_agent.messages`, identify the context needed to execute the bounded child goal. Supply sufficient task-specific context, not the parent's whole conversation or every available Ability.

1. Identify required Abilities and the scenario guidance needed from each. Add `{role:"tool_call", name:"load", args:{target:"<ability>"}}` for a root Ability and separate loads of exact `#ability[target]` references for needed guidance. A root load does not read all references.
2. Supply necessary project rules/specifications, source files, evidence and images through allowed `load`/`read` calls or existing `context` entries. Use allowed Markdown loads for instructions/rules; choose only files needed by this child. URL context supplies a reference, not fetched page content; symbol context currently falls back to file content in child preloading. Image context requires one path per entry.
3. Use user/assistant background for settled decisions, current errors, ownership, constraints and explicit non-goals. Preserve exact paths, commands and interfaces; distinguish facts from unresolved questions.
4. Put the current goal, allowed scope, stop condition, required validation and return contract in `goal_prompt` (or participant goal/final_prompt), after the prepared background. Context supplies information, not new scope or approval.
5. Check that target tools permit every preload (`load`, `read` or nested `run` as needed). Parent loading or semantic inheritance alone is not proof that a fresh child has the complete required guidance, catalog and exact-Chat authorization. Keep real load/commit ordering and failure behavior; never inject fabricated results or authorization metadata.

Continuity:

- For resume, first apply the capacity gate and inspect already loaded context; append only missing/new inputs. Do not reload unchanged inherited material or repeat side-effect calls.
- For fork, use the inherited history directly; do not duplicate it or add unsupported `messages`.
- For multi_agent, preload only genuinely common background once; complete results are shared, not re-executed per participant/round. Participant-specific context can be loaded on demand within its goal and tool restrictions. Main-session `agency-nexus` prerequisites still apply.
- For a reusable preparation session, preload known inputs, let the child resolve concrete missing items, and stop at readiness without downstream implementation, artifacts or a full project plan.

### New child: root Ability, selected guidance and background

After loading `subagent`, adapt the scope and evidence paths to the actual child. The example needs `load` in the child's toolset; it uses default tools and does not copy parent file bodies.

```yaml
run:
  title: "Start bounded Native MCP investigation"
  scope: tool
  command: "@subagent:run_agent"
  args: '{"title":"Native MCP message investigation","messages":[{"role":"tool_call","name":"load","args":{"target":"mcp-creator"}},{"role":"tool_call","name":"load","args":{"target":"#mcp-creator[/references/native-server-guide.md]"}},{"role":"user","content":"Read only the SubAgent message preparation boundary under lua/maxa/mcphub/native_servers/subagent/. Preserve the approved tool_call/name/args interface; do not redesign adjacent modules."}],"goal_prompt":"Locate how background messages reach the child Chat. Do not modify files or delegate. Stop after identifying the owning paths and call order; return evidence, blockers and any validation gap."}'
```

### Resume: supplement missing context only

Apply the resume capacity gate first. This example assumes the saved child already has `mcp-creator` and `native-server-guide.md`, but lacks the LLM-facing contract reference. Replace the save_id with the returned relevant history ID; do not repeat unchanged root loads or prior side effects.

```yaml
run:
  title: "Continue the saved message investigation"
  scope: tool
  command: "@subagent:resume_agent"
  args: '{"save_id":"<returned-save-id>","messages":[{"role":"tool_call","name":"load","args":{"target":"#mcp-creator[/references/llm-facing-tool-contract.md]"}},{"role":"user","content":"The public tool_call/name/args interface is fixed. Review only its message contract using the existing findings; no code changes."}],"goal_prompt":"Check the identified contract for actionable parameter and result guidance. Do not edit or delegate. Stop with concrete findings, owning paths and verification gaps."}'
```

### Discussion: load common context once

Load `agency-nexus` in the main session before this discussion. Both participants need the same Ability/reference; the shared preloads execute once. Do not place repeated side-effect work in shared context, and preserve each participant's restrictions.

```yaml
run:
  title: "Discuss the message contract"
  scope: tool
  command: "@subagent:multi_agent"
  args: '{"title":"Message contract discussion","messages":[{"role":"tool_call","name":"load","args":{"target":"mcp-creator"}},{"role":"tool_call","name":"load","args":{"target":"#mcp-creator[/references/llm-facing-tool-contract.md]"}},{"role":"user","content":"Keep the registered tool names and tool_call/name/args interface. Discuss only whether supplied context is sufficient for a bounded child; do not edit files."}],"agents":[{"name":"ContextReviewer","role":"Context completeness reviewer","goal_prompt":"Use the shared background to identify required versus redundant context. No edits or delegation. Return concise evidence, then hand off to BoundaryReviewer."},{"name":"BoundaryReviewer","role":"Authorization and scope reviewer","goal_prompt":"Use shared background and public discussion to check tool restrictions and ownership. No edits or delegation. Return concrete risks or no findings, then hand off to user."}],"task":"Review the fixed child context contract without implementation work.","final_agent":"fork","final_prompt":"Synthesize the public findings using the shared context. Do not edit or delegate. Stop with the required context, any concrete gap and no speculative redesign."}'
```

## Default Tool Behavior

| Tool | Default tools/config | Notes |
| --- | --- | --- |
| `run_agent` | all Chat builtins in independent mode; parent semantic config in inherit mode | `restrict_tools` only limits tools. |
| `fork_agent` | inherits parent history, tools, adapter/model, runtime config | Adds a user-role fork boundary. No `restrict_tools`/`temperature`. |
| `resume_agent` | inherits restored history tools when possible | Pass the Resume capacity gate first. `restrict_tools` only limits. Default `resume_mode="in_place"`. |
| `multi_agent` | independent hidden chats; handoff tool | Phase 2 `fork` or `run`. |

## Parameter Discipline

Default minimal call: set only task-body fields and required identifiers.

Task-body fields include required `goal_prompt` for run/fork/resume, optional background `messages`, `save_id`, `task`, `final_prompt`, and dynamic `title` when required. Do not add `inherit`, `preset`, `restrict_tools`, `soul`, `max_turns`, `temperature`, `warmup`, `run_mode`, `fork_mode`, or `resume_mode` unless one condition applies:

- the user explicitly asked;
- task semantics clearly require it;
- the tool schema requires it;
- safety or boundary constraints make it necessary and the reason is stated.

Rules:

- `title`: required for `run_agent`, `fork_agent`, `multi_agent`; optional for `resume_agent` and defaults to restored title. Generate a short task-specific title; do not copy examples.
- `resume_agent`: pass the Resume capacity gate before every call. Default `resume_mode="in_place"` appends to the same `save_id` and refuses if that history is already open. Use `new_chat` when a separate resumed history is intended, including context-preparation fan-out from a base `save_id`; it does not reduce restored-history context cost.
- `run_agent`: do not set `inherit` for ordinary calls. `restrict_tools` only limits tools; it does not change adapter/model/role/context inheritance.
- After a child session exists, treat another `run_agent` as an exception requiring the Run/resume gate. Related follow-up, implementation phase, repair, validation, and re-review work normally use `resume_agent` on the owning `save_id`.
- Do not use `run_agent` for follow-up tasks that should reuse prior child decisions, loaded files, worktree knowledge, or a prepared `save_id`; use `resume_agent` instead.
- `fork_agent`: always inherits parent chat; no `restrict_tools`, `temperature`, or `warmup`. Use only when full current history is required and has acceptable size; it is not a token-saving delegation mode.
- `resume_agent`: default preserves restored adapter/model and tools; set `preset` only when explicitly requested.
- `warmup`: only `run_agent`; set only for prompt-cache debugging/verification or explicit user request. Do not set `warmup="force"` or `warmup="disable"` for speed/token guesses.
- `restrict_tools: []` removes all tools; use only with explicit user request or strong safety reason.
- Tool names in `restrict_tools` must be registered bare first-party builtins such as `read`, `load`, or `run`. Ability targets such as `@session:get_session_status` remain targets of `run(scope="tool")`, not registry schema names. Selecting `run` permits its command and tool modes subject to runtime guards; it is not a mode-specific allowlist.
- `preset` omitted means inherit source adapter/model when available; without a source Chat use `maxa.defaults.chat`.
- `goal_prompt` states the current goal, scope, constraints, stop conditions and return format. It is appended as the final user message after background/history; do not put parent-side orchestration commands such as `use fork_agent` inside it.
- Optional `messages` retain user/assistant background roles, preload file/symbols/url/image context, and accept `{role:"tool_call", name:"<registered bare tool>", args:{...}}` before the goal; no user task is required in that array. Runtime executes real calls serially, generates paired history/IDs, and commits deferred context before the next item. Calls use the target Chat's available tools, schema, approvals and authorization; errors/cancellation stop later calls and model execution without rolling back completed side effects. Do not supply results, IDs or authorization metadata. Ability actions use `name:"run"` with `scope:"tool"`; literal `@load` text does not execute. Background calls do not consume LLM response turns. `multi_agent.messages` executes shared calls once in its Display/final Chat using caller tools, then persists/copies the completed snapshot to participants and final execution, including continuation; it does not repeat side effects per participant or round.
- `instructions` is retired and rejected; migrate ordinary/participant assignments to `goal_prompt`, final-run assignments to `final_prompt`. Goals never modify Runtime/Soul or select independent mode.
- Do not repeat context already available in the child's inherited history. Do not use special syntaxes such as `@{variable}` or `#{resource}`.
- Prepare known required Abilities and relevant guidance through `messages` under Child Context Preparation, rather than only naming them in the goal. Child discovery may add concrete missing dependencies within scope; do not invent execution conditions the user did not request.

## Role, Inherit, And Fork Semantics

| Concept | Meaning |
| --- | --- |
| `inherit` | New session inherits parent role/system prompt, tools, and context metadata; does not itself control adapter/model. |
| independent mode | Triggered by `inherit=false` or `soul`; omitted preset still inherits parent settings or uses defaults.chat. Goals do not change mode. |
| `fork_agent` | Deep-copies full parent message history plus config. Use when prior conversation content itself is required. |
| `soul` | Complete Soul source: exact `#ability[/path]` file, explicit absolute/`~/`/`./`/`../` path, or inline text. Matching references/paths fail closed; Soul composition never activates resource access. |
| `goal_prompt` | Current execution goal, appended as the last user message. Participant goals default to `task`; the final goal is `final_prompt`. |

Effective inheritance is incompatible with `soul`; without a parent, explicit `inherit=true` still resolves to independent mode. `restrict_tools` only limits tools. Soul inputs replace only Soul, never the common Runtime or tool authorization. Legacy `soul_prompt`/`soul_file` inputs remain compatibility-only and are not public schema fields; retired `role_prompt`/`role_file` names are rejected.

## Child-Agent Boundary

Child Agents may use SubAgent tools for smaller subproblems, supervision, repair, verification, or role separation. They must not recursively pass through the parent request unchanged.

Allowed:

- supervisor child starts execution/repair/review children;
- child delegates an independent subproblem with scope and stop condition;
- child resumes a relevant `save_id`;
- child uses a limited multi-agent discussion.

Forbidden:

- child receives a parent task and immediately creates another child for the same task;
- next child prompt is only a restatement without smaller scope, boundary, stop condition, and return format;
- multiple layers ask each other to continue the same goal.

## Required Companion Abilities

| Use | Load first |
| --- | --- |
| `multi_agent` | `agency-nexus` |
| `run_agent` with an Agency role reference in `soul` | `agency-nexus` when selecting Agency roles |

Do not build multi-agent calls without the companion Ability.

## Completion And Results

| Tool | Completion condition |
| --- | --- |
| delegated `run_agent` / `fork_agent` / `resume_agent` | no tool calls or `max_turns` reached |
| `run_agent(run_mode="handoff")` | preparation acknowledgement inside the invoking session; safe-boundary main switch or same-parent child replacement. A child's original parent call still waits for successor completion. |
| `multi_agent` | handoff to `user`, max rounds/messages, or Phase 2 completion |

Ordinary run/fork/resume returns short metadata followed by the first exact `---` separator and the complete raw final answer. `save_id` identifies the actual completing child once (omitted for temporary calls); `context` gives percent, used/limit and source, or `unavailable`. Natural completion/config defaults, goal, message counts and inheritance/override diagnostics are not echoed. Non-completed termination keeps `finish_reason`; a differing resume/transfer source keeps `source_save_id`. Treat only the header as metadata; code, JSON and later separators belong to the answer.

multi_agent returns `session_id` and applicable final `save_id` plus the complete final answer. Handoff preparation returns only `status: handoff_scheduled` and successor ID, not final output; a child transfer leaves its outer delegated call waiting for the successor's result. Discussion handoff returns status, new public contributions and necessary private notes. Errors retain actual cause/recovery references. Full SubAgent answers remain exempt from output truncation; UI folding does not change model content. Internal trace data remains structured; session queries still return structured `context_status`.

Use returned `save_id` with `session` when fresh history status or summary is needed:

```yaml
load: { target: "session" }
run:
  title: "Inspect child session summary"
  scope: tool
  command: "@session:get_chat_summary"
  args: '{"save_id":"<returned save_id>"}'
```

## Usage Patterns

After `load(target="subagent")`, invoke only cataloged targets through titled `run(scope="tool", command="@subagent:<tool>", args=<encoded JSON object string>)`; names such as `run_agent` are not bare builtin entrypoints. Wrapper title is separate from the target's child-session title; do not rename target business fields.

### Fork current context

```yaml
run:
  title: "Request security review"
  scope: tool
  command: "@subagent:fork_agent"
  args: '{"title":"Security review","goal_prompt":"Review the current plan for security gaps. Return findings, evidence, and uncertainty."}'
```

### Default run_agent

```yaml
run:
  title: "Request auth audit"
  scope: tool
  command: "@subagent:run_agent"
  args: '{"title":"Auth audit","goal_prompt":"Audit src/auth for high-value risks. Return findings with file paths and validation gaps."}'
```

Do not add `inherit`, `preset`, `restrict_tools`, `soul`, `max_turns`, or `run_mode` unless justified by the user/task.

### Explicit Agency Soul

Load `agency-nexus` before selecting a role, then pass its exact role reference through `soul`.

```yaml
run:
  title: "Request OWASP audit"
  scope: tool
  command: "@subagent:run_agent"
  args: '{"title":"OWASP audit","soul":"#agency-nexus[/agents/engineering/security-engineer.md]","goal_prompt":"Audit src/auth/. Focus on OWASP Top 10; read relevant files and output an evidence-backed ranked risk table."}'
```

Exact Ability references resolve before explicit paths; all other strings are complete inline Souls. If a value matches reference or path syntax but cannot be read, the call fails instead of reinterpreting it as text.

### Durable implementation session

Start once:

```yaml
run:
  title: "Start implementation session"
  scope: tool
  command: "@subagent:run_agent"
  args: '{"title":"Feature implementation","goal_prompt":"Implement the first bounded slice. Return changed paths, validation, blockers, unresolved risks, and context status."}'
```

For related integration, repair, or validation, check returned `context` usage or query `context_status`, then continue the same session:

```yaml
run:
  title: "Continue implementation session"
  scope: tool
  command: "@subagent:resume_agent"
  args: '{"save_id":"<history-save-id>","goal_prompt":"Continue with the next related bounded slice using the existing decisions and worktree context. Return changed paths, exact validation, blockers, and remaining risks."}'
```

Do not replace this resume with a fresh `run_agent` merely because the next slice owns different files.

### Resume history

```yaml
run:
  title: "Resume historical analysis"
  scope: tool
  command: "@subagent:resume_agent"
  args: '{"save_id":"<history-save-id>","goal_prompt":"Continue the remaining analysis. Preserve prior decisions and report validation gaps."}'
```

### Context preparation session

Create the base context with `run_agent`; preload known task-specific inputs and let the child resolve only concrete missing items, then stop at readiness. Adapt the Ability and paths to the actual downstream task.

```yaml
run:
  title: "Prepare reusable MCP context"
  scope: tool
  command: "@subagent:run_agent"
  args: '{"title":"MCP context loader","messages":[{"role":"tool_call","name":"load","args":{"target":"mcp-creator"}},{"role":"tool_call","name":"load","args":{"target":"#mcp-creator[/references/native-server-guide.md]"}}],"goal_prompt":"Prepare a reusable context session for bounded Native MCP investigation. Confirm the injected guidance and required source paths; load only concrete missing task inputs. Do not execute downstream work, generate artifacts, modify files or create a full project plan. Stop with READY, loaded items, verified paths and blockers."}'
```

Fan out later tasks from the returned `save_id` with separate resumed chats.

```yaml
run:
  title: "Branch prepared context"
  scope: tool
  command: "@subagent:resume_agent"
  args: '{"save_id":"<base-save-id>","resume_mode":"new_chat","goal_prompt":"Use the prepared context for this bounded task only. Return created paths, validation, blockers, and next steps."}'
```

### Parallel analysis

Use the Parallel Child Agents contract above for independent SubAgent targets. Each target request retains its required child title, goal/scope, stop condition, and output contract inside encoded `args`. Main Agent synthesizes and verifies the separate member outputs. When asynchronous execution is necessary, set `opts='{"async":true}'` on the relevant member and track its independent async ID with `wait`/`kill`; submission completes that invocation, not the child task. There is no batch async option or aggregate result. Do not put wrapper async into target arguments, nest `multicall`, or target `run`/`multicall` through tool-mode members. Handoff remains a standalone synchronous `run`, never a batch member.

After the Serial-first and capacity gates permit two independent read-only reviews:

```yaml
multicall:
  title: "Review independent auth modules"
  mode: parallel
  max_concurrency: 2
  runs:
    - scope: tool
      command: "@subagent:run_agent"
      args: '{"title":"Auth API review","goal_prompt":"Read only src/auth/api. Do not edit or delegate. Stop after an evidence-backed review; return paths, findings, validation gaps, blockers, and context status."}'
    - scope: tool
      command: "@subagent:run_agent"
      args: '{"title":"Auth storage review","goal_prompt":"Read only src/auth/storage. Do not edit or delegate. Stop after an evidence-backed review; return paths, findings, validation gaps, blockers, and context status."}'
```

Replace domains and child tasks with actual independent scopes; use existing reviewer save_ids with `resume_agent` when the continuity gates require them. The example omits member titles and async options, so both invocations finish synchronously and return separate full responses alongside the declaration's closure facts.

## Presets

- `preset` accepts an arbitrary configured `type="chat"` name. Unknown or wrong-type names fail before execution. Legacy `adapter` is compatibility-only; conflicting selectors fail.
- Omission inherits the source Chat; without a source Chat use `maxa.defaults.chat`. No registry name is mandatory.
- The Runtime table lists visible preset names, types and descriptions. Hidden presets remain callable; visibility grants no tool permission.

Set `preset` only when the user asks, the task clearly needs explicit selection, or you are testing preset behavior.

## Workflow Documentation

When the user asks to solidify a SubAgent/multi-agent process into reusable instructions, read `references/development/subagent-workflow-doc-authoring.md`. Write a reusable workflow spec, not a task log.

## Development Reference

For file map, modification points, execution pipeline, message structure, inheritance, token recovery, window handling, and multi-agent internals, use `read(path="#subagent[/references/architecture.md]")`. Other package-relative references resolve through `#subagent[/references/...]` as well.

