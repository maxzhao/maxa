-- Tree-sitter owns Markdown grammar; this module only selects destination bytes.
local M = {}

local function label(value)
  return value:gsub("^%[", ""):gsub("%]$", ""):gsub("%s+", " "):lower()
end

local function child(node, kind)
  for item in node:iter_children() do
    if item:type() == kind then return item end
  end
end

function M.destinations(text)
  if type(text) ~= "string" or not text:find("[", 1, true) then return {} end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown")
  if not ok then return {} end
  local parsed = pcall(parser.parse, parser, true)
  if not parsed then return {} end
  local destinations, definitions, used, excluded = {}, {}, {}, {}
  local function exclude_code(node)
    local kind = node:type()
    if kind == "fenced_code_block" or kind == "indented_code_block" then
      local _, _, first = node:start()
      local _, _, last = node:end_()
      excluded[#excluded + 1] = { first, last }
      return
    end
    for item in node:iter_children() do exclude_code(item) end
  end
  for _, tree in ipairs(parser:trees()) do exclude_code(tree:root()) end
  local function destination(node)
    local raw = vim.treesitter.get_node_text(node, text)
    local _, _, first = node:start()
    local _, _, last = node:end_()
    if raw:sub(1, 1) == "<" and raw:sub(-1) == ">" then
      first, last, raw = first + 1, last - 1, raw:sub(2, -2)
    end
    return { first = first, last = last, target = raw }
  end
  local function walk(node)
    local _, _, first = node:start()
    for _, range in ipairs(excluded) do if first >= range[1] and first < range[2] then return end end
    local kind = node:type()
    -- Do not descend into code, including injected Markdown inside a fence.
    if kind == "fenced_code_block" or kind == "indented_code_block" or kind == "code_span" then return end
    if kind == "link_reference_definition" then
      local key, target = child(node, "link_label"), child(node, "link_destination")
      if key and target then
        local name = label(vim.treesitter.get_node_text(key, text))
        definitions[name] = definitions[name] or destination(target)
      end
      return
    end
    if kind == "inline_link" or kind == "image" then
      local target = child(node, "link_destination")
      if target then destinations[#destinations + 1] = destination(target)
      else
        local key = child(node, "link_label") or child(node, "image_description")
        if key then used[label(vim.treesitter.get_node_text(key, text))] = true end
      end
    elseif kind == "full_reference_link" or kind == "collapsed_reference_link" or kind == "shortcut_link" then
      local key = child(node, "link_label") or child(node, "link_text")
      if key then used[label(vim.treesitter.get_node_text(key, text))] = true end
    end
    for item in node:iter_children() do walk(item) end
  end
  parser:for_each_tree(function(tree, language)
    if language:lang() == "markdown" or language:lang() == "markdown_inline" then walk(tree:root()) end
  end)
  for key in pairs(used) do if definitions[key] then destinations[#destinations + 1] = definitions[key] end end
  table.sort(destinations, function(a, b) return a.first < b.first end)
  return destinations
end

function M.replace(text, destinations, urls)
  for index = #destinations, 1, -1 do
    local item = destinations[index]
    local url = urls[item.path]
    if url then text = text:sub(1, item.first) .. url .. (item.fragment or "") .. text:sub(item.last + 1) end
  end
  return text
end

return M
