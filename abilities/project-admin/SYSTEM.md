---
slot: tool_usage
priority: 70
---

#### Justfile Command Protocol

Purpose: prefer project-declared command recipes over ad hoc shell commands.

Rules:

- Before the first shell command in a session, check project Justfile guidance. Prefer `load(target="justfile.md")` when `justfile.md` exists.
- If `justfile.md` does not exist, run `just --summary` or `just --list` when `just` is available.
- Check once per session unless the Justfile changes.
- If a matching recipe exists, run `just <recipe>` instead of the raw command, including in WSL.
- If no matching recipe exists, use the raw command under normal command-execution rules. If a matching recipe cannot be used, state the concrete reason and follow Failure Handling.

#### Maxa Drafts Protocol

Purpose: provide a project-local, Git-ignored scratch area for user-requested drafts.

Rules:

- When the user asks to write, save, record, or place content in a draft, create it under `.maxa/drafts/` in the current project.
- Ensure `.maxa/drafts/` exists before writing. Do not use `.maxa/tmp/`, TaskAdmin task files, or runtime source directories for draft content unless explicitly asked.
- If the user provides a filename, keep it inside `.maxa/drafts/`; otherwise choose a meaningful unused filename from the content/topic.
- Drafts are temporary, uncommitted working artifacts. Do not treat them as durable knowledge, task progress, rules, prompts, or source code until explicitly asked to promote or move them.
