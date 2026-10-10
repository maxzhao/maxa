# Docker Desktop And WSL Recovery

Purpose: diagnose and recover Docker Desktop access from WSL2 when Linux tools, Workerd, Wrangler Containers, or other consumers require a Linux Docker CLI connected through `/var/run/docker.sock`.

## Success Contract

Do not stop after proving that Windows `docker.exe` can reach Docker Desktop. Recovery is complete only when all checks pass inside the target WSL distribution:

```bash
stat /mnt/c
docker context show
docker version --format 'client={{.Client.Os}}/{{.Client.Arch}} server={{.Server.Os}}/{{.Server.Arch}}'
curl --silent --show-error --max-time 5 --unix-socket /var/run/docker.sock http://localhost/_ping
```

Expected Docker evidence:

```text
default
client=linux/amd64 server=linux/amd64
OK
```

A Windows CLI using `desktop-linux` and `npipe://` proves only that the Windows client can reach the Engine. It does not satisfy Linux Workerd or Cloudflare Container tooling.

## Safety And Boundaries

- Diagnose before restarting or editing settings.
- Do not run `wsl.exe --shutdown` from the active WSL Agent session by default; it terminates that session.
- Do not delete Docker data, unregister `docker-desktop`, reset Docker Desktop to factory defaults, prune images, or remove VHDX files as routine repair.
- Do not install a second Linux Docker daemon while Docker Desktop integration is the selected architecture.
- Do not replace `/var/run/docker.sock` with a Windows `npipe` endpoint for Linux Workerd.
- Treat Docker Desktop internal binaries and log-derived commands as version-specific. Use the emergency proxy path only after verifying the installed command from current logs and files.
- Do not persist an emergency proxy as a permanent service. Docker Desktop owns normal integration lifecycle.

## Initial Triage

Run WSL-side checks first:

```bash
printf '%s\n' '--- host mounts and interop ---'
stat /mnt/c
cmd.exe /d /c ver

printf '%s\n' '--- Linux Docker path and socket ---'
command -v docker
readlink -f "$(command -v docker)" || true
ls -l /usr/bin/docker /var/run/docker.sock 2>&1 || true
id
docker context show 2>&1 || true
docker version --format 'client={{.Client.Os}}/{{.Client.Arch}} server={{.Server.Os}}/{{.Server.Arch}}' 2>&1 || true
curl --silent --show-error --max-time 5 --unix-socket /var/run/docker.sock http://localhost/_ping 2>&1 || true
```

Then inspect Windows-side state with `run(scope="win", command="powershell.exe", args=["-NoProfile", "-Command", "<code below>"], cwd="C:/")`. Pass the PowerShell code as one literal argument:

```powershell
Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue |
  Select-Object ProcessName,Id,StartTime
Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue |
  Select-Object Name,Status,StartType
wsl.exe -l -v
& 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' desktop status
& 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' version
```

## Failure Classification

| Evidence | Owning failure | Recovery route |
| --- | --- | --- |
| `/mnt/c` and `/mnt/d` return `Input/output error`; Interop reports `Broken pipe`; logs contain `Operation canceled @p9io.cpp` | WSL host 9P/Interop channel is stale or disconnected | Preserve evidence, then require a Windows-side `wsl.exe --shutdown` and reopen WSL |
| Windows `docker desktop status` is stopped or Windows `docker.exe version` has no Server section | Docker Desktop Engine is unavailable | Start or restart Docker Desktop, then wait for Windows Engine readiness |
| Windows Engine is healthy but `/mnt/wsl/docker-desktop` is absent | Docker Desktop WSL distribution/bootstrap has not mounted | Restart Docker Desktop; inspect `docker-desktop` state and current backend logs |
| Windows Engine is healthy and `/mnt/wsl/docker-desktop` exists, but `/var/run/docker.sock` is absent | Target-distribution WSL integration proxy is missing or failed | Restart target-distro integration; inspect backend error before any emergency recovery |
| `/var/run/docker.sock` exists but has no listener | Stale bind mount or dead integration proxy | Confirm socket probe failure; restart integration rather than changing permissions |
| Socket returns permission denied and Engine is listening | Linux group/mode problem | Verify `id`, socket group, and Docker Desktop integration group setup; do not use `chmod 777` |
| Docker works from Windows as `client=windows/amd64 server=linux/amd64`, but Linux reports `client=windows/amd64`, `desktop-linux`, or `npipe` | WSL is falling back to `docker.exe` | Restore `/usr/bin/docker` and Unix-socket integration; do not accept Windows fallback |

## Recovery Workflow

### 1. Repair WSL Host Channel First

When Windows drives themselves return `Input/output error`, Docker is downstream of a broken WSL host channel. Useful evidence:

```bash
journalctl -k -b --no-pager | grep -Ei 'p9io|Broken pipe|CheckConnection|docker-desktop|unmounting filesystem'
```

Do not repeatedly restart Docker Desktop in this state. A Windows-side `wsl.exe --shutdown` is the reliable reset. Because it terminates the active session, ask the user or use an out-of-session Windows control path only when explicitly safe. After WSL restarts, recheck `/mnt/c`, Interop, and `runwingui` before Docker.

### 2. Recover Docker Desktop Engine

Use the installed Docker Desktop CLI from Windows:

