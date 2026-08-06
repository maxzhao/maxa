-- filepath: tests/config/verify-ui-status.lua
--- W5 headless verification: ui/status config blocks (supermax-configuration spec).
---
--- Covers the phase-5 W5 additions to the LazyVim-opts configuration model:
---   * M.defaults new fields exist with the documented defaults:
---       ui.start_in_insert = false, ui.spinner_delay = 300,
---       status.lualine = { enabled = true, show_spinner = true, show_usage = true },
---       status.billing = { enabled = false, provider = nil }.
---   * legal merge: user opts override ui.start_in_insert / spinner_delay and
---     status.lualine / status.billing sub-blocks (deep merge keeps siblings).
---   * fail-closed ui block: unknown sub-keys rejected; start_in_insert must be
---     boolean; spinner_delay must be a non-negative integer; layout enum.
---   * fail-closed status block: unknown sub-keys rejected; lualine flags are
---     booleans; billing.enabled boolean; billing.provider nil | function | module
---     name (empty module name rejected).
---
--- Offline; no network, no key. Exit contract: returns true on success; the
--- caller (just recipe / acceptance command) turns a false/error into `:cq`.
local ok_all = true
local failures = {}
local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("VERIFY_FAIL: " .. msg)
  end
end
local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end
-- Ensure LazyVim ecosystem (plenary.path) is require-able before loading config.
local function ensure_ecosystem()
  local ok, _ = pcall(require, "plenary.path")
  if not ok then
    error("tests/config/verify-ui-status.lua: plenary.path not require-able (LazyVim ecosystem missing)")
  end
end
ensure_ecosystem()
local config = require("maxa.runtime.config")
local maxa_mod = require("maxa")

------------------------------------------------------------
-- 1. M.defaults new fields exist with documented defaults
------------------------------------------------------------
do
  local ui = maxa_mod.defaults.ui
  check(type(ui) == "table", "1: defaults.ui is a table")
  if type(ui) == "table" then
    assert_eq(ui.start_in_insert, false, "1: defaults.ui.start_in_insert == false")
    assert_eq(ui.spinner_delay, 300, "1: defaults.ui.spinner_delay == 300")
  end
  local status = maxa_mod.defaults.status
  check(type(status) == "table", "1b: defaults.status is a table")
  if type(status) == "table" then
    assert_eq(status.lualine and status.lualine.enabled, true, "1b: defaults.status.lualine.enabled == true")
    assert_eq(status.lualine and status.lualine.show_spinner, true, "1b: defaults.status.lualine.show_spinner == true")
    assert_eq(status.lualine and status.lualine.show_usage, true, "1b: defaults.status.lualine.show_usage == true")
    assert_eq(status.billing and status.billing.enabled, false, "1b: defaults.status.billing.enabled == false")
    assert_eq(status.billing and status.billing.provider, nil, "1b: defaults.status.billing.provider == nil")
  end
  -- The defaults tree itself must pass fail-closed validation (defaults are valid).
  local cfg, cerr = config.configure(maxa_mod.defaults, {})
  check(cfg ~= nil, "1c: default tree validates (err=" .. tostring(cerr and cerr.message) .. ")")
end

------------------------------------------------------------
-- 2. Legal merge: ui/status sub-blocks deep-merge over defaults
------------------------------------------------------------
do
  local cfg, cerr = config.configure(maxa_mod.defaults, {
    ui = { start_in_insert = true },
    status = {
      lualine = { show_spinner = false },
      billing = {
        enabled = true,
        provider = function()
          return { available = false }
        end,
      },
    },
  })
  check(cfg ~= nil, "2: ui/status legal merge ok (err=" .. tostring(cerr and cerr.message) .. ")")
  if cfg then
    assert_eq(cfg.ui.start_in_insert, true, "2: ui.start_in_insert merged")
    assert_eq(cfg.ui.spinner_delay, 300, "2: ui.spinner_delay default kept (deep merge)")
    assert_eq(cfg.ui.show_reasoning, false, "2: ui.show_reasoning default kept")
    assert_eq(cfg.status.lualine.show_spinner, false, "2: status.lualine.show_spinner merged")
    assert_eq(cfg.status.lualine.show_usage, true, "2: status.lualine.show_usage default kept")
    assert_eq(cfg.status.billing.enabled, true, "2: status.billing.enabled merged")
    check(type(cfg.status.billing.provider) == "function", "2: status.billing.provider function kept")
  end
end

