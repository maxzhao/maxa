--[[
Manages the UI for the chat buffer such as opening and closing splits/windows
and rendering extmarks.
--]]
local config = require("maxa.config")
local helpers = require("maxa.interactions.chat.helpers")
local log = require("maxa.utils.log")
local ui_utils = require("maxa.utils.ui")
local buffer_guard = require("maxa.interactions.chat.ui.buffer_guard")
local utils = require("maxa.utils")

local api = vim.api

local CONSTANTS = {
  NS_HEADER = api.nvim_create_namespace("MaxaAI-headers"),
  NS_TOKENS = api.nvim_create_namespace("MaxaAI-tokens"),
  NS_VIRTUAL_TEXT = api.nvim_create_namespace("MaxaAI-virtual_text"),

  AUTOCMD_GROUP = "maxa.ai.chat.ui",
}

---Finalize window setup by applying the options and setting the filetype. This
---This ensures that any maxa_ai specific ftplugins can run after the
---window options are set, allowing the plugin defaults to be overridden
---@param winnr number
---@param bufnr number
---@param opts table Window options to apply
---@return nil
local function apply_window_config(winnr, bufnr, opts)
  ui_utils.set_win_options(winnr, opts)
  api.nvim_set_option_value("filetype", "maxa_ai", { buf = bufnr })
end

---Set the LLM role based on the adapter
---@param role string|function
---@param adapter table
---@return string
local function set_llm_role(role, adapter)
  if type(role) == "function" then
    return role(adapter)
  end
  return role
end

---@class MaxaAI.Chat.UI
---@field adapter MaxaAI.HTTPAdapter The adapter in use for the chat
---@field aug number The autocmd group ID
---@field chat_bufnr number The buffer number of the chat
---@field chat_id number The unique ID of the chat
---@field cursor { has_moved: boolean, pos?: table } Cursor state tracking
---@field folds MaxaAI.Chat.UI.Folds The folds for the chat
---@field header_ns number The namespace for the header
---@field roles table The roles in the chat
---@field winnr number The window number of the chat
---@field tokens number The current token count in the chat
---@field window_opts? table The window configuration options for the chat buffer

---@class MaxaAI.Chat.UIArgs
---@field adapter MaxaAI.HTTPAdapter
---@field aug number The autocmd group ID
---@field chat_bufnr number
---@field chat_id number
---@field roles table
---@field winnr number
---@field tokens number
---@field window_opts? table

---@class MaxaAI.Chat.UI
local UI = {}

