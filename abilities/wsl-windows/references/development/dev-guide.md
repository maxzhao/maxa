# WSL-Windows Development Guide

Purpose: maintain the WSL→Windows execution stack:

1. Chat builtin tool: `run(scope="win")`.
2. Bridge engine: `runwingui` bash + WSL `client.py` + Windows `server.py`.

Read this only for implementation/debugging work. Ordinary Windows-side command execution should use `SKILL.md`.

## Chat Builtin Side

### Code Locations

```text
lua/maxa/interactions/chat/tools/builtin/
├── init.lua                           # ordered first-party builtin registration
├── tools/
│   └── builtin_run.lua                 # shared preparation and Shell/Windows dispatch
└── runtime/
    ├── windows_command.lua            # Windows argv/cwd/async/bridge backend
    ├── output_collector.lua           # bounded stdout/stderr collection
    └── utils.lua                      # shared output limits/helpers
```

### Execution Flow

```text
run(command, scope="win", args, cwd, timeout, opts)
├─ side-effect-free run.prepare before existing first-match Ability interception
│  ├─ preserve Windows drive/UNC cwd; default/relative cwd uses exact Chat project root
│  └─ normalize args/opts without inheriting Shell-only options
├─ when no extension handles win: Windows backend
│  ├─ convert only WSL cwd using list-form wslpath; validate accessible target directory
│  ├─ args absent/null -> one command string to COMSPEC cmd.exe (system cmd.exe fallback)
│  │  └─ reject UNC cwd before launch
│  └─ args array, including [] -> [command,...args] with shell=False
│     └─ native argv accepts accessible UNC cwd; no missing-executable shell fallback
├─ bridge transport: options before target; consume -- once; preserve remaining argv
│  ├─ no command/argument path conversion, joining or re-splitting
│  └─ use explicit strict execution request; retained legacy CLI behavior stays isolated
├─ monitored/default or opts='{"async":true}'
│  ├─ Windows service owns positive deadline and process-tree cancellation
│  ├─ drain stdout/stderr before final exit; retain failure/timeout/cancel distinctions
│  └─ reuse run output bounds, shared async registry and direct/wrapped cancellation
└─ opts='{"detach":true}'
   ├─ native launch from existing interactive Windows service; no captured output queue
   └─ return launch status and remote process ID, not async_id/completion; timeout bounds launch only
```

### Backend Boundaries

| Area | `run(scope="shell")` / default | `run(scope="win")` |
| --- | --- | --- |
| Environment | configured WSL/Linux Shell | Windows service environment |
| args absent/null | configured Shell string | cmd.exe string; explicit PowerShell argv for PowerShell syntax |
| args array | literal executable argv | native Windows argv; .cmd/.bat require explicit interpreter or cmd string |
| cwd | accessible local directory | exact Chat root/relative WSL converted; drive/UNC preserved; cmd-string UNC rejected |
| opts JSON | boolean/null `pty`, `async` | boolean/null `async`, `detach`; reject unknown keys and both true |
| async | shared session-local wait/kill | same registry and terminal latch; server owns process tree |
| detach | unavailable | output-free native launch, including GUI; real remote ID |

`run` still exposes only `command`, `scope`, `args`, `cwd`, `timeout`, `opts`. Do not add public env/stdin, shell-selection or GUI-specific parameters. Extension-first ordering and command-less trusted Ability-script execution remain unchanged. Retired `winrun` has no schema, callback, nested target or alias; persisted calls/messages and historical display are not translated.

### Chat Builtin Change Rules

For an authorized Windows backend change:

1. Inspect `builtin_run.lua`, its preparation/dispatch boundary, the owning Windows backend and bridge request parser. Preserve required title/command, optional scope/args/cwd/timeout/opts, and extension-first behavior for non-tool scopes; tool scope is reserved builtin dispatch.
2. Validate Windows-specific args/options before execution. String args must first decode as JSON objects under the shared contract, then fail as unsupported Windows args; native execution takes only a direct string array.
3. Preserve command/argument values through every launcher/client/server boundary and strict native execution. OS-unrepresentable values fail; never reinterpret missing executables as code.
4. Reuse bounded output and existing async/cancellation bridges for `run` and `multicall` members; preserve independent member async IDs and lifecycle without adding batch async or result aggregation. Propagate or clear exact caller project-root/save-id identity without interpolating it into commands.
5. Update directly affected Windows guidance and focused checks. Restart Neovim through the `mcp-creator` workflow; in-process builtin registration requires a fresh process.

Output handling:

- Share `run`'s output contract across Shell and Windows; detach reports launch rather than command completion.
- Reuse `builtin.runtime.utils.MAX_OUTPUT_CHARS` and `builtin.runtime.output_collector` semantics.
- Preserve exit-code and stderr behavior; do not turn failed Windows commands into success.

Debugging:

- Inspect existing Snacks notifier history and bridge errors before adding logs; never leave local debug noise or identity values in shared runtime output.
- Distinguish bridge launch failure, target nonzero exit, timeout and cancellation; preserve available stdout/stderr.
- For cwd failures, check the translated directory and native-vs-cmd mode; do not filter away a wrong-cwd warning or silently change directories.

