local config = require("maxa.config")
local log = require("maxa.utils.log")

local M = {}

---Create options for vim.ui.select with formatting
---@param prompt string The prompt to display
---@param conditional string The item to mark as current
---@return table
local function select_opts(prompt, conditional)
  return {
    prompt = prompt,
    kind = "maxa_ai",
    format_item = function(item)
      if conditional == item then
        return "* " .. item
      end
      return "  " .. item
    end,
  }
end

---Get list of available HTTP adapters
---@param current_adapter string The currently selected adapter
---@return table List of adapter names with current adapter first
function M.get_adapters_list(current_adapter)
  local adapters_list = vim
    .iter(vim.deepcopy(config.adapters.http))
    :filter(function(adapter)
      return adapter ~= "opts" and adapter ~= current_adapter
    end)
    :map(function(adapter, _)
      return adapter
    end)
    :totable()

  table.sort(adapters_list)
  table.insert(adapters_list, 1, current_adapter)
  return adapters_list
end

---Get list of available models for an HTTP adapter
---@param adapter MaxaAI.HTTPAdapter
---@return table|nil
function M.list_http_models(adapter)
  local models = adapter.schema.model.choices
  local show_choices = config.adapters
    and config.adapters.http
    and config.adapters.http.opts
    and config.adapters.http.opts.show_model_choices

  if not show_choices then
    models = { adapter.schema.model.default }
  end
  if type(models) == "function" then
    models = models(adapter, { async = false })
  end
  if not models or vim.tbl_count(models) < 2 then
    return nil
  end

  local current_model_id = adapter.schema.model.default
  if type(current_model_id) == "function" then
    current_model_id = current_model_id(adapter)
  end

  local current_model
  for _, model_str in ipairs(models) do
    if model_str == current_model_id then
      current_model = model_str
      break
    end
  end
  if not current_model and models[current_model_id] then
    current_model = models[current_model_id]
    if type(current_model) == "table" and not current_model.id then
      current_model.id = current_model_id
    end
  end

  local models_list = vim
    .iter(models)
    :map(function(key, value)
      if type(key) == "string" and value == nil then
        return key
      end
      if type(value) == "table" and not value.id then
        value.id = key
      end
      return value
    end)
    :filter(function(model)
      local model_id = type(model) == "table" and model.id or model
      return model_id ~= current_model_id
    end)
    :totable()

  table.sort(models_list, function(a, b)
    local id_a = type(a) == "table" and (a.formatted_name or a.id) or a
    local id_b = type(b) == "table" and (b.formatted_name or b.id) or b
    return id_a < id_b
  end)
  if current_model then
    table.insert(models_list, 1, current_model)
  end
  return models_list
end

---@param chat MaxaAI.Chat
function M.select_model(chat)
  local models_list = M.list_http_models(chat.adapter)
  if not models_list then
    return log:debug("No models to select for the HTTP adapter")
  end

  local function get_model_id(model)
    return type(model) == "table" and (model.id or model.modelId) or model
  end
  local current_id = get_model_id(models_list[1])
  local opts = {
    prompt = "Select Model",
    kind = "maxa_ai",
    format_item = function(model)
      local model_id = get_model_id(model)
      local display = type(model) == "table" and (model.description or model.formatted_name or model.id or "Unknown") or model
      return (model_id == current_id and "* " or "  ") .. display
    end,
  }

  vim.ui.select(models_list, opts, function(selected_model)
    if selected_model then
      chat:change_model({ model = get_model_id(selected_model) })
    end
  end)
end

---@param chat MaxaAI.Chat
function M.callback(chat)
  local current_adapter = chat.adapter.name
  vim.ui.select(M.get_adapters_list(current_adapter), select_opts("Select Adapter", current_adapter), function(selected_adapter)
    if not selected_adapter then
      return
    end
    if current_adapter ~= selected_adapter then
      chat:change_adapter(selected_adapter)
    end
    return M.select_model(chat)
  end)
end

return M
