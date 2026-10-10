# Vault Diagnostic And Feedback Entrypoints

Purpose: select existing project-local Vault scripts without reading their implementation. Apply `knowledge-governance.md` for content/repair authorization and `knowledge-vault.md` before external operations.

## Invocation

After `load(target="project-admin")`, use titled `run(scope="tool")` with a cataloged `@project-admin:/scripts/` address. Python uses the owning uv executor. Resolve `<PROJECT_ROOT>` and `<VAULT>` (`<PROJECT_ROOT>/.maxa`) before invocation; array arguments are literal strings.

Start with `args: ["--help"]` when usage is uncertain. These examples are alternatives, not an unconditional batch.

## Health, Scale And Naming

`vault_health.sh` resolves the selected project root or its own `.maxa/`, never the active Obsidian Vault. Linked Worktrees automatically use file checks; `--quick` never contacts external services. Eligible live checks use guarded dispatch; failure is non-zero and is not evidence of a healthy graph.

```yaml
- title: "Check project Vault health"
  scope: tool
  command: "@project-admin:/scripts/vault_health.sh"
  args: ["--project-root", "<PROJECT_ROOT>"]
- title: "Check project Vault files only"
  scope: tool
  command: "@project-admin:/scripts/vault_health.sh"
  args: ["--project-root", "<PROJECT_ROOT>", "--quick"]
- title: "Inspect Vault statistics"
  scope: tool
  command: "@project-admin:/scripts/vault_stats.sh"
  args: ["<VAULT>"]
- title: "Check Vault document sizes"
  scope: tool
  command: "@project-admin:/scripts/vault_doc_sizes.py"
  args: ["--vault", "<VAULT>", "--json"]
- title: "Check generated weave byte budgets"
  scope: tool
  command: "@project-admin:/scripts/vault_doc_sizes.py"
  args: ["--vault", "<VAULT>/weave", "--json"]
- title: "Check note titles"
  scope: tool
  command: "@project-admin:/scripts/note_titles.py"
  args: ["--vault", "<VAULT>", "--issues-only", "--format", "json"]
```

Health scripts are diagnostics, not authorization to restructure or process queues. Report the script's actual threshold/coverage; a file-only result does not validate live graph behavior.

## Graph Neighborhood

Require eligible checkout and existing verified registration. For general CLI syntax and property/link operations, use `obsidian-cli.md` and the guarded `project_knowledge_vault.py exec` entrypoint.

```yaml
title: "Inspect note neighbors"
scope: tool
command: "@project-admin:/scripts/graph_neighbors.sh"
args: ["--project-root", "<PROJECT_ROOT>", "My Note"]
```

`project_vault_cli.sh` is a sourced internal helper, not a callable entrypoint. Do not fall back to raw/default-Vault CLI operations.

## Feedback Listing And Listening

Process feedback only when requested, following Feedback Processing in `knowledge-governance.md`. For pending listing without processing:

```yaml
- title: "List pending feedback once"
  scope: tool
  command: "@project-admin:/scripts/watch_feedback.py"
  args: ["--vault", "<VAULT>", "--once", "--json"]
- title: "List all feedback"
  scope: tool
  command: "@project-admin:/scripts/watch_feedback.py"
  args: ["--vault", "<VAULT>", "--all", "--once", "--json"]
```

Listening omits `--once`; preserve infinite-wait semantics and the user stop condition. Queue listing alone does not authorize target-note edits or feedback state changes.

## Other Script Owners

- Capture inventory/report/mark-merged/validate: `inbox-curation.md`.
- Local plugin publication: `obsidian-plugin-development.md`.
- Plugin/config distribution: `obsidian-plugin-sync.md`.

Ordinary file edits and plugin publication do not imply a forced Syncthing scan. Only an explicit user scan request uses `project_knowledge_sync.py scan`.
