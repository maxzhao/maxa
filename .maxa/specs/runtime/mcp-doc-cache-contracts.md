---
title: MCP Tool Schema 与 Ability-owned Guidance 稳定规格
created: 2026-06-29
updated: 2026-10-09
type: source
doc_role: spec
authority: stable
status: stable
capability: mcp-tool-schema-guidance
validation:
  specification: passed
  automated: passed
  live: passed
  human: passed
sources:
  - abilities/*/SKILL.md
  - abilities/*/ABILITY.yaml
  - lua/util/ability_catalog.lua
  - lua/maxa/interactions/chat/tools/builtin/tools/builtin_load.lua
  - lua/maxa/interactions/chat/tools/builtin/runtime/
  - abilities/ability-creator/
  - abilities/mcp-creator/
confidence: high
---

## Purpose

Define live schema authority, compact load catalogs, package-local description overrides and Ability-owned guidance.

## Requirements

### Requirement: Live allowed MCP schemas are the structural authority

Ability loading SHALL obtain the exact-workspace MCPHub source's currently allowed tools, preserving complete normalized `name`, `description` and `inputSchema`. The live schema SHALL exclusively define required fields, types, arrays, objects, enums, defaults, alternatives and constraints. Conflicting historical files/prose SHALL be ignored, never merged to add, remove, rename or structurally alter tools/parameters or restore retired tools/fields.

### Requirement: Package-local MCP overrides change descriptions only

A same-named composite Ability MAY point `ABILITY.yaml.mcp.overrides` to one root-confined file replacing named current tool/parameter descriptions only. Unlisted or unconfigured descriptions remain live; schema structure SHALL remain byte-equivalent excluding descriptions. Unknown tools/parameters, blank descriptions, missing files, unsupported fields or root escapes SHALL fail preparation; failed refresh retains the prior committed revision. Normalized results SHALL enter the Ability revision and complete protected catalog result.

### Requirement: Usage guidance is Ability-owned

The same-named Ability's `SKILL.md` or cataloged references SHALL own decision guidance, caveats and examples, without complete-schema duplication or authorization grants. Instructions MAY explain load/read/call use; runtime policy and tool schemas remain authoritative.

### Requirement: Central MCP prompt/cache directories are retired

Runtime SHALL NOT consult `prompts/mcp/{server}.json`, `prompts/mcp/{server}.md`, `prompts/abilities/` or other central per-Server caches for current definitions/guidance; current authoring workflows SHALL NOT direct updates there. These paths may appear only in migration/history evidence. Live schemas and generated Ability discovery suffice without optional override/guidance files.

### Requirement: Complete catalogs remain compact and recoverable

The load result's `tools[n]{name,description,inputSchema}` SHALL be the sole LLM-visible complete MCP tool catalog; hidden normalized dispatch/restore metadata SHALL NOT inject duplicate definitions. Oversized catalogs SHALL fail before commit, never truncate structure. [Ability Package And Authoring](./package-and-authoring.md) owns complete catalog-result association, hard-size failure, compaction/restore protection and no-TTL behavior.

## Validation

- `tests/ability_catalog_test.lua`: strict override parsing, root confinement, hidden runtime-file ownership.
- `tests/builtin_load_ability_test.lua`: changed descriptions with intact live schema structure.
- Fresh-Neovim Sentry composite load: nine live schemas, package-owned concise descriptions, no central cache directory.
- Human review passed by explicit user declaration, 2026-09-22.

## Historical Provenance

Former `prompts/mcp/` contracts survive only in Git history; live schemas and Ability packages own current behavior.

## Source Trace

- Metadata/resolution: `lua/util/ability_catalog.lua`; load/catalog: `lua/maxa/interactions/chat/tools/builtin/`.
- Authoring: `abilities/ability-creator/`, `abilities/mcp-creator/`.
- Related owners: [MCP Creator Workflow](../abilities/base/mcp-creator/mcp-creator-workflow.md), [MCPHub Runtime](./mcphub-runtime.md), [Ability Package And Authoring](./package-and-authoring.md).
