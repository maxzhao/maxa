-- Default session prompt-cache warmup support.
--
-- This module intentionally builds warmup payloads with the same message/tool
-- snapshot shape that Maxa AI Chat:submit() passes to _submit_http(). The
-- warmup request itself is sent through maxa_ai.http directly so any model
-- tool_calls produced during warmup are recorded but never executed.
local history_core = require("maxa.session.history_core")
local M = {}

local CACHE_VERSION = 2
local WARMUP_USER_CONTENT = "不要思考，直接回复`ok`，不要有任何多余字符。"
local WARMUP_USER_TAG = "default_session_cache_warmup"
local WARMUP_RESPONSE_TAG = "default_session_cache_warmup_response"
local WARMUP_TOOL_RESULT_TAG = "default_session_cache_warmup_tool_result"
local DEFAULT_MODE = "auto"
local CACHE_STATE_VERSION = 1
local CACHE_STATE_KEY = "default_session_cache"

local installed = false
local pending_by_hash = {}

local function safe_require(name)
  local ok, mod = pcall(require, name)
  if ok then
    return mod
  end
  return nil
end

local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  if vim.islist then
    return vim.islist(t)
  end
  local max = 0
  local count = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      return false
    end
    if k > max then
      max = k
    end
    count = count + 1
  end
  return max == count and getmetatable(t) == nil
end

local function clone_without_functions(value)
  if type(value) ~= "table" then
    if type(value) == "function" or type(value) == "thread" or type(value) == "userdata" then
      return nil
    end
    return value
  end

  if is_array(value) then
    local arr = {}
    for i, item in ipairs(value) do
      arr[i] = clone_without_functions(item)
    end
    return arr
  end

  local dict = vim.empty_dict()
  local keys = vim.tbl_keys(value)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local v = clone_without_functions(value[key])
    if v ~= nil then
      dict[key] = v
    end
  end
  return dict
end

local function canonical_encode(value)
  value = clone_without_functions(value)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end

  if vim.islist(value) then
    local items = {}
    for i = 1, #value do
      items[i] = canonical_encode(value[i])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local keys = vim.tbl_keys(value)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local items = {}
  for _, key in ipairs(keys) do
    local item = clone_without_functions(value[key])
    if item ~= nil then
      table.insert(items, vim.json.encode(tostring(key)) .. ":" .. canonical_encode(item))
    end
  end
  return "{" .. table.concat(items, ",") .. "}"
end

function M.canonical_json(value)
  return canonical_encode(value)
end

local function digest(value)
  return vim.fn.sha256(type(value) == "string" and value or M.canonical_json(value))
end

local function get_model_name(adapter)
  if type(adapter) ~= "table" then
    return ""
  end
  if adapter.model and type(adapter.model) == "table" and adapter.model.name then
    return tostring(adapter.model.name)
  end
  local schema_model = adapter.schema and adapter.schema.model
  local model = schema_model and schema_model.default
  if type(model) == "function" then
    local ok, result = pcall(model, adapter)
    if ok then
      model = result
    else
      model = ""
    end
  end
  return tostring(model or "")
end

function M.get_cache_dir()
  local dir = history_core.get_history_dir() .. "/caches"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

local function cache_path(hash)
  return M.get_cache_dir() .. "/" .. hash .. ".json"
end

