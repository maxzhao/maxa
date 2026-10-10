-- Read-only cursor inspection; canonical history and execution stay untouched.
local M = {}
local api = vim.api
local json = require("maxa.mcphub.utils")

local function decode(value)
  if type(value) ~= "string" then
    return value, true
  end
  local ok, parsed = pcall(vim.json.decode, value)
  if ok then
    return parsed, true
  end
  return value, false
end

local function object(value)
  local parsed = decode(value)
  return type(parsed) == "table" and parsed ~= vim.NIL and parsed or nil
end

local function raw_text(value)
  if type(value) == "string" then
    return value
  end
  if value == nil then
    return ""
  end
  return vim.json.encode(value)
end

local function fence(text)
  local size = 3
  for run in text:gmatch("`+") do
    size = math.max(size, #run + 1)
  end
  return string.rep("`", size)
end

-- Decode only complete structured string values, never snippets or business fields.
local function structured_lines(value, foldable)
  local lines, folds = {}, {}
  local function append(label, item, depth)
    local nested = object(item)
    if nested then
      item = nested
    end
    local first = #lines + 1
    local indent = string.rep("  ", depth)
    local prefix = indent .. "- " .. (label and ("**" .. label .. "**: ") or "")
    if type(item) == "table" and item ~= vim.NIL and next(item) ~= nil then
      lines[#lines + 1] = prefix
      if vim.islist(item) then
        for i, child in ipairs(item) do
          append("[" .. i .. "]", child, depth + 1)
        end
      else
        local keys = vim.tbl_keys(item)
        table.sort(keys, function(a, b)
          return tostring(a) < tostring(b)
        end)
        for _, key in ipairs(keys) do
          append(tostring(key):gsub("([*_%[%]\\])", "\\%1"), item[key], depth + 1)
        end
      end
    else
      local text = item == vim.NIL and "null" or raw_text(item)
      if foldable or text:find("\n", 1, true) then
        lines[#lines + 1] = prefix
        local block = fence(text)
        lines[#lines + 1] = indent .. "  " .. block .. "text"
        for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
          lines[#lines + 1] = indent .. "  " .. line
        end
        lines[#lines + 1] = indent .. "  " .. block
      else
        local ticks = fence(text)
        lines[#lines + 1] = prefix .. ticks .. " " .. text .. " " .. ticks
      end
    end
    if foldable then
      local kind = item == vim.NIL and "null" or type(item)
      if kind == "table" then
        kind = vim.islist(item) and "array" or "object"
      end
      local count = vim.fn.strchars(raw_text(item))
      folds[#folds + 1] = {
        first = first,
        last = #lines,
        label = label or "input",
        kind = kind,
        chars = count,
        closed = count > 500,
      }
    end
  end
  local nested = object(value)
  if nested and next(nested) ~= nil then
    if vim.islist(nested) then
      for i, item in ipairs(nested) do
        append("[" .. i .. "]", item, 0)
      end
    else
      local keys = vim.tbl_keys(nested)
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      for _, key in ipairs(keys) do
        append(tostring(key):gsub("([*_%[%]\\])", "\\%1"), nested[key], 0)
      end
    end
  else
    append(nil, value, 0)
  end
  return lines, folds
end

local function output_lines(value, format)
  if format == "markdown" then
    local parsed, ok = decode(value)
    if type(parsed) == "table" and parsed ~= vim.NIL then
      return structured_lines(parsed)
    end
    if ok and type(parsed) == "string" then
      value = parsed
    end
  elseif format == "json" then
    local parsed = decode(value)
    return vim.split(json.pretty_json(vim.json.encode(parsed), { unescape_slashes = false }), "\n", { plain = true })
  end
  return vim.split(raw_text(value), "\n", { plain = true })
end

local function inspect(chat, message, origin)
  local id = origin and origin.call_id or message.tools and message.tools.call_id
  if not id then
    return { name = message.role or "Message", output = message.content or "" }
  end
  local call, result
  for _, candidate in ipairs(chat.messages or {}) do
    for _, invocation in ipairs(candidate.tools and candidate.tools.calls or {}) do
      if (invocation.call_id or invocation.id) == id then
        call = invocation
      end
    end
    if candidate.tools and candidate.tools.call_id == id then
      result = candidate
    end
  end
  if not call or not call["function"] then
    return nil, "Tool invocation is unavailable at the cursor"
  end
  local fn = call["function"]
  local input, output = fn.arguments or {}, result and result.content
  local name = fn.name or "Tool"
  return { name = name, input = input, output = output, unavailable = output == nil }
end

function M.fold_text()
  for _, fold in ipairs(vim.b.maxa_inspector_folds or {}) do
    if fold.first == vim.v.foldstart then
      local label = fold.label:gsub("\\([*_%[%]\\])", "%1")
      return string.format("▸ %s · %s · %d chars", label, fold.kind, fold.chars)
    end
  end
  return vim.fn.foldtext()
end

local function apply_folds(win, folds)
  if not win or not api.nvim_win_is_valid(win) then
    return
  end
  api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    vim.wo.foldmethod = "manual"
    vim.wo.foldenable = true
    vim.wo.foldminlines = 0
    vim.wo.foldtext = 'v:lua.require("maxa.interactions.chat.message_inspector").fold_text()'
    vim.b.maxa_inspector_folds = folds
    vim.cmd("normal! zE")
    for _, fold in ipairs(folds) do
      vim.cmd(string.format("%d,%dfold", fold.first, fold.last))
    end
    vim.cmd("normal! zR")
    for _, fold in ipairs(folds) do
      if fold.closed then
        vim.cmd(fold.first .. "foldclose")
      end
    end
    vim.fn.winrestview(view)
  end)
end

function M.open(chat)
  local cursor = api.nvim_win_get_cursor(0)
  local message, _, origin = chat.ui:message_at(cursor[1] - 1, cursor[2])
  if not message then
    return vim.notify("[Chat] No message under cursor to inspect", vim.log.levels.INFO)
  end
  local item, err = inspect(chat, message, origin)
  if not item then
    return vim.notify("[Chat] " .. err, vim.log.levels.INFO)
  end

  local snacks = require("snacks")
  local caller_win = api.nvim_get_current_win()
  local panes, buffers, closing, layout = {}, {}, false, nil
  local ratio, zoom, views = 0.5, nil, {}
  local input_lines, folds
  if item.input ~= nil then
    input_lines, folds = structured_lines(item.input, true)
  end
  local function close()
    if closing then
      return
    end
    closing = true
    if layout then
      layout:close()
    end
    for _, buf in ipairs(buffers) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_delete(buf, { force = true })
      end
    end
    if api.nvim_win_is_valid(caller_win) then
      api.nvim_set_current_win(caller_win)
    end
  end
  local function window(lines, title, footer)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "markdown"
    local win = snacks.win({
      show = false,
      buf = buf,
      title = title,
      title_pos = "center",
      border = "rounded",
      footer = footer,
      footer_pos = "center",
      backdrop = false,
      fixbuf = true,
      bo = {
        buftype = "nofile",
        bufhidden = "hide",
        swapfile = false,
        modifiable = false,
        readonly = true,
      },
      wo = { wrap = true, number = false, relativenumber = false, signcolumn = "no", statuscolumn = "" },
    })
    win:open_buf()
    buffers[#buffers + 1] = win.buf
    return win
  end
  if input_lines then
    panes.input = window(input_lines, " Input · " .. item.name .. " ", " za Value · zA All · + Zoom ")
  end
  local format = "markdown"
  panes.output = window(
    item.unavailable and { "No output available (pending or unavailable)." } or output_lines(item.output, format),
    " Output · " .. item.name .. " · Markdown ",
    " " .. vim.fn.keytrans(vim.g.maplocalleader or "\\") .. "m/t/j Format · C-h/C-l Panes · + Zoom · q Close "
  )
  local output = panes.output
  local formats = { markdown = output.buf }
  local map_buffer

  local function current_pane()
    return panes.input and api.nvim_get_current_win() == panes.input.win and "input" or "output"
  end
  local function remember_views()
    for name, pane in pairs(panes) do
      if pane:win_valid() then
        views[name] = api.nvim_win_call(pane.win, vim.fn.winsaveview)
      end
    end
  end
  local function update_layout(focus)
    remember_views()
    layout.opts.hidden = zoom and { zoom == "input" and "output" or "input" } or {}
    layout:update()
    if panes.input and panes.input:win_valid() then
      apply_folds(panes.input.win, folds)
    end
    for name, pane in pairs(panes) do
      if pane:win_valid() then
        map_buffer(pane.buf)
        if views[name] then
          api.nvim_win_call(pane.win, function()
            vim.fn.winrestview(views[name])
          end)
        end
      end
    end
    local pane = panes[focus]
    if pane and pane:win_valid() then
      api.nvim_set_current_win(pane.win)
    end
  end
  local function toggle_zoom()
    if not panes.input then
      return
    end
    local focus = current_pane()
    if zoom then
      zoom = nil
    else
      zoom = focus
    end
    update_layout(focus)
  end
  local function resize(delta)
    if not panes.input or zoom then
      return
    end
    local focus = current_pane()
    local total = math.max(2, api.nvim_win_get_width(layout.root.win) - 4)
    local minimum = math.min(20, math.floor(total / 2))
    local width = math.floor(total * ratio) + delta * (focus == "input" and 1 or -1) * vim.v.count1
    ratio = math.max(minimum, math.min(total - minimum, width)) / total
    update_layout(focus)
  end
  local function fold_all(closed)
    if not panes.input or not panes.input:win_valid() then
      return
    end
    for _, fold in ipairs(folds) do
      fold.closed = closed
    end
    apply_folds(panes.input.win, folds)
  end
  local function toggle_value()
    local row = api.nvim_win_get_cursor(0)[1]
    local target
    for _, fold in ipairs(folds) do
      if row >= fold.first and row <= fold.last and (not target or fold.first >= target.first) then
        target = fold
      end
    end
    if target then
      target.closed = not target.closed
      apply_folds(panes.input.win, folds)
    end
  end
  local function set_format(next_format)
    local buf = formats[next_format]
    if not buf then
      buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        item.unavailable and { "No output available (pending or unavailable)." }
          or output_lines(item.output, next_format)
      )
      vim.bo[buf].filetype = next_format
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].swapfile = false
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true
      formats[next_format] = buf
      buffers[#buffers + 1] = buf
      map_buffer(buf)
    end
    format = next_format
    output.opts.title = " Output · " .. item.name .. " · " .. format .. " "
    layout.win_opts.output.title = output.opts.title
    if output:win_valid() then
      output:set_buf(buf)
      output:set_title(output.opts.title)
    else
      output.buf = buf
    end
  end
  map_buffer = function(buf)
    local function map(key, fn, desc)
      vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
    end
    map("q", close, "Close message inspector")
    map("<Esc>", close, "Close message inspector")
    map("+", toggle_zoom, "Toggle pane zoom")
    map("<C-w><", function()
      resize(-4)
    end, "Shrink inspector pane")
    map("<C-w>>", function()
      resize(4)
    end, "Grow inspector pane")
    for key, next_format in pairs({ m = "markdown", t = "text", j = "json" }) do
      map("<localleader>" .. key, function()
        set_format(next_format)
      end, "Output format: " .. next_format)
    end
    local function focus_pane(target)
      if not panes[target] or current_pane() == target then
        return
      end
      if zoom then
        zoom = target
        update_layout(target)
      elseif panes[target]:win_valid() then
        api.nvim_set_current_win(panes[target].win)
      end
    end
    map("<C-h>", function()
      focus_pane("input")
    end, "Focus inspector input")
    map("<C-l>", function()
      focus_pane("output")
    end, "Focus inspector output")
    if panes.input then
      if buf == panes.input.buf then
        map("za", toggle_value, "Toggle current input value")
        map("zA", function()
          for _, fold in ipairs(folds) do
            if fold.closed then
              return fold_all(false)
            end
          end
          fold_all(true)
        end, "Toggle all input values")
        map("zM", function()
          fold_all(true)
        end, "Fold all input values")
        map("zR", function()
          fold_all(false)
        end, "Expand all input values")
      end
    end
  end
  local box = { box = "horizontal", width = 0.82, height = 0.82, border = "none" }
  if panes.input then
    box[#box + 1] = {
      win = "input",
      width = function()
        return zoom and 0 or ratio
      end,
    }
  end
  box[#box + 1] = { win = "output" }
  layout = snacks.layout.new({ show = false, wins = panes, layout = box, on_close = close })
  for _, pane in pairs(panes) do
    map_buffer(pane.buf)
  end
  update_layout("output")
  return output
end

return M
