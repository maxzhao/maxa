# Scenario: Startup MVP Planning

> **Mode**: Sprint | **Agents**: 6-8 across 2-3 phases | **Rounds**: 4-6 per phase

## Overview

Multi-phase planning from idea to actionable sprint plan for a startup MVP. Runs 2-3 sequential `multi_agent` calls, each phase feeding into the next.

## Phase 1: Discovery & Validation

### Agents
| Agent | Role |
|-------|------|
| Trend Researcher | Market intelligence, competitive analysis |
| UX Researcher | User needs validation |
| Feedback Synthesizer | Synthesize findings |

### Task Template
```
Evaluate the viability of this MVP concept:

[PRODUCT DESCRIPTION]

Target users: [TARGET AUDIENCE]
Key hypothesis: [WHAT WE'RE TESTING]

Discuss:
1. Market opportunity — is this a real problem? How big?
2. Competitive landscape — who else is solving this?
3. User validation — what would users need to see to adopt this?
4. Risks — what could kill this idea?

Converge on a GO / NO-GO / PIVOT recommendation.
```

### Parameters
```yaml
termination: { max_rounds: 6, min_rounds: 2 }
final_agent: "fork"
final_prompt: |
  Produce a 1-page Discovery Brief:
  ## Verdict: [GO / NO-GO / PIVOT]
  ## Market Opportunity (with sizing if possible)
  ## Target User Profile
  ## Key Differentiator
  ## Top 3 Risks
  ## Recommended MVP Scope (must-have features only)
```

## Phase 2: Architecture & Planning

### Agents
| Agent | Role |
|-------|------|
| Backend Architect | System design |
| Frontend Developer | Client architecture |
| UX Architect | UX foundation |
| Senior PM | Task breakdown |

### Task Template
```
Based on this Discovery Brief, design the MVP architecture:

[PASTE PHASE 1 OUTPUT]

Discuss:
1. Technical stack recommendation (with rationale)
2. System architecture (services, database, APIs)
3. Component architecture (pages, key components)
4. Data model (core entities and relationships)
5. What to build first (critical path)
```

### Parameters
```yaml
termination: { max_rounds: 6, min_rounds: 2 }
final_agent: "fork"
final_prompt: |
  Produce a Technical Architecture Document:
  ## Stack Decision
  ## System Architecture (diagram in text)
  ## Core Data Model
  ## API Endpoints (key ones)
  ## Component Hierarchy
  ## Build Order (what depends on what)
```

## Phase 3: Sprint Planning

### Agents
| Agent | Role |
|-------|------|
| Sprint Prioritizer | Backlog creation, RICE scoring |
| Senior PM | Task scoping, effort estimation |
| Reality Checker | Feasibility check |

### Task Template
```
Create a sprint plan based on this architecture:

[PASTE PHASE 2 OUTPUT]

Timeline: [N weeks]
Team size: [N developers]

Discuss:
1. Break architecture into implementable tasks
2. RICE-score each task
3. Assign to weekly sprints
4. Identify dependencies and blockers
5. Reality check — is this achievable in the timeline?
```

### Parameters
```yaml
termination: { max_rounds: 6, min_rounds: 2 }
final_agent: "fork"
final_prompt: |
  Produce a Sprint Plan:
  ## Sprint Overview
  | Sprint | Week | Goal | Key Deliverables |

  ## Task Backlog (RICE scored)
  | ID | Task | RICE | Sprint | Dependencies |

  ## Risk Register
  | Risk | Probability | Impact | Mitigation |

  ## Definition of Done
  Criteria for MVP completion.
```

## Orchestration Notes

The main agent (you) runs these phases sequentially:
1. Run Phase 1 → get Discovery Brief
2. If GO → Run Phase 2 with Phase 1 output as context
3. Run Phase 3 with Phase 2 output as context
4. Deliver combined output to user

If Phase 1 returns NO-GO or PIVOT, discuss with user before proceeding.
