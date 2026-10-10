-- Unified Ability/context loader utilities.
-- 1. Standard SKILL.md frontmatter/body parsing
-- 2. chat/agent 获取
-- 3. context 消息插入（tool_call 之前）
-- 4. context 去重
-- 5. Context-path whitelisting and Markdown sanitization

local cc_config = require("maxa.config")

local M = {}

-- Both read and load share file precedence and absence-only resource fallback.
function M.resolve_reference(context, reference)
  local catalog = require("maxa.abilities.catalog")
  local name, target, parse_err = catalog.parse_reference(reference)
  if not name then
    return nil, parse_err
  end
  if not context or type(context.cwd) ~= "string" or context.cwd == "" then
    return nil, "Exact workspace context is unavailable for Ability reference"
  end
  if target:sub(1, 1) == "/" then
    local entry, file_err, reason = catalog.resolve_file_reference(reference, context.cwd)
    if entry then
      return { ability_name = name, target = target, file = entry }
    end
    if reason ~= "not_found" then
      return nil, file_err
    end
  end
  local chat = M.get_chat_and_agent(context)
  if not chat then
    return nil, "Exact Chat/workspace context is unavailable for Ability reference"
  end
  local resource, err = require("maxa.session.abilities").resolve_resource(chat, context.cwd, name, target)
  if not resource then
    return nil, err
  end
  return { ability_name = name, target = target, resource = resource }
end

local function ensure_trailing_slash(path)
  if not path or path == "" then
    return nil
  end
  if path:sub(-1) == "/" then
    return path
  end
  return path .. "/"
end

