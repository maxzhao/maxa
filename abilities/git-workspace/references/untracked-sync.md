# Untracked File Sync

Purpose: copy local development files from the current checkout and link configured single-source files from the primary worktree into a target workspace.

## Rules

- This is development-file copy/link synchronization, not Obsidian/Syncthing or knowledge publication. Follow the Project Vault Boundary in `SKILL.md`; do not configure a whole-Vault copy/link or registration command as a workaround. Tracked knowledge integrates through explicit Git merges; ignored Worktree drafts/cache do not auto-publish.

- Source checkout: the directory where the create/sync command is run.
- Target: configured workspace path.
- Pattern root: source checkout root.
- Semantics: `.gitignore`-similar include/copy patterns, not ignore patterns.
- `sync.only_untracked: true` means tracked Git files are skipped even if matched.
- Existing copy or link targets use `skip_warn`: leave unchanged and report warning.
- Missing copy pattern matches use `warn`: report and continue.
- `sync.link_patterns` sources always resolve from the repository primary worktree and must be files.
- A missing link source is an error; the script never creates a dangling link.
- File contents must never be printed.

## Pattern Notes

- Empty lines and lines beginning with `#` are ignored.
- Directory patterns ending in `/` copy recursively.
- Glob patterns are allowed.
- Path traversal outside source checkout is invalid.
- Symlinks encountered by copy patterns are skipped with warning.
- Link patterns create absolute symlinks to the primary-worktree source file.

## Expected Result Fields

Structured output should include:

- `copied`: copied relative paths.
- `linked`: linked relative paths.
- `skipped_existing`: target paths that already existed.
- `skipped_tracked`: tracked source paths not copied.
- `skipped_symlink`: symlink paths not copied.
- `missing_patterns`: patterns that matched nothing.
- `warnings`: concise warning strings.
