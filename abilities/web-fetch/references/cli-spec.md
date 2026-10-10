# Web Fetch Unified CLI Contract

Purpose: define the argument/output contract behind the cataloged `@web-fetch:/bin/web-fetch` entrypoint. Agents first `load(target="web-fetch")`, then use titled `run(scope="tool")` with literal array `args`; do not execute these reference signatures as Shell commands. The `web-fetch ...` blocks below document CLI grammar and diagnostic text for maintainers, not an alternate Agent invocation path.

```yaml
run:
  title: "Extract example web page"
  scope: tool
  command: "@web-fetch:/bin/web-fetch"
  args: ["auto", "https://example.com", "--format", "markdown"]
```

URL modes are named by function; shared options control content format/output. Former source-named URL commands are not public subcommands.

## URL Fetch Commands

```bash
web-fetch auto <url> [shared-options]
web-fetch direct <url> [shared-options]
web-fetch readable <url> [shared-options]
web-fetch browser <url> [shared-options]
web-fetch stealth <url> [shared-options]
```

| Command | Use | Internal strategy |
| --- | --- | --- |
| `auto` | Default known-URL entry | special route -> direct -> readable -> browser -> stealth |
| `direct` | HTTP(S) direct access/download | requests/static HTTP |
| `readable` | readable body/container extraction | open-websearch `fetchWebContent` capability |
| `browser` | JS/browser environment page | scrapling browser strategy |
| `stealth` | stronger anti-bot page | scrapling max-stealth/highest-intensity strategy |

Shared options:

| Option | Default | Meaning |
| --- | --- | --- |
| `<url>` | required | HTTP(S) URL |
| `--format raw|markdown` | `markdown` | `raw` emits fetched artifact; `markdown` converts through `uvx markitdown` |
| `--output <path>` | unset | write file; unset means inline stdout |
| `--overwrite` | false | allow replacing an existing output file |
| `--max-bytes <N>` | 2097152 | maximum read/content bytes |
| `--timeout <seconds>` | 30; browser/stealth 60 | fetch/render timeout |
| `--proxy-url <url>` | unset | per-call proxy URL |
| `--pattern <regex>` | unset | regex context extraction on final formatted text |
| `--context-chars <N>` | 200 | context chars around each regex match |
| `--no-special-route` | false | `auto` only: disable special routes |

Fixed processing order:

```text
fetch -> --format final text -> --pattern post-process -> inline/file output
```

## Output Semantics

URL fetch success is not JSON:

| Shape | stdout |
| --- | --- |
| inline, no `--output` | final content only |
| file, with `--output` | `Wrote <path>` |

Failure semantics:

- Non-zero exit.
- stderr preserves real error and necessary suggestion.
- Common prefixes: `[access]`, `[convert]`, `[output]`, `[route]`, `[pattern]`.

Required diagnostics:

- Binary `raw` inline: suggest `--format markdown` and `--format raw --output <path>`.
- `markitdown` conversion failure: preserve raw stderr; suggest `--format raw --output <path>`.
- Existing file: suggest `--overwrite` or a new path.
- Browser/stealth dependency missing: report dependency problem; do not present static fallback as browser/stealth success.

## Pattern Post-Processing

`--pattern` is a shared URL-fetch option, not a standalone subcommand.

```bash
web-fetch auto <url> --no-special-route --pattern "regex"
web-fetch direct <url> --format raw --pattern "regex"
web-fetch readable <url> --format markdown --pattern "regex" --context-chars 300
web-fetch browser <url> --pattern "regex"
web-fetch stealth <url> --pattern "regex"
```

Rules:

- Regex runs on final text after `--format`.
- Each match returns surrounding `--context-chars` characters.
- Overlapping/adjacent contexts merge.
- Multiple contexts are separated by blank line, `---`, blank line.
- No match returns non-zero; stderr starts with `[pattern] no matches`.
- Invalid regex returns argument error and preserves underlying regex error.
- Raw binary content does not support pattern; use `--format markdown` or save raw file.

## Auto Special Routes

`auto` enables internal special routes by default:

| URL type | Internal route |
| --- | --- |
| GitHub repository URL | `github-readme` |
| CSDN article URL | `csdn` |
| Juejin article URL | `juejin` |
| Linux.do topic/article URL | `linuxdo` |

Special routes are not public CLI subcommands. Disable them with:

```bash
web-fetch auto <url> --no-special-route --format markdown
```

Special route plus `--pattern` must fail directly, with no implicit fallback. stderr example:

```text
[route] This URL uses special route: github-readme.
[pattern] --pattern is not supported for special routes.
Suggestion: use --no-special-route or an explicit generic command such as `web-fetch readable <url> --pattern ...`.
```

## Search

`search` is separate from URL fetch and emits a JSON envelope:

```bash
web-fetch search <query> [--engine NAME] [--engines a,b] [--limit N] [--search-mode request|auto|playwright] [--proxy-url URL] [--timeout SEC] [--json]
```

`search` does not support URL fetch shared options such as `--format`, `--output`, or `--pattern`.

## Legacy Entry Cleanup

Only functional entries remain public: `auto`, `direct`, `readable`, `browser`, `stealth`, and `search`.

| Old capability | New usage |
| --- | --- |
| static access / raw save | `web-fetch direct <url> --format raw|markdown` |
| generic readable body | `web-fetch readable <url>` |
| browser-rendered fetch | `web-fetch browser <url>` |
| strong anti-bot fetch | `web-fetch stealth <url>` |
| regex snippet extraction | add `--pattern` to `auto/direct/readable/browser/stealth` |
| site-specific fetch | `web-fetch auto <url>` internal special route |
| search | `web-fetch search <query>` |

## Ability Resource Exposure

`ABILITY.yaml` excludes `scripts/`, `tests/`, and `vendor/`, but not `bin/`. The `load` script catalog must expose `/bin/web-fetch`. Read guides through cataloged `#web-fetch[/references/...]` addresses; `load` injects `SKILL.md`. Inspect filesystem implementation files only for explicit maintenance/debugging, not normal capability use.

## Validation Commands

Maintainer-only shell exception for tests excluded from the public catalog. Resolve `<ability_root>` from the loaded package:

```bash
uv run --project <ability_root> python <ability_root>/tests/test_auto_router.py
uv run --project <ability_root> python <ability_root>/tests/test_output_model_cli.py
uv run --project <ability_root> python <ability_root>/tests/smoke_cli.py
```
