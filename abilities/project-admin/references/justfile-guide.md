---
name: justfile-guide
description: Guide Agents to create and maintain project `justfile` and `justfile.md`, including system tags, WSL/Windows cooperation, documentation structure, and minimal templates.
---

# Justfile / justfile.md Guide

Purpose: provide a command entrypoint that humans and Agents can use consistently.

| File | Role |
| --- | --- |
| `justfile` | command implementation and platform dispatch |
| `justfile.md` | command usage, platform scope, constraints |

Maintain both together. If a project adopts `just`, do not create only one unless explicitly scoped.

## Create When

Create or maintain this pair when:

1. The project has repeated build/test/dev/sync/release commands.
2. A command needs Windows vs WSL execution differences.
3. Agents need one stable command entrypoint.
4. The team does not want users/Agents to memorize scattered `npm`, `cargo`, `python`, `bash`, or `powershell` commands.

If the project has only a few one-off commands and no cross-platform need, creation is optional.

## Project-admin Integration

When `project-admin` finds a `justfile` or the user requests unified command entry:

1. `project-admin` decides when to handle it.
2. This file defines concrete justfile / justfile.md rules.
3. During `init`, if `justfile` exists and `justfile.md` is missing, create a minimal `justfile.md` by default.
4. During `sync`, if `justfile.md` is missing, report it by default; create it only when the user explicitly asks.

## Mandatory Rules

### System Tags

Every recipe must have an explicit system tag. Bare recipes are forbidden.

Allowed base tags:

- `[windows]`
- `[linux]`

Other just attributes may be added, but the system tag must remain.

### Dual Implementation Only For Real Cross-System Commands

Use same-name dual implementations only when both Windows and WSL can provide stable entrypoints.

```just
[linux]
check:
    #!/usr/bin/env bash
    cargo check

[windows]
[script('powershell.exe -NoProfile -Command')]
check:
    cargo check
```

### Do Not Fake The Other Platform

- Bash/WSL/bridge-only command -> `[linux]` only.
- PowerShell/GUI/Windows-path command -> `[windows]` only.
- Do not add unusable counterparts for symmetry.

### WSL-To-Windows Bridge Is `[linux]`

In this guide, `[linux]` means WSL-side execution by default. A recipe launched from WSL that bridges to Windows via `runwingui`, `powershell.exe`, or `cmd /c` is a valid `[linux]` recipe.

Rules:

- Document it as `WSL only`.
- State that it starts in WSL and bridges to Windows.
- Do not add native-Linux guards or substitutes unless the user explicitly asks for native Linux support.

### Keep `justfile.md` Synchronized

After adding, deleting, or renaming recipes, update `justfile.md` with:

- command name;
- system scope (`Windows + WSL`, `Windows only`, `WSL only`);
- purpose;
- parameters;
- special prerequisites.

## Workflow

1. Classify commands: `Windows + WSL`, `Windows only`, `WSL only`.
2. Choose semantic command names such as `build`, `test`, `dev`, `lint`, `format`, `install`, `status`.
3. Hide platform differences inside recipes so callers run `just build` / `just test`.
4. Create or update `justfile.md`.
5. Validate recipe summary and docs.

## Recommended `justfile` Structure

1. File header comment: system tag strategy.
2. Path constants: project root, Windows path, WSL path.
3. Base commands: install / build / test / lint / format.
4. Project commands: sync / release / bridge / deploy / e2e.
5. Environment commands: status / logs / stop / doctor.

Path constants example:

```just
JUST_ROOT := justfile_directory()
WIN_APP_ROOT := "C:\\Projects\\demo"
WSL_APP_ROOT := "/mnt/c/Projects/demo"
```

## Recipe Patterns

### WSL Recipe (`[linux]`)

```just
[linux]
fmt:
    #!/usr/bin/env bash
    cd "{{JUST_ROOT}}"
    cargo fmt --all
```

Rules: use shebang, `cd` to project root when needed, use `{{JUST_ROOT}}`, and treat `[linux]` as WSL-side unless the project explicitly supports native Linux.

### Windows Recipe

```just
[windows]
[script('powershell.exe -NoProfile -Command')]
fmt:
    Push-Location "{{JUST_ROOT}}"
    try {
      cargo fmt --all
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally {
      Pop-Location
    }
```

Rules: prefer PowerShell script recipes, use `Push-Location` / `Pop-Location`, and propagate external command exit codes.

### WSL Recipe Bridging Windows

```just
[linux]
app-build:
    #!/usr/bin/env bash
    runwingui --cwd "C:\Projects\demo" cmd /c "npm run build"
```

Document as `WSL only` and explain the bridge.

## `justfile.md` Structure

Recommended frontmatter:

```markdown
---
name: justfile
description: "Justfile guide; read before running project commands."
---
```

Recommended sections:

1. Purpose.
2. Quick start.
3. Core conventions: tags, WSL/Windows cooperation.
4. Command summary table.
5. Grouped command details.
6. Notes/prerequisites.

### Init Default Creation Rule

During project initialization, if:

1. user is initializing the project;
2. root `justfile` exists;
3. root `justfile.md` is missing;

then create `justfile.md` by default. Use a minimal template, do not invent business detail, optionally fill command table from `just --list` / `just --summary`, and never overwrite an existing `justfile.md`.

### Minimal Template

```markdown
---
name: justfile
description: "Project justfile usage guide. Read before running commands."
---

# Justfile Usage

## Core Rules

- Every recipe must have an explicit system tag.
- Windows + WSL compatible commands use same-name dual implementations.
- Single-system commands must state their system scope.

## Commands

| Command | System | Purpose | Usage |
| --- | --- | --- | --- |
| `just build` | Windows + WSL | Build project | `just build` |
| `just test` | Windows + WSL | Run tests | `just test` |
| `just release` | WSL only | Release project | `just release <version>` |

## Notes

- Agents should read this file before running commands.
- Update this file whenever `justfile` changes.
```

## Documentation Terms

Use exact scope labels:

- `Windows + WSL`
- `Windows only`
- `WSL only`

Avoid vague wording such as “probably works on Windows,” “usually Linux,” or “may need bridge.”

## Compatibility Questions

Before writing a recipe, ask:

1. Depends on PowerShell, Windows GUI, `.exe`, registry, or Windows path? -> likely `[windows]`.
2. Depends on Bash, `/mnt/c/...`, WSL bridge tools, or WSL-initiated Windows calls? -> likely `[linux]` / WSL-side.
3. Can both Windows and WSL provide stable maintainable implementations? -> dual implementation.
4. Only needs WSL + Windows model, not native Linux? -> document `WSL only`; do not add native-Linux compatibility.

## Agent Execution Checklist

1. Check for existing `justfile` and `justfile.md`.
2. In init, create missing `justfile.md` when `justfile` exists.
3. If files exist, patch incrementally and preserve command names.
4. If both are missing and creation is requested, create a minimal pair rather than many business recipes.
5. After modifying `justfile`, update `justfile.md`.
6. Preserve command semantics and avoid breaking callers.

## Validation

After changes, check:

- `just --summary` or `just --list` works.
- No recipe lacks a system tag.
- Single-system commands state scope.
- Dual-system commands really have two same-name implementations.
- `justfile.md` matches `justfile`.
- Documented system scope matches implementation.
