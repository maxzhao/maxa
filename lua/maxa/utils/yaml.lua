local M = {}

local islist = vim.islist or vim.tbl_islist

---@param data any
---@return string
M.encode = function(data)
  local dt = type(data)
  if data == nil then
    return "null"
  elseif dt == "number" then
    if data % 1 == 0 then
      return string.format("%d", data)
    else
      return string.format("%.1f", data)
    end
  elseif dt == "boolean" then
    return string.format("%s", data)
  elseif dt == "string" then
    if data == "yes" or data == "no" or data == "true" or data == "false" or data == "on" or data == "off" then
      return string.format('"%s"', data)
    else
      return data
    end
  elseif dt == "table" then
    local lines = {}
    if islist(data) then
      if vim.tbl_isempty(data) then
        return "[]"
      else
        for _, v in ipairs(data) do
          table.insert(lines, string.format("- %s", M.encode(v)))
        end
      end
    else
      if vim.tbl_isempty(data) then
        return "{}"
      else
        for k, v in pairs(data) do
          table.insert(lines, string.format("%s: %s", k, M.encode(v)))
        end
      end
    end
    return table.concat(lines, "\n")
  else
    error(string.format("Cannot encode type '%s' to yaml", dt))
  end
end

local decode_block_scalar

---Decode a yaml node
---@param source string
---@param node TSNode
---@return any
local function decode(source, node)
  local ok, nt = pcall(function()
    return node:type()
  end)
  if not ok then
    return {}
  end

  if nt == "stream" or nt == "document" or nt == "block_node" or nt == "flow_node" or nt == "plain_scalar" then
    for child in node:iter_children() do
      if child:named() then
        return decode(source, child)
      end
    end
  elseif nt == "block_mapping" then
    local result = {}
    for child in node:iter_children() do
      if child:type() == "comment" then
        goto continue
      end
      assert(child:type() == "block_mapping_pair")
      local key = decode(source, child:named_child(0))
      if not key then
        error("Could not decode map key")
      end
      result[key] = decode(source, child:named_child(1))
      ::continue::
    end
    -- Provide a way to get the TSNode for a map
    return setmetatable(result, {
      __index = {
        __ts_node = node,
      },
    })
  elseif nt == "flow_sequence" or nt == "block_sequence" then
    local ret = {}
    for child in node:iter_children() do
      if child:named() then
        table.insert(ret, decode(source, child))
      end
    end
    return ret
  elseif nt == "block_sequence_item" then
    for child in node:iter_children() do
      if child:named() then
        return decode(source, child)
      end
    end
    return nil
  elseif nt == "block_scalar" then
    return decode_block_scalar(source, node)
  elseif nt == "string_scalar" then
    return vim.treesitter.get_node_text(node, source)
  elseif nt == "single_quote_scalar" or nt == "double_quote_scalar" then
    local text = vim.treesitter.get_node_text(node, source)
    return text:sub(2, text:len() - 1)
  elseif nt == "integer_scalar" or nt == "float_scalar" then
    return tonumber(vim.treesitter.get_node_text(node, source))
  elseif nt == "boolean_scalar" then
    local text = vim.treesitter.get_node_text(node, source)
    if text == "true" then
      return true
    elseif text == "false" then
      return false
    else
      error("Invalid boolean scalar")
    end
  elseif nt == "null_scalar" then
    return nil
  elseif nt == "ERROR" then
    -- TODO should probably annotate this and pass it up somehow
    return nil
  else
    error(string.format("Unknown yaml node type '%s'", nt))
  end
end

local function strict_location(node)
  local row, column = node:start()
  return string.format("line %d, column %d", row + 1, column + 1)
end

local function strict_error(node, message)
  error(string.format("YAML %s: %s", strict_location(node), message), 0)
end