Registration:

```lua
-- The ordered inventory in builtin/init.lua maps public names to private modules:
{ name = "run", module = "builtin_run" },
```

## runwingui Bridge

### Bridge Source Binding

Resolve `<wingui-root>` from the actual `runwingui` installation before maintenance; authoritative source is the Maxa monorepo's `tools/wingui/`, not a separate Git repository or an Ability package. Inspect and preserve the current diff. Windows executes this source through WSL UNC paths; generated local launchers and interpreters are runtime data. If unavailable, request source/access instead of recreating a bridge or guessing a deployment.

| Item | Value |
| --- | --- |
| Source | `<wingui-root>` from the active launcher |
| WSL entry | `runwingui` on PATH; installations may use a symlink |
| Port | `127.0.0.1:19527` |
| Python | >= 3.10, no external deps |
| WSL runtime | owning uv project, `package=false` |
| Windows runtime | local Python >=3.10; `pythonw.exe` on Windows PATH |
| Generated launch entry | `%LOCALAPPDATA%\Maxa\wingui\start-server.bat`; no source copy |

### Architecture

```text
WSL side
  runwingui (bash)
  ├─ parse bridge options only before target; honor -- and preserve target argv
  ├─ manage server: --start-server/--stop-server/--restart-server/...
  └─ auto-start server before first command
      ↓
  client.py
  ├─ WinGUIClient HTTP wrapper
  ├─ SSE stream_output()
  ├─ Ctrl+C -> kill_async remote process
  └─ strict run requests plus health/list/kill/purge management; legacy CLI launch conveniences remain separate
      ↓ HTTP 127.0.0.1:19527 / SSE
Windows side
  server.py
  ├─ ThreadedHTTPServer
  ├─ ProcessManager
  │  ├─ subprocess.Popen
  │  ├─ monitored-only stdout/stderr readers; drain before terminal event
  │  ├─ monitored deadline/process-tree cancellation; output-free detach
  │  └─ completed-process TTL purge
  ├─ WinGUIHandler routes: /run, /stream, /kill, /health, /processes, /purge
  └─ Windows-local generated start-server.bat via Explorer -> local pythonw.exe -> UNC source
```

### Server Startup

```text
runwingui <command>
├─ owning uv project -> client.py --health, timeout 2s
├─ if failed: start_server()
│  ├─ uv sync --project <wingui-root>; wslpath -w server.py
│  ├─ Windows PowerShell resolves local pythonw.exe and regenerates a local runtime .bat
│  ├─ explorer.exe <Windows-local launcher>; cwd=%TEMP%, script=<UNC source>
│  └─ poll health up to 15s
└─ uv run --project <wingui-root> --no-sync python client.py [options] -- <command>
```

Explorer preserves interactive-desktop startup. Directly opening a UNC .bat triggers Windows security confirmation; generate only the tiny launcher locally instead. Use local Python with an absolute UNC script path and local Windows cwd, because cmd.exe cannot cd to UNC. Source stays single-owner in tools/wingui; do not copy it or change trusted zones. The generated launcher uses UTF-8 for non-ASCII paths and contains no credentials.

## HTTP API

### `POST /run`

Bridge request fields remain private to this backend. `run` invokes `runwingui --strict --timeout <seconds> --cwd <windows-cwd> [--detach] [--shell] -- <target...>`. The client requires `/health.strict_execution=true` before submission; restart an older server rather than lose strict argv/deadline behavior. Shell requests use `command:string` and `shell:true`; native requests use `command:string[]`. Existing caller identity travels through bridge `env`, not public parameters.

Strict native argv request:

```json
{
  "command": ["cmd.exe", "/d", "/c", "dir"],
  "cwd": "C:\\Projects",
  "strict": true,
  "detach": false,
  "timeout": 300
}
```

Response:

```json
{
  "id": "uuid-string",
  "command": ["cmd.exe", "/d", "/c", "dir"]
}
```

### `GET /stream?id=xxx`

```text
Content-Type: text/event-stream

event: stdout
data: output line content

event: stderr
data: error line content

event: exit
data: 0
```

Execution timeout emits `event: timeout` before the final exit. The client forwards `__MCPX_COMMAND_TIMEOUT__` to stderr and exits 124; the Windows `run` backend filters the marker into its timeout status. Cancellation uses `/kill` plus the shared terminal latch, not an additional SSE event. Detached processes reject `/stream` because they do not capture output.

