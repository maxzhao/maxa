# Contracts & Invariants — preserve when extending maxa runtime

These are the shared, already-agreed shapes. Extend by adding; never rename,
remove, or change the meaning of an existing field, event, signature, or state
transition. Source of truth: `phase0-development-plan.md` §4 + the module code.

## Import-guard (hard)

- Runtime and any tests MUST NOT `require`/`load` `codecompanion.*`, `mcphub.*`,
  or `lua/util/hooks/*`.
- They MAY load any other LazyVim-ecosystem dependency (`plenary.*`, `snacks.*`,
  `nui.*`, `mini.*`, etc.).
- `guard/init.lua` provides `is_forbidden` / `require` / `assert_no_forbidden`.
  Keep it applied at every entrypoint (`maxa.runtime` load, tests, smoke).

## Provider interface (single adapter surface)

```lua
provider = {
  name        = "mock" | "echo" | <real adapter name>,
  schema      = <table: model/stream params>,
  setup       = function(self, opts) end,
  map_roles   = function(self, messages) -> messages,
  chat_output = function(self, data, tools) -> lines,
  format_data = function(self, data) -> table,
  stream      = function(self, params, callback) -> handle,
}
-- stream callback: { on_chunk(delta)?, on_done()?, on_error(err)? }
--   exactly one terminal (on_done xor on_error) per stream
-- handle: { cancel = function(on_cancelled?) -> boolean, active = boolean }
```

- Add real adapters to this surface; keep mock/echo conformant.
- `handle.cancel` is a zero-arg/optional-callback closure — call it with no `self`.

## Normalized message (conversation)

```lua
{ role="user"|"assistant"|"system"|"tool", content=string|nil,
  tools={ calls=... }?, opts={}?, _meta={ id, index, cycle },
  context?=nil, reasoning?=nil }
```

- `_meta.id` stable & immutable; `_meta.index` monotonic; `_meta.cycle` = regen
  generation for the same index. `validate` returns `nil` on success, an error
  table on failure (Lua protocol).

## Events bus

- `on(event, cb) / once / emit(event, payload) -> envelope`, callback
  `cb(payload, envelope)`; envelope `{ event, sequence, payload, emitted_at }`.
- sequence monotonic per bus; single callback failure is pcall-isolated.
- Extend the name set (add) only; names live on `M.events`.

## Config (LazyVim opts) / state (fail-closed)

- Configuration follows LazyVim rules: defaults in `lua/maxa/init.lua` `M.defaults`
  (comments are the documentation); users override via `lua/plugins/maxa.lua` `opts`;
  `config.configure` deep-merges and validates fail-closed (unknown top-level keys,
  protocol enum, capability matrix, literal-secret rejection); credentials enter
  only by env-var name (`api_key_env`). There is NO `.maxa/runtime.yaml` config layer.
- `.maxa/state.yaml` is the only `.maxa/` state file (formal name, yaml; role like
  SuperMax `.supermax/_meta.yaml`), read/written via `config.load_state`/`save_state`;
  missing state is "not initialized", not a config error.
- Extension content follows CodeCompanion file conventions (not opts):
  `.maxa/mcp/servers.yaml`, `.maxa/skills/`; `.supermax/` is never a runtime root.
- YAML decode via `config/yaml.lua` (TinyYaml wrapper) for `state.yaml` only.
  TinyYaml is tolerant of some malformed flow/quote syntax; the real fail-closed
  guarantee is enforced in `config.configure` (opts validation) and `load_state`
  (decode contract).

## State machine (session/orchestrator)

```text
idle --submit--> busy(streaming) --on_done--> completed -> idle
                                   --on_error--> failed  -> idle
                                   --cancel----> cancelled -> idle
```

- Duplicate submit while busy is rejected (no second request identity).
- `completed/failed/cancelled` fire as terminal exactly once per request.

## Authoritative references

- `.supermax/phase0-development-plan.md` §4 (only contracts) / §10 (rework notes).
- `AGENTS.md` Dependency Policy (higher authority).
- `.supermax/specs/implementation-sequence.md` (phase roadmap), `.supermax/specs/`
  module specs (runtime-fixture-contract, protocol-fixture-contract).