local function read_json(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "not_found"
  end
  local lines = vim.fn.readfile(path)
  local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    return nil, "invalid_json"
  end
  return data, nil
end

local function write_json_atomic(path, data)
  local encoded = vim.json.encode(clone_without_functions(data))
  if type(encoded) ~= "string" or encoded == "" then
    return false, "encode_failed"
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local tmp = path .. ".tmp." .. tostring(vim.loop.hrtime())
  local ok_write, write_err = pcall(vim.fn.writefile, vim.split(encoded, "\n", { plain = true }), tmp)
  if not ok_write then
    pcall(vim.fn.delete, tmp)
    return false, tostring(write_err)
  end
  local ok_rename, rename_err = pcall(vim.fn.rename, tmp, path)
  if not ok_rename then
    pcall(vim.fn.delete, tmp)
    return false, tostring(rename_err)
  end
  return true, nil
end

local function delete_cache(path)
  if type(path) == "string" and path ~= "" and vim.fn.filereadable(path) == 1 then
    pcall(vim.fn.delete, path)
  end
end

local function message_tag(msg)
  return msg and msg._meta and msg._meta.tag or nil
end

local function is_warmup_message(msg)
  local tag = message_tag(msg)
  return tag == WARMUP_USER_TAG or tag == WARMUP_RESPONSE_TAG or tag == WARMUP_TOOL_RESULT_TAG
end

local function has_disallowed_context_items(chat)
  for _, item in ipairs(chat.context_items or {}) do
    -- 默认会话会包含 rules context 以及默认 Chat 内建工具注册产生的 tool context。
    -- 是否为默认工具集由 default_tools_only() 基于 schema 名称继续约束。
    if item.source ~= "rules" and item.source ~= "tool" then
      return true
    end
  end
  return false
end

local function default_prefix_count(chat)
  local count = 0
  for _, msg in ipairs(chat.messages or {}) do
    local tag = message_tag(msg)
    if tag == "system_prompt_from_config" or tag == "soul_prompt_from_config" or tag == "rules" then
      count = count + 1
    else
      break
    end
  end
  return count
end

local function schema_tool_name(schema, fallback)
  if type(schema) == "table" then
    if type(schema.name) == "string" then
      return schema.name
    end
    if type(schema["function"]) == "table" and type(schema["function"].name) == "string" then
      return schema["function"].name
    end
  end
  return fallback
end

local function default_tools_only(chat)
  local schemas = chat.tool_registry and chat.tool_registry.schemas or {}
  if vim.tbl_isempty(schemas) then
    return false
  end
  local defaults = {}
  for _, name in ipairs(require("maxa.interactions.chat.tools.builtin").names) do
    defaults[name] = true
  end
  for id, schema in pairs(schemas) do
    local name = schema_tool_name(schema, tostring(id))
    if not defaults[name] then
      return false
    end
  end
  return true
end

function M.is_default_chat(chat)
  if type(chat) ~= "table" then
    return false, "missing_chat"
  end
  if not chat.adapter or chat.adapter.type ~= "http" then
    return false, "non_http_adapter"
  end
  if chat.opts and chat.opts._history_restored then
    return false, "history_restored"
  end
  if chat.from_prompt_library then
    return false, "prompt_library"
  end
  if has_disallowed_context_items(chat) then
    return false, "non_rules_context"
  end
  local count = default_prefix_count(chat)
  if count <= 0 then
    return false, "no_default_prefix"
  end
  for i = 1, count do
    local tag = message_tag(chat.messages[i])
    if tag ~= "system_prompt_from_config" and tag ~= "soul_prompt_from_config" and tag ~= "rules" then
      return false, "bad_prefix"
    end
  end
  if not default_tools_only(chat) then
    return false, "non_default_tools"
  end
  return true, nil, count
end

local function get_cache_config(chat)
  local cfg = chat and chat._default_session_cache_config or nil
  if type(cfg) ~= "table" then
    cfg = { mode = DEFAULT_MODE }
  end
  cfg.mode = cfg.mode or DEFAULT_MODE
  return cfg
end

local function effective_prefix_count(chat, cfg)
  if type(cfg.prefix_count) == "number" and cfg.prefix_count > 0 then
    return math.min(math.floor(cfg.prefix_count), #(chat.messages or {}))
  end
  local ok, _, count = M.is_default_chat(chat)
  if ok then
    return count
  end
  return 0
end

local function should_enable_for_chat(chat, cfg)
  local mode = cfg.mode or DEFAULT_MODE
  if mode == "disable" then
    return false, "disabled"
  end
  if mode == "force" then
    local count = effective_prefix_count(chat, cfg)
    if count > 0 and chat.adapter and chat.adapter.type == "http" then
      return true, nil, count
    end
    return false, "force_no_prefix"
  end
  local ok, reason, count = M.is_default_chat(chat)
  if ok then
    return true, nil, count
  end
  return false, reason
end

local function split_messages(chat, prefix_count)
  local prefix = {}
  local tail = {}
  for i, msg in ipairs(chat.messages or {}) do
    if i <= prefix_count then
      table.insert(prefix, vim.deepcopy(msg))
    elseif not is_warmup_message(msg) then
      table.insert(tail, vim.deepcopy(msg))
    end
  end
  return prefix, tail
end

local function add_warmup_user(messages)
  table.insert(messages, {
    role = require("maxa.config").constants.USER_ROLE,
    content = WARMUP_USER_CONTENT,
    opts = { visible = false },
    _meta = { tag = WARMUP_USER_TAG },
  })
end

local function mapped_adapter_for_chat(chat)
  local adapter = vim.deepcopy(chat.adapter)
  if adapter and adapter.map_schema_to_params then
    local ok, mapped = pcall(function()
      return adapter:map_schema_to_params(chat.settings or {})
    end)
    if ok and mapped then
      adapter = mapped
    end
  end
  return adapter
end

function M.build_payload_snapshot(chat, messages)
  local payload = {
    messages = chat.adapter:map_roles(vim.deepcopy(messages or {})),
    tools = (chat.tool_registry and not vim.tbl_isempty(chat.tool_registry.schemas) and { chat.tool_registry.schemas } or {}),
  }
  return clone_without_functions(payload)
end

function M.build_request_body_snapshot(chat, payload)
  local adapters = require("maxa.adapters")
  local adapter = mapped_adapter_for_chat(chat)
  local params = adapter.parameters or {}
  local body = vim.tbl_extend(
    "keep",
    adapters.call_handler(adapter, "build_parameters", vim.deepcopy(params), payload.messages) or {},
    adapters.call_handler(adapter, "build_messages", payload.messages) or {},
    adapters.call_handler(adapter, "build_tools", payload.tools) or {},
    adapter.body and vim.deepcopy(adapter.body) or {},
    adapters.call_handler(adapter, "build_body", payload) or {}
  )
  return clone_without_functions({
    url = adapter.url,
    body = body,
  })
end

local function fingerprint(chat, warmup_messages)
  local payload = M.build_payload_snapshot(chat, warmup_messages)
  local request_snapshot = M.build_request_body_snapshot(chat, payload)
  local data = {
    version = CACHE_VERSION,
    project_root = (chat.buffer_context and chat.buffer_context.project_root) or vim.fs.root(0, { ".maxa" }) or vim.fn.getcwd(),
    adapter = chat.adapter and chat.adapter.name or "unknown",
    model = get_model_name(chat.adapter),
    settings = chat.settings or {},
    warmup_user_content = WARMUP_USER_CONTENT,
    payload = payload,
    request = request_snapshot,
  }
  local payload_digest = digest(payload)
  local request_digest = digest(request_snapshot)
  local hash = digest(data)
  return {
    hash = hash,
    path = cache_path(hash),
    payload = payload,
    request = request_snapshot,
    data = data,
    payload_digest = payload_digest,
    request_digest = request_digest,
    tools_digest = digest(payload.tools or {}),
    settings_digest = digest(chat.settings or {}),
  }
end

local function synthetic_tool_result(tool_call)
  local call_id = tool_call.call_id or tool_call.id
  return {
    role = require("maxa.config").constants.TOOL_ROLE or "tool",
    content = "[Warmup tool call intentionally not executed]",
    tools = { call_id = call_id, id = tool_call.id },
    opts = { visible = false },
    _meta = { tag = WARMUP_TOOL_RESULT_TAG },
  }
end

local function append_warmup_response(chat, messages, output_chunks, tools, reasoning, meta)
  local cc_config = require("maxa.config")
  local content = vim.trim(table.concat(output_chunks or {}, ""))
  if type(tools) == "table" and not vim.tbl_isempty(tools) then
    local adapters = require("maxa.adapters")
    local formatted = adapters.call_handler(chat.adapter, "format_calls", tools) or tools
    local reasoning_content
    if type(reasoning) == "table" and not vim.tbl_isempty(reasoning) then
      reasoning_content = adapters.call_handler(chat.adapter, "build_reasoning", reasoning)
    end
    table.insert(messages, {
      role = cc_config.constants.LLM_ROLE,
      content = content ~= "" and content or nil,
      reasoning = reasoning_content,
      tools = { calls = formatted },
      opts = { visible = false },
      _meta = { tag = WARMUP_RESPONSE_TAG },
    })
    for _, call in ipairs(formatted) do
      table.insert(messages, synthetic_tool_result(call))
    end
  else
    table.insert(messages, {
      role = cc_config.constants.LLM_ROLE,
      content = content,
      opts = { visible = false },
      _meta = { tag = WARMUP_RESPONSE_TAG },
    })
  end
end

local function parse_warmup_chunk(chat, data, output, reasoning, tools, meta)
  if chat.adapter.features and chat.adapter.features.tokens then
    require("maxa.adapters").call_handler(chat.adapter, "parse_tokens", data)
  end
  local result = require("maxa.adapters").call_handler(chat.adapter, "parse_chat", data, tools)
  local parse_meta = require("maxa.adapters").get_handler(chat.adapter, "parse_meta")
  if result and result.extra and type(parse_meta) == "function" then
    result = parse_meta(chat.adapter, result)
  end
  if result and result.status == "success" and result.output then
    if result.output.reasoning then
      table.insert(reasoning, result.output.reasoning)
    end
    if result.output.meta then
      vim.tbl_deep_extend("force", meta, result.output.meta)
    end
    if result.output.content then
      table.insert(output, result.output.content)
    end
  elseif result and result.status == "error" then
    return false, result.output or "warmup parse error"
  end
  return true, nil
end

local send_warmup

local function chat_event_bufnr(chat)
  if type(chat) ~= "table" then
    return nil
  end
  return tonumber(chat._default_session_cache_bufnr or chat.bufnr or chat.buffer or chat.buffer_number or chat.opts and chat.opts.bufnr)
end

local function emit_warmup_event(event, chat, fp, extra)
  local data = vim.tbl_extend("force", {
    bufnr = chat_event_bufnr(chat),
    id = type(chat) == "table" and chat.id or nil,
    adapter = type(chat) == "table" and chat.adapter or nil,
    kind = "default_session_cache_warmup",
    hash = type(fp) == "table" and fp.hash or nil,
  }, extra or {})
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event,
    data = data,
  })