### Other Endpoints

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/health` | GET | `{"status":"ok","version":"1.0.0"}` |
| `/processes` | GET | process list |
| `/kill` | POST | kill process by `{"id":"..."}` |
| `/purge` | GET | purge completed processes |

## Process Lifecycle

```text
POST /run
├─ ProcessManager.start_process()
│  ├─ strict native resolution or explicit cmd-string launch; no implicit PowerShell fallback
│  ├─ monitored: Popen(..., stdout=PIPE, stderr=PIPE), readers and monitor
│  │  ├─ positive deadline starts at actual process launch
│  │  └─ timeout/kill terminate owned tree; readers drain before final exit result
│  └─ detach: native Popen without capture/readers/output queue; return remote launch ID
├─ monitored client GET /stream?id=xxx
│  └─ SSE emits stdout/stderr, optional timeout, then exit and closes
└─ after completion
   ├─ process stays in memory for delayed stream consumption, TTL 60s
   └─ cleanup every 30s or manual /purge
```

## Development Environment

First setup:

```bash
# Manual setup after uv and Windows Python prerequisites are satisfied:
uv sync --project <wingui-root>
# Inspect any existing PATH entry before deliberately switching it.
ln -s <wingui-root>/runwingui ~/.local/bin/runwingui
runwingui --start-server
runwingui --health
```

Change behavior:

- `client.py` or `runwingui`: WSL-side changes apply immediately.
- `server.py`: run `runwingui --restart-server`.

## Troubleshooting

Fast path:

```text
runwingui not found -> which runwingui && readlink -f $(which runwingui)
server unhealthy    -> runwingui --health; check port 19527, uv runtime, Windows Python and UNC access
command timeout     -> runwingui --list; runwingui --restart-server
GUI not visible     -> use native run argv with opts='{"detach":true}'; ensure server launched via explorer.exe
mojibake            -> for cmd strings, prefix command with chcp 65001 &&; for native argv, use target encoding options
```

Common issues:

| Issue | Cause | Fix |
| --- | --- | --- |
| `ConnectionRefused` | server not running | `runwingui --restart-server` |
| `wslpath: command not found` | not in WSL | run from WSL2 |
| port 19527 occupied | stale server/process | `netstat -ano \| findstr 19527` then `taskkill /F /PID` |
| uv runtime unavailable | owning WSL project/interpreter missing | request setup/access; manual setup uses `uv sync --project <wingui-root>` |
| `pythonw.exe not found` | Windows Python absent from PATH | request existing Windows Python setup; no Windows source-directory venv is required |
| UNC cwd rejected | cmd-string mode cannot use UNC cwd | use native executable+args or an accessible drive directory; never silently substitute another cwd |
| generated start-server.bat no effect | local launcher/Python/UNC access | inspect the Windows-local generated launcher and retry only after fixing the concrete prerequisite; never bypass UNC security prompts |
| process list pile-up | completed processes not purged | `runwingui --purge` |

## Extension Guide

Add runwingui option:

1. `runwingui`: add bridge-only option parsing before the target and pass `CLIENT_ARGS`; never consume target tokens after the command/`--` boundary.
2. `client.py`: add argparse option and update command function.
3. `server.py`: update `_handle_run` / `ProcessManager` if process execution changes.

Public Chat contract changes belong to `builtin_run.lua` and require explicit authorization. Keep this migration's six fields unchanged; Windows-only modes use the existing `opts` JSON field. Follow Chat Builtin Change Rules above rather than adding a second Windows tool or compatibility alias.

Add server API endpoint:

1. Add route in `server.py` `do_GET` or `do_POST`.
2. Add `WinGUIClient` method in `client.py`.
3. Add argparse subcommand in `client.py`.
4. Add runwingui management command when needed.
5. Run `runwingui --restart-server`.

## Validation

For bridge changes, use its resolved uv project for Python syntax checks and `bash -n <wingui-root>/runwingui`. Inspect `runwingui --health` and `runwingui --list`; reload changed server code with the existing `runwingui --restart-server` path. Preserve installation/startup ownership; these checks do not authorize dependency installation or service redesign.

For Chat builtin changes, run the affected existing inventory/registry/schema/run/extensions/prompt checks, then restart Neovim through `mcp-creator` and validate actual titled `run(scope="win")` and Windows-scope `multicall` members. Use Windows run requests in `runs` or native `run` siblings; do not mix the two forms, route execution wrappers through tool-mode targets, or nest `multicall`:

- Cmd strings and explicit PowerShell argv remain separate; representative literal values and option-like target arguments survive monitored, async and detach modes.
- Default/relative WSL cwd and drive cwd resolve correctly; native UNC works and cmd-string UNC fails before execution. Existing Windows search/glob remains compatible with the launcher parser.
- Nonzero/short-lived final output, server-owned positive timeout and direct/wrapped process-tree cancellation retain output and distinct terminal status. Async uses wait/kill; detach returns a real remote ID without captured output and survives the call.
- Native detached GUI launch: observe the real intended Windows window/file using existing desktop tools, then close only the disposable launched application. Do not author GUI tests or infer UI success from unit tests/launch acknowledgement.
- Verify `run` and `multicall` against the current builtin inventory; `call` and `winrun` remain unavailable, while their historical display/messages remain readable without rewriting. Check separate full member outputs and closure facts rather than an aggregate result. Do not run a full-project suite for this migration.

Detailed acceptance/results belong to the owning task, not this guide. Report exact unverified behavior when a required target or observation is unavailable.
