---
title: Browser External MCP 稳定规格
created: 2026-06-28
updated: 2026-10-07
type: source
doc_role: spec
authority: stable
status: stable
capability: browser-mcp-server
validation:
  specification: passed
  automated: partial
  live: passed
  human: passed
sources:
  - abilities/browser/SKILL.md
  - abilities/browser/references/tauri-app.md
  - abilities/browser/references/browser.md
  - abilities/browser/references/browser-backends.md
  - abilities/browser/references/operations.md
  - abilities/browser/references/development/server-dev.md
  - mcp-servers/browser/index.js
  - mcp-servers/browser/lib/session.js
  - mcp-servers/browser/lib/tool-registry.js
  - mcp-servers/browser/lib/tools/tauri.js
  - mcp-servers/browser/package.json
confidence: high
---

## Scope and ownership

`browser` external MCP/Ability owns connection routing/lifecycle, operation registration, refs/diff and Tauri IPC. Imperatives express SHALL obligations.

- **Browser operation scope**: Describe supported Chromium/CDP, Tauri WebView and managed backends, not every engine or real rendering from `standard`/Obscura. Search/fetch/extraction route to `web-fetch`; exploratory QA to [Browser Dogfood](../../extensions/browser-dogfood/browser-dogfood.md), authorized test work to [Browser E2E](../../extensions/browser-e2e/browser-e2e.md). Ordinary operation requires neither QA/test workflow.
- Excluded: protected-browser one-time setup beyond routing, complete per-tool schemas, Node internals and generated/build output. Do not freeze every underlying `agent-browser` schema.

## Requirements

- **Server runs as an external MCP stdio server**: Node.js ESM package `browser-mcp`, entry `mcp-servers/browser/index.js`, creates MCP server `browser` and connects via `StdioServerTransport` at initialization.
- **Scenario routing selects the connection mode before operations**: Before page tools, choose the workflow below; once connected, use shared `references/operations.md`.

  | Target | Ability reference; entrypoint/ownership |
  | --- | --- |
  | Tauri app | `references/tauri-app.md`; `tauri_connect` connects active CDP or may launch the app if its port is inactive. |
  | Existing Chrome/Edge/Chromium CDP | `references/browser.md`; `cdp_connect` expects an external endpoint; by default does not own its process. |
  | Managed standard/protected/auto backend | `references/browser-backends.md`; `browser_start` / status / stop. |

- **Browser operation tools require an active connection**: `tool-registry.js` handlers reject operations when `session.connected=false` with “Not connected” and instruction to connect first.
- **Unified operation surface covers observation, interaction, waits, diffing, state, network, media, tabs, and environment control**: One shared action registry registers operations across connection modes; connected snapshot/screenshot/click/fill/type/wait/diff/tabs/network/storage/cookies/viewport/evaluate calls dispatch to underlying browser actions.
- **Snapshot refs are short-lived page-state handles**: `@eN` (e.g. `@e1`) expires after page-changing actions—navigation clicks, form submission, dynamic content, tab switching and navigation included. Take a fresh snapshot before reusing refs.
- **Diff tools support verification of UI changes**: After an operation, `diff_snapshot` compares current state with a captured baseline snapshot; `diff_screenshot` produces visual evidence from a baseline screenshot path. Semantic and visual evidence remain distinct.
- **Tauri IPC tools operate only when Tauri APIs are available**: Connected Tauri pages exposing `window.__TAURI__.core.invoke` or compatible internals allow `tauri_invoke(command,args)` to invoke the backend and return result/timeout error. Missing globals explicitly fail `tauri_invoke`, `tauri_emit`, `tauri_listen` with Tauri API unavailable. Invoke/listen time out rather than wait indefinitely.
- **Server connection lifecycle is explicit and single-active-session oriented**: Connecting while connected errors and requests disconnect first. Disconnect/stop closes or detaches browser manager/session according to connection type/options; external-CDP process ownership is not implied.

## Identity and compatibility

- **Composite Browser identity**: Same-name MCP composition: one `browser` load commits guidance, references and permitted source tools together; discovery adds no duplicate entry for that MCP source.
- **Direct public identity migration**: Active config/instructions/runtime addresses use `browser`, `browser-dogfood`, `browser-e2e`; retire previous Ability/MCP identities without forwarding aliases. Migration guidance identifies affected project overrides/physical helper imports; historical records retain original identities.
- **Existing operation compatibility**: Preserve tool names, schemas/constraints, returns, backend defaults, Tauri availability checks and ref refresh; `@browser:*` retains the former source's output-policy treatment.
- **Ability-owned Python override migration**: Helper root precedence: explicit `BROWSER_ABILITY_ROOT` > explicit `TAURI_PLAYWRIGHT_ABILITY_ROOT` > relocated `browser` default. Default invocation: `uv run --project <owning Ability root> python`; missing uv/dependencies fail explicitly, never fall back to system Python.

## Acceptance and evidence

Source map (full paths in frontmatter): server → `index.js`/`package.json`; connection → `session.js`; dispatch → `lib/tool-registry.js`; IPC → `lib/tools/tauri.js`; routing/ref/diff → `abilities/browser/SKILL.md` and references. [Browser index](./index.md) owns module routing.

Acceptance requires current source citations, explicit connection mode/prerequisite and ref invalidation/diff/IPC/disconnect boundaries, distinguishing static/unit from live validation. Existing checks:

```bash
cd mcp-servers/browser
node --check index.js
node --check lib/session.js
node --check lib/tool-registry.js
node --check lib/tools/tauri.js
npx vitest run tests/session-browser-backend.test.js tests/session-obscura.test.js
```

To upgrade live status, start through MCPHub, verify listing, exercise test-app `tauri_connect` plus one external-CDP or managed-backend path, and observe ref refresh/diff after real page changes. Before upgrading automated coverage, check test portability/browser/service dependencies. Specification-only edits need no restart; external behavior changes follow MCP Creator reload rules. Split protected-backend behavior only if later dogfood establishes an independent contract.

Dated evidence retains its scope; current status does not erase earlier limits:

| Scope/date | Evidence and limits |
| --- | --- |
| 2026-06-28; historical `mcp-servers/tauri-playwright` | `node --check index.js && node --check lib/session.js && node --check lib/tool-registry.js && node --check lib/tools/tauri.js` passed. The Vitest command above: 1 test passed/3 skipped; 1 file passed/1 skipped. Live Tauri/CDP/managed flows `not-run`; automated `partial`; human spec review `passed`. |
| 2026-10-04; browser workflow evolution | Migration accepted: focused checks, fresh composite load, real Chromium interaction/screenshot, helper ownership/partial-start cleanup and retained Tauri UI/IPC evidence. Extra standard remote warmup timed out; automated `partial`, model behavior unmeasured, human review not-run. |
| Current | Source/skill/module-index/cross-spec reachability and scoped live status `passed`; dated not-run/skipped/warmup limits remain. |
| 2026-10-07 | User review passed; earlier human not-run is historical. Automated/live gaps and unmeasured model behavior remain. |
