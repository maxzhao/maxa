---
kind: module-index
authority: draft
status: partial
module: chat-lifecycle
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
---

# Chat Lifecycle Module

- Specification: [[spec]]
- Scope: CodeCompanion.nvim `v18.7.0` chat create/open/submit/stop/close, request state, rendering, navigation, events, and observable errors.
- Status: `partial`; baseline UI builder/formatters/folds/keymaps/autocmds, event mapping, ACP disconnect race, request/error/stop/close paths, and tool-loop boundaries are traced. Default keymap inventory is complete; runtime race/listener validation, end-to-end provider continuation, and executable lifecycle tests remain incomplete.
- Authority: evidence-backed draft only; no SuperMax downstream behavior and no latest-upstream behavior included.
