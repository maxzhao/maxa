---
title: Godot 自动语言工具链行为规格
created: 2026-09-01
updated: 2026-09-15
type: source
doc_role: spec
authority: normative
status: active
validation:
  automated: passed
  human: passed
accepted_at: 2026-09-01
capability: godot-language-tooling
sources:
  - lua/plugins/godot.lua
  - lua/util/godot_lsp/
  - lua/util/godot_shader_lsp.lua
  - lua/util/godot_tools.lua
  - tests/godot_lsp_core_spec.lua
  - tests/godot_lsp_posix_smoke.lua
  - https://docs.godotengine.org/en/stable/tutorials/editor/external_editor.html
  - https://github.com/Dead-Shrimp-Studio/gdshader-lsp-cpp/releases/tag/v0.3.2
confidence: high
---

# Spec: Godot Language Tooling

## Requirements

### Requirement: Project GDScript buffers automatically receive an owned language service

Throughout this contract, root means the nearest ancestor containing `project.godot`, canonicalized to its real normalized directory; no cwd/`.git` fallback. Symlink aliases SHALL share state/process/port/client within this Neovim.

On filetype assignment to a `.gd` file, loaded `gdscript` buffers SHALL automatically receive official Godot LSP:

- No root: no Godot process/client or ordinary-opening failure notification.
- No owned service: asynchronously launch `godot --headless --editor --path <root> --lsp-port <owned-port>`, await readiness without blocking the editor, then start/attach one root-scoped GDScript client.
- Ready service: attach without another process/client.

### Requirement: Owned Godot services are isolated per project and Neovim instance

Each `(Neovim instance, canonical root)` SHALL own at most one headless Godot process group and GDScript client, with independent state and a dynamic port. Roots SHALL NOT mutate each other's lifecycles; same-project Neovims SHALL use distinct processes/ports and may exit without terminating another's service.

The runtime SHALL NOT discover/adopt/reuse/terminate other actors' Godot/LSP processes, including other Neovims and GUI Godot. Even with GUI project LSP available, start the owned headless service/port; never connect to or terminate the GUI service.

### Requirement: Godot startup uses dynamic readiness and safe process-group ownership

The runtime SHALL launch WSL `PATH`'s `godot` in a new POSIX session/process group, allocate a collision-free non-default loopback port and observe exit. Readiness SHALL require cancellable asynchronous TCP readiness, not fixed delays, plus successful native LSP initialization/attachment; TCP alone is insufficient.

- Candidate unavailable before binding with detected startup collision/failure: discard/retry a different bounded candidate; never connect to an unknown listener.
- Exit before readiness/internal readiness timeout: clean owned group/async handles, record bounded exit/stdout/stderr evidence, apply eligible recovery.
- Failed LSP initialization/attachment after TCP readiness: stop the owned generation before recovery/terminal failure.
- Stopping a forking wrapper (e.g. `gdvm`): signal the owned group, not only wrapper PID; leave no wrapper child/owned listener.

### Requirement: Managed services persist until explicit lifecycle termination

Ready owned Godot process/service state SHALL survive closure of all tracked project GDScript buffers. Managed stop SHALL occur only for explicit stop/restart, terminal failed-start cleanup or Neovim exit. Exit SHALL stop every manager-owned LSP client and terminate every owned group with bounded `SIGTERM`, escalating to `SIGKILL` if necessary; no owned process/listening port may remain.

### Requirement: Unexpected exits recover with bounded policy

Unexpected owned process/client loss SHALL clean stale client/process state in the exit callback. With at least one valid loaded project GDScript buffer, automatically start a new owned generation with increasing bounded backoff, at most three consecutive attempts per failure episode, reattaching valid buffers on success. Otherwise clean without restart; a later newly opened project GDScript buffer may start another episode.

After three consecutive automatic failures, latch `failed`, emit one actionable notification and block ordinary-buffer-event restart loops; explicit restart or a later fresh buffer session may begin another episode. All callbacks SHALL be generation-safe: after stop/restart advances generation, prior readiness/exit/retry/stability callbacks detect mismatch and perform no state mutation or process/client action.

