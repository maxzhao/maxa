---
title: Events and public integration upstream delta
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
---

## Source diff

The directly matched public integration change is `doc/usage/events.md` (+41/- changes). No source event implementation change is claimed from the path filter alone.

## Observable behavior delta

Latest-upstream documents additional or clarified events/integration observations. Documentation is evidence of intended public surface, not proof that every event or payload changed at runtime.

## Compatibility impact

Potentially medium for event listeners: event names, timing, payload shape, or lifecycle guarantees may have expanded/clarified. Existing listeners should be checked against source before migration.

## Validation and unknowns

Reviewed the baseline/latest documentation diff. Not run: event emission tracing or listener contract tests. Unknown: which documented events are new versus clarified and whether payload/timing changed.
