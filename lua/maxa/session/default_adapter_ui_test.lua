-- Run: nvim --headless -u NONE -l lua/maxa/session/default_adapter_ui_test.lua

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then print("PASS " .. name) else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

local selections, clears = {}, {}
local state = {
  project_root = function() return "/tmp/project" end,
  current_scope = function(scope)
    if scope == "project" then
      return { adapter = "http-a", model = "model-a", inherited = true }
    end
    return { adapter = "http-a", model = "model-a" }
  end,
  clear = function(opts) table.insert(clears, opts); return true end,
  persist = function() return true end,
  validate = function() return true end,
}
package.loaded["maxa.session.default_adapter"] = state
package.loaded["maxa.mcphub.native_servers.config"] = { get_adapter = function() return { adapter = "http-a", model = "model-a" } end }
package.loaded["maxa.config"] = { adapters = { http = { ["http-a"] = {} } } }
package.loaded["maxa.session.default_adapter_ui"] = nil

local old_select, old_notify = vim.ui.select, vim.notify
vim.notify = function() end
vim.ui.select = function(items, opts, cb)
  table.insert(selections, { items = items, opts = opts, cb = cb })
end
local ui = require("maxa.session.default_adapter_ui")

test("adapter picker exposes clear and tab in global scope", function()
  ui.select_default({ scope = "global", project_root = "/tmp/project" })
  local pick = selections[#selections]
  assert(pick.items[1].__clear_default_override)
  assert(pick.opts.prompt:find("%[Global%]"))
  assert(pick.opts.snacks.win.input.keys["<Tab>"])
  assert(pick.opts.snacks.win.list.keys["<Tab>"])
end)

test("tab reopens adapter stage in project scope", function()
  local pick = selections[#selections]
  local action = pick.opts.snacks.actions.switch_default_scope
  action({ close = function() end })
  vim.wait(30)
  local switched = selections[#selections]
  assert(switched.opts.prompt:find("%[Project: project%]"))
  assert(switched.opts.prompt:find("inherited"))
end)

test("clear dispatches current project scope and opens no model picker", function()
  local before = #selections
  local pick = selections[#selections]
  pick.cb(pick.items[1])
  assert(#selections == before)
  assert(clears[#clears].scope == "project")
  assert(clears[#clears].project_root == "/tmp/project")
end)

vim.ui.select, vim.notify = old_select, old_notify
print(string.format("RESULT %d passed, %d failed", total - failed, failed))
if failed > 0 then vim.cmd("cquit 1") end
