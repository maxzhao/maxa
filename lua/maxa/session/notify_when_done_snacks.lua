-- Optional editor UI integration; completion-listener state lives in notify_when_done.
local M = {}

function M.setup()
  local snacks = rawget(_G, "Snacks")
  if type(snacks) ~= "table" or not snacks.toggle then return end

  snacks.toggle({
    id = "maxa_ai_notify_when_done_default",
    name = "Maxa AI completion listener default",
    get = function()
      return require("maxa.session.notify_when_done").default_enabled()
    end,
    set = function(enabled)
      require("maxa.session.notify_when_done").set_default(enabled)
    end,
    notify = false, -- set_default already reports success/failure.
  }):map("<leader>aN")
end

return M
