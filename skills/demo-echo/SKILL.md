---
name: demo-echo
description: Bundled maxa demo skill used to verify Skill discovery and loading (phase-3 W5) and the SkillHook machinery (phase-3 W6). Provides a fixed echo instruction fragment as sanitized context; declares no dependencies.
visibility: global
triggers:
  - demo-echo
  - demo skill
dependencies: []
mcp_dependencies: []
resources: []
hooks: []
system: []
---

# Demo Echo

Purpose: bundled demo Skill for the maxa runtime (this file lives in the
repository root `skills/` directory, which is the bundled/config global Skill
root for the `nvim-maxa` target because `~/.config/nvim-maxa` links to this
repository).

## Behavior

- Discovery (`maxa.runtime.skills.discover`) finds this Skill under the global
  root with id `demo-echo` and parses the frontmatter metadata above.
- Loading (`maxa.runtime.skills.loader`) activates it with no dependencies and
  exposes this body as sanitized instruction context.
- Loading never executes project code: `hooks/` files (W6) are declared
  artifacts, not executed during discovery/loading.

## Verification

```bash
NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function() local d='/home/maxzhao/maxa/tests/skills/runner.lua' local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
```
