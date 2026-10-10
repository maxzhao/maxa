---
name: wsl-windows
description: "Execute Windows-side commands from WSL2, bridge Windows GUI and background services, handle cross-system paths, recover Docker Desktop WSL integration, and guide Windows + WSL environment detection, bootstrap, migration, and reuse."
compatibility: Requires Maxa Ability runtime.
---
# WSL Windows

Purpose: operate Windows-side CLI/GUI/background processes from WSL2, handle WSL↔Windows paths, and guide Windows + WSL bootstrap/migration.

## Capability Map

| Need | Route |
| --- | --- |
| Windows CLI/build/test | `run(scope="win", command=..., cwd=...)` |
| Windows GUI app | `run(scope="win", command=..., args=[...], opts='{"detach":true}')` |
| Windows background service | `run(scope="win", command=..., args=[...], opts='{"detach":true}')` |
| Windows toolchain from WSL | run the build/test on Windows side |
| Pure WSL/Linux logic | use normal WSL commands/tests |
| Fresh Windows + WSL bootstrap, SSH, ports, keepalive, migration | read `references/fresh-wsl-bootstrap.md` first |
| Docker Desktop Engine, WSL integration, `/var/run/docker.sock`, Linux Workerd/Container access | read `references/docker-desktop-wsl.md` first |
| `run(scope="win")`, runwingui, HTTP/SSE server, Chat builtin contract maintenance | read `references/development/dev-guide.md` first |

Default: for ordinary Windows-side execution and path handling, use this `SKILL.md`; do not load references unless the task matches their route. Read cataloged references with `#wsl-windows[/references/...]`, for example `read(path="#wsl-windows[/references/fresh-wsl-bootstrap.md]")`.

## Docker Desktop And WSL

When Docker works from Windows but Linux Docker, Workerd, Wrangler Containers, or `/var/run/docker.sock` fails, read `references/docker-desktop-wsl.md` before restarting services, changing settings, or accepting a Windows `docker.exe` fallback.

Required completion evidence:

- Windows Docker Engine state is checked separately from target-distribution integration.
- The target WSL distribution uses a Linux Docker CLI and Unix socket.
- `docker version` reports `client=linux/... server=linux/...` inside WSL.
- `/var/run/docker.sock` responds to `/_ping` with `OK`.
- The closest project-owned Docker or Container validation passes, or its unrelated failure is reported exactly.

Do not run `wsl.exe --shutdown` from the current WSL Agent session by default, install a second daemon, use `chmod 777`, replace the Unix socket with `npipe`, delete Docker data, or treat a temporary proxy as persistent repair.

## Fresh Windows + WSL Bootstrap

When the user asks to recreate, migrate, or initialize a fresh Windows + WSL environment, read `references/fresh-wsl-bootstrap.md` before acting.

Required workflow:

1. Run the read-only audit through `run(title="Audit WSL Windows readiness", scope="tool", command="@wsl-windows:/scripts/audit-wsl-windows-readiness.sh", args=[])`.
2. Choose route: configure a fresh distro, or migrate an existing distro via `wsl --export/import`.
3. Separate user/admin blockers from Agent-executable WSL work.
4. Guide user/admin steps: Windows Administrator PowerShell, OpenSSH services, firewall, `.wslconfig`, required `wsl.exe --shutdown`; for migration, export/import path and default distro; ask before any keepalive plan.
5. After user restart/import, configure or repair WSL-side systemd, `/etc/wsl.conf`, `sshd_config`, `ssh.service`, `authorized_keys`; for imported distros, do not overwrite healthy migrated config without evidence.
6. Re-run audit and verify Windows/WSL ports from both sides.

Hard boundaries:

- Do not run `wsl.exe --shutdown` in the current WSL chat by default; it terminates the session.
- Do not create keepalive by default. Ask whether the user wants NSSM Windows startup keepalive or WSL systemd keepalive.
- Do not assume a WSL shell has Windows administrator rights. Generate commands/scripts for Administrator PowerShell when UAC is required.
- Do not download NSSM or other binaries unless the user approves source and install path.
- `wsl --export` includes private keys, tokens, cookies, git/gh/aws/npm/pip credentials, and SSH host keys. Do not clean/delete them before confirming migration purpose.
- `wsl --import` requires an explicit install directory. Do not import into Store Ubuntu `...\Packages\CanonicalGroupLimited.Ubuntu_...\LocalState`.
- To replace a default distro, require backup confirmation before `wsl --unregister <old>`, import to `%LOCALAPPDATA%\wsl\<Distro>` or a data-disk directory, then run `wsl --set-default <Distro>`.
- `/etc/wsl.conf` `[user] default=...` is the Linux user inside WSL, not the Windows user.