end

local function default_send_warmup(chat, fp, callback)
  local payload = fp and fp.payload or nil
  local http = safe_require("maxa.http")
  local adapters = safe_require("maxa.adapters")
  if not http or not adapters then
    callback(false, nil, "missing maxa_ai http/adapters")
    return
  end

  local adapter = mapped_adapter_for_chat(chat)
  local ok_setup = adapters.call_handler(adapter, "setup")
  if ok_setup == false then
    callback(false, nil, "adapter setup failed")
    return
  end
  adapter = require("maxa.utils.adapters").get_env_vars(adapter, {
    timeout = require("maxa.config").adapters.opts.cmd_timeout,
  })

  local output, reasoning, tools, meta = {}, {}, {}, {}
  local finished = false
  local function finish(ok, result, err)
    if not finished then
      finished = true
      emit_warmup_event("MaxaAIDefaultSessionCacheWarmupFinished", chat, fp, {
        ok = ok == true,
        error = err,
      })
    end
    callback(ok, result, err)
  end

  emit_warmup_event("MaxaAIDefaultSessionCacheWarmupStarted", chat, fp)
  local client = http.new({ adapter = adapter })
  client:send(payload, {
    silent = true,
    interaction = "chat",
    on_chunk = function(data)
      local ok, err = parse_warmup_chunk(chat, data, output, reasoning, tools, meta)
      if not ok then
        chat._default_session_cache_warmup_error = tostring(err)
      end
    end,
    on_done = function(data)
      if data and not adapter.opts.stream then
        local ok, err = parse_warmup_chunk(chat, data, output, reasoning, tools, meta)
        if not ok then
          finish(false, nil, tostring(err))
          return
        end
      end
      if chat._default_session_cache_warmup_error then
        local err = chat._default_session_cache_warmup_error
        chat._default_session_cache_warmup_error = nil
        finish(false, nil, err)
        return
      end
      finish(true, { output = output, reasoning = reasoning, tools = tools, meta = meta }, nil)
    end,
    on_error = function(err)
      finish(false, nil, vim.inspect(err))
    end,
  })
