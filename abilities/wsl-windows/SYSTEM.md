---
slot: tool_usage
priority: 75
---

#### Windows Command Protocol From WSL2

Purpose: route Windows-side commands and GUI launches through the WSL-to-Windows bridge.

Rules:

- Use `run(scope="win")` for Windows CLI commands, builds, and tests.
- Supply executable `command` plus literal `args` array for native execution; omitted/null `args` sends a command string to Windows cmd.exe. Use explicit PowerShell executable/argv for PowerShell syntax.
- Use `opts='{"detach":true}'` for Windows GUI applications and independent background processes; `opts='{"async":true}'` uses the shared `wait`/`kill` lifecycle. Windows opts accept only boolean/null `async` and `detach`, not both true; no PTY or GUI-specific flag.
- `cwd` defaults to exact Chat project root; relative paths resolve there. The bridge converts WSL cwd, preserves Windows drive/UNC cwd, and never converts command/argument values. Native argv supports accessible UNC cwd; cmd-string mode rejects UNC before execution.
- Load `wsl-windows` when detailed Windows/WSL path, command, GUI, service, or troubleshooting guidance is needed.