## Scripts

After `load(target="wsl-windows")`, use the cataloged scripts. Script output is run-state evidence; workflow rules live here and in references.

```yaml
# Read-only audit and help
- run: {title: "Inspect WSL audit help", scope: tool, command: "@wsl-windows:/scripts/audit-wsl-windows-readiness.sh", args: ["--help"]}
- run: {title: "Audit WSL Windows readiness", scope: tool, command: "@wsl-windows:/scripts/audit-wsl-windows-readiness.sh", args: []}
- run: {title: "Inspect WSL bootstrap help", scope: tool, command: "@wsl-windows:/scripts/bootstrap-wsl-side.sh", args: ["--help"]}
```

Bootstrap plan/apply requires root; `run(scope="tool")` does not elevate privileges. If the authorized executor is already root, use the following calls after resolving the actual `<LINUX_USER>` (no `$USER` expansion):

```yaml
- run:
    title: "Plan WSL bootstrap"
    scope: tool
    command: "@wsl-windows:/scripts/bootstrap-wsl-side.sh"
    args: ["--ssh-port", "2222", "--default-user", "<LINUX_USER>"]
- run:
    title: "Apply approved WSL bootstrap"
    scope: tool
    command: "@wsl-windows:/scripts/bootstrap-wsl-side.sh"
    args: ["--apply", "--ssh-port", "2222", "--default-user", "<LINUX_USER>", "--permit-root", "prohibit-password"]
```

Otherwise request the required user/admin action. Explicit manual privilege exception, with `{ability_root}` resolved from `load`: plan first, apply only after approval.

```bash
sudo bash {ability_root}/scripts/bootstrap-wsl-side.sh --ssh-port 2222 --default-user "$USER"
sudo bash {ability_root}/scripts/bootstrap-wsl-side.sh --apply --ssh-port 2222 --default-user "$USER" --permit-root prohibit-password
```

Windows admin script is run by the user in Administrator PowerShell. Prefer `-WhatIf` first:

```powershell
Get-Help {ability_root}\scripts\bootstrap-windows-admin.ps1 -Full

powershell.exe -NoProfile -ExecutionPolicy Bypass -File {ability_root}\scripts\bootstrap-windows-admin.ps1 `
  -DistroName Ubuntu-24.04 `
  -WslSshPort 2222 `
  -ConfigureWslConfig `
  -ConfigureWindowsOpenSSH `
  -ConfigureFirewall `
  -ConfigureKeepAlive `
  -NssmPath C:\path\to\nssm.exe `
  -WhatIf
```

Key Windows script parameters:

| Parameter | Meaning |
| --- | --- |
| `-DistroName` | Target distro from `wsl.exe -l -v`; after same-name import, confirm `wsl --set-default <DistroName>`. |
| `-WindowsUserProfile` | Target user profile for `.wslconfig` when admin account differs from normal user. |
| `-WslSshPort` | WSL sshd port; default 2222. |
| `-ConfigureWslConfig` | Write mirrored networking config. |
| `-ConfigureWindowsOpenSSH` | Install/enable Windows OpenSSH. |
| `-ConfigureFirewall` | Allow TCP 22 and WSL SSH port. |
| `-ConfigureKeepAlive` | Create NSSM Windows startup keepalive; use only after user confirmation. |
| `-NssmPath` | NSSM executable path. |
| `-WhatIf` | PowerShell dry-run. |

WSL systemd keepalive is a separate optional plan: after user confirmation, create `wsl-keepalive.service` to run `/usr/bin/sleep infinity` after WSL is manually started. It does not auto-start WSL at Windows boot.

## Command Execution Decision Tree

```text
Need Windows-side operation?
├─ Agent tool call: use run(scope="win")
│  ├─ cmd string    -> command="dir C:\\", args omitted/null
│  ├─ executable    -> command="tool.exe", args=[...], including []
│  ├─ PowerShell    -> command="powershell.exe", args=["-NoProfile", "-Command", "..."]
│  ├─ async capture -> opts='{"async":true}', then wait/kill
│  └─ GUI/background -> opts='{"detach":true}'
├─ Shell script / justfile: use runwingui directly when already wrapped there
└─ Project has matching just recipe: prefer just recipe
```

## `run(scope="win")`

Parameters for titled Windows execution:

