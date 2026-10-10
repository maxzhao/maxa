# Fresh Windows + WSL Bootstrap Guide

Purpose: guide an Agent through recreating Windows + WSL capabilities: WSL starts/keeps alive as needed, Windows↔WSL ports work, and both Windows and WSL OpenSSH can be reached remotely. Supports two routes: configure a fresh distro, or import an existing WSL distro and repair missing Windows-side integration.

Core rule: detect first, choose route, execute in phases. Do not assume Administrator rights, the bridge required by `run(scope="win")`, NSSM, mirrored networking, or systemd exist. A WSL import does not carry Windows services, firewall rules, or `.wslconfig`.

Agent invocation uses `load(target="wsl-windows")` and titled `run(scope="tool")` with cataloged commands and literal string-array `args`. References use `#wsl-windows[/references/...]`. The `sudo` and Administrator PowerShell blocks below are explicit human/admin exceptions: resolve script locations from the loaded Ability root, and do not assume `scripts/` belongs to the user's project. Tool dispatch grants no elevation; an already-authorized root executor may invoke `@wsl-windows:/scripts/bootstrap-wsl-side.sh` with the same literal options, as shown in the root guide.

## 0. Read-Only Audit First

When the user asks to configure or migrate Windows + WSL, first invoke:

```yaml
run:
  title: "Audit Windows WSL environment"
  scope: tool
  command: "@wsl-windows:/scripts/audit-wsl-windows-readiness.sh"
  args: []
```

Classify audit output:

- Route: fresh distro vs imported existing distro.
- WSL can call `powershell.exe` / `wsl.exe`.
- WSL supports systemd; `/etc/wsl.conf` has `[boot] systemd=true`.
- Windows `%USERPROFILE%\.wslconfig` has `networkingMode=mirrored`, `dnsTunneling=true`, `autoProxy=true`.
- Windows `sshd` and `ssh-agent` are enabled and auto-starting.
- WSL `ssh.service` is installed/enabled/active.
- Windows Firewall allows TCP 22 and WSL SSH port, default 2222.
- Keepalive exists: Windows NSSM `WSL_KeepAlive`, or WSL `wsl-keepalive.service`.

Audit is read-only. Do not modify config in this step.

## 1. Route Selection

### Route A: Fresh WSL Distro

Use when the user wants a clean distro and only needs runtime capabilities: networking, SSH, systemd, keepalive, and later dependency installation.

Proceed with:

1. User/admin Windows-side preparation.
2. Required WSL restart.
3. Agent WSL-side configuration.
4. Verification.

### Route B: Export/Import Existing Distro

Use when the user wants to preserve existing WSL packages, home directory, dotfiles, services, and caches.

Imported content includes:

- Linux filesystem: `/home`, `/etc`, `/usr`, `/var`.
- apt/pip/npm/cargo/go dependencies and caches inside WSL.
- `/etc/wsl.conf`, `/etc/ssh/sshd_config`, systemd units, shell config.
- Linux users, `authorized_keys`, SSH host keys, private keys, tokens, credentials, login states.

Imported content does not include:

- Windows `%USERPROFILE%\.wslconfig`.
- Windows OpenSSH service and `C:\ProgramData\ssh` config.
- Windows Firewall rules.
- NSSM and `WSL_KeepAlive` Windows service.
- Windows toolchains, PATH, scheduled tasks, registry, runwingui Windows server dependencies.
- Windows Terminal settings and default WSL distro choice.

After import, still run Windows-side preparation and audit verification.

## 2. Route B: Export/Import Procedure

### 2.1 Source Machine Export

Estimate size:

```bash
df -hT /
du -shx /
```

Find VHDX path/size from Windows PowerShell:

```powershell
Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss | ForEach-Object {
  $p = Get-ItemProperty $_.PsPath
  $v = Join-Path $p.BasePath 'ext4.vhdx'
  if (Test-Path $v) { Get-Item $v | Select-Object FullName,Length,LastWriteTime }
}
```

User runs export in Windows PowerShell. `wsl.exe --shutdown` terminates current WSL sessions; do not run it from the active Agent session unless the user explicitly accepts interruption.

```powershell
wsl.exe -l -v
wsl.exe --shutdown
wsl.exe --export Ubuntu-24.04 D:\backup\Ubuntu-24.04.tar
```

Default to tar export for compatibility. Use VHD export only when the user requests it and target WSL supports it.

### 2.2 Sensitive Data Decision

Export contains private keys, tokens, cookies, git/gh/aws/npm/pip credentials, login states, and SSH host keys. Ask the migration purpose first:

| Destination | Default handling |
| --- | --- |
| User's own new machine | Usually keep; tell user to encrypt/store backup safely. |
| Template for others | Do not export the personal environment directly; clean secrets or use Route A. |

Do not delete or clean secrets before the user confirms purpose. If building a shareable template, provide a cleanup checklist and SSH host-key regeneration steps.

### 2.3 Target Import Directory

`wsl.exe --import` requires an explicit install directory. It does not use Store Ubuntu's default directory and does not automatically become default.

Do not import into Store-managed `LocalState`, such as:

```text
C:\Users\<WindowsUser>\AppData\Local\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc\LocalState
```

Recommended user-managed locations:

```powershell
$Distro = "Ubuntu-24.04"
$InstallDir = "$env:LOCALAPPDATA\wsl\$Distro"
New-Item -ItemType Directory -Force $InstallDir
wsl.exe --import $Distro $InstallDir D:\backup\Ubuntu-24.04.tar --version 2
wsl.exe --set-default $Distro
wsl.exe -l -v
```

or:

```powershell
$Distro = "Ubuntu-24.04"
$InstallDir = "D:\WSL\$Distro"
New-Item -ItemType Directory -Force $InstallDir
wsl.exe --import $Distro $InstallDir D:\backup\Ubuntu-24.04.tar --version 2
wsl.exe --set-default $Distro
```

Confirm `wsl.exe -l -v` shows `*` before the target distro.

### 2.4 Replace Default Distro / Same-Name Import

Clarify semantics: WSL has no in-place container overwrite; default distro is a registry setting. To replace an old default distro, unregister old data only after backup confirmation.

```powershell
wsl.exe -l -v
wsl.exe --shutdown

# Dangerous: deletes old distro data. Require confirmed backup first.
wsl.exe --unregister Ubuntu

$Distro = "Ubuntu"
$InstallDir = "$env:LOCALAPPDATA\wsl\$Distro"
New-Item -ItemType Directory -Force $InstallDir
wsl.exe --import $Distro $InstallDir D:\backup\Ubuntu-24.04.tar --version 2
wsl.exe --set-default $Distro
wsl.exe -l -v
```

If the old distro is Store `Ubuntu`, do not reuse its `...\Packages\CanonicalGroupLimited.Ubuntu_...\LocalState`. Use `%LOCALAPPDATA%\wsl\Ubuntu` or `D:\WSL\Ubuntu`.

If the user wants to keep old Store Ubuntu, import under a new name and set default:

```powershell
$Distro = "Ubuntu-24.04"
$InstallDir = "$env:LOCALAPPDATA\wsl\$Distro"
New-Item -ItemType Directory -Force $InstallDir
wsl.exe --import $Distro $InstallDir D:\backup\Ubuntu-24.04.tar --version 2
wsl.exe --set-default $Distro
```

### 2.5 Imported Default User

If import enters root, check:

```bash
cat /etc/wsl.conf
```

`[user] default=<linux-user>` is the WSL Linux user, not the Windows user. After edit, user must run in Windows PowerShell:

```powershell
wsl.exe --shutdown
```

### 2.6 Post-Import Gap Repair

After import and a new Agent session, load `wsl-windows` again and invoke:

```yaml
run:
  title: "Audit imported WSL gaps"
  scope: tool
  command: "@wsl-windows:/scripts/audit-wsl-windows-readiness.sh"
  args: []
```

Repair only gaps found by audit:

1. Missing `.wslconfig` / mirrored networking: user runs Windows-side script.
2. Windows `sshd` / `ssh-agent` disabled: user enables in Administrator PowerShell.
3. Firewall lacks TCP 22 / WSL SSH port: user creates rules in Administrator PowerShell.
4. No keepalive: ask whether needed. Use NSSM for Windows-boot auto-start; use WSL `wsl-keepalive.service` only for keeping WSL alive after manual start.
5. WSL `ssh.service` inactive: Agent may repair/restart inside WSL.
6. Imported `/etc/wsl.conf` or `sshd_config` healthy: do not overwrite without evidence.

Windows admin script example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/bootstrap-windows-admin.ps1 `
  -DistroName Ubuntu-24.04 `
  -WslSshPort 2222 `
  -ConfigureWslConfig `
  -ConfigureWindowsOpenSSH `
  -ConfigureFirewall `
  -ConfigureKeepAlive `
  -NssmPath C:\path\to\nssm.exe
```

For imported WSL config repair, dry-run first:

```bash
sudo bash scripts/bootstrap-wsl-side.sh --ssh-port 2222 --default-user "$USER"
```

Add `--apply` only after confirming planned changes are correct.

## 3. User / Administrator Phase

These actions usually require Windows UAC, Administrator rights, WSL restart, or operations that terminate the current session.

### 3.1 Version Support

Agent may detect:

```bash
powershell.exe -NoProfile -Command "wsl.exe --version; wsl.exe --status"
```

If `wsl --version` is unavailable or too old for mirrored networking/systemd, instruct the user to update WSL/Windows first.

### 3.2 Administrator PowerShell

Tell the user to open PowerShell as Administrator for:

- Install/enable Windows OpenSSH Server.
- Set `sshd` and `ssh-agent` to automatic and start them.
- Add Windows Firewall inbound rules.
- Optional: create Windows service for WSL boot keepalive.
- Optional: install or provide NSSM path.

### 3.3 Windows Admin Script

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/bootstrap-windows-admin.ps1 `
  -DistroName Ubuntu-24.04 `
  -WslSshPort 2222 `
  -ConfigureWslConfig `
  -ConfigureWindowsOpenSSH `
  -ConfigureFirewall `
  -ConfigureKeepAlive `
  -NssmPath C:\path\to\nssm.exe
```

