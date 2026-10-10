# Knowledge Governance

Purpose: maintain project-local Obsidian-backed content and source-backed LLM retrieval views. Layout, schema, index/log ownership, ignore/sync rules and checkout eligibility are owned by `references/knowledge-vault.md`; read it before governed operations.

## Model And Routing

Layers:

1. **Content**: articles, evidence, source summaries, ideas, rule sources, behavior specs and reports under their semantic owner. External originals are preserved; project-owned notes may evolve through their owning workflow.
2. **Weave**: compact LLM-maintained topic/concept navigation and explained relationships; `references/weave.md` owns node format, budgets, user-triggered maintenance and retrieval.
3. **Schema**: Ability instructions, project rules, references, templates and scripts.

Humans curate content and review; Agents perform authorized content work and maintain generated weave. Generated views do not replace source authority. Intake writes content, not weave; query/check never implies persistence or repair.

| Operation | Required route |
| --- | --- |
| Locate / save | Current repository `.maxa/`, its entry/indexes and the note contract below |
| Query | Progressive Read Path and Query Contract |
| Ingest | Note Contract and Ingest Contract |
| Curate inbox captures | Curation Contract, then `references/inbox-curation.md` |
| Lint / health | Lint And Repair Boundary; script examples in `references/vault-operations.md` |
| Agent reachability | `references/agent-reachability.md` |
| Feedback processing/listening | Feedback Processing below |
| Markdown / Bases / Canvas / TODOseq | Corresponding scenario reference from `SKILL.md` |
| Plugin development/distribution | Corresponding plugin reference from `SKILL.md` |

Combined work: locate/query before ingest; ingest before link repair; lint before governance repair; report before bulk movement. Do not copy TaskAdmin documents or transient execution data into knowledge.

## Progressive Read Path

| Level | Select |
| --- | --- |
| L0 | Project rules, Vault entry and target routing |
| L1 | `index.md`, selected `weave/index.md`, `inbox/index.md`, `specs/index.md` or content category indexes |
| L2 | Candidate TLDRs, source summaries, scoped search results and graph neighbors |
| L3 | Selected full notes |
| L4 | Source/evidence documents when summaries are insufficient or fidelity requires them |

Read entry/indexes first. Search likely filenames/headings with file tools or the guarded CLI. Use outgoing/backlinks when graph context matters. Do not scan the whole Vault or bulk-read raw sources for broad queries.

## Note Contract

New durable notes use English/ASCII slug filenames and Chinese or mixed Chinese/English semantic frontmatter `title`.

```markdown
---
title: 中文语义标题，可混合必要英文技术术语
created: YYYY-MM-DD
updated: YYYY-MM-DD
type: entity|concept|source-summary|comparison|synthesis|pattern|decision|module|glossary|personal|reading
tags: [tag1, tag2]
sources: ["research/example-source.md"]
confidence: high|medium|low
aliases: [alternate name]
---

> **TLDR**: One-sentence core takeaway.

Content with [[wikilinks]] to related concepts.

## 待解问题
- [TODO: 未确认的点——标记空白，绝不填充幻觉内容]

## 反论与数据空白
```

Requirements:

- Important claims trace to `sources:` or explicit user input. Separate fact, inference and open question; use `confidence: low` and `[TODO: ...]` for uncertainty.
- Preserve immutable sources; write summaries/synthesis separately. Search for duplicates before creating a note, and preserve previous provenance on repeated ingest.
- Link only from observed names, indexes, backlinks, source relations or explicit user input. Do not fabricate relationships.
- Preserve `反论与数据空白` for non-trivial conclusions. Prefer minimal diffs; do not rewrite unrelated existing sections.
- Keep Agent-facing notes dense: TLDR, facts, evidence, paths, links, open questions and validation; omit blog-style background and one-off process narrative.
- Update the nearest index and Vault-level index when discoverability changes; add a concise entry to the owning `log.md`. Respect existing `overview.md`, `hot.md`, `_index.md` conventions rather than inventing them.

Title checks flag Chinese filenames, missing `title`, placeholders (`Index`, `Untitled`), pure slug titles, and English titles merely followed by a Chinese type suffix such as `...（错误经验）`.

## Ingest Contract

1. Record source path, URL or user-provided origin.
2. Classify target: source material, source-summary, concept/entity, decision, pattern, comparison, module, glossary or synthesis; choose its semantic owner.
3. Read indexes/search duplicates before creating notes.
4. Merge existing notes conservatively and retain prior provenance. Create/update source-summary before broad synthesis for durable source material.
5. Apply the content note contract; source summaries/synthesis stay with their semantic content owner, without parallel generated articles. Weaving is a separate user-requested operation.
6. Update nearest indexes, graph links and owning log.
7. Validate frontmatter, links and discoverability; report changed files, sources and unresolved questions.

