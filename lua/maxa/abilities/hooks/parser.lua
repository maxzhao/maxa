-- ability_hooks/parser.lua
-- Hook 文件解析器
--
-- 解析 hooks/{EventName}.md 文件，提取：
--   - frontmatter: enabled, load, scope, filter, opts
--   - prompts: [{role, content}, ...]
--
-- Hook 文件格式：
-- ```markdown
-- ---
-- load: startup
-- scope: global
-- filter:
--   tool_id: "prefix:session__"
-- opts:
--   visible: false
-- ---
--
-- ## user
--
-- 用户角色消息（明确要求，LLM 必须回应）
--
-- ## llm
--
-- LLM 角色消息（自我承诺，以 LLM 自身身份描述）
-- ```

local M = {}

--- 从文件路径提取事件名（文件名去掉 .md 后缀）
---@param path string 文件路径
---@return string event_name
function M.extract_event_name(path)
  local filename = path:match("([^/]+)%.[^.]+$")
  return filename or ""
end

--- 解析 hook 文件的 frontmatter
--- 支持简单 key-value 和嵌套结构（filter 对象、filter 数组）
---@param content string 文件完整内容
---@return table|nil frontmatter 解析后的 frontmatter
---@return string body frontmatter 之后的正文
function M.parse_frontmatter(content)
  -- 检查是否以 frontmatter 开始
  if not (content:match("^%-%-%-\n") or content:match("^%-%-%-\r\n")) then
    return nil, content
  end

  -- 找到结束的 ---
  local _, fm_end = content:find("\n%-%-%-\n", 4)
  if not fm_end then
    _, fm_end = content:find("\n%-%-%-\r\n", 4)
  end
  if not fm_end then
    _, fm_end = content:find("\n%-%-%-$", 4)
  end

  if not fm_end then
    return nil, content
  end

  local fm_text = content:sub(5, fm_end - 4) -- 内容在 ---\n 和 \n--- 之间
  local frontmatter = {}

  -- 多行 YAML 解析：支持顶级 key-value 和嵌套对象/数组
  local current_key = nil
  local current_obj = nil

  for line in fm_text:gmatch("[^\r\n]*") do
    -- 空行跳过
    if line:match("^%s*$") then
      goto continue
    end

    -- 检查是否是顶级 key（无缩进）
    local top_key, top_val = line:match("^(%w[%w_%-]*):%s*(.*)$")
    if top_key then
      -- 保存之前的嵌套对象
      if current_key and current_obj then
        frontmatter[current_key] = current_obj
      end

      top_val = top_val:gsub("^%s+", ""):gsub("%s+$", "")

      if top_val == "" then
        -- 可能是嵌套对象/数组的开始
        current_key = top_key
        current_obj = {}
      elseif top_val == "{}" or top_val == "[]" then
        -- 显式空表/空数组
        current_key = nil
        current_obj = nil
        frontmatter[top_key] = {}
      else
        -- 简单 key-value
        current_key = nil
        current_obj = nil
        -- 去除引号
        top_val = top_val:gsub("^['\"]", ""):gsub("['\"]$", "")
        -- 处理布尔值
        if top_val == "true" then
          frontmatter[top_key] = true
        elseif top_val == "false" then
          frontmatter[top_key] = false
        else
          frontmatter[top_key] = top_val
        end
      end
      goto continue
    end

    -- 检查是否是缩进行（属于当前嵌套对象）
    if current_key and current_obj then
      -- 数组元素: "  - value"
      local array_val = line:match("^%s+%-%s+(.+)$")
      if array_val then
        array_val = array_val:gsub("^%s+", ""):gsub("%s+$", "")
        array_val = array_val:gsub("^['\"]", ""):gsub("['\"]$", "")
        table.insert(current_obj, array_val)
        goto continue
      end

      -- 对象属性: "  key: value"
      local sub_key, sub_val = line:match("^%s+(%w[%w_%-]*):%s*(.+)$")
      if sub_key then
        sub_val = sub_val:gsub("^%s+", ""):gsub("%s+$", "")
        sub_val = sub_val:gsub("^['\"]", ""):gsub("['\"]$", "")
        -- 处理布尔值
        if sub_val == "true" then
          current_obj[sub_key] = true
        elseif sub_val == "false" then
          current_obj[sub_key] = false
        else
          current_obj[sub_key] = sub_val
        end
        goto continue
      end

      -- 嵌套对象中的数组值: "    - value"（更深缩进）
      -- 当子 key 的值是数组时
      local deep_array_val = line:match("^%s%s%s%s+%-%s+(.+)$")
      if deep_array_val then
        deep_array_val = deep_array_val:gsub("^%s+", ""):gsub("%s+$", "")
        deep_array_val = deep_array_val:gsub("^['\"]", ""):gsub("['\"]$", "")
        -- 追加到最后一个 sub_key 的数组
        -- 简化处理：如果 current_obj 最后设置的值是 string，转为数组
        -- 这里简化为不支持深度嵌套数组，filter 的数组在直接子级
        goto continue
      end
    end

    ::continue::
  end

  -- 保存最后一个嵌套对象
  if current_key and current_obj then
    frontmatter[current_key] = current_obj
  end

  -- 提取正文
  local body = content:sub(fm_end + 1)
  body = body:gsub("^[\r\n]+", "")

  return frontmatter, body