Parameter notes:

- `-DistroName`: target distro from `wsl.exe -l -v`.
- `-WslSshPort`: WSL SSH port; default/recommended 2222 to avoid Windows SSH port 22 conflict.
- `-ConfigureWslConfig`: write `.wslconfig` for the target Windows user.
- `-WindowsUserProfile`: required when Administrator account differs from target normal user, e.g. `C:\Users\alice`.
- `-ConfigureWindowsOpenSSH`: enable Windows OpenSSH service.
- `-ConfigureFirewall`: allow TCP 22 and WSL SSH port.
- `-ConfigureKeepAlive`: optional NSSM `WSL_KeepAlive`; require user confirmation.
- `-NssmPath`: NSSM executable path; script should not force network download.

Prefer dry-run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/bootstrap-windows-admin.ps1 `
  -DistroName Ubuntu-24.04 -ConfigureWindowsOpenSSH -ConfigureFirewall -ConfigureWslConfig -WhatIf
```

### 3.4 Required WSL Restart

After `.wslconfig` or `/etc/wsl.conf` changes, user runs:

```powershell
wsl.exe --shutdown
```

Then reopen Neovim/Agent and continue. Do not run this from the active session by default.

## 4. Agent WSL-Side Phase

Prerequisite: user completed admin steps and restarted WSL; current WSL user has sudo access or can provide sudo password.

Keepalive is not default. Ask first and let user choose:

- Windows NSSM service: auto-start WSL at Windows boot and keep it alive.
- WSL systemd keepalive: after manual WSL start, keep tmux/services alive after shell exit.

### 4.1 Configure systemd, default user, SSH

```bash
sudo bash scripts/bootstrap-wsl-side.sh --apply --ssh-port 2222 --default-user "$USER"
```

Options:

- `--apply`: write changes; omit for plan-only.
- `--ssh-port`: WSL sshd port, default 2222.
- `--default-user`: Linux user for `/etc/wsl.conf`; not Windows user.
- `--authorized-key-file`: append public key to current user's `~/.ssh/authorized_keys`.
- `--permit-root no|prohibit-password|yes`: root SSH policy; prefer `no` or `prohibit-password`.

Script actions:

- Back up `/etc/wsl.conf` and `/etc/ssh/sshd_config`.
- Ensure `[boot] systemd=true`.
- Install `openssh-server` on Debian/Ubuntu when apt is available.
- Configure sshd port, public-key auth, password auth disabled.
- Enable/start `ssh.service`.
- Fix `~/.ssh` and `authorized_keys` permissions.

### 4.2 Verification

```yaml
run:
  title: "Verify configured WSL readiness"
  scope: tool
  command: "@wsl-windows:/scripts/audit-wsl-windows-readiness.sh"
  args: []
```

Then use the normal platform command tools for system-owned checks, not invented Ability targets:

```bash
systemctl is-enabled ssh
systemctl is-active ssh
ss -ltnp | grep ':2222'
powershell.exe -NoProfile -Command "Test-NetConnection -ComputerName 127.0.0.1 -Port 2222"
```

If `Test-NetConnection` fails, check:

- WSL restarted after mirrored networking change.
- Windows Firewall allows WSL SSH port.
- WSL sshd listens on `0.0.0.0:<port>`.
- `.wslconfig` was written to the correct Windows user profile.

## 5. Agent Boundaries

Agent may execute:

- WSL-side audit.
- WSL-side `/etc/wsl.conf` and sshd config with sudo.
- WSL service enable/start.
- Generate Windows admin commands for the user.
- Guide `wsl --export` / `wsl --import` migration.
- Verify after user admin/import steps.

Agent must not do by default:

- Run `wsl.exe --shutdown` in the current session.
- Create Windows NSSM `WSL_KeepAlive` or WSL `wsl-keepalive.service` without user confirmation.
- Perform UAC-required Windows admin operations directly.
- Open public firewall exposure or relax SSH root login without user confirmation.
- Download NSSM or other binaries without user-approved source/path.
- Delete private keys, tokens, cookies, git/gh/aws/npm/pip credentials, or SSH host keys before confirming migration purpose.

## 6. Target State

Windows `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
autoProxy=true
dnsTunneling=true

[experimental]
autoMemoryReclaim=gradual
```

WSL `/etc/wsl.conf`:

```ini
[boot]
systemd=true

[user]
default=<linux-user>

[interop]
enabled=true
appendWindowsPath=true

[automount]
enabled=true
options=metadata
```

Expected services:

- Windows OpenSSH: `sshd` and `ssh-agent` running and automatic; TCP 22 allowed.
- WSL OpenSSH: `ssh.service` enabled/active; TCP 2222; public-key auth enabled; password auth disabled.
- Optional keepalive after user confirmation:
  - Windows NSSM `WSL_KeepAlive`: starts `wsl.exe -d <DistroName> -e sh -c "sleep infinity"` at Windows boot.
  - WSL `wsl-keepalive.service`: runs `/usr/bin/sleep infinity` after WSL is manually started.
