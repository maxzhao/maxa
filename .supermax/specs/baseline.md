---
title: CodeCompanion.nvim 规格反推基线
created: 2026-08-01
updated: 2026-08-01
type: source-summary
doc_role: reverse-spec-baseline
authority: draft
status: experimental
tags: [codecompanion, reverse-engineering, baseline]
sources:
  - lazy-lock.json
  - https://github.com/olimorris/codecompanion.nvim/tree/558518f8d78a44198cd428f6bf8bf48bfa38d76d
  - https://github.com/olimorris/codecompanion.nvim/commit/2b959b2bf5fdb13e3b333c078ba549996e477b7c
confidence: high
---

> **TLDR**: 主基线固定为项目锁定提交 `558518f8d78a44198cd428f6bf8bf48bfa38d76d`（`v18.7.0`）；最新上游比较点固定为调查时的 `2b959b2bf5fdb13e3b333c078ba549996e477b7c`，二者不得混写为同一行为版本。

## Primary Baseline

| Field | Value | Evidence |
| --- | --- | --- |
| Repository | `olimorris/codecompanion.nvim` | upstream Git remote |
| Project lock | `558518f8d78a44198cd428f6bf8bf48bfa38d76d` | `lazy-lock.json` |
| Tag/version | `v18.7.0` / `18.7.0` | upstream tag and `version.txt` at locked commit |
| Branch declaration | `main` | `lazy-lock.json` |
| Commit time | `2026-02-18T08:00:51+00:00` | upstream Git commit metadata |
| Role | authoritative extraction baseline | explicit user decision, 2026-08-01 |

All requirements describing “current CodeCompanion behavior” MUST trace to this commit unless a requirement explicitly identifies another version.

## Latest-Upstream Comparison Point

| Field | Value |
| --- | --- |
| Commit | `2b959b2bf5fdb13e3b333c078ba549996e477b7c` |
| `version.txt` | `19.22.0` |
| Commit time | `2026-07-31T17:28:54+01:00` |
| Distance from baseline | 329 commits |
| Diff scale observed | 610 files changed, 59,073 insertions, 24,994 deletions |

The comparison point is a dated snapshot, not a floating specification. Refreshing it requires updating this file and `log.md`; do not silently reinterpret old evidence against a newer `main`.

## Evidence Priority

1. Baseline source logic plus baseline tests.
2. Baseline source logic plus schemas/configuration/parsers.
3. Baseline source logic only.
4. Baseline documentation or release notes, marked when not code-confirmed.
5. SuperMax integration behavior, explicitly labeled as downstream adaptation rather than upstream behavior.
6. Latest-upstream source/diff, explicitly labeled `latest-upstream`.
7. Inference, explicitly labeled assumption or open question.

## Separation Rules

- Never derive baseline behavior from the current upstream `main` checkout without checking the baseline commit.
- Never treat SuperMax patches under `lua/util/hooks/`, `lua/util/codecompanion/`, `lua/codecompanion/_extensions/`, or `lua/util/mcphub/` as upstream behavior.
- Never treat documentation headings, source inventories, exported names, or test filenames as behavior requirements by themselves.
- Preserve exact upstream public names where evidence requires them, but do not make API compatibility a target-runtime requirement without a later explicit decision.

## Reproduction Checks

```text
rg -n '"codecompanion.nvim"' lazy-lock.json
git -C <codecompanion-checkout> show -s --format='%H%n%cI' 558518f8d78a44198cd428f6bf8bf48bfa38d76d
git -C <codecompanion-checkout> show 558518f8d78a44198cd428f6bf8bf48bfa38d76d:version.txt
git -C <codecompanion-checkout> diff --stat 558518f8d78a44198cd428f6bf8bf48bfa38d76d..2b959b2bf5fdb13e3b333c078ba549996e477b7c
```

Expected primary identity: commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d`, version `18.7.0`.

## Open Questions

- Which latest-upstream changes represent desirable behavior versus upstream-specific evolution? Decide only after baseline modules are extracted.
- Which SuperMax patches compensate for upstream defects, and which introduce independent product behavior? Requires a separate downstream adaptation map.
