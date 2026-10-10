# Self-Improvement Knowledge Flow

Purpose: route reusable errors, learnings, and feature ideas into the project-local `.maxa/` root Vault without creating a separate learning-log system.

## Destination Model

Default project capture path:

```text
.maxa/inbox/
├── index.md
├── log.md
├── errors/
├── learnings/
└── feature-requests/
```

Selection:

| Capture type | Destination |
| --- | --- |
| Error fixes / troubleshooting patterns | `.maxa/inbox/errors/` |
| Non-obvious findings / user corrections / workflow learnings | `.maxa/inbox/learnings/` |
| Toolchain ideas / automation suggestions / structure improvements | `.maxa/inbox/feature-requests/` |

Do not write new captures to `.maxa/knowledge/`, `.maxa/rules.md`, root `raw/`, TaskAdmin task workspaces, or runtime temp directories.

## Pre-Capture Check

Use the smallest useful scope:

1. `.maxa/index.md`
2. `.maxa/inbox/index.md`
3. Same-topic notes under the matching inbox subdirectory
4. Relevant content-owner notes through current category indexes; weave can locate sources but is not a capture/merge target

If a suitable note exists, update/append/merge it. Otherwise create a new note in the matching inbox subdirectory.

## Capture Note Contract

Minimum content:

- Frontmatter: `title`, `created`, `updated`, `type`, `tags`, `sources`, `confidence`.
- `> **TLDR**:` one-sentence summary.
- Dense body: problem/finding/fix/proposal.
- Traceability to current task, source, or explicit user input.
- Link relation to `inbox/index.md`, same-topic capture notes, or later organized notes.

Use exact Vault-relative links such as `[[inbox/index]]` and `[[rules/example]]`; follow observed targets, not invented nodes.

## Reachability

Every capture must be discoverable through `inbox/index.md` or an equivalent review entrypoint.

Rules:

- If a capture subdirectory grows enough to need routing, add a child `index.md` there.
- Parent indexes route to child indexes or directly owned files; they must not duplicate deep child index content.
- When curating stable captures, follow ProjectAdmin's content-owner workflow and update its nearest index/log. Generated weave maintenance remains separately requested, outside capture/hooks.
- Do not edit `AGENTS.md` only to expose a capture; maintain indexes/links instead.

## Content Curation Flow

1. Confirm stable reusable content and current evidence.
2. Search inbox and matching content indexes; use weave only as a source locator.
3. Conservatively merge into existing content or organize into the justified semantic owner.
4. Update the nearest index/log and preserve source provenance.
5. Mark/archive originals only after actual absorption under ProjectAdmin curation; a generated summary does not absorb a source.

## Evidence Handling

Root `raw/` is retired. If original evidence must be preserved:

- attach files under `attachments/` when they are durable shared files;
- use `research/` when the project intentionally has a research category;
- use `reports/` for audits, health reports, migration reports, or validation report artifacts;
- create a new top-level category only with explicit ownership, `index.md`, and `log.md`.

Reference evidence through `sources:` or body links.

## Hook Boundary

The self-improvement `TaskCompleted` hook is optional side-channel work after the main deliverable is complete. It must not replace or extend the current task.

- Capture stable, reusable learning only when the completed work produced clear value.
- Hook-triggered capture should be delegated according to the main self-improvement Ability rules.
- Child results should report only capture status/counts and any material blocker.
- Pre-task project exploration and knowledge lookup belong to the requesting workflow before an implementation task is created; they are outside this capture flow.