---@param args MaxaAI.Chat.UIArgs
function UI.new(args)
  local self = setmetatable({
    adapter = args.adapter,
    aug = args.aug,
    chat_bufnr = args.chat_bufnr,
    chat_id = args.chat_id,
    chat = args.chat,
    cursor = {
      has_moved = false,
      pos = nil,
    },
    roles = args.roles,
    tokens = args.tokens,
    winnr = args.winnr,
    window_opts = args.window_opts,
  }, { __index = UI })

  self.folds = require("maxa.interactions.chat.ui.folds")
  self.message_provenance = require("maxa.interactions.chat.ui.message_provenance").new(self.chat, self.chat_bufnr)

  local function reconcile_windows()
    if self._window_sync_scheduled then
      return
    end
    self._window_sync_scheduled = true
    -- Leave/close events run before the transition has finished. One scheduled
    -- reconciliation observes the resulting windows; it never waits or retries.
    vim.schedule(function()
      self._window_sync_scheduled = nil
      if api.nvim_buf_is_valid(self.chat_bufnr) then
        self:sync_windows()
      end
    end)
  end
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "BufWinLeave" }, {
    group = self.aug,
    buffer = self.chat_bufnr,
    callback = function()
      if vim.fn.win_gettype() ~= "autocmd" then
        reconcile_windows()
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = self.aug,
    callback = reconcile_windows,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = self.aug,
    buffer = self.chat_bufnr,
    callback = function()
      self.winnr = nil
      self.folds:cleanup(self.chat_bufnr)
    end,
  })

  api.nvim_create_autocmd("InsertEnter", {
    group = self.aug,
    buffer = self.chat_bufnr,
    once = true,
    desc = "Clear the virtual text in the Maxa AI chat buffer",
    callback = function()
      api.nvim_buf_clear_namespace(self.chat_bufnr, CONSTANTS.NS_VIRTUAL_TEXT, 0, -1)
    end,
  })

  if config.display.chat.auto_scroll then
    local debounce = nil
    local debounce_ms = config.interactions.chat.opts.debounce or 0

    api.nvim_create_autocmd("CursorMoved", {
      group = self.aug,
      buffer = self.chat_bufnr,
      desc = "Track the cursor in a Maxa AI buffer",
      callback = function()
        if not self:is_visible() then
          return
        end

        ---@return nil
        local function get_cursor_pos()
          if not self:is_visible() then
            return
          end

          local ok, cursor = pcall(api.nvim_win_get_cursor, self.winnr)
          if not ok then
            return
          end

          local last_line = self:last()

          -- Check that the cursor is not on the last line. This likely means the
          -- user has moved it and is likely reading the LLM's response. We do
          -- not want to force an autoscroll so we save the cursor position
          if cursor[1] ~= last_line + 1 then
            self.cursor.has_moved = true
            self.cursor.pos = { cursor[1], cursor[2] }
          else
            self.cursor.has_moved = false
            self.cursor.pos = nil
          end
        end

        -- PERF: If we're testing, skip the debounce
        if debounce_ms == 0 then
          return get_cursor_pos()
        end

        if debounce then
          pcall(function()
            debounce:stop()
          end)
        end

        debounce = vim.defer_fn(function()
          debounce = nil
          get_cursor_pos()
        end, debounce_ms)
      end,
    })

    api.nvim_create_autocmd("WinLeave", {
      group = self.aug,
      buffer = self.chat_bufnr,
      desc = "Save cursor position when leaving a Maxa AI chat buffer",
      callback = function()
        if self:is_visible() and self.cursor.has_moved then
          local ok, cursor = pcall(api.nvim_win_get_cursor, self.winnr)
          if ok then
            self.cursor.pos = { cursor[1], cursor[2] }
          end
        end
      end,
    })
  end

  return self
end

-- Single write boundary for Chat message presentation; callers retain formatting,
-- highlights and buffer-lock ownership. Source is a canonical message or call locator.
function UI:write_lines(start_row, end_row, lines, source)
  if start_row == 0 and (end_row == -1 or end_row == api.nvim_buf_line_count(self.chat_bufnr)) then
    self.folds:cleanup(self.chat_bufnr)
  elseif self.folds.invalidate_range then
    local last = end_row == -1 and api.nvim_buf_line_count(self.chat_bufnr) or end_row
    self.folds:invalidate_range(self.chat_bufnr, start_row, last)
  end
  return self.message_provenance:lines(start_row, end_row, lines, source)
end

function UI:write_text(start_row, start_col, end_row, end_col, lines, source)
  return self.message_provenance:text(start_row, start_col, end_row, end_col, lines, source)
end

function UI:message_at(row, col)
  return self.message_provenance:at(row, col)
end

function UI:message_indices_in_range(start_row, start_col, end_row, end_col, blockwise)
  return self.message_provenance:indices_in_range(start_row, start_col, end_row, end_col, blockwise)
end

