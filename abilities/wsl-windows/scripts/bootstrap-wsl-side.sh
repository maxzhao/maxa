#!/usr/bin/env bash
set -euo pipefail

APPLY=0
SSH_PORT=2222
DEFAULT_USER="${SUDO_USER:-${USER:-}}"
AUTHORIZED_KEY_FILE=""
PERMIT_ROOT="prohibit-password"

usage() {
  cat <<'USAGE'
Usage: sudo bash scripts/bootstrap-wsl-side.sh [options]

Configure WSL-side systemd and OpenSSH for Windows/WSL remote access.
Default mode is dry-run. Pass --apply to write changes.

Options:
  --apply                         Write files and run service commands
  --ssh-port PORT                 WSL sshd port (default: 2222)
  --default-user USER             Linux user for /etc/wsl.conf [user] default
  --authorized-key-file PATH      Append public key file to target user's authorized_keys
  --permit-root VALUE             no | prohibit-password | yes (default: prohibit-password)
  -h, --help                      Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --default-user) DEFAULT_USER="$2"; shift 2 ;;
    --authorized-key-file) AUTHORIZED_KEY_FILE="$2"; shift 2 ;;
    --permit-root) PERMIT_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with sudo/root." >&2
  exit 1
fi

case "$PERMIT_ROOT" in
  no|prohibit-password|yes) ;;
  *) echo "Invalid --permit-root: $PERMIT_ROOT" >&2; exit 2 ;;
esac

TARGET_USER="$DEFAULT_USER"
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "Linux user does not exist: $TARGET_USER" >&2
  exit 1
fi

run() {
  if [[ "$APPLY" == "1" ]]; then
    echo "+ $*"
    "$@"
  else
    echo "[dry-run] $*"
  fi
}

backup_file() {
  local path="$1"
  if [[ -f "$path" && "$APPLY" == "1" ]]; then
    cp -a "$path" "$path.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

write_wsl_conf() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<CONF
[boot]
systemd=true

[user]
default=$TARGET_USER

[interop]
enabled=true
appendWindowsPath=true

[automount]
enabled=true
options=metadata
CONF
  backup_file /etc/wsl.conf
  if [[ "$APPLY" == "1" ]]; then
    install -m 0644 "$tmp" /etc/wsl.conf
  else
    echo "[dry-run] write /etc/wsl.conf:"
    cat "$tmp"
  fi
  rm -f "$tmp"
}

ensure_openssh() {
  if command -v sshd >/dev/null 2>&1; then
    echo "openssh-server already present"
    return
  fi
  if command -v apt-get >/dev/null 2>&1; then
    run apt-get update
    run apt-get install -y openssh-server
  else
    echo "sshd missing and apt-get not found; install openssh-server manually." >&2
    exit 1
  fi
}

configure_sshd() {
  local cfg=/etc/ssh/sshd_config
  backup_file "$cfg"
  if [[ ! -f "$cfg" && "$APPLY" == "1" ]]; then
    touch "$cfg"
  fi
  if [[ "$APPLY" == "1" ]]; then
    python3 - "$cfg" "$SSH_PORT" "$PERMIT_ROOT" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
port = sys.argv[2]
permit_root = sys.argv[3]
lines = path.read_text().splitlines() if path.exists() else []
keys = {
    "Port": f"Port {port}",
    "AddressFamily": "AddressFamily any",
    "ListenAddress": "ListenAddress 0.0.0.0",
    "PermitRootLogin": f"PermitRootLogin {permit_root}",
    "PubkeyAuthentication": "PubkeyAuthentication yes",
    "PasswordAuthentication": "PasswordAuthentication no",
    "KbdInteractiveAuthentication": "KbdInteractiveAuthentication no",
    "UsePAM": "UsePAM yes",
}
seen = set()
out = []
for line in lines:
    stripped = line.strip()
    key = stripped.split(None, 1)[0] if stripped and not stripped.startswith('#') else None
    if key in keys:
        out.append(keys[key])
        seen.add(key)
    else:
        out.append(line)
for key, value in keys.items():
    if key not in seen:
        out.append(value)
path.write_text("\n".join(out).rstrip() + "\n")
PY
  else
    echo "[dry-run] ensure sshd_config: Port=$SSH_PORT ListenAddress=0.0.0.0 PubkeyAuthentication=yes PasswordAuthentication=no PermitRootLogin=$PERMIT_ROOT"
  fi
}

configure_authorized_keys() {
  [[ -n "$AUTHORIZED_KEY_FILE" ]] || return 0
  if [[ ! -f "$AUTHORIZED_KEY_FILE" ]]; then
    echo "authorized key file not found: $AUTHORIZED_KEY_FILE" >&2
    exit 1
  fi
  local home_dir ssh_dir auth_file
  home_dir=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  ssh_dir="$home_dir/.ssh"
  auth_file="$ssh_dir/authorized_keys"
  if [[ "$APPLY" == "1" ]]; then
    install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$ssh_dir"
    touch "$auth_file"
    chown "$TARGET_USER:$TARGET_USER" "$auth_file"
    chmod 0600 "$auth_file"
    grep -qxF "$(cat "$AUTHORIZED_KEY_FILE")" "$auth_file" || cat "$AUTHORIZED_KEY_FILE" >> "$auth_file"
  else
    echo "[dry-run] append $AUTHORIZED_KEY_FILE to $auth_file and set permissions"
  fi
}

enable_ssh_service() {
  run systemctl enable ssh
  run systemctl restart ssh
  run systemctl is-active ssh
}

echo "WSL bootstrap plan: apply=$APPLY user=$TARGET_USER ssh_port=$SSH_PORT permit_root=$PERMIT_ROOT"
write_wsl_conf
ensure_openssh
configure_sshd
configure_authorized_keys
enable_ssh_service

echo "Done. If /etc/wsl.conf changed, run 'wsl.exe --shutdown' from Windows and reopen WSL."
