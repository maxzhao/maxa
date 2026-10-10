#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="maxa-telegram-bridge.service"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
UNIT_PATH="${UNIT_DIR}/${SERVICE_NAME}"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/maxa/telegram-bridge"
LOG_FILE="${STATE_DIR}/service.log"

usage() {
  cat <<'EOF'
Usage: systemd-user-service.sh <command> [args]

Commands:
  install        Install, enable, and start the user systemd service
  uninstall      Stop, disable, and remove the user systemd service
  start          Start the installed service
  stop           Stop the installed service
  restart        Restart the installed service
  status         Show service status and log path
  log [lines]    Tail the file log (default: 100 lines)
  print-unit     Print the generated unit file to stdout

Notes:
  - This is a WSL/Linux user systemd service, not a Windows service.
  - For startup when the WSL distro boots, WSL systemd must be enabled and
    user lingering must be enabled for the target Linux user.
  - Logs are written to:
      ${XDG_STATE_HOME:-$HOME/.local/state}/maxa/telegram-bridge/service.log
EOF
}

fail() {
  echo "❌ $*" >&2
  exit 1
}

require_user_systemd() {
  command -v systemctl >/dev/null 2>&1 || fail "systemctl not found; enable WSL systemd first"
  systemctl --user show-environment >/dev/null 2>&1 || fail "systemd --user is not available for ${USER}; start a systemd-enabled WSL session first"
}

uv_bin() {
  command -v uv || fail "uv not found in PATH; install uv or fix PATH before installing the service"
}

check_linger() {
  if command -v loginctl >/dev/null 2>&1; then
    local linger
    linger="$(loginctl show-user "${USER}" -p Linger --value 2>/dev/null || true)"
    if [[ "${linger}" != "yes" ]]; then
      cat >&2 <<EOF
⚠️  User lingering is not enabled for ${USER}.
   The service can run after login, but may not start automatically when the WSL distro boots.
   To make it start with WSL systemd boot, run:
     sudo loginctl enable-linger ${USER}
EOF
    fi
  fi
}

print_unit() {
  local uv
  uv="$(uv_bin)"
  cat <<EOF
[Unit]
Description=Maxa Telegram Bridge
Documentation=file://${BRIDGE_DIR}/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BRIDGE_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStartPre=/usr/bin/mkdir -p ${STATE_DIR}
ExecStart=${uv} run --project ${BRIDGE_DIR} maxa-telegram-bridge run
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
KillMode=mixed
SendSIGKILL=yes
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
EOF
}

install_service() {
  require_user_systemd
  check_linger
  mkdir -p "${UNIT_DIR}" "${STATE_DIR}"
  print_unit > "${UNIT_PATH}"
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}"
  echo "✅ Installed and started ${SERVICE_NAME}"
  echo "Unit: ${UNIT_PATH}"
  echo "Log:  ${LOG_FILE}"
}

uninstall_service() {
  require_user_systemd
  systemctl --user disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  rm -f "${UNIT_PATH}"
  systemctl --user daemon-reload
  echo "✅ Removed ${SERVICE_NAME}"
  echo "Log retained at: ${LOG_FILE}"
}

kill_bridge_processes() {
  local pids
  pids="$(ps -u "${USER}" -o pid=,args= | awk -v bridge_dir="${BRIDGE_DIR}" '
    index($0, bridge_dir "/.venv/bin/maxa-telegram-bridge run") > 0 { print $1 }
    index($0, "uv run --project " bridge_dir " maxa-telegram-bridge run") > 0 { print $1 }
  ' | tr '\n' ' ')"
  if [[ -n "${pids}" ]]; then
    # shellcheck disable=SC2086
    kill -KILL ${pids} >/dev/null 2>&1 || true
  fi
}

restart_service() {
  require_user_systemd
  if ! timeout 20 systemctl --user stop "${SERVICE_NAME}"; then
    echo "⚠️  ${SERVICE_NAME} did not stop within 20s; killing bridge processes" >&2
    systemctl --user kill --kill-who=all --signal=SIGKILL "${SERVICE_NAME}" >/dev/null 2>&1 || true
    kill_bridge_processes
    timeout 10 systemctl --user stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl --user reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
  fi
  systemctl --user start "${SERVICE_NAME}"
}

show_status() {
  require_user_systemd
  echo "Unit: ${UNIT_PATH}"
  echo "Log:  ${LOG_FILE}"
  systemctl --user status "${SERVICE_NAME}" --no-pager || true
}

tail_log() {
  local lines="${1:-100}"
  echo "Log: ${LOG_FILE}"
  if [[ -f "${LOG_FILE}" ]]; then
    tail -n "${lines}" "${LOG_FILE}"
  else
    echo "No log file found yet. Start the service first: just telegram-bridge-install"
  fi
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    install) install_service ;;
    uninstall) uninstall_service ;;
    start) require_user_systemd; systemctl --user start "${SERVICE_NAME}" ;;
    stop) require_user_systemd; systemctl --user stop "${SERVICE_NAME}" ;;
    restart) restart_service ;;
    status) show_status ;;
    log) tail_log "${1:-100}" ;;
    print-unit) print_unit ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; fail "unknown command: ${command}" ;;
  esac
}

main "$@"
