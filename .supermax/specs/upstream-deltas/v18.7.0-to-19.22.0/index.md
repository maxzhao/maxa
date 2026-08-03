---
title: CodeCompanion v18.7.0 to v19.22.0 upstream delta index
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
versions: [18.7.0, 19.22.0]
---

> Scope: latest-upstream behavior delta only. Baseline specifications remain authoritative for baseline extraction and are not amended by these documents. This is reverse-engineering evidence, not an independent runtime target.

## Comparison contract

- Baseline: `olimorris/codecompanion.nvim` commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d` (`v18.7.0`).
- Latest comparison point: commit `2b959b2bf5fdb13e3b333c078ba549996e477b7c` (`v19.22.0`).
- Source evidence: `git diff/show` in `~/.local/share/nvim/lazy/codecompanion.nvim`; baseline behavior is read from the baseline commit, latest behavior from the comparison commit.
- Authority is `draft`; no delta is an accepted design decision.

## Module coverage

| Module | Delta document | Review status |
|---|---|---|
| ACP protocol | removed from target; historical comparison file deleted | n/a |
| Actions and extensions | `actions-extensions.md` | source diff reviewed; compatibility needs verification |
| Background interactions | `background-interactions.md` | source diff reviewed; queue semantics need tests |
| Bootstrap and configuration | `bootstrap-configuration.md` | source/doc diff reviewed; schema migration needs verification |
| Chat lifecycle | `chat-lifecycle.md` | large source diff reviewed; behavior coverage incomplete |
| Events and integration | `events-integration.md` | public event documentation diff reviewed |
| HTTP transport | `http-transport.md` | adapter/provider diff reviewed; provider matrix incomplete |
| Inline assistant | removed from target; historical comparison file deleted | n/a |
| Message and context | `message-context.md` | context-management diff reviewed; edge cases incomplete |
| Tools and agent loop | `tools-agent-loop.md` | registry/tool/approval diff reviewed; end-to-end behavior incomplete |

## Cross-cutting findings

- The release is not a small patch: the recorded baseline notes report 329 commits and 610 changed files. Module documents therefore distinguish file-level evidence from externally observable behavior.
- Renames and new entrypoints are recorded as compatibility risks, not as proof that old user behavior was removed.
- No SuperMax hook, integration, or independent runtime requirement is included here.

## Validation

Performed: commit identity/version checks and module-scoped `git diff --name-status`, `--stat`, and targeted `git show` review. Upstream test execution was not completed in this worktree. Unknowns and required checks are listed per module.

## Open questions

- Which retained upstream changes and Actions/Commands details should be carried into the target runtime require target-module review.
- Provider-specific payload, UI rendering, cancellation, and migration behavior require executable comparison tests before promotion.
