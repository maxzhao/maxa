# Large Git-Tracked Code Files

Purpose: inventory oversized code and choose semantic refactor boundaries. This workflow remains separate from Vault structure and content maintenance.

## Entrypoint

After `load(target="project-admin")`, inspect help when needed:

```yaml
title: "Inspect large-code-file help"
scope: tool
command: "@project-admin:/scripts/list_large_code_files.py"
args: ["--help"]
```

Uses `git ls-files` as source and `scc` to classify code. Default threshold is `50k` bytes. Prefer `--format summary` for Agent reading and `--format json` for machines. JSON envelope: `project_root`, `threshold_bytes`, `stats`, `files`.

Choose one invocation with a resolved literal project path:

```yaml
- title: "Summarize large code files"
  scope: tool
  command: "@project-admin:/scripts/list_large_code_files.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--format", "summary"]
- title: "Summarize first twenty large code files"
  scope: tool
  command: "@project-admin:/scripts/list_large_code_files.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--format", "summary", "--limit", "20"]
- title: "Export large-code-file inventory"
  scope: tool
  command: "@project-admin:/scripts/list_large_code_files.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--format", "json"]
```

Default filters remain cross-project: hidden directories, dependencies/third-party/build/generated output such as `node_modules`, `vendor`, `dist`, `build`, `target`, Python venvs and Unreal generated directories. Do not bake current-project paths into defaults.

## Refactor Decisions

- Do not split mechanically by lines/bytes. Identify responsibility, call boundary, public API, state ownership and test boundary first.
- Prefer domain, runtime phase, interface, data model, adapter, persistence, workflow or fixture modules.
- Avoid generic `utils`, `helpers`, `common`, `misc`, `shared` buckets unless they are small stable primitives with clear APIs.
- For already over-fragmented code or generic facades, consider fewer semantic modules and concrete imports.
- If framework/generated/packaging/entrypoint/state-machine/public-interface constraints prevent splitting, report reason, risk and alternatives.
- For many matches, classify by module/language/directory/runtime layer/test/generated/third-party, recommend batch size and ask which category to prioritize.
- Do not parallelize one coupled module's refactor. Only independent modules may run in parallel; each remains serial inside its worker.

## Output And Validation

Report inventory, semantic ownership and next action. Inspection does not authorize a refactor. For authorized changes, run the closest relevant existing checks and preserve public behavior within the agreed scope.
