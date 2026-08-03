---
title: HTTP transport upstream delta
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
---

## Source diff

HTTP/ACP adapter and provider surfaces change broadly: Anthropic has a large rewrite, Copilot model discovery changes substantially, ACP adapter helpers/init and multiple adapters change, and HTTP/adapter configuration docs expand.

## Observable behavior delta

Request construction, authentication/model discovery, streaming/event parsing, provider-specific payloads, and error handling may differ. New ACP-backed transports/adapters broaden selectable backends.

## Compatibility impact

High for custom providers, model catalogs, request hooks, headers, schemas, and streaming consumers. Provider behavior must not be inferred from documentation-only changes.

## Validation and unknowns

Reviewed `git diff/show` for adapter/provider source, tests, and docs. Not run: provider contract matrix, streaming fixtures, auth/model discovery, retries, malformed responses, and cancellation. Unknown: exact payload/header changes and fallback semantics.
