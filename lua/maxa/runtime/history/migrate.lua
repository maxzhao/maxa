-- filepath: lua/maxa/runtime/history/migrate.lua
--- Phase-4 legacy chat file migration (W1): missing `schema_version` files are
--- legacy input; parse ONLY known legacy fields, normalize `refs` -> `context_items`
--- exactly once, sanitize tool-argument JSON + UTF-8, back up the original, then
--- write the v1 envelope atomically (original file kept; `.bak` preserved).
---
--- 契约（specs session-history §Migration contract / runtime-fixture-contract）：
--- - 版本 1 直接加载；版本 > 1 -> `runtime-upgrade-required`，不重写；
--- - corrupt/未知结构 -> `corrupt`（隔离：不重写、不删除，报告 path/reason）；
--- - 备份：写 `<name>.json.bak` 后原子写 v1；两个写失败都报 `write_failed`，
---   原始文件保持原样（本 wave 不删除原始文件）。
--- - 消毒函数对齐证据 `codecompanion/_extensions/history/storage.lua:40-169`
---   （只读参考，非依赖）；迁移 reader 只接受显式 legacy 路径输入，绝不扫描
---   `.supermax`。

local storage_mod = require("maxa.runtime.history.storage")

local M = {}

--- Replace non-UTF-8 bytes with U+FFFD (replacement character).
--- 对齐证据 storage.lua:40-119。
---@param str string
---@return string
local function sanitize_utf8(str)
  if not str or str == "" then
    return str
  end
  if not str:match("[\128-\255]") then
    return str
  end
  local result = {}
  local i = 1
  local len = #str
  while i <= len do
    local byte = str:byte(i)
    if byte < 128 then
      result[#result + 1] = str:sub(i, i)
      i = i + 1
    elseif byte >= 194 and byte <= 223 then
      if i + 1 <= len then
        local b2 = str:byte(i + 1)
        if b2 >= 128 and b2 <= 191 then
          result[#result + 1] = str:sub(i, i + 1)
          i = i + 2
        else
          result[#result + 1] = "\xEF\xBF\xBD"
          i = i + 1
        end
      else
        result[#result + 1] = "\xEF\xBF\xBD"
        i = i + 1
      end
    elseif byte >= 224 and byte <= 239 then
      if i + 2 <= len then
        local b2, b3 = str:byte(i + 1), str:byte(i + 2)
        if b2 >= 128 and b2 <= 191 and b3 >= 128 and b3 <= 191 then
          if byte == 224 and b2 < 160 then
            result[#result + 1] = "\xEF\xBF\xBD"
            i = i + 1
          elseif byte == 237 and b2 > 159 then
            result[#result + 1] = "\xEF\xBF\xBD"
            i = i + 1
          else
            result[#result + 1] = str:sub(i, i + 2)
            i = i + 3
          end
        else
          result[#result + 1] = "\xEF\xBF\xBD"
          i = i + 1
        end
      else
        result[#result + 1] = "\xEF\xBF\xBD"
        i = i + 1
      end
    elseif byte >= 240 and byte <= 244 then
      if i + 3 <= len then
        local b2, b3, b4 = str:byte(i + 1), str:byte(i + 2), str:byte(i + 3)
        if b2 >= 128 and b2 <= 191 and b3 >= 128 and b3 <= 191 and b4 >= 128 and b4 <= 191 then
          if byte == 240 and b2 < 144 then
            result[#result + 1] = "\xEF\xBF\xBD"
            i = i + 1
          elseif byte == 244 and b2 > 143 then
            result[#result + 1] = "\xEF\xBF\xBD"
            i = i + 1
          else
            result[#result + 1] = str:sub(i, i + 3)
            i = i + 4
          end
        else
          result[#result + 1] = "\xEF\xBF\xBD"
          i = i + 1
        end
      else
        result[#result + 1] = "\xEF\xBF\xBD"
        i = i + 1
      end
    else
      result[#result + 1] = "\xEF\xBF\xBD"
      i = i + 1
    end
  end
  return table.concat(result)
end

--- 递归消毒消息字符串字段的 UTF-8。对齐证据 storage.lua:121-139。
---@param messages table[]
local function sanitize_messages_utf8(messages)
  if not messages then
    return
  end
  for _, msg in ipairs(messages) do
    if type(msg.content) == "string" then
      msg.content = sanitize_utf8(msg.content)
    end
    if msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        if call["function"] and type(call["function"].arguments) == "string" then
          call["function"].arguments = sanitize_utf8(call["function"].arguments)
        end
      end
    end
  end
end

--- 消毒非法工具参数 JSON。对齐证据 storage.lua:141-169。
---@param messages table[]
local function sanitize_tool_call_arguments(messages)
  if not messages then
    return
  end
  for _, msg in ipairs(messages) do
    if msg.role == "llm" and msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        if call["function"] and call["function"].arguments then
          local args = call["function"].arguments
          if type(args) == "string" and args ~= "" then
            local ok, decoded = pcall(vim.json.decode, args)
            if not ok or type(decoded) ~= "table" then
              call["function"].arguments = "{}"
            end
          elseif type(args) ~= "string" then
            local ok, encoded = pcall(vim.json.encode, args)
            if ok then
              call["function"].arguments = encoded
            else
              call["function"].arguments = "{}"
            end
          end
        end
      end
    end
  end
end

--- 将 legacy 数据映射为 v1 信封。只解析已知 legacy 字段；`refs` -> `context_items`
--- 归一；绝不写 `refs` 键。返回 (nil, 错误信息) 表示无法迁移。
---@param data table legacy JSON 对象（无 schema_version）
---@param filename_save_id string|nil 文件名派生的 save_id
---@return table|nil env
---@return string|nil err
local function legacy_to_envelope(data, filename_save_id)
  local save_id = data.save_id
  if type(save_id) ~= "string" or save_id == "" or save_id:match("[/\\]") then
    return nil, "legacy save_id invalid: " .. tostring(save_id)
  end
  if filename_save_id and filename_save_id ~= save_id then
    return nil, "legacy save_id does not match filename: " .. save_id .. " != " .. filename_save_id
  end

  local messages = data.messages
  if messages == nil then
    messages = {}
  end
  if type(messages) ~= "table" then
    return nil, "legacy messages must be a table"
  end
  sanitize_tool_call_arguments(messages)
  sanitize_messages_utf8(messages)

  local settings = type(data.settings) == "table" and data.settings or {}
  local runtime_state = {}
  if type(data.cycle) == "number" then
    runtime_state.cycle = data.cycle
  end
  if type(data.compact_protected_prefix_count) == "number" then
    runtime_state.compact_protected_prefix_count = data.compact_protected_prefix_count
  end
  if type(data.cwd) == "string" then
    runtime_state.cwd = data.cwd
  end
  if type(data.project_root) == "string" then
    runtime_state.project_root = data.project_root
  end

  local updated_at = type(data.updated_at) == "number" and data.updated_at or os.time()

  -- refs -> context_items 归一（一次；优先 refs，其次已有 context_items）。
  local context_items = {}
  if type(data.refs) == "table" then
    context_items = data.refs
  elseif type(data.context_items) == "table" then
    context_items = data.context_items
  end

  local adapter = type(data.adapter) == "string" and data.adapter
    or (type(settings.adapter) == "string" and settings.adapter)
    or "unknown"
  local model = type(settings.model) == "string" and settings.model or "unknown"

  local env = {
    schema_version = storage_mod.SCHEMA_VERSION,
    session_id = save_id,
    save_id = save_id,
    project_id = (type(data.project_root) == "string" and data.project_root) or "unknown",
    parent_session_id = nil,
    created_at = updated_at,
    updated_at = updated_at,
    title = type(data.title) == "string" and data.title or nil,
    provider_id = adapter,
    protocol = "unknown",
    model = model,
    messages = messages,
    context_items = context_items,
    runtime_state = runtime_state,
    trace = { id = nil, membership = {} },
    status_snapshot = {},
  }

  local verr = storage_mod.validate_envelope(env)
  if verr then
    return nil, "migrated envelope invalid: " .. verr
  end
  return env, nil
end

--- 迁移一个 legacy 会话文件为 v1 信封。
---@param storage HistoryStorage 已构造的存储实例（复用其原子写）
---@param legacy_path string chats/ 下的 legacy 文件路径
---@param opts? table 预留（后续 wave 使用）
---@return {ok: boolean, save_id?: string, code?: string, error?: string, path?: string}
function M.migrate_file(storage, legacy_path, opts)
  opts = opts or {}
  if vim.fn.filereadable(legacy_path) == 0 then
    return { ok = false, code = "corrupt", error = "legacy file not found: " .. legacy_path, path = legacy_path }
  end
  local fh, oerr = io.open(legacy_path, "rb")
  if not fh then
    return { ok = false, code = "corrupt", error = "cannot open legacy file: " .. tostring(oerr), path = legacy_path }
  end
  local body = fh:read("*a")
  fh:close()

  local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    return { ok = false, code = "corrupt", error = "unparseable legacy JSON: " .. legacy_path, path = legacy_path }
  end

  if data.schema_version ~= nil then
    if type(data.schema_version) == "number" then
      if data.schema_version == storage_mod.SCHEMA_VERSION then
        -- 已迁移：幂等 no-op（不重写、不重复备份）。
        if type(data.save_id) == "string" then
          return { ok = true, save_id = data.save_id }
        end
        return { ok = false, code = "corrupt", error = "v1 file missing save_id: " .. legacy_path, path = legacy_path }
      end
      return {
        ok = false,
        code = "runtime-upgrade-required",
        error = ("schema_version %s > supported %s"):format(tostring(data.schema_version), storage_mod.SCHEMA_VERSION),
        path = legacy_path,
      }
    end
    return {
      ok = false,
      code = "corrupt",
      error = "schema_version is not a number: " .. legacy_path,
      path = legacy_path,
    }
  end

  local filename_save_id = legacy_path:match("([^/]+)%.json$")
  local env, verr = legacy_to_envelope(data, filename_save_id)
  if not env then
    return { ok = false, code = "corrupt", error = verr .. " (" .. legacy_path .. ")", path = legacy_path }
  end

  -- 备份原始内容；之后原子写 v1。任何写失败都保持原始文件不动。
  local okb, berr = storage:atomic_write(legacy_path .. ".bak", body)
  if not okb then
    return { ok = false, code = "write_failed", error = "backup failed: " .. tostring(berr), path = legacy_path }
  end
  local okw, werr = storage:atomic_write(legacy_path, vim.json.encode(env))
  if not okw then
    return { ok = false, code = "write_failed", error = tostring(werr), path = legacy_path }
  end

  return { ok = true, save_id = env.save_id }
end

return M
