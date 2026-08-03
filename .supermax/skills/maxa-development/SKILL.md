---
name: maxa-development
description: Guide to extending or enhancing the maxa runtime horizontal functional points. Load when adding or changing providers, modules, tools, MCP, skills, events, session state, or persistence under lua/maxa/runtime, or when deciding whether to reuse a LazyVim ecosystem facility versus reimplementing it.
visibility: global
triggers:
  - extend maxa runtime
  - maxa horizontal functional point
  - reuse LazyVim ecosystem utility
  - keep maxa module contract
  - add a maxa provider or module
---

# maxa runtime development

North star for any later-phase work on this repository:

> Enhance and extend the existing Phase-0 skeleton. Do not reimplement what
> LazyVim/Nvim already provides, and do not change already-agreed contracts.

Treat every runtime change as a behavior contract: goal, inputs, scope, tools,
process, output, failure handling, and validation.

## When to load

Use this skill when a task modifies anything under `lua/maxa/runtime/**` or the
maxa plugin wiring (`lua/plugins/maxa.lua`, `lua/maxa/init.lua`), including:

- Adding a real protocol adapter (OpenAI Chat/Responses, Anthropic Messages, Gemini).
- Implementing tools / MCP / skills (currently places holders).
- Adding history/persistence, session restore, streaming usage normalization.
- Adding spine/statusline or new Chat UI surface.
- Extracting or changing an invariant already relied on by another module.

## Three questions before any horizontal capability

For every generic/non-domain capability the runtime needs, answer in order:

1. **Does LazyVim (or Nvim builtins) already provide it?** Reuse it.
   LazyVim dependency tree = all 33 plugins it pulls in (including ones not yet
   loaded/enabled), plus `vim.*` builtins (`vim.deepcopy`, `vim.json`,
   `vim.tbl_*`, `vim.uv`, `vim.iter`, `vim.keymap`, `vim.system`, `nvim_*` API).
2. **Is it domain-specific to maxa?** Only then is a self-written/kept model justified:
   events bus, schema validation, normalized message model, session/orchestrator
   state machine, guard. Reimplement a generic facility only when the ecosystem
   truly has no fitting module; document that reasoning in code.
3. **If reusing, does it violate the import-guard or the contracts?** Reusing
   `codecompanion.*`, `mcphub.*`, `lua/util/hooks/*` is forbidden. Otherwise
   LazyVim-ecosystem dependencies are always allowed.

Rules for the answer:

- Prefer the existing harness module over a handwritten generic facility for
  YAML, serialization, floating-window/UI, async/await, path utilities, deep
  copy, table helpers.
- If you must keep/self-write anything generic, annotate it `生态缺位最小替代`
  (ecosystem-missing minimal substitute) or record the domain reason in a
  comment. Never silently hand-write a generic facility.
- Never introduce a new *external* dependency without an explicit user decision.
  Vendoring a mature single-file library (e.g. TinyYaml) is allowed only when the
  user approves and the license/copyright header is preserved.

## Enhance, don't rewrite

The Phase-0 contracts are the shared spine. Extending means *adding*, not
changing shape:

- Only add fields/events/providers; never rename or remove existing ones.
- Provider interface (`stream(params, {on_chunk,on_done,on_error})` ->
  `{cancel, active}`) is the single adapter surface; add real adapters to it,
  keep mock/echo conformant.
- Events emit through the bus (`on/emit` + envelope + sequence); only add names.
- `CONFIG/runtime.yaml` changes must stay fail-closed and unknown-core-key safe.
- Keep `import-guard`(guard module) active for the whole runtime and tests.

## Horizontal catalog

See `references/ecosystem-catalog.md` for the authoritative reuse table
(which facility maps to which ecosystem lib) and the hand-written kept-set with
reasons. When in doubt, read that catalog first.

## Domain models (do not force-fit an ecosystem component)

These are maxa's redefined surface with no LazyVim equivalent; analyzed once:

- `events` typed bus (on/emit/envelope/sequence/pcall isolation)
- `schema` payload validation primitives
- `conversation` normalized message + identity
- `session`/`orchestrator` state machine + message loop
- `guard` import-guard

For these you extend, not replace. If you believe LazyVim now provides an
equivalent, verify it actually matches the semantics before switching; otherwise
keep and extend.

## Validation discipline

Every behavior-affecting change must run its closest validation before being
reported complete:

```bash
cd /home/maxzhao/maxa
just smoke          # headless full-chain load + import-guard + echo submit
just lint && just fmt   # stylua
just check          # git diff --check
```

- Headless runs use `NVIM_APPNAME=nvim-maxa nvim --headless` inside the event
  loop (see `just smoke` for the exact launcher).
- The runtime and any tests MUST NOT load `codecompanion.*`, `mcphub.*`, or
  `lua/util/hooks/*`.
- Do not claim success for unvalidated changes. Report exact commands, expected
  results, blockers, and remaining risk.

## References

- `references/ecosystem-catalog.md` — authoritative reuse table + kept hand-writes.
- `references/contracts-and-invariants.md` — the shared contracts & invariants to
  preserve (message shape, provider interface, events, config, import-guard).
- `phase0-development-plan.md` (`.supermax/drafts/`) — §4 contracts / §10 rework notes.
- `AGENTS.md` Dependency Policy (higher authority for dependency rules).
- `.supermax/specs/implementation-sequence.md` — the seven-phase roadmap & gates.
