---
title: Web Fetch Workflow 行为规格
created: 2026-06-29
updated: 2026-09-22
type: source
doc_role: spec
authority: draft
status: experimental
capability: web-fetch-workflow
sources:
  - abilities/web-fetch/SKILL.md
  - abilities/web-fetch/references/cli-spec.md
  - abilities/web-fetch/bin/web-fetch
  - prompts/system.md
  - user-review:2026-09-15
confidence: medium
---

## Requirements

- **Routing**: Before search/URL fetch/body extraction, load `web-fetch` and resolve its CLI from the returned skill root. Known URLs start with `<skill_root>/bin/web-fetch auto <url> --format markdown`. Search uses `<skill_root>/bin/web-fetch search "<query>" --json` for candidate JSON/discovery metadata, not source content; then fetch selected URLs.
- **Escalation**: On failure, follow the skill decision tree; never jump directly to browser automation. Escalate to browser/stealth or Tauri only as required. After web-fetch escalation, load `browser` for required protected browser state/CDP/app interaction. Deprecated Web MCP servers are not public fallbacks.
- **Output**: Public URL modes: `auto`, `direct`, `readable`, `browser`, `stealth`; formats: `raw`, `markdown`. Apply format before regex snippets/output writing. Inline success returns final content; `--output` confirms writing with overwrite safeguards. Binary content should use raw file output rather than inline text.
- **Environment**: Mainland-China networking uses configured proxy defaults unless project rules override. All invoked skill Python tests/scripts SHALL use its declared uv project/runtime; system `python3` is invalid validation.

## Validation Plan

Run `<skill_root>/bin/web-fetch --help` and relevant subcommand help; run skill-owned regression entrypoints under **Environment**; fetch one stable URL via `auto --format markdown` with project proxy rules.

## Validation And Review State

Human specification review passed by explicit user declaration on 2026-09-15. Current local regression suite and stable-URL network smoke: not run; status remains experimental.
