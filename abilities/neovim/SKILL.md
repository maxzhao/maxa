---
name: neovim
description: Execute Lua in the current Neovim and query symbols, navigation, references, hover, diagnostics and one-hop call relations through read-only LSP.
compatibility: Requires Maxa builtin extensions and Neovim 0.11+; LSP queries also require enabled installed configurations supporting the requested operation.
---

# Neovim Lua execution and read-only LSP

Load this Ability before using its `run`/`search`/`read` extensions. Loading enables them only in the invoking Chat/workspace; ordinary commands, filesystem searches and reads retain their default behavior. LSP queries are read-only; no Rename, Code Action, formatting or source writes. Lua executes arbitrary code in the current Neovim process and may modify editor state or files; it is not sandboxed.

## Current-Neovim Lua execution

Call `run` with `scope="@neovim:lua"`, a nonblank `title`, and Lua source in `command`. `@neovim:lua` is a scope selector, not an MCP tool address. The standalone `lua` builtin is retired; migrate its `code` parameter to `command`.

- Execution uses `nvim_exec2` with output capture in the current Neovim, not another process. `command` must be nonblank; in JSON, use `\n` for code newlines and `\\n` inside Lua strings. Prefer `vim.print()` / `vim.inspect()` for structured output.
- Omit `args`, `cwd`, `timeout` and `opts`. A cwd equal to the Chat root and neutral `opts.async=false|null` are accepted without changing execution. Other cwd values, arguments, timeouts and execution options error.
- Execution is synchronous and can block Neovim; no hard timeout or cancellable background Lua task is provided. `multicall` can dispatch this scope, but its scheduling does not make Lua execute concurrently or interrupt blocking code. Use `mode="sequence"` with default `on_error="stop"` for fixed dependent editor-state operations; issue separate calls when later arguments need an earlier result.
- Output is returned as text; empty output returns `Code executed successfully. (No output)`. Oversized output returns a preview, full temporary log path and size. Exceptions are tool errors, and side effects before an exception are not rolled back. An unloaded or failing extension never falls back to Shell execution.

```yaml
- load: {target: "neovim"}
- run:
    title: "Inspect current buffer"
    scope: "@neovim:lua"
    command: "vim.print(vim.api.nvim_get_current_buf())"
```

## Scope

| `scope` | Search |
| --- | --- |
| `@neovim:symbols` | Current Chat project, all detected languages with enabled LSP configurations |
| `@neovim:symbols:lua` | Project symbols for native filetype `lua` |
| `@neovim:symbols:xxxx_xxx` | Project symbols for that configured filetype label |
| `@neovim:symbols:lua/xxx.lua` | One project-relative code file |
| `@neovim:symbols:./lua/xxx.lua` | Same, with explicit `./` |
| `@neovim:symbols:/absolute/path/xxx.lua` | One absolute code file, including outside the Chat project |

The selector is implemented by this Ability, not a framework namespace requirement. After the colon, a basename with a suffix selects a file; otherwise the value selects a language. Relative paths resolve from the Chat cwd. Native filetype dots become underscores externally (for example `yaml.docker-compose` → `yaml_docker-compose`); mapping comes from actual enabled configurations, not blindly replacing underscores. Unknown or ambiguous labels error.

```yaml
- load: {target: "neovim"}
- search:
    scope: "@neovim:symbols:lua"
    text: "parse_metadata"
    max_results: 10
- search:
    scope: "@neovim:symbols:lua/maxa/abilities/catalog.lua"
    text: "parse_metadata"
```

## Query and results

- Supply exactly one of `text` or `regex`: a nonempty string or nonempty string list with OR semantics. `patterns` and `literal` are removed; null/empty queries and mixed fields error.
- Project/language `text` sends native `workspace/symbol` queries; matching is server-defined, not guaranteed exact/case matching. `regex` sends an empty query to applicable providers, then filters returned symbol names with ripgrep's default Rust regex engine. Results disclose `completeness=unknown`: zero matches only describes returned candidates, not absence in the project. A rejected empty query is an error.
- File searches send `textDocument/documentSymbol`, flatten nested symbols and filter names using case-sensitive literal substring `text` or Rust `regex`.
- Regex filtering uses runtime-host `rg`, not Lua patterns or Vim regex; missing rg/invalid expressions error without fallback, including empty candidate sets. Filtering precedes output deduplication/count limits. Candidate safety bounds are 10,000 records / 1 MB of names and are explicitly marked when reached.
- `output=matches`: `file:line:column:symbol [kind]`; coordinates are 1-based and columns are UTF-8 byte columns. Paths inside the Chat project are relative; explicit outside-project files use absolute paths. Header identifies the LSP method/source.
- `output=files`: each matching file once. `max_results` is an optional positive limit after deduplication; truncation is marked. Large output uses existing bounded output/temp files.
- Omitted/null/default `case=sensitive`, `hidden=false`, and `no_ignore=false` are neutral. Other values are unsupported and error. `include`/`exclude` must be omitted/null/empty arrays.

## On-demand startup and failures

The extension starts or reuses enabled, already installed LSP configurations internally and waits for initialization. Users do not need to open a code file. It prepares hidden buffers from existing source files, preserves loaded user buffers, never opens a window, and removes buffers it created after completion/cancellation. Project discovery inspects filenames to choose representative filetypes; it does not open/index every file or install/configure a server.