decode_block_scalar = function(source, node)
  local text = vim.treesitter.get_node_text(node, source):gsub("\r\n", "\n")
  local header, body = text:match("^([^\n]*)\n?(.*)$")
  local style = header and header:match("^%s*([|>])")
  if not style then
    strict_error(node, "invalid block scalar header")
  end
  if style ~= "|" then
    strict_error(node, "folded block scalars are not supported; use literal style |")
  end

  local lines = vim.split(body or "", "\n", { plain = true })
  local indent
  for _, line in ipairs(lines) do
    if line:match("%S") then
      local current = #(line:match("^(%s*)") or "")
      indent = indent and math.min(indent, current) or current
    end
  end
  indent = indent or 0

  local values = {}
  for index, line in ipairs(lines) do
    values[index] = line:sub(math.min(#line, indent) + 1)
  end

  local result = table.concat(values, "\n")
  local chomping = header:match("[+-]")
  if chomping == "-" then
    result = result:gsub("\n+$", "")
  elseif chomping ~= "+" then
    result = result:gsub("\n+$", "") .. "\n"
  end
  return result
end

local function unicode_char(codepoint)
  if utf8 and utf8.char then
    return utf8.char(codepoint)
  end
  return vim.fn.nr2char(codepoint)
end

local DOUBLE_QUOTE_ESCAPES = {
  ["0"] = "\0",
  a = "\a",
  b = "\b",
  t = "\t",
  n = "\n",
  v = "\v",
  f = "\f",
  r = "\r",
  e = string.char(27),
  [" "] = " ",
  ['"'] = '"',
  ["/"] = "/",
  ["\\"] = "\\",
  N = unicode_char(0x85),
  ["_"] = unicode_char(0xA0),
  L = unicode_char(0x2028),
  P = unicode_char(0x2029),
}

local function decode_double_quoted(node, text)
  local inner = text:sub(2, -2)
  local result = {}
  local index = 1
  while index <= #inner do
    local char = inner:sub(index, index)
    if char ~= "\\" then
      result[#result + 1] = char
      index = index + 1
    else
      local escaped = inner:sub(index + 1, index + 1)
      if escaped == "" then
        strict_error(node, "unterminated escape in double-quoted scalar")
      end
      if escaped == "\n" then
        index = index + 2
        while inner:sub(index, index):match("[ \\t]") do
          index = index + 1
        end
      elseif escaped == "x" or escaped == "u" or escaped == "U" then
        local digits = escaped == "x" and 2 or (escaped == "u" and 4 or 8)
        local value = inner:sub(index + 2, index + 1 + digits)
        if #value ~= digits or not value:match("^[0-9a-fA-F]+$") then
          strict_error(node, "invalid Unicode escape in double-quoted scalar")
        end
        local codepoint = tonumber(value, 16)
        local ok, decoded = pcall(unicode_char, codepoint)
        if not ok then
          strict_error(node, "invalid Unicode codepoint in double-quoted scalar")
        end
        result[#result + 1] = decoded
        index = index + digits + 2
      else
        local decoded = DOUBLE_QUOTE_ESCAPES[escaped]
        if decoded == nil then
          strict_error(node, "unsupported escape \\" .. escaped .. " in double-quoted scalar")
        end
        result[#result + 1] = decoded
        index = index + 2
      end
    end
  end
  return table.concat(result)
end

local function strict_decode(source, node)
  local nt = node:type()
  if nt == "ERROR" then
    strict_error(node, "syntax error")
  elseif nt == "anchor" or nt == "alias" or nt == "tag" then
    strict_error(node, nt .. " is not supported")
  elseif nt == "stream" then
    local documents = {}
    for child in node:iter_children() do
      if child:named() and child:type() ~= "comment" then
        if child:type() ~= "document" then
          strict_error(child, "unsupported top-level construct " .. child:type())
        end
        documents[#documents + 1] = child
      end
    end
    if #documents ~= 1 then
      strict_error(node, "expected exactly one document")
    end
    return strict_decode(source, documents[1])
  elseif nt == "document" or nt == "block_node" or nt == "plain_scalar" then
    local value_node = nil
    for child in node:iter_children() do
      if child:named() and child:type() ~= "comment" then
        if value_node then
          strict_error(child, "unsupported additional construct " .. child:type())
        end
        value_node = child
      end
    end
    if not value_node then
      strict_error(node, "empty value is not supported")
    end
    return strict_decode(source, value_node)
  elseif nt == "flow_node" then
    local value_node = nil
    for child in node:iter_children() do
      if child:named() and child:type() ~= "comment" then
        local child_type = child:type()
        if child_type == "anchor" or child_type == "alias" or child_type == "tag" then
          strict_error(child, child_type .. " is not supported")
        end
        if value_node then
          strict_error(child, "unsupported decorated value")
        end
        value_node = child
      end
    end
    if not value_node then
      strict_error(node, "empty value is not supported")
    end
    return strict_decode(source, value_node)
  elseif nt == "block_mapping" or nt == "flow_mapping" then
    local result = {}
    for child in node:iter_children() do
      if child:type() ~= "comment" and child:named() then
        if child:type() ~= "block_mapping_pair" and child:type() ~= "flow_pair" then
          strict_error(child, "unsupported mapping construct " .. child:type())
        end
        local key_node = child:named_child(0)
        local value_node
        for index = 1, child:named_child_count() - 1 do
          local candidate = child:named_child(index)
          if candidate:type() ~= "comment" then value_node = candidate; break end
        end
        if not key_node or not value_node then
          strict_error(child, "mapping keys require explicit values")
        end
        local key = strict_decode(source, key_node)
        if type(key) ~= "string" or key == "" then
          strict_error(key_node, "mapping keys must be nonblank strings")
        end
        if key == "<<" then
          strict_error(key_node, "merge keys are not supported")
        end
        if rawget(result, key) ~= nil then
          strict_error(key_node, "duplicate mapping key " .. key)
        end
        result[key] = strict_decode(source, value_node)
      end
    end
    return result
  elseif nt == "flow_sequence" or nt == "block_sequence" then
    local result = {}
    for child in node:iter_children() do
      if child:named() and child:type() ~= "comment" then
        result[#result + 1] = strict_decode(source, child)
      end
    end
    return result
  elseif nt == "block_sequence_item" then
    local value_node = nil
    for child in node:iter_children() do
      if child:named() and child:type() ~= "comment" then
        if value_node then
          strict_error(child, "sequence item contains multiple values")
        end
        value_node = child
      end
    end
    if not value_node then
      strict_error(node, "null sequence entries are not supported")
    end
    return strict_decode(source, value_node)
  elseif nt == "string_scalar" then
    return vim.treesitter.get_node_text(node, source)
  elseif nt == "block_scalar" then
    return decode_block_scalar(source, node)
  elseif nt == "single_quote_scalar" then
    local text = vim.treesitter.get_node_text(node, source)
    return text:sub(2, -2):gsub("''", "'")
  elseif nt == "double_quote_scalar" then
    return decode_double_quoted(node, vim.treesitter.get_node_text(node, source))
  elseif nt == "integer_scalar" or nt == "float_scalar" then
    local value = vim.treesitter.get_node_text(node, source):gsub("_", "")
    local number = tonumber(value)
    if number == nil then
      strict_error(node, "invalid numeric scalar")
    end
    return number
  elseif nt == "boolean_scalar" then
    local text = vim.treesitter.get_node_text(node, source)
    if text == "true" then
      return true
    elseif text == "false" then
      return false
    end
    strict_error(node, "invalid boolean scalar")
  elseif nt == "null_scalar" then
    return vim.NIL
  end
  strict_error(node, "unsupported construct " .. nt)
end

---@param source string|integer
---@param node TSNode
---@return any
M.decode_node = function(source, node)
  return decode(source, node)
end

---Decode one YAML mapping document without discarding syntax needed by strict schemas.
---Null scalars are preserved as vim.NIL so schema validators can reject them.
---@param str string
---@return any
M.decode_strict = function(str)
  local ok, parser = pcall(vim.treesitter.get_string_parser, str, "yaml", { injections = { yaml = "" } })
  if not ok then
    error("YAML parser unavailable: " .. tostring(parser), 0)
  end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then
    error("YAML parse produced no document", 0)
  end
  return strict_decode(str, root)
end

---@param str string
---@return any
M.decode = function(str)
  local lang_tree = vim.treesitter.get_string_parser(str, "yaml", { injections = { yaml = "" } })
  local root = lang_tree:parse()[1]:root()
  return decode(str, root)
end

return M
