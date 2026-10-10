-- Project-local runtime selections; no read/lookup creates governance files.
local M = {}
local yaml = require("maxa.utils.yaml")
local MEDIA = { image = true, tts = true, video = true }

function M.project_root(root)
  if type(root) ~= "string" or root == "" then return nil end
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  return root
end

function M.context_root(bufnr)
  local runtime = package.loaded["maxa"]
  local chat = runtime and runtime.buf_get_chat and runtime.buf_get_chat(bufnr)
  if chat then return M.project_root(chat.opts.project_root or chat.opts.cwd) end
  local name = bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr)
  local start = name and name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  return M.project_root(vim.fs.root(start, { ".maxa", ".git", ".svn", ".hg" }) or start)
end

local function identifier(name)
  return type(name) == "string" and #name > 0 and #name <= 64
    and name:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
    and not name:find("--", 1, true) and name:sub(-1) ~= "-"
end
local function mapping(value)
  return type(value) == "table" and (next(value) == nil or not vim.islist(value))
end

local function validate(data)
  if not mapping(data) then return nil, "project metadata must be a mapping" end
  local ai = data
  local adapter, model = ai.default_adapter, ai.default_model
  if (adapter == nil) ~= (model == nil) then return nil, "project default adapter/model override is incomplete" end
  for _, key in ipairs({ "default_adapter", "default_model", "soul" }) do
    local value = ai[key]
    if value ~= nil and (type(value) ~= "string" or vim.trim(value) == "") then
      return nil, "project " .. key .. " must be a nonblank string"
    end
  end
  local state = ai.abilities
  if state ~= nil then
    if not mapping(state) then return nil, "abilities must be a mapping" end
    for key in pairs(state) do
      if key ~= "enabled_suites" and key ~= "states" and key ~= "visibility" then return nil, "unknown abilities field: " .. tostring(key) end
    end
    local suites = state.enabled_suites
    if suites ~= nil then
      if type(suites) ~= "table" or not vim.islist(suites) then return nil, "enabled_suites must be a list" end
      local seen = {}
      for _, name in ipairs(suites) do
        if not identifier(name) or seen[name] then return nil, "invalid or duplicate suite identifier" end
        seen[name] = true
      end
    end
    if state.visibility ~= nil then
      if not mapping(state.visibility) then return nil, "abilities.visibility must be a mapping" end
      for name, value in pairs(state.visibility) do
        if not identifier(name) or (value ~= "global" and value ~= "search" and value ~= "hidden") then
          return nil, "abilities.visibility requires identifier/global|search|hidden entries"
        end
      end
    end
    if state.states ~= nil then
      if not mapping(state.states) then return nil, "abilities.states must be a mapping" end
      for name, enabled in pairs(state.states) do
        if not identifier(name) or type(enabled) ~= "boolean" then return nil, "abilities.states requires identifier/boolean entries" end
      end
    end
  end
  if ai.genai ~= nil then
    if not mapping(ai.genai) then return nil, "genai must be a mapping" end
    local defaults = ai.genai.default_adapters
    if defaults ~= nil then
      if not mapping(defaults) then return nil, "genai.default_adapters must be a mapping" end
      for medium, adapter in pairs(defaults) do
        if not MEDIA[medium] or type(adapter) ~= "string" or vim.trim(adapter) == "" then
          return nil, "genai.default_adapters requires image/tts/video adapter names"
        end
      end
    end
  end
  return true
end

-- Read-only compatibility view; only explicit writes migrate the old wrapper.
local function canonical(data)
  if not mapping(data) then return nil, "project metadata must be a mapping" end
  if data.maxa_ai == nil then return data end
  if not mapping(data.maxa_ai) then return nil, "legacy maxa_ai must be a mapping" end
  local result = vim.deepcopy(data)
  for key, value in pairs(data.maxa_ai) do
    if key == "maxa_ai" or result[key] ~= nil then return nil, "root/legacy project setting conflict: " .. key end
    result[key] = value
  end
  result.maxa_ai = nil
  return result
end

