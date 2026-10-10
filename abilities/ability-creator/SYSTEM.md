---
slot: tool_usage
priority: 40
---

#### Ability Source Access

For an MCP-backed Ability, only a successful `load` can authorize the exact Chat/workspace by committing a revision and complete catalog. Discovery and shared connections grant no authorization. Project Ability availability governs source activation and use regardless of visibility; Server JSON `disabled` is retired. An authorized MCP tool connects a disconnected source and waits for success before execution; it does not reload the Ability or create authorization. History restore and batch preflight never connect; resource access never auto-reconnects.

#### Ability Invocation Protocol

- Use `#ability[target]` with `read`/`load` for Ability content. The opening bracket after the identifier and the final closing bracket enclose a nonblank single-line target; preserve internal brackets, spaces, `#`, `@`, query/fragment characters and identifier spelling. No quotes, type markers, aliases, URI rewriting or old colon-form compatibility.
- A leading `/` target first resolves a current root-confined package file. File lookup uses current project/global ownership without requiring or loading the Ability; disclosure, `include`, `exclude`, hard exclusions and executable classification do not restrict it. Control files such as `SYSTEM.md` are exact-readable; credential-read safety still applies. File lookup does not authorize execution or activate hooks/extensions.
- Only genuine file absence, including no package roots, permits exact authorized resource lookup with the original target. Malformed paths, access/I/O errors, non-file owners, containment/overlay violations and a selected file's read or consumer-eligibility failure stop without fallback. Existing files win; there is no resource bypass. Other targets go directly to exact resource lookup.
- `run(title="...", scope="tool", command="@ability:target", args=...)` actions and resource access through `#ability[target]` require a ready committed catalog, exact-Chat/workspace authorization and membership. Load the Ability if this state is absent; valid restored state needs no new load before tool execution. Preserve the resource's listed original identifier and owning server; resource access remains connected-only and excluded executables remain unavailable as actions.
- Resolve package-relative file references in Ability instructions through their owning `#ability[/path]`, not the project's current directory. Use the committed catalog for actions and resource identifiers. Do not replace an available Ability address with a filesystem `load`/`read` or a shell `run` command.
- Ability scripts accept literal `args:string[]`; MCP tools and bare builtin targets accept `args` as an encoded JSON object string. Resolve placeholder/project paths first; script argv does not expand shell variables, globs, pipes or command substitution. The declared executor owns the Python/uv runtime.
- For current-Neovim Lua operations, load `neovim` and use `run(scope="@neovim:lua")`. Keep explicit exceptions for APIs requiring physical paths, package-source maintenance, project/output files, external CLIs, and clearly labeled human/manual or test commands. Do not invent callable addresses for uncataloged helpers or bypass authorization with a fallback path.

#### Ability Python Runtime Protocol

Purpose: enforce portable Python execution for Ability packages that ship Python scripts.

Rules:

- Applies to global Abilities and downstream project Abilities under `.maxa/abilities/*`.
- Treat the selected script's owning Ability root as the uv project root.
- Resolve `<ability_root>` from the loaded Ability catalog or package location.
- Invoke cataloged Python scripts through `run(scope="tool")`; their executor must use the following underlying command. Explicit maintenance/manual commands and internal wrappers must use the same runtime:

```bash
uv run --project <ability_root> python <ability_root>/scripts/<script>.py [args...]
```

- Abilities with Python scripts must include `pyproject.toml`; declare Python dependencies in that uv project.
- Do not run Ability Python scripts with system `python`, system `python3`, direct shebang execution, or implicit PATH resolution.
- `bin/*` wrappers, shell scripts, AbilityHook files, and Agent-facing docs that invoke Python scripts must use the same `uv run --project <ability_root>` contract.

Failure handling:

- If `uv` is unavailable, dependency sync fails, or `uv run` fails, report the exact error and follow normal tool-failure handling.
- Do not fall back to system Python.
