# SuperMax project-local `.supermax/` root Vault

Whole-project Agent knowledge routing. `.supermax/` is an independent Obsidian Vault.

## Zones

- **[wiki](wiki/index.md)** — agent-maintained synthesis layer.
- **[specs](specs/index.md)** — behavior specs and change workspaces.
- **[inbox](inbox/index.md)** — capture / review / feedback entry.
- **[attachments](attachments/index.md)** — durable shared files with no more specific owner.
- **[canvases](canvases/index.md)** — Obsidian Canvas artifacts.
- `tasks/` — TaskAdmin internal storage (not ordinary notes). Load `task-admin` before task operations.
- `drafts/` — temporary Agent drafts, not durable knowledge. Git/Syncthing-visible, Git-ignored.
- `translate-cache/` — generated translation/cache content, Git-ignored.

## Guidance

- Start knowledge retrieval here, then enter the category index that matches your goal.
- Parent indexes route only to direct child indexes or directly owned files; do not duplicate deep index content.
- Do not create `.supermax/knowledge/` or root `raw/`.

## Capture / review

New or unprocessed content goes to **[inbox](inbox/index.md)**.
