---
kind: module-index
authority: draft
status: partial
module: events-integration
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
---

# Events / Public Integration Module

- Specification: [[spec]]
- Scope: CodeCompanion.nvim `v18.7.0` User autocmd event bridge, event payloads/timing, internal listeners, public Lua entrypoints and `:CodeCompanion*` commands.
- Status: `partial`: baseline checkout and source event inventory are verified; complete runtime listener-failure isolation and full command callback behavior remain unvalidated.
- Authority: evidence-backed reverse-engineering draft. It records upstream behavior only; no downstream/latest-upstream/target design is included.
- Validation blocker: `make test` was not run because the baseline test command requires network-fetched `deps/*`; no test failure is claimed. A focused source/static validation was run instead.

## Reading order

1. `../../baseline.md`
2. `spec.md`
3. baseline source traces listed in `spec.md`

## Boundary

The event bridge is `require("codecompanion.utils").fire(event, opts)`, which synchronously calls `vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanion" .. event, data = opts })`. Event names and payloads are not declared in one schema; they are distributed across interaction, transport, diff, tool, and completion modules.
