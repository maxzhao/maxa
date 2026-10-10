local runtime_state = require("maxa.state")
local buf_utils = require("maxa.utils.buffers")
local config = require("maxa.config")
local helpers = require("maxa.interactions.chat.helpers")
local ui_utils = require("maxa.utils.ui")
local utils = require("maxa.utils")

local api = vim.api

---@param bufnr number
---@param opts? table
local function _get_settings_key(bufnr, opts)
  opts = vim.tbl_extend("force", opts or {}, {
    lang = "lua",
  })
  local node = vim.treesitter.get_node(opts)

  local current = node
  local in_settings = false
  while current do
    if current:type() == "assignment_statement" then
      local name_node = current:named_child(0)
      if name_node and vim.treesitter.get_node_text(name_node, bufnr) == "settings" then
        in_settings = true
        break
      end
    end
    current = current:parent()
  end

  if not in_settings then
    return
  end

  while node do
    if node:type() == "field" then
      local key_node = node:named_child(0)
      if key_node and key_node:type() == "identifier" then
        local key_name = vim.treesitter.get_node_text(key_node, bufnr)
        return key_name, node
      end
    end
    node = node:parent()
  end
end

---Extract the settings and messages from the buffer
local function get_buffer_content(lines)
  local content = table.concat(lines, "\n")

  local env = {}
  local chunk, err = load(
    "local settings, messages; " .. content .. " return {settings=settings, messages=messages}",
    "buffer",
    "t",
    env
  )
  if not chunk then
    return error("Failed to parse buffer: " .. (err or "unknown error"))
  end

  local result = chunk()
  return result.settings, result.messages
end

---@class MaxaAI.Chat.Debug
---@field chat MaxaAI.Chat
---@field settings table
---@field aug number
local Debug = {}

-- Keep each tool request and all its results in the editable canonical interval.
local function expand_tool_range(messages, range)
  local requests, results, links = {}, {}, {}
  for i, message in ipairs(messages) do
    if (message.role == "llm" or message.role == "assistant") and message.tools then
      for _, call in ipairs(message.tools.calls or {}) do
        local id = call.call_id or call.id
        if id then
          requests[id] = i
        end
      end
    elseif (message.role == "tool" or message.role == "user") and message.tools and message.tools.call_id then
      local id = message.tools.call_id
      results[id] = results[id] or {}
      table.insert(results[id], i)
    end
  end
  for id, request in pairs(requests) do
    for _, result in ipairs(results[id] or {}) do
      table.insert(links, { request, result })
    end
  end

  local first, last = unpack(range)
  local changed = true
  while changed do
    changed = false
    for _, pair in ipairs(links) do
      local request, result = pair[1], pair[2]
      if (request >= first and request <= last) or (result >= first and result <= last) then
        local new_first, new_last = math.min(first, request, result), math.max(last, request, result)
        if new_first ~= first or new_last ~= last then
          first, last, changed = new_first, new_last, true
        end
      end
    end
  end
  return { first, last }
end

function Debug.new(args)
  local range = args.range and expand_tool_range(args.chat.messages, args.range)
  local self = setmetatable({
    chat = args.chat,
    settings = args.settings,
    range = range,
    original_messages = range and vim.list_slice(args.chat.messages, range[1], range[2]),
    before = range and args.chat.messages[range[1] - 1],
    after = range and args.chat.messages[range[2] + 1],
  }, { __index = Debug })

  return self
end

