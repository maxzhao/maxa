# Browser MCP Server Development

Purpose: maintain or extend the `browser` MCP Server. Do not read for ordinary app/browser operation.

For Agent MCP invocation, first use `load(target="browser")`, then titled `run(scope="tool", command="@browser:<tool>", args=<encoded JSON object string>)` with a cataloged target. Load package handbooks through `read`/`load`, for example `read(path="#browser[/references/operations.md]")`.

This document is a source-maintenance exception: JavaScript snippets describe implementation or direct test APIs, and shell commands are maintainer diagnostics/build steps, not callable Ability scripts. `index.js`, `lib/*`, and dependency source paths are physical paths in the inspected MCP server or dependency checkout. Resolve those checkouts before running maintenance commands; do not turn implementation functions or example new tools into `@` addresses until they exist in the loaded catalog.

## Architecture

`browser` wraps `agent-browser` behind MCP, sharing operation tools across managed backends, external Chromium/CDP, and Tauri WebView2.

```text
index.js                         MCP server entry
├── lib/session.js               TauriSession: app launch + CDP connection lifecycle
├── lib/bridge.js                dispatch(): MCP params -> agent-browser command -> MCP response
├── lib/tool-registry.js         registerAllTools(): agent-browser tool registration
├── lib/tools/tauri.js           Tauri-specific invoke/emit/listen/app info tools
├── lib/test-helper.js           BrowserTest / compatible TauriTest E2E helper
└── lib/errors.js                formatError/formatSuccess response helpers

external:
├── agent-browser/dist/browser.js   BrowserManager
├── agent-browser/dist/actions.js   executeCommand()
├── @modelcontextprotocol/sdk       McpServer + StdioServerTransport
└── zod                             input schemas
```

Startup:

```text
node index.js
-> create TauriSession
-> create McpServer
-> register tauri_connect / tauri_disconnect
-> registerAllTools() from lib/tool-registry.js
-> registerTauriTools() from lib/tools/tauri.js
-> connect StdioServerTransport
```

Tool module imports are wrapped so missing optional modules do not block server startup.

## Request Data Flow

```text
MCP tool call
-> session.connected check
-> bridge.dispatch(action, params, browser)
   -> block CDP_FATAL_ACTIONS
   -> special-case clipboard timeout/recovery
   -> special-case REF_BROKEN_ACTIONS
   -> executeCommand({ id, action, ...params }, browser)
-> formatSuccess(data) or formatError(action, err)
```

## Bridge Contract (`lib/bridge.js`)

Core shape:

```javascript
export async function dispatch(action, params, browser) {
  if (CDP_FATAL_ACTIONS.has(action)) {
    return formatError(action, `Not supported in Tauri CDP mode...`);
  }
  if (action === "clipboard") return handleClipboard(params, browser);
  if (REF_BROKEN_ACTIONS.has(action) && browser.isRef(params.selector)) {
    return handleRefBrokenAction(action, params, browser);
  }
  const command = { id: randomUUID(), action, ...params };
  const response = await executeCommand(command, browser);
  return response.success
    ? formatSuccess(response.data)
    : formatError(action, response.error);
}
```

Special cases:

| Set/action | Reason | Handling |
| --- | --- | --- |
| `CDP_FATAL_ACTIONS` | `browser.newContext()` breaks CDP connection | return error with alternative |
| `REF_BROKEN_ACTIONS` | agent-browser uses `page.locator()` instead of `browser.getLocator()` | resolve ref through `browser.getLocator()` |
| clipboard `read` | WebView2 permission dialog may hang | `Promise.race` timeout, detect permission URL, recover |

Fatal actions currently include `window_new`, `recording_start`, `recording_stop`, `recording_restart`. Use Tauri/app windows + `tab_switch`, or `trace_*` / `screencast_*` alternatives.

Add bridge interception only when parameter conversion, timeout protection, or CDP-specific behavior is required:

```javascript
const MY_SPECIAL_ACTIONS = new Set(["my_action"]);

if (MY_SPECIAL_ACTIONS.has(action)) {
  return await handleMyAction(params, browser);
}

async function handleMyAction(params, browser) {
  const page = browser.getPage();
  return formatSuccess({ done: true });
}
```