Project/language queries require `workspace/symbol`; file queries require `textDocument/documentSymbol`. After initialization, query only applicable clients supporting that method; skip auxiliary clients without it and identify only queried providers in the output. If no applicable client supports the method, return an explicit error. Missing configuration, startup failure, request/position errors, or the combined 10-second startup/query/filtering deadline remain tool errors, never filesystem fallback. Cancellation stops LSP requests and the filter process; source changes and late callbacks cannot produce a stale success. `run(scope="tool")` and tool-mode `multicall` members wrapping the builtin use the same extension and cooperative cancellation.

Results reflect the server's index. Supporting `workspace/symbol` does not guarantee every symbol is indexed; zero results are not proof of absence.

## Position-based semantic search

Use an explicit file followed by `:<line>:<column>`, both positive 1-based integers; column is a UTF-8 byte offset, including end-of-line. Addresses parse from the right, preserving path colons. Relative paths resolve from Chat cwd; absolute files remain absolute. Missing/out-of-range positions, multibyte-character interior bytes and inaccessible/non-code files error. Never substitute the editor cursor or a name-only guess.

| `search.scope` operation | LSP method |
| --- | --- |
| `@neovim:definition:<file>:<line>:<column>` | `textDocument/definition` |
| `@neovim:declaration:<file>:<line>:<column>` | `textDocument/declaration` |
| `@neovim:implementation:<file>:<line>:<column>` | `textDocument/implementation` |
| `@neovim:type-definition:<file>:<line>:<column>` | `textDocument/typeDefinition` |
| `@neovim:references:<file>:<line>:<column>` | `textDocument/references`, exclude declaration |
| `@neovim:references-with-declaration:<file>:<line>:<column>` | `textDocument/references`, include declaration |
| `@neovim:incoming-calls:<file>:<line>:<column>` | Prepare call hierarchy, then one incoming hop |
| `@neovim:outgoing-calls:<file>:<line>:<column>` | Prepare call hierarchy, then one outgoing hop |

- Omit `text`/`regex` for unfiltered results. `text` applies case-sensitive literal-substring OR over rendered result rows; `regex` uses the same Rust engine on those rows. `text="*"` matches a real star, not an unfiltered sentinel. These rules do not change symbol-name matching above.
- `output=matches` returns destination ranges or caller/callee relations and call-site ranges, in 1-based UTF-8 byte coordinates. `output=files` returns unique destination files (incoming caller files / outgoing callee files). Paths inside Chat cwd are relative; external dependency files may be absolute.
- Equivalent locations/relations deduplicate with provider attribution. Multiple prepared call items remain separate; no UI choice or recursive graph. `max_results` limits filtered deduplicated results and marks truncation; hard output bounds also mark truncation.
- The neutral/unsupported search options above also apply. Supported empty responses state `0 results`; missing capability, invalid URI/coordinates and request failures are errors.

```yaml
- search:
    scope: "@neovim:definition:tools/blender-cli/foundation.js:200:27"
- search:
    scope: "@neovim:incoming-calls:tools/blender-cli/foundation.js:38:17"
    max_results: 10
```

## Hover and diagnostics through read

| `read.path` | Report |
| --- | --- |
| `@neovim:hover:<file>:<line>:<column>` | Each supporting provider's Markdown/plaintext type/signature/documentation, without floating UI |
| `@neovim:diagnostics:<file>` | File diagnostics/status, prefer pull reports; otherwise observed push/cache |
| `@neovim:diagnostics` | Existing project-local LSP cache only: `coverage=known-cache`, not a project check |

File operations use loaded user-buffer text before disk text (`source=buffer|disk`), synchronize it through hidden request buffers and convert positions per provider encoding. A source change during a request errors as `stale-source`. User buffers/unsaved edits/windows remain unchanged. Applicable initialized providers are filtered by method; push diagnostics do not require pull support.

Diagnostics disclose provider, source, count and `freshness=current|stale|unknown`, even for empty reports. Current requires source-associated full/matching unchanged pull, or observed versioned push; earlier source is stale. Missing/unversioned evidence is unknown, not a clean file. Rows identify file/range, severity, message, provider and optional code/source. A current zero-item report establishes only that provider's report has no diagnostics. Known-project reads never start servers or scan/open all files and exclude unrelated workspaces/non-LSP namespaces; zero known entries do not mean a clean project.

Semantic reads reuse the ordinary `next_cursor` header, 20,000-byte limit, ranges and result policies. `start_line`/`end_line` select rendered report lines, not source coordinates. A cursor continues the frozen report without another LSP request; use the same address/policy/Chat/workspace. Missing/expired snapshots error and require a new initial read. Snapshots expire after five minutes, retain at most eight reports / 4 MB per Chat, and are not persisted across Neovim restarts. A report exceeding 4 MB errors. `temporary`/`persist` retain normal result TTL semantics.

```yaml
- read: {path: "@neovim:hover:tools/blender-cli/foundation.js:200:27"}
- read: {path: "@neovim:diagnostics:tools/blender-cli/foundation.js"}
- read: {path: "@neovim:diagnostics"}
```

## Package ownership

`ABILITY.yaml` declares `builtin_extensions: [search, read, run]`; fixed `builtin/search.lua`, `builtin/read.lua` and `builtin/run.lua` own matching/execution with package-local helpers. They are current-Neovim code, not external-process or reference entrypoints. Installed declarations/code remain user-editable and later calls use changes without reload or renewed authorization. LSP operations through direct search/read, `run(scope="tool")` and tool-mode `multicall` members share dispatch, exact caller identity, cancellation and a single 10-second startup/request/filtering deadline. Lua execution through `run(scope="@neovim:lua")` and `multicall` members uses the same loaded-Ability dispatch without an LSP deadline.