function M.read(root)
  root = M.project_root(root)
  if not root then return nil, "Maxa project root unavailable" end
  local path = vim.fs.joinpath(root, ".maxa", "_meta.yaml")
  local stat, stat_err, code = vim.uv.fs_stat(path)
  if not stat then
    if code == "ENOENT" then return { root = root, path = path, data = {}, missing = true } end
    return nil, "cannot inspect project metadata: " .. tostring(stat_err)
  end
  local file, err = io.open(path, "rb")
  if not file then return nil, "cannot read project metadata: " .. tostring(err) end
  local text = file:read("*a")
  file:close()
  local ok, data = pcall(yaml.decode_strict, text)
  if not ok then return nil, "invalid project metadata: " .. tostring(data) end
  local effective, canonical_err = canonical(data)
  if not effective then return nil, canonical_err end
  local valid, validation_err = validate(effective)
  if not valid then return nil, validation_err end
  return { root = root, path = path, data = effective, text = text, legacy = data.maxa_ai ~= nil }
end

function M.ability_enabled(root, name)
  local record, err = M.read(root)
  if not record then return nil, err end
  local ai = record.data
  local states = (ai.abilities or {}).states or {}
  return states[name] ~= false
end

function M.ability_visibility(root, name, default)
  local record, err = M.read(root)
  if not record then return nil, err end
  return ((record.data.abilities or {}).visibility or {})[name] or default
end

function M.check_ability(root, name)
  local enabled, err = M.ability_enabled(root, name)
  if not enabled then return nil, err or ("Ability '" .. name .. "' is disabled in this project") end
  return true
end

function M.media_adapter(root, medium)
  local record, err = M.read(root)
  if not record then return nil, err end
  local ai = record.data
  return ((ai.genai or {}).default_adapters or {})[medium]
end

-- Patch only the selected owned entry using YAML node ranges. Unrelated text,
-- including Soul literal blocks, comments and ordering, is not reserialized.
local function mapping_node(node)
  if node:type() == "block_mapping" or node:type() == "flow_mapping" then return node end
  for child in node:iter_children() do
    if child:named() and child:type() ~= "comment" then
      local found = mapping_node(child)
      if found then return found end
    end
  end
end
local function unwrap_mapping(node)
  while node and node:type() ~= "block_mapping" and node:type() ~= "flow_mapping" do
    local next_node
    for child in node:iter_children() do
      if child:named() and child:type() ~= "comment" then next_node = child; break end
    end
    node = next_node
  end
  return node
end
local function pair_value(pair)
  for index = 1, pair:named_child_count() - 1 do
    local node = pair:named_child(index)
    if node:type() ~= "comment" then return node end
  end
