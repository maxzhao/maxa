-- Role defaults and reusable named configurations share one resolver.
local M = {}
local TYPES = { chat = true, image = true, tts = true, video = true }
local ROLES = { chat = "chat", compact = "chat", summary = "chat", translate = "chat", title = "chat", image = "image", tts = "tts", video = "video" }
local function runtime(config) return config or require("maxa.config").runtime() end
local function copy(value) return vim.deepcopy(value) end

local function normalize(value, expected, source)
  if type(value) ~= "table" then return nil, source .. " must be a preset table" end
  local kind = value.type or expected or "chat"
  if not TYPES[kind] or (expected and kind ~= expected) then
    return nil, source .. " must have type " .. tostring(expected or "chat/image/tts/video")
  end
  if value.visible ~= nil and type(value.visible) ~= "boolean" then return nil, source .. ".visible must be a boolean" end
  if value.description ~= nil and type(value.description) ~= "string" then return nil, source .. ".description must be a string" end
  if value.visible and (not value.description or vim.trim(value.description) == "") then return nil, source .. " requires a description when visible" end
  local result = copy(value)
  result.type, result.visible, result.description = nil, nil, nil
  result.source = source
  if kind == "chat" then
    if type(result.adapter) ~= "string" or result.adapter == "" then return nil, source .. " is missing adapter" end
    if result.model ~= nil and type(result.model) ~= "string" then return nil, source .. ".model must be a string" end
    if result.temperature ~= nil and type(result.temperature) ~= "number" then return nil, source .. ".temperature must be a number" end
    if result.thinking_mode ~= nil and type(result.thinking_mode) ~= "string" then return nil, source .. ".thinking_mode must be a string" end
    result.inherit = result.adapter == "inherit"
  elseif result.adapter ~= nil and (type(result.adapter) ~= "string" or vim.trim(result.adapter) == "") then
    return nil, source .. ".adapter must be a nonblank string"
  end
  return result
end

function M.get_preset(name, expected, config)
  config = runtime(config)
  if type(name) ~= "string" or name == "" then return nil, "preset name is required" end
  local value = (config.presets or {})[name]
  if not value then return nil, "Unknown preset '" .. name .. "'" end
  -- Untyped legacy Chat presets may omit fields supplied by the old default.
  if value.type == nil and (expected == nil or expected == "chat") and value.adapter == nil then
    if name == "compact" or name == "default_agent" then
      value = copy(value)
      value.adapter = "inherit"
    else
      local fallback = (config.presets or {}).default or {}
      value = vim.tbl_deep_extend("keep", copy(value), copy(fallback))
    end
  end
  local result, err = normalize(value, expected or value.type or "chat", "preset:" .. name)
  if result and (expected == "image" or expected == "tts" or expected == "video") and not result.adapter then
    return nil, "preset:" .. name .. " is missing adapter"
  end
  return result, err
end

function M.get_default(role, config)
  config = runtime(config)
  local kind = ROLES[role]
  if not kind then return nil, "Unknown default role '" .. tostring(role) .. "'" end
  local value = (config.defaults or {})[role]
  if value == nil then
    if role == "compact" then value = { adapter = "inherit" }
    elseif kind == "chat" and role ~= "chat" then return M.get_default("chat", config)
    else value = {} end
  end
  if type(value) == "string" then return M.get_preset(value, kind, config) end
  return normalize(value, kind, "default:" .. role)
end

-- Called once at composition; legacy inputs only fill roles not explicitly set.
function M.compose(config, declared)
  declared = declared or {}
  config.defaults = config.defaults or {}
  for role, kind in pairs(ROLES) do
    if not (declared.defaults and declared.defaults[role] ~= nil) then
      if kind == "chat" then
        local name = role == "chat" and "default" or role
        local old = declared.presets and declared.presets[name]
        if old and old.type == nil then
          config.defaults[role] = copy(old)
          if (role == "compact") and old.adapter == nil then config.defaults[role].adapter = "inherit" end
          if role ~= "chat" and role ~= "compact" then
            config.defaults[role] = vim.tbl_deep_extend("keep", config.defaults[role], copy(declared.presets.default or {}))
          end
        end
      else
        local old = declared.genai or {}
        local legacy = copy((old.defaults or {})[role] or {})
        if role == "video" and legacy.preset ~= nil then
          legacy.generation_preset = legacy.generation_preset or legacy.preset
          legacy.preset = nil
        end
        config.defaults[role] = vim.tbl_deep_extend("force", copy(config.defaults[role] or {}), legacy)
        if old.default_adapters and old.default_adapters[role] then config.defaults[role].adapter = old.default_adapters[role] end
      end
    end
  end
  for name, value in pairs(config.presets or {}) do
    assert(type(name) == "string" and name ~= "" and type(value) == "table", "preset names must map to tables")
    local kind = value.type or "chat"
    assert(TYPES[kind], "invalid preset type: " .. tostring(kind))
    local _, err = normalize(vim.tbl_extend("keep", copy(value), { adapter = "inherit" }), kind, "preset:" .. name)
    assert(not err, err)
  end
  for role, value in pairs(config.defaults) do
    assert(ROLES[role], "Unknown default role '" .. tostring(role) .. "'")
    local selected, err = M.get_default(role, config)
    -- A standalone library may omit a concrete Chat deployment.
    if role ~= "chat" or type(value) == "string" or (type(value) == "table" and next(value) ~= nil) then
      assert(selected, err)
    end
  end
  if config.genai then config.genai.defaults, config.genai.default_adapters = nil, nil end
  return config
end

function M.visible(config)
  local result = {}
  for name, value in pairs(runtime(config).presets or {}) do
    if value.visible then result[#result + 1] = { name = name, type = value.type or "chat", description = value.description } end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end
return M
