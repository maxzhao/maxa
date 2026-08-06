-- filepath: lua/maxa/runtime/history/title.lua
--- Phase-4 W2 title generation（历史服务操作族的一部分）。
---
--- 行为基线（只读参考，非依赖）：
--- `codecompanion._extensions/history/title_generator.lua`（should_generate /
--- generate：中文首标 / 英文刷新 prompt、1000 字符截断、"Deciding title..."/
--- "Refreshing title..." 反馈、refresh_every_n_prompts / max_refreshes / format_title）。
---
--- 本模块与证据的差异（maxa 形状）：
--- - 消息为 content-parts 数组（conversation 消息模型），文本提取拼接 text 部分；
--- - provider 通过注入的 `provider_resolver(ctx)` 解析，`provider.request(prompt, cb)`
---   的 callback 接收 (text, err)；同步 provider 直接返回最终结果，异步 provider
---   经 `opts.on_result` 回调送达（同步 provider 的 on_result 用 vim.schedule 模拟
---   异步派发）；
--- - 标题结果的应用（generation 守卫 + 持久化）由服务层 `Service:title` 完成，
---   本模块只负责"是否生成"与"生成什么"。
---
--- 本模块禁止加载 codecompanion.* / mcphub.* / lua/util/hooks/*（import-guard）。

local M = {}

local TitleGenerator = {}
TitleGenerator.__index = TitleGenerator

--- UTF-8 安全截断（不截断多字节字符）。
---@param str string
---@param max_bytes integer
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

--- 提取消息可读文本：content 字符串原样；content-parts 数组拼接 text 部分。
---@param msg any
---@return string|nil
local function message_text(msg)
  if type(msg) ~= "table" then
    return nil
  end
  local content = msg.content
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local out = {}
    for _, part in ipairs(content) do
      if type(part) == "table" and part.type == "text" then
        local t = part.text or part.content
        if type(t) == "string" then
          out[#out + 1] = t
        end
      end
    end
    if #out > 0 then
      return table.concat(out)
    end
  end
  return nil
end

--- 消息是否带 tag/reference/context 标记（对齐 title_generator 的排除逻辑：
--- opts.tag / opts.reference / opts.context_id；maxa 消息中 context_ref 内容部分
--- 即上下文注入标记）。
---@param msg table
---@return boolean
local function has_context_marker(msg)
  if type(msg.content) == "table" then
    for _, part in ipairs(msg.content) do
      if type(part) == "table" and part.type == "context_ref" then
        return true
      end
    end
  end
  local meta = msg._meta
  if type(meta) == "table" and (meta.tag or meta.reference or meta.context_id) then
    return true
  end
  return false
end

--- 构造标题生成器。
---@param opts {config?: table, ids?: table, provider_resolver?: fun(ctx: table): table|nil}
---@return table generator
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, TitleGenerator)
  self.config = opts.config or {}
  self.ids = opts.ids or require("maxa.runtime.history.ids")
  self.provider_resolver = opts.provider_resolver
  return self
end

--- 可见 user 消息计数（非空内容、无 tag/reference/context 标记）。
---@param messages table[]
---@return integer
function TitleGenerator:_count_user_messages(messages)
  if type(messages) ~= "table" then
    return 0
  end
  local n = 0
  for _, msg in ipairs(messages) do
    if type(msg) == "table" and msg.role == "user" then
      local text = message_text(msg)
      if text and vim.trim(text) ~= "" and not has_context_marker(msg) then
        n = n + 1
      end
    end
  end
  return n
end

--- 是否应生成/刷新标题（对齐 title_generator.should_generate）：
--- 无标题 -> 生成；refresh_every_n_prompts>0 且 user_message_count 整除
--- 且 refresh_count < max_refreshes -> 刷新。
---@param chat_state {title?: string, user_message_count?: integer, title_refresh_count?: integer, messages?: table[]}
---@return boolean should_generate
---@return boolean is_refresh
function TitleGenerator:should_generate(chat_state)
  chat_state = chat_state or {}
  if (self.config.title_provider or "auto") == "none" then
    return false, false
  end
  if not chat_state.title then
    return true, false
  end
  local gen_opts = self.config.title_generation_opts or {}
  local every = tonumber(gen_opts.refresh_every_n_prompts) or 0
  if every > 0 then
    local count = chat_state.user_message_count
    if count == nil and chat_state.messages ~= nil then
      count = self:_count_user_messages(chat_state.messages)
    end
    count = count or 0
    local refresh_count = tonumber(chat_state.title_refresh_count) or 0
    local max_refreshes = tonumber(gen_opts.max_refreshes) or 3
    if count > 0 and count % every == 0 and refresh_count < max_refreshes then
      return true, true
    end
  end
  return false, false
end

--- 处理 provider 回调结果。
---@param text string|nil
---@param err any
---@return table result {ok: boolean, title?: string, error?: string}
function TitleGenerator:_finalize(text, err)
  if err then
    return { ok = false, error = tostring(err) }
  end
  if type(text) ~= "string" or vim.trim(text) == "" then
    return { ok = false, error = "empty title result" }
  end
  return { ok = true, title = vim.trim(text) }
end

--- 构建生成 prompt（对齐 title_generator.lua：中文首标 / 英文刷新）。
---@param snapshot table|nil
---@param is_refresh boolean
---@return string|nil prompt 无有效消息时返回 nil
function TitleGenerator:_build_prompt(snapshot, is_refresh)
  local messages = (snapshot and snapshot.messages) or {}
  if is_refresh then
    -- 刷新：相关消息（user/assistant、非空、无标记），取最近 <=6 条，英文 prompt。
    local relevant = {}
    for _, msg in ipairs(messages) do
      if type(msg) == "table" and (msg.role == "user" or msg.role == "assistant") then
        local text = message_text(msg)
        if text and vim.trim(text) ~= "" and not has_context_marker(msg) then
          relevant[#relevant + 1] = { role = msg.role, text = text }
        end
      end
    end
    if #relevant == 0 then
      return nil
    end
    local recent_count = math.min(6, #relevant)
    local start_index = math.max(1, #relevant - recent_count + 1)
    local parts = {}
    for i = start_index, #relevant do
      local entry = relevant[i]
      local prefix = entry.role == "user" and "User" or "Assistant"
      local content = vim.trim(entry.text)
      if #content > 1000 then
        content = content:sub(1, 1000) .. " [truncated]"
      end
      parts[#parts + 1] = prefix .. ": " .. content
    end
    local conversation_context = table.concat(parts, "\n")
    if #conversation_context > 10000 then
      conversation_context = conversation_context:sub(1, 10000) .. "\n[conversation truncated]"
    end
    local original_title = (snapshot and snapshot.title) or "Unknown"
    return string.format(
      [[The conversation has evolved since the original title was generated. Based on the recent conversation below, generate a new concise title (max 5 words) that better reflects the current topic.

Original title: "%s"

Recent conversation:
%s

Generate a new title that captures the main topic of the recent conversation. Do not include any special characters or quotes. Your response should contain only the new title.

New Title:]],
      original_title,
      conversation_context
    )
  end

  -- 首标：可见 user 消息，取第一条（+ 最后一条不同时），中文 prompt。
  local valid = {}
  for _, msg in ipairs(messages) do
    if type(msg) == "table" and msg.role == "user" then
      local text = message_text(msg)
      if text and vim.trim(text) ~= "" and not has_context_marker(msg) then
        valid[#valid + 1] = vim.trim(text)
      end
    end
  end
  if #valid == 0 then
    return nil
  end
  local function truncate1000(s)
    if #s > 1000 then
      return utf8_safe_truncate(s, 1000) .. " [truncated]"
    end
    return s
  end
  local first = truncate1000(valid[1])
  if #valid == 1 then
    return string.format(
      [[根据以下用户消息生成简短标题（10 字以内）。
不要包含任何特殊字符或引号。
你的回复应该只包含标题本身，不要有其他文字。

用户消息：
%s

标题：]],
      first
    )
  end
  local last = truncate1000(valid[#valid])
  return string.format(
    [[根据以下用户消息生成简短标题（10 字以内）。

【对话起点】第一条用户消息：
%s

【当前焦点】最后一条用户消息：
%s

请生成一个标题，体现对话的主题或演进。
不要包含任何特殊字符或引号。
你的回复应该只包含标题本身，不要有其他文字。

标题：]],
    first,
    last
  )
end

--- 生成标题。
--- 同步 provider（request 内已调用 callback）直接返回最终结果；
--- 异步 provider 返回 { ok=true, pending=true }，结果经 opts.on_result 送达；
--- 同步 provider 的 on_result 用 vim.schedule 模拟异步派发（对齐
--- "simulate async via vim.schedule if the provider is synchronous"）。
---@param snapshot table 会话快照（messages 必填）
---@param opts {is_refresh?: boolean, refresh_count?: integer, interim?: fun(string), on_result?: fun(table)}
---@return table result {ok=true, title=string} | {ok=false, error=string} | {ok=true, pending=true}
function TitleGenerator:generate(snapshot, opts)
  opts = opts or {}
  local is_refresh = opts.is_refresh or false
  local prompt = self:_build_prompt(snapshot, is_refresh)
  if not prompt then
    return { ok = false, error = "no valid user messages" }
  end
  if opts.interim then
    opts.interim(is_refresh and "Refreshing title..." or "Deciding title...")
  end
  local provider = nil
  if self.provider_resolver then
    provider = self.provider_resolver({ snapshot = snapshot, is_refresh = is_refresh })
  end
  if not provider or type(provider.request) ~= "function" then
    return { ok = false, error = "no title provider" }
  end
  local returned = false
  local done = false
  local result = nil
  local callback = function(text, err)
    done = true
    result = self:_finalize(text, err)
    if opts.on_result and returned then
      -- 异步路径：request 返回后回调才到达，直接派发。
      opts.on_result(result)
    end
  end
  provider.request(prompt, callback)
  returned = true
  if done then
    -- 同步 provider：最终结果同步可用；on_result 经 vim.schedule 模拟异步派发。
    if opts.on_result then
      vim.schedule(function()
        opts.on_result(result)
      end)
    end
    return result
  end
  return { ok = true, pending = true }
end

return M
