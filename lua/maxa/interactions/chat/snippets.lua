local api = vim.api
local M = {}
local bindings = {}

local function engine()
  local ok, ls = pcall(require, "luasnip")
  if not ok then return nil, "LuaSnip is unavailable: " .. tostring(ls) end
  return ls
end

---Preflight before removing the invocation token; LuaSnip owns the grammar.
function M.prepare(selected, chat)
  if not chat or api.nvim_get_current_buf() ~= chat.bufnr or not vim.bo[chat.bufnr].modifiable
    or chat.current_request or chat.current_tool then
    return false, "snippet expansion requires the active editable Chat"
  end
  local ls, err = engine()
  if not ls then return false, err end
  local prompt = require("maxa.prompts.markdown").resolve_placeholders(vim.deepcopy(selected.config), selected.context)
  local contents = {}
  for _, message in ipairs(prompt.prompts) do
    if message.role ~= "user" then return false, "snip requires a user-only prompt" end
    contents[#contents + 1] = message.content
  end
  local ok, snippet = pcall(ls.parser.parse_snippet, "", table.concat(contents, "\n\n"), {
    trim_empty = false, dedent = false,
  })
  if not ok or not snippet then return false, "LuaSnip could not parse prompt: " .. tostring(snippet) end
  selected.snippet = snippet
  selected.snippet_input = {
    lines = api.nvim_buf_get_lines(chat.bufnr, 0, -1, false),
    cursor = api.nvim_win_get_cursor(0),
  }
  return true
end

local function restore_keys(bufnr)
  local maps = bindings[bufnr]
  if not maps then return end
  bindings[bufnr] = nil
  if not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_call(bufnr, function()
    for _, item in ipairs(maps) do
      pcall(vim.keymap.del, item.mode, item.key, { buffer = bufnr })
      if item.map.buffer == 1 then vim.fn.mapset(item.mode, false, item.map) end
    end
  end)
end

---Discard editing state, never snippet text. All LuaSnip roots belong to this
---Chat draft; nested and previously visited snippets must not survive submit.
function M.stop(bufnr)
  local ls = package.loaded["luasnip"]
  local active = bindings[bufnr] or (ls and ls.session.current_nodes[bufnr])
  if ls and api.nvim_buf_is_valid(bufnr) and ls.session.current_nodes[bufnr] then
    api.nvim_buf_call(bufnr, function()
      ls.active_update_dependents()
      while ls.session.current_nodes[bufnr] do ls.unlink_current() end
    end)
  end
  restore_keys(bufnr)
  if active then
    -- Lua mappings/tool execution may temporarily report Normal mode before
    -- restoring Select mode. Queue Escape for this Chat without a mode check.
    vim.schedule(function()
      if api.nvim_get_current_buf() == bufnr then api.nvim_input("<Esc>") end
    end)
  end
end

local function bind(chat)
  local bufnr = chat.bufnr
  if bindings[bufnr] then return end
  bindings[bufnr] = {}
  local function map(mode, key, action, desc)
    local previous = vim.fn.maparg(key, mode, false, true)
    bindings[bufnr][#bindings[bufnr] + 1] = { mode = mode, key = key, map = previous }
    vim.keymap.set(mode, key, function()
      if not action() then
        -- End our overlay and replay through the original completion/keymap.
        restore_keys(bufnr)
        api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, false, true), "m", false)
      end
    end, { buffer = bufnr, desc = desc })
  end
  local ls = require("luasnip")
  for _, mode in ipairs({ "i", "s" }) do
    map(mode, "<Tab>", function()
      if not ls.locally_jumpable(1) then return false end
      ls.jump(1)
      return true
    end, "[Chat snippet] Next field")
    map(mode, "<S-Tab>", function()
      if not ls.locally_jumpable(-1) then return false end
      ls.jump(-1)
      return true
    end, "[Chat snippet] Previous field")
    map(mode, "<C-l>", function()
      if ls.choice_active() then ls.change_choice(1) end
      return true
    end, "[Chat snippet] Next choice")
    map(mode, "<C-e>", function()
      if not ls.session.current_nodes[bufnr] then return false end
      local blink = package.loaded["blink.cmp"]
      if blink and blink.is_visible() then blink.hide(); return true end
      M.stop(bufnr)
      return true
    end, "[Chat snippet] Exit")
  end
end

function M.expand(selected, chat)
  local ok, failure = pcall(function()
    local ls, err = engine()
    if not ls then error(err) end
    local insertion = require("maxa.interactions.chat.slash_commands.insertion")
    local anchor, prefix, suffix = insertion.prompt_position(chat, selected.context, selected.config.insert)
    if not anchor then error("snippet insertion anchor is unavailable") end
    -- Insert layout boundaries before expansion, so the first selected node
    -- is not displaced by a subsequent Chat-builder cursor movement.
    if prefix ~= "" or suffix ~= "" then
      api.nvim_buf_set_text(chat.bufnr, anchor.row, anchor.col, anchor.row, anchor.col,
        vim.split(prefix .. suffix, "\n", { plain = true, trimempty = false }))
    end
    local pos = prefix ~= "" and { anchor.row + 1, 0 } or { anchor.row, anchor.col }
    -- Initialize node indentation without inheriting whitespace from the Chat
    -- line; LuaSnip mirrors/transforms also require this initialization.
    selected.snippet:indent("")
    ls.snip_expand(selected.snippet, { pos = pos, indent = false })
    bind(chat)
  end)
  if not ok then
    pcall(M.stop, chat.bufnr)
    local snapshot = selected.snippet_input
    if snapshot then
      api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, snapshot.lines)
      api.nvim_win_set_cursor(0, snapshot.cursor)
    end
    return false, "LuaSnip expansion failed: " .. tostring(failure)
  end
  return true
end

return M
