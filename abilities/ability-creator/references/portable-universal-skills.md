# Portable Universal Skills

Use this guide when creating a skill package that can be copied to multiple AI coding Agents or IDEs, such as Claude Code, Codex, Cursor, Aider, Gemini CLI, or MCP-capable clients.

Portable skills differ from local Neovim/MCPHub AgentSkills: describe the capability from the consuming Agent’s perspective, not from the authoring repository.

## Goal

A portable universal skill lets an Agent use a capability after installation or connection without knowing which repository authored it. Assume the consuming Agent can see only the shipped skill files and runtime capabilities those files describe.

## Frontmatter Model

For universal `SKILL.md`, prefer broad-compatible frontmatter:

```yaml
---
name: skill-name
description: Short English description of the capability.
---
```

Rules:

- Do not add local-routing metadata such as `triggers` unless the target runtime explicitly requires it.
- Claude-style portable skills usually rely only on `name` and `description`.
- Keep `description` English for broad multi-tool reuse.

## Perspective Rules

Write from the consuming Agent’s perspective.

Prefer:

- “Use this skill when connected to the NexusFlow MCP server.”
- “Before UE operations, call `get_connection_status`.”
- “Treat live MCP tool schemas as the source of truth.”

Avoid:

- “This skill is for external IDEs.”
- “External Agents do not have this repository.”
- “Do not access `.maxa` or local project files.”
- “This file is the maintenance entrypoint.”

Omit authoring-repository concepts entirely when the target environment is unrelated to them; even negative statements can introduce irrelevant concepts.

## Language Rules

Unless the target ecosystem is explicitly localized, portable skill files should be pure English:

- `SKILL.md`
- `AGENTS.md`
- `CLAUDE.md`
- `.cursor/rules/*.mdc`
- copied reference files

For maximum compatibility, prefer ASCII separators such as `search -> load -> execute`, not Unicode arrows.

## Recommended Package Structure

```text
skill-name/
├── SKILL.md                  # Claude-style universal skill entry
├── AGENTS.md                 # canonical plain Markdown for Codex/other Agents
├── CLAUDE.md                 # Claude Code memory file, usually importing AGENTS.md
├── .cursor/rules/skill-name.mdc
└── references/capability-tools.md  # optional focused details
```

Include only files needed by the target distribution. Do not add README, changelog, or setup narrative unless the consuming Agent needs it to operate the capability.

## Entry File Responsibilities

### `SKILL.md`

Include:

- Concise capability description.
- Runtime setup assumptions.
- First checks/health checks.
- Main workflow.
- Safety rules.
- Links to focused references.

Do not include:

- Authoring project paths.
- Local development commands.
- Internal task-management rules.
- Local skill-system references unless the skill targets that system.

### `AGENTS.md`

Use as canonical plain-Markdown instructions for multiple coding Agents.

Good content: runtime assumptions, tool discovery, standard workflow, error handling, reporting requirements. Avoid frontmatter because many Agents treat it as ordinary text.

### `CLAUDE.md`

Keep short. If `AGENTS.md` exists, import it:

```markdown
# Skill Instructions

@AGENTS.md

## Claude Code Notes

- Treat `AGENTS.md` as the canonical instruction source.
- Treat live tool schemas as the source of truth.
```

If copied without `AGENTS.md`, tell the user to replace the import with full AGENTS content.

### Cursor Rules

Use `.cursor/rules/*.mdc`:

```yaml
---
description: Operate the target capability through its MCP server.
alwaysApply: false
---
```

Use `alwaysApply: false` for narrow capabilities. Keep the rule shorter than `AGENTS.md`: activation scenario, required checks, workflow, and key safety rules.

## Runtime Capability Guidance

For MCP servers or similar runtime interfaces:

- Treat live tool schemas as authoritative.
- Avoid hardcoding server prefixes; MCP clients may rename servers.
- Use expected tool names as directional hints, not mandatory namespaces.
- Require connection/status check first when available.
- Use progressive disclosure for search/load/execute patterns.
- Define degradation through errors the Agent can actually observe.

Example:

```markdown
Before any operation:

1. Call `get_connection_status`.
2. Continue only when it reports `connected: true`.
3. Call `get_context` to inspect current state.
4. Prefer the live MCP schema over examples in this document.
```

## Remove Authoring Environment Context

Before delivery, remove references to:

- Local repository paths.
- Internal task systems.
- Local build/test commands.
- Local skill loader names.
- Project knowledge vaults.
- Authoring-only files/directories.
- Phrases such as “external IDE” or “external agent.”
- Negative statements about concepts the consuming Agent would otherwise not know.

Absence of irrelevant context is part of skill quality.

## Validation Checklist

- [ ] `SKILL.md` is a runtime skill, not maintenance notes.
- [ ] `SKILL.md` frontmatter uses only portable fields required by the target runtime.
- [ ] `description` is English and capability-focused.
- [ ] No local-routing `triggers` exist unless the target runtime requires them.
- [ ] User-visible files are English unless the target ecosystem is explicitly localized.
- [ ] No authoring repository paths or local development commands remain.
- [ ] No internal project, task, or knowledge system is referenced.
- [ ] Text uses the consuming Agent’s perspective.
- [ ] Live tool schemas are authoritative.
- [ ] First checks, workflow, safety, error handling, and reporting rules are present.
- [ ] Cross-Agent entry files are consistent.
- [ ] References are focused and loaded only when useful.

Suggested scans from the authoring repository:

```bash
grep -R -n -P '[^\x00-\x7F]' skill-name || true
grep -R -n -E 'external IDE|external agent|maxa|Justfile|/mnt/|mcpx__|triggers:' skill-name || true
```

Adjust forbidden terms for the actual authoring environment.
