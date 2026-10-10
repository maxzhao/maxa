---
name: obsidian-plugin-sync
description: Sync current project Vault Obsidian plugins and cross-platform-safe configuration one-way into other project knowledge Vaults.
---

# Obsidian Plugin Sync

Goal: treat the current project `.maxa/.obsidian/` as the authoritative source for Obsidian plugins and safe plugin config distribution. Target project Vaults remain knowledge-independent; this workflow copies only managed `.obsidian/` runtime assets, not Markdown notes.

The script:

- Discovers target project knowledge Vaults from the Syncthing folder registry.
- Excludes the source project Vault by resolved path equality.
- Copies plugin code, enabled plugin lists, and cross-platform-safe config into target `.obsidian/`.
- Removes `.stignore` rules that block plugin propagation to Windows/Android via Syncthing.

## Target Discovery

Source of truth: Syncthing folder registry, not repository directory scanning.

Included target folder ids:

```text
smx-knowledge-*
```

The source project Vault is excluded even if its folder id matches the prefix.

## Sync Scope

Default synced paths:

- `.obsidian/community-plugins.json`
- `.obsidian/core-plugins.json`
- `.obsidian/appearance.json`
- `.obsidian/templates.json`
- `.obsidian/plugins/`
- `.obsidian/snippets/`
- `.obsidian/themes/`

Default excluded local state:

- `.obsidian/workspace*.json`
- `.obsidian/workspace-mobile.json`
- `.obsidian/hotkeys.json`
- `.obsidian/graph.json`
- `.obsidian/cache/`
- `.obsidian/plugins/<plugin>/data.json` unless allowlisted

`data.json` may contain local paths, device preferences, window state, tokens, or other unsafe cross-device state.

Allowlist example:

```json
{
  "sync_plugin_data": ["plugin-id"],
  "sync_extra_files": ["plugins/example-plugin/settings.json"]
}
```

Paths in `sync_extra_files` are relative to `.obsidian/` and may use glob patterns.

## Usage

Default scope is all discoverable target project Vaults except the source project. If the user says only “sync knowledge Vault plugins / sync Obsidian plugins / update project knowledge Vault plugins” and does not specify a project/path/folder id, use this project `.maxa/.obsidian/` as source and sync all eligible targets.

Use `--folder-id` only when the user explicitly asks for a specific target project/folder id.

After `load(target="project-admin")`, pass the selected YAML fields to `run`. Resolve the source project path, explicit folder ID and optional allowlist path before invocation; array `args` are literal CLI strings, not shell expressions. The catalog preserves the owning uv executor.

```yaml
# dry-run all target project Vaults
- title: "Preview project plugin sync"
  scope: tool
  command: "@project-admin:/scripts/sync_project_plugins.py"
  args: ["--source-project-root", "<PROJECT_ROOT>", "--json"]

# apply all target project Vaults
- title: "Sync eligible project plugins"
  scope: tool
  command: "@project-admin:/scripts/sync_project_plugins.py"
  args: ["--source-project-root", "<PROJECT_ROOT>", "--apply"]

# explicit single target project only
- title: "Sync requested project plugins"
  scope: tool
  command: "@project-admin:/scripts/sync_project_plugins.py"
  args: ["--source-project-root", "<PROJECT_ROOT>", "--folder-id", "smx-knowledge-example-00000000", "--apply"]

# custom allowlist
- title: "Sync plugins with selected allowlist"
  scope: tool
  command: "@project-admin:/scripts/sync_project_plugins.py"
  args: ["--source-project-root", "<PROJECT_ROOT>", "--allowlist", "/path/to/allowlist.json", "--apply"]
```

## Syncthing Rescan

After `--apply`, do not manually trigger project Vault Syncthing rescan by default. Do it only when the user explicitly asks “force scan / immediate rescan / manual scan”.

For a requested rescan, resolve each target project root from project context or the Syncthing registry when only `--folder-id` is known. Apply `references/knowledge-vault.md` and invoke this Ability's guarded sync entrypoint; platform ownership and registration rules remain there.

## Platform And Safety

- Runs in WSL/Linux.
- Syncthing folder paths may be Linux, WSL, or Windows paths. Windows-mounted project Vaults are owned by Windows Syncthing, not WSL Syncthing.
- Android is not touched directly; it receives synced files through Syncthing.
- Sync is one-way: source project Vault `.obsidian/` → target project Vault `.obsidian/`.
- Markdown knowledge notes are never copied by this workflow.
- Target `.obsidian/plugins/` directories are replaced with real directories.
- No merge, no backup.
- Without `--apply`, always dry-run.
- Inaccessible, source, or non-project targets are skipped and reported.
