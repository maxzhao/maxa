---
name: obsidian-plugin-development
description: Develop self-maintained Obsidian community plugins in the project, publish runtime builds to the current project Vault, and validate real plugin files.
---

# Obsidian Plugin Development

Scope: self-maintained Obsidian community plugins in this Maxa/Neovim config project. This is not for ordinary note maintenance and does not replace official Obsidian API docs.

Project source directory:

```text
obsidian-plugins/
├── disable-unresolved-link/
├── grab-note/
└── sync-conflict-resolver/
```

Runtime target: current project Vault `.maxa/.obsidian/plugins/<plugin-id>/` must be a real directory, not a symlink to project files. Android/Windows Syncthing targets cannot reliably load WSL/Linux absolute symlinks.

## Minimum Plugin Files

```text
<plugin-id>/
├── manifest.json
└── main.js
```

Optional: `styles.css`. `manifest.json.id` must match the plugin directory name.

## Project Knowledge Entrypoints

Before plugin changes, read relevant project-local notes when needed:

- `.maxa/modules/Obsidian Self-maintained Plugin Development Context.md`
- `.maxa/patterns/Obsidian Plugin Interaction Reliability Pattern.md`
- `.maxa/decisions/Grab Note Feedback Workflow Decision.md`

Add new durable plugin lessons to these or related notes rather than leaving them only in chat.

## Development Rules

- Edit project `obsidian-plugins/<plugin-id>/` first.
- Keep plugin ID, project directory, and project Vault plugin directory consistent.
- If source/build project exists, modify source and build `main.js`; Obsidian loads `manifest.json`, `main.js`, and optional `styles.css`.
- Runtime-affecting changes (`manifest.json`, `styles.css`, build configuration, source affecting `main.js`, or `main.js`) require build/syntax checks, publication to the current project Vault and runtime-file verification unless the user explicitly says “source only, do not publish”.
- Never keep project Vault `.obsidian/plugins/<plugin-id>` as an external-project symlink.
- Do not sync device-local state, tokens, window state, or local paths. `data.json` is excluded by default.
- If important draft state exists, do not rely only on `data.json`; use Vault business paths when needed and preserve target `data.json` during sync.
- Business writes must use paths relative to Vault root, e.g. `inbox/feedback/pending/`, not `inbox/feedback/pending/`.
- Queue-like plugins must be fail-safe: clear local drafts only after all output files are written successfully.

## Publish To Current Project Vault

Script: `scripts/sync_dev_plugins_to_project_vault.py`. It copies project plugins to current project Vault real directories and replaces old symlinks. For standard plugin projects, publish only runtime files; exclude `src/`, `node_modules/`, `package*.json`, `tsconfig.json`, `esbuild.config.mjs`, and `data.json` unless `--include-data`.

After `load(target="project-admin")`, pass the selected YAML fields to `run`. Resolve project paths and plugin IDs before invocation; array `args` are literal CLI strings. The catalog preserves the owning uv executor.

```yaml
# dry-run
- title: "Preview developed plugin publication"
  scope: tool
  command: "@project-admin:/scripts/sync_dev_plugins_to_project_vault.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--json"]

# apply all known self-maintained plugins and publish to the project Vault
- title: "Publish developed project plugins"
  scope: tool
  command: "@project-admin:/scripts/sync_dev_plugins_to_project_vault.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--apply"]

# single plugin
- title: "Publish grab-note plugin"
  scope: tool
  command: "@project-admin:/scripts/sync_dev_plugins_to_project_vault.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--plugin", "grab-note", "--apply"]
```

Key args: `--project-root`, repeatable `--plugin`, `--apply`, `--include-data`, `--json`.

## Required Closeout After Plugin Changes

Build and syntax-check with project shell commands (prefer matching Justfile recipes):

```bash
cd <PROJECT_ROOT>/obsidian-plugins/<plugin-id>
npm run build
node --check main.js
```

Then publish through titled `run(scope="tool")`:

```yaml
title: "Publish changed Obsidian plugin"
scope: tool
command: "@project-admin:/scripts/sync_dev_plugins_to_project_vault.py"
args: ["--project-root", "<PROJECT_ROOT>", "--plugin", "<plugin-id>", "--apply"]
```

Finally verify the runtime target with file checks:

```bash
test -d "<PROJECT_ROOT>/.maxa/.obsidian/plugins/<plugin-id>"
test ! -L "<PROJECT_ROOT>/.maxa/.obsidian/plugins/<plugin-id>"
test -f "<PROJECT_ROOT>/.maxa/.obsidian/plugins/<plugin-id>/manifest.json"
test -f "<PROJECT_ROOT>/.maxa/.obsidian/plugins/<plugin-id>/main.js"
```

Tell the user to reload/restart Obsidian; Android also waits for Syncthing. Dry-run is only a precheck, not closeout validation.

## Relationship To Project Vault Plugin Sync

After a plugin is stable, project knowledge Vault plugin sync may copy the current project Vault `.obsidian/` into other project Vaults. Read `#project-admin[/references/obsidian-plugin-sync.md]`.

Key behavior:

- `sync_project_plugins.py` source is the current project Vault `.obsidian/`.
- Target `.obsidian/plugins/` directories are replaced with real directories.
- Markdown knowledge notes are never copied by plugin sync.
- `data.json` excluded by default unless allowlisted.
- After `--apply`, manual project Vault Syncthing rescan is not default; do it only when user explicitly requests.

## Validation Checklist

Source structure:

```bash
for plugin in disable-unresolved-link grab-note sync-conflict-resolver; do
  test -d "obsidian-plugins/$plugin"
  test -f "obsidian-plugins/$plugin/manifest.json"
  test -f "obsidian-plugins/$plugin/main.js"
done
```

Project Vault plugin sync dry-run/apply through titled `run(scope="tool")` when requested:

```yaml
- title: "Preview project plugin sync"
  scope: tool
  command: "@project-admin:/scripts/sync_project_plugins.py"
  args: ["--source-project-root", "<PROJECT_ROOT>", "--json"]
- title: "Apply requested project plugin sync"
  scope: tool
  command: "@project-admin:/scripts/sync_project_plugins.py"
  args: ["--source-project-root", "<PROJECT_ROOT>", "--apply", "--json"]
```

For an explicit post-sync scan request, follow `references/knowledge-vault.md` and use this Ability's guarded sync entrypoint. Ordinary publication/distribution does not request a scan.

## Troubleshooting

Plugin not updated in Obsidian:

- Confirm source build ran when applicable.
- Confirm `sync_dev_plugins_to_project_vault.py --apply` ran.
- Confirm global plugin dir is real and contains latest `manifest.json` / `main.js`.
- Reload plugin or restart Obsidian.

Android/Windows project Vault plugin unusable:

- Check for symlink in project Vault `.obsidian/plugins/<plugin-id>`.
- Replace with real directory via sync script and confirm Syncthing received files.

Project Vault sync missing plugin:

- Run `sync_project_plugins.py --json` for eligibility.
- Confirm project Vault real plugin dir exists with runtime files.
- Manual scan is only required if user explicitly requested immediate rescan; use the owning Syncthing side only.

Settings not synced:

- Expected by default. `data.json` can contain local paths, tokens, or state. Sync only through allowlist/explicit parameter after safety review.
