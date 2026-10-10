---
name: resource-scout
description: "Search, discover, compare, and evaluate existing AgentSkills and MCP Servers before building custom capabilities or integrating external tools, then route adoption work to the proper creator Ability."
compatibility: Requires Maxa Ability runtime.
---
# Resource Scout

Purpose: discover, compare, acquire, and evaluate existing AgentSkills and MCP Servers before building custom solutions.

For external searches, registry queries, downloads, or repository access, follow the active system prompt's proxy requirements. Use configured proxy settings without inventing, hardcoding, or persisting proxy values in skill artifacts.

## Use When

- The user asks whether an existing AgentSkill can provide a capability.
- The user wants MCP Server candidates for an external tool, service, data source, or local capability.
- A custom skill or MCP Server is being considered and resource discovery should happen first.
- Candidates need quality, maintenance, compatibility, security, or installation-cost evaluation.
- A resource must be acquired from ClawHub, `npx skills`, a marketplace, or GitHub before adaptation.

## Authority Boundary

Resource Scout owns discovery, comparison, acquisition guidance, and adoption recommendations. Implementation authority stays with creator Abilities:

| Work | Load before changing files/config | Resource Scout handoff reference |
| --- | --- | --- |
| AgentSkill install/update/repair/normalization | `ability-creator` | `references/setup/install-guide.md` |
| MCP Server install/create/configure/reload/maintenance | `mcp-creator` | `references/setup/mcp-server-install-guide.md` |

Marketplace or CLI install commands are acquisition helpers only. Final placement, validation, reload, cleanup, and compatibility fixes must follow the relevant creator Ability.

## Skill Discovery

Fast sources:

```bash
npx skills find [query]
clawhub search "query"
```

Read when needed:

- `references/npx-skills-guide.md`: `npx skills` search, acquisition, cleanup.
- `references/clawhub-guide.md`: ClawHub CLI/API search, acquisition.
- `references/sources.md`: full source directory.

Web/API sources:

- Use `web-fetch` for external URLs. Default to `web-fetch auto`; escalate only after actual failure.
- ClawHub API: `https://clawhub.ai/api/search?q=<query>`.
- GitHub search fallback:
  - `site:github.com "SKILL.md" [topic]`
  - `site:github.com "agent skill" [topic]`

Primary skill sources:

| Source | Type | Best for | Access |
| --- | --- | --- | --- |
| ClawHub | OpenClaw registry | semantic skill discovery | CLI/API |
| SkillsMP | large marketplace | long-tail search | `web-fetch auto`, then browser/stealth if blocked |
| SkillHub.club | curated marketplace | quality-filtered skills | `web-fetch auto` |
| agent-skills.md | online directory | quick browse/install hints | `web-fetch auto` |
| Claude Skills Hub | online directory | UI-friendly browsing | `web-fetch auto` |
| MCP Market | combined marketplace | skill + MCP discovery | `web-fetch auto` |
| skills.sh | CLI ecosystem | `npx skills` search | CLI |

ClawHub website pages are SPA-rendered; prefer CLI/API. SkillsMP may require browser/stealth after `web-fetch auto` fails.

GitHub lists:

- `github.com/keyuyuan/skillhub-awesome-skills`
- `github.com/VoltAgent/awesome-claude-skills`
- `github.com/ComposioHQ/awesome-claude-skills`
- `github.com/heilcheng/awesome-agent-skills`

## MCP Server Discovery

Web directories:

| Source | URL | Signal | Access |
| --- | --- | --- | --- |
| Glama | `glama.ai/mcp/servers` | stars, downloads, updates | `web-fetch auto` |
| mcpservers.org | `mcpservers.org` | categories, official tags | `web-fetch auto` |
| PulseMCP | `pulsemcp.com/servers` | weekly visitors, updates | `web-fetch auto` |
| Smithery | `smithery.ai` | registry/distribution | `web-fetch auto` |
| MCP.so | `mcp.so/servers` | CN/EN broad index | `web-fetch auto` |

Official resources:

- `github.com/modelcontextprotocol/servers`
- `registry.modelcontextprotocol.io`

GitHub lists:

- `github.com/punkpeye/awesome-mcp-servers`
- `github.com/wong2/awesome-mcp-servers`

## Search And Evaluation

Search tactics:

1. Use specific capability keywords: `react testing` beats `testing`.
2. Try synonyms: `deploy`, `deployment`, `release`, `ci-cd`.
3. Use natural-language queries for vector sources such as ClawHub.
4. Cross-check multiple sources before recommending adoption.
5. Prefer recently maintained resources with clear docs and minimal permissions.

Evaluation dimensions:

- Capability match and main limitation.
- Maintenance signal: update date, stars/downloads, registry score, issue activity.
- Docs/resource quality and portability.
- Installation/adoption complexity.
- Credentials, tokens, API keys, filesystem/network/browser/shell/database permissions.
- Compatibility with Neovim + MaxaAI + MCPHub.

## Output Contract

Report candidates with:

- Name, source, URL or package identifier.
- Capability fit and limitation.
- Maintenance/quality signal available from the source.
- Install/adoption complexity and required credentials/permissions.
- Recommendation: adopt, adapt, reference only, or build custom.

If no suitable resource is found:

1. State searched scope and rejection reason.
2. Offer a direct implementation path when feasible.
3. Route to `ability-creator` for a custom AgentSkill or `mcp-creator` for a custom/configured MCP Server.

