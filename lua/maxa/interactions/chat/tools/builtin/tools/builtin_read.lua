local param_utils = require("maxa.mcphub.native_servers.shared.params")
local utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")

local MAX_RETURN_CHARS = 20000
local TMP_PREFIX = "/tmp/"

local function valid_line(value)
  return type(value) == "number" and value == math.floor(value)
end

local function validate_request(params)
  local policy = params.result_policy or "auto"
  if not ({ auto = true, temporary = true, keep = true, persist = true })[policy] then
    return nil, "Invalid result_policy. Expected one of: auto, temporary, keep, persist"
  end
  if params.force == true then
    return nil, "force=true is no longer supported; use next_cursor to continue reading"
  end
  if params.start_line ~= nil and (not valid_line(params.start_line) or params.start_line < 1) then
    return nil, "start_line must be a positive integer"
  end
  if params.end_line ~= nil and (not valid_line(params.end_line) or (params.end_line ~= -1 and params.end_line < 1)) then
    return nil, "end_line must be a positive inclusive line number or -1 for EOF"
  end
  if policy == "temporary" and params.end_line ~= nil and params.end_line ~= -1 then
    return nil, "temporary reads support only end_line=-1 or an omitted end_line"
  end
  if params.cursor ~= nil then
    if type(params.cursor) ~= "string" or params.cursor == "" then
      return nil, "cursor must be a nonempty string"
    end
    if params.start_line ~= nil or params.end_line ~= nil then
      return nil, "cursor cannot be combined with start_line or end_line"
    end
  end
  return policy
end

local function next_line(content, offset)
  local pos = content:find("[\r\n]", offset)
  if not pos then
    return #content + 1
  end
  return content:sub(pos, pos + 1) == "\r\n" and pos + 2 or pos + 1
end

local function line_start(content, number)
  local offset = 1
  for _ = 2, number do
    if offset > #content then
      return nil
    end
    offset = next_line(content, offset)
    if offset == #content + 1 and content:sub(-1) ~= "\n" and content:sub(-1) ~= "\r" then
      return nil
    end
  end
  return offset
end

local function cursor_for(hash, offset, boundary)
  return string.format("%x.%x.%s", offset, boundary, hash)
end

local function decode_cursor(cursor, hash, size)
  local start_hex, end_hex, fingerprint = cursor:match("^([0-9a-f]+)%.([0-9a-f]+)%.([0-9a-f]+)$")
  if not fingerprint then
    return nil, nil, "Invalid cursor"
  end
  if fingerprint ~= hash then
    return nil, nil, "Cursor does not match the current source or result_policy; start a new read"
  end
  local offset, boundary = tonumber(start_hex, 16), tonumber(end_hex, 16)
  if not offset or not boundary or offset < 1 or offset >= boundary or boundary > size + 1 then
    return nil, nil, "Invalid cursor position or bound"
  end
  return offset, boundary
end

local function safe_end(content, offset, last)
  while last >= offset do
    local next_byte = content:byte(last + 1)
    if not next_byte or next_byte < 128 or next_byte > 191 then
      break
    end
    last = last - 1
  end
  return last
end