end

--- 解析消息体（## user / ## llm 分段）。
---@param body string frontmatter 之后的正文
---@return table[]|nil prompts
---@return string|nil error
function M.parse_prompts(body)
  local prompts = {}
  local current_role = nil
  local current_lines = {}

  local function flush_current()
    if not current_role then
      return
    end
    local content = table.concat(current_lines, "\n")
    content = content:gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
    if content ~= "" then
      table.insert(prompts, { role = current_role, content = content })
    end
  end

  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local heading = line:match("^##(.*)$")
    if heading and heading:sub(1, 1) ~= "#" then
      if heading ~= "" and not heading:match("^%s") then
        return nil, string.format("malformed prompt role heading '%s'; expected '## user' or '## llm'", line)
      end
      local role = heading:gsub("^%s+", ""):gsub("%s+$", "")
      if role ~= "user" and role ~= "llm" then
        return nil, string.format("unsupported prompt role '%s'; valid roles: user, llm", role)
      end
      flush_current()
      current_role = role
      current_lines = {}
    elseif current_role then
      table.insert(current_lines, line)
    elseif line:match("%S") then
      return nil, "prompt content must be under a '## user' or '## llm' section"
    end
  end

  flush_current()
  if #prompts == 0 then
    return nil, "no non-empty '## user' or '## llm' prompts found"
  end
  return prompts, nil
end

--- 解析完整的 hook 文件
---@param path string 文件路径
---@param ability_dir string|nil 技能根目录
---@return table|nil hook 解析后的 hook 结构，失败返回 nil
---@return string|nil status `disabled` when the definition is intentionally disabled
function M.parse_hook_file(path, ability_dir)
  local file = io.open(path, "r")
  if not file then
    vim.notify(
      string.format("[ability_hooks/parser] Cannot read hook file: %s", path),
      vim.log.levels.WARN
    )
    return nil
  end
  local content = file:read("*a")
  file:close()

  local frontmatter, body = M.parse_frontmatter(content)

  if frontmatter and frontmatter.enabled == false then
    return nil, "disabled"
  end

  -- 提取 hook 配置
  local hook = {
    kind = "markdown",
    event_name = M.extract_event_name(path),
    path = path,
    ability_dir = ability_dir,
    load = (frontmatter and frontmatter.load) or "on_load",
    scope = (frontmatter and frontmatter.scope) or "global",
    inject_at = (frontmatter and frontmatter.inject_at) or "post",
    filter = frontmatter and frontmatter.filter or nil,
    opts = frontmatter and frontmatter.opts or {},
  }

  local prompts, prompt_err = M.parse_prompts(body)
  if not prompts then
    vim.notify(string.format("[ability_hooks/parser] Invalid prompts in hook %s: %s", path, prompt_err), vim.log.levels.WARN)
    return nil
  end
  hook.prompts = prompts

  -- 验证
  if hook.inject_at ~= "pre" and hook.inject_at ~= "post" then
    vim.notify(
      string.format(
        "[ability_hooks/parser] Invalid inject_at '%s' in hook: %s (expected 'pre' or 'post')",
        tostring(hook.inject_at),
        path
      ),
      vim.log.levels.WARN
    )
    return nil
  end

  if hook.event_name == "" then
    vim.notify(
      string.format("[ability_hooks/parser] Invalid hook filename: %s", path),
      vim.log.levels.WARN
    )
    return nil
  end

  if #hook.prompts == 0 then
    vim.notify(
      string.format("[ability_hooks/parser] No prompts found in hook: %s", path),
      vim.log.levels.WARN
    )
    return nil
  end

  -- 结构校验：检测多轮对话（llm → user 边界 = 隐含对话断裂）
  local prev_role = nil
  local turn_breaks = 0
  for _, prompt in ipairs(hook.prompts) do
    if prev_role == "llm" and prompt.role == "user" then
      turn_breaks = turn_breaks + 1
    end
    prev_role = prompt.role
  end
  if turn_breaks > 0 then
    vim.notify(
      string.format(
        "[ability_hooks/parser] ⚠️ Hook '%s' has %d llm→user turn break(s). "
          .. "LLM will treat earlier turns as completed conversation. "
          .. "Recommended: use single-turn structure (user → llm).",
        path,
        turn_breaks
      ),
      vim.log.levels.WARN
    )
  end

  return hook
