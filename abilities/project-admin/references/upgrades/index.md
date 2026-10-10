# ProjectAdmin Versioned Upgrades

Purpose: store executable upgrade guidance for `.maxa/` schema versions. ProjectAdmin uses these guides to derive a project-specific upgrade plan before modifying files.

## Version rule

- Current project version is read only from `.maxa/_meta.yaml` field `schema_version`.
- Missing field or missing `_meta.yaml` means version `0`.
- Upgrade guides are applied in ascending target-version order.
- Update `schema_version` only after the corresponding upgrade validation passes.

## Guides

| From | To | Guide | Summary |
| --- | --- | --- | --- |
| 0 | 1 | `v0-to-v1-root-vault-layout.md` | Make `.maxa/` the Obsidian Vault root, retire `.maxa/knowledge/`, rename `rules.md` to `AGENTS.md`, and remove TaskAdmin export-to-knowledge. |