---Render the settings and messages
---@return MaxaAI.Chat.Debug
function Debug:render()
  local models
  local adapter = vim.deepcopy(self.chat.adapter)
  self.adapter = adapter

  local bufname
  if runtime_state.current_context and api.nvim_buf_is_valid(runtime_state.current_context) then
    bufname = buf_utils.name_from_bufnr(runtime_state.current_context)
  end

  -- Get the current settings from the chat buffer rather than making new ones
  local current_settings = self.settings or {}

  if adapter.schema and adapter.schema.model then
    if type(adapter.schema.model.choices) == "function" then
      models = adapter.schema.model.choices(adapter, { async = false })
    else
      models = adapter.schema.model.choices
    end
  end

  local lines = {}

  table.insert(lines, '-- Adapter: "' .. adapter.formatted_name .. '"')
  table.insert(lines, "-- Buffer Number: " .. self.chat.bufnr)
  if bufname then
    table.insert(lines, '-- Following Buffer: "' .. bufname .. '" (' .. runtime_state.current_context .. ")")
  end

  local tool_names = {}
  for name, enabled in pairs(self.chat.tool_registry and self.chat.tool_registry.in_use or {}) do
    if enabled then
      table.insert(tool_names, name)
    end
  end
  table.sort(tool_names)
  table.insert(lines, string.format("-- Bound tools (%d):", #tool_names))
  if #tool_names == 0 then
    table.insert(lines, "--   none")
  else
    local names_line = ""
    for _, name in ipairs(tool_names) do
      local next_name = (names_line == "" and "" or ", ") .. name
      if #names_line > 0 and #names_line + #next_name > 80 then
        table.insert(lines, "--   " .. names_line)
        names_line = name
      else
        names_line = names_line .. next_name
      end
    end
    table.insert(lines, "--   " .. names_line)
  end

  -- Add settings
  table.insert(lines, "")
  local keys = {}

  -- Collect all settings keys including those with nil defaults
  if self.settings then
    for key, _ in pairs(self.settings) do
      table.insert(keys, key)
    end
  end

  -- Add any schema keys that have an explicit nil default
  if adapter.schema then
    for key, schema_value in pairs(adapter.schema) do
      if schema_value.default == nil and not vim.tbl_contains(keys, key) then
        table.insert(keys, key)
      end
    end
  end

  table.sort(keys, function(a, b)
    local a_order = adapter.schema[a] and adapter.schema[a].order or 999
    local b_order = adapter.schema[b] and adapter.schema[b].order or 999
    if a_order == b_order then
      return a < b -- alphabetical sort as fallback
    end
    return a_order < b_order
  end)

  if vim.tbl_count(keys) == 0 then
    table.insert(lines, "-- No settings available")
  else
    table.insert(lines, "local settings = {")
    for _, key in ipairs(keys) do
      local val = self.settings[key]
      local is_nil = adapter.schema[key] and adapter.schema[key].default == nil

      local formatted_key = key
      if key:find("%.") then
        formatted_key = '["' .. key .. '"]'
      end

      if key == "model" then
        local other_models = " -- "

        vim.iter(models):each(function(model, model_name)
          if type(model) == "number" then
            model = model_name
          end
          if model ~= val then
            other_models = other_models .. '"' .. model .. '", '
          end
        end)

        if type(val) == "function" then
          val = val(self.adapter)
        end
        if vim.tbl_count(models) > 1 then
          table.insert(lines, "  " .. formatted_key .. ' = "' .. val .. '", ' .. other_models)
        else
          table.insert(lines, "  " .. formatted_key .. ' = "' .. val .. '",')
        end
      elseif is_nil and current_settings[key] == nil then
        table.insert(lines, "  " .. formatted_key .. " = nil,")
      else
        if type(val) == "function" then
          val = val(self.adapter)
        end

        if type(val) == "number" or type(val) == "boolean" then
          table.insert(lines, "  " .. formatted_key .. " = " .. tostring(val) .. ",")
        elseif type(val) == "string" then
          table.insert(lines, "  " .. formatted_key .. ' = "' .. val .. '",')
        else
          local inspected = vim.inspect(val)
          local lines_to_add = vim.split(inspected, "\n")
          for i, line in ipairs(lines_to_add) do
            if i == 1 then
              table.insert(lines, "  " .. formatted_key .. " = " .. line)
            else
              table.insert(lines, "  " .. line)
            end
          end
          lines[#lines] = lines[#lines] .. ","
        end
      end
    end

    table.insert(lines, "}")
  end

  -- Add messages, including an empty list when no message has been committed yet.
  local shown_messages = self.range and self.original_messages or self.chat.messages
  table.insert(lines, "")
  if self.range then
    table.insert(lines, string.format("-- Canonical messages %d–%d", self.range[1], self.range[2]))
  end
  table.insert(lines, "local messages = ")

  local messages = vim.inspect(shown_messages)
  for line in messages:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  self.bufnr = api.nvim_create_buf(false, true)

  api.nvim_buf_set_name(self.bufnr, "MaxaAI_debug")
  -- Set the keymaps as per the user's chat buffer config
  local maps = {}
  local config_maps = vim.deepcopy(config.interactions.chat.keymaps)
  maps["save"] = config_maps["send"]
  maps["save"].callback = "save"
  maps["save"].description = "Save debug window content"
  maps["close"] = config_maps["close"]
  maps["close"].callback = "close"
  maps["close"].description = "Close debug window"

  require("maxa.utils.keymaps")
    .new({
      bufnr = self.bufnr,
      callbacks = function()
        local M = {}
        M.save = function()
          return self:save()
        end
        M.close = function()
          return self:close()
        end
        return M
      end,
      data = nil,
      keymaps = maps,
    })
    :set()

  local window_config = config.display.chat.floating_window

  ui_utils.create_float(lines, {
    bufnr = self.bufnr,
    filetype = "lua",
    opts = window_config.opts,
    title = "Debug Chat",
    window = window_config,
  })

  self:setup_window()

  return self
end

---Setup the debug window
---@return nil
function Debug:setup_window()
  self.aug = api.nvim_create_augroup("maxa.ai.debug" .. ":" .. self.bufnr, {
    clear = true,
  })

  api.nvim_create_autocmd("CursorMoved", {
    group = self.aug,
    buffer = self.bufnr,
    desc = "Show settings information in the Maxa AI chat buffer",
    callback = function()
      local key_name, node = _get_settings_key(self.bufnr)
      if not key_name or not node then
        return vim.diagnostic.set(config.INFO_NS, self.bufnr, {})
      end

      local key_schema = self.adapter.schema[key_name]
      if key_schema and key_schema.desc then
        local lnum, col, end_lnum, end_col = node:range()
        local diagnostic = {
          lnum = lnum,
          col = col,
          end_lnum = end_lnum,
          end_col = end_col,
          severity = vim.diagnostic.severity.INFO,
          message = key_schema.desc,
        }
        vim.diagnostic.set(config.INFO_NS, self.bufnr, { diagnostic })
      end
    end,
  })

  api.nvim_create_autocmd("BufWrite", {
    group = self.aug,
    buffer = self.bufnr,
    desc = "Save the contents of the debug window to the chat buffer",
    callback = function()
      return self:save()
    end,
  })

  api.nvim_create_autocmd({ "BufUnload", "WinClosed" }, {
    group = self.aug,
    buffer = self.bufnr,
    desc = "Clear the autocmds in the debug window",
    callback = function()
      return self:close()
    end,
  })
end

---Save the contents of the debug window to the chat buffer
function Debug:save()
  local contents = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  local settings, messages = get_buffer_content(contents)

  if not settings and not messages then
    return
  end

  if messages and self.range then
    if not vim.islist(messages) then
      return utils.notify("Messages must be a list")
    end
    local first, last = unpack(self.range)
    if self.chat.messages[first - 1] ~= self.before or self.chat.messages[last + 1] ~= self.after then
      return utils.notify("Messages changed since this debug window opened; reopen it before saving")
    end
    for offset, original in ipairs(self.original_messages) do
      if self.chat.messages[first + offset - 1] ~= original then
        return utils.notify("Messages changed since this debug window opened; reopen it before saving")
      end
    end
  end
  if settings then
    helpers.apply_settings_and_model(self.chat, settings)
  end
  if messages then
    if self.range then
      local first, last = unpack(self.range)
      self.chat.ui.message_provenance:forget_indices(first, last)
      for i = last, first, -1 do
        table.remove(self.chat.messages, i)
      end
      for i, message in ipairs(messages) do
        table.insert(self.chat.messages, first + i - 1, message)
      end
      self.range[2] = first + #messages - 1
      self.original_messages = vim.list_slice(self.chat.messages, first, self.range[2])
      self.after = self.chat.messages[self.range[2] + 1]
    else
      self.chat.ui.message_provenance:clear()
      self.chat.messages = messages
      if self.chat.tools then
        self.chat.tools.messages = messages
      end
    end
  end

  utils.notify("Updated the settings and messages")
end

---Function to run when the debug chat is closed
---@return nil
function Debug:close()
  if self.aug then
    api.nvim_clear_autocmds({ group = self.aug })
  end
  api.nvim_buf_delete(self.bufnr, { force = true })
end

return Debug
