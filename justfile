# maxa development recipes — freeze project init / test-env startup / validation.
# Requires: just, nvim (>=0.11), stylua. No application build/lint exists beyond these.

set shell := ["bash", "-c"]

# Project root = directory containing this justfile.
root := justfile_directory()

# The isolated LazyVim config directory (soft-link target).
maxa_conf := env_var("HOME") + "/.config/nvim-maxa"   # ~/.config/nvim-maxa soft-link to this repo

# List recipes with descriptions (default `just` target).
default:
    @just --list

# One-time: create ~/.config/nvim-maxa soft link -> this repo.
# Makes `NVIM_APPNAME=nvim-maxa nvim` boot THIS repo's LazyVim config as the
# (clean, LazyVim-only) alternate of ~/.config/nvim, without touching it.
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -L '{{maxa_conf}}' ]; then
      echo "'{{maxa_conf}}' already symlinked -> $(readlink '{{maxa_conf}}')"
    elif [ -e '{{maxa_conf}}' ]; then
      echo "error: '{{maxa_conf}}' exists but is not a symlink; remove or inspect it first" >&2
      exit 1
    else
      ln -s '{{root}}' '{{maxa_conf}}'
      echo "created '{{maxa_conf}}' -> '{{root}}'"
    fi

# Launch the maxa development/test environment.
# Clean, only-LazyVim Neovim using this repo as config; never touches ~/.config/nvim.
run: (setup)
    NVIM_APPNAME=nvim-maxa nvim

# Headless smoke: boot via nvim-maxa soft-link config (project = config dir, so lua/maxa
# is on rtp), then load runtime + import-guard + one echo Chat submit (offline, key-free).
smoke: (setup)
    # Run inside the event loop so lazy.nvim can register plugin runtimes before smoke.lua
    # loads the maxa runtime. `-l` would execute before lazy's startup pass => plenary/snacks
    # missing. Use `-c` + vim.defer_fn, which enters the loop and waits 2s for lazy.
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() d='{{root}}/scripts/smoke.lua' local ok=pcall(dofile,d) vim.cmd('qa!') end, 2000)"

# Headless protocol fixture runner (phase-1 W1): loads tests/protocol/fixtures,
# validates envelopes, runs the comparison-helper self-test, and proves the W1
# infrastructure modules (sse/transport) load. Offline; no network or key.
# Same lazy-wait pattern as smoke. Exit 0 on success; failure prints details
# and exits 1 (the runner itself calls :cq on failure).
test-protocol: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/protocol/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless unit tests for the W1 protocol infrastructure (sse parser + curl
# transport with a fake curl; no network). Offline and deterministic.
test-protocol-unit: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local s='{{root}}/tests/protocol/unit_sse.lua' local a=pcall(dofile,s) if not a then vim.cmd('cq') return end local t='{{root}}/tests/protocol/unit_transport.lua' local b=pcall(dofile,t) vim.cmd(b and 'qa!' or 'cq') end, 2000)"
# Headless W3 config verification: full runtime.yaml schema (struct/map/any), provider
# cross-field checks (default existence, protocol capability matrix), credential guard,
# resolve_provider normalization + adapter bind interface. Offline; no network or key.
test-config: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/config/verify.lua' local ok,res=pcall(dofile,d) if not (ok and res) then vim.cmd('cq') return end vim.cmd('qa!') end, 2000)"

# stylua check
lint:
    stylua --check lua/maxa

# stylua format
fmt:
    stylua lua/maxa

# whitespace / conflict-marker check
check:
    git diff --check