| Parameter | Default | Meaning |
| --- | --- | --- |
| `title` | required | Nonblank display title; does not select or alter execution behavior. |
| `command` | required | Nonblank cmd.exe string when args is absent/null; executable name/path when args is an array. Do not quote an executable path in literal mode. |
| `scope` | `shell` | Set `"win"` for the Windows backend. Existing loaded-Ability first-match interception still precedes builtin dispatch. |
| `args` | absent/null | Native string array, including `[]`; values remain literal and ordered. Windows rejects object args, including encoded JSON objects. |
| `cwd` | exact Chat project root | WSL or Windows directory; relative paths resolve from that root. Only cwd is translated. |
| `timeout` | 300 | Monitored execution deadline in seconds; nonpositive disables it. With detach, bounds launch/acknowledgement only. |
| `opts` | absent/null | Encoded JSON object string accepting only boolean/null `async` and `detach`; both default false and cannot both be true. Unknown keys, including `pty` and `start_process`, fail even when null. |

Modes:

```yaml
# Independent mode examples; select one, not a batch.
# cmd.exe string: Windows shell builtins, .cmd/.bat tools, operators
- run:
    title: "Install and build Windows Node project"
    scope: win
    command: "pnpm install && pnpm build"
    cwd: "/mnt/c/Projects/my-app"

# Explicit PowerShell: its code is one target argument, not WSL/cmd input
- run:
    title: "Inspect Windows project directory"
    scope: win
    command: powershell.exe
    args: ["-NoProfile", "-Command", "Get-Item -LiteralPath 'C:\\Projects'"]
    cwd: "C:/Projects"

# Native executable path: no extra quoting or shell splitting
- run:
    title: "Launch Unreal project commandlet"
    scope: win
    command: 'C:\Program Files\Epic Games\UE_5.7\Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
    args: ['C:\Projects\NexusFlow\FirstPerson.uproject', "-NoSplash"]
    cwd: "/mnt/c/Projects/NexusFlow"

# GUI: native launch from the existing interactive Windows service
- run:
    title: "Open config in Windows editor"
    scope: win
    command: notepad.exe
    args: ['C:\config.txt']
    cwd: "C:/"
    opts: '{"detach":true}'

# Independent background service: no captured output
- run:
    title: "Start Windows HTTP service"
    scope: win
    command: python.exe
    args: ["-m", "http.server", "8000"]
    cwd: "/mnt/c/Projects/my-app"
    opts: '{"detach":true}'

# Monitored async: capture output; consume through wait, cancel through kill
- run:
    title: "Build Windows Rust project asynchronously"
    scope: win
    command: cargo.exe
    args: ["build"]
    cwd: "/mnt/c/Projects/my-rust-app"
    opts: '{"async":true}'
```

Literal argv supports empty strings, spaces, quotes, trailing backslashes, Unicode, metacharacters and target tokens such as `--cwd` without bridge reinterpretation. It never converts command/argument paths or retries a missing executable as shell code. OS-unrepresentable arguments fail. Target interpreters own their code parsing; `.cmd/.bat` and shell builtins require cmd-string mode or an explicit interpreter rather than implicit literal execution.

Monitored/async execution captures stdout/stderr and preserves available output on nonzero exit, timeout or cancellation. Positive deadlines are enforced by the Windows service from process launch; timeout/cancellation terminate the owned process tree. Detach reports launch status and a real remote process ID, not application completion or an `async_id`; the launched process survives the call and has no captured-output queue. Bridge failures never execute on Linux. Child processes inherit the Windows service environment plus `run`'s exact caller project-root/save-id identity contract; no public env/stdin parameters are added.

## Paths And cwd

| Input | Handling | Example |
| --- | --- | --- |
| WSL `/mnt/` path | `wslpath -w` to drive path | `/mnt/c/Projects` -> `C:\Projects` |
| Windows drive path | preserve backslash or forward-slash form | `C:\Projects`, `C:/Projects` |
| Native UNC | pass through for native argv | `\\server\share\project` |
| WSL native path | `wslpath -w` to UNC | `/home/user/proj` -> `\\wsl.localhost\...` |
| relative path / `.` | resolve against exact Chat project root, then convert | `src`, `.` |

Native argv accepts accessible UNC cwd. Cmd-string mode rejects UNC before execution with guidance to use native argv or a drive directory; it must not silently use `C:\Windows`. Blank, invalid or inaccessible directories fail. This conversion applies only to cwd, never to `command` or `args` values.

Use `wslpath` for manual conversion:

```bash
wslpath -w /mnt/c/Projects
wslpath -u 'C:\Projects\app'
```

