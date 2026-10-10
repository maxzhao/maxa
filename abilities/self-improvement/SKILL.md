---
name: self-improvement
description: "Capture stable task errors, reusable learnings, and improvement ideas into the project knowledge Vault through explicit requests or optional TaskCompleted workflows."
compatibility: Requires Maxa Ability runtime.
---
# Self-Improvement Ability

Purpose: guide Agents to capture stable errors, learnings, and improvement ideas into the project knowledge Vault.

## Responsibility Boundary

| Layer | Responsibility |
| --- | --- |
| `project-admin` | Project governance and Vault operations: init/sync/migrate, knowledge workflows, progressive disclosure, CLI/file boundaries. |
| `self-improvement` | Capture entry: decide whether knowledge is worth capturing, check existing knowledge, choose capture-note destination. |
| `.maxa/` | Root Vault knowledge layer: capture, organize, review, index, link, promote when appropriate. |

Core rule: `self-improvement` only guides knowledge capture. It is not a publishing layer, does not maintain a separate learnings layer, and does not copy captures to other project Vaults by default.

## Capture Destination

Default project capture path:

```text
.maxa/inbox/
├── index.md              # capture / feedback review entrypoint
├── errors/
├── learnings/
└── feature-requests/
```

Selection:

- Error fixes / troubleshooting patterns -> `.maxa/inbox/errors/`.
- Non-obvious findings / user corrections / workflow learnings -> `.maxa/inbox/learnings/`.
- Toolchain ideas / automation suggestions / structure improvements -> `.maxa/inbox/feature-requests/`.

## Pre-Capture Check

Before creating a capture note, check the smallest useful scope:

1. `.maxa/index.md`
2. `.maxa/inbox/index.md`
3. Same-topic notes under the relevant `.maxa/inbox/*` directory
4. Relevant content-owner notes, located through the root/category indexes; generated weave nodes may help find sources but are not capture destinations

If a suitable note exists, update/append/merge it. Otherwise create a new note in the matching inbox subdirectory.

Reachability rules:

- Do not write new capture notes directly into `AGENTS.md`.
- Every capture note must be discoverable through `inbox/index.md` or an equivalent review entrypoint.
- If the review entrypoint is missing, create or update it before leaving the note as hidden knowledge.
- Content curation/merging uses ProjectAdmin's semantic owner workflow. Weaving is a separate user-triggered operation; do not update generated weave during capture/hooks or treat a generated summary as absorbed original content.

## Capture Note Contract

Minimum content:

- Frontmatter: `title`, `created`, `updated`, `type`, `tags`, `sources`, `confidence`.
- `> **TLDR**:` one-sentence summary.
- Dense body: problem/finding/fix/proposal.
- Traceability to current task or source.
- Explicit link relation to `inbox/index.md`, same-topic capture notes, or later organized notes.

Capture notes are Agent-facing knowledge artifacts. Prefer dense fields: `Fact`, `Trigger`, `Evidence`, `Paths`, `Fix`, `Proposal`, `Reuse`, `Validation`, `Risk`. Remove one-off narrative and status-report prose. Preserve exact commands, paths, error strings, tool names, task IDs, and validation evidence.

For detailed capture flow and hook boundaries, read `references/knowledge-flow.md`.

For generic Vault operations, index maintenance or graph checks, load `project-admin` and follow its knowledge workflows. Do not hardcode its internal resource paths here. Durable knowledge remains project-local; cross-project Markdown knowledge migration is outside this capture workflow.

## Hook Boundary

The `TaskCompleted` hook is optional side-channel guidance after the current task deliverable is complete, not a new main task.

Rules:

1. First decide whether self-improvement work is worthwhile; skip when value is unclear.
2. Hook-triggered self-improvement actions must use fork agent. Before using fork agent, load `subagent` and follow it.
3. The main Agent must not directly perform self-improvement knowledge search, Vault reads, file writes, or note updates.
4. The child Agent may load `self-improvement` and perform the smallest pre-capture check plus capture.
5. Child results returned to the main Agent must be minimal: capture count/status and any material blocker.
6. After hook-side work, the main Agent must immediately return to the current task.
7. Capture must not change the current task goal or make the final reply end on knowledge capture.

## TaskCompleted

Use `TaskCompleted` capture only for stable, reusable, high-value knowledge, following Hook Boundary above.

Pre-task project exploration and knowledge lookup belong to the requesting workflow before an implementation task is created; they are not self-improvement hooks or capture work.

## Default Non-Goals

- Do not write `.maxa/learnings/ERRORS.md`, `LEARNINGS.md`, or `FEATURE_REQUESTS.md` for new capture.
- Do not write directly to `rules/` or `research/` from hooks.
- Do not copy captures to another project Vault by default.
- Do not capture raw `ToolCallError` noise by default; stable error-fix knowledge belongs in `TaskCompleted` capture.
- Do not treat capture reachability as a reason to edit `AGENTS.md`; maintain `inbox/index.md`, category indexes, same-topic notes, or organized-note links.

An explicit cross-project knowledge migration request is outside this Ability's default responsibility; determine the authorized source/target and scope before any file movement. Routine knowledge maintenance uses `project-admin`.

## Resources

- `references/knowledge-flow.md` — capture -> organize -> review path and hook boundaries.
- `hooks/TaskCompleted.md` — skippable post-task capture hook for high-value stable knowledge.
- `assets/ERRORS.md`, `assets/LEARNINGS.md`, `assets/FEATURE_REQUESTS.md` — legacy log templates for recognizing or migrating old material; do not write new default capture there.

