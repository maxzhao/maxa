# Root Categories And Source Scaffolds

Purpose: choose semantic content owners and scaffold source notes. `references/knowledge-vault.md` owns required/optional roots, workspace boundaries, retired paths and progressive index/log rules; read it before creating or repairing categories.

## Category Selection

Optional categories are project-shaped, not mandatory source directories:

| Category | Use for | Do not use for |
| --- | --- | --- |
| `ideas/` | Exploratory concepts, pre-spec proposals, topic bundles | Accepted behavior contracts or stable synthesis |
| `reports/` | Migration reports, audits, health/validation reports | Behavior contracts or evergreen operational content |
| `research/` | External/technical evidence, API notes, investigations | Accepted decisions without evidence |
| `rules/` | Source-layer rule notes/research | Live L0 Agent contract; use `AGENTS.md` |

Content/evidence belongs to a semantic owner, not retired root `raw/`. Accepted behavior uses the SpecAdmin `specs/` workflow; detailed patterns/decisions/module explanations remain content in the appropriate owner. `weave/` contains only generated topic/concept retrieval views; weaving is separate from intake. Task workspaces, drafts and generated cache are not content notes.

## Scaffold Workflow

1. Confirm target category from content and current project indexes.
2. Repair missing required skeleton through the governance operation; do not silently create unrelated roots.
3. For a missing optional category, create only when the user explicitly requested the category/content or confirm the project need first.
4. Ensure the owner category's index/log and applicable child index exist, following `knowledge-vault.md`.
5. Write the note using Note Contract in `knowledge-governance.md`, including source provenance.
6. Update the nearest relevant index and owning log; parent indexes route rather than duplicating child content.
7. Validate provenance, links and reachability; report changed files/open questions.

## Example Paths

```text
.maxa/specs/<capability>/spec.md
.maxa/specs/changes/<change-id>/proposal.md
.maxa/rules/<workflow>.md
.maxa/weave/concepts/<concept>.md
.maxa/research/<topic>.md
.maxa/ideas/<topic>/index.md
.maxa/reports/<report>.md
.maxa/rules/<rule-source>.md
```

Optional paths apply only after intentionally creating their category. Spec and TaskAdmin lifecycle operations retain their owning Ability workflows.
