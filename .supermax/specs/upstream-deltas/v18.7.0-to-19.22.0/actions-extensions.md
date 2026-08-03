---
title: Actions and extensions upstream delta
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
---

## Source diff

The `actions` implementation is renamed/reworked under `action_palette` with large changes to `init.lua` and `static.lua`. Latest-upstream adds Gemini interaction support, diff UI, and changes UI/parser/extension documentation and helper naming.

## Observable behavior delta

The user-facing action launcher may expose a different palette, action registration/discovery, and UI rendering. Gemini interactions and diff presentation add visible workflows. Existing extension/parser/UI configuration may require renamed paths or fields.

## Compatibility impact

Medium to high for custom extensions and action registrations; low-to-additive for users who only invoke built-ins. Rename compatibility and action ordering/keymap behavior are unverified.

## Validation and unknowns

Reviewed baseline/latest source paths and docs with `git diff/show`. Not run: action palette interaction tests, custom extension loading, parser contracts, and diff UI rendering. Unknown: aliases for the old `actions` path and exact extension API compatibility.
