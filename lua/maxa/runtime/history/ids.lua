-- filepath: lua/maxa/runtime/history/ids.lua
--- Phase-4 history save_id / title / time utilities (W1 storage layer).
---
--- 行为基线（只读参考，非依赖）：`codecompanion._extensions.history/utils.lua`
--- `generate_save_id`（utils.lua:12-72）与 `util/mcphub/cc_history/history_core.lua`
--- `make_unsavable_save_id` / `is_unsavable_save_id`（history_core.lua:41-72）、
--- `get_chat_title`（history_core.lua:357-371）、`format_save_id_time`
--- （history_core.lua:304-318）。本模块按 maxa 消息形状（content-parts 数组）
--- 扩展了标题提取：content 为字符串时沿用证据逻辑；为 content-parts 数组时
--- 拼接 text 部分。save_id 形状保持证据兼容（时间戳+毫秒+计数器+随机后缀），
--- 文件系统安全且按时间可排序。

local M = {}

local save_id_counter = 0

local function sanitize_prefix(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  value = value:gsub("[^%w_-]", "_")
  value = value:gsub("_+", "_")
  value = value:gsub("^_+", ""):gsub("_+$", "")
  if value == "" then
    return nil
  end
  return value
end

local function random_suffix()
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local out = {}
  for _ = 1, 6 do
    local idx = math.random(1, #chars)
    out[#out + 1] = chars:sub(idx, idx)
  end
  return table.concat(out)
end

local function exists(history_dir, save_id)
  if type(history_dir) ~= "string" or history_dir == "" then
    return false
  end
  return vim.fn.filereadable(history_dir .. "/chats/" .. save_id .. ".json") == 1
end

--- Generate a collision-resistant, filesystem-safe, human-sortable save_id.
--- 形状：`[<prefix>_]YYYYMMDD_HHMMSS_<ms>_<counter>_<random6>`（对齐证据）。
---@param opts? {prefix?: string, history_dir?: string, max_attempts?: integer}
---@return string save_id
function M.generate_save_id(opts)
  opts = opts or {}
  local max_attempts = opts.max_attempts or 32
  local clean_prefix = sanitize_prefix(opts.prefix)
  for _ = 1, max_attempts do
    local now_ms = math.floor((vim.uv and vim.uv.now and vim.uv.now() or os.time() * 1000))
    save_id_counter = (save_id_counter + 1) % 1000000
    local body =
      string.format("%s_%03d_%06d_%s", os.date("%Y%m%d_%H%M%S"), now_ms % 1000, save_id_counter, random_suffix())
    local save_id = clean_prefix and (clean_prefix .. "_" .. body) or body
    if not exists(opts.history_dir, save_id) then
      return save_id
    end
  end
  -- 防御性兜底：加上 hrtime 再次去重。
  local hr = (vim.uv and vim.uv.hrtime and vim.uv.hrtime()) or math.random(1000000000)
  local fallback = string.format("%s_%s_%s", os.date("%Y%m%d_%H%M%S"), tostring(hr), random_suffix())
  return clean_prefix and (clean_prefix .. "_" .. fallback) or fallback
end

local UNSAVABLE_SAVE_ID_PREFIX = "_cc_history_unsavable_"

--- 构造受控的“不可保存” save_id：含 `/`，会被路径安全校验拒绝，从而永不落盘。
--- scratch/rescue 等临时会话使用；显式保存时才生成正规 save_id。
---@param kind? string 短命名空间，如 "scratch" / "rescue"
---@return string
function M.make_unsavable_save_id(kind)
  kind = tostring(kind or "temp")
  kind = kind:gsub("[^%w_-]", "_")
  local suffix = M.generate_save_id({ prefix = kind })
  return UNSAVABLE_SAVE_ID_PREFIX .. kind .. "/" .. suffix
end

--- 判断 save_id 是否为受控的不可保存 ID（前缀匹配且含路径分隔符，对齐证据语义）。
---@param save_id any
---@param kind? string 可选命名空间
---@return boolean
function M.is_unsavable_save_id(save_id, kind)
  if type(save_id) ~= "string" then
    return false
  end
  local prefix = UNSAVABLE_SAVE_ID_PREFIX
  if kind ~= nil then
    kind = tostring(kind):gsub("[^%w_-]", "_")
    prefix = prefix .. kind .. "/"
  end
  return vim.startswith(save_id, prefix) and save_id:match("[/\\]") ~= nil
end

local function truncate_content(content, max_length)
  max_length = max_length or 200
  if not content or #content <= max_length then
    return content
  end
  return content:sub(1, max_length) .. "..."
end

--- 提取消息的可读文本：content 字符串原样；content-parts 数组拼接 text 部分。
--- text part 形状为 `{ type="text", text=... }`（conversation.text_part）。
---@param content any
---@return string|nil
local function content_text(content)
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

--- 会话标题：第一条可见 user 消息文本，换行折叠、截断 100 字符，缺省 "Untitled"。
---@param messages table|nil
---@return string
function M.get_chat_title(messages)
  if not messages then
    return "Untitled"
  end
  for _, msg in ipairs(messages) do
    if type(msg) == "table" and msg.role == "user" then
      local text = content_text(msg.content)
      if text and text ~= "" then
        local title = text:gsub("\n", " "):gsub("%s+", " ")
        return truncate_content(title, 100)
      end
    end
  end
  return "Untitled"
end

--- 格式化 save_id 内嵌时间戳（save_id 前 15 位：YYYYMMDD_HHMMSS）。
---@param save_id string
---@return string
function M.format_save_id_time(save_id)
  if not save_id or #save_id < 15 then
    return save_id
  end
  local year = save_id:sub(1, 4)
  local month = save_id:sub(5, 6)
  local day = save_id:sub(7, 8)
  local hour = save_id:sub(10, 11)
  local min = save_id:sub(12, 13)
  local sec = save_id:sub(14, 15)
  return string.format("%s-%s-%s %s:%s:%s", year, month, day, hour, min, sec)
end

return M
