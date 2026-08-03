---
title: SuperMax Async Lifecycle and View Detach
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/background-interactions/spec.md
---

# Contract

Every asynchronous request, provider stream, tool task, watchdog timer, history operation and UI callback has an owner scope: session, request, tool call or view. Child tasks inherit cancellation from their owner.

## Cancellation and cleanup

- Chat cancel propagates to the provider request and owned tool tasks.
- Chat close cancels owned tasks, closes timers/handles and prevents late mutation.
- Neovim exit performs best-effort cancellation and cleanup.
- Soft stop does not cancel active work; it changes continuation policy at the safe boundary.
- Buffer deletion detaches the view and preserves the session unless close was requested.

Callbacks MUST check generation/request identity and target validity before mutating state. Cleanup is idempotent and observable when a task cannot be cancelled cleanly. The replacement harness and mandatory provider/tool/view/history cancellation fixtures are defined in `../../runtime-fixture-contract.md`; every fixture asserts resource cleanup and exactly one terminal effect.
