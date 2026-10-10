<#
.SYNOPSIS
Configure Windows-side prerequisites for WSL + Windows interoperability.

.DESCRIPTION
Run from an elevated Administrator PowerShell when Windows-side changes are needed.
The script can write WSL mirrored networking configuration, enable Windows OpenSSH,
open firewall ports for Windows/WSL SSH, and optionally configure an NSSM-based WSL
keepalive service. Use -WhatIf first to preview changes.

.PARAMETER DistroName
Target WSL distribution name, as shown by wsl.exe -l -v.

.PARAMETER WslSshPort
WSL sshd port to allow through firewall. Defaults to 2222.

.PARAMETER WindowsUserProfile
Windows user profile that owns the .wslconfig file. Defaults to $env:USERPROFILE.

.PARAMETER ConfigureWslConfig
Write mirrored networking settings to .wslconfig.

.PARAMETER ConfigureWindowsOpenSSH
Install/enable Windows OpenSSH services.

.PARAMETER ConfigureFirewall
Create or update inbound firewall rules for TCP 22 and the WSL SSH port.

.PARAMETER ConfigureKeepAlive
Create an NSSM service that starts the target WSL distro at Windows boot.

.PARAMETER NssmPath
Path to nssm.exe, required when ConfigureKeepAlive is used.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-windows-admin.ps1 -DistroName Ubuntu-24.04 -ConfigureWslConfig -ConfigureFirewall -WhatIf
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$true)] [string] $DistroName,
  [int] $WslSshPort = 2222,
  [string] $WindowsUserProfile = $env:USERPROFILE,
  [switch] $ConfigureWslConfig,
  [switch] $ConfigureWindowsOpenSSH,
  [switch] $ConfigureFirewall,
  [switch] $ConfigureKeepAlive,
  [string] $NssmPath,
  [string] $KeepAliveServiceName = 'WSL_KeepAlive'
)

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
  if (-not (Test-IsAdmin)) {
    throw 'This script must be run from an elevated Administrator PowerShell for selected operations.'
  }
}

function Ensure-WslConfig {
  param([string] $Profile)
  $path = Join-Path $Profile '.wslconfig'
  $content = @'
[wsl2]
networkingMode=mirrored
autoProxy=true
dnsTunneling=true

[experimental]
autoMemoryReclaim=gradual
'@
  if ($PSCmdlet.ShouldProcess($path, 'write WSL2 mirrored networking config')) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { throw "Windows user profile not found: $dir" }
    if (Test-Path $path) { Copy-Item -LiteralPath $path -Destination "$path.bak.$(Get-Date -Format yyyyMMddHHmmss)" -Force }
    Set-Content -LiteralPath $path -Value $content -Encoding UTF8
  }
}

function Ensure-OpenSSH {
  Ensure-Admin
  if ($PSCmdlet.ShouldProcess('Windows OpenSSH Server', 'install capability if missing')) {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -ne 'Installed') {
      Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Host
    }
  }
  foreach ($svc in 'sshd','ssh-agent') {
    if ($PSCmdlet.ShouldProcess($svc, 'set startup automatic and start')) {
      Set-Service -Name $svc -StartupType Automatic
      Start-Service -Name $svc -ErrorAction SilentlyContinue
    }
  }
}

function Ensure-Firewall {
  Ensure-Admin
  $rules = @(
    @{ Name='OpenSSH SSH Server (sshd)'; Port=22; Program='%SystemRoot%\system32\OpenSSH\sshd.exe' },
    @{ Name='WSL2 SSH'; Port=$WslSshPort; Program=$null }
  )
  foreach ($rule in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if ($existing) {
      if ($PSCmdlet.ShouldProcess($rule.Name, 'enable existing firewall rule')) {
        Enable-NetFirewallRule -DisplayName $rule.Name | Out-Null
      }
      continue
    }
    if ($PSCmdlet.ShouldProcess($rule.Name, "create inbound TCP allow rule on port $($rule.Port)")) {
      $params = @{
        DisplayName = $rule.Name
        Direction = 'Inbound'
        Action = 'Allow'
        Protocol = 'TCP'
        LocalPort = $rule.Port
        Profile = 'Any'
      }
      if ($rule.Program) { $params.Program = $rule.Program }
      New-NetFirewallRule @params | Out-Null
    }
  }
}

function Resolve-NssmPath {
  param([string] $PathFromArg)
  $candidates = @()
  if ($PathFromArg) { $candidates += $PathFromArg }
  $cmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
  if ($cmd) { $candidates += $cmd.Source }
  $candidates += @(
    "$env:USERPROFILE\scoop\apps\nssm\current\nssm.exe",
    "$env:ProgramFiles\nssm\win64\nssm.exe",
    "$env:ProgramFiles\nssm\win32\nssm.exe"
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) { return (Resolve-Path $candidate).Path }
  }
  return $null
}

function Ensure-KeepAlive {
  Ensure-Admin
  $resolvedNssm = Resolve-NssmPath -PathFromArg $NssmPath
  if (-not $resolvedNssm) {
    throw 'NSSM not found. Install NSSM or pass -NssmPath C:\path\to\nssm.exe, then rerun.'
  }
  $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
  $params = "-d $DistroName -e sh -c `"sleep infinity`""
  $svc = Get-Service -Name $KeepAliveServiceName -ErrorAction SilentlyContinue
  if (-not $svc) {
    if ($PSCmdlet.ShouldProcess($KeepAliveServiceName, 'install NSSM keepalive service')) {
      & $resolvedNssm install $KeepAliveServiceName $wsl | Out-Host
    }
  }
  if ($PSCmdlet.ShouldProcess($KeepAliveServiceName, 'configure NSSM service parameters')) {
    & $resolvedNssm set $KeepAliveServiceName Application $wsl | Out-Host
    & $resolvedNssm set $KeepAliveServiceName AppParameters $params | Out-Host
    & $resolvedNssm set $KeepAliveServiceName AppDirectory (Split-Path -Parent $wsl) | Out-Host
    & $resolvedNssm set $KeepAliveServiceName AppExit Default Restart | Out-Host
    Set-Service -Name $KeepAliveServiceName -StartupType Automatic
    Start-Service -Name $KeepAliveServiceName -ErrorAction SilentlyContinue
  }
}

Write-Host "Target distro: $DistroName"
Write-Host "Windows user profile for .wslconfig: $WindowsUserProfile"
Write-Host "WSL SSH port: $WslSshPort"

if ($ConfigureWslConfig) { Ensure-WslConfig -Profile $WindowsUserProfile }
if ($ConfigureWindowsOpenSSH) { Ensure-OpenSSH }
if ($ConfigureFirewall) { Ensure-Firewall }
if ($ConfigureKeepAlive) { Ensure-KeepAlive }

Write-Host 'Done. If .wslconfig changed, run: wsl.exe --shutdown, then reopen WSL.'