## Session Contract (`lib/session.js`)

`TauriSession` owns Tauri app lifecycle.

Key rules:

- `connect()` first probes CDP port. If ready, reuse existing app and keep `processId = null`.
- Launch GUI apps from WSL through `runwingui --env ... --detach`, not direct PowerShell.
- Save `processId` only for processes started by this session; `disconnect()` kills only owned processes.
- Recreate `BrowserManager` on each `connect()` to avoid leaked state.
- Call `initActionPolicy()` before `browser.launch()`.
- `browser.launch({ cdpPort, headless: false })` must connect over CDP, not launch a new browser.
- WebView2 CDP is enabled by environment: `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222`.

Connection flow:

```text
connect({ app_path, port, args, timeout })
-> _isCDPReady(port)
   -> ready: reuse existing instance
   -> not ready: _launchApp(appPath, port, extraArgs)
-> _waitForCDP(port, timeout)
-> browser = new BrowserManager()
-> initActionPolicy()
-> browser.launch({ cdpPort: port, headless: false })
```

## Tool Registry Contract (`lib/tool-registry.js`)

Agent-browser tools are centralized in `buildToolDefinitions(z)`.

Definition shape:

```javascript
{
  name: "click",
  action: "click",
  description: "Click...",
  inputSchema: {
    selector: z.string().describe("..."),
    button: z.enum(["left", "right", "middle"]).optional(),
  },
}
```

Rules:

- `inputSchema` is a bare Zod shape object, not `z.object({...})`.
- Do not include `id` or `action` in `inputSchema`; bridge adds them.
- Follow `agent-browser/src/protocol.ts` for schema shape.
- `registerAllTools(server, session, z)` iterates definitions and wraps each with `session.connected` check + `dispatch()`.

Add an agent-browser bridge tool by appending one definition to `buildToolDefinitions()`; no other file is needed unless bridge special handling is required.

## Tauri Tools (`lib/tools/tauri.js`)

Tauri tools execute `page.evaluate()` against Tauri JS APIs.

Pattern:

```javascript
server.tool("tauri_xxx", "description", { /* zod shape */ }, async (params) => {
  try {
    ensureConnected();
    const page = session.browser.getPage();
    const result = await page.evaluate(async (args) => {
      const api = window.__TAURI__?.module?.method;
      if (!api) throw new Error("Tauri API not available");
      return await api(...);
    }, params);
    return formatSuccess(result);
  } catch (err) {
    return formatError("tauri_xxx", err);
  }
});
```

API compatibility paths:

| API | Primary | Fallback |
| --- | --- | --- |
| invoke | `window.__TAURI__.core.invoke` | `window.__TAURI_INTERNALS__.invoke` |
| emit | `window.__TAURI__.event.emit` | `window.__TAURI_INTERNALS__.emit` |
| once | `window.__TAURI__.event.once` | `window.__TAURI_INTERNALS__.once` |
| app info | `window.__TAURI__.app.*` | `window.__TAURI__.core.invoke("plugin:app|...")` |

Prerequisite: app `tauri.conf.json` must enable `withGlobalTauri: true`.

`tauri_invoke` uses `Promise.race` timeout; default 10s, override by `timeout` param.

## BrowserTest Helper (`lib/test-helper.js`)

`BrowserTest` and compatible `TauriTest` share one E2E implementation calling `TauriSession` + `dispatch()` directly, bypassing MCP JSON-RPC. Generic entries are `startBrowser(options)` and `connectCDP(options)`; existing `start(appPath, opts)` remains Tauri-specific. `stop()` releases managed runtime, residual Obscura, and connection/owned Tauri resources, including partial-start failures. Keep API/setup examples in the independent `browser-e2e` Ability.

Example API:

```javascript
const app = new TauriTest();
await app.start("C:\\path\\to\\app.exe", { port: 9222 });
await app.click("@e1");
await app.fill("@e2", "hello");
const text = await app.getText(".message");
const result = await app.invoke("greet", { name: "World" });
await app.stop();
```

