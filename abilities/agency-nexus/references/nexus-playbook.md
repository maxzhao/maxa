# NEXUS Playbook — Multi-Agent Orchestration Guide

> Adapted from The Agency's NEXUS strategy for use with the `multi_agent` tool.

## Core Principles

1. **Evidence Over Claims** — All assessments require proof, not assertions
2. **Context Continuity** — Every handoff carries full context (agents see all prior discussion)
3. **Progressive Complexity** — Start simple (Micro), scale up only when needed
4. **Quality Gates** — Verify output before proceeding to next phase

## Mode: Micro (Default)

**Single `multi_agent` call. 2-5 agents. One discussion round.**

### When to Use
- Code review, security audit, architecture analysis
- Brainstorm, ideation, requirement analysis
- Bug investigation, debugging discussion
- Any focused, single-topic discussion

### Structure
```
User Request
    │
    ▼
[Orchestrator] Select 2-5 agents
    │
    ▼
[multi_agent] Phase 1: Discussion (2-5 rounds)
    │           Agents discuss, handoff between each other
    │
    ▼
[multi_agent] Phase 2: Synthesis (fork agent)
    │           Combines discussion into deliverable
    │
    ▼
Deliver result to user
```

### Recommended Settings
```yaml
termination:
  max_rounds: 6      # Enough for each agent to speak 1-2 times
  min_rounds: 2      # At least 2 rounds before ending
final_agent: "fork"  # Inherit parent tools for synthesis
```

## Mode: Sprint

**Multiplential `multi_agent` calls. 5-10 agents across phases.**

### When to Use
- Feature design from spec to implementation plan
- MVP architecture + sprint planning
- Comprehensive quality audit across dimensions

### Structure
```
User Request
    │
    ▼
[Phase 1: Discovery] multi_agent call
│  Agents: Trend Researcher, UX Researcher, Feedback Synthesizer
│  Output: Research findings, user needs, competitive landscape
    │
    ▼
[Phase 2: Architecture] multi_agent call
│  Agents: Backend Architect, Frontend Developer, UX Architect, DevOps
│  Input: Phase 1 findings (via task description)
│  Output: Technical architecture, component design
    │
    ▼
[Phase 3: Planning] multi_agent call
│  Agents: Senior PM, Sprint Prioritizer, Reality Checker
│  Input: Phase 2 architecture
│  Output: Task breakdown, sprint plan, risk assessment
    │
    ▼
Deliver combined result to user
```

### Phase Chaining

Pass Phase N output to Phase N+1 via the `task` parameter:

```yaml
# Phase 2 call
task: |
  Based on the following discovery findings, design the technical architecture:

  [Paste Phase 1 output here]

  Focus on: API design, database schema, component architecture.
```

## Mode: Full

**Multi-phase pipeline following NEXUS 7-phase model. 10+ agents.**

⚠️ **Advanced**: Only use when explicitly requested. Requires significant token budget.

### NEXUS 7-Phase Pipeline
```
Phase 0: Discovery     → Market validation, user research
Phase 1: Strategy      → Architecture, brand, sprint plan
Phase 2: Foundation    → Scaffolding, CI/CD, design system
Phase 3: Build         → Dev↔QA loops (task by task)
Phase 4: Harden        → Integration testing, performance
Phase 5: Launch        → Deployment, marketing activation
Phase 6: Operate       → Monitoring, iteration
```

Each phase is one or more `multi_agent` calls. Results chain forward.

## Dev↔QA Loop Pattern

For Sprint/Full modes, implement quality loops:

```
[Developer agents discuss implementation]
    │
    ▼
Phase 2 output: Implementation plan/code
    │
    ▼
[Orchestrator evaluates output]
    │
    ├── Quality OK → Next phase
    │
    └── Issues found → New multi_agent call with:
        - Same agents + fix instructions
        - max_retries: 3 (track in task description)
```

## Agent Configuration Patterns

### Analysis-Only Agent (no tools)
```yaml
- name: "Trend Researcher"
  role: "Market intelligence analyst"
  soul: "<complete inline role definition>"
  # No restrict_tools — gets full Chat builtins by default
```

### Code-Aware Agent (with tools + instructions)
```yaml
- name: "Backend Architect"
  role: "System architecture reviewer"
  soul: "#agency-nexus[/agents/engineering/backend-architect.md]"
  instructions: "Focus on API layer architecture. Output findings as a table."
```

### Challenger Agent
```yaml
- name: "Reality Checker"
  role: "Evidence-based integration reviewer"
  soul: |
    Assess the requested outcome against actual artifacts and acceptance criteria.
    Return material findings with evidence, or report that the examined criteria pass.
    Distinguish missing evidence from a proven defect. Do not prescribe a rejection
    verdict, score, or revision count. Further checks need a concrete unresolved concern.
```

## Quality Gate Checklist

Before delivering multi_agent results to user, verify:

- [ ] Phase 2 output is substantive (not just a summary of "we discussed...")
- [ ] All key perspectives were represented in the discussion
- [ ] Actionable recommendations are included
- [ ] If code changes are suggested, they reference specific files/locations
- [ ] Conflicting opinions are noted with resolution or "requires decision"
