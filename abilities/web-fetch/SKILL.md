---
name: web-fetch
description: "Use the Ability-local CLI for web search, URL fetching, readable body extraction, browser or stealth fetching, content saving, and regex snippet extraction when a task needs web content retrieval or extraction."
compatibility: Requires Maxa Ability runtime.
---
# Web Fetch

Purpose: use the Ability-local CLI for web search, URL fetch, readable extraction, browser/stealth fetch, file output, and regex snippet extraction.

After `load(target="web-fetch")`, invoke the cataloged entrypoint through titled `run(scope="tool")`, not a shell command or constructed filesystem target:

```yaml
run:
  title: "Inspect web-fetch help"
  scope: tool
  command: "@web-fetch:/bin/web-fetch"
  args: ["--help"]
```

Every subcommand/option below is literal array `args` content. Replace URL/query/path placeholders before invoking; there is no shell expansion.

Public contract:

- For external network access, follow the active system prompt's proxy requirements. Use the configured proxy through inherited proxy environment variables or `--proxy-url`; do not invent, hardcode, or persist proxy values in Ability artifacts.
- Public URL modes: `auto`, `direct`, `readable`, `browser`, `stealth`.
- Public search mode: `search`.
- Former source-named URL commands are not public CLI subcommands.
- The `load` script catalog must expose `/bin/web-fetch`; `exclude` intentionally hides `scripts/`, `tests/`, and `vendor/`.
- For full CLI schema, output semantics, special routes, and validation commands, use `read(path="#web-fetch[/references/cli-spec.md]")`.

## Decision Guide

| Need | Array `args` for `@web-fetch:/bin/web-fetch` |
| --- | --- |
| Web search | `["search", "query", "--json"]` |
| Known URL, unsure method | `["auto", "<url>", "--format", "markdown"]` |
| Exact/raw response or download | `["direct", "<url>", "--format", "raw"]` |
| Article/body extraction | `["readable", "<url>", "--format", "markdown"]` |
| JS-rendered page | `["browser", "<url>", "--format", "markdown"]` |
| Stronger anti-bot attempt | `["stealth", "<url>", "--format", "markdown"]` |
| Regex snippet extraction | add `--pattern "regex" --context-chars N` |
| Save output | add `--output <path>` and `--overwrite` when replacement is intended |

Default for known URLs: start with `auto --format markdown`. Do not skip directly to `browser`/`stealth` unless the user asks or `auto`/lighter modes provide evidence.

If URL fetch modes still cannot obtain content and the likely cause is JS rendering, real browser state, CDP-only access, or protected browser access, load `browser` and follow that Ability's instructions.

## URL Fetch Commands

CLI argument grammar only; pass the selected subcommand and each option as separate array `args` entries:

```text
auto <url> [shared-options]
direct <url> [shared-options]
readable <url> [shared-options]
browser <url> [shared-options]
stealth <url> [shared-options]
```

| Command | Use when |
| --- | --- |
| `auto` | Default for known URLs; special site routing plus generic fallback. |
| `direct` | Direct HTTP(S); raw text/API/HTML or binary file saving. |
| `readable` | Readable page text/body via open-websearch adapter. |
| `browser` | Page likely needs browser/JS rendering. |
| `stealth` | Stronger anti-bot/Cloudflare-style pages. |

Shared options: `--format raw|markdown`, `--output <path>`, `--overwrite`, `--max-bytes <N>`, `--timeout <seconds>`, `--proxy-url <url>`, `--pattern <regex>`, `--context-chars <N>`, and for `auto` only `--no-special-route`.

Processing order:

```text
fetch -> --format final text -> --pattern context extraction -> stdout/file output
```

URL fetch success output is not JSON:

- Inline: stdout is final content only.
- File: stdout is `Wrote <path>`.

Failures exit non-zero and write stderr diagnostics with prefixes such as `[access]`, `[convert]`, `[output]`, `[route]`, or `[pattern]`.

## Auto Routing And Pattern

`auto` may internally use special routes for GitHub repositories, CSDN, Juejin, and Linux.do. These routes are not public subcommands.

Bypass special routing:

```yaml
run:
  title: "Fetch URL without special routing"
  scope: tool
  command: "@web-fetch:/bin/web-fetch"
  args: ["auto", "<url>", "--no-special-route", "--format", "markdown"]
```

Special routes do not support `--pattern`; use `--no-special-route` or an explicit generic command:

```yaml
run:
  title: "Extract URL snippets"
  scope: tool
  command: "@web-fetch:/bin/web-fetch"
  args: ["readable", "<url>", "--pattern", "regex", "--context-chars", "300"]
```

## Search

Search discovers candidate URLs, then the Agent fetches selected pages with URL modes.

CLI argument grammar for array `args`:

```text
search <query> [--engine NAME] [--engines a,b] [--limit N] [--search-mode request|auto|playwright] [--proxy-url URL] [--timeout SEC] --json
```

`search` is separate from URL fetch and emits a JSON envelope.

## Examples

```yaml
# Default URL extraction
- run:
    title: "Extract example page"
    scope: tool
    command: "@web-fetch:/bin/web-fetch"
    args: ["auto", "https://example.com", "--format", "markdown"]
# Raw HTML inline
- run:
    title: "Fetch raw example HTML"
    scope: tool
    command: "@web-fetch:/bin/web-fetch"
    args: ["direct", "https://example.com", "--format", "raw"]
# Save raw bytes
- run:
    title: "Download example bytes"
    scope: tool
    command: "@web-fetch:/bin/web-fetch"
    args: ["direct", "https://example.com/file.bin", "--format", "raw", "--output", "/tmp/file.bin"]
# Regex extraction after Markdown conversion
- run:
    title: "Extract article version snippets"
    scope: tool
    command: "@web-fetch:/bin/web-fetch"
    args: ["readable", "https://example.com/article", "--format", "markdown", "--pattern", "Version [0-9.]+", "--context-chars", "120"]
# Search
- run:
    title: "Search Neovim Lua API"
    scope: tool
    command: "@web-fetch:/bin/web-fetch"
    args: ["search", "neovim lua api", "--engines", "duckduckgo,bing", "--limit", "10", "--json"]
```

## Error Handling

- Binary `raw` inline fails; use `--format markdown` to identify/convert, or `--format raw --output <path>` to save.
- Markdown conversion failures preserve `uvx markitdown` stderr and suggest raw file output.
- Existing output files fail unless `--overwrite` is provided.
- `browser`/`stealth` dependency failures must be reported; downgrade manually to `direct`/`readable` when appropriate.
- Legacy URL command names are invalid public subcommands; follow help output and use functional commands above.

## Validation

Maintainer-only test commands, not cataloged operational entrypoints. Resolve `<ability_root>` from the loaded package before using this explicit shell exception:

```bash
uv run --project <ability_root> python <ability_root>/tests/test_auto_router.py
uv run --project <ability_root> python <ability_root>/tests/test_output_model_cli.py
uv run --project <ability_root> python <ability_root>/tests/smoke_cli.py
```