Ask before overwriting sources, deleting notes or merging conflicting claims when interpretation is not mechanical.

## Query Contract

1. State target Vault and entrypoints used.
2. Read indexes, search scoped folders, then TLDR/source summaries before selected full notes. Summarize candidate coverage before deep-reading many notes.
3. Use backlinks/outgoing links when graph context matters; separate Vault facts from current-session inference.
4. Include paths or wikilinks for important claims.
5. Save durable synthesis only when requested; ask before persistence otherwise.
6. If knowledge is insufficient, report searched entrypoints and terms.

## Curation Contract

Curation reviews content, not generated-node publishing.

Order: `inbox/index.md` → inventory active captures → cluster by meaning → detect duplicates/conflicts/staleness → propose broad changes → merge/organize into the matching content owner (or keep pending) → mark/archive originals with traceability → update indexes/log → validate links/reachability. Do not promote captures into weave; separately requested weaving may use reviewed content.

Do not include `inbox/feedback/` in ordinary capture curation. Use `references/inbox-curation.md` for queue definitions and mechanical script assistance.

## Lint And Repair Boundary

Health/lint is diagnostic by default. Do not move, rename, archive, delete, cluster/promote captures, process feedback, migrate sources or bulk rewrite without explicit repair authorization.

Default diagnostics:

1. Structure/key entries: target root, `index.md`, `weave/index.md`, `inbox/index.md`, `specs/index.md`, applicable content indexes/logs. An unmigrated old generated area is pending migration, not permission to rename or create a parallel tree.
2. Link/graph health: broken/unresolved links and abnormal outgoing/backlinks. Orphan overview does not establish Agent reachability.
3. Frontmatter and semantic-title checks.
4. Markdown size: ordinary knowledge notes <= 30,000 bytes; target-owned evidence/workspace directories and non-Markdown are exempt. Generated files use `references/weave.md` role budgets including metadata/links; source-owner location alone does not exempt an ordinary Markdown article.
5. Source metadata consistency where source collections exist.
6. Inbox capture counts and obvious metadata issues, without clustering/promotion.
7. Feedback queue counts, without reading/processing bodies or changing state.
8. User-maintained files such as root `plan.md` are report-only unless explicitly requested.
9. Report risks and relevant follow-up; record only safe log entries.

CLI checks require guarded project dispatch and verified physical target. Linked Worktrees and `--quick` checks are file-only; report graph coverage gaps, never another Vault's graph as evidence.

## Feedback Processing

For “process feedback / listen feedback / watch feedback / process `inbox/feedback`”:

1. Resolve the current project's `.maxa/` target.
2. Wait/list through the cataloged watcher. Existing pending feedback returns immediately; otherwise wait for new files.

```yaml
title: "Wait for Vault feedback"
scope: tool
command: "@project-admin:/scripts/watch_feedback.py"
args: ["--vault", "<VAULT>", "--json"]
```

3. Use infinite-wait semantics; if numeric timeout is required, use a large timeout rather than the default 300 seconds. Apply the Runtime async/wait contract to long-running commands.
4. Read feedback, locate `target` / `target_note`, and verify `quoted_text` / `selection` before editing.
5. If safely actionable, minimally update target content or regenerate a source-backed weave target under `references/weave.md`, relevant indexes and owning log; mark feedback `done` with `processed_at`, `processed_by`, `result`, `changed_files`, then move to `inbox/feedback/done/`.
6. If target/evidence/selection is missing or user choice is required, ask. If still blocked, mark `failed` with reason and move to `inbox/feedback/failed/`.
7. After each item, output a short processing log and immediately wait for the next until the user stops the loop.

Compression follows the Runtime Token Management Protocol. Authorized compaction preserves user goal, Vault/queue paths, recent results, current feedback and unresolved issues.

## Optional Recent-Context Cache

Use `hot.md`, `overview.md` or dashboard notes only when already present or required by project rules. Keep updated date, key facts, recent changes/flags, active threads and open questions concise. These caches do not replace `log.md`.

## Validation And Final Output

After durable knowledge changes, validate:

- Markdown/Obsidian syntax and frontmatter/provenance.
- New wikilinks resolve or are intentional placeholders.
- Nearest/root indexes expose the note through the documented entry chain.
- Owning `log.md` records the operation.
- Required graph checks used the guarded CLI when available; otherwise state the validation gap.

Report target Vault, operation, changed files, sources/entrypoints, index/log changes, validation and open questions. Keep detailed execution evidence in its existing owner.
