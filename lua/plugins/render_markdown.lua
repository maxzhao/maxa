local function reveal_source()
  local mouse = vim.fn.getmousepos()
  if mouse.winid == 0 then
    return "<LeftMouse>"
  end

  local ui = package.loaded["render-markdown.core.ui"]
  if not ui then
    return "<LeftMouse>"
  end
  local buf = vim.api.nvim_win_get_buf(mouse.winid)
  local blocks, previews = {}, {}
  for _, extmark in ipairs(ui.get(buf):get()) do
    if extmark.id then
      local mark = extmark:get()
      if mark.replace then
        blocks[#blocks + 1] = mark
      elseif mark.conceal == true and mark.opts.virt_lines then
        previews[#previews + 1] = mark
      end
    end
  end
  local function by_row(a, b)
    return a.start_row < b.start_row
  end
  table.sort(blocks, by_row)
  table.sort(previews, by_row)

  local index = 1
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, preview in ipairs(previews) do
    local position = vim.fn.screenpos(mouse.winid, math.min(preview.start_row + 1, line_count), 1)
    local row = position.row
    if preview.start_row < line_count then
      row = row - #preview.opts.virt_lines
    end
    while blocks[index] and blocks[index].start_row < preview.start_row do
      local block = blocks[index]
      local height = #block.replace
      if position.row > 0 and mouse.screenrow >= row and mouse.screenrow < row + height then
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(mouse.winid) and vim.api.nvim_win_get_buf(mouse.winid) == buf then
            vim.api.nvim_set_current_win(mouse.winid)
            vim.api.nvim_win_set_cursor(mouse.winid, { block.start_row + 1, block.start_col })
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
          end
        end)
        return "<LeftMouse>"
      end
      row = row + height
      index = index + 1
    end
  end
  return "<LeftMouse>"
end

local function setup_source_click(buf)
  vim.api.nvim_buf_call(buf, function()
    -- Preserve user mappings; regular clicks retain Neovim's native behavior.
    local mapping = vim.fn.maparg("<LeftMouse>", "n", false, true)
    if vim.tbl_isempty(mapping) or mapping.desc == "Reveal rendered Markdown source" then
      vim.keymap.set("n", "<LeftMouse>", reveal_source, {
        buffer = buf,
        expr = true,
        desc = "Reveal rendered Markdown source",
      })
    end
  end)
end

local function replace_latex(ctx, marks, nodes)
  if vim.bo[ctx.buf].filetype ~= "maxa_ai" or vim.fn.has("nvim-0.11") == 0 then
    return marks
  end

  local config = require("render-markdown.request.context").get(ctx.buf).config
  local blocks = {}

  for _, node in ipairs(nodes) do
    if node.end_row > node.start_row then
      local first = vim.api.nvim_buf_get_lines(ctx.buf, node.start_row, node.start_row + 1, false)[1] or ""
      local last = vim.api.nvim_buf_get_lines(ctx.buf, node.end_row, node.end_row + 1, false)[1] or ""
      -- Never hide surrounding prose on a partially occupied formula line.
      if first:sub(1, node.start_col):match("^%s*$") and last:sub(node.end_col + 1):match("^%s*$") then
        local row = config.latex.position == "below" and node.end_row or node.start_row
        blocks[row] = node
      end
    end
  end

  local result = {}
  for _, mark in ipairs(marks) do
    local node = blocks[mark.start_row]
    if node and mark.opts.virt_lines then
      local lines = mark.opts.virt_lines
      local text = {}
      for _, line in ipairs(lines) do
        local chunks = {}
        for _, chunk in ipairs(line) do
          chunks[#chunks + 1] = chunk[1]
        end
        local value = vim.trim(table.concat(chunks))
        if value ~= "" then
          text[#text + 1] = value
        end
      end
      -- The builtin converter uses this sentinel on failure; leave its source visible.
      if #text > 0 and table.concat(text, "\n") ~= "error" then
        -- Native replacements keep the preview tied to the complete source
        -- range, so anti-conceal can reveal the whole formula under the cursor.
        result[#result + 1] = {
          modes = mark.modes,
          conceal = true,
          start_row = node.start_row,
          start_col = node.start_col,
          opts = {
            end_row = node.end_row,
            end_col = node.end_col,
            conceal_lines = "",
          },
          replace = lines,
        }
      else
        result[#result + 1] = mark
      end
    else
      result[#result + 1] = mark
    end
  end

  return result
end

local function render_latex(ctx)
  local marks = require("render-markdown.handler.latex").parse(ctx)
  if not ctx.last then
    return marks
  end
  return replace_latex(ctx, marks, require("render-markdown.request.context").get(ctx.buf).latex:get())
end

local latex_cache = {}

local function convert_latex(input, commands)
  for _, command in ipairs(commands) do
    local key = command .. "\n" .. input
    if latex_cache[key] == nil then
      local ok, output = pcall(function()
        return vim.system({ command }, { stdin = input, text = true, timeout = 2000 }):wait()
      end)
      latex_cache[key] = ok and output.code == 0 and output.stdout or false
    end
    if latex_cache[key] and vim.trim(latex_cache[key]) ~= "" then
      return vim.split(latex_cache[key]:gsub("\n$", ""), "\n", { plain = true })
    end
  end
end

local function backslash_latex(ctx, config)
  local parser = vim.treesitter.get_parser(ctx.buf, "markdown")
  local row, col = ctx.root:range()
  -- A fenced Markdown example can itself have injected inline trees.
  -- Inspect the outer tree so examples remain source, not math previews.
  local outer = parser:trees()[1]:root():named_descendant_for_range(row, col, row, col)
  while outer do
    if outer:type() == "fenced_code_block" or outer:type() == "indented_code_block" then
      return {}
    end
    outer = outer:parent()
  end

  local query = require("render-markdown.core.ts").parse(
    "markdown_inline",
    [[
    (backslash_escape) @delimiter
    [(code_span) (latex_block)] @boundary
  ]]
  )
  local nodes, opening, closing = {}, nil, nil
  for id, token in query:iter_captures(ctx.root, ctx.buf) do
    local text = vim.treesitter.get_node_text(token, ctx.buf)
    if query.captures[id] == "boundary" then
      opening, closing = nil, nil
    elseif text == "\\(" or text == "\\[" then
      opening = token
      closing = text == "\\(" and "\\)" or "\\]"
    elseif opening and text == closing then
      local inline = closing == "\\)"
      if (inline and config.inline) or (not inline and config.block) then
        local node = require("render-markdown.lib.node").new(ctx.buf, opening)
        local _, _, end_row, end_col = token:range()
        node.end_row, node.end_col = end_row, end_col
        node.text =
          table.concat(vim.api.nvim_buf_get_text(ctx.buf, node.start_row, node.start_col, end_row, end_col, {}), "\n")
        node.input = vim.trim(node.text:sub(3, -3))
        if node.input ~= "" then
          nodes[#nodes + 1] = node
        end
      end
      opening, closing = nil, nil
    end
  end
  return nodes
end

local function render_backslash_latex(ctx)
  local context = require("render-markdown.request.context").get(ctx.buf)
  local config = context.config.latex
  local builtin = require("render-markdown.handler.markdown_inline")
  if not config.enabled then
    return builtin.parse(ctx)
  end
  local commands = require("render-markdown.lib.env").commands(config.converter)
  if #commands == 0 then
    return builtin.parse(ctx)
  end

  local nodes, rows = {}, {}
  for _, node in ipairs(backslash_latex(ctx, config)) do
    local lines = convert_latex(node.input, commands)
    if lines then
      nodes[#nodes + 1] = node
      for _ = 1, config.top_pad do
        table.insert(lines, 1, "")
      end
      for _ = 1, config.bottom_pad do
        lines[#lines + 1] = ""
      end
      node.output = lines
      local row = config.position == "below" and node.end_row or node.start_row
      rows[row] = rows[row] or {}
      table.insert(rows[row], node)
    end
  end

  -- Do not decorate links/highlights that happen to occur inside a formula.
  local result = {}
  for _, mark in ipairs(builtin.parse(ctx)) do
    local inside = false
    for _, node in ipairs(nodes) do
      local after_start = mark.start_row > node.start_row
        or (mark.start_row == node.start_row and mark.start_col >= node.start_col)
      local before_end = mark.start_row < node.end_row
        or (mark.start_row == node.end_row and mark.start_col < node.end_col)
      inside = inside or (after_start and before_end)
    end
    if not inside then
      result[#result + 1] = mark
    end
  end

  local marks = require("render-markdown.lib.marks").new(context, true)
  for row, row_nodes in pairs(rows) do
    local above, below, current = {}, {}, 0
    for _, node in ipairs(row_nodes) do
      local lines, width = node.output, 0
      for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
      end
      for i, line in ipairs(lines) do
        lines[i] = line .. string.rep(" ", width - vim.fn.strdisplaywidth(line))
      end
      local position = config.position
      if position == "center" and node.end_row > node.start_row then
        position = "above"
      end
      local top, bottom = 0, 0
      if position == "center" then
        local center = math.floor(#lines / 2) + 1
        top, bottom = center - 1, #lines - center
        marks:over(config, "latex", node, {
          virt_text = { { lines[center], config.highlight } },
          virt_text_pos = "inline",
          conceal = "",
        })
      elseif position == "above" then
        top = #lines
      else
        bottom = #lines
      end
      local first = vim.api.nvim_buf_get_lines(ctx.buf, node.start_row, node.start_row + 1, false)[1] or ""
      local col = context:width({
        text = first:sub(1, node.start_col),
        start_row = node.start_row,
        start_col = 0,
        end_row = node.start_row,
        end_col = node.start_col,
      })
      local padding = string.rep(" ", math.max(col - current, current == 0 and 0 or 1))
      while #above < top do
        table.insert(above, 1, string.rep(" ", current))
      end
      while #below < bottom do
        below[#below + 1] = string.rep(" ", current)
      end
      for i, line in ipairs(above) do
        above[i] = line .. padding .. (lines[i - (#above - top)] or string.rep(" ", width))
      end
      for i, line in ipairs(below) do
        below[i] = line .. padding .. (lines[i + (#lines - bottom)] or string.rep(" ", width))
      end
      current = current + #padding + width
    end
    for _, part in ipairs({ { above, true }, { below, false } }) do
      if #part[1] > 0 then
        local lines = {}
        for _, line in ipairs(part[1]) do
          lines[#lines + 1] = { { line, config.highlight } }
        end
        marks:add(config, "virtual_lines", row, 0, { virt_lines = lines, virt_lines_above = part[2] })
      end
    end
  end
  vim.list_extend(result, replace_latex(ctx, marks:get(), nodes))
  return result
end

return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    init = function()
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("MaxaMarkdownSource", { clear = true }),
        pattern = "maxa_ai",
        callback = function(args)
          setup_source_click(args.buf)
        end,
      })
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "maxa_ai" then
          setup_source_click(buf)
        end
      end
    end,
    opts = {
      overrides = {
        filetype = {
          maxa_ai = {
            anti_conceal = {
              enabled = true,
              above = 0,
              below = 0,
              ignore = { virtual_lines = false },
            },
            win_options = {
              concealcursor = { rendered = "" },
            },
          },
        },
      },
      custom_handlers = {
        latex = { parse = render_latex },
        markdown_inline = { parse = render_backslash_latex },
      },
    },
  },
}
