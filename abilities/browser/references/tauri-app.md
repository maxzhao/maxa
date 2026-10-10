# Tauri App Scenario

Purpose: test/debug Tauri desktop apps through `tauri_connect`, WebView2 CDP, Tauri multi-window handling, and Tauri IPC.

Prerequisite: `load(target="browser")`; invoke MCP targets through titled `run(scope="tool")` with encoded JSON object `args` as shown below. After connection, use `read(path="#browser[/references/operations.md]")` for page observation, interaction, screenshots, diff, network, and state tools. Replace the `app_path` placeholder with the actual Windows executable path, not an Ability address.

## Multi-Window Model

Each Tauri window is a separate WebView2 page under one process-level CDP port:

```text
Tauri process (PID 1234) -> CDP port 9222
├── WebView2 "main"     -> page index 0
├── WebView2 "settings" -> page index 1
└── WebView2 "editor"   -> page index 2
```

Workflow:

```yaml
- run: {title: "Connect Tauri app", scope: tool, command: "@browser:tauri_connect", args: '{"app_path":"...","port":9222}'}
- run: {title: "Open app settings window", scope: tool, command: "@browser:tauri_invoke", args: '{"command":"open_settings_window"}'}
- run: {title: "List Tauri windows", scope: tool, command: "@browser:tab_list", args: '{}'}
- run: {title: "Select observed settings window", scope: tool, command: "@browser:tab_switch", args: '{"index":1}'}
- run: {title: "Inspect settings window", scope: tool, command: "@browser:snapshot", args: '{"compact":true}'}
- run: {title: "Return to main app window", scope: tool, command: "@browser:tab_switch", args: '{"index":0}'}
```

Rules:

- Call `tauri_connect` once per target app session.
- Use `tab_switch` for every Tauri window switch.
- Each window has independent DOM, state, and refs.
- Create windows through app behavior or `tauri_invoke`; close with `tab_close` when appropriate.
- Do not use browser `window_new` as a Tauri multi-window API.

## CDP-Limited Tools

`tauri_connect` attaches to an existing WebView2 BrowserContext. Creating a new BrowserContext can break the whole CDP connection; recover with `tauri_disconnect` -> `tauri_connect`.

| Tool/action | Root cause | Use instead |
| --- | --- | --- |
| `window_new` | `newContext()` breaks connection | app/Tauri command creates window, then `tab_switch` |
| `recording_start/stop/restart` | video recording needs new context | `trace_start/stop` or `screencast_start/stop` |
| `tap` | touch context cannot be changed after CDP attach | `input_touch` |
| `clipboard read` | WebView2 permission dialog may hang | bridge has 3s timeout and URL recovery |
| `state_load` | requires browser relaunch | not applicable to Tauri CDP |

Known working despite earlier misclassification: `state_save`, `state_show/rename/clean`, `diff_url`, `screencast_start/stop`.

## Clipboard Permission

WebView2 may show a system permission dialog for `navigator.clipboard.readText()` without a user gesture.

Server-side defense already exists:

1. `clipboard read` has 3s timeout.
2. On timeout, bridge checks whether the page was hijacked to `edge://permission-request-dialog/`.
3. If hijacked, it navigates back and returns an error.

Recommended app-side fix on Windows: register `PermissionRequested` and allow required permissions. The Rust/TOML and lockfile command below are app source-maintenance examples, not Ability tool calls; their paths refer to the target app project.

```rust
// filepath: src-tauri/src/lib.rs
use tauri::Manager;

#[cfg(target_os = "windows")]
fn auto_grant_permissions(app: &tauri::AppHandle) {
    use webview2_com::Microsoft::Web::WebView2::Win32::COREWEBVIEW2_PERMISSION_STATE;
    use webview2_com::PermissionRequestedEventHandler;

    if let Some(main_window) = app.get_webview_window("main") {
        let _ = main_window.with_webview(move |webview| unsafe {
            let core = webview.controller().CoreWebView2().unwrap();
            let mut token: i64 = 0;
            let handler = PermissionRequestedEventHandler::create(Box::new(
                move |_sender, args| {
                    if let Some(args) = args {
                        let _ = args.SetState(COREWEBVIEW2_PERMISSION_STATE(1)); // Allow
                    }
                    Ok(())
                },
            ));
            let _ = core.add_PermissionRequested(&handler, &mut token);
        });
    }
}
```

Cargo dependency versions must match the Tauri lockfile; inspect with `grep -A 2 'name = "webview2-com"' Cargo.lock`.

```toml
[target.'cfg(windows)'.dependencies]
webview2-com = "0.38"
windows = { version = "0.61", features = ["Win32_Foundation"] }
```

For production, check `args.PermissionKind()` and grant only required kinds: `6` = ClipboardRead, `3` = Geolocation.

## Geolocation Permission

`geolocation` + `permissions` can trigger a system dialog and block navigation. Prefer JS stubbing in tests:

```yaml
run:
  title: "Set test geolocation behavior"
  scope: tool
  command: "@browser:evaluate"
  args: '{"script":"navigator.geolocation.getCurrentPosition = (success) => { success({ coords: { latitude: 37.7749, longitude: -122.4194, accuracy: 10 } }); };"}'
```

Alternative: authorize Geolocation in the app-side `PermissionRequested` handler. If blocked by a permission dialog, recover with `tauri_disconnect` -> `tauri_connect`.
