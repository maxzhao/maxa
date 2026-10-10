# Managed Browser Backend Scenario

Purpose: choose and start a managed browser backend with `browser_start/status/stop`. Covers `standard`, `protected`, `auto`, lifecycle, warmup, proxy, and security-check handling.

Prerequisite: `load(target="browser")`; invoke MCP targets through titled `run(scope="tool")` with encoded JSON object `args` as shown below. After backend readiness, read `#browser[/references/operations.md]` with `read`/`load`. Executable, profile, and storage parameters remain physical paths.

## Workflow

```text
browser_start(mode=standard|protected|auto)
-> browser_status confirms ready
-> read(path="#browser[/references/operations.md]") and operate
-> browser_stop
```

## Mode Selection

| mode | Use |
| --- | --- |
| `standard` | Normal dynamic pages, JavaScript execution, DOM/network extraction. |
| `protected` | Cloudflare/bot-check pages or need for real Chromium behavior. |
| `auto` | Currently equivalent to `standard`; switch to `protected` when security check or real rendering need is proven. |

`standard` currently uses Obscura. It is good for lightweight fetching, JS execution, links, and request extraction. It does not provide real layout/paint. Use `protected` or real browser CDP for screenshots, PDF, visual evidence, complex Playwright locator/actionability, or pixel-level behavior.

## Start Examples

Standard dynamic page with proxy:

```yaml
run:
  title: "Start standard browser backend"
  scope: tool
  command: "@browser:browser_start"
  args: '{"mode":"standard","proxy":"socks5://127.0.0.1:10808"}'
```

Warmup and persistent state:

```yaml
run:
  title: "Start warmed browser state"
  scope: tool
  command: "@browser:browser_start"
  args: '{"mode":"standard","proxy":"socks5://127.0.0.1:10808","warmupUrl":"https://example.com","warmupWaitText":"Example","storageDir":"/tmp/example-browser-state"}'
```

Protected page:

```yaml
run:
  title: "Start protected browser backend"
  scope: tool
  command: "@browser:browser_start"
  args: '{"mode":"protected","proxy":"socks5://127.0.0.1:10808","warmupUrl":"https://www.fab.com"}'
```

After startup, select operations by backend capability: `evaluate`, `content`, `requests`, `snapshot`, `screenshot`, etc.

Cleanup:

```yaml
run: {title: "Stop managed browser backend", scope: tool, command: "@browser:browser_stop", args: '{}'}
```

## Status Contract

`browser_start` / `browser_status` return fact state, not next-step instructions.

| status | Meaning |
| --- | --- |
| `ready` | Backend started, CDP ready, browser tools connected. |
| `started` | Backend started but browser tools not connected; usually `connect=false`. |
| `not_started` | No managed backend in current session. |
| `not_ready` | Endpoint does not answer CDP. |
| `disconnected` | Managed process still runs but browser tools are disconnected. |
| `process_exited` | Managed process exited. |

## Security Check Handling

Likely security-check content:

- `One more step`
- `Please complete a security check to continue`
- `Enable JavaScript and cookies to continue`
- `Just a moment`
- same-origin API returns `403 text/html`

Rules:

1. If current mode is `standard`, call `browser_stop`, then retry with `protected` and site homepage as `warmupUrl`.
2. If `protected` still hits interactive CAPTCHA, hCaptcha, interactive Turnstile, login, paywall, or permission wall, stop and report the site limitation.
3. Do not repeatedly retry with identical parameters.

## Boundaries

- No CAPTCHA solver.
- No guarantee of passing interactive verification.
- Do not bypass login, paywall, or permission wall.
- `protected` is heavier; use only after `standard` is blocked by security checks or the task requires real Chromium rendering/screenshots/full Playwright behavior.

## Setup Entry Points

Read setup docs only when `browser_start(mode="standard" | "protected")` reports missing dependency, missing executable, Chrome/ChromeDriver mismatch, or the user explicitly asks to prepare a new environment.

Use `read`/`load` with the matching cataloged address:

- Standard backend install and CDP verification: `#browser[/references/setup/obscura-setup.md]`.
- Protected backend setup: `#browser[/references/setup/protected-browser-setup.md]`.

Implementation details, tool registration, and MCP server development belong to `#browser[/references/development/server-dev.md]` (read with `read`/`load`), not daily browser access.