---Open/create the chat window
---@param opts? table
---@return MaxaAI.Chat.UI|nil
function UI:open(opts)
  opts = opts or {}

  if self:is_visible() then
    local requested = opts.window_opts
    if requested and (requested.position == "left" or requested.position == "right")
      and require("maxa.session.agent_identity").is_main(self.chat) then
      if api.nvim_win_get_config(self.winnr).relative == "" then
        api.nvim_win_call(self.winnr, function() vim.cmd(requested.position == "right" and "wincmd L" or "wincmd H") end)
        self.window_opts = vim.tbl_extend("force", {}, requested, { layout = "vertical" })
        return self
      end
      self:hide()
    else
      return self
    end
  end
  if config.display.chat.start_in_insert_mode then
    -- Delay entering insert mode until after Telescope picker fully closes,
    -- since Telescope resets to normal mode on close.
    vim.schedule(function()
      vim.cmd("startinsert")
    end)
  end

  if opts.window_opts then
    if opts.window_opts.default then
      self.window_opts = nil
    else
      self.window_opts = opts.window_opts
    end
  end
  self.window_opts = require("maxa.session.agent_identity").window_opts(self.chat, self.window_opts)
  local window
  if self.window_opts then
    window = vim.tbl_deep_extend("force", {}, config.display.chat.window, self.window_opts)
  else
    window = vim.deepcopy(config.display.chat.window)
  end

  local function cols()
    return vim.o.columns
  end
  local function rows()
    return vim.o.lines
  end

  --NOTE: Previously we allowed "auto" values for the width, so guarding against that here
  if type(window.height) == "string" then
    window.height = rows()
  end
  if type(window.width) == "string" then
    window.width = cols()
  end

  if type(window.height) == "function" then
    window.height = window.height()
  end
  if type(window.width) == "function" then
    window.width = window.width()
  end

  local height = window.height > 1 and window.height or math.floor(rows() * window.height)
  local width = window.width > 1 and window.width or math.floor(cols() * window.width)

  if window.layout == "float" then
    local win_opts = {
      relative = window.relative,
      width = width,
      height = height,
      col = window.col or math.floor((cols() - width) / 2),
      row = window.row or math.floor((rows() - height) / 2),
      border = window.border,
      title = window.title or "MaxaAI",
      title_pos = "center",
      zindex = 45,
    }
    self.winnr = api.nvim_open_win(self.chat_bufnr, true, win_opts)
    apply_window_config(self.winnr, self.chat_bufnr, window.opts)
  elseif window.layout == "vertical" then
    local position = window.position
    local full_height = window.full_height
    if position == nil or (position ~= "left" and position ~= "right") then
      position = vim.opt.splitright:get() and "right" or "left"
    end
    if full_height then
      if position == "left" then
        vim.cmd("topleft vsplit")
      else
        vim.cmd("botright vsplit")
      end
    else
      vim.cmd("vsplit")
    end
    if position == "left" and vim.opt.splitright:get() then
      vim.cmd("wincmd h")
    end
    if position == "right" and not vim.opt.splitright:get() then
      vim.cmd("wincmd l")
    end
    vim.cmd("vertical resize " .. width)
    self.winnr = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.winnr, self.chat_bufnr)
    apply_window_config(self.winnr, self.chat_bufnr, window.opts)
  elseif window.layout == "horizontal" then
    local position = window.position
    if position == nil or (position ~= "top" and position ~= "bottom") then
      position = vim.opt.splitbelow:get() and "bottom" or "top"
    end
    vim.cmd("split")
    if position == "top" and vim.opt.splitbelow:get() then
      vim.cmd("wincmd k")
    end
    if position == "bottom" and not vim.opt.splitbelow:get() then
      vim.cmd("wincmd j")
    end
    vim.cmd("resize " .. height)
    self.winnr = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.winnr, self.chat_bufnr)
    apply_window_config(self.winnr, self.chat_bufnr, window.opts)
  else
    self.winnr = api.nvim_get_current_win()
    api.nvim_set_current_buf(self.chat_bufnr)
    apply_window_config(self.winnr, self.chat_bufnr, window.opts)
  end

  vim.bo[self.chat_bufnr].textwidth = 0

  if not opts.toggled then
    -- Put the cursor back in the original position
    if self.cursor.has_moved and self.cursor.pos then
      vim.schedule(function()
        if self:is_visible() then
          pcall(api.nvim_win_set_cursor, self.winnr, self.cursor.pos)
        end
      end)
    else
      self:follow()
    end
  end

  self:sync_windows()

  log:trace("Chat opened with ID %d", self.chat_id)
  utils.fire("ChatOpened", { bufnr = self.chat_bufnr, id = self.chat_id })

  return self