end

local function build_cache_record(chat, fp, cached_messages, context_items)
  local prefix_text = {}
  for _, msg in ipairs(cached_messages) do
    if msg.content then
      table.insert(prefix_text, tostring(msg.content))
    end
  end
  return {
    version = CACHE_VERSION,
    hash = fp.hash,
    created_at = os.time(),
    updated_at = os.time(),
    project_root = fp.data.project_root,
    adapter = fp.data.adapter,
    model = fp.data.model,
    warmup = {
      user_content = WARMUP_USER_CONTENT,
      status = "completed",
    },
    fingerprint = {
      payload_digest = fp.payload_digest,
      request_digest = fp.request_digest,
      system_prompt_digest = digest(table.concat(prefix_text, "\n")),
      tools_digest = fp.tools_digest,
      settings_digest = fp.settings_digest,
    },
    messages = cached_messages,
    context_items = context_items or {},
    schemas = chat.tool_registry and chat.tool_registry.schemas or {},
    in_use = chat.tool_registry and chat.tool_registry.in_use or {},
    prefix_count = #cached_messages,
  }
end

local function validate_cache(record, fp)
  if type(record) ~= "table" then
    return false, "bad_record"
  end
  if record.version ~= CACHE_VERSION or record.hash ~= fp.hash then
    return false, "version_or_hash_mismatch"
  end
  if not record.fingerprint or record.fingerprint.payload_digest ~= fp.payload_digest then
    return false, "payload_digest_mismatch"
  end
  if record.fingerprint.request_digest ~= fp.request_digest then
    return false, "request_digest_mismatch"
  end
  if type(record.messages) ~= "table" or #record.messages == 0 then
    return false, "missing_messages"
  end
  return true, nil
