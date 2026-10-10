# Initialized `.maxa/` Layout

Purpose: give init/sync a concrete skeleton and asset map. `references/knowledge-vault.md` is the normative owner for required/optional roots, metadata, index/log rules, retired paths, ignore layers, checkout eligibility and synchronization. Apply it before using this layout; create optional categories only for actual project content.

## Skeleton

```text
.maxa/
├── AGENTS.md
├── index.md
├── _meta.yaml
├── .gitignore
├── .stignore
├── .stignore-shared
├── .obsidian/
├── inbox/
│   ├── index.md
│   └── log.md
├── specs/
│   ├── index.md
│   └── log.md
├── weave/
│   ├── index.md
│   └── log.md
├── tasks/
├── drafts/
├── translate-cache/
├── attachments/
│   ├── index.md
│   └── log.md
└── canvases/
    ├── index.md
    └── log.md
```

This tree is the initialized baseline, not a directory inventory for mature-project `AGENTS.md`. TaskAdmin/workspace zones retain their separate ownership.

## Generation Inputs

| Output | Input / procedure |
| --- | --- |
| `AGENTS.md` | Inspect project source of truth, then `references/rules-authoring.md` and `assets/rules-template.md` |
| `index.md` and zone indexes | Apply progressive routing from `knowledge-vault.md`; describe why/when to read direct children |
| `_meta.yaml` | `assets/project-knowledge-meta.yaml`; preserve identity, creation provenance, Ability selections and supported runtime settings |
| `.gitignore` | Merge `assets/gitignore`, preserving user entries |
| `.obsidian/app.json` | `assets/project-knowledge-obsidian-app.json`; Obsidian visibility is independent of Git/Syncthing |
| `.stignore-shared` | `assets/project-knowledge-stignore-shared` |
| Local `.stignore` | `assets/project-knowledge-stignore`; exactly `#include .stignore-shared` on each client |

## Validation

Run the structure checks in `knowledge-vault.md` and the selected operation guide. Also require `.stignore-shared` and verify the local include:

```bash
test -f .maxa/.stignore-shared
printf '#include .stignore-shared\n' | cmp -s - .maxa/.stignore
```

Report missing or blocked checks; local skeleton creation is not proof of external registration or live graph readiness.