end
local function serialize(value, indent)
  if type(value) ~= "table" then return vim.json.encode(value) end
  if next(value) == nil then return "{}" end
  local lines, pad = {}, string.rep(" ", indent)
  if vim.islist(value) then
    for _, item in ipairs(value) do lines[#lines + 1] = pad .. "- " .. vim.json.encode(item) end
  else
    local keys = vim.tbl_keys(value)
    table.sort(keys)
    for _, key in ipairs(keys) do
      local item = value[key]
      if type(item) == "table" and next(item) ~= nil then
        lines[#lines + 1] = pad .. key .. ":\n" .. serialize(item, indent + 2)
      elseif key == "enabled_suites" and type(item) == "table" and next(item) == nil then
        lines[#lines + 1] = pad .. key .. ": []"
      else
        lines[#lines + 1] = pad .. key .. ": " .. serialize(item, indent + 2)
      end
    end
  end
  return table.concat(lines, "\n")
end
local function byte_offset(text, row, col)
  local at = 1
  for _ = 1, row do at = (text:find("\n", at, true) or #text) + 1 end
  return at + col
end
local function patch(record, path, value)
  local parser = vim.treesitter.get_string_parser(record.text, "yaml")
  local node = mapping_node(parser:parse()[1]:root())
  local parent_col
  local function replace(target, replacement)
    local row, col, last_row, last_col = target:range()
    local first, last = byte_offset(record.text, row, col), byte_offset(record.text, last_row, last_col)
    if last_col == 0 and last_row > row and replacement:sub(-1) ~= "\n" then replacement = replacement .. "\n" end
    return record.text:sub(1, first - 1) .. replacement .. record.text:sub(last)
  end
  for index, key in ipairs(path) do
    if not node then return nil, "project settings path is not a mapping" end
    local pair
    for child in node:iter_children() do
      if child:type() == "block_mapping_pair" or child:type() == "flow_pair" then
        local raw = vim.treesitter.get_node_text(child:named_child(0), record.text)
        if raw == key or raw == '"' .. key .. '"' or raw == "'" .. key .. "'" then pair = child; break end
      end
    end
    if pair and index < #path then
      local _, col = pair:start()
      parent_col = col
      node = unwrap_mapping(pair_value(pair))
    elseif pair then
      local target = pair_value(pair)
      if value ~= nil then return replace(target, vim.json.encode(value)) end
      if node:type() == "flow_mapping" then return nil, "clear requires a block mapping" end
      local entries = 0
      for child in node:iter_children() do
        if child:type() == "block_mapping_pair" then entries = entries + 1 end
      end
      if entries == 1 then
        local _, _, end_row, end_col = node:range()
        local suffix = record.text:sub(byte_offset(record.text, end_row, end_col))
        return replace(node, "{}" .. (end_col == 0 and suffix ~= "" and "\n" or ""))
      end
      local row = pair:start()
      local end_row, end_col = pair:end_()
      local first = byte_offset(record.text, row, 0)
      local last = byte_offset(record.text, end_row, end_col)
      local line_end = record.text:find("\n", last, true) or (#record.text + 1)
      -- Scalar trailing comments survive as standalone comments.
      local suffix = record.text:sub(last, line_end - 1)
      if end_col == 0 then suffix = ""; line_end = last - 1 end
      local _, col = pair:start()
      local comment = suffix:match("^%s*(#.*)$")
      local kept = comment and (string.rep(" ", col) .. comment .. "\n") or ""
      return record.text:sub(1, first - 1) .. kept .. record.text:sub(line_end + 1)
    else
      if value == nil then return record.text end
      local nested = value
      for tail = #path, index, -1 do nested = { [path[tail]] = nested } end
      if node:type() == "flow_mapping" then
        if node:named_child_count() ~= 0 then return nil, "adding settings requires a block or empty mapping" end
        return replace(node, parent_col and ("\n" .. serialize(nested, parent_col + 2)) or serialize(nested, 0))
      end
      local _, col = node:start()
      local row, end_col = node:end_()
      local at = byte_offset(record.text, row, end_col)
      if end_col ~= 0 then at = (record.text:find("\n", at, true) or #record.text) + 1 end
      local prefix = record.text:sub(1, at - 1)
      return prefix .. (prefix:sub(-1) == "\n" and "" or "\n")
        .. serialize(nested, col) .. "\n" .. record.text:sub(at)
    end
  end
end

-- Lift the legacy block verbatim, dedenting the same amount as its keys.
local function flatten(record)
  if not record.legacy then return record.text end
  local parser = vim.treesitter.get_string_parser(record.text, "yaml")
  local node = mapping_node(parser:parse()[1]:root())
  for pair in node:iter_children() do
    if pair:type() == "block_mapping_pair" then
      local key = vim.treesitter.get_node_text(pair:named_child(0), record.text)
      if key == "maxa_ai" or key == '"maxa_ai"' or key == "'maxa_ai'" then
        local row = pair:start()
        local end_row, end_col = pair:end_()
        local value = unwrap_mapping(pair_value(pair))
        local first = byte_offset(record.text, row, 0)
        local last = byte_offset(record.text, end_row, end_col)
        if not value then return nil, "legacy maxa_ai must be a mapping" end
        if value:type() == "flow_mapping" then
          local data = yaml.decode_strict(record.text).maxa_ai
          local body = next(data) and serialize(data, 0) or ""
          return record.text:sub(1, first - 1) .. body .. "\n" .. record.text:sub(last)
        end
        local _, indent = value:start()
        local header_end = record.text:find("\n", first, true)
        if not header_end then return nil, "legacy settings block has no body" end
        local body = record.text:sub(header_end + 1, last - 1)
        local lines = vim.split(body, "\n", { plain = true })
        for i, line in ipairs(lines) do
          if line:sub(1, indent) == string.rep(" ", indent) then lines[i] = line:sub(indent + 1) end
        end
        local comment = record.text:sub(first, header_end - 1):match("%s+(#.*)$")
        local prefix = comment and (comment .. "\n") or ""
        return record.text:sub(1, first - 1) .. prefix .. table.concat(lines, "\n") .. record.text:sub(last)
      end
    end
  end
  return nil, "legacy settings migration requires a block root mapping"
end

-- Each leaf edit reparses current text; one compare-and-rename publishes all edits.
function M.update_many(root, edits)
  local record, err = M.read(root)
  if not record then return nil, err end
  if record.missing then return nil, "Initialize the project's .maxa/_meta.yaml before changing settings" end
  local original = record.text
  local flat, flatten_err = flatten(record)
  if not flat then return nil, flatten_err end
  record.text = flat
  for _, edit in ipairs(edits) do
    local text, patch_err = patch(record, edit.path, edit.value)
    if not text then return nil, patch_err end
    local ok, data = pcall(yaml.decode_strict, text)
    if not ok then return nil, "cannot publish invalid metadata: " .. tostring(data) end
    record.text = text
  end
  local decoded_ok, data = pcall(yaml.decode_strict, record.text)
  if not decoded_ok then return nil, "cannot publish invalid metadata: " .. tostring(data) end
  local valid, validation_err = validate(data)
  if not valid then return nil, validation_err end
  local file = io.open(record.path, "rb")
  if not file then return nil, "project metadata became unavailable" end
  local current = file:read("*a"); file:close()
  if current ~= original then return nil, "project metadata changed; retry the edit" end
  local tmp = record.path .. ".tmp." .. tostring(vim.uv.hrtime())
  local out, write_err = io.open(tmp, "wb")
  if not out then return nil, write_err end
  local written, err_write = out:write(record.text); out:close()
  if not written then vim.uv.fs_unlink(tmp); return nil, err_write end
  local renamed, rename_err = vim.uv.fs_rename(tmp, record.path)
  if not renamed then vim.uv.fs_unlink(tmp); return nil, rename_err end
  vim.api.nvim_exec_autocmds("User", { pattern = "MaxaProjectSettingsChanged", modeline = false, data = { project_root = record.root } })
  return true
end
function M.update(root, path, value) return M.update_many(root, { { path = path, value = value } }) end
function M.migrate(root)
  local record, err = M.read(root)
  if not record then return nil, err end
  if not record.legacy then return true end
  return M.update_many(root, {})
end

function M.set_media(root, medium, adapter)
  if not MEDIA[medium] then return nil, "unsupported medium: " .. tostring(medium) end
  if adapter then
    local declared = require("maxa.mcphub.native_servers.genai.capability_registry").get(adapter)
    if not declared or not declared.capabilities[medium] then return nil, "adapter does not provide " .. medium end
  end
  return M.update(root, { "genai", "default_adapters", medium }, adapter)
end

function M.set_ability(root, name, enabled)
  return M.update(root, { "abilities", "states", name }, enabled)
end

function M.set_visibility(root, name, visibility)
  return M.update(root, { "abilities", "visibility", name }, visibility)
end

function M.reset_ability(root, name)
  return M.update_many(root, {
    { path = { "abilities", "states", name } },
    { path = { "abilities", "visibility", name } },
  })
end

function M.set_suite(root, suite, enabled, abilities)
  local record, err = M.read(root)
  if not record then return nil, err end
  local state = vim.deepcopy(record.data.abilities or {})
  state.states = state.states or {}
  state.enabled_suites = vim.tbl_filter(function(name) return name ~= suite end, state.enabled_suites or {})
  if enabled then state.enabled_suites[#state.enabled_suites + 1] = suite end
  table.sort(state.enabled_suites)
  local edits = {}
  for _, ability in ipairs(abilities) do
    if vim.tbl_contains(ability.suite or {}, suite) then
      local protected = false
      for _, other in ipairs(ability.suite or {}) do
        if vim.tbl_contains(state.enabled_suites, other) then protected = true end
      end
      if enabled or not protected then
        edits[#edits + 1] = { path = { "abilities", "states", ability.name }, value = enabled }
      end
    end
  end
  edits[#edits + 1] = { path = { "abilities", "enabled_suites" }, value = state.enabled_suites }
  return M.update_many(root, edits)
end
return M