end

local function build_cached_messages(record, tail)
  local messages = vim.deepcopy(record.messages or {})
  for _, msg in ipairs(tail or {}) do
    table.insert(messages, vim.deepcopy(msg))
  end
  return messages
end

local function mark_request_cache(chat, record, source)
  chat._default_session_cache_used_hash = record.hash
  chat._default_session_cache_path = cache_path(record.hash)
  chat._default_session_cache_payload_digest = record.fingerprint and record.fingerprint.payload_digest
  chat._default_session_cache_request_digest = record.fingerprint and record.fingerprint.request_digest
  chat._default_session_cache_source = source or "existing"
end

local function sanitize_warmup_cached_messages(messages)
  if type(messages) ~= "table" then
    return false
  end
  local changed = false
  for _, msg in ipairs(messages) do
    if message_tag(msg) == WARMUP_RESPONSE_TAG then
      -- Tool-call continuations from thinking models must retain reasoning.
      -- Plain warmup responses still discard it to keep cache artifacts small.
      local has_tool_calls = msg.tools and type(msg.tools.calls) == "table" and not vim.tbl_isempty(msg.tools.calls)
      if not has_tool_calls and msg.reasoning ~= nil then
        msg.reasoning = nil
        changed = true
      end
      local meta = msg._meta
      local has_extra_meta = false
      if type(meta) == "table" then
        for key, _ in pairs(meta) do
          if key ~= "tag" then
            has_extra_meta = true
            break
          end
        end
      end
      if type(meta) ~= "table" or meta.tag ~= WARMUP_RESPONSE_TAG or has_extra_meta then
        msg._meta = { tag = WARMUP_RESPONSE_TAG }
        changed = true
      end
    end
  end
  return changed
