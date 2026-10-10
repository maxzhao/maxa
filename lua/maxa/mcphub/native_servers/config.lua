-- MCP 工具链统一配置模块
-- 所有 adapter preset 和 agent preset 的单一来源
-- 被 ai.lua, subagent, session 等模块引用
local M = {}

-- Deprecated compatibility fields. Runtime presets no longer read these values;
-- each compact/summary block owns its complete configuration.
M.compaction_planning_reasoning_effort = "none"
M.compaction_summary_reasoning_effort = "none"

-- ============================================================================
-- Adapter Presets
-- ============================================================================

-- Keep the public table identity: legacy clients read adapters_preset directly.
M.adapters = require("maxa.config").runtime().presets
function M.configure(presets)
  assert(type(presets) == "table", "maxa.presets must be a table")
  for name, value in pairs(presets) do
    assert(type(name) == "string" and name ~= "" and type(value) == "table", "preset names must map to tables")
  end
  local copied = vim.deepcopy(presets)
  local target = M.adapters
  for name in pairs(target) do target[name] = nil end
  for name, value in pairs(copied) do target[name] = value end
end

local presets = require("maxa.presets")

-- ============================================================================
-- Agent Presets
-- ============================================================================

--- Agent 预设表
--- inherits: 控制非 inherit 模式下从父 chat 继承的属性
-- ============================================================================
-- API Functions
-- ============================================================================

--- 深拷贝简单 Lua table，保留 function 引用。
--- @param value any
--- @return any
local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copied = {}
  for k, v in pairs(value) do
    copied[deepcopy(k)] = deepcopy(v)
  end
  return copied
end

local function normalize_adapter_preset(name, preset, source)
  if type(preset) ~= "table" then
    return nil, "adapter preset must be a table"
  end
  if type(preset.adapter) ~= "string" or preset.adapter == "" then
    return nil, "adapter preset is missing adapter"
  end
  if preset.model ~= nil and type(preset.model) ~= "string" then return nil, "preset model must be a string" end
  if preset.temperature ~= nil and type(preset.temperature) ~= "number" then return nil, "preset temperature must be a number" end
  if preset.thinking_mode ~= nil and type(preset.thinking_mode) ~= "string" then return nil, "preset thinking_mode must be a string" end

  return {
    adapter = preset.adapter,
    model = preset.model,
    temperature = preset.temperature,
    thinking_mode = preset.thinking_mode,
    inherit = preset.adapter == "inherit",
    source = source or ("preset:" .. tostring(name)),
  },
    nil
end

--- 获取 adapter 预设（按名称）
--- @param name string 预设名称（如 "default", "summary", "compact", "fast"）
--- @return {adapter: string, model: string|nil, temperature: number|nil, thinking_mode: string|nil, inherit: boolean, source: string}|nil config
--- @return string|nil error
function M.get_internal_adapter(name)
  return presets.get_default(name == "default" and "chat" or name)
end

M.get_default = presets.get_default
M.get_preset = presets.get_preset

function M.get_adapter(name)
  return presets.get_preset(name, "chat")
end

local function get_adapter_name_from_session(chat, chat_data)
  if chat and chat.adapter and chat.adapter.name and chat.adapter.name ~= "" then
    return chat.adapter.name
  end
  if chat_data and chat_data.adapter and chat_data.adapter ~= "" then
    return chat_data.adapter
  end
  return nil
end

local function get_runtime_maxa(adapter_name, chat, kind)
  local adapter = chat and chat.adapter or nil
  if adapter and adapter.maxa and adapter.maxa[kind] then
    return adapter.maxa[kind], "adapter:" .. tostring(adapter.name or adapter_name) .. ":" .. kind
  end

  if adapter_name and adapter_name ~= "" then
    local ok, resolved = pcall(require("maxa.adapters").resolve, adapter_name)
    if ok and resolved and resolved.maxa and resolved.maxa[kind] then
      return resolved.maxa[kind], "adapter:" .. adapter_name .. ":" .. kind
    end
  end

  return nil, nil
end

--- 构建目标 HTTP adapter 的推理强度 settings override。
--- 只写入目标 adapter schema 明确支持的键；Anthropic 的 `none` 映射为关闭 extended thinking。
--- @param adapter table|nil
--- @param reasoning_effort string|nil
--- @return table|nil settings
function M.get_reasoning_effort_settings(adapter, reasoning_effort)
  if not adapter or reasoning_effort == nil or reasoning_effort == "" then
    return nil
  end

  local schema = adapter.schema or {}
  if schema["reasoning.effort"] then
    return { ["reasoning.effort"] = reasoning_effort }
  end
  if schema.reasoning_effort then
    return { reasoning_effort = reasoning_effort }
  end
  if schema.extended_thinking and reasoning_effort == "none" then
    return { extended_thinking = false }
  end
  return nil
end

--- 获取运行时 adapter 配置：当前/目标 adapter 的 maxa 配置优先，整个配置块不存在时才使用全局 preset。
--- preset 采用整体覆盖语义，不从其他层补齐缺失字段。
--- @param kind string
--- @param opts table|nil { chat?: table, chat_data?: table }
--- @return {adapter: string, model: string|nil, temperature: number|nil, reasoning_effort: string|nil, inherit: boolean, source: string}|nil config
--- @return string|nil error
function M.get_runtime_adapter(kind, opts)
  opts = opts or {}
  local adapter_name = get_adapter_name_from_session(opts.chat, opts.chat_data)
  local runtime_preset, runtime_source = get_runtime_maxa(adapter_name, opts.chat, kind)
  local normalized
  local err
  if runtime_preset then
    normalized, err = normalize_adapter_preset(kind, deepcopy(runtime_preset), runtime_source)
    if not normalized then
      return nil, string.format("invalid runtime %s adapter config from %s: %s", kind, runtime_source, err)
    end
  else
    normalized, err = presets.get_default(kind == "default" and "chat" or kind)
    if not normalized then return nil, err end
  end

  normalized.reasoning_effort = normalized.thinking_mode
  return normalized, nil
end

return M