------------------------------------------------------------
-- 3. Fail-closed: ui block unknown keys / wrong types
------------------------------------------------------------
do
  local bad_ui_key, err_ui_key = config.configure(maxa_mod.defaults, { ui = { bogus = 1 } })
  check(bad_ui_key == nil and err_ui_key ~= nil, "3: ui unknown sub-key rejected fail-closed")

  local bad_start, err_start = config.configure(maxa_mod.defaults, { ui = { start_in_insert = "yes" } })
  check(bad_start == nil and err_start ~= nil, "3b: ui.start_in_insert non-boolean rejected")

  local bad_delay_neg, _ = config.configure(maxa_mod.defaults, { ui = { spinner_delay = -1 } })
  check(bad_delay_neg == nil, "3c: ui.spinner_delay negative rejected")

  local bad_delay_float, _ = config.configure(maxa_mod.defaults, { ui = { spinner_delay = 1.5 } })
  check(bad_delay_float == nil, "3d: ui.spinner_delay fractional rejected")

  local bad_delay_str, _ = config.configure(maxa_mod.defaults, { ui = { spinner_delay = "300" } })
  check(bad_delay_str == nil, "3e: ui.spinner_delay string rejected")

  local bad_layout, _ = config.configure(maxa_mod.defaults, { ui = { layout = "center" } })
  check(bad_layout == nil, "3f: ui.layout outside enum rejected")

  -- Legal boundaries: spinner_delay 0 (immediate) and non-zero are valid.
  local ok_delay0, err_delay0 = config.configure(maxa_mod.defaults, { ui = { spinner_delay = 0 } })
  check(ok_delay0 ~= nil, "3g: ui.spinner_delay 0 legal (err=" .. tostring(err_delay0 and err_delay0.message) .. ")")
end

------------------------------------------------------------
-- 4. Fail-closed: status block unknown keys / wrong types
------------------------------------------------------------
do
  local bad_status_key, err_status_key = config.configure(maxa_mod.defaults, { status = { bogus = 1 } })
  check(bad_status_key == nil and err_status_key ~= nil, "4: status unknown sub-key rejected fail-closed")

  local bad_lualine_key, _ = config.configure(maxa_mod.defaults, {
    status = { lualine = { bogus = true } },
  })
  check(bad_lualine_key == nil, "4b: status.lualine unknown sub-key rejected")

  local bad_lualine_type, _ = config.configure(maxa_mod.defaults, {
    status = { lualine = { enabled = "true" } },
  })
  check(bad_lualine_type == nil, "4c: status.lualine.enabled non-boolean rejected")

  local bad_billing_key, _ = config.configure(maxa_mod.defaults, {
    status = { billing = { bogus = 1 } },
  })
  check(bad_billing_key == nil, "4d: status.billing unknown sub-key rejected")

  local bad_billing_enabled, _ = config.configure(maxa_mod.defaults, {
    status = { billing = { enabled = 1 } },
  })
  check(bad_billing_enabled == nil, "4e: status.billing.enabled non-boolean rejected")

  local bad_billing_provider, _ = config.configure(maxa_mod.defaults, {
    status = { billing = { enabled = true, provider = 123 } },
  })
  check(bad_billing_provider == nil, "4f: status.billing.provider non-function/non-string rejected")

  local bad_billing_provider_empty, _ = config.configure(maxa_mod.defaults, {
    status = { billing = { enabled = true, provider = "" } },
  })
  check(bad_billing_provider_empty == nil, "4g: status.billing.provider empty module name rejected")

  -- Legal: module-name string provider.
  local ok_provider_str, err_provider_str = config.configure(maxa_mod.defaults, {
    status = { billing = { enabled = true, provider = "maxa.runtime.status.billing" } },
  })
  check(
    ok_provider_str ~= nil,
    "4h: status.billing.provider module-name legal (err="
      .. tostring(err_provider_str and err_provider_str.message)
      .. ")"
  )

  -- Legal: status.lualine fully disabled + billing untouched defaults.
  local ok_lualine_off, err_lualine_off = config.configure(maxa_mod.defaults, {
    status = { lualine = { enabled = false, show_spinner = false, show_usage = false } },
  })
  check(
    ok_lualine_off ~= nil,
    "4i: status.lualine all-false legal (err=" .. tostring(err_lualine_off and err_lualine_off.message) .. ")"
  )
end

if ok_all then
  print("CONFIG_UI_STATUS_VERIFY_OK")
else
  print("CONFIG_UI_STATUS_VERIFY_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
