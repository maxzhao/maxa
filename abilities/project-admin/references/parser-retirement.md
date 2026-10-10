# Parser Retirement Reference

Purpose: retire legacy `rules_parser.lua` / generated rules-table discovery and replace it with schema v1 root Vault entrypoints.

## Replacement Entry Chain

Current v1 chain:

```text
AGENTS.md
-> index.md
-> weave/index.md / inbox/index.md / specs/index.md / content category indexes
-> child indexes
-> selected notes
```

No current workflow should depend on:

```text
rules.md
knowledge/index.md
sources/index.md
raw/
```

## Responsibilities

| Artifact | Role |
| --- | --- |
| `AGENTS.md` | L0 project contract, low-context stable rules. |
| `index.md` | Whole-Vault router. |
| `weave/index.md` | Compact LLM-derived topic/concept router; not content intake. |
| `inbox/index.md` | Capture/review router. |
| `specs/index.md` | Spec router. |
| Optional category indexes | Project-shaped content routing for `ideas/`, `reports/`, `research/`, `rules/` when present. |
| Obsidian/project CLI | On-demand graph/search expansion. |

## Preconditions Before Removing Parser Dependencies

1. `.maxa/AGENTS.md` exists.
2. `.maxa/index.md` exists and routes to required zones.
3. Required roots exist: `inbox/`, `specs/`, `weave/`, `tasks/`, `drafts/`, `translate-cache/`, `attachments/`, `canvases/`; explicit old-content migration precedes retirement.
4. Maintained root knowledge directories have `index.md` and `log.md`.
5. Optional categories have `index.md` and `log.md` when present.
6. Parent indexes route to child indexes or directly owned files and do not duplicate child index contents.
7. No runtime code still requires generated `rules_parser` tables.

## Migration Steps

1. Update prompts/runtime docs to reference `AGENTS.md` and root `index.md`.
2. Replace any generated table insertion with explicit entrypoint text.
3. Move old `rules.md` content to `AGENTS.md` or an optional `rules/` source category according to ownership.
4. Ensure root routing reaches weave, inbox, specs, workspace zones and existing content indexes.
5. Verify child indexes exist for multi-note directories.
6. Delete parser runtime wiring after validation.
7. Search for stale references: `rules_parser`, `rules.md`, `.maxa/knowledge`, `sources/index`.

## Validation

```bash
test -f .maxa/AGENTS.md
test -f .maxa/index.md
test -f .maxa/weave/index.md
test -f .maxa/inbox/index.md
test -f .maxa/specs/index.md
rg --color=never -n "rules_parser|\.maxa/rules\.md|\.maxa/knowledge|sources/index" lua abilities prompts .maxa || true
```

Interpretation:

- Hits in upgrade/historical migration references may be acceptable.
- Hits in active runtime prompts, Ability routing, scripts, or generated templates must be fixed.

## Completion State

`rules_parser.lua` is fully retired only when current runtime discovery works through:

```text
AGENTS.md + index.md + progressive category indexes + explicit Vault-targeted search/graph tools
```
