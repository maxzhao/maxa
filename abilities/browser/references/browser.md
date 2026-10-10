# Real Browser CDP Scenario

Purpose: control a real installed Chrome, Edge, or Chromium browser through Chrome DevTools Protocol (CDP). Use this when the user wants an existing/local browser profile, login state, extensions, or manually opened pages.

Prerequisite: `load(target="browser")`; invoke MCP targets through titled `run(scope="tool")` with encoded JSON object `args` as shown below. After `cdp_connect`, read `#browser[/references/operations.md]` with `read`/`load`.

## Use This When

- User mentions an already opened Chrome/Edge/Chromium.
- User wants Agent to take over a real local browser instead of a managed backend.
- User provides a CDP endpoint, remote debugging port, `9222`, `9223`, or `9333`.
- User needs a real profile, login state, extension, or manually opened page.

Do not use for:

Read the matching reference with `read`/`load` instead:

- Tauri app testing -> `#browser[/references/tauri-app.md]`.
- Managed `standard`/`protected` backend -> `#browser[/references/browser-backends.md]`.
- Post-connection page operations -> `#browser[/references/operations.md]`.

## Workflow

```text
confirm real installed browser target
-> check supplied/common CDP endpoint
-> if missing, guide user to start browser with --remote-debugging-port
-> cdp_connect
-> tab_list / tab_switch
-> read(path="#browser[/references/operations.md]") and operate
-> cdp_disconnect
```

## Find Existing CDP Endpoint

Check supplied endpoint/port first, then common ports:

```text
9222
9223
9333
```

Probe:

```text
http://127.0.0.1:<port>/json/version
http://127.0.0.1:<port>/json/list
```

Valid `/json/version` usually includes:

```json
{
  "Browser": "Chrome/...",
  "Protocol-Version": "1.3",
  "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/browser/..."
}
```

Connect:

```yaml
run:
  title: "Connect browser CDP endpoint"
  scope: tool
  command: "@browser:cdp_connect"
  args: '{"endpoint":"http://127.0.0.1:9222"}'
```

or:

```yaml
run:
  title: "Connect browser CDP host"
  scope: tool
  command: "@browser:cdp_connect"
  args: '{"host":"127.0.0.1","port":9222}'
```

Default `bootstrap: true` may navigate a blank initial page to a safe bootstrap URL. Even `bootstrap: false` can initialize a blank page during BrowserManager attachment; it is not a no-navigation guarantee. Nonblank pages are preserved by the existing connection setup. Confirm target authorization before attaching.

Then inspect/select pages:

```yaml
- run: {title: "List browser pages", scope: tool, command: "@browser:tab_list", args: '{}'}
- run: {title: "Select observed browser page", scope: tool, command: "@browser:tab_switch", args: '{"index":1}'}
```

## Guide User To Start Browser With CDP

If no endpoint exists, do not close the user's current browser without confirmation. Prefer a separate profile with `--user-data-dir` so the CDP flag takes effect and daily profiles are not polluted.

The commands below are manual browser/platform setup, not cataloged Ability scripts. Paths are real executables and profile directories. When an Agent launches a Windows GUI from WSL, use `run(scope="win", opts='{"detach":true}')` under the Windows command protocol rather than running PowerShell directly in WSL.

Chrome/Chromium Linux/WSL:

```bash
google-chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/browser-chrome-profile
```

```bash
chromium \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/browser-chromium-profile
```

Chrome Windows:

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --remote-debugging-port=9222 `
  --user-data-dir="$env:TEMP\browser-chrome-profile"
```

Edge Windows:

```powershell
& "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" `
  --remote-debugging-port=9222 `
  --user-data-dir="$env:TEMP\browser-edge-profile"
```

Edge Linux:

```bash
microsoft-edge \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/browser-edge-profile
```

Optional flags:

```bash
--proxy-server=socks5://127.0.0.1:10808
--remote-allow-origins=*
```

## Verify Connection

After startup:

```text
http://127.0.0.1:9222/json/version
http://127.0.0.1:9222/json/list
```

Then:

```yaml
- run: {title: "Connect browser CDP", scope: tool, command: "@browser:cdp_connect", args: '{"endpoint":"http://127.0.0.1:9222"}'}
- run: {title: "List connected browser pages", scope: tool, command: "@browser:tab_list", args: '{}'}
- run: {title: "Read connected page title", scope: tool, command: "@browser:title", args: '{}'}
- run: {title: "Read connected page URL", scope: tool, command: "@browser:url", args: '{}'}
```

## Page Operations

Use `read(path="#browser[/references/operations.md]")` for:

- `snapshot`, `screenshot`, `content`
- `click`, `fill`, `press`
- `navigate`, `waitforloadstate`, `waitforfunction`
- `evaluate`
- `requests`, `responsebody`, `cookies_*`, `storage_*`
- `diff_snapshot`, `diff_screenshot`

## Cleanup

Real browsers are user/external processes. End by disconnecting the MCP tool only:

```yaml
run: {title: "Disconnect external browser CDP", scope: tool, command: "@browser:cdp_disconnect", args: '{}'}
```

Do not use `browser_stop` to close a user-started real browser. Do not use `tauri_disconnect` for real browser CDP.
