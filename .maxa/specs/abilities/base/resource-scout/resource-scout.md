---
title: Resource Scout Workflow 行为规格
created: 2026-06-29
updated: 2026-09-22
type: source
doc_role: spec
authority: draft
status: experimental
capability: resource-scout-workflow
sources:
  - abilities/resource-scout/SKILL.md
  - abilities/resource-scout/references/sources.md
  - abilities/resource-scout/references/clawhub-guide.md
  - abilities/resource-scout/references/npx-skills-guide.md
  - user-review:2026-09-15
confidence: medium
---

## Requirements

- **Discovery**: For explicit requests to find/compare existing AgentSkills or MCP Servers before building, load `resource-scout`; select sources by resource type and use [[specs/abilities/base/web-fetch/web-fetch|Web Fetch]] for required external search/fetch. If none qualify, report searched scope and route to custom implementation; never invent results.
- **Candidate report**: SHALL include exact name/source/URL or package ID, capability match, limitations, maintenance signal, compatibility/security, installation cost, credentials/permissions and an `adopt|adapt|reference|custom` recommendation.
- **Adoption handoff**: Marketplace commands/third-party code are untrusted acquisition inputs, not installation authority. Route AgentSkill adopt/adapt to `ability-creator` and MCP install/configure to `mcp-creator`; discovery SHALL NOT silently perform either.

## Validation And Review State

Human specification review passed by explicit user declaration on 2026-09-15. Representative live registry search for one skill and one MCP Server plus adoption handoff review remain not run; status remains experimental.
