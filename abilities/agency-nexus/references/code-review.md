# Scenario: Code Review

> **Mode**: Micro | **Agents**: 3-4 | **Rounds**: 4-6

## Overview

Multi-expert code review combining security, architecture, and quality perspectives.

## Recommended Agents

| Agent | Role | Why |
|-------|------|-----|
| Security Engineer | Vulnerability analysis | Finds security flaws |
| Backend Architect | Architecture review | Evaluates design decisions |
| Senior Developer | Code quality & patterns | Catches implementation issues |
| Reality Checker | Evidence-based assessment | Challenges assumptions, demands proof |

All agents receive full Chat builtin tools by default — they can read files, run commands, and load additional MCP services as needed.

**Variant — Frontend focus**: Replace Backend Architect with Frontend Developer, add Accessibility Auditor.

## Task Template

```
Review the code in [TARGET_PATH] for:

1. Security vulnerabilities (injection, auth bypass, data exposure, CSRF)
2. Architecture quality (separation of concerns, error handling, SOLID principles)
3. Code quality (naming, complexity, test coverage, documentation)
4. Performance concerns (N+1 queries, memory leaks, unnecessary computation)

For each issue found:
- Reference the specific file and approximate location
- Explain the risk/impact
- Suggest a concrete fix

After your analysis, hand off to the next expert. The final agent should
handoff to "user" when all perspectives have been covered.
```

## Parameters

```yaml
termination:
  max_rounds: 6
  min_rounds: 2
final_agent: "fork"
final_prompt: |
  Based on the multi-expert discussion above, produce a structured code review report:

  ## Summary
  One paragraph overview of the codebase quality.

  ## Critical Issues (P0 — must fix before merge)
  Numbered list. Each with: file, description, risk, fix suggestion.

  ## Important Issues (P1 — should fix soon)
  Numbered list. Same format.

  ## Minor Issues (P2 — nice to have)
  Numbered list. Same format.

  ## Positive Observations
  What's done well. Acknowledge good patterns.

  ## Action Items
  Prioritized checklist of changes, roughly ordered by risk × effort.
```

## Context Configuration

```yaml
# Load the target code for all agents to see
context:
  - type: "file"
    path: "[TARGET_PATH]"
```

If reviewing against rules/standards:
```yaml
context:
  - type: "file"
    path: "[TARGET_PATH]"
  - type: "rules"
    path: ".maxa/rules/coding-standards.md"
```
