# AgentSkill Acquisition / Install Handoff

Purpose: Resource Scout handoff checklist for AgentSkills acquired from `npx skills`, ClawHub, GitHub, or downloads. For actual edits/installation, load and follow `ability-creator`.

## Mandatory Authority

Before installing, updating, or adapting any AgentSkill:

```text
load(target="ability-creator")
```

`ability-creator` is authoritative for target directory, structure, frontmatter, resources, scripts, validation, and local adaptation. Resource Scout only discovers and stages candidates.

## 1. Choose Target

Allowed final targets:

| Scope | Target |
| --- | --- |
| Global/cross-project | `<global-skills-root>/{skill-name}/` |
| Project-only | `{project_root}/.maxa/abilities/{skill-name}/` |

If scope is unclear, ask the user.

Forbidden final targets:

- `~/.agents/abilities/`
- `~/.claude/abilities/`
- `~/.codex/abilities/`
- `~/.config/crush/abilities/`
- `~/.config/devin/abilities/`
- `~/.config/goose/abilities/`
- Any other non-`ability-creator` agent-specific directory

## 2. Acquire To Staging

Acquisition commands download or stage files only; they do not complete installation.

| Source | Acquisition | Source-specific guide |
| --- | --- | --- |
| `npx skills` | `npx skills add` to temp/global staging | `references/npx-skills-guide.md` |
| ClawHub | `clawhub install` to temp/current workdir staging | `references/clawhub-guide.md` |
| GitHub repo | clone/download to temp dir, copy candidate skill dir | upstream docs |
| Web download | download `SKILL.md` and needed resources to staging | source page |

For GitHub/npm/external access, use environment proxy variables when required. Do not hardcode proxy ports; check existing `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`, detect, or ask.

## 3. Normalize Structure

Expected Maxa Ability anatomy:

```text
ability-name/
├── SKILL.md          # required standard Agent Skill source
├── ABILITY.yaml      # optional Maxa metadata
├── USER_GUIDE.md     # required
├── hooks/            # optional
├── scripts/          # optional
├── references/       # optional
└── assets/           # optional
```

Check and fix in staging:

- `SKILL.md` exists.
- `SKILL.md` frontmatter uses only standard fields: `name`, `description`, optional `license`, `compatibility`, `metadata`, `allowed-tools`.
- `ABILITY.yaml`, when present, uses only `merge`, `visibility`, `triggers`, `dependencies`, `exclude`, `executors`, and `mcp`; triggers are English routing phrases.
- `description` has no trigger list, negative boundary, exclusion text, or stale implementation count.
- Keep portable relative resource links, but make Maxa Agent execution prefer cataloged `load`/`read` references and titled `run(scope="tool")` script/tool commands. Verify each published `@`/`#` target; do not turn helper filesystem paths into imaginary callable entries.
- Root `USER_GUIDE.md` exists and is Chinese user-facing guidance.
- Remove marketplace artifacts, agent-specific config, README/CHANGELOG, install narratives, and non-runtime clutter unless needed as Agent-facing references.
- If scripts exist, `SKILL.md` or references document help command, common scenarios, key arguments, stable output, and error interpretation.

## 4. Clean Acquisition Residue

Before deletion, list candidate residue and verify each path is not the final target and has no local work to keep:

```bash
find ~/.agents ~/.claude ~/.codex ~/.config -maxdepth 4 -type d -name '<skill-name>' 2>/dev/null
```

Also remove temporary clone/download directories after confirming staged/final copies are safe.

## 5. Load Test

```text
load(target="<skill-name>", force_reload=true)
```

Check:

- Loads without frontmatter/path errors.
- Resources list is useful and bounded.
- Root `USER_GUIDE.md`, `SYSTEM.md`, and hidden implementation files are not exposed unexpectedly.
- Instructions contain no invalid local paths or impossible commands.

## 6. Lint

After `load(target="ability-creator")`, use the cataloged lint script. Substitute actual root paths as literal strings:

```yaml
run:
  title: "Lint adopted Ability descriptions"
  scope: tool
  command: "@ability-creator:/scripts/lint_skill_descriptions.py"
  args: ["--project-root", "<PROJECT_ROOT>"]
```

With an extra root:

```yaml
run:
  title: "Lint adopted Ability roots"
  scope: tool
  command: "@ability-creator:/scripts/lint_skill_descriptions.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--root", "<global-skills-root>"]
```

Fix errors. Review warnings and resolve when practical.

## 7. Functional Review

Verify the candidate's core path:

- External URLs/resources are reachable or documented as optional.
- Referenced callable scripts accept a safe `--help` call through `@ability:/path` when applicable; executor/runtime selection stays in the catalog.
- Referenced `references/` and `assets/` exist.
- Python scripts use the skill uv runtime contract.
- Instructions fit Neovim + MaxaAI + MCPHub behavior.

## 8. Update Existing Skill

Before updating:

```bash
git log --oneline -- <skill-path>/
git diff -- <skill-path>/
```

Update flow:

1. Record local modifications.
2. Acquire new upstream version to staging.
3. Diff upstream staging against installed target.
4. Normalize according to `ability-creator`.
5. Reapply local adaptation deliberately.
6. Run load test and linter.

Never let marketplace CLI overwrite a final target without local-change review.
