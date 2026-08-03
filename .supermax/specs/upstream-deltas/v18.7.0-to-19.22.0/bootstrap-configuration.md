---
title: Bootstrap and configuration upstream delta
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
---

## Source diff

The release substantially updates configuration documentation and adds/expands configuration surfaces for ACP, CLI, code review, MCP, prompt library, action palette, chat buffer, rules, system prompt, and upgrading. The source diff also touches bootstrap/configuration-related Lua entrypoints and schemas.

## Observable behavior delta

Latest-upstream exposes more configuration domains and likely changes defaults/schema validation for chat, ACP, MCP, prompt libraries, rules, and code review. Upgrade guidance and newly documented entrypoints indicate migration-sensitive configuration behavior.

## Compatibility impact

High for configuration schemas and defaults; unknown keys, renamed keys, and default changes can alter startup or interaction behavior. Documentation changes alone are not treated as behavior proof.

## Validation and unknowns

Reviewed `git diff/show` for configuration source/docs and version metadata. Not run: clean-start bootstrap, legacy configuration loading, schema rejection, and migration checks. Unknown: exact default changes and whether old keys are accepted or warned.
