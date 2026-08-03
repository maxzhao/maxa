# Ecosystem Catalog — maxa runtime horizontal facilities

Authoritative reuse table for generic horizontal capabilities in the maxa
runtime. Read this before writing or keeping anything generic.

## Reuse table (ecosystem facility → where maxa uses it)

| Horizontal capability | Ecosystem facility | maxa usage |
| --- | --- | --- |
| Deep copy | `vim.deepcopy` (builtin) | `conversation` message copies |
| YAML decode | vendored TinyYaml (`config/vendor/tinyyaml.lua`, MIT) | `config/yaml.lua` `.maxa/runtime.yaml` |
| Async coroutines | `plenary.async` | `protocol/init.lua` async stream driver |
| Async sleep / scheduler | `plenary.async.util.sleep`, `.scheduler` | `protocol/init.lua` drive leaves |
| Project root / path walk | `plenary.path` (`find_upwards`, `parent`, `absolute`) | `config/init.lua` project-root binding |
| Floating-window/UI layout | `snacks` (`snacks.layout`, `snacks.win`) | `host/nvim/init.lua` Chat view |
| Serialization | `vim.json` (builtin) | `conversation` to_json/from_json |
| Table utils | `vim.islist` / `vim.tbl_islist` / `vim.tbl_deep_extend` | schema / config merge |
| Monotonic clock | `vim.uv.hrtime` | `events/init.lua` emitted_at |
| File stat | `vim.uv.fs_stat` | `config` load |
| File read | `io.open` (`read("*a")`) | `config` load |
| Command / keymap | `vim.api.nvim_create_user_command`, `vim.keymap.set` | `host/nvim` |
| Buffer line IO / focus | `nvim_buf_get_lines/set_lines`, `nvim_set_current_win` | `host/nvim` render / input |
| Plugin assembly | `lazy.nvim` spec (`dir`, `cmd`, `keys`, `dependencies`, `opts`) | `lua/plugins/maxa.lua` |
| Config override | `vim.tbl_deep_extend("force", ...)` | `lua/maxa/init.lua` setup |

## Kept hand-written set (ecosystem-missing OR maxa-domain)

These are intentionally NOT replaced. Each entry states the reason.

| Kept facility | Location | Reason |
| --- | --- | --- |
| FNV-1a content hash | `conversation`, `config` | Nvim 0.11.5 has no `vim.hash_string`; no pure-Lua standard stabilizing hash in the tree. Evidence-fingerprint / id derivation only. |
| Read-only freeze proxy | `config/init.lua` `freeze` | No deep-freeze facility in plenary/snacks/nui. Domain fail-closed snapshot. |
| ID generators (`os.time` + counter) | `session`, `protocol`, `conversation` | No UUID facility (`vim.fn.uuidgen` absent). Domain id semantics (§4.4). |
| Secret / unknown-key guard | `config/init.lua` | Domain fail-closed config safety. |

## Domain models (redefined surface — extend, never replace)

| Module | What it is | Nvim/LazyVim equivalent? |
| --- | --- | --- |
| `events` | typed bus: on/emit/envelope/sequence/pcall isolation | `autocmd` is low-level Vim events, not an app-layer typed bus; plenary/snacks have none. No equivalent. |
| `schema` | payload validation primitives | plenary has no schema validation. No equivalent. |
| `conversation` | normalized message + identity | No equivalent in the tree. |
| `session`/`orchestrator` | state machine + message loop | No equivalent in the tree. |
| `guard` | import-guard | maxa-specific safety policy. |

## Additions must follow

- New domain logic lives under `lua/maxa/runtime/<module>/`; keep the semantic
  boundaries from `implementation-sequence.md`.
- Generic/new capability: apply the three questions in `SKILL.md` first. If the
  final choice is reuse, record the facility here; if kept, record the reason.
- Any vendored file keeps its license/copyright header and an upstream commit note.

## Validation of this catalog

After adding a reuse row or a kept hand-write, run the closest relevant check:

```bash
cd /home/maxzhao/maxa
just smoke
just lint && just fmt
just check
```
