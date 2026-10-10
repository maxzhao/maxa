# Agency Role And Discussion Operations

Purpose: configure a selected specialist or bounded discussion. Paths in this handbook are relative to the `agency-nexus` Ability root. Read only sections needed for the chosen mode; `subagent` owns current tool contracts, child-context preparation, execution ownership, and session continuity.

> **Based on**: [The Agency](https://github.com/msitarzewski/agency-agents) specialist AI agent roles, adapted for this local role catalog
> **Runtime**: Maxa common Runtime with replaceable Souls via SubAgent. Use discussion tools only when present in the loaded `subagent` catalog; role selection grants no permission to enable unavailable tools. Registered `multi_agent` retains its independent discussion Tab.
> **Purpose**: Orchestrate teams of specialist agents for collaborative analysis, review, planning, and execution

## Overview

This Ability enables you to assemble teams of specialist AI agents (from The Agency's role library) and run structured multi-agent discussions using the `multi_agent` tool. Each agent has a unique personality, expertise domain, workflow, and communication style.

**NEXUS** = **N**etwork of **EX**perts, **U**nified in **S**trategy — the orchestration approach from The Agency that coordinates specialist agents through structured phases with quality gates.

**You** (the main agent / Maxa) are the **orchestrator**. You:
1. Analyze the user's request
2. Select appropriate specialist agents
3. Build `multi_agent` tool call parameters
4. Execute the discussion
5. Deliver the result

## Using Roles with run_agent

Agency roles can be used as **standalone agents** via `run_agent`'s `soul` parameter. This is simpler than `multi_agent` — one specialist agent working autonomously on a task.

**When to use run_agent vs multi_agent**:
- **run_agent + role**: Single specialist working alone (e.g., security audit, code review by one expert)
- **multi_agent + roles**: Multiple specialists collaborating (e.g., architecture discussion with diverse perspectives)

**Example** — Security audit with Security Engineer role:
```yaml
run:
  title: "Request specialist security audit"
  scope: tool
  command: "@subagent:run_agent"
  # Target title is required: generate it for the actual task rather than copying the placeholder.
  args: '{"title":"<根据当前任务填写的简短标题>","soul":"#agency-nexus[/agents/engineering/security-engineer.md]","goal_prompt":"Perform OWASP Top 10 audit on src/auth/. Read the relevant files and return an evidence-backed ranked risk table."}'
```

**Role reference pattern**: `#agency-nexus[/agents/<division>/<filename>.md]`. Exact references can load excluded catalog files even though the parent Ability catalog does not list them.

Refer to the **Agent Selection Quick Reference** below or `references/agent-catalog.md` for available roles.

**Soul source**: `soul` accepts an exact Ability reference, explicit file path, or complete inline definition. An Agency reference retains the complete selected role, including cases, code examples, templates, methods and tool preferences. It replaces only Soul, never the common Runtime.

## Soul And Discussion Context

Keep complete Soul sources. Do not prescribe source/token length caps, mandatory condensation or example deletion. Keep task messages and discussion handoffs focused on the actual assignment rather than duplicating loaded context. Preserve exact Soul paths, Ability/tool names, commands, security findings and validation evidence; never shorten safety-critical findings or ordered handoff rules into ambiguous fragments.

## Execution Modes (multi_agent)

For mode selection, phase chaining, Dev↔QA loops, and quality gates, see `references/nexus-playbook.md`. For handoff behavior, termination rules, and final synthesis responsibilities, see `references/handoff-protocol.md`.

| Mode | Agents | Duration | When to Use |
|------|--------|----------|-------------|
| **Micro** | 2-5 | Single discussion | Code review, brainstorm, focused analysis |
| **Sprint** | 5-10 | Multiple discussions | Feature design, architecture planning |
| **Full** | 10+ | Multi-phase pipeline | Product development lifecycle |

**Default**: Start with **Micro** mode. Escalate to Sprint/Full only when explicitly requested or when task complexity demands it.

## Discussion Setup

The following sections cover selection, role construction, calls, and results. Reuse known role/context decisions; they are not a mandatory itinerary for standalone role use. Preserve actual tool dependencies and validate the resulting deliverable.

### Step 1: Analyze the Request

Determine:
- **Task type**: review / brainstorm / analysis / planning / debugging / design
- **Execution mode**: Micro (default) / Sprint / Full
- **Required expertise domains**: engineering, design, testing, product, etc.

### Step 2: Select Agents

Read `references/agent-catalog.md` to find suitable agents.

**Selection rules**:
- Micro: Pick 2-5 agents with **complementary** perspectives (avoid overlap)
- Include at least one "challenger" role (e.g., Reality Checker, Security Engineer) for critical tasks
- Identify which Abilities each agent needs (described in the Soul, not in restrict_tools)

### Step 3: Load Agent Definitions

For each selected agent, use the exact `#agency-nexus[/agents/<division>/<filename>.md]` reference. Read it only when its contents are needed for selection or review; pass the same reference directly through `soul`.

Use the complete file through `soul`. Its capabilities, methods, cases and tool preferences remain part of the Soul; common loading/authorization rules come from Runtime. Set per-assignment goals/constraints in `goal_prompt`, appended as the final user message. Retired `instructions` is rejected. Omit `adapter` unless the user/task justifies a preset override under `subagent`.

**Inline Soul example** — an independent inline definition, not a requirement to replace a selected complete file with a summary:

```
You are Reality Checker, an integration reviewer. Assess the requested
outcome against actual artifacts, relevant checks, and acceptance criteria.

Return actionable findings with locations, evidence, and impact, or report
that the examined criteria pass. Distinguish missing evidence from a proven
defect. Do not prescribe a score, rejection verdict, or revision count in
advance. Request further checks only for changes, failures, or unresolved
concerns; otherwise proceed to completion.
```

### Step 4a: Follow SubAgent Tool Protocol

Before using `multi_agent` or `run_agent`, load the composite `subagent` Ability once and follow its child-context preparation, parameter rules, and runtime constraints. This load provides guidance and tools together. This Ability owns Agency role selection and orchestration patterns only.

### Step 4b: Build and Call multi_agent

Use `multi_agent` only when the loaded `subagent` catalog exposes it. Supply common facts/evidence through shared `messages`; each participant and final executor receives the same loaded background. Assign participant goals through `goal_prompt` (default `task`); `final_prompt` is the final executor's last user message.

```yaml
run:
  title: "Request expert discussion"
  scope: tool
  command: "@subagent:multi_agent"
  # Conditional target illustration only. Generate the target title and complete agents list.
  # soul may instead contain an explicit path or complete inline Soul.
  # Omit adapter/restrict_tools unless justified; final_agent must be fork or run.
  args: '{"title":"<根据当前讨论任务填写的简短标题>","messages":[{"role":"user","content":"<Shared facts, constraints and evidence>"}],"agents":[{"name":"<Agent Name>","role":"<One-line role description>","soul":"#agency-nexus[/agents/<division>/<filename>.md]","goal_prompt":"<Participant objective and deliverable>"}],"task":"<Shared discussion objective>","termination":{"max_rounds":10,"min_rounds":2},"final_agent":"fork","final_prompt":"<Final synthesis objective and deliverable>"}'
```

⚠️ **Do NOT set `restrict_tools`** unless you need to **restrict** an agent's toolset. By default, all agents receive the full Chat builtin toolset (read/write/edit files, execute commands, load Abilities, call tools, etc.).

**`final_agent` — `fork` vs `run`**:

| Mode | Behavior | When to Use |
|------|----------|-------------|
| `"fork"` | Retains shared messages/public discussion, inherits parent Runtime/Soul, adapter and tools; does not copy the parent's full transcript. | **Default choice** for synthesis with parent capabilities. |
| `"run"` | Retains shared messages/public discussion; `final_agent_config` selects inherited or custom Soul/tools and adapter preset. | Use a specific final role or tool restriction. |

Use `fork` unless you have a specific reason to use `run`.

### Step 5: Interpret Results

The `multi_agent` call returns:
```json
{
  "success": true,
  "data": {
    "content": "<Phase 2 agent's final output>",
    "save_id": "<session ID for history>"
  }
}
```

**If success**: Deliver `content` to user, optionally summarize
**If failed**: Check error message, adjust parameters, retry once

## Agent Selection Quick Reference

All agents receive **full Chat builtin tools by default**. Differentiate agents through `soul` (role identity) and `goal_prompt` (current objective); share baseline evidence through top-level `messages`. Agents can self-load additional files via `read` / `load`.

### Code Review Team
| Agent | File | Role | Capability Hints |
|-------|------|------|------------------|
| Security Engineer | engineering/security-engineer.md | Vulnerability analysis | — |
| Backend Architect | engineering/backend-architect.md | Architecture review | — |
| Senior Developer | engineering/senior-developer.md | Code quality | — |
| Reality Checker | testing/reality-checker.md | Evidence-based assessment | — |

### Architecture Discussion Team
| Agent | File | Role | Capability Hints |
|-------|------|------|------------------|
| Backend Architect | engineering/backend-architect.md | System design | — |
| Frontend Developer | engineering/frontend-developer.md | Client perspective | — |
| DevOps Automator | engineering/devops-automator.md | Infrastructure | — |
| UX Architect | design/ux-architect.md | UX foundation | — |

### Brainstorm / Ideation Team
| Agent | File | Role | Capability Hints |
|-------|------|------|------------------|
| Trend Researcher | product/trend-researcher.md | Market intelligence | Ability: `web-fetch` |
| Sprint Prioritizer | product/sprint-prioritizer.md | Prioritization | — |
| Rapid Prototyper | engineering/rapid-prototyper.md | Feasibility | — |
| UX Researcher | design/ux-researcher.md | User perspective | Ability: `web-fetch` |

### Bug Investigation Team
| Agent | File | Role | Capability Hints |
|-------|------|------|------------------|
| Backend Architect | engineering/backend-architect.md | System diagnosis | — |
| API Tester | testing/api-tester.md | Endpoint validation | Ability: `web-fetch` |
| Performance Benchmarker | testing/performance-benchmarker.md | Performance analysis | — |
| DevOps Automator | engineering/devops-automator.md | Infrastructure check | — |

### Quality Assurance Team
| Agent | File | Role | Capability Hints |
|-------|------|------|------------------|
| Evidence Collector | testing/evidence-collector.md | Visual QA | MCP: `browser` |
| Reality Checker | testing/reality-checker.md | Integration assessment | — |
| API Tester | testing/api-tester.md | API validation | Skill: `web-fetch` |
| Accessibility Auditor | testing/accessibility-auditor.md | A11y compliance | — |

**Capability Hints** = Abilities recommended by the Soul or assignment. Agents load them on demand with `load`.

For complete catalog, read `references/agent-catalog.md`.
For scenario-specific templates, read files in `references/`.

## Key Constraints

### Tool & Capability Model

**Default tools**: All agents automatically receive the full Chat builtin toolset (file I/O, shell commands, Ability loading, tool calling, etc.) plus the mandatory `handoff` tool. **Do NOT set `restrict_tools` unless you need to restrict an agent.**

**Capability architecture**:

| Layer | Mechanism | How Agents Use It |
|-------|-----------|-------------------|
| **Built-in tools** | Always available | `read`, `run`, etc. — use directly |
| **Abilities** | `load` | Load domain instructions and exact-Chat MCP authorization when present |
| **Ability targets** | `run(scope="tool")` / `read` | Invoke committed scripts/tools or read committed files/resources |

**How to assign capabilities**: Include capability hints in an inline `soul` when deliberately defining a custom role:

```
# In an inline Soul for an API Tester:
...
Available MCP services (load on-demand with load):
- context7 — third-party library documentation

Available Abilities (load on-demand with load):
- web-fetch — web search and URL/content extraction
- browser-e2e — E2E testing patterns
```

The agent follows Runtime's Ability Gate and loads its own required Abilities in the exact child Chat. A Soul recommendation does not itself load or authorize a capability.

**Only set `restrict_tools` when you want to restrict**: For example, a pure brainstorm agent that should NOT read files:
```yaml
restrict_tools: []  # Handoff only — no file access, no commands
```

### Agent File Access

Use `multi_agent.messages` context entries to preload common files/images or URL references for all participants and the final executor. Agents can also self-load additional sources using their built-in tools:
- `read` — read source code or data files
- `load` — load reference documents into persistent context

Include file loading hints in the inline `soul` or the `task` description:
```
"Review the authentication module in src/auth/. Read the files first, then analyze."
```

### Phase 2 Strategy

| Scenario | final_agent | final_prompt guidance |
|----------|-------------|----------------------|
| Analysis/Review | `"fork"` | "Synthesize the discussion into a structured report with findings, recommendations, and action items" |
| Code changes needed | `"fork"` | "Based on the discussion, implement the agreed-upon changes" (fork inherits parent tools) |
| Documentation output | `"fork"` | "Create documentation based on the experts' consensus" |

### Token Budget

Soul and discussion history both consume context. Preserve the complete selected Soul and its examples; manage the actual assignment's context rather than imposing preset Soul size limits. Reference task evidence by path instead of pasting duplicate file bodies, and follow the existing SubAgent session-continuity and capacity rules.

## Scenarios

Pre-built scenario templates are in `references/`. Load them for specific use cases:
- `references/code-review.md` — Multi-expert code review (Micro mode)
- `references/brainstorm.md` — Ideation and requirement analysis (Micro mode)
- `references/startup-mvp.md` — MVP planning (Sprint mode)
- `references/enterprise-feature.md` — Enterprise feature development (Sprint mode)

## Sprint / Full Mode: Multi-Phase Orchestration

For Sprint and Full modes, the orchestrator runs **multiple sequential `multi_agent` calls**, each representing one phase. The output of each phase feeds into the next as context.

**Protocol**:
1. Load the appropriate scenario template (e.g., `references/startup-mvp.md`)
2. The template defines phases, each with its own agent team, task, and expected output
3. Run Phase 1 as a `multi_agent` call → collect the Phase 2 output
4. Paste Phase 1 output into Phase 2's `task` parameter as input context
5. Repeat for each phase defined in the template
6. Deliver the combined results to the user

**Phase chaining example**:
```
Phase 1 (Discovery): multi_agent → output = "Discovery Brief"
    ↓ paste output into task
Phase 2 (Architecture): multi_agent → output = "Architecture Doc"
    ↓ paste output into task
Phase 3 (Planning): multi_agent → output = "Sprint Plan"
    ↓
Deliver combined results
```

**Quality gate between phases**: After each phase, evaluate the output. If the result is insufficient, either re-run the phase with adjusted parameters or halt and report to the user. Do not blindly chain forward.

## Troubleshooting

| Issue | Solution |
|-------|---------|
| Agent doesn't call handoff | System auto-retries once, then force-extracts response |
| Discussion goes in circles | Reduce `max_rounds`, or add "identify action items" in task |
| Phase 2 output too short | Make `final_prompt` more specific about expected deliverable format |
| Agent ignores its role | Select a suitable Soul and specify the current objective/constraints in `goal_prompt` |
| Tool call errors | Verify tool names match Maxa AI config exactly |
