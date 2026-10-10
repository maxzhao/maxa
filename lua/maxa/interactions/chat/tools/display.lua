-- Chat owns rendering/provenance/lifecycle; tools own every semantic ToolView.
local M = {}
local api = vim.api
local helpers = require("maxa.interactions.chat.tools.display_helpers")
local presentation = require("maxa.interactions.chat.tools.presentation")
local NS = api.nvim_create_namespace("Maxa-tool_summary")
local RIGHT_NS = api.nvim_create_namespace("Maxa-tool_right")
local function decorate(bufnr, first, text, id)
  if not api.nvim_buf_is_valid(bufnr) or not first then return nil end
  if not text or text == "" then
    if id then pcall(api.nvim_buf_del_extmark, bufnr, RIGHT_NS, id) end
    return nil
  end
  return api.nvim_buf_set_extmark(bufnr, RIGHT_NS, first, 0, {
    id = id, right_gravity = true, virt_text = { { "  " .. text, "Comment" } },
    virt_text_pos = "eol_right_align", priority = 110,
  })
end
local states = {} -- bufnr -> existing call ID -> invocation-local state
local pending = {}
local observers = setmetatable({}, { __mode = "k" })
local orders = setmetatable({}, { __mode = "k" })
local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function chat_for(bufnr)
  local Chat = package.loaded["maxa.interactions.chat"]
  return Chat and Chat.buf_get_chat and Chat.buf_get_chat(bufnr)
end
local function valid(chat) return chat and chat.bufnr and api.nvim_buf_is_valid(chat.bufnr) end
local function source(state, phase, fragment)
  return { call_id = state.id, phase = phase, fragment = fragment, member = state.member,
    related_chat_id = state.related_chat_id }
