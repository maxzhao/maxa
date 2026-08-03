# maxa

> A comprehensive developer agent harness that turns Neovim into your agentic IDE.

**maxa** is an extensible, all-in-one agentic IDE harness for developers who use Neovim
as their editor. It is built as a self-contained working environment on top of
[LazyVim/starter](https://github.com/LazyVim/starter.git) and grows into a full agent
runtime that orchestrates assistants, tools, and model protocols from inside your editor.

- **Developer-first.** Built for people who live in Neovim while working on other
  projects — your editor is the harness, not the product.
- **Agentic by default.** A growing runtime that turns editing into an agentic workflow:
  conversation, sessions, tool execution, and provider-agnostic model protocols, all
  driven in-editor.
- **Lean foundation.** LazyVim is the only runtime dependency. No other agent/plugin
  stack is assumed — the harness is designed to be extended, not replaced.
- **Self-contained and isolated.** The runtime is validated in a dedicated environment
  and never interferes with your main Neovim configuration.

## Layout

```
<clone-path>/
├── init.lua               # lazy.nvim / LazyVim bootstrap
├── lua/
│   ├── config/            # options, keymaps, autocmds, lazy.lua
│   └── plugins/           # lazy.nvim plugin specs
├── .supermax/             # project knowledge Vault + spec drafts
├── specs/                 # behavior specs and implementation plan
├── LICENSE                # Apache-2.0 (from LazyVim/starter)
├── stylua.toml
└── README.md
```

## Enable

Clone the harness and wire it into Neovim. Both approaches work; pick whichever fits
your workflow.

### Option A — Symlink / copy into `~/.config/nvim`

```bash
git clone https://github.com/maxzhao/maxa.git <clone-path>
ln -s <clone-path> ~/.config/nvim
nvim
```

Or, without a symlink, copy the tree into your active config:

```bash
rsync -a --exclude=.git <clone-path>/ ~/.config/nvim/
nvim
```

### Option B — Isolated via `NVIM_APPNAME`

Keep the harness fully independent of your main config:

```bash
git clone https://github.com/maxzhao/maxa.git <clone-path>
NVIM_APPNAME=nvim-maxa nvim  # after wiring <clone-path> into ~/.config/nvim-maxa
```

Symlink your clone into the app-specific config directory so LazyVim state and
`runtimepath` stay namespaced and won't collide with other Neovim setups.

> First launch clones `lazy.nvim`, downloads LazyVim and its plugins, and then
> installs the configured tools. Subsequent launches are fast.

## Configuration

- `lua/config/options.lua`, `lua/config/keymaps.lua`, `lua/config/autocmds.lua` — tune
  editor behavior.
- `lua/plugins/` — one file per plugin spec; every spec under this directory is loaded
  automatically by lazy.nvim.
- `lua/plugins/example.lua` — reference examples (colorscheme, treesitter, lualine,
  mason, LSP, telescope, trouble, nvim-cmp).

## Community

Join the **maxa** community:

- **QQ 群 `maxa 官方群`**: `700926364`
- **Telegram `maxa (official)`**: <https://t.me/+SzvSYXmACKg1NWE9>

## Resource

- LazyVim: <https://www.lazyvim.org>
- Inspiration: <https://github.com/LazyVim/starter> — this repository derives its
  scaffolding from the LazyVim starter and keeps the Apache-2.0 license.

## License

This project is released under the Apache-2.0 License, inherited from
[LazyVim/starter](https://github.com/LazyVim/starter.git). See `LICENSE`.
