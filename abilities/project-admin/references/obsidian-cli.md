---
name: obsidian-cli
description: Use the Obsidian CLI to read, create, search, and manage notes, tasks, properties, graph relations, and plugin/theme development state in a running Obsidian instance.
---

# Obsidian CLI

The commands below describe Obsidian syntax. Apply `references/knowledge-vault.md` and use this Ability's guarded `exec` for project operations, including plugin/eval commands. `obsidian help` discovers syntax; it does not grant Vault eligibility.

Obsidian must be open or a headless instance available for eligible live operations. Missing registration is an explicit setup prerequisite; querying never creates or retargets it.

## Agent Project Dispatch

Call `load(target="project-admin")`, then `read(path="#project-admin[/references/knowledge-vault.md]")` before project CLI work. Resolve `<PROJECT_ROOT>` and pass the selected fields to `run`:

```yaml
# Read-only ownership/registration inspection
- title: "Inspect project Vault eligibility"
  scope: tool
  command: "@project-admin:/scripts/project_knowledge_vault.py"
  args: ["--project-root", "<PROJECT_ROOT>", "status"]
# Eligible, already registered project only
- title: "Search registered project Vault"
  scope: tool
  command: "@project-admin:/scripts/project_knowledge_vault.py"
  args: ["--project-root", "<PROJECT_ROOT>", "exec", "--", "search", "query=search term", "limit=10"]
- title: "Inspect registered source backlinks"
  scope: tool
  command: "@project-admin:/scripts/project_knowledge_vault.py"
  args: ["--project-root", "<PROJECT_ROOT>", "exec", "--", "backlinks", "path=research/example.md", "format=json"]
```

`exec` supplies the verified Vault selector. Pass each command argument literally (for example `"file=My Note"` is one argument); do not include shell quote characters, substitutions, or an alternate `vault=` selector. The internal `project_vault_cli.sh` helper is not a cataloged callable entrypoint; use the ProjectAdmin entrypoint above, not a fabricated helper address or raw CLI fallback.

For weave, prefer exact `path=` targets, limited scoped search, and backlinks filtered to relevant topic/concept nodes. Run dependent live CLI operations sequentially; empty output is not proof of successful graph inspection.

## CLI Reference / Manual Command Discovery

The remaining shell examples are generic CLI syntax reference, not the default Agent execution path. For project operations translate tokens after `obsidian` into the guarded `exec --` argv above, subject to the same ownership/setup gates. Keep builds and file checks in their project toolchain.

```bash
obsidian help
```

Official docs: https://help.obsidian.md/cli

## Syntax

Parameters use `key=value`; quote values with spaces. Boolean flags have no value. Use `\n` and `\t` for multiline content.

```bash
obsidian create name="My Note" content="Hello world"
obsidian create name="My Note" silent overwrite
```

## Targeting

| Target | Syntax | Meaning |
| --- | --- | --- |
| File by wikilink-like name | `file="My Note"` | name only, no path/extension needed |
| File by exact path | `path="folder/note.md"` | path from Vault root |
| Vault | `vault="My Vault"` as first parameter | avoids most-recent focused Vault ambiguity |

Example:

```bash
obsidian vault="My Vault" search query="test"
```

## Common Patterns

```bash
obsidian read file="My Note"
obsidian create name="New Note" content="# Hello" template="Template" silent
obsidian append file="My Note" content="New line"
obsidian search query="search term" limit=10
obsidian daily:read
obsidian daily:append content="- [ ] New task"
obsidian property:set name="status" value="done" file="My Note"
obsidian tasks daily todo
obsidian tags sort=count counts
obsidian backlinks file="My Note"
obsidian links file="My Note"
obsidian unresolved
```

Use `--copy` on any command to copy output to clipboard, `silent` to prevent opening files, and `total` on list commands for counts.

## Plugin / Theme Development

After plugin/theme code changes:

```bash
obsidian plugin:reload id=my-plugin
obsidian dev:errors
obsidian dev:console level=error
obsidian dev:screenshot path=screenshot.png
obsidian dev:dom selector=".workspace-leaf" text
```

If errors appear, fix and repeat reload/error checks before visual verification.

Additional developer commands:

```bash
obsidian eval code="app.vault.getFiles().length"
obsidian dev:css selector=".workspace-leaf" prop=background-color
obsidian dev:mobile on
```