end
local function write(chat, first, last, lines, origin)
  if not valid(chat) then return end
  local modifiable = vim.bo[chat.bufnr].modifiable
  vim.bo[chat.bufnr].modifiable = true
  local ok, err = pcall(function()
    if last == first + 1 and #lines == 1 then
      -- Preserve neighboring row anchors while replacing summary text.
      local old = api.nvim_buf_get_lines(chat.bufnr, first, last, false)[1] or ""
      if chat.ui and chat.ui.write_text then chat.ui:write_text(first, 0, first, #old, lines, origin)
      else api.nvim_buf_set_text(chat.bufnr, first, 0, first, #old, lines) end
    elseif chat.ui and chat.ui.write_lines then chat.ui:write_lines(first, last, lines, origin)
    else api.nvim_buf_set_lines(chat.bufnr, first, last, false, lines) end
  end)
  if valid(chat) then vim.bo[chat.bufnr].modifiable = modifiable end
  if not ok then error(err, 0) end
end
local function display_update(state, fn)
  if state.display_failed then return false end
  local ok, result = pcall(fn)
  if not ok then
    state.rendering = nil
    state.display_failed = true
    vim.notify("Tool display failed (" .. tostring(state.id) .. "): " .. tostring(result), vim.log.levels.ERROR)
  end
  return ok, result
end
local function row(state, mark)
  if not valid(state.chat) or not mark then return nil end
  local pos = api.nvim_buf_get_extmark_by_id(state.chat.bufnr, NS, mark, { details = true })
  if #pos > 0 and not (pos[3] and pos[3].invalid) then return pos[1] end
end
local function anchor(state, first, last)
  local b = state.chat.bufnr
  state.first = api.nvim_buf_set_extmark(b, NS, first, 0, { id = state.first, right_gravity = true })
  -- Own content is [first, last). A next-row boundary cannot move to the
  -- beginning of a summary when its entire text is replaced.
  state.last = api.nvim_buf_set_extmark(b, NS, last, 0, { id = state.last, right_gravity = false, strict = false })
end
local function extent(state)
  local child = state.members and state.members[#state.members] or state.continuation
  return child and extent(child) or row(state, state.last)
end
local function forget_marks(state, descendants)
  for _, key in ipairs({ "first", "last", "summary_mark", "detail_mark" }) do
    if state[key] and valid(state.chat) then pcall(api.nvim_buf_del_extmark, state.chat.bufnr, NS, state[key]) end
    state[key] = nil
  end
  if descendants ~= false then
    for _, member in ipairs(state.members or {}) do forget_marks(member) end
    if state.continuation then forget_marks(state.continuation) end
  end
end
local function clear_range(state, descendants)
  local first = row(state, state.first)
  local last = descendants and extent(state) or row(state, state.last)
  if not first and not last then return nil end
  if not first or not last or first >= last or last > api.nvim_buf_line_count(state.chat.bufnr) then
    error("Invalid tool display range: " .. tostring(first) .. ".." .. tostring(last), 0)
  end
  api.nvim_buf_clear_namespace(state.chat.bufnr, RIGHT_NS, first, last)
  state.right_mark = nil
  forget_marks(state, descendants == true)
  write(state.chat, first, last, {})
  return first
end
local function emit(state, text, status)
  if not text then return end
  for callback in pairs(observers[state.chat] or {}) do
    pcall(callback, { call_id = state.id, start_order = state.order, summary = text, status = status })
  end
end
function M.observe_tool_display(chat, callback)
  if type(callback) ~= "function" then return function() end end
  observers[chat] = observers[chat] or {}
  observers[chat][callback] = true
  return function()
    if observers[chat] then observers[chat][callback] = nil end
  end
end

M.format_path = helpers.format_path
M.parse_args = function(fn) return helpers.normalize_args(fn and fn.arguments) end
M.escape_markdown = function(text) return tostring(text or ""):gsub("~", "\\~") end
M.format_time = function() return os.date("%H:%M:%S") end
function M.format_duration(ms)
  if ms < 1000 then return string.format("%.0fms", ms) end
  local seconds = ms / 1000
  if seconds < 60 then return string.format("%.1fs", seconds) end
  return string.format("%dm%.0fs", math.floor(seconds / 60), seconds % 60)
end
function M.format_bytes_info(input, output)
  local total = (input or 0) + (output or 0)
  return total >= 1024 and string.format(" ↕%.1fKB", total / 1024) or ""
end
function M.format_ttl_status_suffix(meta)
  local ttl = meta and meta.ttl_result
  if not ttl then return "" end
  local policy = ttl.display_state or ttl.policy
  if policy == "keep" then return "" end
  if policy == "discarded" or ttl.discarded then return " · 🗑 discarded" end
  if policy == "expired" or ttl.expired then return " · 🧹 expired" end
  if policy == "persist" or ttl.persistent then return " · 💾 persist" end
  if policy == "defer" then return string.format(" · ⏱ defer %dr", tonumber(ttl.ttl) or 1) end
  return ttl.enabled ~= false and string.format(" · ⏱ TTL %dr", tonumber(ttl.ttl) or 1) or ""
end
function M.is_ttl_cleaned(meta)
  local ttl = meta and meta.ttl_result
  return ttl and (ttl.display_state == "discarded" or ttl.policy == "discarded" or ttl.discarded == true
    or ttl.display_state == "expired" or ttl.policy == "expired" or ttl.expired == true) or false
end
function M.apply_ttl_line_style(text, meta)
  return M.is_ttl_cleaned(meta) and ("~~" .. text .. "~~") or text
end
local function async(name, args)
  if name == "run" then return helpers.normalize_args(args.opts).async == true end
  return false
end
local function icon(name, args, meta)
  if name == "wait" and meta then return "✅" end
  if async(name, args) then return "📨" end
  return name == "run" and args.scope == "tool" and not (type(args.title) == "string" and args.title:find("%S")) and "🔗" or "⚡"
end
local function view_for(name, args, meta)
  local persisted = meta and meta.presentation and meta.presentation.result
  local view = persisted and presentation.normalize(persisted)
    or presentation.builtin(name, args, meta and { ok = meta.is_error ~= true, text = meta.content or "" })
  if M.is_ttl_cleaned(meta) then view.blocks = {} end
  return view
end
local function summary(name, args, meta, view)
  local is_error = meta and meta.is_error == true
  if view.summary == false and not is_error then return nil, false end
  local detail = view.summary == false and name or (view.summary or name)
  detail = M.escape_markdown(detail:gsub("[\r\n]", " "))
  if meta and meta.duration_ms then detail = detail .. " (" .. M.format_duration(meta.duration_ms) .. ")" end
  if meta then detail = detail .. M.format_bytes_info(meta.input_bytes, meta.output_bytes) end
  detail = detail .. M.format_ttl_status_suffix(meta)
  local cancelled = meta and meta.status == "cancelled"
  if cancelled then detail = detail .. " · cancelled" end
  if meta and meta.status == "not-executed" then detail = detail .. " · not executed" end
  return M.apply_ttl_line_style((cancelled and "⊘" or is_error and "❌" or icon(name, args, meta)) .. " " .. detail, meta), is_error
end
function M.build_tool_summary_text(call, meta)
  local fn = call and call["function"]
  if not fn then return nil, false end
  local args = M.parse_args(fn)
  return summary(fn.name or "unknown", args, meta, view_for(fn.name or "unknown", args, meta))
end
function M.format_tool_detail(name, args)
  return presentation.builtin(name, args).summary or name
end
function M.get_display(name, args, meta)
  args = helpers.normalize_args(args)
  local view = view_for(name, args, meta)
  return icon(name, args), view.summary == false and "" or view.summary or name
end
function M.apply_highlight(bufnr, line, is_error)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) or not line or line >= api.nvim_buf_line_count(bufnr) then return end
  local text = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
  pcall(api.nvim_buf_set_extmark, bufnr, NS, line, 0, { end_row = line, end_col = #text,
    hl_group = is_error and "MaxaAIChatToolFailure" or "MaxaAIChatToolSuccess", hl_eol = true })
  local bytes = text:find(" ↕", 1, true)
  if bytes then pcall(api.nvim_buf_set_extmark, bufnr, NS, line, bytes, { end_row = line, end_col = #text, hl_group = "DiagnosticWarn" }) end
end
function M.highlight_summary_lines(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end
  for index, text in ipairs(api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if text:match("^⚡ ") or text:match("^🔗 ") or text:match("^📨 ") or text:match("^❌ ") or text:match("^~~") then
      M.apply_highlight(bufnr, index - 1, text:find("❌", 1, true) ~= nil)
    end
  end
end
local function stop(state)
  if state.timer then pcall(state.timer.stop, state.timer); pcall(state.timer.close, state.timer); state.timer = nil end
end
local function insert_at(chat)
  if chat.builder then
    local modifiable = vim.bo[chat.bufnr].modifiable
    chat:add_buf_message({ role = require("maxa.config").constants.LLM_ROLE })
    vim.bo[chat.bufnr].modifiable = modifiable
  end
  local last = api.nvim_buf_line_count(chat.bufnr)
  local first = last
  while first > 0 and api.nvim_buf_get_lines(chat.bufnr, first - 1, first, false)[1] == "" do first = first - 1 end
  write(chat, first, last, { "" })
  return first + 1
end
local redraw, refresh_outer, snapshot, invocation_parts, sync_native_parent
local function current_view(state, result)
  if state.mirrored then return vim.deepcopy(state.mirrored.view) end
  local target_name = state.name == "run" and state.args.scope == "tool" and state.args.command or state.name
  local view = state.final or state.shown or (state.bound and presentation.view(state.bound, state.bound_args, result, target_name)
    or presentation.builtin(state.name, state.args, result))
  view = vim.deepcopy(view)
  if state.right_set then view.right = state.right end
  if M.is_ttl_cleaned(state.meta) then view.blocks = {} end
  if state.name == "run" and view.summary ~= false and type(state.args.title) == "string" and state.args.title:find("%S") then
    local summary = presentation.builtin("run", state.args, result).summary
    for _, block in ipairs(view.blocks or {}) do
      if block.kind == "fold" and block.title == view.summary then block.title = summary end
    end
    view.summary = summary
  end
  return view
end
local function pending_text(state)
  if state.mirrored then return state.mirrored.summary end
  local view = current_view(state)
  if view.summary == false or view.progress == false then return nil end
  local text = M.escape_markdown((view.summary or state.name):gsub("[\r\n]", " "))
  if state.status == "queued" then return "◷ " .. text .. " · queued" end
  local seconds = math.max(0, math.floor((vim.uv.hrtime() - state.started) / 1e9))
  return FRAMES[state.frame] .. " " .. text .. "... " .. seconds .. "s"
end
local render_pending
local function update_pending(state)
  if state.terminal or not valid(state.chat) then return end
  local text = pending_text(state)
  if not text then return end
  text = string.rep("   ", state.indent or 0) .. text
  local first = row(state, state.summary_mark)
  if not first then
    if state.member or state.continuation or #current_view(state).blocks > 0 then redraw(state); return end
    first = insert_at(state.chat)
    write(state.chat, first, first, { text }, source(state, "request"))
    anchor(state, first, first + 1)
    state.summary_mark = api.nvim_buf_set_extmark(state.chat.bufnr, NS, first, 0, { right_gravity = true })
  else write(state.chat, first, first + 1, { text }, source(state, "request")) end
  pcall(api.nvim_buf_set_extmark, state.chat.bufnr, NS, first, 0, {
    id = state.summary_mark, right_gravity = true,
    end_row = first, end_col = #text, hl_group = "MaxaAIChatInfo", hl_eol = true })
  state.right_mark = decorate(state.chat.bufnr, first, current_view(state).right, state.right_mark)
  emit(state, text, "pending")
  for _, member in ipairs(state.members or {}) do
    if not member.terminal then
      member.frame = state.frame
      render_pending(member)
    end
  end
  if state.refresh_wait then state.refresh_wait() end
end
render_pending = function(state)
  return display_update(state, function() return update_pending(state) end)
end
local function detail(state, text)
  if state.terminal or (state.parent and state.parent.terminal) then return false end
  state.detail = text and tostring(text):gsub("[\r\n]", " ") or nil
  if state.sink then state.publish(); return true end
  if not valid(state.chat) then return false end
  if state.member or state.continuation or #current_view(state).blocks > 0 then redraw(state); return true end
  local parent = row(state, state.summary_mark)
  if not parent then return false end
  local first = row(state, state.detail_mark)
  if text == nil then
    if not first then return true end
    write(state.chat, first, first + 1, {})
    api.nvim_buf_del_extmark(state.chat.bufnr, NS, state.detail_mark)
    state.detail_mark = nil
    if state.last then anchor(state, row(state, state.first), parent + 1) end
    return true
  end
  text = "   └─ " .. tostring(text):gsub("[\r\n]", " ")
  first = first or parent + 1
  write(state.chat, first, state.detail_mark and first + 1 or first, { text }, source(state, "request"))
  state.detail_mark = api.nvim_buf_set_extmark(state.chat.bufnr, NS, first, 0, {
    id = state.detail_mark, right_gravity = false, end_row = first, end_col = #text, hl_group = "Comment", hl_eol = true })
  if state.last then anchor(state, row(state, state.first), first + 1) end
  return true
end

-- Shared live/history fragment construction. All source selection is host-owned.
local function fragments(name, args, view, meta, origin)
  local out = {}
  local text, is_error = summary(name, args, meta, view)
  if text then out[#out + 1] = { content = text, origin = origin, summary = true, is_error = is_error, right = view.right } end
  for index, block in ipairs(view.blocks or {}) do
    local content = block.content
    local fold
    if block.kind == "fold" then
      local merged = block.title == view.summary and #out == 1 and out[1].summary
      local title = merged and text or block.title
      if merged then out = {} end
      content = title .. "\n\n" .. content
      fold = { title = title, collapsed = block.collapsed ~= false }
    end
    out[#out + 1] = { role = block.role, content = content,
      origin = vim.tbl_extend("force", origin or {}, { fragment = index }), fold = fold,
      merged_summary = fold and block.title == view.summary and text ~= nil,
      right = fold and block.title == view.summary and text ~= nil and view.right or nil }
  end
  return out
end
local function render_fragments(state, parts, at)
  local chat = state.chat
  if not valid(chat) then return end
  local first = at or insert_at(chat)
  local current, locations, spans = first, {}, {}
  for _, part in ipairs(parts) do
    local lines = {}
    if part.role and chat.ui and chat.ui.set_header then
      local config = require("maxa.config")
      local role = part.role == "user" and config.constants.USER_ROLE or config.constants.LLM_ROLE
      lines = { "", "" }
      chat.ui:set_header(lines, config.interactions.chat.roles[role])
      if not chat._tool_input then
        chat._last_role = role
        if chat.builder then chat.builder.state.last_role = role end
        chat.ui.last_role = role
      end
    end
    local start = current + #lines
    vim.list_extend(lines, vim.split(part.content, "\n", { plain = true }))
    write(chat, current, current, lines, part.origin)
    current = current + #lines
    if (part.summary or part.fold) and not state.summary_mark then
      state.summary_mark = api.nvim_buf_set_extmark(chat.bufnr, NS, start, 0, { right_gravity = true })
      M.apply_highlight(chat.bufnr, start, part.is_error or (state.meta and state.meta.is_error))
    end
    if part.right then
      local mark = decorate(chat.bufnr, start, part.right)
      if start == row(state, state.summary_mark) then state.right_mark = mark end
    end
    locations[part.origin and part.origin.fragment or false] = { start, current - 1 }
    if part.fold then spans[#spans + 1] = { first = start, last = current - 1, fold = part.fold } end
    for _, span in ipairs(part.fold_spans or {}) do
      local location = locations[span.first]
      if location then spans[#spans + 1] = { first = location[1], last = current - 1, fold = span } end
    end
  end
  -- Empty target views still reserve an invocation-local region; otherwise a
  -- later show() can acquire the sibling's row at the same insertion boundary.
  if current == first then write(chat, first, first, { "" }, source(state, "request")); current = current + 1 end
  anchor(state, first, current)
  for _, span in ipairs(spans) do
    if chat.ui and chat.ui.folds then
      chat.ui.folds:create_tool_fold(chat.bufnr, span.first, span.last, span.fold.title, { collapsed = span.fold.collapsed })
    end
  end
end
local function final_view(state, result) return current_view(state, result) end

-- These snapshots describe only existing invocations/members, not tool-authored
-- components. Definitions/callbacks/anchors never enter saved history.
snapshot = function(state)
  if state.mirrored then
    local item = vim.deepcopy(state.mirrored)
    item.indent = state.indent
    return item
  end
  local meta = state.meta or (state.terminal and {
    is_error = state.result_ok == false, status = state.status, duration_ms = state.duration_ms,
    input_bytes = state.input_bytes, output_bytes = state.output_bytes,
  })
  if meta then
    meta = { is_error = meta.is_error, status = meta.status, duration_ms = meta.duration_ms, input_bytes = meta.input_bytes,
      output_bytes = meta.output_bytes, ttl_result = vim.deepcopy(meta.ttl_result) }
  end
  local view = current_view(state)
  local out = { name = state.name, args = vim.deepcopy(state.args), view = view,
    terminal = state.terminal == true, status = state.status, detail = state.detail, indent = state.indent,
    summary = state.terminal and summary(state.name, state.args, meta, view) or pending_text(state), meta = vim.deepcopy(meta),
    related_chat_id = state.related_chat_id, call_id = state.id }
  if state.members then
    out.members = {}
    for index, member in ipairs(state.members) do out.members[index] = snapshot(member) end
  end
  if state.saved_continuation then out.continuation = vim.deepcopy(state.saved_continuation)
  elseif state.continuation then out.continuation = snapshot(state.continuation) end
  return out
end
local function own_parts(item, origin)
  local parts = fragments(item.name, item.args, item.view, item.meta, origin)
  if not item.terminal then
    for _, part in ipairs(parts) do
      if part.summary then part.content = item.summary or ""
      elseif part.merged_summary then
        local newline = part.content:find("\n", 1, true)
        part.content = (item.summary or part.fold.title) .. (newline and part.content:sub(newline) or "")
        part.fold.title = item.summary or part.fold.title
      end
    end
    if not item.summary then
      for index = #parts, 1, -1 do if parts[index].summary then table.remove(parts, index) end end
    end
  end
  if item.detail and item.summary then
    -- Detail remains inside the owning fold when its header is the summary.
    if parts[1] and parts[1].fold then
      local newline = parts[1].content:find("\n", 1, true)
      parts[1].content = parts[1].content:sub(1, newline - 1) .. "\n   └─ " .. item.detail .. parts[1].content:sub(newline)
    else table.insert(parts, math.min(2, #parts + 1), { content = "   └─ " .. item.detail, origin = origin }) end
  end
  if item.indent and item.indent > 0 then
    local prefix = string.rep("   ", item.indent)
    for _, part in ipairs(parts) do
      part.content = prefix .. part.content:gsub("\n", "\n" .. prefix)
      if part.fold then part.fold.title = prefix .. part.fold.title end
    end
  end
  return parts
end
invocation_parts = function(item, origin)
  local out, counter = {}, 0
  local function append(current, member, indent)
    current = vim.tbl_extend("force", {}, current, { indent = indent })
    local first = #out + 1
    local own_origin = vim.tbl_extend("force", origin or {}, { member = member, related_chat_id = current.related_chat_id,
      call_id = current.call_id or (origin and origin.call_id) })
    local parts = own_parts(current, own_origin)
    for _, part in ipairs(parts) do
      counter = counter + 1
      part.origin = vim.tbl_extend("force", own_origin, { fragment = counter })
      out[#out + 1] = part
    end
    for index, child in ipairs(current.members or {}) do append(child, index, indent + 1) end
    local completed_wait = current.terminal and (current.name == "wait"
      or current.name == "run" and current.args.scope == "tool" and current.args.command == "wait")
    if current.continuation then append(current.continuation, member, indent + 1) end
    if (current.members or completed_wait and current.continuation) and #out > first then
      local last = out[#out]
      last.fold_spans = last.fold_spans or {}
      last.fold_spans[#last.fold_spans + 1] = {
        first = out[first].origin.fragment, first_call_id = out[first].origin.call_id,
        title = string.rep("   ", indent) .. (current.summary or current.view.summary or current.name),
        collapsed = current.terminal,
      }
    end
  end
  append(item, nil, 0)
  return out
end
refresh_outer = function(state)
  if state.sink or state.rendering then return end
  if state.members and state.chat.ui and state.chat.ui.folds then
    local first, last = row(state, state.first), extent(state)
    if first and last then
      state.chat.ui.folds:create_tool_fold(state.chat.bufnr, first, last - 1,
        string.rep("   ", state.indent or 0) .. (state.terminal and summary(state.name, state.args, state.meta, current_view(state)) or pending_text(state) or state.name),
        { collapsed = state.terminal == true })
    end
  end
  if state.parent then refresh_outer(state.parent) end
end
redraw = function(state, at)
  if state.sink then state.publish(); return end
  if not valid(state.chat) then return end
  state.rendering = true
  local first = clear_range(state) or at
  local item = snapshot(state)
  if state.terminal and state.saved_continuation then
    render_fragments(state, invocation_parts(item, source(state, "result")), first)
    state.rendering = nil
    refresh_outer(state)
    return
  end
  render_fragments(state, own_parts(item, source(state, state.terminal and "result" or "request")), first)
  local cursor = row(state, state.last)
  for _, member in ipairs(state.members or {}) do
    if not row(member, member.first) then redraw(member, cursor) end
    cursor = extent(member)
  end
  if state.continuation and not row(state.continuation, state.continuation.first) then
    redraw(state.continuation, cursor)
  end
  state.rendering = nil
  refresh_outer(state)
end
local function make_handle(state)
  local handle = { _state = state }
  function handle:show(view)
    if state.terminal or (state.parent and state.parent.terminal) then return false end
    view = presentation.normalize(view)
    if not view then return false end
    state.shown = view
    return display_update(state, function() redraw(state) end)
  end
  function handle:right(text)
    if state.terminal or (state.parent and state.parent.terminal) then return false end
    if text ~= nil and type(text) ~= "string" then return false end
    text = text and text:gsub("[\r\n]", " ") or nil
    if state.right_set and state.right == text then return true end
    state.right, state.right_set = text, true
    return display_update(state, function()
      if state.sink then state.publish()
      elseif valid(state.chat) then
        state.right_mark = decorate(state.chat.bufnr, row(state, state.summary_mark), text, state.right_mark)
      end
    end)
  end
  function handle:detail(text)
    local ok, result = display_update(state, function() return detail(state, text) end)
    return ok and result or false
  end
  function handle:input(options, on_submit)
    if state.terminal or (state.parent and state.parent.terminal) then return nil, "tool invocation has ended" end
    if state.batch_parent then return nil, "multicall members cannot open parent Chat input" end
    if state.sink then return nil, "Async presentation has no active Chat input UI" end
    local input, err = require("maxa.interactions.chat.tools.input").open(state.chat, options, on_submit)
    if input then state.input = input end
    return input, err
  end
  return handle
end
function M.create_ui(chat, call_id, name, args, definition)
  states[chat.bufnr] = states[chat.bufnr] or {}
  local state = states[chat.bufnr][call_id]
  if not state then
    orders[chat] = (orders[chat] or 0) + 1
    state = { chat = chat, id = call_id, name = name, args = vim.deepcopy(args or {}),
      order = orders[chat], started = vim.uv.hrtime(), frame = 1 }
    state.handle = make_handle(state)
    states[chat.bufnr][call_id] = state
  end
  -- Chat execution adapters carry cmds/schema/output, not the owning ToolView
  -- callback. Only bind an actual display owner; dispatch binds targets later.
  if definition and type(definition.display) == "function" then
    state.bound, state.bound_args = definition, vim.deepcopy(args or {})
  end
  return state.handle
end
-- Runtime-owned related Chat identity; never a tool-authored UI coordinate.
function M.link_chat(handle, chat)
  if not handle or not chat then return end
  local state = handle._state
  if state.terminal then return end
  local id = chat.opts and chat.opts.save_id
  if id and not require("maxa.session.history_core").is_unsavable_save_id(id) then
    state.related_chat_id = id
  end
  chat._tool_display_owner = { chat = state.chat, call_id = state.id, member = state.member }
  display_update(state, function() if state.sink then state.publish() else redraw(state) end end)
end

-- Native members have their own canonical IDs, but share the existing batch UI.
function M.begin_native_batch(parent, members)
  local p = parent._state
  p.members = {}
  for index, member in ipairs(members) do
    local state = M.create_ui(p.chat, member.call_id, member.name, member.args, member.definition)._state
    state.parent, state.member, state.batch_parent = p, index, true
    state.status, state.indent = "queued", (p.indent or 0) + 1
    p.members[index] = state
  end
  display_update(p, function() redraw(p) end)
end
function M.start_member(handle)
  local state = handle._state
  if state.terminal or state.parent.terminal then return end
  state.status, state.started = "running", vim.uv.hrtime()
  if state.sink then state.publish() else render_pending(state) end
end
function M.bind_target(handle, definition, args)
  if not handle then return end
  local state = handle._state
  if state.terminal then return end
  if state.bound == definition and vim.deep_equal(state.bound_args, args) then return end
  state.bound, state.bound_args = definition, vim.deepcopy(args)
  display_update(state, function() redraw(state) end)
end
function M.complete_ui(handle, result)
  if not handle then return nil end
  local state = handle._state
  if state.terminal then return state.final end
  state.result_ok = result.ok
  state.final = final_view(state, result)
  state.duration_ms = math.floor((vim.uv.hrtime() - state.started) / 1e6 + 0.5)
  state.status = result.status or (result.ok and "success" or "error")
  if state.member then
    local encoded, args = pcall(vim.json.encode, state.args)
    state.input_bytes, state.output_bytes = encoded and #args or 2, #(result.text or "")
  end
  state.detail = nil
  state.terminal = true
  for callback in pairs(state.on_terminal or {}) do pcall(callback) end
  state.on_terminal = nil
  stop(state)
  if state.input then pcall(state.input.close, state.input) end
  if state.detach_wait then pcall(state.detach_wait) end
  state.detach_wait, state.refresh_wait = nil, nil
  for _, member in ipairs(state.members or {}) do
    M.complete_ui(member.handle, { ok = result.ok, text = result.text, status = result.status or (result.ok and "success" or "cancelled") })
  end
  display_update(state, function()
    if state.sink then state.publish()
    elseif state.member or state.members then redraw(state) end
  end)
  return state.final
end
-- An async task retains its own invocation/member snapshots, never caller anchors
-- or an input lease. Blocking wait may subscribe; submission stays immutable.
function M.async_ui(context, task)
  local original = context.ui and context.ui._state
  local state = {
    chat = context.chat or (original and original.chat), id = task.id,
    name = original and original.name or context.tool_name or task.tool,
    args = vim.deepcopy(context.display_args or (original and original.args) or context.params or {}),
    bound = original and original.bound, bound_args = original and vim.deepcopy(original.bound_args),
    sink = true, started = vim.uv.hrtime(), frame = 1, listeners = {}, submission = context.ui,
  }
  local handle = make_handle(state)
  state.handle = handle
  state.publish = function()
    for callback in pairs(state.listeners) do pcall(callback, snapshot(state)) end
    if state.terminal then state.listeners = {} end
  end
  function handle:_observe(callback)
    pcall(callback, snapshot(state))
    if state.terminal then return function() end end
    state.listeners[callback] = true
    return function() state.listeners[callback] = nil end
  end
  -- Active wait's existing spinner drives the original summary frame too.
  -- Child tool changes arrive via the retained sink, never buffer scans/polling.
  function handle:_snapshot(frame)
    if frame and not state.terminal then state.frame = frame end
    for _, member in ipairs(state.members or {}) do
      if not member.terminal then member.frame = state.frame end
    end
    return snapshot(state)
  end
  function handle:_finish(result) return M.complete_ui(self, result) end
  if original then M.follow_async_right(context.ui, handle) end
  return handle
end

-- A completed submission remains immutable except for its source-owned right
-- decoration. Never use a terminal tool handle to reopen text/detail/input.
function M.follow_async_right(submission, sink)
  local root = submission._state
  local unsubscribe, detached
  local function detach()
    if detached then return end
    detached = true
    if unsubscribe then unsubscribe() end
    root.detach_right = nil
  end
  local function update(state, item)
    if not state.terminal and state.member and item.view then
      state.shown = { summary = item.view.summary, blocks = {} }
    end
    local text = item.view and item.view.right
    if text ~= nil or state.right_set then
      if not state.right_set or state.right ~= text then
        state.right, state.right_set = text, true
        if state.final then state.final.right = text end
        display_update(state, function()
          state.right_mark = decorate(state.chat.bufnr, row(state, state.summary_mark), text, state.right_mark)
        end)
      end
    end
    for index, child in ipairs(item.members or {}) do
      local member = state.members and state.members[index]
      if member then update(member, child) end
    end
  end
  unsubscribe = sink:_observe(function(item)
    if detached then return end
    if not valid(root.chat) then detach(); return end
    update(root, item)
    local meta = root.meta
    if meta and meta.presentation then
      meta.presentation.result.right = root.right
      if root.members then meta.presentation.invocation = snapshot(root) end
    end
    if sync_native_parent then sync_native_parent(root) end
    if item.terminal then detach() end
  end)
  if not detached then root.detach_right = detach end
end

-- Retain only the completed ToolView, not the source execution snapshot. The
-- wait owns the surrounding fold and survives consume without live subscriptions.
function M.retain_wait_result(handle, sink)
  if not handle or not sink or not sink._snapshot then return end
  local state = handle._state
  if state.terminal or state.sink then return end
  display_update(state, function()
    local item = sink:_snapshot()
    if not item.terminal then return end
    state.shown = { summary = current_view(state).summary, blocks = {} }
    state.saved_continuation = {
      name = item.name, args = {}, view = vim.deepcopy(item.view), terminal = true,
      related_chat_id = item.related_chat_id,
    }
    state.related_chat_id = item.related_chat_id
  end)
end

-- Blocking wait mounts invocation-local mirrors; source execution and definitions
-- stay in the async sink. Updating one member does not replace its siblings.
function M.attach_wait(handle, sink)
  if not handle or not sink or not sink._observe then return function() end end
  local state = handle._state
  if state.terminal or state.sink then return function() end end
  local detached = false
  local function mirror(item, parent, existing, member)
    local previous = existing and existing.mirrored
    if previous and previous.terminal then return existing end
    local target = existing or { chat = state.chat, id = state.id, parent = parent, member = member, frame = 1,
      started = vim.uv.hrtime(), batch_parent = true, indent = (parent.indent or 0) + 1 }
    target.name, target.args, target.shown = item.name, item.args, item.view
    target.related_chat_id = item.related_chat_id
    target.terminal, target.status, target.detail, target.meta = item.terminal, item.status, item.detail, item.meta
    target.mirrored = item
    if not existing then
      target.members = item.members and {} or nil
      for index, child in ipairs(item.members or {}) do target.members[index] = mirror(child, target, nil, index) end
      if item.continuation then target.continuation = mirror(item.continuation, target) end
      return target
    end
    local structure_changed = ((previous and previous.members ~= nil) ~= (item.members ~= nil))
      or ((previous and previous.continuation ~= nil) ~= (item.continuation ~= nil))
    local own_changed = structure_changed or not vim.deep_equal(previous and previous.view, item.view)
      or (previous and previous.detail ~= item.detail) or (previous and previous.terminal ~= item.terminal)
      or (previous and previous.related_chat_id ~= item.related_chat_id)
    if structure_changed then
      local at = clear_range(target, true)
      target.members = item.members and {} or nil
      for index, child in ipairs(item.members or {}) do target.members[index] = mirror(child, target, nil, index) end
      target.continuation = item.continuation and mirror(item.continuation, target) or nil
      redraw(target, at)
    else
      if own_changed then redraw(target)
      else
        local first = row(target, target.summary_mark)
        if first and item.summary and previous.summary ~= item.summary then
          write(state.chat, first, first + 1, { string.rep("   ", target.indent or 0) .. item.summary }, source(target, "request"))
        end
      end
      for index, child in ipairs(item.members or {}) do mirror(child, target, target.members[index], index) end
      if item.continuation then mirror(item.continuation, target, target.continuation) end
      refresh_outer(target)
    end
    return target
  end
  local function update(item)
    if detached or state.terminal then return end
    display_update(state, function()
      if not state.continuation then
        state.continuation = mirror(item, state)
        redraw(state)
      else mirror(item, state, state.continuation) end
    end)
  end
  local unsubscribe = sink:_observe(update)
  state.refresh_wait = function() update(sink:_snapshot(state.frame)) end
  local function detach()
    if detached then return end
    detached = true
    unsubscribe()
    state.refresh_wait, state.detach_wait = nil, nil
    display_update(state, function()
      if state.continuation then clear_range(state.continuation, true) end
      state.continuation = nil
      redraw(state)
    end)
    state.continuation = nil
  end
  state.detach_wait = detach
  M.on_terminal(handle, detach)
  return detach
end


function M.push_pending_tool(bufnr, name, args, msg_count, call_id)
  pending[bufnr] = pending[bufnr] or {}
  pending[bufnr][#pending[bufnr] + 1] = { name = name, args = args, msg_count = msg_count, id = call_id }
end
function M.setup()
  api.nvim_create_autocmd("User", { pattern = "MaxaAIToolStarted", callback = function(event)
    local bufnr = event.data and event.data.bufnr
    local info = bufnr and pending[bufnr] and table.remove(pending[bufnr], 1)
    local chat = bufnr and chat_for(bufnr)
    if not info or not valid(chat) or not info.id then return end
    local handle = M.create_ui(chat, info.id, info.name, info.args)
    local state = handle._state
    state.msg_count = info.msg_count
    orders[chat] = (orders[chat] or 0) + 1
    state.order, state.started = orders[chat], vim.uv.hrtime()
    render_pending(state)
    if pending_text(state) then
      state.timer = vim.uv.new_timer()
      state.timer:start(120, 120, vim.schedule_wrap(function()
        if state.terminal or not valid(chat) then stop(state); return end
        state.frame = state.frame % #FRAMES + 1
        render_pending(state)
      end))
    end
  end })
  api.nvim_create_autocmd("User", { pattern = "MaxaAIToolsFinished", callback = function(event)
    local bufnr = event.data and event.data.bufnr
    pending[bufnr] = nil
    for _, state in pairs(states[bufnr] or {}) do
      if not state.terminal then
        M.complete_ui(state.handle, { ok = false, text = "tool cancelled" })
        display_update(state, function() clear_range(state, true) end)
      end
    end
  end })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, { callback = function(event)
    for _, state in pairs(states[event.buf] or {}) do
      if state.detach_right then state.detach_right() end
      M.complete_ui(state.handle, { ok = false, text = "Chat closed" })
    end
    states[event.buf], pending[event.buf] = nil, nil
  end })
end

local function result_id(tool) local call = tool.function_call or tool._tool_call; return call and (call.call_id or call.id) end
local function find_result(chat, id)
  for _, message in ipairs(chat.messages or {}) do
    if message.role == "tool" and message.tools and message.tools.call_id == id then return message end
  end
end
sync_native_parent = function(state)
  local parent = state and state.parent
  if parent and parent.name == "multicall" and parent.meta and parent.meta.presentation then
    parent.meta.presentation.invocation = snapshot(parent)
  end
end
local function refresh_native_snapshot(item, messages)
  if item.name ~= "multicall" then return end
  for _, member in ipairs(item.members or {}) do
    for _, message in ipairs(messages or {}) do
      if message.role == "tool" and message.tools and message.tools.call_id == member.call_id then
        local meta = message._meta or {}
        member.meta = { is_error = meta.is_error, status = meta.status, duration_ms = meta.duration_ms,
          input_bytes = meta.input_bytes, output_bytes = meta.output_bytes, ttl_result = vim.deepcopy(meta.ttl_result) }
        if meta.presentation and meta.presentation.result then member.view = vim.deepcopy(meta.presentation.result) end
        if M.is_ttl_cleaned(meta) then
          member.view.blocks, member.continuation = {}, nil
          member.members = nil
        end
        if member.name == "run" and type(member.args.title) == "string" and member.args.title:find("%S") then
          member.view.summary = presentation.builtin("run", member.args).summary
        end
        member.summary = summary(member.name, member.args, member.meta, member.view)
        break
      end
    end
  end
end
function M.add_tool_output(chat, tool, for_llm, for_user, store_output, opts)
  opts = opts or {}
  local id = result_id(tool)
  local handle = id and M.create_ui(chat, id, tool.name or "unknown", tool.args)
  local state = handle and handle._state
  local is_error = opts.is_error
  if is_error == nil then
    is_error = (state and state.result_ok == false) or (chat.tools and chat.tools.status == "error") or false
  end
  local result = { ok = not is_error, text = for_llm or "" }
  -- Canonical results must exist even if final UI rendering fails.
  store_output(chat, tool, for_llm, "", opts)
  local view = state and (state.final or M.complete_ui(handle, result)) or presentation.builtin(tool.name, tool.args, result)
  local message = id and find_result(chat, id)
  local meta = message and message._meta or {}
  if message then message._meta = meta end
  meta.duration_ms = state and math.floor((vim.uv.hrtime() - state.started) / 1e6 + 0.5) or nil
  meta.call_time, meta.is_error = M.format_time(), is_error or nil
  local encoded, args = pcall(vim.json.encode, tool.args or {})
  meta.input_bytes, meta.output_bytes = encoded and #args or 0, #(for_llm or "")
  if state and state.msg_count then
    for index = state.msg_count + 1, #chat.messages do
      local msg = chat.messages[index]
      if msg.context and msg.context.id then meta.output_bytes = meta.output_bytes + #(msg.content or "") end
    end
  end
  if id then
    local wrapped = require("maxa.interactions.chat.tools.builtin.runtime.wrapped_side_effect_registry").take(id)
    local images = wrapped and wrapped.images
    if images and #images > 0 then
      meta.images, meta.image = images, images[1]
      meta.tag = meta.tag or images[1].tag or "image_tool_result"
    end
    if wrapped then meta.wrapped_side_effects = wrapped.tools end
    local ttl = require("maxa.interactions.chat.tools.builtin.runtime.ttl_result")
    local ttl_opts = ttl.take_pending(id)
    if message and (ttl_opts or images and #images > 0) then ttl.attach_to_tool_result(chat, message, id, ttl_opts or { ttl = 3, cleanup = "image" }) end
  end
  meta.status = state and state.status or meta.status
  meta.presentation = { result = vim.deepcopy(view), related_chat_id = state and state.related_chat_id,
    batch_call_id = state and state.parent and state.parent.name == "multicall" and state.parent.id }
  if state and (state.members or state.saved_continuation) then
    state.meta = meta
    meta.presentation.invocation = snapshot(state)
  end
  -- A tool's message blocks may span request/result phases (ask). The host
  -- captures the pure request view separately and never forges model messages.
  local request_view = state and state.request_view
  if request_view then meta.presentation.request = vim.deepcopy(request_view) end
  if state then sync_native_parent(state) end
  if not state and valid(chat) then
    state = { chat = chat, id = id, name = tool.name, args = tool.args or {} }
  end
  if state then
    state.meta = meta
    display_update(state, function()
      if state.parent and state.parent.name == "multicall" then
        -- Member output is canonical on its own ID; the parent owns only layout.
        redraw(state)
      elseif state.members and row(state, state.first) then
        -- Member final views are already committed. Only decorate the outer
        -- summary; snapshots above retain the complete restoration content.
        redraw(state)
      else
        local first = clear_range(state, true)
        local parts = {}
        if request_view then vim.list_extend(parts, fragments(tool.name, tool.args, request_view, nil, source(state, "request"))) end
        if meta.presentation.invocation then
          vim.list_extend(parts, invocation_parts(meta.presentation.invocation, source(state, "result")))
        else vim.list_extend(parts, fragments(tool.name, tool.args, view, meta, source(state, "result"))) end
        render_fragments(state, parts, first)
      end
      local text = summary(tool.name, tool.args or {}, meta, view)
      emit(state, text, is_error and "error" or "success")
    end)
  end
end
function M.on_terminal(handle, callback)
  if not handle then return end
  local state = handle._state
  if state.terminal then pcall(callback); return end
  state.on_terminal = state.on_terminal or {}
  state.on_terminal[callback] = true
end
function M.clear_transient_ui(handle)
  if not handle or handle._state.terminal then return end
  handle._state.shown = nil
  local request = handle._state.request_view
  if request then handle:show(request); handle._state.shown = nil end
end
function M.set_request_view(handle, view)
  if handle then handle._state.request_view = presentation.normalize(view) end
end
function M.get_tool_summary_line(bufnr, id)
  local state = states[bufnr] and states[bufnr][id]
  return state and row(state, state.summary_mark)
end
function M.refresh_tool_summary_line(chat, id)
  local message = find_result(chat, id)
  if not message then return false end
  local state = states[chat.bufnr] and states[chat.bufnr][id]
  if not state then
    for _, msg in ipairs(chat.messages or {}) do
      for _, call in ipairs(msg.tools and msg.tools.calls or {}) do
        if (call.call_id or call.id) == id then
          local fn = call["function"]
          state = M.create_ui(chat, id, fn.name, M.parse_args(fn))._state
          state.terminal = true
        end
      end
    end
  end
  if not state then return false end
  if not row(state, state.first) then
    local provenance = chat.ui and chat.ui.message_provenance
    local first, last
    if provenance and provenance.rows then
      first, last = provenance:rows({ call_id = id, phase = "result", all_fragments = true })
    end
    if first then anchor(state, first, last + 1) end
  end
  local meta = vim.tbl_extend("force", {}, message._meta or {}, { content = message.content })
  local first = clear_range(state, true)
  local batch_id = meta.presentation and meta.presentation.batch_call_id
  if batch_id and not state.parent then
    local parent_message = find_result(chat, batch_id)
    local invocation = parent_message and parent_message._meta and parent_message._meta.presentation
      and parent_message._meta.presentation.invocation
    if invocation then
      refresh_native_snapshot(invocation, chat.messages)
      return M.refresh_tool_summary_line(chat, batch_id)
    end
  end
  if M.is_ttl_cleaned(meta) then
    if meta.presentation then meta.presentation.result.blocks = {}; meta.presentation.request = nil; meta.presentation.invocation = nil end
    state.final, state.shown, state.request_view, state.saved_continuation = nil, nil, nil, nil
    for _, member in pairs(state.members or {}) do
      member.final, member.shown, member.request_view, member.saved_continuation = nil, nil, nil, nil
    end
    -- Provenance follows redraws; remove only this result's rendered fragments.
    local origins = chat.ui and chat.ui.message_provenance
    if origins and origins.remove_call then origins:remove_call(id, "result"); origins:remove_call(id, "request") end
  end
  if state.parent and state.parent.name == "multicall" then
    state.meta = meta
    sync_native_parent(state)
    local parent = state.parent
    redraw(parent)
    return true
  end
  local parts = meta.presentation and meta.presentation.invocation
    and invocation_parts(meta.presentation.invocation, source(state, "result"))
    or fragments(state.name, state.args, view_for(state.name, state.args, meta), meta, source(state, "result"))
  render_fragments(state, parts, first)
  return true
end

function M.rebuild_tool_summaries(messages)
  local calls, out = {}, {}
  for _, message in ipairs(messages or {}) do
    if message.tools and message.tools.calls then
      for _, call in ipairs(message.tools.calls) do calls[call.call_id or call.id] = call end
      -- Canonical tool calls remain hidden; their render-only fragments follow results.
      message.opts = message.opts or {}
      message.opts.visible = type(message.content) == "string" and message.content ~= ""
      out[#out + 1] = message
    elseif message.role == "tool" then
      local id = message.tools and message.tools.call_id
      local call = calls[id]
      message.opts = message.opts or {}; message.opts.visible = false
      out[#out + 1] = message
      if call and call["function"] and not (message._meta and message._meta.presentation and message._meta.presentation.batch_call_id) then
        local fn, meta = call["function"], vim.tbl_extend("force", {}, message._meta or {}, { content = message.content })
        local args = M.parse_args(fn)
        local request = not M.is_ttl_cleaned(meta) and meta.presentation and meta.presentation.request
        if not request and not meta.presentation and fn.name == "ask" then
          request = presentation.builtin(fn.name, args)
        end
        local parts = {}
        if request then vim.list_extend(parts, fragments(fn.name, args, request, nil, { call_id = id, phase = "request" })) end
        if not M.is_ttl_cleaned(meta) and meta.presentation and meta.presentation.invocation then
          refresh_native_snapshot(meta.presentation.invocation, messages)
          vim.list_extend(parts, invocation_parts(meta.presentation.invocation, { call_id = id, phase = "result" }))
        else vim.list_extend(parts, fragments(fn.name, args, view_for(fn.name, args, meta), meta,
          { call_id = id, phase = "result", related_chat_id = meta.presentation and meta.presentation.related_chat_id })) end
        for _, part in ipairs(parts) do
          out[#out + 1] = { role = part.role == "user" and "user" or "llm", content = part.content,
            opts = { visible = true, force_role = part.role ~= nil, _presentation_display = true, _display_origin = part.origin },
            _meta = { _presentation_fold = part.fold, _presentation_fold_spans = part.fold_spans,
              _presentation_summary = part.summary or part.fold ~= nil, _presentation_right = part.right } }
        end
      end
    else
      local previous = out[#out]
      if message.role == "user" and message.content == "" and previous and previous.role == "user"
        and previous.opts and previous.opts._presentation_display then
        message.opts = message.opts or {}; message.opts.force_role = true
      end
      out[#out + 1] = message
    end
  end
  for index = #messages, 1, -1 do messages[index] = nil end
  vim.list_extend(messages, out)
  return messages
end
function M.build_render_messages(messages)
  local copy = vim.deepcopy(messages or {})
  for index, message in ipairs(copy) do
    message.opts = message.opts or {}
    message.opts._display_origin = (messages[index].opts and messages[index].opts._display_origin) or messages[index]
  end
  return M.rebuild_tool_summaries(copy)
end
function M.apply_render_postprocess(chat, messages)
  if not valid(chat) then return end
  -- Full-buffer replacement moves old anchors to unrelated boundaries. Keep
  -- invocation state, but rebuild all layout anchors from the new rendering.
  local active = {}
  for _, state in pairs(states[chat.bufnr] or {}) do
    forget_marks(state)
    state.right_mark, state.display_failed, state.rendering = nil, nil, nil
    if not state.terminal and not state.parent then active[#active + 1] = state end
  end
  api.nvim_buf_clear_namespace(chat.bufnr, NS, 0, -1)
  M.highlight_summary_lines(chat.bufnr)
  api.nvim_buf_clear_namespace(chat.bufnr, RIGHT_NS, 0, -1)
  local provenance = chat.ui and chat.ui.message_provenance
  if not provenance or not provenance.rows then return end
  for _, message in ipairs(messages or {}) do
    local origin = message.opts and message.opts._display_origin
    local meta = message._meta or {}
    if origin and origin.call_id then
      local first, last = provenance:rows(origin)
      if first and meta._presentation_right then decorate(chat.bufnr, first, meta._presentation_right) end
      if first and meta._presentation_summary then
        local handle = M.create_ui(chat, origin.call_id, "unknown", {})
        local state = handle._state
        state.terminal = true
        for _, msg in ipairs(chat.messages or {}) do
          for _, call in ipairs(msg.tools and msg.tools.calls or {}) do
            if (call.call_id or call.id) == origin.call_id then
              state.name, state.args = call["function"].name, M.parse_args(call["function"])
            end
          end
        end
        if not state.summary_mark then
          state.summary_mark = api.nvim_buf_set_extmark(chat.bufnr, NS, first, 0, { right_gravity = true })
        end
        local call_first, call_last = provenance:rows({ call_id = origin.call_id, phase = origin.phase, all_fragments = true })
        anchor(state, call_first, call_last + 1)
        local fold = meta._presentation_fold
        if fold and chat.ui.folds then
          chat.ui.folds:create_tool_fold(chat.bufnr, first, last, fold.title, { collapsed = fold.collapsed })
        end
      end
      -- Match live rendering: register this fragment's own fold before the
      -- containing invocation spans ending here, then apply outer policy last.
      for _, span in ipairs(meta._presentation_fold_spans or {}) do
        local span_first = provenance:rows({ call_id = span.first_call_id or origin.call_id, phase = origin.phase, fragment = span.first })
        if span_first and last and chat.ui.folds then
          chat.ui.folds:create_tool_fold(chat.bufnr, span_first, last, span.title, { collapsed = span.collapsed })
          if span.first_call_id and span.first_call_id ~= origin.call_id then
            local outer = M.create_ui(chat, span.first_call_id, "unknown", {})._state
            anchor(outer, span_first, last + 1)
          end
        end
      end
    end
  end
  -- In-flight invocations have no canonical result yet, so history cannot
  -- reconstruct them. Restore their live views without completing the tools.
  table.sort(active, function(a, b) return a.order < b.order end)
  for _, state in ipairs(active) do
    display_update(state, function() redraw(state) end)
  end
end
return M
