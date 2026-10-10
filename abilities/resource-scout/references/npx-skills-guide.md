# npx skills Guide

Purpose: use `npx skills` / skills.sh only as a search and acquisition source. It is not the final installer for Neovim + MCPHub Maxa Abilities.

Site: `https://skills.sh/`

## Mandatory Context

Before installing, updating, or adapting a skill acquired through `npx skills`, load and follow `ability-creator`:

```text
load(target="ability-creator")
```

Final placement, frontmatter, resource paths, script docs, loading tests, and cleanup must follow `ability-creator` and `references/setup/install-guide.md`.

## Commands

```bash
npx skills find [query]
npx skills add <package> ...
npx skills list -g --json
npx skills remove -g -s <name> --all -y
```

## Search

```bash
npx skills find "<query>"
```

Record candidate identifiers in this shape when available:

```text
<owner>/<repo>@<skill-name>
```

## Proxy

Use the environment's existing proxy variables when required. If missing, detect or ask; do not hardcode proxy ports.

```bash
export HTTP_PROXY=<proxy-url>
export HTTPS_PROXY=<proxy-url>
export ALL_PROXY=<proxy-url>
```

## Acquire To Staging

Prefer global staging for easier cleanup:

```bash
npx skills add <owner>/<repo> --skill <skill-name> --copy -g -y
```

Do not use `--agent '*'` as final installation. Any generated agent-specific copies must be reviewed and cleaned.

If the output path is unclear, locate candidates:

```bash
find ~/.agents ~/.claude ~/.config -maxdepth 4 -type d -name '<skill-name>' 2>/dev/null
```

## Migrate To Maxa Ability Layout

Choose final target according to `ability-creator`:

```text
<global-skills-root>/<skill-name>/
<project-root>/.maxa/abilities/<skill-name>/
```

Safe migration:

```bash
cp -a <npx-skills-output>/<skill-name> <staging-dir>/<skill-name>
```

Then normalize in staging, check final target for local changes, and install/update through the `ability-creator` workflow.

## Clean Residue

After confirming the final target is correct and no staged copy contains local-only work to preserve:

```bash
npx skills remove -g -s <skill-name> --all -y || true
find ~/.agents ~/.claude ~/.codex ~/.config -maxdepth 4 -type d -name '<skill-name>' 2>/dev/null
```

Do not delete or overwrite the final Maxa Ability target during cleanup.

## Update Flow

1. Check the installed target for local changes.
2. Re-acquire the upstream version to staging:
   ```bash
   npx skills add <owner>/<repo> --skill <skill-name> --copy -g -y
   ```
3. Diff staged upstream against the current target.
4. Reapply local Maxa adaptation.
5. Move only the normalized result into the final target.
6. Clean agent-specific copies.
7. Run load test and `ability-creator` lint.

## Handoff Checklist

- Treat `npx skills` as acquisition, not final install.
- Keep only an `ability-creator`-approved global or project Ability directory as the final target.
- Do not keep `~/.agents/skills`, `~/.claude/skills`, or similar agent-specific directories as final target.
- Ensure `SKILL.md` frontmatter, resources, script docs, and relative paths match Maxa rules.
- Run `load(target="<skill-name>", force_reload=true)`.
- Run `ability-creator` linter and fix errors/warnings where practical.
