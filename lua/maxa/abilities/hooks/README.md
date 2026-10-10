# AbilityHook Runtime

Purpose: define the active runtime ownership and integration contract for AbilityHook discovery, registration, filtering, injection, once state, and restore.

## Owners

| Module | Ownership |
| --- | --- |
| `init.lua` | effective Ability-root discovery, startup preparation, on-load prepare/commit, restore |
| `parser.lua` | Markdown/Lua hook parsing and schema validation |
| `registry.lua` | event registrations, Chat/session/cascade bindings, refresh replacement |
| `fire.lua` | `AbilityHook<Event>` dispatch and exact-buffer injection |
| `filter.lua` | event-data matching |
| `injector.lua` | message rendering, batching, once/ephemeral state, tombstones |

## Package Contract

```text
abilities/<ability>/hooks/<Event>.md
abilities/<ability>/hooks/<Event>.lua
.maxa/abilities/<ability>/hooks/<Event>.md
.maxa/abilities/<ability>/hooks/<Event>.lua
```

One effective file owns each Ability-relative hook path. Project roots precede global roots in a merged Ability. Defining both Markdown and Lua formats for one effective Ability/event is invalid. MCP sources do not install filesystem hooks.

Markdown frontmatter retains the established hook schema: `load`, `scope`, `filter`, `opts`, and `inject_at`. Bodies use `## user` / `## llm` prompt sections. Lua files return one hook table with `render(ctx)`.

## Lifecycle

- Startup discovery is side-effect free with respect to Ability instructions and MCP activation; only `load: startup` hooks register.
- Unified `load` prepares and validates `load: on_load` hooks before the root revision commits.
- Commit replaces that Chat's effective on-load registrations, preserves unchanged logical once identities, then fires `AbilityLoaded` with complete `{bufnr, ability_name}` data.
- Unchanged loads fire no event. Failed preparation/refresh installs nothing. Post-commit handler failure is reported without rolling back the Ability revision.
- Restore uses committed roots and valid Ability names from new-format metadata. Invalid names and retired SkillHook records do not register, replay, or synthesize once state; stored messages remain unchanged.

## Events

Call `fire(event="<Event>", data=<complete-payload>)`; callers omit the `AbilityHook` prefix. The runtime injects `bufnr`. File-operation tools emit `FileOperation`; scripts may emit stderr lines `__FIRE_EVENT__:<json>` through the isolated launcher.

## Validation

Run the focused parser/filter/injection tests and a fresh-Neovim load/restore check. Verify generated system fragments and hook paths use Ability terminology and that no retired event mirroring is active.
