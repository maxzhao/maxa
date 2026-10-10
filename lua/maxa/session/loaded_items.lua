local M = {}

local function estimate_message_bytes(message)
  local ok, encoded = pcall(vim.json.encode, message)
  return ok and #encoded or #(tostring(message and message.content or ""))
end

local function text_hint(content, limit)
  local value = vim.trim(tostring(content or ""):gsub("%s+", " "))
  limit = limit or 120
  return #value > limit and (value:sub(1, limit - 3) .. "...") or value
end

function M.is_tool_error(message)
  return message
    and message.role == "tool"
    and ((message.tools and message.tools.is_error) or tostring(message.content or ""):match("Tool%*%*: Failed"))
    or false
end

---Return current Ability revisions and ordinary loaded context files.
function M.extract_loaded_items(messages)
  local result = { abilities = {}, contexts = {} }
  local abilities, contexts = {}, {}
  for _, message in ipairs(messages or {}) do
    local ability = message._meta and message._meta.ability
    if ability and ability.name then
      local item = abilities[ability.name] or { value = ability.name, bytes = 0, text_hint = nil }
      item.bytes = item.bytes + estimate_message_bytes(message)
      item.text_hint = item.text_hint or text_hint(message.content)
      item.digest = ability.digest or item.digest
      abilities[ability.name] = item
    elseif message._meta and message._meta.tag == "context_file" and message.context and message.context.id then
      contexts[message.context.id] = {
        value = message.context.id,
        bytes = estimate_message_bytes(message),
        text_hint = text_hint(message.content),
      }
    end
    if message.role == "tool" and message._meta and message._meta.ability_catalogs then
      for name, catalog in pairs(message._meta.ability_catalogs) do
        local item = abilities[name] or { value = name, bytes = 0, text_hint = nil }
        item.bytes = item.bytes + estimate_message_bytes(message)
        item.digest = catalog.digest or item.digest
        abilities[name] = item
      end
    end
  end
  for _, item in pairs(abilities) do
    result.abilities[#result.abilities + 1] = item
  end
  for _, item in pairs(contexts) do
    result.contexts[#result.contexts + 1] = item
  end
  table.sort(result.abilities, function(a, b)
    return a.value < b.value
  end)
  table.sort(result.contexts, function(a, b)
    return a.value < b.value
  end)
  return result
end

local function selected(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[value] = true
  end
  return result
end

---Remove selected Ability/context records while preserving unrelated history.
function M.clean_context_items(messages, clean_config)
  clean_config = clean_config or {}
  local ability_names = selected(clean_config.abilities)
  local context_paths = selected(clean_config.contexts)
  if next(ability_names) == nil and next(context_paths) == nil then
    return messages, { abilities = 0, contexts = 0, tool_pairs = 0 }
  end
  local remove_call_ids = {}
  local stats = { abilities = 0, contexts = 0, tool_pairs = 0 }
  for _, message in ipairs(messages or {}) do
    local ability = message._meta and message._meta.ability
    if ability and ability_names[ability.name] and ability.catalog_call_id then
      remove_call_ids[ability.catalog_call_id] = true
    end
  end
  local output = {}
  for _, message in ipairs(messages or {}) do
    local skip = false
    local ability = message._meta and message._meta.ability
    if ability and ability_names[ability.name] then
      skip = true
      stats.abilities = stats.abilities + 1
    elseif message._meta and message._meta.tag == "context_file" and message.context and context_paths[message.context.id] then
      skip = true
      stats.contexts = stats.contexts + 1
    elseif message.role == "tool" then
      local call_id = (message.tools and message.tools.call_id) or message.tool_call_id
      local catalogs = message._meta and message._meta.ability_catalogs
      if call_id and remove_call_ids[call_id] then
        skip = true
        stats.tool_pairs = stats.tool_pairs + 1
      elseif catalogs then
        for name in pairs(catalogs) do
          if ability_names[name] then
            skip = true
            stats.tool_pairs = stats.tool_pairs + 1
            break
          end
        end
      end
    elseif (message.role == "llm" or message.role == "assistant") and message.tools and message.tools.calls then
      local kept = {}
      for _, call in ipairs(message.tools.calls) do
        local call_id = call.call_id or call.id
        if not (call_id and remove_call_ids[call_id]) then
          kept[#kept + 1] = call
        end
      end
      if #kept ~= #message.tools.calls then
        if #kept == 0 and (not message.content or message.content == "") then
          skip = true
        else
          message = vim.deepcopy(message)
          message.tools.calls = kept
        end
      end
    end
    if not skip then
      output[#output + 1] = message
    end
  end
  return output, stats
end

return M
