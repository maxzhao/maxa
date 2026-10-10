---
title: Grab Note Feedback Plugin 行为规格
created: 2026-06-28
updated: 2026-09-22
type: source
doc_role: spec
authority: draft
status: experimental
capability: grab-note-feedback
sources:
  - obsidian-plugins/grab-note/manifest.json
  - obsidian-plugins/grab-note/package.json
  - obsidian-plugins/grab-note/src/main.ts
  - obsidian-plugins/grab-note/main.js
  - obsidian-plugins/grab-note/styles.css
  - abilities/obsidian/SKILL.md
  - user-review:2026-09-15
confidence: medium
---

> **TLDR**: `grab-note` captures reviewable Markdown/Canvas feedback locally with auditable target context.

## Requirements

- **Workflow**: The plugin SHALL expose feedback capture/review/submission commands and a side-panel workflow.
- **Local state**: Entries remain editable/reviewable at `inbox/feedback/.grab-note-local.json` until successful submission. Write failure preserves local feedback and reports the error.
- **Capture context**: Markdown preserves target file, quote/text, available line range and surrounding context; Canvas preserves target kind/id and formatted context. Unresolved targets are skipped rather than guessed. Missing target/file and unavailable clipboard operations fail safely.
- **Submission**: Write one Markdown file per entry under `inbox/feedback/pending/` with `type: feedback`, `status: pending`, target/source context, TLDR, quoted text, user feedback and quote-verification instruction.
- **Ownership**: Obsidian workflow owns Agent-side feedback processing; [[specs/abilities/base/project-admin/project-vault|Project Vault Governance]] owns plugin distribution.

## Validation And Review State

- Historical checks passed: TypeScript typecheck and built `main.js` syntax.
- Human specification review passed by explicit user declaration on 2026-09-15.
- Not run: current live Markdown/Canvas capture, batch submission and Agent processing smoke in a disposable Vault. Status remains experimental.
