# Scenario: Brainstorm / Ideation

> **Mode**: Micro | **Agents**: 3-5 | **Rounds**: 6-10

## Overview

Multi-perspective brainstorm for new features, products, or solutions. Agents bring different expertise to generate diverse ideas and challenge assumptions.

## Recommended Agents

| Agent | Role | Why |
|-------|------|-----|
| Trend Researcher | Market intelligence | Industry context, competitive landscape |
| UX Researcher | User perspective | User needs, behavior patterns |
| Rapid Prototyper | Technical feasibility | Quick assessment of what's buildable |
| Sprint Prioritizer | Prioritization | RICE scoring, effort estimation |

All agents receive full Chat builtin tools by default. For pure brainstorm sessions where you want agents to focus on discussion without tool distractions, set `restrict_tools: []` to restrict them to handoff-only.

**Variant — Technical brainstorm**: Replace Trend Researcher with Backend Architect, add AI Engineer.

**Variant — Design brainstorm**: Replace Sprint Prioritizer with UI Designer, add Whimsy Injector.

## Task Template

```
Brainstorm session: [TOPIC/QUESTION]

Context:
[Brief description of current state, constraints, goals]

Discussion guidelines:
1. Each agent should propose at least 2-3 ideas from their unique perspective
2. Build on others' ideas — "yes, and..." rather than "no, but..."
3. Challenge assumptions constructively
4. Consider feasibility, user impact, and competitive advantage
5. After 2-3 rounds, converge on top 3-5 ideas with brief rationale

When the group has explored the space sufficiently and identified top candidates,
the last agent should handoff to "user".
```

## Parameters

```yaml
termination:
  max_rounds: 10
  min_rounds: 3      # Ensure everyone speaks at least once + follow-up
final_agent: "fork"
final_prompt: |
  Synthesize the brainstorm discussion into a structured ideation report:

  ## Problem Statement
  What we're trying to solve (from the discussion context).

  ## Ideas Generated
  For each idea:
  - **Name**: Short catchy name
  - **Description**: 2-3 sentences
  - **Champion**: Which agent proposed/supported it
  - **Feasibility**: Quick assessment (Easy/Medium/Hard)
  - **Impact**: Expected user/business impact (Low/Medium/High)

  ## Top Recommendations (ranked)
  Top 3-5 ideas with reasoning for ranking.
  Include any conditions or prerequisites.

  ## Open Questions
  Unresolved debates or items needing more investigation.

  ## Next Steps
  Suggested actions to move forward with top ideas.
```

## Notes

- For pure brainstorm, consider setting `restrict_tools: []` to keep agents focused on discussion
- Higher `min_rounds` (3+) ensures ideas are challenged and refined
- The Whimsy Injector adds creative "wild card" ideas that others might not consider
- If agents need to research during brainstorm, leave tools at default — they can load the `web-fetch` Ability on demand
