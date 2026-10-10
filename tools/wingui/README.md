# WinGUI Bridge

Maxa-owned WSL2 → Windows CLI/GUI bridge. Source lives only in `tools/wingui/`; Windows Python executes `server.py` directly through the WSL UNC filesystem.

## Runtime ownership

- `runwingui`: WSL entrypoint, resolves its own source directory and runs `client.py` through this uv project.
- `client.py`: HTTP/SSE client; preserves literal argv and process results.
- `server.py`: Windows service, standard-library-only Python >=3.10; native process/GUI launch, deadlines, output and process-tree cancellation.
- Windows generated launcher: `%LOCALAPPDATA%\Maxa\wingui\start-server.bat`; contains only local `pythonw.exe` and the authoritative source path, never a source copy. Explorer starts this local launcher in the interactive desktop session. `cwd` is Windows `%TEMP%`, not UNC.
- Default endpoint: `127.0.0.1:19527`. Source changes apply after restarting the Windows service; client/launcher edits apply on the next invocation.
- Virtual environments, bytecode and generated launchers are runtime data, not tracked source. Do not import a nested Git repository.

## Invocation

From another project, use the installed `runwingui` PATH entry. From this monorepo, the equivalent entry is `tools/wingui/runwingui`.

```bash
runwingui --strict --cwd 'C:\Projects' -- tool.exe '' 'argument with spaces'
runwingui --strict --cwd 'C:\Projects' --shell -- 'dir && echo done'
runwingui --strict --detach --cwd 'C:\Windows' -- notepad.exe
runwingui --health
runwingui --list
runwingui --kill <remote-id>
runwingui --start-server
runwingui --stop-server
runwingui --restart-server
```

Bridge options precede the executable or `--`; target argv remains opaque. Chat Agents use `run(scope="win")` under the `wsl-windows` Ability contract rather than adding a second Windows tool. Setup: [README_SETUP.md](./README_SETUP.md).

## Validation and failure handling

- Static: `bash -n tools/wingui/runwingui`; use this uv project for Python syntax checks.
- After startup changes: restart only when no unrelated managed processes need preservation; check health, one native argv call and actual GUI launch. Preserve the existing monitored/async/detach API.
- UNC .bat files trigger Windows security confirmation; generate a local launcher instead. Do not disable security prompts or alter trusted zones.
- Missing uv/Windows Python, inaccessible UNC source or absent interactive desktop session: report the exact failure and request the missing setup/access. Do not copy the service to Windows to manufacture a second source owner.
