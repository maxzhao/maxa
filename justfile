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
# Headless W3 config verification: LazyVim opts merge/validation (defaults +
# user opts), provider cross-field checks (default existence, protocol capability
# matrix), credential guard, resolve_provider normalization + adapter bind
# interface, state.yaml round-trip. W5/W6 also runs the ui/status sub-block
# checks and the orchestrator sub-block wiring (defaults + fail-closed +
# host consumption). Offline; no network or key.
test-config: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local ok=true for _,d in ipairs({'{{root}}/tests/config/verify.lua','{{root}}/tests/config/verify-ui-status.lua','{{root}}/tests/config/verify-orchestrator.lua'}) do local r,e=pcall(dofile,d) print('CONFIG_FILE', d, r) if not r then print(tostring(e)) ok=false end end vim.cmd(ok and 'qa!' or 'cq') end, 3000)"

# Headless phase-2 R-STATE fixture runner (W2 test base): discovers and runs
# every fixture under tests/state/ (entities + clock determinism), asserts the
# import guard, and drives all timestamps through the deterministic fake clock.
# Offline; no network or key. Exit 0 on success; 1 (cq) on any failure.
test-state: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/state/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
# Headless phase-3 W1 tool-registry fixture runner (tests/tools): registry
# register/resolve/hash semantics, executor sync/async tasks, schema argument
# validation, result durability + display projection, parallel barrier, and the
# W7 tool-fold display projection. Offline; no network or key.
test-tools: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/tools/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
# Headless phase-3 W3 MCP fixture runner (tests/mcp): servers.yaml config
# validation, external stdio lifecycle (spawn/initialize/tools/list/tools/call),
# server registry, native servers, reload/restart/stop/timeout behavior.
# Offline; no network or key (fake processes only).
test-mcp: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/mcp/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
# Headless phase-3 W5/W6 skills fixture runner (tests/skills): three-root
# discovery + shadowing, dependency-topological loader, hook parser/registry/
# fire/injector machinery. Offline; no network or key.
test-skills: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/skills/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
# Headless phase-3 W8 gate end-to-end (tests/p3-gate): real node stdio MCP
# fixture server discovery -> registration -> tools/call JSON-RPC round trip,
# plus demo skill tool registration, through ONE host submit (two tool calls:
# external MCP + skill tool; barrier exactly once; one automatic continuation).
# Local node process only; no network or key.
test-gate: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/p3-gate/gate.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless phase-4 session-history fixture runner (tests/history): schema v1
# envelope + atomic session/index writes + saved-index-stale + legacy
# refs->context_items migration + generation serialization. Fixtures run
# against a temp fixture project root (.maxa/); offline; no network or key.
test-history: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/history/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless chat-ui-render validation (phase 1.5 subpackage 3.1): markdown treesitter
# attach, header/separator extmarks, message structure, incremental append (no rewrite
# jitter), follow-to-bottom, streaming virtual-text cursor, re-render equivalence.
test-ui: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/ui/render.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless chat-ui-input validation (phase 1.5 subpackage 3.3): intro placeholder
# virtual text, session input history + <Up>/<Down> recall, visual selection attach
# as fenced code block. Offline; no network or key.
test-ui-input: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/ui/input.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless chat-ui-actions validation (phase 1.5 subpackage 3.4): keymap registry
# presence, ]] / [[ header navigation, provider picker candidates, keymap help
# float. Offline; no network or key.
test-ui-actions: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/ui/actions.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless chat-ui-status validation (phase 1.5 subpackage 3.5): read-only status
# projection lifecycle (idle/busy spinner/completed usage), spinner determinism,
# lualine component projection. Offline; no network or key.
test-ui-status: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/ui/status.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless chat-ui config wiring validation (phase 1.5 subpackage 3.6): default
# setup safety + ui.show_reasoning flow from LazyVim opts through config.configure
# into host view defaults. Offline; no network or key.
test-ui-config: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/ui/config.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless phase-5 W1 event-bus fixture runner (tests/events): complete envelope
# (event_id/per-session sequence/identity fields), transactional reducers,
# idempotent replay, observer isolation and backward compatibility.
# Offline; no network or key.
test-events: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/events/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless phase-5 W2 status/spine fixture runner (tests/status): immutable spine
# reducer (S-001 counts/provider/model/usage/terminal), lualine read-only
# projection (S-002), spinner phase precedence + delay, billing failure isolation
# and deleted-view safety. Offline; no network or key.
test-status: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/status/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless phase-5 W4 Action/Command registry fixture runner (tests/actions):
# register/discover/dispatch contract, duplicate-hash rejection, requires_idle
# gating, typed failures (never lock the Chat) and built-in operation families
# over mock contexts. Offline; no network or key.
test-actions: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/actions/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless phase-5 W5 prompt-composer fixture runner (tests/prompts): bundled
# fallback (C-001), .maxa/system.md override + placeholder expansion (C-002),
# skill SYSTEM slots (C-003), dump consistency and (integration) schema-version
# classification (C-004). Offline; no network or key.
test-prompts: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/prompts/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# Headless phase-5 W6 wiring validation (tests/host/phase5-wiring.lua): real
# maxa.setup assembles the status spine service and Action/Command registry;
# palette dispatch and typed failures keep the Chat usable.
# Offline; no network or key.
test-phase5-wiring: (setup)
    NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='{{root}}/tests/host/phase5-wiring.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

# stylua check
lint:
    stylua --check lua/maxa

# stylua format
fmt:
    stylua lua/maxa

# whitespace / conflict-marker check
check:
    git diff --check