end

---Hide the chat buffer from view
---@return nil
function UI:hide()
  local layout
  if self.window_opts then
    layout = vim.tbl_deep_extend("force", {}, config.display.chat.window, self.window_opts).layout
  else
    layout = config.display.chat.window.layout
  end

  if layout == "float" or layout == "vertical" or layout == "horizontal" then
    if self:is_active() then
      vim.cmd("hide")
    else
      if not self.winnr then
        self.winnr = ui_utils.buf_get_win(self.chat_bufnr)
      end
      api.nvim_win_hide(self.winnr)
    end
  else
    vim.cmd("buffer " .. vim.fn.bufnr("#"))
  end

  utils.fire("ChatHidden", { bufnr = self.chat_bufnr, id = self.chat_id })
end

---Follow the cursor in the chat buffer
---@return nil
function UI:follow()
  if not self:is_visible() then
    return
  end

  -- Don't follow if the user has manually positioned their cursor
  if self.cursor.has_moved then
    return
  end

  local last_line, last_column, line_count = self:last()
  if line_count == 0 then
    return
  end

  api.nvim_win_set_cursor(self.winnr, { last_line + 1, last_column })
end

---Reconcile real window association and recover its missing folds.
function UI:sync_windows()
  local wins = self.folds:windows(self.chat_bufnr)
  local current = api.nvim_get_current_win()
  if self.folds:is_chat_window(current, self.chat_bufnr) then
    self.winnr = current
  elseif not self.folds:is_chat_window(self.winnr, self.chat_bufnr) then
    self.winnr = wins[1]
  end
  for _, win in ipairs(wins) do
    self.folds:apply(self.chat_bufnr, win)
  end
end

---Determine if the current chat buffer is active
---@return boolean
function UI:is_active()
  return self.folds:is_chat_window(api.nvim_get_current_win(), self.chat_bufnr)
end

---Determine if the chat buffer is visible
---@return boolean
function UI:is_visible()
  return self.folds:is_chat_window(self.winnr, self.chat_bufnr)
end

---Chat buffer is visible but not in the current tab
---@return boolean
function UI:is_visible_non_curtab()
  return self:is_visible() and api.nvim_get_current_tabpage() ~= api.nvim_win_get_tabpage(self.winnr)
end

---Get the formatted header for the chat buffer
---@param role string The role of the user
---@return string
function UI:format_header(role)
  local header = "## " .. role
  if config.display.chat.show_header_separator then
    header = string.format("%s %s", header, config.display.chat.separator)
  end

  return header
end

---Format the header in the chat buffer
---@param tbl table containing the buffer contents
---@param role string The role of the user to display in the header
---@return nil
function UI:set_header(tbl, role)
  -- If the role is the LLM then we need to swap this out for a user func
  if type(role) == "function" then
    role = set_llm_role(role, self.adapter)
  end

  table.insert(tbl, self:format_header(role))
  table.insert(tbl, "")
end

