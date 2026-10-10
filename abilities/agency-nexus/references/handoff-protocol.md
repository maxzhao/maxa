# Handoff Protocol

> How agents communicate within `multi_agent` discussions.

## Mechanism

The `multi_agent` tool manages a **Handoff-based discussion flow**:

1. Agent A receives the task + other agents' prior messages
2. Agent A outputs its analysis (public speech — all agents can see)
3. Agent A calls the registered discussion-local `subagent__handoff` tool directly after its public text:
   - `target`: Next agent name or `"user"` to end
   - `message`: Private message to target only (1-2 sentences)
4. Agent B receives the task + all prior messages (including A's public speech) + A's private message
5. Repeat until `target="user"` or max_rounds reached

## Visibility Rules

| Content | Who Can See |
|---------|-------------|
| Agent's text output (public speech) | All agents + user |
| `handoff.message` (private message) | Only the target agent |
| Prior discussion history | Current agent sees all others' public speech (not their own) |
| `multi_agent.messages` shared background | Every participant and final executor |
| Additional agent-loaded files | That agent unless included in public discussion |
| Agent's `tools` output | Only that specific agent |

## Handoff Decision Patterns

### When to handoff to another agent
- "I've completed my analysis from [my specialty] perspective. Let me hand off to [Agent B] who can evaluate [their specialty]."
- "I found [issue]. [Agent C] should investigate further."

### When to handoff to "user" (end discussion)
- All agents have spoken at least once
- Consensus reached or key disagreements documented
- No new insights being generated (discussion converging)
- Explicit "summarize and conclude" instruction in task

### min_rounds constraint
The current valid public contribution counts toward `min_rounds`. Default `1` allows the first contribution to finish; a larger minimum rejects earlier endings and suggests an actual participant (self is available when alone). Rejected calls do not advance the count. A retry is a new request: restate the public conclusion before calling handoff; keep the private note separate.

## Best Practices for Task Description

Write the `task` parameter to guide productive discussion:

### ✅ Good task descriptions
```
Review the authentication module in src/auth/ for:
1. Security vulnerabilities (SQL injection, XSS, CSRF)
2. Architecture soundness (separation of concerns, error handling)
3. Performance implications (N+1 queries, connection pooling)

Each agent should focus on their area of expertise.
Identify specific files and line numbers where issues are found.
Conclude with a prioritized list of recommendations.
```

### ❌ Poor task descriptions
```
Look at the code and tell me what you think.
```

## Phase 2 Synthesis

After discussion ends, Phase 2 converts the discussion into a deliverable.

### final_prompt guidelines

Be specific about the expected output format:

```
Based on the multi-agent discussion above, produce a structured code review report:

## Summary
Brief overview of findings

## Critical Issues (must fix)
- Issue description, location, recommended fix

## Recommendations (should fix)  
- Improvement suggestions with rationale

## Positive Observations
- Things done well

## Action Items
Prioritized list of changes with effort estimates
```