### Requirement: Manual lifecycle commands are project-scoped and deterministic

Commands SHALL resolve only the current buffer's canonical Godot project, leaving other projects/external processes untouched:

- `:GodotLspStatus`: report root, phase, port, owned process group, client, tracked buffers, recovery count, suppression and bounded last error; no start/stop.
- `:GodotLspStop`: stop its client/group and suppress it session-locally; ordinary events from already loaded buffers SHALL NOT immediately restart it.
- `:GodotLspRestart`: clear suppression/failure latch and start a fresh owned generation.

After manual stop and closure of all tracked GDScript buffers, a later newly opened project GDScript buffer SHALL clear suppression and become eligible for automatic startup.

### Requirement: GDShader uses a separate pinned stdio language server

`.gdshader`/`.gdshaderinc` intelligence SHALL use pinned `Dead-Shrimp-Studio/gdshader-lsp-cpp` `v0.3.2`; shader-only buffers SHALL NOT attach GDScript LSP or start headless Godot. On shader filetype activation:

- No root: no GDShader client.
- Root with verified Linux binary installed: start/reuse one root-scoped stdio GDShader client with `--stdio` in argv, providing supported completion, diagnostics, hover/signature, definition and include intelligence.
- Missing/checksum-invalid pinned binary: no server/download; emit one actionable message naming `:GodotToolsInstall`.

### Requirement: GDShader installation is explicit, pinned, verified, and atomic

`:GodotToolsInstall` SHALL install Linux `v0.3.2` asset `gdshader_lsp_release_linux` from its exact release URL with SHA-256 `bda05c0c6103d9aee5fe1a0d8a0fe11a3fa2b51415288b35d0d79dcc972dd1e5` under a versioned `stdpath("data")` location; no Mason or repository/project writes.

Matching destination checksum: report current without a network request. Otherwise download to a unique temporary sibling using inherited standard proxy environment variables, verify exact SHA-256 before executable mode/final rename, then atomically rename into the versioned destination. Download/checksum failure: remove temporary content, preserve any valid installation and report failure without enabling the invalid binary.

### Requirement: Godot language parsing is pinned and semantically separated

The runtime SHALL provide the standard GDScript Treesitter parser and pin `GodOfAvacyn/tree-sitter-gdshader` revision `14e834063e136fa69b6d91f711f4f1981acf424b` for `gdshader`/`gdshaderinc`, including GDShader queries for `.gdshaderinc`. Treesitter SHALL provide syntax/highlighting, not replace LSP; include files remain eligible for pinned GDShader stdio LSP.

### Requirement: Automatic behavior is quiet and failures are observable

Successful automatic startup/reuse/attachment/shutdown SHALL be silent; logs SHALL stay bounded and in memory, with no repository log on ready-service reuse. Unrelated filetypes/clients SHALL remain operational.

Actionable final failures, missing tools, exhausted recovery and explicit command results SHALL notify. On `failed` after missing `godot`, root canonicalization failure, LSP initialization failure or exhausted recovery, emit one actionable notification; `:GodotLspStatus` SHALL expose bounded diagnostics.

## Validation And Acceptance

Acceptance requires:

- focused Lua unit and Neovim headless state/process/transport/client/installer/parser tests;
- official Godot `4.7.2-stable` real-project completion/diagnostics/hover/definition smoke;
- current `gdvm` wrapper/engine: no orphan process/port after explicit stop and Neovim exit;
- one-Neovim multi-project and two-Neovim same-project isolation smoke;
- external GUI/headless Godot untouched;
- real pinned GDShader `v0.3.2` completion/diagnostics/hover/signature/definition/include smoke;
- relevant existing runtime regression checks;
- human confirmation of automatic open, status, restart, stop/suppression and quiet normal behavior.

## Source Trace

- User-approved design and final human acceptance, 2026-09-01.
- Official Godot external-editor docs and 4.7 GDScript language-server source.
- Local official Godot 4.7.2/`gdvm` process-group feasibility probes.
- `gdshader-lsp-cpp v0.3.2` release, checksum, features and Neovim stdio contract.
