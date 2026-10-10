# Scenario: Enterprise Feature Development

> **Mode**: Sprint | **Agents**: 8-12 across 3 phases | **Rounds**: 4-6 per phase

## Overview

Structured feature development for enterprise products with compliance, quality gates, and stakeholder alignment. Follows a compressed NEXUS pipeline.

## Phase 1: Requirements & Architecture

### Agents
| Agent | Role |
|-------|------|
| UX Researcher | User needs for the feature |
| Backend Architect | System integratisign |
| UX Architect | UX foundation and component architecture |
| Senior PM | Spec-to-task conversion |
| Security Engineer | Security requirements |

### Task Template
```
Design a feature for an enterprise product:

Feature: [FEATURE DESCRIPTION]
Current system: [BRIEF DESCRIPTION OF EXISTING SYSTEM]
Constraints: [COMPLIANCE, PERFORMANCE, COMPATIBILITY REQUIREMENTS]

Discuss:
1. User stories and acceptance criteria
2. Technical architecture (how it integrates with existing system)
3. Security implications and requirements
4. Component design and data flow
5. Breaking this into implementable tasks

Each expert should flag risks and non-negotiable requirements from their domain.
```

### Parameters
```yaml
termination: { max_rounds: 8, min_rounds: 3 }
final_agent: "fork"
final_prompt: |
  Produce a Feature Design Document:
  ## Feature Summary
  ## User Stories (with acceptance criteria)
  ## Technical Architecture
  ## Security Requirements (non-negotiable)
  ## Component Design
  ## Data Model Changes
  ## API Changes
  ## Task Breakdown (with effort estimates)
  ## Risk Assessment
```

## Phase 2: Implementation Planning

### Agents
| Agent | Role |
|-------|------|
| Sprint Prioritizer | Sprint planning |
| DevOps Automator | CI/CD and deployment strategy |
| Reality Checker | Feasibility assessment |

### Task Template
```
Create an implementation plan for this feature:

[PASTE PHASE 1 OUTPUT]

Timeline: [N sprints]
Team: [TEAM COMPOSITION]
Quality requirements: [CODE COVERAGE, PERFORMANCE, A11Y]

Discuss:
1. Sprint assignment (which tasks in which sprint)
2. Feature flag strategy
3. Testing strategy (unit, integration, e2e)
4. Deployment strategy (canary, blue-green)
5. Rollback plan
```

## Phase 3: Quality Gate Definition

### Agents
| Agent | Role |
|-------|------|
| Evidence Collector | QA criteria definition |
| API Tester | API test plan |
| Performance Benchmarker | Performance criteria |
| Accessibility Auditor | A11y requirements |

### Task Template
```
Define quality gates for this feature:

[PASTE PHASE 2 OUTPUT]

Define:
1. What must pass before merge (unit tests, code review checklist)
2. What must pass before staging (integration tests, a11y audit)
3. What must pass before production (load test, security scan, final sign-off)
4. Monitoring and alerting criteria post-deploy
```

## Key Difference from MVP Scenario

- Security Engineer is always included
- Quality gates are explicitly defined (Phase 3)
- More conservative risk tolerance
- Compliance tracking throughout
