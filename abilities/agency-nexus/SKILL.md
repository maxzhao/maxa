---
name: agency-nexus
description: "使用 The Agency 专家角色编排多专家协作与单专家角色代理，适合代码审查、架构讨论、头脑风暴、问题调查、分阶段规划，以及通过 soul 引用 Agency 角色。"
compatibility: Requires Maxa Ability runtime.
---
# Agency NEXUS

Purpose: select The Agency specialist roles for a bounded single-agent assignment or multi-agent discussion. Use role collaboration when requested or when independent perspectives serve the actual goal, not as a default substitute for main-session work.

## Routing

| Need | Read |
| --- | --- |
| Select a specialist | `references/agent-catalog.md`, then the selected `agents/<division>/<filename>.md` |
| Use a standalone role or configure a discussion | `references/orchestration.md` |
| Choose Micro/Sprint/Full, phase chaining, or Dev↔QA repair | `references/nexus-playbook.md` |
| Handoff, termination, or final synthesis | `references/handoff-protocol.md` |
| Multi-expert code review | `references/code-review.md` |
| Brainstorm or requirement exploration | `references/brainstorm.md` |
| MVP planning | `references/startup-mvp.md` |
| Enterprise feature planning | `references/enterprise-feature.md` |

Read only the selected scenario's references. Before SubAgent calls, load the composite `subagent` Ability and follow its instructions; it supplies tools and owns child-context preparation, parameter semantics, session continuity, and child boundaries.

## Role And Output Contract

- Address a selected role as `#agency-nexus[/agents/<division>/<filename>.md]`; excluded catalog entries remain available through exact references.
- Use the selected role file as a complete Maxa Soul: preserve its identity, expertise, methods, examples, templates, communication character and tool preferences. Pass the exact reference through `soul`; do not impose preset length limits or require lossy condensation into inline text.
- Soul-specific tool preferences operate within the common Runtime, actual tool schemas/authorization and user scope. Correct incompatible invocation protocols without deleting the professional cases that illustrate them.
- Use `multi_agent` only when present in the loaded SubAgent catalog; load `subagent` once and this Ability before configuring the discussion. Role selection never authorizes enabling unavailable tools.
- Judge review findings against requirements and actual evidence. Do not inherit preset rejection verdicts, arbitrary scores, or expected revision counts from role examples. Passing evidence permits completion; rerun or broaden review only for new changes, failures, or unresolved concerns.
- Return a verified deliverable, material findings, and remaining blockers. A discussion summary is not implementation or validation evidence.
- Preserve required approvals and independent ownership. A proposed later phase does not authorize implementation, deployment, or monitoring beyond the user's scope.

