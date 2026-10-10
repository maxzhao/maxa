-- ability_hooks/filter.lua
-- Event data 过滤匹配引擎
--
-- 三条组合规则：
--   1. 多个字段 → AND（跨字段合取）
--   2. 数组元素 → AND（同字段合取）
--   3. "|" 分隔符 → OR（值析取）
--
-- 保留字符：! | * prefix: pattern:
-- 如需留字符的字面值，使用 pattern: 绕过

local M = {}

--- 解析单个条件字符串为 matcher 函数
---@param cond_str string
---@return fun(val: any): boolean
function M.parse_condition(cond_str)
  local negated = false
  local cond = cond_str

  if cond:sub(1, 1) == "!" then
    negated = true
    cond = cond:sub(2)
  end

  -- 禁止歧义语法 !value|other
  if negated and cond:find("|") then
    error(string.format(
      "[ability_hooks/filter] Syntax error: '!...|...' is ambiguous in '%s'. "
        .. "Use separate array items for multiple negations: [\"!a\", \"!b\"]",
      cond_str
    ))
  end

  local matcher

  if cond == "*" then
    -- 存在性检查
    matcher = function(val) return val ~= nil end
  elseif cond:sub(1, 7) == "prefix:" then
    local prefix = cond:sub(8)
    local plen = #prefix
    matcher = function(val)
      return type(val) == "string" and val:sub(1, plen) == prefix
    end
  elseif cond:sub(1, 8) == "pattern:" then
    local pat = cond:sub(9)
    -- 支持 | 作为 OR（Lua pattern 没有原生 alternation）
    if pat:find("|", 1, true) then
      local patterns = {}
      for p in pat:gmatch("[^|]+") do
        patterns[#patterns + 1] = p
      end
      matcher = function(val)
        if type(val) ~= "string" then
          return false
        end
        for _, p in ipairs(patterns) do
          if val:find(p) ~= nil then
            return true
          end
        end
        return false
      end
    else
      matcher = function(val)
        return type(val) == "string" and val:find(pat) ~= nil
      end
    end
  elseif cond:find("|") then
    -- OR: 管道分隔的多值精确匹配
    local values = {}
    for v in cond:gmatch("[^|]+") do
      values[v] = true
    end
    matcher = function(val)
      return val ~= nil and values[tostring(val)] ~= nil
    end
  else
    -- 精确匹配（要求 non-nil 防止 tostring(nil) == "nil"）
    matcher = function(val)
      return val ~= nil and tostring(val) == cond
    end
  end

  if negated then
    local orig = matcher
    return function(val) return not orig(val) end
  end
  return matcher
end

--- 标准化 filter 值为条件字符串数组
---@param filter_val any
---@return string[]
function M.normalize(filter_val)
  if type(filter_val) == "string" then
    return { filter_val }
  elseif type(filter_val) == "number" or type(filter_val) == "boolean" then
    return { tostring(filter_val) }
  elseif type(filter_val) == "table" then
    local result = {}
    for _, v in ipairs(filter_val) do
      result[#result + 1] = tostring(v)
    end
    return result
  end
  return {}
end

--- 检查 event data 是否匹配 filter
---@param filter table|nil hook frontmatter 中的 filter
---@param event_data table 事件载荷
---@return boolean
function M.matches(filter, event_data)
  if not filter or type(filter) ~= "table" or next(filter) == nil then
    return true -- 无 filter / 非 table / 空 table = 始终匹配
  end

  for field, filter_val in pairs(filter) do
    local conditions = M.normalize(filter_val)
    local val = event_data[field]

    for _, cond in ipairs(conditions) do
      local ok, matcher = pcall(M.parse_condition, cond)
      if not ok then
        -- 条件解析失败，记录警告并跳过此 hook
        vim.notify(
          string.format("[ability_hooks/filter] %s", matcher),
          vim.log.levels.WARN
        )
        return false
      end
      if not matcher(val) then
        return false -- AND: 所有字段的所有条件必须全部通过
      end
    end
  end

  return true
end

return M
