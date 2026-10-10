# Obscura WSL2 One-Time Setup

Purpose: install and verify Obscura in WSL2 for `browser_start(mode="standard")`. Ordinary web-access tasks should use `read(path="#browser[/references/browser-backends.md]")`, not this setup guide.

Prerequisite: `load(target="browser")` before MCP calls. Shell examples here are explicit manual installation, platform checks, or maintenance diagnostics, not cataloged Ability scripts. Keep executable/storage paths as physical paths; resolve placeholders before execution.

## Positioning

Obscura is a Chrome DevTools Protocol (CDP) headless browser engine usable through Playwright/Puppeteer CDP connections. In this Ability it is an optional external CDP backend, not a required dependency.

Constraints:

- Do not make Obscura mandatory for `browser`.
- Do not change `tauri_connect` semantics.
- Install under user-level paths; avoid system directories.
- External Obscura processes are owned by their starter. Connectors disconnect only and must not kill unrelated external processes.

## Install From Release

Preferred for WSL2 x86_64 Linux: GitHub release binary. Use source build only if release assets do not fit the environment.

Recommended paths:

```bash
~/.local/bin/obscura
~/.local/bin/obscura-worker
~/.local/share/obscura
```

Install:

```bash
set -euo pipefail

version="v0.1.7"
asset="obscura-x86_64-linux.tar.gz"
url="https://github.com/h4ckf0r0day/obscura/releases/download/${version}/${asset}"
workdir="$(mktemp -d)"

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/obscura"
cd "$workdir"

# Mainland China usually needs proxy for GitHub.
curl -L --proxy socks5://127.0.0.1:10808 -o "$asset" "$url"
tar -xzf "$asset"
install -m 0755 obscura "$HOME/.local/bin/obscura"
install -m 0755 obscura-worker "$HOME/.local/bin/obscura-worker"

"$HOME/.local/bin/obscura" --version || true
"$HOME/.local/bin/obscura" --help | sed -n '1,80p'
```

Fallback source build:

```bash
git clone https://github.com/h4ckf0r0day/obscura.git
cd obscura
cargo build --release --features stealth
```

Source build requires Rust 1.75+ and may take a long time because of V8.

## PATH Check

```bash
command -v obscura
obscura --help | sed -n '1,80p'
```

If missing from PATH, use the full path:

```bash
$HOME/.local/bin/obscura --help
```

Do not assume identical PATH across projects or machines.

## CDP Verification

Use a non-default port to avoid `9222` conflicts:

```bash
port=9223
obscura serve --port "$port" --stealth > /tmp/obscura-${port}.log 2>&1 &
echo $! > /tmp/obscura-${port}.pid

curl -fsS "http://127.0.0.1:${port}/json/version"
curl -fsS "http://127.0.0.1:${port}/json/list"
```

Expected `/json/version` fields:

```json
{
  "Browser": "Chrome/...",
  "Protocol-Version": "1.3",
  "webSocketDebuggerUrl": "ws://127.0.0.1:9223/devtools/browser"
}
```

## MCP Tool Verification

After MCPHub restart/schema refresh, call `load(target="browser", force_reload=true)` to refresh this Chat's catalog. Prefer unified lifecycle over handwritten Playwright scripts or legacy `obscura_start` daily usage:

```yaml
run:
  title: "Verify standard browser backend"
  scope: tool
  command: "@browser:browser_start"
  args: '{"mode":"standard","executablePath":"/absolute/path/to/obscura","port":9223,"connect":true}'
```

Expected:

```json
{
  "status": "ready",
  "mode": "standard",
  "connected": true,
  "smoke": { "ok": true }
}
```

`smoke.ok = true` means the toolchain can execute JS and read rendered results. Optional manual follow-up: `navigate` / `evaluate`. Cleanup:

```yaml
run: {title: "Stop verified browser backend", scope: tool, command: "@browser:browser_stop", args: '{}'}
```

`obscura_start/status/stop` may remain maintainer diagnostics for the standard backend, but ordinary Agents should use unified browser lifecycle.

## Stop Verification Process

```bash
if [ -f /tmp/obscura-9223.pid ]; then
  kill "$(cat /tmp/obscura-9223.pid)" 2>/dev/null || true
fi
```

Port check:

```bash
curl -fsS http://127.0.0.1:9223/json/version >/dev/null \
  && echo "still running" \
  || echo "stopped"
```

## Upgrade / Uninstall

Upgrade: repeat release install and overwrite `~/.local/bin/obscura` and `~/.local/bin/obscura-worker`.

Uninstall:

```bash
rm -f "$HOME/.local/bin/obscura" "$HOME/.local/bin/obscura-worker"
```

Only delete caches clearly owned by Obscura. Do not clean shared project or system directories.

## Troubleshooting

| Symptom | Response |
| --- | --- |
| GitHub download slow/fails | Use proxy: `curl -L --proxy socks5://127.0.0.1:10808 -o obscura-x86_64-linux.tar.gz <release-url>` |
| Port occupied | Use another port such as `9223` or `9333`; do not blindly kill unknown processes. |
| `/json/version` missing | Check process, log, port, firewall/proxy effects. |
| Need standard backend | Use `run(title="Start standard backend", scope="tool", command="@browser:browser_start", args='{"mode":"standard"}')`, not `tauri_connect`. |
| Need existing external CDP endpoint | Use `run(title="Connect external CDP", scope="tool", command="@browser:cdp_connect", args='{"endpoint":"http://127.0.0.1:9223"}')`. |

After connection, use normal browser tools such as `navigate`, `content`, `evaluate`, `screenshot`, and `snapshot`.