end

local function sanitize_cache_record(record)
  if type(record) ~= "table" then
    return false
  end
  return sanitize_warmup_cached_messages(record.messages)
end

local function prepare_cache_record(record, path)
  if sanitize_cache_record(record) and path then
    record.updated_at = os.time()
    write_json_atomic(path, record)
  end
  return record
end

local function warmup_request_messages(messages)
  if type(messages) ~= "table" then
    return {}
  end
  local result = {}
  for _, msg in ipairs(messages) do
    local tag = message_tag(msg)
    if tag ~= WARMUP_RESPONSE_TAG and tag ~= WARMUP_TOOL_RESULT_TAG then
      table.insert(result, vim.deepcopy(msg))
    end
    if tag == WARMUP_USER_TAG then
      break
    end
  end
  return result
end

local function get_state_message(chat)
  if type(chat) ~= "table" or type(chat.messages) ~= "table" then
    return nil
  end
  return chat.messages[1]
end

local function get_cache_state(chat)
  local msg = get_state_message(chat)
  return msg and msg._meta and msg._meta[CACHE_STATE_KEY] or nil
end

local function set_cache_state(chat, fp, status)
  if type(chat) ~= "table" or type(fp) ~= "table" then
    return false
  end
  chat._default_session_cache_checked = true
  local msg = get_state_message(chat)
  if not msg then
    return false
  end
  msg._meta = msg._meta or {}
  msg._meta[CACHE_STATE_KEY] = {
    version = CACHE_STATE_VERSION,
    checked = true,
    status = status or "checked",
    hash = fp.hash,
    request_digest = fp.request_digest,
    at = os.time(),
  }
  return true
end

local function has_cache_state(chat, fp)
  if type(chat) ~= "table" or type(fp) ~= "table" then
    return false
  end
  if chat._default_session_cache_checked then
    return true
  end
  local state = get_cache_state(chat)
  if type(state) ~= "table" or state.checked ~= true then
    return false
  end
  if state.request_digest ~= fp.request_digest then
    return false
  end
  chat._default_session_cache_checked = true
  return true
end

local function preflight_cached_prefix(chat, record)
  if type(record) ~= "table" or type(record.messages) ~= "table" then
    return false
  end
  local payload = M.build_payload_snapshot(chat, warmup_request_messages(record.messages))
  local request = M.build_request_body_snapshot(chat, payload)
  return digest(request) == (record.fingerprint and record.fingerprint.request_digest)
end

local function replace_messages_with_ui_sources(chat, messages, index_map)
  if chat.ui and chat.ui.message_provenance then
    chat.ui.message_provenance:rebind_messages(chat.messages, messages, index_map)
  end
  chat.messages = messages
end

local function finish_submit(original_submit, chat, opts)
  chat._default_session_cache_bypass = true
  local ok, result = pcall(original_submit, chat, opts)
  chat._default_session_cache_bypass = false
  if not ok then
    error(result)
  end
  return result
end

local function finish_submit_with_cache(original_submit, chat, opts, record, prefix_count, source)
  local original_submit_http = chat._submit_http
  chat._submit_http = function(self, payload)
    self._submit_http = original_submit_http
    local _, live_tail = split_messages(self, prefix_count)
    local cached_messages = build_cached_messages(record, live_tail)
    local index_map, tail_index = {}, 0
    for i, message in ipairs(self.messages) do
      if i <= prefix_count then
        index_map[i] = i
      elseif not is_warmup_message(message) then
        tail_index = tail_index + 1
        index_map[i] = #(record.messages or {}) + tail_index
      end
    end
    replace_messages_with_ui_sources(self, cached_messages, index_map)
    self.context_items = vim.deepcopy(record.context_items or self.context_items or {})
    if self.tool_registry then
      self.tool_registry.schemas = vim.deepcopy(record.schemas or self.tool_registry.schemas or {})
      self.tool_registry.in_use = vim.deepcopy(record.in_use or self.tool_registry.in_use or {})
    end
    mark_request_cache(self, record, source)
    return original_submit_http(self, {
      messages = self.adapter:map_roles(vim.deepcopy(self.messages)),
      tools = (not vim.tbl_isempty(self.tool_registry and self.tool_registry.schemas or {}) and { self.tool_registry.schemas } or {}),
    })
  end

  local ok, result = pcall(original_submit, chat, opts)
  if chat._submit_http ~= original_submit_http then
    chat._submit_http = original_submit_http
  end
  if not ok then
    error(result)
  end
  return result
