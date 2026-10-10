-- fire 工具实现
-- LLM 可调用的 MCP 工具，触发自定义 AbilityHook* 事件
--
-- 用途：让 LLM 在工作流中根据已加载 Ability 的指导触发事件
local param_utils = require("maxa.mcphub.native_servers.shared.params")

local function fire(context, response)
  -- 验证请求
  if not context or not context.params then
    return response:error("fire: Invalid request object")
  end

  local params = param_utils.normalize(context.params)
  local event = params.event
  if not event or event == "" then
    return response:error("fire: event parameter is required (e.g., 'TaskPhaseRed')")
  end

  -- 事件名不应包含 AbilityHook 前缀（fire.lua 会自动添加）
  if event:match("^AbilityHook") then
    event = event:sub(#"AbilityHook" + 1) -- 去掉前缀
  end

  -- 获取 bufnr
  local fire_ok, fire = pcall(require, "maxa.abilities.hooks.fire")
  if not fire_ok then
    return response:error("fire: Failed to load ability_hooks.fire module")
  end

  local bufnr = context.bufnr
    or (context.chat and context.chat.bufnr)
    or (context.caller and context.caller.context and context.caller.context.bufnr)
  if not bufnr then
    return response:error("fire: exact Chat buffer is unavailable")
  end

  -- 构建 event data
  local data = params.data or {}
  -- 处理 data 类型：如果是 JSON 字符串则自动解析
  if data ~= nil and type(data) == "string" then
    -- 尝试解析 JSON 字符串
    local ok, parsed = pcall(vim.json.decode, data)
    if ok and type(parsed) == "table" then
      data = parsed
    else
      return response:error(
        string.format("fire: data is a string but failed to parse as JSON: %s", data:sub(1, 100))
      )
    end
  elseif data ~= nil and type(data) ~= "table" then
    return response:error("fire: data must be an object/table, got " .. type(data))
  end

  data.bufnr = bufnr

  -- 触发事件
  fire.fire(event, data)

  return response:text(string.format("Event fired: AbilityHook%s", event)):send()
end

-- 工具定义
return {
  name = "fire",
  display = function(args)
    return { summary = type(args.event) == "string" and args.event ~= "" and ("fire " .. args.event) or "fire" }
  end,
  description = [[Fire a custom AbilityHook event.

Call only when explicitly instructed by a loaded Ability. Do not invent event names. `data` must include the event's full required payload; do not send only partial fields such as `phase="red"` for `TaskPhaseChanged`. `bufnr` is injected automatically. Listening hooks receive the event and may inject chat messages.]],

  inputSchema = {
    type = "object",
    properties = {
      event = {
        type = "string",
        description = "Event name without `AbilityHook` prefix; must be defined by a loaded Ability.",
      },
      data = {
        -- type = "object",
        description = "Event payload object. Include all fields required by the event; `bufnr` is auto-injected.",
        additionalProperties = true,
      },
    },
    required = { "event" },
  },
  run = fire,
}
