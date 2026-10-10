local runtime_state = require("maxa.state")
local async = require("plenary.async")
local completion = require("maxa.providers.completion")
local config = require("maxa.config")
local ts = require("maxa.utils.treesitter")
local ui_utils = require("maxa.utils.ui")
local utils = require("maxa.utils")

local api = vim.api

local M = {}

-- CHAT MAPPINGS --------------------------------------------------------------
M.options = {
  callback = function(chat)
    local float_opts = {
      filetype = "maxa_ai",
      lock = true,
      style = "minimal",
      title = "Options",
      window = config.display.chat.window,
    }

    local lines = {}
    local indent = " "

    local function max(col, tbl)
      local max_length = 0
      for key, val in pairs(tbl) do
        if val.hide then
          goto continue
        end

        local get_length = (col == "key") and key or val[col]

        local length = #get_length
        if length > max_length then
          max_length = length
        end

        ::continue::
      end
      return max_length
    end

    local function pad(str, max_length, offset)
      return str .. string.rep(" ", max_length - #str + (offset or 0))
    end

    --- Cleans and truncates a string to a maximum width.
    ---@param desc string? The description to clean
    ---@param max_width number? The maximum width to truncate the description to
    ---@return string The cleaned and truncated description
    local function clean_and_truncate(desc, max_width)
      if not desc then
        return ""
      end
      desc = vim.trim(tostring(desc):gsub("\n", " "))
      if max_width and #desc > max_width then
        return desc:sub(1, max_width - 3) .. "..."
      end
      return desc
    end

    local function sorted_pairs(tbl, comp)
      local keys = {}
      for k in pairs(tbl) do
        table.insert(keys, k)
      end
      table.sort(keys, comp)
      local i = 0
      return function()
        i = i + 1
        local key = keys[i]
        if key ~= nil then
          return key, tbl[key]
        end
      end
    end

    -- Filter out private keymaps
    local keymaps = {}
    for k, v in pairs(config.interactions.chat.keymaps) do
      if k:sub(1, 1) ~= "_" then
        keymaps[k] = v
      end
    end
    -- Workout the column spacing
    local keymaps_max = max("description", keymaps)

    local mentions = completion.mentions(chat and chat.bufnr or api.nvim_get_current_buf())
    local vars = {}
    for _, item in ipairs(mentions.hash) do
      vars[item.label] = { description = item.detail or item.description }
    end
    local vars_max = max("key", vars)

    local tools = {}
    for _, item in ipairs(mentions.at) do
      tools[item.label] = { description = item.detail or item.description }
    end
    local tools_max = max("key", tools)

    local max_length = math.max(keymaps_max, vars_max, tools_max)

    -- Keymaps
    table.insert(lines, "### Keymaps")

    local function compare_keymaps(a, b)
      return (keymaps[a].description or "") < (keymaps[b].description or "")
    end

    for _, map in sorted_pairs(keymaps, compare_keymaps) do
      if type(map.condition) == "function" and not map.condition() then
        goto continue
      end
      if not map.hide then
        local modes = {
          n = "Normal",
          i = "Insert",
          s = "Select",
        }

        local output = {}
        for mode, key in pairs(map.modes) do
          if type(key) == "table" then
            local keys = {}
            for _, v in ipairs(key) do
              table.insert(keys, "`" .. v .. "`")
            end
            key = table.concat(key, "|")
            table.insert(output, "`" .. key .. "` in " .. modes[mode] .. " mode")
          else
            table.insert(output, "`" .. key .. "` in " .. modes[mode] .. " mode")
          end
        end
        local output_str = table.concat(output, " and ")

        table.insert(lines, indent .. pad("_" .. map.description .. "_", max_length, 4) .. " " .. output_str)
      end
      ::continue::
    end

    -- Literal # completion
    table.insert(lines, "")
    table.insert(lines, "### Literal # Ability references")

    for key, val in sorted_pairs(vars) do
      local desc = clean_and_truncate(val.description)
      table.insert(lines, indent .. pad(key, max_length, 4) .. " " .. desc)
    end

    -- Literal @ completion
    table.insert(lines, "")
    table.insert(lines, "### Literal @ Ability targets")

    for key, val in sorted_pairs(tools) do
      local desc = clean_and_truncate(val.description)
      table.insert(lines, indent .. pad(key, max_length, 4) .. " " .. desc)
    end

    ui_utils.create_float(lines, float_opts)
  end,
}

-- Native completion
M.completion = {
  callback = function(chat)
    local function complete_items(callback)
      async.run(function()
        local slash_cmds = completion.slash_commands(chat.bufnr)
        local tools = completion.tools(chat.bufnr)
        local vars = completion.variables(chat.bufnr)

        local items = {}

        if type(slash_cmds[1]) == "table" then
          vim.list_extend(items, slash_cmds)
        end
        if type(tools[1]) == "table" then
          vim.list_extend(items, tools)
        end
        if type(vars[1]) == "table" then
          vim.list_extend(items, vars)
        end

        -- Process each item to match the completion format
        for _, item in ipairs(items) do
          if item.label then
            item.word = item.label

            item.abbr = item.label:sub(2)
            item.menu = item.description or item.detail
            item.icase = 1
            item.dup = 0
            item.empty = 0
            item.user_data = {
              command = item.label:sub(2),
              label = item.label,
              type = item.type,
              config = item.config,
              from_prompt_library = item.from_prompt_library,
            }
          end
        end

        vim.schedule(function()
          callback(items)
        end)
      end)
    end

    local function trigger_complete()
      local line = vim.api.nvim_get_current_line()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local col = cursor[2]
      if col == 0 or #line == 0 then
        return
      end

      local token = completion.token_at_cursor(line, col, chat.bufnr)
      if not token then
        return
      end
      local start = token.start_col
      local prefix = token.text

      complete_items(function(items)
        vim.fn.complete(
          start + 1,
          vim.tbl_filter(function(item)
            return vim.startswith(item.label:lower(), prefix:lower())
          end, items)
        )
      end)
    end

    trigger_complete()
  end,
}

M.send = {
  callback = function(chat)
    chat:submit()
  end,
}

M.open_tool_window = {
  callback = function(chat)
    local cursor = api.nvim_win_get_cursor(0)
    local state = chat._handoff_compaction
    if state and state.progress then
      local runner = require("maxa.session.handoff_compaction").runner_at_progress(chat, cursor[1] - 1)
      if runner then return require("maxa.mcphub.native_servers.subagent.tools.open_chat").open_live(runner) end
    end
    local message, _, origin = chat.ui:message_at(cursor[1] - 1, cursor[2])
    require("maxa.mcphub.native_servers.subagent.tools.open_chat").open(chat, message, origin)
  end,
}

M.hide = {
  callback = function(chat)
    if chat.ui:is_visible() then chat.ui:hide() end
  end,
}

local function chat_is_running(chat)
  return chat.current_request ~= nil or chat.current_tool ~= nil or chat._tool_input ~= nil
end

M.close = {
  callback = function(chat)
    if chat_is_running(chat)
      and vim.fn.confirm("This chat is running. Force exit and cancel its active work?", "&Force exit\n&Cancel", 2) ~= 1 then
      return
    end
    require("maxa.session.slash_commands.chat_fork_utils").close_chat_with_scratch_guard(chat)
  end,
}

M.hide_or_close = {
  callback = function(chat)
    if chat_is_running(chat) then
      return M.hide.callback(chat)
    end
    return M.close.callback(chat)
  end,
}

M.stop = {
  callback = function(chat)
    if chat.current_request or chat.current_tool or chat._tool_input then
      chat:interrupt()
    end
  end,
}

M.clear = {
  callback = function(chat)
    if vim.fn.confirm("Clear this chat's messages and context?", "&Yes\n&No", 2) == 1 then
      chat:clear()
    end
  end,
}

M.rewind_message = {
  callback = function(chat)
    local cursor = api.nvim_win_get_cursor(0)
    local message, index = chat.ui:message_at(cursor[1] - 1, cursor[2])
    if not index then
      vim.notify("[Chat] No message under cursor to rewind", vim.log.levels.WARN)
      return
    end

    local rewind = require("maxa.session.slash_commands.chat_fork_utils")
    local target, err = rewind.rewind_target_for_message(chat, index)
    if not target then
      vim.notify("[Chat] Rewind failed: " .. tostring(err), vim.log.levels.WARN)
      return
    end
    local user_input = rewind.rewind_user_input(chat, index)
    local edit_user_message = user_input ~= nil
    local prompt
    if user_input and user_input.call_id then
      prompt = string.format(
        "Restore ask reply [%d] to the editable draft and remove %d later message(s)? The next send replaces this reply.\nPress Y to confirm; Enter cancels.",
        index, target.removed_count
      )
    elseif edit_user_message then
      prompt = string.format(
        "Remove message [%d] and %d later message(s), then restore it to the editable draft?\nPress Y to confirm; Enter cancels.",
        index, #chat.messages - index
      )
    else
      prompt = string.format(
        "Keep message [%d]%s and remove %d later message(s)? Current draft will be cleared.\nPress Y to confirm; Enter cancels.",
        index, target.index > index and string.format(" (including tool batch through [%d])", target.index) or "",
        target.removed_count
      )
    end
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
      vim.notify("[Chat] Rewind cancelled (No is the default)")
      return
    end
    if chat.messages[index] ~= message then
      vim.notify("[Chat] Rewind cancelled: selected message changed", vim.log.levels.WARN)
      return
    end
    local ok, result
    if edit_user_message then
      ok, result = rewind.rewind_chat_to_user_message(chat, index)
    else
      ok, result = rewind.rewind_chat_to_message(chat, index)
    end
    if not ok then
      vim.notify("[Chat] Rewind failed: " .. tostring(result), vim.log.levels.ERROR)
      return
    end
    if edit_user_message then
      vim.notify(string.format("[Chat] Restored input from [%d]; removed %d message(s)", result.index, result.removed_count))
    else
      vim.notify(string.format("[Chat] Kept through [%d]; removed %d later message(s)", result.index, result.removed_count))
    end
  end,
}

M.codeblock = {
  desc = "Insert a codeblock",
  callback = function(chat)
    local bufnr = api.nvim_get_current_buf()
    local cursor_pos = api.nvim_win_get_cursor(0)
    local line = cursor_pos[1]

    local ft = chat.buffer_context.filetype or ""

    local codeblock = {
      "````" .. ft,
      "",
      "````",
    }

    api.nvim_buf_set_lines(bufnr, line - 1, line, false, codeblock)
    api.nvim_win_set_cursor(0, { line + 1, vim.fn.indent(line) })
  end,
}

---@param node TSNode to yank text from
local function yank_node(node)
  local start_row, start_col, end_row, end_col = node:range()
  local cursor_position = vim.fn.getcurpos()

  -- Create marks for the node range
  local ok, _ = pcall(function()
    vim.api.nvim_buf_set_mark(0, "[", start_row + 1, start_col, {})
    vim.api.nvim_buf_set_mark(0, "]", end_row + 1, end_col - 1, {})
  end)

  if not ok then
    return utils.notify("Failed to copy code block", vim.log.levels.WARN)
  end

  -- Yank using marks
  vim.cmd(string.format('normal! `["%sy`]', config.interactions.chat.opts.register))

  -- Restore position after delay
  vim.defer_fn(function()
    vim.fn.setpos(".", cursor_position)
  end, config.interactions.chat.opts.yank_jump_delay_ms)
end

M.yank_code = {
  desc = "Yank focused or the last codeblock",
  callback = function(chat)
    local node = chat:get_codeblock()
    if node ~= nil then
      yank_node(node)
    end
  end,
}

---@param chat MaxaAI.Chat
---@param direction number
local function move_buffer(chat, direction)
  local Chat = require("maxa.interactions.chat")
  local identity = require("maxa.session.agent_identity")
  if not identity.is_main(chat) then return end
  local chats = {}
  for _, bufnr in ipairs(runtime_state.buffers) do
    local candidate = Chat.buf_get_chat(bufnr)
    if identity.is_main(candidate) then chats[#chats + 1] = candidate end
  end
  if #chats < 2 then return end
  for i, candidate in ipairs(chats) do
    if candidate == chat then
      local next_chat = chats[((i - 1 + direction) % #chats) + 1]
      local window_opts = chat.ui.window_opts or { default = true }
      chat.ui:hide()
      next_chat.ui:open({ window_opts = window_opts })
      return
    end
  end
end

M.next_chat = {
  desc = "Move to the next chat",
  callback = function(chat)
    if vim.tbl_count(runtime_state.buffers) == 1 then
      return
    end
    move_buffer(chat, 1)
  end,
}

M.previous_chat = {
  desc = "Move to the previous chat",
  callback = function(chat)
    if vim.tbl_count(runtime_state.buffers) == 1 then
      return
    end
    move_buffer(chat, -1)
  end,
}

M.next_header = {
  desc = "Go to the next message",
  callback = function()
    ts.goto_heading("next", 1)
  end,
}

M.previous_header = {
  desc = "Go to the previous message",
  callback = function()
    ts.goto_heading("prev", 1)
  end,
}

local function move_to_user_message(chat, direction)
  local current_row = api.nvim_win_get_cursor(0)[1] - 1
  local row = chat.ui.message_provenance:user_message_row(current_row, direction)
  if not row and direction > 0 and vim.bo[chat.bufnr].modifiable then
    local header = chat.header_line
    local input_row = header and header + 1 -- header is 1-based; skip its blank separator
    if input_row and input_row < api.nvim_buf_line_count(chat.bufnr) and input_row > current_row then
      local line = api.nvim_buf_get_lines(chat.bufnr, header - 1, header, false)[1]
      if line == chat.ui:format_header(chat.ui.roles.user) then
        row = input_row
      end
    end
  end
  if row then
    api.nvim_win_set_cursor(0, { row + 1, 0 })
  end
end

M.next_user_message = {
  callback = function(chat)
    move_to_user_message(chat, 1)
  end,
}

M.previous_user_message = {
  callback = function(chat)
    move_to_user_message(chat, -1)
  end,
}

M.change_adapter = {
  desc = "Change the session LLM/media adapter",
  callback = function(chat)
    return require("maxa.session.adapter_ui").select_session(chat)
  end,
}

M.fold_code = {
  callback = function(chat)
    chat.ui:fold_code()
  end,
}

M.debug = {
  desc = "Show debug information for the current chat",
  callback = function(chat)
    local settings, messages = chat:debug()
    if not settings and not messages then
      return
    end

    return require("maxa.interactions.chat.debug")
      .new({ chat = chat, settings = settings })
      :render()
  end,
}

M.inspect_message = {
  callback = function(chat)
    return require("maxa.interactions.chat.message_inspector").open(chat)
  end,
}

M.debug_messages = {
  desc = "Edit selected messages or the full chat when none is selected",
  callback = function(chat)
    local first, last
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
      local anchor, cursor = vim.fn.getpos("v"), vim.fn.getpos(".")
      local start_row, end_row = math.min(anchor[2], cursor[2]) - 1, math.max(anchor[2], cursor[2]) - 1
      local start_col, end_col
      local blockwise = mode == "\22"
      if mode == "V" then
        start_col, end_col = 0, #(api.nvim_buf_get_lines(chat.bufnr, end_row, end_row + 1, false)[1] or "")
      elseif blockwise then
        start_col, end_col = math.min(anchor[3], cursor[3]) - 1, math.max(anchor[3], cursor[3])
      elseif anchor[2] < cursor[2] or (anchor[2] == cursor[2] and anchor[3] <= cursor[3]) then
        start_col, end_col = anchor[3] - 1, cursor[3]
      else
        start_col, end_col = cursor[3] - 1, anchor[3]
      end
      first, last = chat.ui:message_indices_in_range(start_row, start_col, end_row, end_col, blockwise)
    else
      local position = api.nvim_win_get_cursor(0)
      local _, index = chat.ui:message_at(position[1] - 1, position[2])
      first, last = index, index
    end
    if not first then
      return M.debug.callback(chat)
    end

    return require("maxa.interactions.chat.debug")
      .new({ chat = chat, settings = chat.settings, range = { first, last } })
      :render()
  end,
}

M.goto_file_under_cursor = {
  desc = "Open the file under cursor in a new tab.",
  ---@param chat MaxaAI.Chat
  callback = function(chat)
    local file_name
    if vim.fn.mode() == "n" then
      file_name = vim.fn.expand("<cfile>")
    elseif string.lower(vim.fn.mode()):find("^.?v%a?") then
      -- one of the visual selection modes
      local start_pos = vim.fn.getpos("v")
      local end_pos = vim.fn.getpos(".")
      if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
        start_pos, end_pos = end_pos, start_pos
      end
      local lines =
        vim.api.nvim_buf_get_text(chat.bufnr, start_pos[2] - 1, start_pos[3] - 1, end_pos[2] - 1, end_pos[3], {})
      if lines then
        file_name = table.concat(lines)
      end
    end
    if type(file_name) == "string" then
      file_name = vim.fs.normalize(file_name)
    else
      return
    end

    local stat = vim.uv.fs_stat(file_name)
    if stat == nil or stat.type ~= "file" then
      return
    end
    local action = nil
    local user_action = config.interactions.chat.opts.goto_file_action
    if type(user_action) == "string" then
      action = function(fname)
        vim.cmd(user_action .. " " .. fname)
      end
    elseif type(user_action) == "function" then
      action = user_action
    else
      error(string.format("%s is not a valid jump action!", vim.inspect(user_action)))
    end
    action(file_name)
  end,
}

return M
