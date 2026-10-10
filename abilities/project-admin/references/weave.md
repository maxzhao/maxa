# Knowledge Weave

Purpose: maintain a compact, source-backed retrieval network for LLMs under `.maxa/weave/`. Read `knowledge-governance.md` for content/evidence boundaries and `knowledge-vault.md` before external operations; `obsidian-cli.md` owns guarded CLI syntax.

## Ownership And Requests

Content belongs to semantic categories (`ideas/`, `research/`, `rules/`, `specs/`, `reports/` or an explicitly governed category). Weave contains derived navigation and concise cross-source interpretation, not article intake, copied full text, executable authority or unique human-authored knowledge. Sources may evolve; preserve their actual lifecycle and owner.

| User intent | Action |
| --- | --- |
| Find/explain knowledge | Read-only topic-first or source-first retrieval below; persist only if requested. |
| Weave/organize relationships/update a topic | Incrementally maintain the specified scope; absent scope, choose the smallest relevant changed cluster from indexes. |
| Check/inspect weave | Diagnose sizes, links, coverage, provenance and freshness; no repair. |
| Repair/rebuild weave | Repair requested nodes/relations; broader deletion or source changes need explicit authorization. |
| Ingest/capture/curate sources | Use content workflows; do not implicitly weave. |
| Migrate old generated content | `wiki-to-weave.md`; never rename the tree wholesale. |

The LLM maintains generated files; humans curate sources, request changes and review. Route corrections through sources or `inbox/feedback/`. Preserve/reconcile detected manual node edits; do not blindly overwrite them. Query/check requests do not grant mutation; clear maintenance requests grant their scoped reversible work without repeated approvals.

## Structure And Byte Budgets

```text
weave/index.md
weave/log.md
weave/topics/index.md
weave/topics/<topic>.md
weave/concepts/index.md
weave/concepts/<concept>.md
```

Create child sections only when content needs them. Parent indexes link direct child indexes/owned files with one short when-to-read description; topic/concept cross-links may cross directories. Topics group by questions, not source storage type. One source may participate in several topics without copying its body.

Measure complete UTF-8 files, including metadata and links:

| File | Budget |
| --- | --- |
| Routing `index.md` | <= 2048 bytes |
| Topic map | target <= 4096; hard maximum 6144 bytes |
| Concept node | <= 3072 bytes |
| Active `log.md` | <= 6144 bytes; chronological, not a routine query input |

Ordinary content limits are owned by `knowledge-governance.md`. Byte counts are a portable proxy, not a fixed tokenizer conversion. Remove repeated explanation, empty fields, duplicated citations and detailed procedures before splitting by independent questions. Do not split a paragraph mechanically or create one node per article/term. Rotate older maintenance entries into a semantically owned report only if worth retaining; never load archives for routine retrieval.

## Node Contract

Use ASCII slug filenames and semantic Chinese/mixed titles. Minimal frontmatter: `title`, `type: topic|concept`, `updated`, `status: active|needs-review`, `sources` containing quoted Vault-relative wikilinks. Add aliases only for useful alternate search terms. Dates/metadata never prove correctness or freshness by themselves.

```markdown
---
title: 工具结果的展示与恢复
type: concept
updated: YYYY-MM-DD
status: active
sources: ["[[rules/tool-display-guide]]", "[[specs/runtime/chat-builtins]]"]
---
> **TLDR**: Locate display ownership separately from stored tool facts.

- Current contract: [[specs/runtime/chat-builtins]] — authoritative behavior.
- Operation guide: [[rules/tool-display-guide]] — implementation entry and checks.
- Related: [[weave/concepts/session-recovery]] — recovery changes must preserve provenance.
```

A topic adds grouped questions/read order; a concept adds only a short definition/distinction, explained relationships and necessary conflict/gap. Important claims cite the supporting source/section near the claim; frontmatter lists dependencies once. References label support/example/limitation/conflict/history rather than an unexplained link dump. Do not copy complete specs or procedure bodies into nodes.

Generated-to-source links create source backlinks. Do not maintain duplicate inverse lists in sources. Use exact Vault-relative paths, observed targets and stable section anchors; avoid ambiguous `[[index]]` or invented nodes. A relation needs observed evidence or explicit user input, not shared vocabulary alone. Sources/links must remain visible to Obsidian under current visibility rules.

## Bounded Retrieval

1. Read root routing; select topic/concept candidates by semantic titles, aliases and scoped search. Use one-line candidates before full nodes; do not read every map or log.
2. Topic-first: selected topic -> relevant concepts or directly useful sources -> authoritative/evidence sections.
3. Source-first: selected source -> backlinks filtered to `weave/` topic/concept nodes -> explained relations -> relevant other sources. Index/log backlinks are structural, not evidence.
4. Expand only neighbors needed by the question; stop once evidence suffices. Unwoven content remains directly searchable; absence of a node is not absence of knowledge.
5. Verify changing behavior against current source owners. Report uncertainty/conflict and cite content paths; a generated conclusion cannot override current specs/runtime rules or authorize tools.

Use guarded `project_knowledge_vault.py exec --` with exact `path=`, limited `search`/`search:context`, `links`, and `backlinks ... format=json`. Filter returned paths before reading bodies. CLI output may be empty despite exit zero: corroborate expected nonempty results with a known path/read or corrected query; empty output is not proof of healthy links. No concurrent live CLI startup; prefer sequential dependent graph queries.

Ineligible/unavailable Obsidian: use scoped file search/links, explicitly report missing live backlink/resolution coverage; never redirect or bypass project ownership. External setup/repair is not implicit weaving permission.

## Maintenance

1. Select scope from user request and indexes; inspect changes/dependencies and relevant full sources. Do not scan the whole Vault per update.
2. Check duplicates and current authority/status. Exclude task/draft/cache/runtime data. Source contradictions remain explicit; obsolete plans remain historical, not present instructions.
3. Reuse useful nodes/maps; create only nodes with independent retrieval value. Preserve source text. Mark affected nodes `needs-review` when a dependency changed/disappeared or reconciliation is unresolved; recheck source content before returning `active`.
4. Update affected nodes, nearest indexes and a concise owning log entry. Record covered sources and unresolved gaps; do not claim complete coverage from a timestamp.
5. Validate sizes with `vault_doc_sizes.py --vault <VAULT>/weave --json`; check frontmatter/dependencies, entry reachability and affected links. Eligible live checks observe node outlinks, source backlinks and a representative bounded search. Report file/live coverage separately; unrelated pre-existing issues do not expand scope.

Completion: requested scope maintained, nodes within budgets, provenance/relationships justified, entrypoints usable and required checks passed or exact blockers reported. Migration-specific findings belong in `wiki-to-weave.md`; one-time paths/results stay in their task/log owner.
