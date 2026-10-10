# {PROJECT_NAME}

> Maxa project-level supplemental rules. Priority is lower than the main system prompt, Ability Gate, tool-safety rules, and loaded Ability instructions.

## Project Scope

{PROJECT_SCOPE}

## Project Root: `<project_dir>`

> Note: `<project_dir>` is a template placeholder. When generating project rules, replace it through the template workflow. Do not hardcode a private local path in reusable governance rules. If the project root is unknown, write `to be confirmed` or inspect it first; do not guess.

## Repository Map And Agent Routing

{REPOSITORY_ROUTING}

<!-- Write a routing contract, not a raw directory inventory. For each stable area, include when to inspect it, source-of-truth files/configs, and generated/runtime paths that are not source. Use `to be inspected` for unknowns. -->

## Environment And Stack

{TECH_STACK_TABLE}

## Commands And Validation

{COMMAND_AND_VALIDATION_NOTES}

- Before shell commands, follow the current session Justfile check rules.
- After modifying code, configuration, runtime prompts, Abilities, tools, hooks, or other behavior-affecting artifacts, run the closest relevant existing validation.
- If validation entrypoints are unknown, inspect project-declared command entrypoints and related tests first. Do not report unvalidated changes as complete.

## Execution Boundaries

{EXECUTION_BOUNDARIES}

- `.maxa/tasks/`: TaskAdmin internal storage. Load `task-admin` before task operations.
- `.maxa/drafts/`: temporary draft directory. It is not durable knowledge, task progress, or runtime source storage.
- `.maxa/`: project knowledge growth layer. Read through the entry chain below. Do not write task state or temporary logs into knowledge body text.

## Important Notes

{IMPORTANT_NOTES}

## Project Knowledge Vault

- External Vault ownership follows `project-admin`: only Git's verified primary checkout (not a branch named `main`) or an independent non-Git project may register/use Obsidian or manage/scan Syncthing. Linked Worktrees maintain their own `.maxa/` with file tools; external governance steps are not applicable. Do not redirect to the primary Vault, create a Worktree-specific identity, or link/copy the whole Vault. Git-tracked knowledge integrates through explicit Git merges; ignored local files do not auto-publish. Explicit setup never silently retargets conflicts; ordinary queries do not register. Load `project-admin` for policy-aware status and guarded external operations.

- `.maxa/` is the independent project-local Obsidian Vault. Required roots: `inbox/`, `specs/`, `weave/`, `tasks/`, `drafts/`, `translate-cache/`, `attachments/`, `canvases/`. Optional content categories (`ideas/`, `research/`, `rules/`, `reports/`) exist only for actual content.
- Content belongs to its semantic owner; `weave/` holds compact LLM-generated topic/concept navigation. Load `project-admin` for user-requested weave maintenance, budgets, guarded retrieval and explicit old-content migration. Ingest/query/check does not implicitly weave.
- Follow root `index.md` to the selected weave/content/inbox index. Each maintained knowledge directory has an index; maintained root categories also have a log. Parent indexes route to direct children without deep duplication. Do not create retired `.maxa/knowledge/` or root `raw/`.
- Graph operations explicitly target this project's verified Vault. Ordinary edits rely on the owning Syncthing watcher; manual scan requires explicit user request and ProjectAdmin guarded dispatch. Do not copy governance scripts or bypass ownership guards.

---

## Project Knowledge And Source Entrypoints

> `AGENTS.md` is the L0 anchor. When knowledge is relevant under the requesting workflow, start at root `index.md`, choose weave/content/review routing, then read only selected nodes/sources. Diagnose unreachable content before authorized repair; query alone does not authorize merge/archive.

**Context levels**:
- L0 (loaded by default): `AGENTS.md`
- L1 (active reading entrypoint): `index.md`
- L1/L2: `weave/index.md`, `specs/index.md` and content indexes; capture/feedback review: `inbox/index.md`
- L2: child indexes and selected notes under maintained categories
- Retired: `.maxa/knowledge/` and root `raw/`

**Notes**:
- `ideas/`, `research/`, `rules/`, `specs/` and `reports/` own their content; no separate `sources/` publishing pipeline.
- Topic-first and source-first retrieval may use weave links/backlinks, then verify the relevant source owner. Generated nodes are not authoritative rules.
- Graph operations use the guarded explicit project Vault dispatcher.

---

## Update Rules

- Update this file when project scope, repository routing, source-of-truth files, command entrypoints, validation methods, knowledge entrypoints, or `.maxa/` governance boundaries change in a stable way.
- When Agents repeatedly make the same project-level mistake and the fix is stable, update this file or add an appropriate knowledge entrypoint.
- Before updating, read the existing content and inspect current source-of-truth files relevant to each new claim; patch only the target section and preserve user-written areas.
- Do not write task TODO state, temporary debugging state, one-off logs, complete research body text, complete note lists, or draft content into this file. Use the owning TaskAdmin workspace, `.maxa/`, or `.maxa/drafts/` instead.
- Keep this file as an L0 entrypoint. If content becomes long, move low-frequency details into `.maxa/` and keep only a stable summary plus entry paths here.
- Keep Agent-facing project rules dense: prefer stable constraints, entry paths, commands, validation, and ownership over narrative explanation. Preserve exact paths, recipe names, tool names, and validation commands.
- `.maxa/AGENTS.md` must be written in English unless a higher-priority project rule explicitly requires another language.
