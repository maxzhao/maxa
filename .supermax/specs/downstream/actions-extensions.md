---
title: Downstream delta — actions-extensions
authority: draft
status: experimental
baseline_module: ../modules/actions-extensions/spec.md
---

## Classification

- `compatibility shim`: CodeCompanion extension lifecycle is consumed by local history/display extensions.
- `product requirement`: SuperMax adds history commands, pickers, transfer, and display behavior.

## Evidence

- Baseline: `../modules/actions-extensions/spec.md`.
- `lua/codecompanion/_extensions/history/init.lua`: `History.new`, `_create_commands`, `_setup_autocommands`, `_setup_keymaps`.
- `lua/codecompanion/_extensions/history/pickers/`, `storage.lua`, `transfer.lua`, `ui.lua`, `title_generator.lua`.
- `lua/codecompanion/_extensions/display_chat_history/init.lua`.

## Coverage / risk / decision

- Upstream baseline behavior: actions/extensions and UI customization provide extension points and action dispatch.
- SuperMax coverage: adapts those boundaries into persistent session history, project registry, pickers, transfer, and commands.
- Coupling risk: direct requires of `codecompanion.interactions.chat` and `codecompanion.config` couple the extension to upstream internals.
- Independent runtime decision: retain as downstream adaptation; final product requirement is not defined here.