Differences from MCP tools:

| Aspect | MCP tool | TauriTest |
| --- | --- | --- |
| Protocol | stdin/stdout MCP JSON-RPC | direct function call |
| Response | MCP content envelope | parsed data |
| Error | `{ isError: true }` | thrown Error |
| Tauri IPC | MCP tool through page context | direct helper method |

Vitest guidance: use `pool: "forks"` and `singleFork: true` when sharing one Tauri instance.

## Response Helpers (`lib/errors.js`)

```javascript
formatError("action_name", error);
// -> { content: [{ type: "text", text: JSON.stringify({...}) }], isError: true }

formatSuccess(data);
// -> { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] }
```

All tools should use try/catch + `formatError("tool_name", err)`.

## Add New Tools

### A. Agent-browser bridge tool

Add to `buildToolDefinitions()`:

```javascript
{
  name: "my_new_tool",
  action: "agent_browser_action",
  description: "Description for LLM",
  inputSchema: {
    param1: z.string().describe("Parameter description"),
    param2: z.number().optional().describe("Optional param"),
  },
}
```

### B. Custom MCP tool

Create `lib/tools/my_feature.js`:

```javascript
import { formatError, formatSuccess } from "../errors.js";

export function registerMyFeatureTools(server, session, z) {
  function ensureConnected() {
    if (!session.connected) throw new Error("Not connected");
  }

  server.tool("my_custom_tool", "Description for LLM", {
    param1: z.string().describe("..."),
  }, async (params) => {
    try {
      ensureConnected();
      const page = session.browser.getPage();
      const result = await page.evaluate((args) => document.title, params);
      return formatSuccess({ result });
    } catch (err) {
      return formatError("my_custom_tool", err);
    }
  });
}
```

Register in `index.js` after Tauri tools:

```javascript
try {
  const { registerMyFeatureTools } = await import("./lib/tools/my_feature.js");
  registerMyFeatureTools(server, session, z);
} catch {
  // optional module absent
}
```

### C. Tool requiring bridge interception

Use when special CDP handling, retry, timeout, or parameter transformation is needed. Add set + handler in `lib/bridge.js` before default `executeCommand()` path.

## Key Implementation Notes

- CDP connection uses `chromium.connectOverCDP("http://localhost:<port>")` through agent-browser when `cdpPort` is supplied.
- Tauri CDP readiness is checked with `/json/version`.
- `snapshot`/`screenshot`/diff behavior is delegated to agent-browser.
- `tauri_listen` waits for one event with timeout; repeated listening requires repeated calls.
- Tauri multi-window: `tauri_connect` -> `tab_list` -> `tab_switch(index)` -> `snapshot`.
- `initActionPolicy()` must run before `browser.launch()`.

## Unsupported Or Restricted In Tauri CDP

| Operation | Reason / alternative |
| --- | --- |
| `launch` / `close` | replaced by `tauri_connect` / `tauri_disconnect` |
| `window_new` | `newContext()` breaks connection; use app/Tauri window creation + `tab_switch` |
| `recording_*` | needs new context; use `trace_*` / `screencast_*` |
| `useragent` / `timezone` / `locale` | context-level settings unavailable after CDP attach |
| `pdf` | not needed for Tauri desktop scenario |
| `swipe` / `device_list` | iOS-specific |
| `video_start/stop` | context-level video config |

## Debugging

Server logs go to stderr through `console.error()` and do not break MCP stdio:

```text
[browser] CDP port 9222 already active, connecting to existing instance
[browser] Connecting BrowserManager to CDP port 9222...
[browser] BrowserManager connected successfully
```

Manual JSON-RPC transport test from the MCP server checkout (maintenance only; normal Agents use `load` + titled `run(scope="tool")`):

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"snapshot","arguments":{}}}' | node index.js
```

After modifying agent-browser source (manual dependency build; substitute the actual inspected checkout for the example path):

```bash
cd ~/devtools/agent-browser && pnpm build
# restart MCP Server
```