end

local function cache_miss_from_usage(chat)
  local usage = chat and chat.adapter and chat.adapter._last_usage
  if type(usage) ~= "table" or not usage.cache_metric_supported then
    return false
  end
  local cached = tonumber(usage.cached_tokens or usage.cache_read_input_tokens or 0) or 0
  return cached <= 0
end

local function hook_chat(chat)
  if type(chat) ~= "table" or chat._default_session_cache_hooked then
    return
  end
  chat._default_session_cache_hooked = true

  local original_submit = chat.submit
  chat.submit = function(self, opts)
    opts = opts or {}
    if self._default_session_cache_bypass or opts._default_session_cache_bypass then
      return original_submit(self, opts)
    end
    if self._default_session_cache_checked then
      return original_submit(self, opts)
    end

    local cfg = get_cache_config(self)
    local enabled, _, prefix_count = should_enable_for_chat(self, cfg)
    if not enabled or prefix_count <= 0 then
      return original_submit(self, opts)
    end

    local original_messages = vim.deepcopy(self.messages or {})
    local prefix, tail = split_messages(self, prefix_count)
    if #prefix == 0 then
      return original_submit(self, opts)
    end

    local warmup_messages = vim.deepcopy(prefix)
    add_warmup_user(warmup_messages)
    local fp = fingerprint(self, warmup_messages)
    if has_cache_state(self, fp) then
      return original_submit(self, opts)
    end

    local record, read_err = read_json(fp.path)
    if record then
      prepare_cache_record(record, fp.path)
      local valid = validate_cache(record, fp)
      if valid and preflight_cached_prefix(self, record) then
        set_cache_state(self, fp, "applied")
        return finish_submit_with_cache(original_submit, self, opts, record, prefix_count, "existing")
      else
        delete_cache(fp.path)
        set_cache_state(self, fp, "invalid")
        return finish_submit(original_submit, self, opts)
      end
    elseif read_err == "invalid_json" then
      delete_cache(fp.path)
      set_cache_state(self, fp, "invalid_json")
      return finish_submit(original_submit, self, opts)
    end

    if pending_by_hash[fp.hash] then
      table.insert(pending_by_hash[fp.hash], function(ok)
        if not ok then
          replace_messages_with_ui_sources(self, original_messages)
        end
        if ok then
          local cached = read_json(fp.path)
          if cached then
            prepare_cache_record(cached, fp.path)
          end
          if cached and validate_cache(cached, fp) and preflight_cached_prefix(self, cached) then
            set_cache_state(self, fp, "applied")
            finish_submit_with_cache(original_submit, self, opts, cached, prefix_count, "existing_waiter")
          else
            set_cache_state(self, fp, "missed_pending")
            finish_submit(original_submit, self, opts)
          end
        else
          set_cache_state(self, fp, "warmup_failed")
          finish_submit(original_submit, self, opts)
        end
      end)
      return
    end

    pending_by_hash[fp.hash] = {}
    send_warmup(self, fp, function(ok, warmup_result)
      if ok then
        local cached_messages = vim.deepcopy(warmup_messages)
        append_warmup_response(self, cached_messages, warmup_result.output, warmup_result.tools, warmup_result.reasoning, warmup_result.meta)
        local record_to_write = build_cache_record(self, fp, cached_messages, self.context_items or {})
        write_json_atomic(fp.path, record_to_write)
      else
        replace_messages_with_ui_sources(self, original_messages)
      end

      local waiters = pending_by_hash[fp.hash] or {}
      pending_by_hash[fp.hash] = nil
      if ok then
        local cached = read_json(fp.path)
        if cached then
          prepare_cache_record(cached, fp.path)
        end
        if cached and validate_cache(cached, fp) and preflight_cached_prefix(self, cached) then
          finish_submit_with_cache(original_submit, self, opts, cached, prefix_count, "created")
          set_cache_state(self, fp, "created")
        else
          set_cache_state(self, fp, "missed_created")
          finish_submit(original_submit, self, opts)
        end
      else
        set_cache_state(self, fp, "warmup_failed")
        finish_submit(original_submit, self, opts)
      end
      for _, waiter in ipairs(waiters) do
        vim.schedule(function()
          waiter(ok)
        end)
      end
    end)
  end

  local original_done = chat.done
  chat.done = function(self, output, reasoning, tools, meta, opts)
    local result = original_done(self, output, reasoning, tools, meta, opts)
    if
      self._default_session_cache_used_hash
      and self._default_session_cache_source ~= "created"
      and cache_miss_from_usage(self)
    then
      delete_cache(self._default_session_cache_path)
      self._default_session_cache_used_hash = nil
      self._default_session_cache_path = nil
      self._default_session_cache_payload_digest = nil
      self._default_session_cache_source = nil
    elseif self._default_session_cache_source == "created" then
      self._default_session_cache_source = nil
    end
    return result
  end
