#!/usr/bin/env bash
set -u

usage() {
  cat <<'EOF'
Usage: bash scripts/audit-wsl-windows-readiness.sh [--help]

Read-only audit for WSL + Windows interoperability readiness.
It prints current WSL basics, /etc/wsl.conf, SSH service/config, WSL network,
Windows interop availability, selected Windows services, firewall rules, and
listen/test port status when powershell.exe is available.

Options:
  -h, --help    Show this help and exit
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    printf 'ERROR: unknown argument: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

section() { printf '\n=== %s ===\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 || true; }

section "WSL basic"
printf 'user=%s\n' "${USER:-}"
printf 'distro=%s\n' "${WSL_DISTRO_NAME:-}"
uname -a 2>/dev/null || true
printf 'pid1='; ps -p 1 -o comm= 2>/dev/null || true
printf 'systemd='; systemctl is-system-running 2>/dev/null || true

section "WSL config"
if [[ -f /etc/wsl.conf ]]; then
  grep -Ev '^[[:space:]]*(#|$)' /etc/wsl.conf || true
else
  echo 'MISSING /etc/wsl.conf'
fi

section "WSL ssh"
if command -v sshd >/dev/null 2>&1; then
  sshd -V 2>&1 || true
else
  echo 'sshd missing'
fi
if [[ -f /etc/ssh/sshd_config ]]; then
  grep -Ev '^[[:space:]]*(#|$)' /etc/ssh/sshd_config || true
else
  echo 'MISSING /etc/ssh/sshd_config'
fi
printf 'ssh enabled='; systemctl is-enabled ssh 2>/dev/null || true
printf 'ssh active='; systemctl is-active ssh 2>/dev/null || true
ss -ltnp 2>/dev/null | awk 'NR==1 || /:(22|2222) /' || true

section "WSL network"
ip -br addr 2>/dev/null || true
ip route 2>/dev/null | sed -n '1,20p' || true

section "Windows interop"
if command -v powershell.exe >/dev/null 2>&1; then
  echo 'powershell.exe available'
else
  echo 'powershell.exe not found from WSL PATH'
fi
if command -v wsl.exe >/dev/null 2>&1; then
  echo 'wsl.exe available'
else
  echo 'wsl.exe not found from WSL PATH'
fi

if command -v powershell.exe >/dev/null 2>&1; then
  section "Windows WSL config and status"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
    $ErrorActionPreference="SilentlyContinue"
    "userprofile=$env:USERPROFILE"
    "--- wsl --version"; wsl.exe --version
    "--- wsl -l -v"; wsl.exe -l -v
    "--- .wslconfig active"; $p=Join-Path $env:USERPROFILE ".wslconfig"; if(Test-Path $p){ Get-Content -LiteralPath $p | ? { $_ -notmatch "^\s*(#|$)" } } else { "MISSING $p" }
  ' 2>&1 | sed 's/\r$//' || true

  section "Windows services"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
    $ErrorActionPreference="SilentlyContinue"
    Get-CimInstance Win32_Service | ? { $_.Name -in "WSL_KeepAlive","sshd","ssh-agent","LxssManager","WinNAT","iphlpsvc" } | % { "{0}|{1}|{2}|{3}" -f $_.Name,$_.State,$_.StartMode,$_.PathName }
  ' 2>&1 | sed 's/\r$//' || true

  section "Windows firewall focus"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
    $ErrorActionPreference="SilentlyContinue"
    foreach($r in Get-NetFirewallRule -Direction Inbound | ? { $_.DisplayName -match "ssh|OpenSSH|WSL|2222" -or $_.Name -match "ssh|OpenSSH|WSL|2222" }){
      $pf=$r|Get-NetFirewallPortFilter
      "{0}|Enabled={1}|Action={2}|Profile={3}|Protocol={4}|Port={5}" -f $r.DisplayName,$r.Enabled,$r.Action,$r.Profile,$pf.Protocol,$pf.LocalPort
    }
  ' 2>&1 | sed 's/\r$//' || true

  section "Windows listen/test ports"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
    $ErrorActionPreference="SilentlyContinue"
    Get-NetTCPConnection -State Listen | ? { $_.LocalPort -in 22,2222,19527 } | sort LocalPort,LocalAddress | % { $p=(Get-Process -Id $_.OwningProcess).ProcessName; "{0}:{1}|pid={2}|{3}" -f $_.LocalAddress,$_.LocalPort,$_.OwningProcess,$p }
    foreach($port in 22,2222){ $r=Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue; "127.0.0.1:$port TcpTestSucceeded=$($r.TcpTestSucceeded)" }
  ' 2>&1 | sed 's/\r$//' || true
fi