local function mark_lifecycle(context, policy, normalized_path)
  local temporary = policy == "temporary" or (policy == "auto" and normalized_path and normalized_path:sub(1, #TMP_PREFIX) == TMP_PREFIX)
  local persist = policy == "persist"
  if not temporary and not persist then
    return
  end
  local ok, ttl = pcall(require, "maxa.interactions.chat.tools.builtin.runtime.ttl_result")
  if not ok then
    return
  end
  if persist then
    ttl.mark_current_tool_result(context, {
      ttl = 3,
      cleanup = "content",
      policy = "persist",
      persistent = true,
      enabled = false,
      display_state = "persist",
    })
  else
    ttl.mark_current_tool_result(context, { ttl = 3, cleanup = "content" })
  end
end

local function content_hash(params, path_label, content)
  return vim.fn.sha256(string.format("%d:%s:%s:%s", #path_label, path_label, params.result_policy or "auto", vim.fn.sha256(content)))
end

local function respond_content(context, response, params, path_label, content, normalized_path)
  local policy = params.result_policy or "auto"
  local hash = content_hash(params, path_label, content)
  local offset, boundary
  if params.cursor then
    local err
    offset, boundary, err = decode_cursor(params.cursor, hash, #content)
    if not offset then
      return response:error(err)
    end
  else
    offset = line_start(content, params.start_line or 1) or #content + 1
    boundary = #content + 1
    if params.end_line and params.end_line ~= -1 then
      if params.start_line and params.end_line < params.start_line then
        return response:error("end_line must be greater than or equal to start_line")
      end
      local after_end = line_start(content, params.end_line + 1)
      boundary = after_end or boundary
    end
    boundary = math.max(offset, boundary)
  end

  local temporary = policy == "temporary" or (policy == "auto" and normalized_path and normalized_path:sub(1, #TMP_PREFIX) == TMP_PREFIX)
  local reserve = temporary and require("maxa.interactions.chat.tools.builtin.runtime.ttl_result").read_header_reserve(context) or 0
  local return_limit = MAX_RETURN_CHARS - reserve
  local stop = math.min(boundary - 1, #content)
  local last = math.min(stop, offset + return_limit - 25)
  if last < stop then
    last = safe_end(content, offset, last)
    if last < offset then
      return response:error("Cannot split content at a UTF-8 character boundary")
    end
  end
  local next_cursor
  while last < stop do
    next_cursor = cursor_for(hash, last + 1, boundary)
    local header = "next_cursor: " .. next_cursor .. "\n---\n"
    local max_end = math.min(stop, offset + return_limit - #header - 1)
    if max_end < last then
      last = safe_end(content, offset, max_end)
    else
      break
    end
    if last < offset then
      return response:error("Cursor metadata exceeds the read output limit")
    end
  end
  local header = "next_cursor: " .. (last == stop and "none" or next_cursor) .. "\n---\n"
  local output = header .. content:sub(offset, last)
  if #output > return_limit then
    return response:error("Cursor metadata exceeds the read output limit")
  end
  mark_lifecycle(context, policy, normalized_path)
  return response:text(output):send()
end

local function resource_text(result)
  if type(result) == "table" and type(result.result) == "table" then
    result = result.result
  end
  local parts = type(result) == "table" and (result.contents or result.content) or result
  if type(parts) == "string" then
    return parts
  end
  if type(parts) ~= "table" then
    return nil, "MCP resource returned no textual content"
  end
  if not (vim.islist or vim.tbl_islist)(parts) then
    parts = { parts }
  end
  local text = {}
  for index, part in ipairs(parts) do
    if type(part) == "string" then
      text[#text + 1] = part
    elseif type(part) == "table" and (part.type == nil or part.type == "text") and type(part.text) == "string" then
      text[#text + 1] = part.text
    else
      return nil, string.format("MCP resource part %d is non-text and cannot be read", index)
    end
  end
  return table.concat(text, "\n")
end

local function read_ability_reference(context, response, params)
  local resolved, err = require("maxa.interactions.chat.tools.builtin.runtime.ability_utils").resolve_reference(context, params.path)
  if not resolved then
    return response:error(err)
  end
  if resolved.file then
    local entry = resolved.file
    local path = require("plenary.path"):new(entry.path)
    local ok, content = pcall(function()
      return path:read()
    end)
    if not ok then
      return response:error("Failed to read Ability file: " .. tostring(content))
    end
    utils.fire_file_event(context, "read", entry.path, "read")
    return respond_content(context, response, params, params.path, content or "", entry.path)
  end

  local resource = resolved.resource
  local transport = require("maxa.mcphub").get_project_transport()
  transport.access_resource(context.cwd, resource.server_name, resource.uri, {
    project_root = context.project_root or context.cwd,
    callback = function(result, access_err)
      local allowed, policy_err = require("maxa.project.settings").check_ability(context.project_root or context.cwd, resource.server_name)
      if not allowed then return response:error(tostring(policy_err)) end
      if not result then
        return response:error(tostring(access_err))
      end
      local content, text_err = resource_text(result)
      if not content then
        return response:error(text_err)
      end
      respond_content(context, response, params, params.path, content, nil)
    end,
  })
end

return {
  -- Semantic consumers reuse the filesystem read protocol rather than copying it.
  validate_request = validate_request,
  respond_content = respond_content,
  content_hash = content_hash,
  name = "read",
  display = function(args)
    return { summary = require("maxa.interactions.chat.tools.display_helpers").path_detail("read", args, true) }
  end,
  description = [[Read filesystem, unified `#ability[target]` content, or loaded Ability semantic text in bounded chunks of at most 20,000 bytes. Leading / targets try the root-confined current package file without loading/disclosure; only file absence falls back to committed content in the exact Chat/workspace. Other targets resolve directly to committed content; identifiers are unchanged. Every successful result starts with `next_cursor: <token|none>`; source text follows the first header separator `---`, unescaped. TTL-managed results add tool_call_id, ttl and any ttl_notice before that separator, never after source text. Pass a returned token unchanged as `cursor` to continue; `none` means finished. `start_line` locates a line; omitted `end_line` and `end_line=-1` both target EOF. Only non-temporary reads accept a positive `end_line`; temporary reads cannot request a short range. `force=true` is unsupported. Textual resource parts join in response order; non-text resources fail without conversion.]],
  inputSchema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Filesystem path, #ability[target] content reference, or address interpreted by a loaded Ability." },
      start_line = { type = "number", description = "Optional 1-based line anchor; omit when using cursor." },
      end_line = { type = "number", description = "Positive inclusive end line (non-temporary only), or -1 for EOF; omitted also means EOF. Omit when using cursor." },
      cursor = { type = "string", description = "Opaque next_cursor from the previous result; omit start_line and end_line." },
      force = { type = "boolean", description = "Deprecated compatibility input; force=true is rejected. Continue with cursor instead.", default = false },
      result_policy = {
        type = "string",
        enum = { "auto", "temporary", "keep", "persist" },
        description = "auto (default; /tmp gets TTL); temporary (3-round TTL, no positive end_line); keep (no TTL); persist (protected across compression).",
        default = "auto",
      },
    },
    required = { "path" },
    additionalProperties = false,
  },
  run = function(context, response)
    local params = param_utils.normalize(context.params)
    if not params.path or params.path == "" then
      return response:error("Missing required parameter: path")
    end
    local _, validation_error = validate_request(params)
    if validation_error then
      return response:error(validation_error)
    end
    if params.path:sub(1, 1) == "#" then
      return read_ability_reference(context, response, params)
    end
    local path = require("plenary.path"):new(params.path)
    if not path:exists() then
      return response:error("File not found: " .. params.path)
    end
    if path:is_dir() then
      return response:error("Path is a directory, not a file: " .. params.path)
    end
    local ok, content = pcall(function()
      return path:read()
    end)
    if not ok then
      return response:error("Failed to read file: " .. tostring(content))
    end
    local absolute = path:absolute()
    utils.fire_file_event(context, "read", absolute, "read")
    return respond_content(context, response, params, params.path, content or "", absolute)
  end,
}
