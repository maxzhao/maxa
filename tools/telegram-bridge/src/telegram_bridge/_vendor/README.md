# Vendored Telegram Markdown Renderer

This directory contains source vendored for the Maxa Telegram Bridge runtime.

## Components

- `telegramify_markdown/`: vendored from `telegramify-markdown` 1.2.0, MIT License, Copyright (c) 2024 Jasmine.
- `licenses/telegramify_markdown.LICENSE`: upstream license text.
- `licenses/pyromark.LICENSE`: license for the direct `pyromark` parser dependency used by the vendored renderer.

## Maintenance policy

This is not treated as a synchronized upstream mirror. Maxa owns this local copy and may change rendering behavior for Telegram readability, especially table and link policies. Do not reintroduce the external `telegramify-markdown` package without an explicit compatibility review.

`pyromark` remains a direct package dependency because it ships platform-specific parser binaries; vendoring those binaries into the repository would make the shared runtime less portable.
