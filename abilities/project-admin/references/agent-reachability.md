# Agent Reachability

Purpose: diagnose and repair project-local knowledge discoverability without bulk-reading the Vault. Read `#project-admin[/references/knowledge-vault.md]` for the entry chain, index/log rules and zone ownership; this reference owns reachability diagnosis and repair, not a second layout contract.

## Reachability Contract

A note is reachable when a path from the documented entry chain leads to it through a parent index, an observed direct wikilink, frontmatter `sources:` / `related:`, or a report/index/log entry explaining when to read it.

A maintained directory is reachable when its parent index links to its own `index.md` or directly owned file. Graph orphan status alone does not establish Agent reachability.

## Repair Flow

1. Identify target note and owner directory from the project entry/indexes.
2. Check the owner index. For multi-note durable topics, add/repair the child `index.md` first.
3. Link the child index from its parent, following the single progressive-index contract; do not duplicate deep entries.
4. Add an Agent-useful summary explaining why/when to read the target.
5. Preserve provenance and observed relationships; record maintenance in the owning `log.md`.
6. Validate the path from the entry chain and affected links. Live graph checks require guarded dispatch; report file-only coverage separately.

Diagnosis does not authorize moves, renames, archives, deletion or bulk rewrites. Use the knowledge repair boundary before those actions.

## Workflow Ownership

- Project structure/schema/registration: governance scenarios in `project-admin`.
- Note bodies, graph, health, curation and feedback: knowledge scenarios in `project-admin`.
- Stable learning capture selection: `self-improvement`; captures remain discoverable through `inbox/index.md`.
- Generated topic/concept navigation and source backlinks: `weave.md`; query coverage is not content completeness.
- Task workspace semantics and execution: `task-admin`; no duplicate knowledge/task exports.