---Render messages in the chat buffer
---@param context table
---@param messages table
---@param opts {force_header?: boolean, stop_context_insertion?: boolean}
---@return self
function UI:render(context, messages, opts)
  require("maxa.interactions.chat.snippets").stop(self.chat_bufnr)
  opts = vim.tbl_extend("keep", opts or {}, { force_header = false, stop_context_insertion = false })

  local lines = {}
  local spans = {}

  local function spacer()
    table.insert(lines, "")
  end

  -- Prevent duplicate headers
  local last_set_role
  local last_presentation_origin

  local function add_messages_to_buf(msgs)
    for i, msg in ipairs(msgs) do
      if (msg.role ~= config.constants.SYSTEM_ROLE) and not (msg.opts and msg.opts.visible == false) then
        -- Keep the main user role adjacent to preceding prompt-library history.
        if i > 1 and self.last_role ~= msg.role and msg.role ~= config.constants.USER_ROLE then
          spacer()
        end

        if
          msg.role == config.constants.USER_ROLE
          and (last_set_role ~= config.constants.USER_ROLE or (msg.opts and msg.opts.force_role))
        then
          if last_set_role ~= nil then
            spacer()
          end
          self:set_header(lines, self.roles.user)
        end
        if
          msg.role == config.constants.LLM_ROLE
          and (last_set_role ~= config.constants.LLM_ROLE or (msg.opts and msg.opts.force_role))
        then
          self:set_header(lines, set_llm_role(self.roles.llm, self.adapter))
        end

        local presentation_origin = msg.opts and msg.opts._presentation_display
          and msg.opts._display_origin
        local presentation_boundary = presentation_origin
          and (not last_presentation_origin or presentation_origin.call_id ~= last_presentation_origin.call_id)
          or (last_presentation_origin and not presentation_origin)
        -- Live tool insertion owns one blank separator. Restore the same
        -- boundary without splitting one call's blocks or extending its spans.
        if presentation_boundary and #lines > 0 and lines[#lines] ~= "" then
          spacer()
        end
        last_presentation_origin = presentation_origin

        if msg._meta and msg._meta.tag == "tool_output" then
          table.insert(lines, "")
        end

        local start_row = #lines
        local preserve_empty = msg.role == config.constants.USER_ROLE
          and (msg.content == "" or (msg.opts and msg.opts._preserve_empty))
        local trimempty = not preserve_empty
        for _, text in ipairs(vim.split(msg.content or "", "\n", { plain = true, trimempty = trimempty })) do
          table.insert(lines, text)
        end

        local source = (msg.opts and msg.opts._display_origin) or msg
        if #lines > start_row then
          table.insert(spans, { start_row, #lines - 1, #lines[#lines], source })
        end
        if msg.opts and msg.opts._display_spans then
          for _, span in ipairs(msg.opts._display_spans) do
            table.insert(spans, { start_row + span[1], start_row + span[2], span[3], span[4] })
          end
        end
        last_set_role = msg.role
        self.last_role = msg.role

        -- The Chat:Submit method will parse the last message and it to the messages table
        if i == #msgs then
          table.remove(msgs, i)
        end
      end
    end
  end

  -- NOTE: Typically, we wouldn't want to render a header if there are existing
  -- messages. However, provide an option to force the header to be rendered
  -- for scenarios where there is no user prompt
  if opts.force_header or (vim.tbl_isempty(messages) or not helpers.has_user_messages(messages)) then
    log:trace("Setting the header for the chat buffer")
    self:set_header(lines, self.roles.user)
    spacer()
  else
    log:trace("Setting the messages in the chat buffer")
    add_messages_to_buf(messages)
  end

  -- If the user has visually selected some text, add that to the chat buffer
  if context and context.is_visual and not opts.stop_context_insertion then
    log:trace("Adding visual selection to chat buffer")
    table.insert(lines, "```" .. context.filetype)
    for _, line in ipairs(context.lines) do
      table.insert(lines, line)
    end
    table.insert(lines, "```")
  end

  self:unlock_buf()
  if self.chat then
    self.chat._file_link_body = nil
    api.nvim_buf_clear_namespace(self.chat_bufnr, api.nvim_create_namespace("MaxaFileLinksBody"), 0, -1)
  end
  self:write_lines(0, -1, lines)
  for _, span in ipairs(spans) do
    self.message_provenance:mark(span[1], 0, span[2], span[3], span[4])
  end
  self:render_headers()
  if self.chat and self.chat._last_turn_metrics and self.last_role == config.constants.USER_ROLE then
    self:display_tokens(self.chat.chat_parser, 1)
  end

  self:follow()
  if self.chat then
    vim.schedule(function()
      if api.nvim_buf_is_valid(self.chat_bufnr) then require("maxa.session.file_links").restore(self.chat) end
    end)
  end

  return self
end

---Render the headers in the chat buffer and apply extmarks
---@return nil
function UI:render_headers()
  if not config.display.chat.show_header_separator then
    return
  end

  local separator = config.display.chat.separator
  local lines = api.nvim_buf_get_lines(self.chat_bufnr, 0, -1, false)
  local llm_role = set_llm_role(self.roles.llm, self.adapter)

  for line, content in ipairs(lines) do
    if content:match("^## " .. vim.pesc(self.roles.user)) or content:match("^## " .. vim.pesc(llm_role)) then
      local col = vim.fn.strwidth(content) - vim.fn.strwidth(separator)

      api.nvim_buf_set_extmark(self.chat_bufnr, CONSTANTS.NS_HEADER, line - 1, col, {
        virt_text_win_col = col,
        virt_text = { { string.rep(separator, vim.go.columns), "MaxaAIChatSeparator" } },
        priority = 100,
      })

      -- Set the highlight group for the header
      api.nvim_buf_set_extmark(self.chat_bufnr, CONSTANTS.NS_HEADER, line - 1, 0, {
        end_col = col + 1,
        hl_group = "MaxaAIChatHeader",
      })
    end
  end
  log:trace("Rendering headers in the chat buffer")
end

---Set the welcome message in the chat buffer
---@param message string The intro message to display
---@return MaxaAI.Chat.UI|nil
function UI:set_intro_msg(message)
  if self.intro_message then
    return self
  end

  if not config.display.chat.start_in_insert_mode then
    local extmark_id = self:set_virtual_text(message, "eol")
    api.nvim_create_autocmd("InsertEnter", {
      buffer = self.chat_bufnr,
      callback = function()
        self:clear_virtual_text(extmark_id)
      end,
    })
    self.intro_message = true
  end

  return self
end

---Set virtual text in the chat buffer
---@param message string
---@param method? string "eol", "inline" etc
---@param range? table<number, number>
---@return number The id of the extmark
function UI:set_virtual_text(message, method, range)
  if not buffer_guard.ensure(self) then
    return nil
  end
  range = range or { api.nvim_buf_line_count(self.chat_bufnr) - 1, 0 }
  local virtual_lines = {}
  for line in tostring(message):gmatch("[^\n]+") do
    virtual_lines[#virtual_lines + 1] = { { line, "MaxaAIVirtualText" } }
  end
  return api.nvim_buf_set_extmark(self.chat_bufnr, CONSTANTS.NS_VIRTUAL_TEXT, range[1], range[2], {
    virt_lines = virtual_lines,
    virt_text_pos = method or "eol",
  })
end

---Clear virtual text in the chat buffer
---@param extmark_id number The id of the extmark to delete
---@return nil
function UI:clear_virtual_text(extmark_id)
  api.nvim_buf_del_extmark(self.chat_bufnr, CONSTANTS.NS_VIRTUAL_TEXT, extmark_id)
end

---Get the last line, column and line count in the chat buffer
---@return number, integer, integer
function UI:last()
  if not buffer_guard.ensure(self) then
    return 0, 0, 0
  end
  local line_count = api.nvim_buf_line_count(self.chat_bufnr)

  local last_line = line_count - 1
  if last_line < 0 then
    return 0, 0, line_count
  end

  local last_line_content = api.nvim_buf_get_lines(self.chat_bufnr, -2, -1, false)
  if not last_line_content or #last_line_content == 0 then
    return last_line, 0, line_count
  end

  local last_column = #last_line_content[1]

  return last_line, last_column, line_count
end

---Display the tokens in the chat buffer
---@param parser table
---@param start_row number
---@return nil
function UI:display_tokens(parser, start_row)
  if not config.display.chat.show_token_count then return end
  local last_turn = self.chat and self.chat._last_turn_metrics
  if last_turn then
    local row = require("maxa.interactions.chat.parser").headers(self.chat)
    if row then
      api.nvim_buf_clear_namespace(self.chat_bufnr, CONSTANTS.NS_TOKENS, 0, -1)
      api.nvim_buf_set_extmark(self.chat_bufnr, CONSTANTS.NS_TOKENS, row, 0, {
        virt_text = { { " " .. require("maxa.adapters.metrics").format(last_turn, true), "MaxaAIChatTokens" } },
        virt_text_pos = "eol",
        priority = 110,
        hl_mode = "combine",
      })
    end
  end
end

---Fold code under the user's heading in the chat buffer
---@return self
function UI:fold_code()
  local query = vim.treesitter.query.parse(
    "markdown",
    [[
(section
(
 (atx_heading
  (atx_h2_marker)
  heading_content: (_) @role
)
([
  (fenced_code_block)
  (indented_code_block)
] @code (#trim! @code))
))
]]
  )

  local parser = vim.treesitter.get_parser(self.chat_bufnr, "markdown")
  local tree = parser:parse()[1]
  vim.o.foldmethod = "manual"

  local role
  for _, matches in query:iter_matches(tree:root(), self.chat_bufnr) do
    local match = {}
    for id, nodes in pairs(matches) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      match = vim.tbl_extend("keep", match, {
        [query.captures[id]] = {
          node = node,
        },
      })
    end

    if match.role then
      role = vim.trim(vim.treesitter.get_node_text(match.role.node, self.chat_bufnr))
      if role:match(self.roles.user) and match.code then
        local start_row, _, end_row, _ = match.code.node:range()
        if start_row < end_row then
          api.nvim_buf_call(self.chat_bufnr, function()
            vim.cmd(string.format("%d,%dfold", start_row, end_row))
          end)
        end
      end
    end
  end

  return self
end

---Add a line break to the chat buffer
---@return nil
function UI:add_line_break()
  if not buffer_guard.ensure(self) then
    return
  end
  local _, _, line_count = self:last()

  self:unlock_buf()
  api.nvim_buf_set_lines(self.chat_bufnr, line_count, line_count, false, { "" })
  self:lock_buf()

  self:move_cursor(true)
end

---Update the cursor position in the chat buffer
---@param cursor_has_moved boolean
---@return nil
function UI:move_cursor(cursor_has_moved)
  if config.display.chat.auto_scroll then
    -- Check if cursor is already on the last line before streaming new content
    if self:is_visible() and not self.cursor.has_moved then
      local ok, cursor = pcall(api.nvim_win_get_cursor, self.winnr)
      if ok then
        local last_line = self:last()

        -- If already on last line, allow following
        if cursor[1] == last_line + 1 then
          self.cursor.has_moved = false
          self.cursor.pos = nil
        end
      end
    end

    if cursor_has_moved and self:is_active() then
      self:follow()
    elseif not self:is_active() then
      self:follow()
    end
  end
end

---Lock the chat buffer from editing
---@return nil
function UI:lock_buf()
  if not buffer_guard.ensure(self) then
    return
  end
  vim.bo[self.chat_bufnr].modified = false
  vim.bo[self.chat_bufnr].modifiable = false
end

---Unlock the chat buffer for editing
---@return nil
function UI:unlock_buf()
  if not buffer_guard.ensure(self) then
    return
  end
  vim.bo[self.chat_bufnr].modified = false
  vim.bo[self.chat_bufnr].modifiable = true
end

return UI