```powershell
& 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' desktop status
& 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' desktop start
# If processes are stale or startup previously timed out:
& 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' desktop restart
```

Poll Windows `docker.exe version` until the Server section reports `linux/amd64`. Do not assume the command's immediate `Starting Docker Desktop` response means the Engine is ready.

### 3. Recover Target-Distribution Integration

Verify ordinary WSL execution from Windows before blaming the distribution:

```powershell
wsl.exe -d <DISTRO> -e whoami
wsl.exe -d <DISTRO> -u root -e /bin/true
```

Inspect current Docker Desktop backend logs without printing unrelated configuration or secrets:

```powershell
$log = Join-Path $env:LOCALAPPDATA 'Docker\log\host\com.docker.backend.exe.log'
Get-Content -LiteralPath $log -Tail 2000 |
  Select-String -Pattern 'wslintegration|setup groups|wslErrorCode|distro agent|docker-desktop-user-distro proxy'
```

Common errors:

- `Wsl/Service/CreateInstance/HCS_E_CONNECTION_TIMEOUT`: Docker Desktop could not bootstrap `docker-desktop`; restart WSL host state before retrying.
- `Wsl/Service/0x8007274c` during `whoami` or `setup groups`: target-distribution integration timed out even though the Engine may be healthy.
- `write |1: The pipe is being closed`: Docker Desktop's integration subprocess lost its WSL execution pipe.

Preferred repair order:

1. Use Docker Desktop's **Restart the WSL integration** action when the error dialog exposes it.
2. Otherwise disable and re-enable integration for the target distribution through Docker Desktop Settings, then wait for resync.
3. Restart Docker Desktop once and revalidate both Windows Engine and Linux socket.
4. If GUI automation is needed, load `winctl`; observe the current window before clicking and verify afterward.
5. If an administrator action or session-terminating reset is required, call builtin `ask` directly and request only that exact action.

Do not directly rewrite `settings-store.json` as the default workflow. If no supported UI/CLI route is available and a settings edit is explicitly justified, back up the file, stop Docker Desktop first, patch only the verified integration key, restart Desktop, validate, and remove the temporary backup after success.

### 4. Version-Specific Emergency Proxy

Use this only when all conditions hold:

- Windows Docker Engine is healthy.
- `/mnt/wsl/docker-desktop` and the target-distribution proxy binary exist.
- Current Docker Desktop logs show the exact proxy invocation for the installed version.
- Supported integration restart has failed.
- Immediate Linux Unix-socket access is required.

Current Docker Desktop logs may show a command shaped like:

```text
wsl.exe -d <DISTRO> -u root -e /run/docker-desktop/docker-desktop-user-distro proxy --distro-name <DISTRO> --docker-desktop-root /mnt/wsl/docker-desktop c:\program files\docker\docker\resources
```

Preserve the required positional Windows resources path. Omitting it can fail with `accepts 1 arg(s), received 0`; substituting the distro name can fail while mounting `/Docker/host`.

A transient, observable recovery can be started from Windows with a unique unit name:

```powershell
wsl.exe -d <DISTRO> -u root -- systemd-run `
  --unit=docker-desktop-proxy-recovery `
  --property=Restart=on-failure -- `
  /run/docker-desktop/docker-desktop-user-distro proxy `
  'c:\program files\docker\docker\resources' `
  --distro-name <DISTRO> `
  --docker-desktop-root /mnt/wsl/docker-desktop
```

Immediately inspect:

```bash
systemctl status docker-desktop-proxy-recovery --no-pager -l
journalctl -u docker-desktop-proxy-recovery --no-pager -n 80
```

Accept only when the log contains `docker-desktop-user-distro proxy has started` and the Linux success contract passes. This is a temporary recovery, not proof that Docker Desktop's normal integration lifecycle is repaired. Stop/remove the transient unit before a later supported integration restart if Docker Desktop does not replace it cleanly.

## Post-Recovery Validation

Run all generic checks:

```bash
test -x /usr/bin/docker
test -S /var/run/docker.sock
docker context show
docker version --format 'client={{.Client.Os}}/{{.Client.Arch}} server={{.Server.Os}}/{{.Server.Arch}}'
curl --fail --silent --show-error --max-time 5 --unix-socket /var/run/docker.sock http://localhost/_ping
docker info --format 'name={{.Name}} os={{.OperatingSystem}} driver={{.Driver}}'
```

Then run the closest project-owned Docker/Container validation rather than a generic hello-world image. Examples include an existing image build, Container test, or Workerd Harness recipe. Report separately:

- WSL host channel state;
- Windows Docker Engine state;
- Linux Unix-socket integration state;
- project validation command and result;
- whether recovery is supported/persistent or an emergency transient proxy;
- remaining failures unrelated to Docker.

## Failure Handling

- If a Windows-side tool call fails after one corrected retry and user action is required, follow the always-on Human Assist Protocol and call builtin `ask` rather than repeatedly issuing the same command.
- If `wsl.exe --shutdown` is required, state that it terminates the current Agent session and preserve exact next validation commands.
- If Windows Engine works but normal WSL integration repeatedly fails, capture the precise current `wslErrorCode` and Docker Desktop version before proposing upgrades, resets, reinstalls, or data-destructive actions.
- Never claim Docker recovery from process presence alone; require Linux socket and project-level evidence.
