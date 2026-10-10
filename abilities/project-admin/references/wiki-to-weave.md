# Legacy Content To Weave Migration

Purpose: explicitly replace `.maxa/wiki/` with content-owned notes plus an LLM-maintained `weave/` network. Apply `knowledge-vault.md`, `knowledge-governance.md` and `weave.md`. This is semantic migration, not an automatic init/sync rename.

## Preconditions And Scope

- Require explicit migration authorization and target project. Preserve user/worktree ownership, Vault identity, metadata/schema version and existing task/chat/Git history.
- Inspect source indexes, actual documents, target indexes and collisions. Read full semantic content before deciding to move, merge, regenerate or retire a document.
- Keep a recoverable temporary snapshot or verified Git originals plus a task-owned mapping of source -> content owner -> generated nodes -> disposition. Do not store secrets or task body copies in knowledge. Recovery snapshots are temporary local data, not a permanent old-area archive.
- Verify eligible Obsidian registration before live moves/checks. Linked/unresolved projects use only allowed file operations; preserve/repair links explicitly and report graph coverage limits.

## Classification

| Old content | Destination / handling |
| --- | --- |
| Unique article, technical investigation, detailed explanation | Existing semantic owner; create an intentional indexed category only if existing owners cannot fit. Preserve useful facts, provenance and exact contracts. |
| Full procedure/rule material | `rules/` source note, not automatically a live Agent rule; route executable Ability instructions to their owning Ability only when in authorized scope. |
| Exploration or unaccepted architecture | `ideas/`; mark actual maturity, never infer acceptance from the old folder name. |
| Research/API/evaluation | `research/`; preserve external sources and validation gaps. |
| Audit/migration/validation result | `reports/`; do not promote dated findings into current policy. |
| Compact context/navigation/synthesis | Regenerate useful topic/concept nodes from current sources under weave budgets; preserve any unique factual body in a content owner first. |
| Old accepted decision or obsolete claim | Verify current spec/rule owner; keep useful rationale in the semantic owner, explicitly historical/superseded where needed. Never turn a stale `active` flag into current truth. |
| Duplicate indexes/landing pages/templates/logs | Replace routes/templates with current owners; preserve necessary provenance/facts, then retire redundant structures under the authorized cutover. Do not carry them into weave as articles. |

No one-document/one-node requirement. Do not create a new owner category per old subdirectory. Existing `rules/research/ideas/reports` are current content owners, not a retired publishing layer; do not rebuild `sources/` or companion `published_to/source_doc/sync_status` pipelines.

## Ordered Migration

1. Inventory scoped originals and no-overwrite target mapping; record source content recovery and expected dispositions.
2. Preserve unique prose in appropriate content owners; merge only evidence-backed duplicates. Check current authoritative contracts and label obsolete instructions before exposing them as active navigation.
3. For eligible live moves, use guarded `exec -- move path=<old.md> to=<new.md>` one file at a time, then verify source absence, target existence and content preservation. Exit zero/empty output can occur without the move; retry only with a concrete correction or independently verified invocation. If still ineffective, use authorized no-overwrite file moves and explicitly repair observed links/paths; do not label that operation live graph validation. Obsidian's parsed-link rewrite does not cover every literal path, YAML string, code snippet or task reference.
4. Generate small topic/concept views from the preserved/current sources. Source metadata should use resolvable quoted links or paths, not fabricated task relationships. Do not duplicate full source bodies.
5. Repair root/category/child indexes and affected ordinary links/frontmatter/Canvas references. Keep parent indexes progressive; use exact paths instead of ambiguous same-basename links. Do not bulk-rewrite task/chat/Git history for cosmetic path cleanup.
6. Retire old directory, old promotion/navigation routes and redundant structures only after every useful unique document has a verified destination or explicitly justified retirement. For a complete cutover, leave no compatibility directory/router, dedicated legacy archive or inactive old templates. Historical facts may remain at their semantic owner, not a parallel knowledge system.
7. Validate source preservation, new byte budgets, frontmatter, entry reachability and affected links. Compare scoped unresolved references before/after, not whole-Vault zero errors. Observe actual source backlinks/node outlinks and bounded search through guarded Obsidian when available.
8. Remove temporary recovery data only after acceptance checks; record concise operation results in the owning log/task. Incorporate reusable migration findings here, without instance paths or one-time logs.

## Content And Metadata Findings

- Preserve substantial explanation at its semantic owner even when old metadata calls it a companion/module/pattern. Retire only proven duplicates after useful differences are absorbed; a rename is not permission to shorten article bodies.
- Remove obsolete `published_to/source_doc/sync_status` publishing-state fields while preserving actual provenance. Quote frontmatter wikilinks as strings; unquoted `[[...]]` can parse as nested arrays. `source_doc` joined by `+` is not a resolvable single dependency.
- Mark historical/global-Vault/prototype/retired-runtime assumptions as advisory history or needs-review. Old `active/reviewed/clean` and newest date do not establish current correctness. Contradictory API/ack/commit or UI fallback claims remain separate and explicitly unverified; do not fix unrelated runtimes to tidy migration.
- Choose a few question-oriented cross-source maps; many complete content articles can support one concept. Ordinary content indexes are not constrained by weave's smaller index budget.

## Recovery And Completion

Target collision: retain source and stop only dependent moves; never overwrite or silently pick a merge. Unclear content loss/authority: preserve source and ask one focused question. Tool failure: corrected retry or authorized smaller file operation; unresolved required graph coverage remains explicit.

Completed means useful source content survives, weave contains only bounded derived views, no old active area/compatibility archive remains, affected references/indexes are usable, and required checks have evidence. Global unrelated broken links do not authorize a Vault-wide repair. A prepared mapping or successful move alone is not completed migration.