end

function M.configure_chat(chat, opts)
  if type(chat) ~= "table" then
    return false
  end
  opts = opts or {}
  local mode = opts.mode or DEFAULT_MODE
  if mode ~= "auto" and mode ~= "force" and mode ~= "disable" then
    mode = DEFAULT_MODE
  end
  chat._default_session_cache_config = {
    mode = mode,
    prefix_count = opts.prefix_count,
    kind = opts.kind,
  }
  hook_chat(chat)
  return true
end

function M.setup()
  if installed then
    return
  end
  installed = true
  vim.api.nvim_create_autocmd("User", {
    pattern = "MaxaAIChatCreated",
    callback = function(args)
      local chat_mod = safe_require("maxa.interactions.chat")
      if not chat_mod or not chat_mod.buf_get_chat then
        return
      end
      local bufnr = args.data and args.data.bufnr
      if not bufnr then
        return
      end
      local ok, chat = pcall(chat_mod.buf_get_chat, bufnr)
      if ok and chat then
        chat._default_session_cache_bufnr = bufnr
        hook_chat(chat)
      end
    end,
  })
end

function M.reset_setup()
  installed = false
  pending_by_hash = {}
end

M._private = {
  WARMUP_USER_CONTENT = WARMUP_USER_CONTENT,
  canonical_json = M.canonical_json,
  canonical_encode = canonical_encode,
  digest = digest,
  split_messages = split_messages,
  add_warmup_user = add_warmup_user,
  append_warmup_response = append_warmup_response,
  fingerprint = fingerprint,
  validate_cache = validate_cache,
  should_enable_for_chat = should_enable_for_chat,
  is_default_chat = M.is_default_chat,
  build_payload_snapshot = M.build_payload_snapshot,
  build_request_body_snapshot = M.build_request_body_snapshot,
  cache_miss_from_usage = cache_miss_from_usage,
  chat_event_bufnr = chat_event_bufnr,
  emit_warmup_event = emit_warmup_event,
  preflight_cached_prefix = preflight_cached_prefix,
  get_cache_state = get_cache_state,
  set_cache_state = set_cache_state,
  has_cache_state = has_cache_state,
  sanitize_warmup_cached_messages = sanitize_warmup_cached_messages,
  sanitize_cache_record = sanitize_cache_record,
  warmup_request_messages = warmup_request_messages,
  build_cache_record = build_cache_record,
  write_json_atomic = write_json_atomic,
}

send_warmup = default_send_warmup

M._private.send_warmup = default_send_warmup
M._private.set_send_warmup_for_test = function(fn)
  if type(fn) == "function" then
    send_warmup = fn
  else
    send_warmup = default_send_warmup
  end
end

return M