local function path_has_prefix(path, prefix)
  return prefix and path:sub(1, #prefix) == prefix
end

local function mark_stripped(stripped, key)
  stripped[key] = (stripped[key] or 0) + 1
end

local function stripped_to_list(stripped)
  local items = {}
  for key, _ in pairs(stripped) do
    table.insert(items, key)
  end
  table.sort(items)
  return items
end

local function extract_first_heading(body)
  for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
    local heading = line:match("^%s*#+%s+(.+)$")
    if heading then
      return vim.trim(heading)
    end
  end
  return nil
end

local function has_matching_top_heading(body, title)
  if not title or title == "" then
    return false
  end

  for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
    if not line:match("^%s*$") then
      local heading = line:match("^%s*#+%s+(.+)$")
      return heading ~= nil and vim.trim(heading) == vim.trim(title)
    end
  end

  return false
end

local function strip_html_comments(content, stripped)
  local sanitized, count = content:gsub("<!%-%-[%z\1-\255]-%-%->", "")
  if count > 0 then
    mark_stripped(stripped, "html_comments")
  end
  return sanitized
end

local function strip_lines(content, predicate)
  local output = {}
  local removed = 0
  local in_code_fence = false

  for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
    local trimmed = vim.trim(line)
    if trimmed:match("^```") or trimmed:match("^~~~") then
      in_code_fence = not in_code_fence
      table.insert(output, line)
    elseif (not in_code_fence) and predicate(line, trimmed) then
      removed = removed + 1
    else
      table.insert(output, line)
    end
  end

  return table.concat(output, "\n"), removed
end

local function normalize_body(body)
  body = body:gsub("\r\n", "\n")
  body = body:gsub("^%s+", "")
  body = body:gsub("%s+$", "")
  body = body:gsub("\n\n\n+", "\n\n")
  return body
end

--- 解析 SKILL.md 格式的 frontmatter 和正文
--- frontmatter 格式：
--- ```
--- ---
--- name: skill-name
--- description: 简短描述
--- ---
--- 正文内容...
--- ```
---
--- @param content string 文件的完整内容
--- @return table|nil frontmatter {name, description, ...} 或 nil（无 frontmatter）
--- @return string instructions 正文部分（去除 frontmatter 后的内容）
function M.parse_frontmatter(content)
  local normalized = content:gsub("\r\n", "\n")
  local frontmatter = nil
  local instructions = normalized

  if not normalized:match("^%-%-%-\n") then
    return nil, instructions
  end

  local _, fm_end = normalized:find("\n%-%-%-\n", 4)
  if not fm_end then
    _, fm_end = normalized:find("\n%-%-%-$", 4)
  end

  if not fm_end then
    return nil, instructions
  end

  local fm_text = normalized:sub(4, fm_end - 3)
  frontmatter = {}

  local current_list_key = nil
  for line in fm_text:gmatch("[^\n]+") do
    local list_value = line:match("^%s+%-%s+(.+)$")
    if list_value and current_list_key then
      list_value = list_value:gsub("^['\"]", ""):gsub("['\"]$", "")
      table.insert(frontmatter[current_list_key], list_value)
    else
      local key, value = line:match("^(%w[%w_%-]*):%s*(.+)$")
      if key and value then
        value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
        frontmatter[key] = value
        current_list_key = nil
      else
        local key_only = line:match("^(%w[%w_%-]*):%s*$")
        if key_only then
          frontmatter[key_only] = {}
          current_list_key = key_only
        else
          current_list_key = nil
        end
      end
    end
  end

  instructions = normalized:sub(fm_end + 1)
  instructions = instructions:gsub("^[\n]+", "")

  return frontmatter, instructions
end

--- Classify Markdown paths accepted by unified `load`.
--- @param absolute_path string 绝对路径
--- @return table|nil info {kind, scope, absolute_path}
--- @return string|nil err
function M.classify_context_path(absolute_path, project_root)
  if type(absolute_path) ~= "string" or absolute_path == "" then
    return nil, "load: path is required"
  end

  if not absolute_path:lower():match("%.md$") then
    return nil, string.format(
      "load: Only Markdown files are supported: %s",
      absolute_path
    )
  end

  if type(project_root) ~= "string" or project_root == "" then
    return nil, "load: exact project working directory is unavailable"
  end
  local project_maxa = ensure_trailing_slash(project_root .. "/.maxa")
  local project_maxa_abilities = ensure_trailing_slash(project_root .. "/.maxa/abilities")
  local project_tasks = ensure_trailing_slash(project_root .. "/.maxa/tasks")
  local project_justfile_md = project_root .. "/justfile.md"
  local global_abilities = ensure_trailing_slash(vim.fn.stdpath("config") .. "/abilities")

  if path_has_prefix(absolute_path, project_maxa_abilities) then
    return { kind = "ability", scope = "project", absolute_path = absolute_path }, nil
  end

  if path_has_prefix(absolute_path, global_abilities) then
    return { kind = "ability", scope = "global", absolute_path = absolute_path }, nil
  end

  if path_has_prefix(absolute_path, project_tasks) then
    return { kind = "task", scope = "project", absolute_path = absolute_path }, nil
  end

  if absolute_path == project_justfile_md then
    return { kind = "justfile_guide", scope = "project", absolute_path = absolute_path }, nil
  end

  if path_has_prefix(absolute_path, project_maxa) then
    return { kind = "knowledge", scope = "project", absolute_path = absolute_path }, nil
  end

  return nil,
    string.format(
      "load: File `%s` is not in an allowed location. Only project `.maxa/**/*.md`, project `.maxa/abilities/**/*.md`, project root `justfile.md`, and global `abilities/**/*.md` are supported.",
      absolute_path
    )
end

--- Derive a display title for unified context-file loading.
--- @param frontmatter table|nil
--- @param body string
--- @param absolute_path string
--- @return string
function M.derive_context_title(frontmatter, body, absolute_path)
  if frontmatter then
    if frontmatter.name and frontmatter.name ~= "" then
      return frontmatter.name
    end
    if frontmatter.title and frontmatter.title ~= "" then
      return frontmatter.title
    end
  end

  local heading = extract_first_heading(body)
  if heading and heading ~= "" then
    return heading
  end

  return vim.fn.fnamemodify(absolute_path, ":t:r")
end

--- Sanitize an allowed Markdown document for unified `load`.
--- @param content string 文件完整内容
--- @param file_info table classify_context_path 的输出
--- @return table sanitized {body, display_name, description, kind, stripped, suppress_title}
--- @return string|nil err
function M.sanitize_context_markdown(content, file_info)
  local frontmatter, body = M.parse_frontmatter(content)
  local stripped = {}

  if frontmatter then
    mark_stripped(stripped, "frontmatter")
  end

  body = strip_html_comments(body, stripped)

  if file_info.kind == "knowledge" then
    local removed
    body, removed = strip_lines(body, function(_, trimmed)
      return trimmed:match("^[A-Za-z0-9_%-][A-Za-z0-9_%- ]*::%s*.*$") ~= nil
    end)
    if removed > 0 then
      mark_stripped(stripped, "obsidian_inline_fields")
    end
  end

  local display_name = M.derive_context_title(frontmatter, body, file_info.absolute_path)

  if file_info.kind == "task" and frontmatter and frontmatter.name and frontmatter.name ~= "" then
    if not has_matching_top_heading(body, frontmatter.name) then
      body = string.format("### %s\n\n%s", frontmatter.name, body)
      mark_stripped(stripped, "task_title_promoted")
    end
  end

  body = normalize_body(body)
  if body == "" then
    return nil, string.format("load: File `%s` has no usable body after sanitization", file_info.absolute_path)
  end

  return {
    body = body,
    display_name = display_name,
    description = frontmatter and frontmatter.description or nil,
    kind = file_info.kind,
    stripped = stripped_to_list(stripped),
    suppress_title = has_matching_top_heading(body, display_name),
  }, nil
end

--- 检查会话中是否已存在相同 context.id 的消息
--- @param messages table MaxaAI 会话消息列表
--- @param context_id string context item 的 id
--- @return boolean 是否已存在
function M.has_context_item(messages, context_id)
  if not messages or type(messages) ~= "table" then
    return false
  end
  for _, msg in ipairs(messages) do
    if msg.context and msg.context.id == context_id then
      return true
    end
  end
  return false
end

local function extract_argument_field(arguments, field)
  if not arguments then
    return nil
  end
  local args = arguments
  if type(args) == "string" then
    local ok, decoded = pcall(vim.json.decode, args)
    if not ok or type(decoded) ~= "table" then
      return nil
    end
    args = decoded
  end
  if type(args) ~= "table" then
    return nil
  end
  return args[field]
end

local function tool_result_call_id(msg)
  return msg and ((msg.tools and msg.tools.call_id) or msg.tool_call_id) or nil
end

local function is_tool_error(msg)
  if not msg or msg.role ~= "tool" then
    return false
  end
  if msg.tools and msg.tools.is_error then
    return true
  end
  return type(msg.content) == "string" and msg.content:match("^%*%*`[^`]+` Tool%*%*: Failed") ~= nil
end

local function argument_matches(value, expected_values, normalizer)
  if normalizer then
    value = normalizer(value)
  end
  if type(expected_values) == "table" then
    for _, expected in ipairs(expected_values) do
      if value == (normalizer and normalizer(expected) or expected) then
        return true
      end
    end
    return false
  end
  return value == (normalizer and normalizer(expected_values) or expected_values)
end

local function has_successful_tool_call(messages, tool_name, argument_field, expected_values, argument_normalizer)
  if not messages or type(messages) ~= "table" then
    return false
  end

  local ok_wrapped, wrapped_calls = pcall(require, "maxa.interactions.chat.tools.builtin.runtime.wrapped_tool_calls")
  local matching_call_ids = {}
  for _, msg in ipairs(messages) do
    if (msg.role == "llm" or msg.role == "assistant") and msg.tools and msg.tools.calls then
      if ok_wrapped then
        for _, semantic in ipairs(wrapped_calls.iter_message_calls(msg)) do
          if semantic.call_id and semantic.tool_name == tool_name then
            local value = semantic.args and semantic.args[argument_field]
            if argument_matches(value, expected_values, argument_normalizer) then
              matching_call_ids[semantic.call_id] = true
            end
          end
        end
      else
        for _, call in ipairs(msg.tools.calls) do
          local func = call["function"]
          local call_id = call.call_id or call.id
          if func and call_id and func.name == tool_name then
            local value = extract_argument_field(func.arguments, argument_field)
            if argument_matches(value, expected_values, argument_normalizer) then
              matching_call_ids[call_id] = true
            end
          end
        end
      end
    elseif msg.role == "tool" then
      local call_id = tool_result_call_id(msg)
      if call_id and matching_call_ids[call_id] and not is_tool_error(msg) then
        return true
      end
    end
  end

  return false
end

local function find_latest_context_contents(messages, context_ids)
  local result = {}
  if not messages or type(messages) ~= "table" then
    return result
  end

  local remaining = 0
  for _ in pairs(context_ids or {}) do
    remaining = remaining + 1
  end
  if remaining == 0 then
    return result
  end

  for i = #messages, 1, -1 do
    local msg = messages[i]
    local context_id = msg.context and msg.context.id
    if context_id and context_ids[context_id] and result[context_id] == nil then
      result[context_id] = msg.content or ""
      remaining = remaining - 1
      if remaining == 0 then
        break
      end
    end
  end

  return result
end

--- force_reload 时判断当前将注入的 context 是否与最近一次成功加载内容一致。
--- 一致时调用方应跳过插入，提示继续参考之前成功加载的内容。
--- @param messages table[] MaxaAI 会话消息列表
--- @param opts table {tool_name, argument_field, argument_value|argument_values, context_id, context_message}
--- @return boolean unchanged
function M.force_reload_unchanged(messages, opts)
  opts = opts or {}
  local context_id = opts.context_id
  local context_message = opts.context_message
  if not context_id or not context_message then
    return false
  end
  if not has_successful_tool_call(
    messages,
    opts.tool_name,
    opts.argument_field,
    opts.argument_values or opts.argument_value,
    opts.argument_normalizer
  ) then
    return false
  end

  local previous = find_latest_context_contents(messages, { [context_id] = true })[context_id]
  if previous == nil then
    return false
  end

  return previous == (context_message.content or "")
end

--- 从请求对象获取 chat 和 agent
--- @param context table 请求对象
--- @return table|nil chat Maxa AI chat 对象
--- @return table|nil agent MaxaAI agent 对象
function M.get_chat_and_agent(context)
  local agent = context and context.caller and context.caller.maxa_ai or nil
  local chat = (context and context.chat) or (agent and agent.chat) or nil
  if type(chat) ~= "table" then
    return nil, agent
  end
  return chat, agent
end

--- 获取 tool_call_id
--- @param agent table|nil agent 对象
--- @return string|nil tool_call_id
function M.get_tool_call_id(agent)
  if agent and agent.tool and agent.tool.function_call then
    return agent.tool.function_call.call_id or agent.tool.function_call.id
  end
  return nil
end

--- 将 context 消息延迟到当前工具批次完成后追加。
--- 这确保消息顺序为：[..., tool_calls(llm), tool_result, context(user)]，
--- 避免在 handler 执行期间把 context 插入 tool_call 与 tool_result 之间。
--- @param chat table Maxa AI chat 对象
--- @param agent table|nil agent 对象（保留参数以兼容调用点）
--- @param message table 要插入的消息
function M.insert_context_message(chat, agent, message)
  local injector = require("maxa.interactions.chat.tools.builtin.runtime.context_injector")
  if not injector.enqueue(chat, message) then
    error("exact Chat context is unavailable for deferred insertion")
  end
end

--- 构建标准的 context 消息
--- @param opts table 选项
---   - content: string 消息内容
---   - context_id: string context 的唯一 ID
---   - tag: string _meta.tag 值（如 "skill", "context_file"）
---   - title: string|nil 可选的标题（会加在 content 前面）
--- @return table message MaxaAI 消息格式
function M.build_context_message(opts)
  local content = opts.content
  if opts.title then
    content = string.format("### %s\n\n%s", opts.title, content)
  end

  return {
    role = cc_config.constants.USER_ROLE,
    content = content,
    context = { id = opts.context_id },
    _meta = { tag = opts.tag },
    opts = { visible = false },
  }
end

return M
