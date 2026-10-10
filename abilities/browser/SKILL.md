---
name: browser
description: "Control supported Chromium/CDP browsers, managed browser backends, and Tauri WebViews for page observation, interaction, screenshots, state/network inspection, and Tauri IPC debugging."
compatibility: Requires Maxa Ability runtime.
---
# Browser

Purpose: connect, observe, and operate supported browser pages through the same-named `browser` MCP source.

Prerequisite: `load(target="browser")` authorizes this Chat and supplies the committed tool/reference catalog. Invoke cataloged tools through titled `run(scope="tool", command="@browser:<tool>", args=<encoded JSON object string>)`. Read references through exact `#browser[/references/...]` addresses. Resolve executable/profile/output parameters to physical paths before calling.

## Scenario Router

Choose the applicable reference before connection; then read `#browser[/references/operations.md]` for page operations.

| Target / need | Read address | Entry |
| --- | --- | --- |
| Tauri desktop app | `#browser[/references/tauri-app.md]` | `tauri_connect`; optional Tauri IPC |
| Existing Chrome/Edge/Chromium CDP | `#browser[/references/browser.md]` | `cdp_connect`; inspect/select existing tabs |
| Managed backend | `#browser[/references/browser-backends.md]` | `browser_start/status/stop` |
| Connected page | `#browser[/references/operations.md]` | snapshot, interaction, navigation, state, network, diff |
| Missing standard backend dependency | `#browser[/references/setup/obscura-setup.md]` | setup only after a dependency failure or explicit request |
| Missing real-browser backend dependency | `#browser[/references/setup/protected-browser-setup.md]` | setup only after a dependency failure or explicit request |
| Server/Ability maintenance | `#browser[/references/development/server-dev.md]` | implementation owners and extension contracts |

- UI/visual verification requires real Chromium/CDP or an actual Tauri WebView. `standard`/Obscura executes JS but does not supply real layout/paint; `auto` currently selects `standard`.
- Search, URL fetch, and body extraction retain `web-fetch` routing. Use this Ability when actual page interaction, browser state, CDP access, or real rendering is needed.
- For an exploratory QA report, load independent `browser-dogfood`; for authorized automated test authoring/maintenance, load independent `browser-e2e`. Ordinary page operation does not automatically require either deliverable.
- Stop dependent actions at interactive CAPTCHA, login, paywall, or permission walls; report the limitation. Follow active authorization rules for destructive actions.

## Tool Surface

Live schemas own exact parameters and defaults; names below are labels, not bare builtins.

| Category | Tools |
| --- | --- |
| Connection | `tauri_connect/disconnect`, `browser_start/status/stop`, `cdp_connect/disconnect` |
| Observation / diff | `snapshot`, `screenshot`, `content`, `url`, `title`, `diff_snapshot`, `diff_screenshot`, `diff_url` |
| Interaction / locators | `click`, `fill`, `type`, `press`, `select`, `check/uncheck`, `getbyrole/text/label/testid/placeholder`, `nth` |
| Navigation / waits | `navigate`, `reload`, `wait`, `waitforurl`, `waitforloadstate`, `waitforfunction` |
| Tabs / input | `tab_list/new/switch/close`, `input_mouse/keyboard/touch` |
| State / network | `state_*`, `cookies_*`, `storage_*`, `route`, `requests`, `responsebody`, `headers` |
| Debug / environment | `evaluate`, `console`, `errors`, `viewport`, `emulatemedia`, `clipboard`, `trace_*`, `har_*`, `screencast_*` |
| Tauri only | `tauri_invoke`, `tauri_listen`, `tauri_emit`, `tauri_app_info` |

## Ref And Evidence Lifecycle

Snapshot refs such as `@e1` describe current page structure. Take a new snapshot after navigation, form submission, dynamic UI changes, or tab switching before reusing refs.

```yaml
- run: {title: "Observe page", scope: tool, command: "@browser:snapshot", args: '{"interactive":true}'}
- run: {title: "Act on observed element", scope: tool, command: "@browser:click", args: '{"selector":"@e2"}'}
- run: {title: "Inspect DOM difference", scope: tool, command: "@browser:diff_snapshot", args: '{}'}
- run: {title: "Refresh references", scope: tool, command: "@browser:snapshot", args: '{"interactive":true}'}
```

For visual comparison, capture a real-rendering `screenshot` baseline, perform the action, then use `diff_screenshot` with that physical baseline path. Keep actual observation distinct from static checks.

## Cleanup And Migration

- Existing CDP: `cdp_disconnect` detaches without stopping the external process.
- Managed backend: `browser_stop` stops owned backend resources; detach any remaining connection with `cdp_disconnect`.
- Tauri: `tauri_disconnect` stops only a process launched by this session, not a reused application.
- Public identities moved from `tauri-playwright`, `tauri-dogfood`, and `tauri-e2e` to `browser`, `browser-dogfood`, and `browser-e2e`. No old Ability/MCP forwarding aliases exist. Migrate project MCP source overrides to `browser`, executable paths to `mcp-servers/browser/index.js`, and helper imports to the new package root. Existing Chats loaded with old revisions must retire their old revision context or start a fresh Chat before loading new identities; historical results need not be rewritten.