end

--- 通知并返回 nil，用于 Lua hook 解析错误
---@param path string
---@param message string
---@return nil
local function lua_hook_error(path, message)
  vim.notify(
    string.format("[ability_hooks/parser] Invalid Lua hook %s: %s", path, message),
    vim.log.levels.WARN
  )
  return nil
end

--- 校验 load 字段
---@param value any
---@return string|nil
local function normalize_load(value)
  value = value or "on_load"
  if value == "startup" or value == "on_load" then
    return value
  end
  return nil
end

--- 校验 scope 字段
---@param value any
---@return string|nil
local function normalize_scope(value)
  value = value or "global"
  if value == "global" or value == "session" or value == "cascade" then
    return value
  end
  return nil
end

--- 校验注入时机字段
---@param value any
---@return string|nil
local function normalize_inject_at(value)
  value = value or "post"
  if value == "pre" or value == "post" then
    return value
  end
  return nil
end

--- 解析 Lua hook 文件
--- Lua hook 是独立的一等定义格式：hooks/{EventName}.lua
--- 文件必须 return table，且只能通过 render(ctx) 动态返回 prompts。
---@param path string 文件路径
---@param ability_dir string|nil 技能根目录
---@return table|nil hook 解析后的 hook 结构，失败返回 nil
---@return string|nil status `disabled` when the definition is intentionally disabled
function M.parse_lua_hook_file(path, ability_dir)
  local chunk, load_err = loadfile(path)
  if not chunk then
    return lua_hook_error(path, tostring(load_err))
  end

  local ok, spec = pcall(chunk)
  if not ok then
    return lua_hook_error(path, "execution failed: " .. tostring(spec))
  end

  if type(spec) ~= "table" then
    return lua_hook_error(path, "Lua hook must return a table")
  end

  if spec.enabled == false then
    return nil, "disabled"
  end

  if spec.prompts ~= nil then
    return lua_hook_error(path, "Lua hook must not define static 'prompts'; use render(ctx) only")
  end

  if type(spec.render) ~= "function" then
    return lua_hook_error(path, "Lua hook must define render(ctx) function")
  end

  local load = normalize_load(spec.load)
  if not load then
    return lua_hook_error(path, "load must be 'startup' or 'on_load'")
  end

  local scope = normalize_scope(spec.scope)
  if not scope then
    return lua_hook_error(path, "scope must be 'global', 'session', or 'cascade'")
  end

  local inject_at = normalize_inject_at(spec.inject_at)
  if not inject_at then
    return lua_hook_error(path, "inject_at must be 'pre' or 'post'")
  end

  if spec.filter ~= nil and type(spec.filter) ~= "table" and type(spec.filter) ~= "function" then
    return lua_hook_error(path, "filter must be a table, function(ctx), or nil")
  end

  if spec.opts ~= nil and type(spec.opts) ~= "table" then
    return lua_hook_error(path, "opts must be a table or nil")
  end

  local hook = {
    kind = "lua",
    event_name = M.extract_event_name(path),
    path = path,
    ability_dir = ability_dir,
    load = load,
    scope = scope,
    inject_at = inject_at,
    filter = spec.filter,
    opts = spec.opts or {},
    render = spec.render,
  }

  if hook.event_name == "" then
    return lua_hook_error(path, "invalid hook filename")
  end

  return hook
end

return M
