---
title: Obsidian DeepSeek Translate Plugin 行为规格
created: 2026-07-04
updated: 2026-10-09
type: source
doc_role: spec
authority: draft
status: experimental
capability: obsidian-deepseek-translate
sources:
  - obsidian-plugins/obsidian-deepseek-translate/manifest.json
  - obsidian-plugins/obsidian-deepseek-translate/package.json
  - obsidian-plugins/obsidian-deepseek-translate/src/main.ts
  - lua/maxa/session/buffer_translate.lua
  - tests/util_maxa_ai_buffer_translate_spec.lua
  - abilities/obsidian/references/obsidian-plugin-development.md
  - user-review:2026-07-04
  - user-review:2026-09-15
confidence: medium
---

> **TLDR**: Cache-first, whole-document DeepSeek translation with Neovim-compatible `.maxa/translate-cache` keys and body-only files.

## Requirements

Throughout translation, the source remains unchanged. Readable cache hits and successful cache writes open in the same reusable fixed right-side result leaf.

### Requirement: Package and settings are local and secret-safe

Plugin ID: `obsidian-deepseek-translate`; implementation should remain mobile-compatible unless a verified dependency requires desktop-only behavior. Settings expose masked `apiKey`, `model`, `targetLanguage`, `temperature`, and `allowedExtensions`. Credentials SHALL NOT enter cache files, logs, specs, wiki notes, Git-tracked files, or distributed plugin `data.json`. Missing credentials fail before network access on cache miss only; existing caches remain readable.

### Requirement: Translation targets a complete supported Vault file

Command/file-menu translation targets the complete active/selected file, not a text selection. Reject unsupported extensions, unresolved roots, and files inside `translate-cache/` before network/write work.

### Requirement: Cache keys match Neovim

Obsidian and `buffer_translate.lua` SHALL produce the same SHA-256 filename for the same repository-relative path, semantic source content, and target language:

```text
normalize_semantic_content(text):
1. Convert CRLF and CR to LF.
2. Remove trailing spaces/tabs from every line.
3. Join with LF and trim full-text leading/trailing whitespace.
4. Repeatedly collapse runs of 3+ LF to exactly 2 LF until stable.

semantic_hash = SHA-256 UTF-8 hex(normalized text)
cache_key = SHA-256 UTF-8 hex(relative_path + "\n" + semantic_hash + "\n" + targetLanguage)
```

| Vault root | Cache file | Key `relative_path` |
| --- | --- | --- |
| `.maxa` | `translate-cache/<key>.md` | `.maxa/<vaultRelativePath>` |
| Project root | `.maxa/translate-cache/<key>.md` | Project-relative source path |

Unsafe/unknown root mode fails without cache creation.

### Requirement: Cache hit avoids network

An existing readable cache SHALL open without a DeepSeek request; an unreadable existing cache reports failure without automatic overwrite.

### Requirement: Cache miss uses DeepSeek Chat Completions

After source validation and cache miss, call `POST https://api.deepseek.com/chat/completions` with bearer authorization, configured model/temperature, and messages requesting body-only translation preserving Markdown structure, links, code, commands, identifiers, URLs, paths, and markup. Non-streaming extraction uses `choices[0].message.content`.

Publish only translated Markdown body: no frontmatter, timestamps, model metadata, comments, wrapper fences, API JSON, or explanations. Duplicate same-key requests SHOULD be coalesced or disabled; an arriving synchronized cache SHOULD win before write.

### Requirement: Errors are explicit and non-destructive

Missing settings, unsupported files, network/HTTP errors, error/invalid/malformed/empty responses, directory/write failures, and cache read failures produce actionable notices without partial cache publication.

## Validation And Review State

- Historical package typecheck, build, and `node --check main.js` passed; project-local publish and runtime-file checks were recorded.
- User live review on 2026-07-04 passed corrected file-menu and cache-hit opening behavior; human specification review passed by explicit user declaration on 2026-09-15.
- Not run in this consolidation: fresh hash cross-language fixtures, cache-hit no-fetch test, cache-miss request/body test, current build, or new live Obsidian smoke. Status remains experimental.
