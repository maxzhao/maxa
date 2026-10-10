local adapter_behavior = require("maxa.adapters.behavior")
local adapter_utils = require("maxa.utils.adapters")

local M = {}

local UNSUPPORTED_PARAMETERS = {
  "store",
  "previous_response_id",
  "conversation",
  "background",
  "metadata",
  "include",
  "prompt",
  "truncation",
  "service_tier",
  "safety_identifier",
  "prompt_cache_key",
  "prompt_cache_retention",
  "context_management",
  "stream_options",
}

local function remove_path(value, path)
  local parts = {}
  for part in path:gmatch("[^%.]+") do
    parts[#parts + 1] = part
  end
  local node = value
  for index = 1, #parts - 1 do
    node = type(node) == "table" and node[parts[index]] or nil
    if type(node) ~= "table" then
      return
    end
  end
  if type(node) == "table" then
    node[parts[#parts]] = nil
  end
end

local function state(self)
  self.temp = self.temp or {}
  self.temp.deepseek_responses = self.temp.deepseek_responses or {}
  return self.temp.deepseek_responses
end

local function reset_state(self)
  self.temp = self.temp or {}
  self.temp.deepseek_responses = {}
  return self.temp.deepseek_responses
end

local function decode(data)
  if type(data) == "table" then
    data = data.body or data.data or data.content
  end
  if type(data) ~= "string" or data == "" then
    return nil
  end
  local cleaned = adapter_utils.clean_streamed_data(data)
  if cleaned == "[DONE]" then
    return nil
  end
  local ok, json = pcall(vim.json.decode, cleaned, { luanil = { object = true } })
  return ok and type(json) == "table" and json or nil
end

local function reasoning_text(item)
  local parts = {}
  local content = item and item.content
  if type(content) == "string" then
    parts[#parts + 1] = content
  elseif type(content) == "table" then
    for _, part in ipairs(content) do
      if type(part) == "table" and part.type == "reasoning_text" and type(part.text) == "string" then
        parts[#parts + 1] = part.text
      end
    end
  end
  return #parts > 0 and table.concat(parts, "") or nil
end

local function completed_function_call(item)
  return type(item) == "table"
    and item.type == "function_call"
    and item.status == "completed"
    and type(item.call_id) == "string"
    and item.call_id ~= ""
end

local function reasoning_metadata(current, include_visible)
  local value = current.reasoning_text
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if include_visible and not current.visible_reasoning_emitted then
    current.visible_reasoning_emitted = true
    return { content = value, _complete_content = value }
  end
  return { _complete_content = value }
end

local function attach_reasoning_to_tool_result(self, json, base_result)
  if json.type ~= "response.output_item.done" or not completed_function_call(json.item) then
    return base_result
  end
  local reasoning = reasoning_metadata(state(self), false)
  if reasoning and type(base_result) == "table" and base_result.status == "success" then
    base_result.output.reasoning = reasoning
  end
  return base_result
end

local function prepare_deepseek_messages(messages)
  local copied = vim.deepcopy(messages or {})
  local latest_reasoning
  local reasoning_since_boundary = false
  for _, message in ipairs(copied) do
    if message.role == "user" then
      latest_reasoning = nil
      reasoning_since_boundary = false
    elseif message.role == "tool" then
      reasoning_since_boundary = false
    end
    local text = type(message.reasoning) == "table" and message.reasoning.content or nil
    if type(text) == "string" and text ~= "" then
      latest_reasoning = vim.deepcopy(message.reasoning)
      reasoning_since_boundary = true
    end
    if message.tools and message.tools.calls then
      if (not text or text == "") and not reasoning_since_boundary and latest_reasoning then
        message.reasoning = vim.deepcopy(latest_reasoning)
      end
      reasoning_since_boundary = false
    end
  end
  return copied
end

local function rewrite_reasoning_items(result)
  for index = #(result.input or {}), 1, -1 do
    local item = result.input[index]
    if item.type == "reasoning" then
      local parts = {}
      for _, part in ipairs(type(item.content) == "table" and item.content or {}) do
        if part.type == "reasoning_text" and type(part.text) == "string" then
          parts[#parts + 1] = part.text
        end
      end
      for _, part in ipairs(type(item.summary) == "table" and item.summary or {}) do
        if part.type == "summary_text" and type(part.text) == "string" then
          parts[#parts + 1] = part.text
        end
      end
      item.id = nil
      item.summary = nil
      item.encrypted_content = nil
      item.content = #parts > 0 and { { type = "reasoning_text", text = table.concat(parts, "") } } or nil
      if not item.content then
        table.remove(result.input, index)
      end
    end
  end
  return result
end

local function deepseek_tools(self, tools)
  if not self.opts.tools or type(tools) ~= "table" or vim.tbl_count(tools) == 0 then
    return nil
  end
  local transformed = {}
  for _, group in pairs(tools) do
    for _, schema in pairs(group) do
      if not (schema._meta and schema._meta.adapter_tool) then
        local copied = vim.deepcopy(schema)
        local definition = copied["function"] or copied
        if type(definition.name) ~= "string" or definition.name == "" or type(definition.parameters) ~= "table" then
          error("DeepSeek Responses function tool requires name and parameters")
        end
        transformed[#transformed + 1] = {
          type = "function",
          name = definition.name,
          description = definition.description,
          parameters = definition.parameters,
        }
      end
    end
  end
  adapter_behavior.sort_tools(transformed)
  return #transformed > 0 and { tools = transformed } or nil
end

function M.extend(base_factory)
  if type(base_factory) ~= "function" then
    error("deepseek.extend requires a base_factory function")
  end
  return function()
    local adapter = base_factory()
    if type(adapter) ~= "table" then
      error("deepseek decorated factory must return an adapter table")
    end
    local handlers = adapter.handlers or {}
    local lifecycle = handlers.lifecycle or {}
    local request = handlers.request or {}
    local response = handlers.response or {}
    local base_build_parameters = assert(request.build_parameters, "DeepSeek extension requires build_parameters")
    local base_build_messages = assert(request.build_messages, "DeepSeek extension requires build_messages")
    local base_parse_chat = assert(response.parse_chat, "DeepSeek extension requires parse_chat")
    local base_parse_metrics = response.parse_metrics
    local base_build_reasoning = assert(request.build_reasoning, "DeepSeek extension requires build_reasoning")
    local base_on_exit = assert(lifecycle.on_exit, "DeepSeek extension requires on_exit")

    adapter.temp = adapter.temp or {}
    reset_state(adapter)
    adapter.available_tools = {}
    adapter.parameters = adapter.parameters or {}
    for _, path in ipairs(UNSUPPORTED_PARAMETERS) do
      remove_path(adapter.parameters, path)
    end
    remove_path(adapter.parameters, "reasoning.summary")
    remove_path(adapter.parameters, "text.verbosity")
    if adapter.schema then
      adapter.schema["reasoning.summary"] = nil
      adapter.schema.verbosity = nil
    end

    request.build_parameters = function(self, params, messages)
      reset_state(self)
      local result = base_build_parameters(self, params, messages)
      for _, path in ipairs(UNSUPPORTED_PARAMETERS) do
        remove_path(result, path)
      end
      remove_path(result, "reasoning.summary")
      remove_path(result, "text.verbosity")
      return result
    end

    request.build_messages = function(self, messages)
      return rewrite_reasoning_items(base_build_messages(self, prepare_deepseek_messages(messages)))
    end
    request.build_reasoning = function(self, data)
      local result = base_build_reasoning(self, data)
      local complete_content
      for _, item in ipairs(data or {}) do
        if type(item) == "table" and type(item._complete_content) == "string" and item._complete_content ~= "" then
          complete_content = item._complete_content
        end
      end
      if complete_content then
        result = type(result) == "table" and result or {}
        result.content = complete_content
      end
      return result
    end
    request.build_tools = deepseek_tools

    response.parse_metrics = function(self, data)
      local json = decode(data)
      if json and json.type == "response.reasoning_text.delta" then
        return { bytes = adapter_behavior.output_bytes(json.delta) }
      end
      local observation = base_parse_metrics and base_parse_metrics(self, data)
      if observation and json and (json.type == "response.completed" or json.object == "response") then
        for _, item in ipairs((json.response or json).output or {}) do
          if item.type == "reasoning" then
            observation.fallback_bytes = (observation.fallback_bytes or 0) + adapter_behavior.output_bytes(reasoning_text(item))
          end
        end
      end
      return observation
    end

    response.parse_chat = function(self, data, tools)
      local json = decode(data)
      if not json then
        return base_parse_chat(self, data, tools)
      end
      local current = state(self)
      if not self.opts.stream then
        local result = base_parse_chat(self, data, tools)
        if result and result.status == "success" then
          local reasoning_parts = {}
          for _, item in ipairs(type(json.output) == "table" and json.output or {}) do
            if item.type == "reasoning" then
              local text = reasoning_text(item)
              if text then
                reasoning_parts[#reasoning_parts + 1] = text
              end
            end
          end
          if #reasoning_parts > 0 and result.output then
            result.output.reasoning = { content = table.concat(reasoning_parts, "") }
          end
        end
        reset_state(self)
        self._maxa_stream_chat_bufnr = nil
        self._maxa_stream_chat_id = nil
        return result
      elseif json.type == "response.created" then
        current = reset_state(self)
      elseif json.type == "response.reasoning_text.delta" then
        local delta = type(json.delta) == "string" and json.delta or ""
        current.reasoning_text = (current.reasoning_text or "") .. delta
        current.delta_seen = true
        if delta == "" then
          return nil
        end
        current.visible_reasoning_emitted = true
        return {
          status = "success",
          output = {
            role = self.roles.llm,
            reasoning = { content = delta },
            meta = json.response_id and { response_id = json.response_id } or nil,
          },
        }
      elseif json.type == "response.reasoning_text.done" then
        local text = json.text or json.content or ""
        if type(text) == "string" and text ~= "" then
          current.reasoning_text = text
        end
        if current.visible_reasoning_emitted then
          return nil
        end
        local reasoning = reasoning_metadata(current, true)
        return reasoning and { status = "success", output = { role = self.roles.llm, reasoning = reasoning } } or nil
      elseif json.type == "response.output_item.done" and json.item and json.item.type == "reasoning" then
        local text = reasoning_text(json.item)
        if text then
          current.reasoning_text = text
        end
        if current.visible_reasoning_emitted then
          return nil
        end
        local reasoning = reasoning_metadata(current, true)
        return reasoning and { status = "success", output = { role = self.roles.llm, reasoning = reasoning } } or nil
      end

      local terminal_reasoning
      if json.type == "response.completed" and json.response and type(json.response.output) == "table" then
        for _, item in ipairs(json.response.output) do
          if item.type == "reasoning" then
            local text = reasoning_text(item)
            if text then
              current.reasoning_text = text
            end
          end
        end
        terminal_reasoning = reasoning_metadata(current, true)
      end

      local result = base_parse_chat(self, data, tools)
      result = attach_reasoning_to_tool_result(self, json, result)
      if terminal_reasoning and type(result) == "table" and result.status == "success" then
        result.output.reasoning = terminal_reasoning
      end
      if json.type == "response.completed" or json.type == "response.failed" or json.type == "response.incomplete" or json.type == "error" then
        reset_state(self)
        self._maxa_stream_chat_bufnr = nil
        self._maxa_stream_chat_id = nil
      end
      return result
    end

    lifecycle.on_exit = function(self, data)
      reset_state(self)
      self._maxa_stream_chat_bufnr = nil
      self._maxa_stream_chat_id = nil
      return base_on_exit(self, data)
    end

    return adapter
  end
end

return M
