# Common Operations

Purpose: shared page-operation handbook after connecting a Tauri app, real browser CDP target, or managed browser backend.

Prerequisite: `load(target="browser")`. First read one scenario with `read`/`load` and complete its connection flow:

- Tauri app: `#browser[/references/tauri-app.md]`.
- Real Chrome/Edge/Chromium CDP: `#browser[/references/browser.md]`.
- Managed standard/protected backend: `#browser[/references/browser-backends.md]`.

Examples invoke cataloged MCP targets through titled `run(scope="tool")` with encoded JSON object `args`; bare tool names in tables are labels. State files, screenshots, and other output paths remain physical paths.

## Flow

```text
connect target or start backend
-> observe page
-> locate element
-> interact / execute JS / inspect network or state
-> validate result / save evidence
-> cleanup by scenario
```

## Observe Page

| Purpose | Tools |
| --- | --- |
| Interactive elements and refs | `snapshot` |
| Screenshot | `screenshot` |
| HTML | `content` |
| Current URL/title | `url`, `title` |
| Element text/HTML/attribute | `gettext`, `innertext`, `innerhtml`, `getattribute` |

Backend differences: `standard`/Obscura has no real layout/paint. Do not rely on it for `screenshot`, PDF, pixel evidence, or complex actionability. Prefer `evaluate`, `content`, and `requests` for DOM/network facts. Switch to `protected` or real browser CDP when the task requires real rendering, screenshots, or full Playwright behavior.

Examples:

```yaml
- run: {title: "Inspect interactive page", scope: tool, command: "@browser:snapshot", args: '{"interactive":true}'}
- run: {title: "Capture complete page", scope: tool, command: "@browser:screenshot", args: '{"fullPage":true}'}
```

## Locator And Ref Lifecycle

`snapshot` refs such as `@e1` are valid only for the current page structure.

Re-run `snapshot` after:

- `navigate`, route change, form submit;
- click that changes page or opens dynamic UI;
- modal, dropdown, async list load;
- `tab_switch`.

Locator priority for real Chromium/Tauri WebView:

| Priority | Method | Example |
| --- | --- | --- |
| 1 | Ref | `@e5` |
| 2 | Role | `getbyrole` |
| 3 | Test ID | `getbytestid` |
| 4 | Label/Text | `getbylabel`, `getbytext` |
| 5 | CSS | `.submit-button` |

In `standard`/Obscura, prefer CSS + `evaluate` for complex pages; locator timeout does not prove page access failed.

## Interact

| Purpose | Tools |
| --- | --- |
| Click | `click`, `dblclick` |
| Text input | `fill`, `type`, `clear` |
| Selection | `select`, `multiselect` |
| Checkbox/radio | `check`, `uncheck` |
| Keyboard | `press`, `keyboard`, `keydown`, `keyup` |
| Mouse | `hover`, `drag`, `wheel`, `mousemove` |
| Low-level input | `input_mouse`, `input_keyboard`, `input_touch` |

Examples:

```yaml
- run: {title: "Fill observed email field", scope: tool, command: "@browser:fill", args: '{"selector":"@e3","value":"hello@example.com"}'}
- run: {title: "Submit observed form", scope: tool, command: "@browser:click", args: '{"selector":"@e10"}'}
```

If an operation can change page structure, re-run `snapshot` before using refs again.

## Navigate And Wait

| Purpose | Tools |
| --- | --- |
| Navigate | `navigate` |
| Back/forward/reload | `back`, `forward`, `reload` |
| Wait element | `wait` |
| Wait URL | `waitforurl` |
| Wait load state | `waitforloadstate` |
| Wait JS condition | `waitforfunction` |

```yaml
run:
  title: "Navigate to example page"
  scope: tool
  command: "@browser:navigate"
  args: '{"url":"https://example.com","waitUntil":"domcontentloaded","timeout":30000}'
```

```yaml
run:
  title: "Wait for page content"
  scope: tool
  command: "@browser:waitforfunction"
  args: '{"expression":"document.body && document.body.innerText.length > 100","timeout":15000}'
```

## JavaScript And Content Extraction

| Purpose | Tools |
| --- | --- |
| Execute JS | `evaluate` |
| Get HTML | `content` |
| Inject script/style | `addscript`, `addstyle`, `addinitscript` |

```yaml
- run: {title: "Read rendered body text", scope: tool, command: "@browser:evaluate", args: '{"script":"document.body ? document.body.innerText : ''''"}'}
- run: {title: "Read article content", scope: tool, command: "@browser:content", args: '{"selector":"article"}'}
```

## Network, Cookies, Storage, State

| Purpose | Tools |
| --- | --- |
| Requests/response body | `requests`, `responsebody` |
| Intercept requests | `route`, `unroute` |
| Headers | `headers` |
| Cookies | `cookies_get`, `cookies_set`, `cookies_clear` |
| Storage | `storage_get`, `storage_set`, `storage_clear` |
| State | `state_save`, `state_load`, `state_list`, `state_show`, `state_clear` |

```yaml
- run: {title: "Inspect API requests", scope: tool, command: "@browser:requests", args: '{"filter":"/api/"}'}
- run: {title: "Save browser session state", scope: tool, command: "@browser:state_save", args: '{"path":"/tmp/session-state.json"}'}
```

Tauri CDP may limit state restore; read `#browser[/references/tauri-app.md]` with `read`/`load`. `standard`/Obscura is useful for request/response and JS extraction. Use `protected` or real browser CDP for download dialogs, file choosers, or true rendering.

## Tabs And Windows

| Purpose | Tools |
| --- | --- |
| List pages | `tab_list` |
| New tab | `tab_new` |
| Switch | `tab_switch` |
| Close | `tab_close` |
| Bring to front | `bringtofront` |

Tauri windows come from the app; create them through app behavior/Tauri command, then use `tab_list/tab_switch`. Do not use browser `window_new` as a Tauri window API.

## Diff And Evidence

| Purpose | Tools |
| --- | --- |
| DOM diff | `diff_snapshot` |
| Screenshot diff | `diff_screenshot` |
| URL diff | `diff_url` |
| Console/page errors | `console`, `errors` |
| Trace/HAR/Screencast | `trace_*`, `har_*`, `screencast_*` |
| Profiler | `profiler_*` |

```yaml
- run: {title: "Capture DOM baseline", scope: tool, command: "@browser:snapshot", args: '{"interactive":true}'}
- run: {title: "Perform observed action", scope: tool, command: "@browser:click", args: '{"selector":"@e2"}'}
- run: {title: "Inspect DOM change", scope: tool, command: "@browser:diff_snapshot", args: '{}'}
```

## Cleanup

Use scenario-specific cleanup:

- Tauri app: `tauri_disconnect`.
- Managed browser backend: `browser_stop`.
- External real browser CDP: `cdp_disconnect`.

Do not use `tauri_disconnect` for browser backends. Do not use `browser_stop` to close user-started external browsers.
