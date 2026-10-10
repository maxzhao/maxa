-- UI for changing scoped Maxa AI adapter/model defaults.
-- Existing/restored chats are never mutated.

local state = require("maxa.session.default_adapter")

local M = {}
local CLEAR = { __clear_default_override = true, name = "Clear Default Override" }

local function fallback_default()
  local ok, mcp_config = pcall(require, "maxa.mcphub.native_servers.config")
  if not ok then
    return {}
  end
  return mcp_config.get_default("chat") or {}
end

local function scope_label(ctx)
  if ctx.scope == "project" then
    local name = ctx.project_root and vim.fs.basename(ctx.project_root) or "unavailable"
    return "Project: " .. name
  end
  return "Global"
end

local function current_default(ctx)
  return state.current_scope(ctx.scope, ctx.project_root, fallback_default())
end

local function switch_scope(ctx, reopen)
  local next_scope = ctx.scope == "global" and "project" or "global"
  if next_scope == "project" and not ctx.project_root then
    vim.notify("Current buffer does not belong to a project with .maxa", vim.log.levels.WARN)
    return
  end
  local next_ctx = vim.tbl_extend("force", {}, ctx, { scope = next_scope })
  vim.schedule(function()
    reopen(next_ctx)
  end)
end

local function select_opts(prompt, current, ctx, reopen)
  local opts = {
    prompt = prompt,
    kind = "maxa_ai",
    format_item = function(item)
      if type(item) == "table" and item.__clear_default_override then
        return "󰆴 " .. item.name
      end
      local id = type(item) == "table" and (item.id or item.modelId or item.name) or item
      local display = id
      if type(item) == "table" then
        display = item.description or item.formatted_name or item.name or item.id or item.modelId or "Unknown"
      end
      if id == current then
        return "* " .. display
      end
      return "  " .. display
    end,
    snacks = {
      actions = {
        switch_default_scope = function(picker)
          picker:close()
          switch_scope(ctx, reopen)
        end,
      },
      win = {
        input = { keys = { ["<Tab>"] = { "switch_default_scope", mode = { "i", "n" } } } },
        list = { keys = { ["<Tab>"] = "switch_default_scope" } },
      },
    },
  }
  if ctx.allow_scope_switch == false then opts.snacks = nil end
  return opts
end

local function adapter_names(config, current)
  local names, seen = { CLEAR }, {}
  for name in pairs(config.adapters and config.adapters.http or {}) do
    if name ~= "opts" and not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  table.sort(names, function(a, b)
    if type(a) == "table" then
      return true
    elseif type(b) == "table" then
      return false
    end
    return a < b
  end)
  if current and seen[current] then
    for index, name in ipairs(names) do
      if name == current then
        table.remove(names, index)
        table.insert(names, 2, current)
        break
      end
    end
  end
  return names
end

local function model_id(model)
  return type(model) == "table" and (model.id or model.modelId or model.name) or model
end

local function persist(ctx, adapter, model)
  local ok, err = state.persist(adapter, model, { scope = ctx.scope, project_root = ctx.project_root })
  if not ok then
    vim.notify("Failed to set the default model: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify(
    string.format("Set %s default model: %s/%s (new Chats only)", scope_label(ctx), adapter, model),
    vim.log.levels.INFO
  )
end

