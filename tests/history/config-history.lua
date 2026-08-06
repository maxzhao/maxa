-- filepath: tests/history/config-history.lua
--- Phase-4 W4-B history config block validation:
---   * defaults from lua/maxa/init.lua M.defaults.history pass configure;
---   * valid overrides pass (auto_save=false, title_provider="first_user"/"none",
---     expiration_days=30, refresh_every_n_prompts=5, format_title fn);
---   * fail-closed typed errors: title_provider="bogus", expiration_days=-1,
---     auto_save="yes", refresh_every_n_prompts=-2, max_refreshes=0,
---     title_generation_opts.format_title="string", unknown history keys.
---
--- Fixture convention: prints HISTORY_OK: config-history on success; throws.

local assert_mod = require("tests.history.lib.assert")
local config = require("maxa.runtime.config")
local maxa_mod = require("maxa")

local ctx = assert_mod.new()

-- 1. Bundled defaults configure cleanly (history stays opt-in: enabled=false).
do
  local cfg, err = config.configure(maxa_mod.defaults, {})
  ctx.check(cfg ~= nil, "config-history: defaults configure (err=" .. tostring(err and err.message) .. ")")
  if cfg then
    ctx.assert_eq(cfg.history.enabled, false, "config-history: default enabled=false")
    ctx.assert_eq(cfg.history.auto_save, true, "config-history: default auto_save=true")
    ctx.assert_eq(cfg.history.continue_last, false, "config-history: default continue_last=false")
    ctx.assert_eq(cfg.history.title_provider, "auto", "config-history: default title_provider=auto")
    ctx.assert_eq(cfg.history.expiration_days, 0, "config-history: default expiration_days=0")
    ctx.assert_eq(cfg.history.title_generation_opts.refresh_every_n_prompts, 0, "config-history: default refresh_every_n_prompts=0")
    ctx.assert_eq(cfg.history.title_generation_opts.max_refreshes, 3, "config-history: default max_refreshes=3")
  end
end

-- 2. Valid overrides pass.
do
  local format_title = function(t)
    return "[maxa] " .. t
  end
  local cfg, err = config.configure(maxa_mod.defaults, {
    history = {
      enabled = true,
      auto_save = false,
      continue_last = true,
      title_provider = "first_user",
      expiration_days = 30,
      title_generation_opts = { refresh_every_n_prompts = 5, max_refreshes = 2, format_title = format_title },
    },
  })
  ctx.check(cfg ~= nil, "config-history: full valid override (err=" .. tostring(err and err.message) .. ")")
  if cfg then
    ctx.assert_eq(cfg.history.enabled, true, "config-history: enabled=true")
    ctx.assert_eq(cfg.history.auto_save, false, "config-history: auto_save=false")
    ctx.assert_eq(cfg.history.continue_last, true, "config-history: continue_last=true")
    ctx.assert_eq(cfg.history.title_provider, "first_user", "config-history: title_provider=first_user")
    ctx.assert_eq(cfg.history.expiration_days, 30, "config-history: expiration_days=30")
    ctx.assert_eq(cfg.history.title_generation_opts.refresh_every_n_prompts, 5, "config-history: refresh_every_n_prompts=5")
    ctx.assert_eq(cfg.history.title_generation_opts.max_refreshes, 2, "config-history: max_refreshes=2")
    ctx.assert_eq(cfg.history.title_generation_opts.format_title, format_title, "config-history: format_title fn kept")
  end
  local cfg_none, err_none = config.configure(maxa_mod.defaults, {
    history = { enabled = true, title_provider = "none" },
  })
  ctx.check(cfg_none ~= nil, "config-history: title_provider=none valid (err=" .. tostring(err_none and err_none.message) .. ")")
end

-- 3. Fail-closed typed errors.
do
  local bad_provider, err_provider = config.configure(maxa_mod.defaults, { history = { title_provider = "bogus" } })
  ctx.check(bad_provider == nil and err_provider ~= nil, "config-history: title_provider=bogus rejected")
  if err_provider then
    ctx.check(err_provider.code == "invalid_argument", "config-history: typed invalid_argument (got " .. tostring(err_provider.code) .. ")")
  end

  local bad_days, err_days = config.configure(maxa_mod.defaults, { history = { expiration_days = -1 } })
  ctx.check(bad_days == nil and err_days ~= nil, "config-history: expiration_days=-1 rejected")

  local bad_auto, err_auto = config.configure(maxa_mod.defaults, { history = { auto_save = "yes" } })
  ctx.check(bad_auto == nil and err_auto ~= nil, "config-history: auto_save='yes' rejected")

  local bad_continue, _ = config.configure(maxa_mod.defaults, { history = { continue_last = 1 } })
  ctx.check(bad_continue == nil, "config-history: continue_last=1 rejected")

  local bad_refresh, err_refresh = config.configure(maxa_mod.defaults, {
    history = { title_generation_opts = { refresh_every_n_prompts = -2 } },
  })
  ctx.check(bad_refresh == nil and err_refresh ~= nil, "config-history: refresh_every_n_prompts=-2 rejected")

  local bad_max, err_max = config.configure(maxa_mod.defaults, {
    history = { title_generation_opts = { max_refreshes = 0 } },
  })
  ctx.check(bad_max == nil and err_max ~= nil, "config-history: max_refreshes=0 rejected")

  local bad_fmt, err_fmt = config.configure(maxa_mod.defaults, {
    history = { title_generation_opts = { format_title = "not-a-function" } },
  })
  ctx.check(bad_fmt == nil and err_fmt ~= nil, "config-history: format_title string rejected")

  local bad_tgo, err_tgo = config.configure(maxa_mod.defaults, { history = { title_generation_opts = 42 } })
  ctx.check(bad_tgo == nil and err_tgo ~= nil, "config-history: title_generation_opts non-table rejected")

  local bad_key, err_key = config.configure(maxa_mod.defaults, { history = { unknown_switch = true } })
  ctx.check(bad_key == nil and err_key ~= nil, "config-history: unknown history key rejected")
end

if not ctx.ok then
  error("config-history failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: config-history")
