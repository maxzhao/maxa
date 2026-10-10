local client = require("maxa.http")
local config = require("maxa.config")
local log = require("maxa.session.history.log")
local schema = require("maxa.schema")

--- UTF-8 safe truncation (won't break multi-byte characters)
---@param str string
---@param max_bytes number
---@return string
local function utf8_safe_truncate(str, max_bytes)
  if not str or #str <= max_bytes then
    return str
  end
  local pos = max_bytes
  while pos > 0 do
    local byte = str:byte(pos)
    if byte < 128 or byte >= 192 then
      break
    end
    pos = pos - 1
  end
  return str:sub(1, pos)
end

--- Check if a message is a system rule/config message
---@param msg table
---@return boolean
local function is_system_rule_message(msg)
  if not msg.content then
    return false
  end
  local content = msg.content
  local rule_patterns = {
    "^# 项目规则",
    "^# Maxa System Prompt",
    "## 环境",
    "## 执行协议",
    "## Execution Protocol",
    "## Role & Identity",
    "## 🔒 强制执行前检查协议",
  }
  for _, pattern in ipairs(rule_patterns) do
    if content:match(pattern) then
      return true
    end
  end
  if #content > 3000 then
    local section_count = 0
    for _ in content:gmatch("\n##+ ") do
      section_count = section_count + 1
    end
    if section_count >= 5 then
      return true
    end
  end
  return false
end

local CONSTANTS = {
    STATUS_ERROR = "error",
    STATUS_SUCCESS = "success",
}

local ERROR_MESSAGE_KEYS = {
    "error",
    "body",
    "response",
    "stderr",
    "output",
    "message",
    "detail",
}

---@param value any
---@param seen? table<table, boolean>
---@param depth? number
---@return string|nil
local function extract_error_message(value, seen, depth)
    depth = depth or 0
    if depth > 6 or value == nil then
        return nil
    end

    if type(value) == "string" then
        local text = vim.trim(value)
        if text == "" or text == "{}" then
            return nil
        end
        if text:match("^[%[{]") then
            local ok, decoded = pcall(vim.json.decode, text)
            if ok then
                local decoded_message = extract_error_message(decoded, seen, depth + 1)
                if decoded_message then
                    return decoded_message
                end
            end
        end
        return text
    end

    if type(value) ~= "table" then
        return tostring(value)
    end

    seen = seen or {}
    if seen[value] then
        return nil
    end
    seen[value] = true

    for _, key in ipairs(ERROR_MESSAGE_KEYS) do
        local message = extract_error_message(value[key], seen, depth + 1)
        if message then
            return message
        end
    end

    local ok, inspected = pcall(vim.inspect, value)
    if ok and type(inspected) == "string" and inspected ~= "{}" then
        return inspected
    end
    return nil
end

---@param value any
---@param fallback? string
---@return string
local function format_error(value, fallback)
    return extract_error_message(value) or fallback or "Unknown error"
end

---@class MaxaAI.History.TitleGenerator
---@field opts MaxaAI.History.Opts
local TitleGenerator = {}

---@param opts MaxaAI.History.Opts
---@return MaxaAI.History.TitleGenerator
function TitleGenerator.new(opts)
    local self = setmetatable({}, {
        __index = TitleGenerator,
    })
    self.opts = opts
    return self --[[@as MaxaAI.History.TitleGenerator]]
end

---Count user messages in chat (excluding tagged/reference messages)
---@param chat MaxaAI.History.Chat
---@return number
function TitleGenerator:_count_user_messages(chat)
    if not chat.messages or #chat.messages == 0 then
        return 0
    end

    local user_messages = vim.tbl_filter(function(msg)
        return msg.role == config.constants.USER_ROLE
    end, chat.messages)

    local actual_user_messages = vim.tbl_filter(function(msg)
        local has_content = msg.content and vim.trim(msg.content) ~= ""
        return has_content
            and not (msg.opts and msg.opts.tag)
            and not (msg.opts and (msg.opts.reference or msg.opts.context_id))
    end, user_messages)

    return #actual_user_messages
end

---Check if title should be generated or refreshed
---@param chat MaxaAI.History.Chat
---@return boolean should_generate, boolean is_refresh
function TitleGenerator:should_generate(chat)
    if not self.opts.auto_generate_title then
        return false, false
    end

    if not chat.opts.title then
        return true, false
    end

    local refresh_opts = self.opts.title_generation_opts or {}
    if refresh_opts.refresh_every_n_prompts and refresh_opts.refresh_every_n_prompts > 0 then
        local user_message_count = self:_count_user_messages(chat)
        local refresh_count = chat.opts.title_refresh_count or 0
        local max_refreshes = refresh_opts.max_refreshes or 3

        if
            user_message_count > 0
            and user_message_count % refresh_opts.refresh_every_n_prompts == 0
            and refresh_count < max_refreshes
        then
            return true, true
        end
    end

    return false, false
end

---Generate title for chat
---@param chat MaxaAI.History.Chat The chat object containing messages and ID
---@param callback fun(title: string|nil) Callback function to receive the generated title
---@param is_refresh? boolean Whether this is a title refresh (default: false)
function TitleGenerator:generate(chat, callback, is_refresh)
    if not self.opts.auto_generate_title then
        return
    end

    is_refresh = is_refresh or false

    -- Early return for disabled auto-generation, but allow refresh if explicitly requested
    if not is_refresh and chat.opts.title then
        log:trace("Using existing chat title: %s", chat.opts.title)
        return callback(chat.opts.title)
    end

    -- Return early if no messages or messages is nil
    if not chat.messages or #chat.messages == 0 then
        log:trace("No messages found in chat, skipping title generation")
        return callback(nil)
    end

    if is_refresh then
        -- For refresh: use original logic with recent messages (English prompt)
        local relevant_messages = vim.tbl_filter(function(msg)
            local has_content = msg.content and vim.trim(msg.content) ~= ""
            local is_relevant_role = msg.role == config.constants.USER_ROLE or msg.role == config.constants.LLM_ROLE
            local not_tagged = not (msg.opts and (msg.opts.tag or msg.opts.reference or msg.opts.context_id))
            return has_content and is_relevant_role and not_tagged
        end, chat.messages)

        if #relevant_messages == 0 then
            return callback(nil)
        end

        callback("Refreshing title...")

        local recent_count = math.min(6, #relevant_messages)
        local start_index = math.max(1, #relevant_messages - recent_count + 1)
        local recent_messages = {}
        for i = start_index, #relevant_messages do
            local msg = relevant_messages[i]
            local role_prefix = msg.role == config.constants.USER_ROLE and "User" or "Assistant"
            local content = vim.trim(msg.content)
            if #content > 1000 then
                content = content:sub(1, 1000) .. " [truncated]"
            end
            table.insert(recent_messages, role_prefix .. ": " .. content)
        end

        local conversation_context = table.concat(recent_messages, "\n")
        if #conversation_context > 10000 then
            conversation_context = conversation_context:sub(1, 10000) .. "\n[conversation truncated]"
        end

        local original_title = chat.opts.title or "Unknown"
        local prompt = string.format(
            [[The conversation has evolved since the original title was generated. Based on the recent conversation below, generate a new concise title (max 5 words) that better reflects the current topic.

Original title: "%s"

Recent conversation:
%s

Generate a new title that captures the main topic of the recent conversation. Do not include any special characters or quotes. Your response should contain only the new title.

New Title:]],
            original_title,
            conversation_context
        )
        return self:_make_adapter_request(chat, prompt, callback)
    end

    -- Initial title generation: use first + last valid user messages with Chinese prompt
    -- Find all valid user messages (excluding system rules, tagged, reference, context)
    local valid_user_messages = {}
    for _, msg in ipairs(chat.messages) do
        if msg.role == config.constants.USER_ROLE then
            local has_content = msg.content and vim.trim(msg.content) ~= ""
            local not_tagged = not (msg.opts and (msg.opts.tag or msg.opts.reference or msg.opts.context_id))
            local not_system_rule = not is_system_rule_message(msg)
            if has_content and not_tagged and not_system_rule then
                table.insert(valid_user_messages, msg)
            end
        end
    end

    if #valid_user_messages == 0 then
        return callback(nil)
    end

    callback("Deciding title...")

    local first_user_msg = valid_user_messages[1]
    local last_user_msg = valid_user_messages[#valid_user_messages]

    local first_content = vim.trim(first_user_msg.content)
    if #first_content > 1000 then
        first_content = utf8_safe_truncate(first_content, 1000) .. " [truncated]"
    end

    local prompt
    if first_user_msg == last_user_msg then
        prompt = string.format(
            [[根据以下用户消息生成简短标题（10 字以内）。
不要包含任何特殊字符或引号。
你的回复应该只包含标题本身，不要有其他文字。

用户消息：
%s

标题：]],
            first_content
        )
    else
        local last_content = vim.trim(last_user_msg.content)
        if #last_content > 1000 then
            last_content = utf8_safe_truncate(last_content, 1000) .. " [truncated]"
        end
        prompt = string.format(
            [[根据以下用户消息生成简短标题（10 字以内）。

【对话起点】第一条用户消息：
%s

【当前焦点】最后一条用户消息：
%s

请生成一个标题，体现对话的主题或演进。
不要包含任何特殊字符或引号。
你的回复应该只包含标题本身，不要有其他文字。

标题：]],
            first_content,
            last_content
        )
    end

    self:_make_adapter_request(chat, prompt, callback)
end

---@param chat MaxaAI.History.Chat
---@param prompt string
---@param callback fun(title: string|nil, error_msg: string|nil)
function TitleGenerator:_make_adapter_request(chat, prompt, callback)
    log:trace("Making adapter request for title generation")
    local opts = self.opts.title_generation_opts or {}
    local adapter = vim.deepcopy(chat.adapter) --[[@as MaxaAI.HTTPAdapter]]
    local settings = vim.deepcopy(chat.settings)
    local adapters = require("maxa.adapters")
    local presets, selected
    if opts.preset or opts.default_role then
        presets = require("maxa.mcphub.native_servers.config")
        local err
        if opts.preset then selected, err = presets.get_preset(opts.preset, "chat")
        else selected, err = presets.get_default(opts.default_role) end
        assert(selected, err)
    end
    if opts.adapter or (selected and not selected.inherit) then
        adapter = adapters.resolve(opts.adapter or selected.adapter)
    end
    local model = opts.model or (not opts.adapter and selected and selected.model)
    local thinking_mode = opts.thinking_mode or (selected and selected.thinking_mode)
    local temperature = opts.temperature
    if temperature == nil and selected then temperature = selected.temperature end
    if model or thinking_mode or temperature ~= nil then
        local overrides = thinking_mode and (presets and presets.get_reasoning_effort_settings(adapter, thinking_mode)
            or { ["reasoning.effort"] = thinking_mode }) or {}
        if model then overrides.model = model end
        if temperature ~= nil then overrides.temperature = temperature end
        settings = schema.get_default(adapter, overrides)
    end
    settings = vim.deepcopy(adapter:map_schema_to_params(settings))
    settings.opts.stream = false
    local payload = {
        messages = adapter:map_roles({
            { role = "user", content = prompt },
        }),
    }
    local finished = false
    local function finish(title)
        if finished then
            return
        end
        finished = true
        callback(title)
    end
    local function fail(error_value)
        if finished then
            return
        end
        local message = format_error(error_value, "Unknown error")
        log:error("Title generation error: %s", message)
        vim.notify("Error while generating title: " .. message)
        finish(nil)
    end

    client.new({ adapter = settings }):request(payload, {
        callback = function(err, data, _adapter)
            if err and not (type(err) == "table" and err.stderr == "{}") then
                return fail(err)
            end
            if data then
                local result = nil
                if _adapter.handlers.chat_output then
                    result = _adapter.handlers.chat_output(_adapter, data)
                else
                   result = adapters.call_handler(_adapter, "parse_chat", data)
                end
                if result and result.status then
                    if result.status == CONSTANTS.STATUS_SUCCESS then
                        local title = vim.trim(result.output.content or "")
                        log:trace("Successfully generated title: %s", title)
                        return finish(title)
                    elseif result.status == CONSTANTS.STATUS_ERROR then
                        return fail(result.output)
                    end
                end
            end
        end,
    }, {
        silent = true,
    })
end

return TitleGenerator