local function clear(ctx)
  local ok, err = state.clear({ scope = ctx.scope, project_root = ctx.project_root }, fallback_default())
  if not ok then
    vim.notify("Failed to clear the default model: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local fallback = state.current_scope(ctx.scope, ctx.project_root, fallback_default()) or {}
  vim.notify(
    string.format(
      "Cleared %s default override%s",
      scope_label(ctx),
      fallback.adapter and ("; effective default: " .. fallback.adapter .. "/" .. fallback.model) or ""
    ),
    vim.log.levels.INFO
  )
end

local function resolve_http_adapter(adapter_name, current)
  local adapters = require("maxa.adapters")
  if current.adapter == adapter_name and current.model and current.model ~= "" then
    local valid = state.validate(current.adapter, current.model)
    if valid then
      return adapters.resolve({ name = adapter_name, model = current.model })
    end
  end
  return adapters.resolve(adapter_name)
end

local select_http_model
local select_adapter

select_http_model = function(adapter_name, ctx)
  local current, current_err = current_default(ctx)
  if not current then
    vim.notify("Failed to read the default model: " .. tostring(current_err), vim.log.levels.ERROR)
    return
  end
  local change_adapter = require("maxa.interactions.chat.keymaps.change_adapter")
  local ok_resolve, adapter = pcall(resolve_http_adapter, adapter_name, current)
  if not ok_resolve or not adapter then
    vim.notify("Could not resolve adapter: " .. adapter_name .. " - " .. tostring(adapter), vim.log.levels.ERROR)
    return
  end
  if not (adapter.schema and adapter.schema.model) then
    vim.notify("Adapter has no statically selectable models: " .. adapter_name, vim.log.levels.ERROR)
    return
  end
  local ok_models, models = pcall(change_adapter.list_http_models, adapter)
  if not ok_models then
    vim.notify("Failed to read the model list: " .. tostring(models), vim.log.levels.ERROR)
    return
  end
  if not models then
    local model = adapter.schema.model.default
    if type(model) == "function" then
      model = model(adapter)
    end
    if type(model) ~= "string" or model == "" then
      vim.notify("Adapter has no available default model: " .. adapter_name, vim.log.levels.ERROR)
      return
    end
    persist(ctx, adapter_name, model)
    return
  end
  local prompt = string.format("Set Default Model [%s] for %s", scope_label(ctx), adapter_name)
  if ctx.scope == "project" and current.inherited then
    prompt = prompt .. " (inherited: " .. current.adapter .. "/" .. current.model .. ")"
  end
  vim.ui.select(models, select_opts(prompt, current.adapter == adapter_name and current.model or nil, ctx, function(next_ctx)
    select_http_model(adapter_name, next_ctx)
  end), function(model)
    if not model then
      return
    end
    local id = model_id(model)
    if not id or id == "" then
      vim.notify("Invalid model selection", vim.log.levels.ERROR)
      return
    end
    persist(ctx, adapter_name, id)
  end)
end

select_adapter = function(ctx)
  local ok_config, config = pcall(require, "maxa.config")
  if not ok_config then
    vim.notify("Maxa AI configuration is not available yet", vim.log.levels.ERROR)
    return
  end
  local current, current_err = current_default(ctx)
  if not current then
    vim.notify("Failed to read the default model: " .. tostring(current_err), vim.log.levels.ERROR)
    return
  end
  local adapters = adapter_names(config, current.adapter)
  if ctx.scope == "project" then
    adapters[1] = { __clear_default_override = true, name = "Inherit global" }
  end
  if #adapters == 1 then
    vim.notify("No Maxa AI adapters are registered", vim.log.levels.ERROR)
    return
  end
  local prompt = string.format("Set Default Adapter [%s]", scope_label(ctx))
  if current.adapter and current.model then
    local prefix = ctx.scope == "project" and current.inherited and "inherited" or "current"
    prompt = prompt .. string.format(" (%s: %s/%s)", prefix, current.adapter, current.model)
  end
  vim.ui.select(adapters, select_opts(prompt, current.adapter, ctx, select_adapter), function(adapter_name)
    if not adapter_name then
      return
    end
    if type(adapter_name) == "table" and adapter_name.__clear_default_override then
      clear(ctx)
      return
    end
    if config.adapters.http and config.adapters.http[adapter_name] then
      return select_http_model(adapter_name, ctx)
    end
    vim.notify("Adapter is not registered: " .. tostring(adapter_name), vim.log.levels.ERROR)
  end)
end

function M.select_default(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  select_adapter({
    scope = opts.scope or "global",
    project_root = opts.project_root or state.project_root(bufnr),
    allow_scope_switch = opts.allow_scope_switch,
  })
end

M._select_adapter = select_adapter
M._clear_item = CLEAR

return M
