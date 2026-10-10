-- SubAgent-owned LLM projection. Internal result/trace tables stay unchanged.
local M = {}
local HEADER_KEYS = {
  status = true, save_id = true, source_save_id = true, parent_save_id = true,
  session_id = true, context = true, finish_reason = true, recovery_available = true,
  recovery = true, private_message_from = true,
}

local function field(lines, key, value)
  if value ~= nil then
    lines[#lines + 1] = key .. ": " .. tostring(value):gsub("[\r\n]", " ")
  end
end

local function join(lines, body)
  local header = table.concat(lines, "\n")
  if body ~= nil then return header .. "\n---\n" .. body end
  return header
end

local function context_line(status)
  local tokens = status and status.tokens
  if not tokens or type(tokens.percent) ~= "number" then return "unavailable" end
  local amount = type(tokens.used) == "number" and type(tokens.limit) == "number"
    and tostring(tokens.used) .. "/" .. tostring(tokens.limit) or "unavailable"
  return tostring(tokens.percent) .. "% (" .. amount .. "; " .. tostring(tokens.source or "unknown") .. ")"
end

function M.answer(result)
  local data = result.data or result
  local lines = {}
  field(lines, "session_id", data.session_id)
  field(lines, "save_id", data.save_id)
  if result.source_save_id and result.source_save_id ~= data.save_id then
    field(lines, "source_save_id", result.source_save_id)
  end
  if not data.session_id or data.context_status then
    field(lines, "context", context_line(data.context_status))
  end
  if result.finish_reason and result.finish_reason ~= "completed" then
    field(lines, "finish_reason", result.finish_reason)
  end
  return join(lines, data.content or "")
end

function M.recovery(result)
  local lines = {}
  field(lines, "status", result.status)
  field(lines, "save_id", result.save_id)
  field(lines, "source_save_id", result.source_save_id ~= result.save_id and result.source_save_id or nil)
  field(lines, "parent_save_id", result.parent_save_id)
  field(lines, "context", context_line(result.context_status))
  field(lines, "recovery_available", result.recovery_available)
  if result.compact_stats then field(lines, "recovery", "session_compacted") end
  return join(lines, result.original_error)
end

function M.handoff(result)
  local lines = {}
  field(lines, "status", result.status)
  field(lines, "save_id", result.save_id)
  field(lines, "private_message_from", result.private_message_from)
  local sections = {}
  local discussion = result.discussion_after or {}
  if #discussion > 0 then
    sections[#sections + 1] = "### Public discussion"
    for _, entry in ipairs(discussion) do
      sections[#sections + 1] = "#### " .. tostring(entry.agent):gsub("[\r\n]", " ") .. "\n\n" .. (entry.message or "")
    end
  end
  if result.private_message then
    sections[#sections + 1] = "### Private message\n\n" .. result.private_message
  end
  return join(lines, #sections > 0 and table.concat(sections, "\n\n") or nil)
end

-- Only the first exact separator ends metadata. Answer contents are opaque.
-- Legacy JSON remains readable for old saved tool results, never rewritten.
function M.parse(text)
  if type(text) ~= "string" then return nil end
  local boundary = text:find("\n---\n", 1, true)
  local header = boundary and text:sub(1, boundary - 1) or text
  local data, count = {}, 0
  for line in (header .. "\n"):gmatch("(.-)\n") do
    local key, value = line:match("^([a-z_]+): (.*)$")
    if not key or not HEADER_KEYS[key] then data = nil; break end
    data[key], count = value, count + 1
  end
  if data and count > 0 then
    if boundary then data.content = text:sub(boundary + #"\n---\n") end
    if data.context then
      local percent, source = data.context:match("^([%d.]+)%% %([^;]*; ([^)]*)%)$")
      data.context_status = { tokens = { percent = tonumber(percent), source = source } }
    end
    return data
  end
  for _, candidate in ipairs({ text, text:match("````%w*%s*\n(.-)````") or "", text:match("```%w*%s*\n(.-)```") or "" }) do
    local ok, value = pcall(vim.json.decode, candidate)
    if ok and type(value) == "table" then return value.data or value end
  end
end

return M