## Platform Dependency Rules

Principle: install dependencies on the side that runs them. When switching WSL↔Windows execution, remove incompatible dependency directories and reinstall on the target side.

```yaml
# Windows-side Node deps (pnpm is commonly a .cmd launcher)
- run:
    title: "Install Windows Node dependencies"
    scope: win
    command: "pnpm install"
    cwd: "/mnt/c/Projects/my-app"

# Windows-side Rust deps/build
- run:
    title: "Fetch Windows Rust dependencies"
    scope: win
    command: cargo.exe
    args: ["fetch"]
    cwd: "/mnt/c/Projects/my-rust-app"
```

Node warning: WSL-installed `node_modules` symlinks can fail on Windows with `ENOENT`. Preferred fix: reinstall dependencies on Windows side. Alternative: `.npmrc` with `node-linker=hoisted` and `symlink=false` when compatible.

Typical Windows project flow:

```text
edit in WSL Neovim under /mnt/c -> install deps on Windows -> build/test on Windows -> run dev server or GUI with opts='{"detach":true}' -> run git in WSL unless project rules say otherwise
```

## Windows Build Environment Notes

For very slow builds, a Defender exclusion requires explicit user authorization of the security impact and Windows administrator privileges:

```yaml
run:
  title: "Apply approved Windows Defender exclusion"
  scope: win
  command: powershell.exe
  args: ["-NoProfile", "-Command", "Add-MpPreference -ExclusionPath 'C:\\Projects\\YourProject'"]
  cwd: "."
```

Rust Windows-native build needs MSVC toolchain. WSL-side target check:

```bash
rustup target add x86_64-pc-windows-msvc
rustup show
```

## runwingui Bridge

Architecture:

```text
WSL Neovim -> run(scope="win") -> runwingui bash -> client.py HTTP/SSE -> Windows server.py -> target Windows process
```

Installed bridge layout:

- Authoritative source: Maxa monorepo `tools/wingui/`; resolve it through the actual `runwingui` PATH launcher, not the caller project's cwd or a machine-specific directory.
- Components: `runwingui` -> `client.py` -> `server.py`; no nested Git repository or Windows source copy.
- WSL interpreter: the owning uv project (`package=false`); Windows interpreter: local Python >=3.10 with `pythonw.exe` on Windows PATH.
- Port: `127.0.0.1:19527`.

Management commands run from WSL:

```bash
runwingui --health
runwingui --list
runwingui --kill <id>
runwingui --purge
runwingui --start-server
runwingui --stop-server
runwingui --restart-server
```

Server starts automatically on first call. The launcher derives the Windows UNC source path with `wslpath`, generates only `%LOCALAPPDATA%\Maxa\wingui\start-server.bat` locally, and opens it through Explorer for desktop-session access. Local `pythonw.exe` directly executes the UNC `server.py` with Windows `%TEMP%` cwd. Do not directly execute a UNC batch file or disable its security confirmation; do not synchronize a second source copy. Source edits require restarting the service.

Troubleshooting:

| Symptom | Likely cause | Check/fix |
| --- | --- | --- |
| `runwingui` not found | broken/missing symlink | `which runwingui && readlink -f $(which runwingui)` |
| Server start fails | uv/Windows Python/UNC access | `runwingui --health`; check owning uv project, Windows `pythonw.exe` PATH and UNC source accessibility |
| command timeout | server/network/hung process | `runwingui --list`; `runwingui --restart-server` |
| GUI does not open | server lacks GUI session | confirm server started through `explorer.exe` |
| mojibake | encoding mismatch | for cmd-string mode, prefix the command with `chcp 65001 &&`; use target-owned encoding options in native mode |

## Validation

For doc-only Ability changes, validate the public invocation:

```yaml
- load: {target: "wsl-windows", force_reload: true}
- run: {title: "Inspect WSL audit invocation", scope: tool, command: "@wsl-windows:/scripts/audit-wsl-windows-readiness.sh", args: ["--help"]}
```

Maintainer-only syntax checks use physical paths resolved from the loaded root; they are not operational script invocation:

```bash
bash -n {ability_root}/scripts/audit-wsl-windows-readiness.sh
bash -n {ability_root}/scripts/bootstrap-wsl-side.sh
```

For Chat builtin/runtime changes, also restart Neovim through the owning runtime workflow and validate `run(scope="win")` with cmd strings, literal argv, monitored async and native detach. Observe GUI windows through existing desktop tools; successful launch status alone does not prove GUI behavior.

