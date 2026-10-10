local M = {}

function M.setup(opts)
  opts = opts or {}
  require("maxa.session.status.billing").register_defaults()
  require("maxa.session.status.state").setup(opts.state or {})
  require("maxa.session.status.spinner").setup(opts.spinner or {})
end

function M.state()
  return require("maxa.session.status.state")
end

function M.lualine()
  return require("maxa.session.status.lualine")
end

function M.billing()
  return require("maxa.session.status.billing")
end

function M.context_limits()
  return require("maxa.session.status.context_limits")
end

function M.spinner()
  return require("maxa.session.status.spinner")
end

return M
