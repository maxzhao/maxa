local adapter_behavior = require("maxa.adapters.behavior")
local adapter_utils = require("maxa.utils.adapters")
local openai = require("maxa.adapters.http.openai")

local function ensure_temp(self)
  self.temp = self.temp or {}
  self.temp.openai_responses = self.temp.openai_responses or {}
  return self.temp.openai_responses
end

local function reset_state(self)
  self.temp = self.temp or {}
  self.temp.openai_responses = {}
  return self.temp.openai_responses
end

local function reset_terminal_state(self)
  reset_state(self)
  self._maxa_stream_chat_bufnr = nil
  self._maxa_stream_chat_id = nil
end

local function selected_model(self)
  local model = self.schema and self.schema.model and self.schema.model.default
  if type(model) == "function" then
    model = model(self)
  end
  return model
end

local function resolve_model_opts(self)
  local model = selected_model(self)
  local choices = self.schema and self.schema.model and self.schema.model.choices
  if type(choices) == "function" then
    choices = choices(self, { async = false })
  end
  local choice = type(choices) == "table" and choices[model] or nil
  return choice and choice.opts or nil
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

local function decode_error(json)
  if type(json) ~= "table" then
    return nil
  end

  local direct_response = json.object == "response" and json or nil
  local response = direct_response or (type(json.response) == "table" and json.response or nil)
  local is_error_event = json.type == "error" or json.type == "response.failed" or json.type == "response.incomplete"
  local is_failed_response = direct_response and direct_response.status ~= "completed"
  if not is_error_event and not is_failed_response then
    return nil
  end

  local err = type(json.error) == "table" and json.error
    or (response and type(response.error) == "table" and response.error)
    or (json.type == "error" and json or nil)
  local incomplete = response and type(response.incomplete_details) == "table" and response.incomplete_details or nil
  local response_status = response and response.status or nil
  local fallback_type = direct_response and ("response." .. tostring(response_status or "unknown")) or json.type
  return {
    type = (err and err.type) or fallback_type,
    code = (err and err.code) or (incomplete and incomplete.reason) or fallback_type,
    message = (err and err.message)
      or (incomplete and incomplete.reason)
      or response_status
      or "OpenAI Responses request failed",
    param = err and err.param or nil,
    reason = incomplete and incomplete.reason or (err and err.reason) or nil,
  }
end

local function error_result(json)
  local err = decode_error(json)
  return err and { status = "error", output = { error = err } } or nil
end

local function classification_string(json)
  local err = decode_error(json)
  if not err then
    return nil
  end
  return table.concat({
    tostring(err.code or ""),
    tostring(err.type or ""),
    tostring(err.message or ""),
    tostring(err.param or ""),
    tostring(err.reason or ""),
  }, " ")
end

local function function_tool(source)
  local copied = vim.deepcopy(source)
  local definition = copied["function"] or copied
  if type(definition.name) ~= "string" or definition.name == "" or type(definition.parameters) ~= "table" then
    error("OpenAI Responses function tool requires name and parameters")
  end
  local parameters = definition.parameters
  -- Preserve the existing fire encoded-object boundary, not strict all-required normalization.
  if definition.name == "fire" and parameters.properties and parameters.properties.data then
    parameters.properties.data = { type = { "string", "null" }, description = parameters.properties.data.description }
  end
  return {
    type = "function", name = definition.name, description = definition.description,
    parameters = parameters, strict = false,
  }
end

local function non_empty_call_id(value, context)
  if type(value) ~= "string" or value == "" then
    error("OpenAI Responses " .. context .. " requires a non-empty call_id")
  end
  return value
end

local function strip_internal_messages(messages)
  for index = #messages, 1, -1 do
    local message = messages[index]
    local tag = message._meta and message._meta.tag
    if tag == "ability_hook_tombstone"
      or tag == "auto_skill_dependency_call"
      or tag == "auto_skill_dependency_result"
    then
      table.remove(messages, index)
    elseif message._meta and message._meta._tool_summary_applied and message.tools and message.tools.calls
      and type(message.content) == "string"
    then
      message.content = nil
    end
  end
end

local function validate_initial_system_block(messages)
  local saw_non_system = false
  for index, message in ipairs(messages or {}) do
    if message.role == "system" and saw_non_system then
      error(string.format(
        "OpenAI Responses message order violation: system message at index %d appears after a non-system message",
        index
      ))
    end
    saw_non_system = saw_non_system or message.role ~= "system"
  end
end

local function tool_result_images(message)
  local images = {}
  local meta = message and message._meta
  if not (message and message.role == "tool" and meta) then
    return images
  end
  local seen = {}
  local function add(image)
    if type(image) ~= "table" or type(image.base64) ~= "string" or image.base64 == "" or image.expired or seen[image] then
      return
    end
    seen[image] = true
    images[#images + 1] = image
  end
  add(meta.image)
  for _, image in ipairs(type(meta.images) == "table" and meta.images or {}) do
    add(image)
  end
  return images
end

local function apply_image_details(messages, input)
  local details = {}
  for _, message in ipairs(messages) do
    if message._meta and message._meta.image_analysis and message.context and message.context.detail then
      details[#details + 1] = message.context.detail
    end
  end
  local index = 0
  for _, item in ipairs(input) do
    if item.role == "user" and type(item.content) == "table" then
      for _, part in ipairs(item.content) do
        if part.type == "input_image" then
          index = index + 1
          part.detail = details[index] or part.detail
        end
      end
    end
  end
end

local function inject_tool_images(messages, input)
  local images_by_call = {}
  for _, message in ipairs(messages) do
    local images = tool_result_images(message)
    local call_id = message.tools and message.tools.call_id
    if call_id and #images > 0 then
      images_by_call[call_id] = images
    end
  end

  local pending = {}
  for _, item in ipairs(input) do
    if item.type == "function_call_output" and item.call_id and images_by_call[item.call_id] then
      item.output = type(item.output) == "string" and item.output or tostring(item.output or "")
      vim.list_extend(pending, images_by_call[item.call_id])
    elseif item.role == "user" and #pending > 0 then
      if type(item.content) == "string" then
        item.content = { { type = "input_text", text = item.content } }
      elseif type(item.content) ~= "table" then
        item.content = { { type = "input_text", text = tostring(item.content or "") } }
      end
      for _, image in ipairs(pending) do
        item.content[#item.content + 1] = {
          type = "input_image",
          image_url = string.format("data:%s;base64,%s", image.mimetype, image.base64),
          detail = image.detail or "original",
        }
      end
      pending = {}
    end
  end

  if #pending > 0 then
    local content = { { type = "input_text", text = "Image returned by load_image tool for the next answer." } }
    for _, image in ipairs(pending) do
      content[#content + 1] = {
        type = "input_image",
        image_url = string.format("data:%s;base64,%s", image.mimetype, image.base64),
        detail = image.detail or "original",
      }
    end
    input[#input + 1] = { role = "user", content = content }
  end
end

local function reasoning_text(item)
  local parts = {}
  local blocks = item and (item.summary or item.content)
  if type(blocks) == "string" then
    parts[#parts + 1] = blocks
  elseif type(blocks) == "table" then
    for _, part in ipairs(blocks) do
        if type(part) == "table"
        and part.type == "summary_text"
        and type(part.text) == "string"
      then
        parts[#parts + 1] = part.text
      end
    end
  end
  return #parts > 0 and table.concat(parts, "") or nil
end

local function reasoning_value(item)
  local reasoning = {
    id = item and item.id or nil,
    encrypted_content = item and item.encrypted_content or nil,
    content = reasoning_text(item),
  }
  return next(reasoning) and reasoning or nil
end

local function update_reasoning_state(state, reasoning)
  if type(reasoning) ~= "table" then
    return nil
  end
  state.reasoning = state.reasoning or {}
  state.reasoning.id = reasoning.id or state.reasoning.id
  state.reasoning.encrypted_content = reasoning.encrypted_content or state.reasoning.encrypted_content
  if type(reasoning.content) == "string" and reasoning.content ~= "" then
    state.reasoning.content = reasoning.content
    state.reasoning_complete_content = reasoning.content
  end
  return state.reasoning
end

local function accumulated_reasoning(state, allow_visible_content)
  local reasoning = state.reasoning or {}
  local result = {
    id = reasoning.id,
    encrypted_content = reasoning.encrypted_content,
    _complete_content = state.reasoning_complete_content,
  }
  if allow_visible_content
    and not state.reasoning_delta_seen
    and not state.reasoning_full_emitted
    and type(state.reasoning_complete_content) == "string"
    and state.reasoning_complete_content ~= ""
  then
    result.content = state.reasoning_complete_content
    state.reasoning_full_emitted = true
  end
  return next(result) and result or nil
end

local function find_tool(tools, item)
  for _, tool in ipairs(type(tools) == "table" and tools or {}) do
    if item.call_id and tool.call_id == item.call_id then
      return tool
    end
    if item.id and tool.id == item.id then
      return tool
    end
    if item.output_index ~= nil and tool._index == item.output_index then
      return tool
    end
  end
end

local function append_function_tool(tools, item, allow_incomplete)
  if type(tools) ~= "table" or type(item) ~= "table" or item.type ~= "function_call" then
    return false
  end
  if not allow_incomplete and item.status ~= "completed" then
    return false
  end

  local tool = find_tool(tools, item)
  if not tool then
    tool = {
      id = item.id,
      call_id = item.call_id,
      type = "function",
      _index = item.output_index,
      _status = item.status,
      ["function"] = { name = item.name, arguments = item.arguments },
    }
    tools[#tools + 1] = tool
  else
    tool.id = item.id or tool.id
    tool.call_id = item.call_id or tool.call_id
    tool._index = item.output_index or tool._index
    tool._status = item.status or tool._status
    tool["function"] = tool["function"] or {}
    tool["function"].name = item.name or tool["function"].name
    if item.arguments ~= nil then
      tool["function"].arguments = item.arguments
    end
  end
  return true
end

local function fire_tool_argument_event(self, json)
  local event
  if json.type == "response.output_item.added" and json.item and json.item.type == "function_call" then
    event = "MaxaAIToolCallArgumentsStarted"
  elseif json.type == "response.function_call_arguments.delta" then
    event = "MaxaAIToolCallArgumentsDelta"
  elseif json.type == "response.function_call_arguments.done"
    or (json.type == "response.output_item.done" and json.item and json.item.type == "function_call")
  then
    event = "MaxaAIToolCallArgumentsDone"
  end
  local bufnr = self._maxa_stream_chat_bufnr
  if not event or type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local item = json.item or {}
  vim.api.nvim_exec_autocmds("User", {
    pattern = event,
    data = {
      bufnr = bufnr,
      id = self._maxa_stream_chat_id,
      item_id = json.item_id or item.id,
      call_id = json.call_id or item.call_id,
      output_index = json.output_index,
      index = json.index,
      name = item.name,
      delta_length = type(json.delta) == "string" and #json.delta or nil,
      arguments_length = type(json.arguments) == "string" and #json.arguments or nil,
    },
  })
end

local function success_output(self, output)
  local value = { role = self.roles.llm }
  for key, item in pairs(output or {}) do
    value[key] = item
  end
  return { status = "success", output = value }
end

local function reasoning_metadata(reasoning)
  if type(reasoning) ~= "table" then
    return nil
  end
  local result = {
    id = reasoning.id,
    encrypted_content = reasoning.encrypted_content,
    _complete_content = reasoning._complete_content,
  }
  return next(result) and result or nil
end

local function empty_success(self, response_id, reasoning)
  return success_output(self, {
    content = "",
    reasoning = reasoning,
    meta = response_id and { response_id = response_id } or nil,
  })
end

local function parse_output_items(self, items, tools, allow_incomplete)
  local text_parts = {}
  local reasoning
  local appended = false
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if item.type == "reasoning" then
      reasoning = reasoning_value(item) or reasoning
    elseif item.type == "message" and type(item.content) == "table" then
      for _, part in ipairs(item.content) do
        if part.type == "output_text" and type(part.text) == "string" then
          text_parts[#text_parts + 1] = part.text
        end
      end
    elseif item.type == "function_call" then
      appended = append_function_tool(tools, item, allow_incomplete) or appended
    end
  end
  return #text_parts > 0 and table.concat(text_parts, "") or nil, reasoning, appended
end

local function build_messages(self, source_messages)
  local messages = vim.deepcopy(source_messages or {})
  strip_internal_messages(messages)
  validate_initial_system_block(messages)

  local instructions = {}
  local input = {}
  local index = 1
  while index <= #messages do
    local message = messages[index]
    if message.role == "system" then
      instructions[#instructions + 1] = tostring(message.content or "")
    else
      if type(message.reasoning) == "table" then
        local item = { type = "reasoning", id = message.reasoning.id }
        if type(message.reasoning.content) == "string" and message.reasoning.content ~= "" then
          item.summary = { { type = "summary_text", text = message.reasoning.content } }
        end
        if message.reasoning.encrypted_content then
          item.encrypted_content = message.reasoning.encrypted_content
        end
        if item.id or item.summary or item.encrypted_content then
          input[#input + 1] = item
        end
      end

      if message._meta and message._meta.tag == "image" and message.context and message.context.mimetype then
        if self.opts and self.opts.vision then
          local next_message = messages[index + 1]
          local content = {
            { type = "input_image", image_url = string.format("data:%s;base64,%s", message.context.mimetype, message.content) },
          }
          if next_message and next_message.role == message.role and type(next_message.content) == "string"
            and not (next_message._meta and next_message._meta.tag == "image")
          then
            content[#content + 1] = { type = "input_text", text = next_message.content }
            index = index + 1
          end
          input[#input + 1] = { role = message.role, content = content }
        end
      elseif message.role == "tool" then
        input[#input + 1] = {
          type = "function_call_output",
          call_id = non_empty_call_id(message.tools and message.tools.call_id, "function output"),
          output = type(message.content) == "string" and message.content or tostring(message.content or ""),
        }
      elseif message.tools and message.tools.calls then
        for _, call in ipairs(message.tools.calls) do
          local definition = call["function"]
          if type(call.id) ~= "string" or call.id == "" then
            error("OpenAI Responses function call requires a non-empty id")
          end
          if type(definition) ~= "table" or type(definition.name) ~= "string" or definition.name == "" then
            error("OpenAI Responses function call requires a non-empty function name")
          end
          if type(definition.arguments) ~= "string" then
            error("OpenAI Responses function call requires string arguments")
          end
          local item = {
            type = "function_call",
            id = call.id,
            call_id = non_empty_call_id(call.call_id, "function call"),
            name = definition.name,
            arguments = definition.arguments,
          }
          -- Expanded members and dependency catalogs have local history IDs,
          -- not provider-issued item IDs. Replay inline; call_id pairs the output.
          if type(call._multicall_member) == "table"
            or (message._meta and message._meta.ability_dependency_catalog)
          then
            item.id = nil
          end
          input[#input + 1] = item
        end
      else
        input[#input + 1] = { role = message.role, content = message.content }
      end
    end
    index = index + 1
  end

  apply_image_details(messages, input)
  inject_tool_images(messages, input)
  return adapter_behavior.deep_ensure_utf8({
    instructions = #instructions > 0 and table.concat(instructions, "\n") or nil,
    input = input,
  })
end

---@class MaxaAI.HTTPAdapter.OpenAIResponses: MaxaAI.HTTPAdapter
return {
  name = "openai_responses",
  formatted_name = "OpenAI_Responses",
  roles = { llm = "assistant", user = "user", tool = "tool" },
  opts = { stream = true, tools = true, vision = true },
  features = { text = true, tokens = true },
  url = "https://api.openai.com/v1/responses",
  env = { api_key = "OPENAI_API_KEY" },
  parameters = { store = false },
  available_tools = {
    web_search = {
      description = "Allow models to search the web for the latest information before generating a response.",
      enabled = true,
      callback = function(_, tools)
        tools[#tools + 1] = { type = "web_search" }
      end,
    },
  },
  headers = { ["Content-Type"] = "application/json", Authorization = "Bearer ${api_key}" },
  handlers = {
    lifecycle = {
      setup = function(self)
        adapter_behavior.reset_usage(self)
        reset_state(self)
        local opts = resolve_model_opts(self)
        self.opts.vision = not opts or opts.has_vision ~= false
        self.opts.tools = not opts or opts.has_function_calling ~= false
        if opts and opts.stream ~= nil then
          self.opts.stream = opts.stream
        end
        self.parameters.stream = self.opts.stream == true
        return true
      end,
      on_exit = function(self, data)
        reset_terminal_state(self)
        return openai.handlers.on_exit(self, data)
      end,
    },
    request = {
      build_parameters = function(self, params)
        reset_state(self)
        local opts = resolve_model_opts(self)
        if opts and opts.can_reason then
          params.include = { "reasoning.encrypted_content" }
        end
        return params
      end,
      build_messages = build_messages,
      build_tools = function(self, tools)
        if not self.opts.tools or type(tools) ~= "table" or vim.tbl_count(tools) == 0 then
          return nil
        end
        local transformed = {}
        for _, group in pairs(tools) do
          for _, schema in pairs(group) do
            if schema._meta and schema._meta.adapter_tool then
              local available = self.available_tools and self.available_tools[schema.name]
              if available then
                available.callback(self, transformed)
              end
            else
              transformed[#transformed + 1] = function_tool(schema)
            end
          end
        end
        adapter_behavior.sort_tools(transformed)
        return { tools = transformed }
      end,
      build_reasoning = function(_, data)
        local reasoning = {}
        local content = {}
        local complete_content
        for _, item in ipairs(data or {}) do
          if type(item) == "table" then
            if type(item.content) == "string" then
              content[#content + 1] = item.content
            end
            if type(item._complete_content) == "string" and item._complete_content ~= "" then
              complete_content = item._complete_content
            end
            reasoning.id = item.id or reasoning.id
            reasoning.encrypted_content = item.encrypted_content or reasoning.encrypted_content
          elseif type(item) == "string" then
            content[#content + 1] = item
          end
        end
        reasoning.content = complete_content or (#content > 0 and table.concat(content, "") or nil)
        return next(reasoning) and reasoning or nil
      end,
    },
    response = {
      parse_error = function(_, data)
        local json = decode(data)
        return json and classification_string(json) or nil
      end,
      parse_chat = function(self, data, tools)
        local json = decode(data)
        if not json then
          return nil
        end
        local incomplete_response = (json.type == "response.incomplete" and json.response)
          or (json.object == "response" and json.status == "incomplete" and json)
        if incomplete_response then
          local content, reasoning, appended = parse_output_items(self, incomplete_response.output, tools, true)
          if appended or (type(tools) == "table" and #tools > 0) then
            for _, tool in ipairs(tools or {}) do
              tool._status = tool._status or "incomplete"
            end
            reset_terminal_state(self)
            return success_output(self, {
              content = content or "",
              reasoning = reasoning,
              meta = incomplete_response.id and { response_id = incomplete_response.id } or nil,
            })
          end
        end

        local failed = error_result(json)
        if failed then
          reset_terminal_state(self)
          return failed
        end

        if not self.opts.stream then
          if json.object ~= "response" or json.status ~= "completed" then
            local result = error_result(json)
              or error_result({
                object = "response",
                status = "invalid_response",
                error = {
                  type = "invalid_response",
                  code = "invalid_response",
                  message = "OpenAI Responses non-streamed body must be a completed response object",
                },
              })
            reset_terminal_state(self)
            return result
          end
          local content, reasoning = parse_output_items(self, json.output, tools)
          local result = success_output(self, {
            content = content,
            reasoning = reasoning,
            meta = json.id and { response_id = json.id } or nil,
          })
          reset_terminal_state(self)
          return result
        end

        fire_tool_argument_event(self, json)
        local state = ensure_temp(self)
        if json.type == "response.created" then
          state = reset_state(self)
          state.response_id = json.response and json.response.id or json.response_id
          return nil
        end

        local response_id = json.response_id or state.response_id
        if json.type == "response.output_item.added" and json.item and json.item.type == "function_call" then
          local item = vim.deepcopy(json.item)
          item.output_index = json.output_index or item.output_index
          append_function_tool(tools, item, true)
          return nil
        elseif json.type == "response.function_call_arguments.delta" then
          local item = {
            type = "function_call",
            id = json.item_id,
            call_id = json.call_id,
            output_index = json.output_index,
          }
          local tool = find_tool(tools, item)
          if tool then
            tool["function"] = tool["function"] or {}
            tool["function"].arguments = (tool["function"].arguments or "") .. (json.delta or "")
          end
          return nil
        elseif json.type == "response.function_call_arguments.done" then
          local item = {
            type = "function_call",
            id = json.item_id,
            call_id = json.call_id,
            output_index = json.output_index,
            arguments = json.arguments,
          }
          append_function_tool(tools, item, true)
          return nil
        elseif json.type == "response.output_text.delta" then
          state.output_text_delta_seen = true
          return success_output(self, { content = json.delta or "", meta = response_id and { response_id = response_id } or nil })
        elseif json.type == "response.reasoning_summary_text.delta" then
          state.reasoning_delta_seen = true
          return success_output(self, {
            reasoning = { content = json.delta or "" },
            meta = response_id and { response_id = response_id } or nil,
          })
        elseif json.type == "response.output_item.done" and json.item and json.item.type == "reasoning" then
          update_reasoning_state(state, reasoning_value(json.item))
          local reasoning = accumulated_reasoning(state, true)
          if reasoning then
            return success_output(self, {
              reasoning = reasoning,
              meta = response_id and { response_id = response_id } or nil,
            })
          end
        elseif json.type == "response.output_item.done" and json.item and json.item.type == "function_call" then
          local appended = append_function_tool(tools, json.item, true)
          if appended and json.item.status == "completed" then
            return empty_success(self, response_id, reasoning_metadata(accumulated_reasoning(state, false)))
          end
        elseif json.type == "response.completed" then
          local response = json.response or {}
          local content, reasoning, appended = parse_output_items(self, response.output, tools)
          update_reasoning_state(state, reasoning)
          local terminal_reasoning = accumulated_reasoning(state, true)
          if state.reasoning_delta_seen or state.reasoning_full_emitted then
            terminal_reasoning = reasoning_metadata(terminal_reasoning)
          end
          local terminal_content = state.output_text_delta_seen and "" or (content or "")
          local result
          if content ~= nil or terminal_reasoning ~= nil or appended or response.output == nil or vim.tbl_isempty(response.output) then
            result = success_output(self, {
              content = terminal_content,
              reasoning = terminal_reasoning,
              meta = (response.id or response_id) and { response_id = response.id or response_id } or nil,
            })
          end
          reset_terminal_state(self)
          return result
        end
        return nil
      end,
      parse_metrics = function(_, data)
        local json = decode(data)
        if not json then return nil end
        local observation = { usage = adapter_behavior.usage(json), error = decode_error(json) ~= nil, bytes = 0 }
        if json.type == "response.output_text.delta" or json.type == "response.reasoning_summary_text.delta"
          or json.type == "response.function_call_arguments.delta" then
          observation.bytes = adapter_behavior.output_bytes(json.delta)
          observation.phase = json.type == "response.function_call_arguments.delta" and "tool_args" or "response"
        elseif json.type == "response.output_item.added" and json.item and json.item.type == "function_call" then
          observation.bytes = adapter_behavior.output_bytes(json.item.name)
          observation.first_output = true
          observation.phase, observation.tool_started, observation.tool_id = "tool_args", true, json.item.id or json.item.call_id
        elseif json.type == "response.function_call_arguments.done"
          or (json.type == "response.output_item.done" and json.item and json.item.type == "function_call") then
          observation.phase, observation.tool_done = "response", true
          observation.tool_id = json.item_id or (json.item and (json.item.id or json.item.call_id))
        elseif json.type == "response.completed" or json.object == "response" then
          observation.phase, observation.tool_done_all = "response", true
          local response = json.response or json
          observation.fallback_bytes = 0
          for _, item in ipairs(response.output or {}) do
            if item.type == "function_call" then
              observation.fallback_bytes = observation.fallback_bytes + adapter_behavior.output_bytes(item.name, item.arguments)
            elseif item.type == "reasoning" then
              observation.fallback_bytes = observation.fallback_bytes + adapter_behavior.output_bytes(reasoning_text(item))
            elseif item.type == "message" then
              for _, part in ipairs(item.content or {}) do
                observation.fallback_bytes = observation.fallback_bytes + adapter_behavior.output_bytes(part.text)
              end
            end
          end
        end
        return observation
      end,
      parse_tokens = function(self, data)
        adapter_behavior.record_usage(self, data)
        local json = decode(data)
        if json and json.type == "response.completed" and json.response and json.response.usage then
          return json.response.usage.total_tokens
        end
      end,
    },
    tools = {
      can_replay_call = function(_, tool_call)
        local fn = type(tool_call) == "table" and tool_call["function"] or nil
        if type(tool_call) ~= "table" or type(tool_call.id) ~= "string" or tool_call.id == "" then
          return false, "OpenAI Responses function call requires a non-empty id"
        end
        if type(tool_call.call_id) ~= "string" or tool_call.call_id == "" then
          return false, "OpenAI Responses function call requires a non-empty call_id"
        end
        if type(fn) ~= "table" or type(fn.name) ~= "string" or fn.name == "" then
          return false, "OpenAI Responses function call requires a non-empty name"
        end
        if type(fn.arguments) ~= "string" then
          return false, "OpenAI Responses function call arguments must be a JSON string"
        end
        return true
      end,
      format_calls = function(_, tools)
        -- Chat-owned validation decides whether each canonical call can be replayed.
        return tools
      end,
      format_response = function(self, tool_call, output, _)
        return {
          role = self.roles.tool or "tool",
          tools = {
            id = tool_call.id,
            call_id = non_empty_call_id(tool_call.call_id, "function output"),
          },
          content = output,
          opts = { visible = false },
        }
      end,
    },
  },
  schema = {
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "ID of the model to use. See the model endpoint compatibility table for details on which models work with the Responses API.",
      default = "gpt-5-2025-08-07",
      choices = {
        ["gpt-5-2025-08-07"] = { formatted_name = "GPT-5", opts = { has_function_calling = true, has_vision = true, can_reason = true } },
        ["codex-mini-latest"] = { formatted_name = "Codex-mini", opts = { has_function_calling = true, has_vision = true, can_reason = true } },
        ["gpt-5-codex"] = { formatted_name = "GPT-5 Codex", opts = { has_function_calling = true, has_vision = true, can_reason = true } },
        ["gpt-5-chat-latest"] = { formatted_name = "GPT-5 Chat", opts = { has_function_calling = true, has_vision = true } },
        ["gpt-5-pro-2025-10-06"] = { formatted_name = "GPT-5 Pro", opts = { has_function_calling = true, has_vision = true, can_reason = true, stream = false } },
        ["o4-mini-deep-research-2025-06-26"] = { formatted_name = "o4-mini-deep-research", opts = { has_function_calling = false, has_vision = true, can_reason = true } },
        ["o3-deep-research-2025-06-26"] = { formatted_name = "o3-deep-research", opts = { has_function_calling = false, has_vision = true, can_reason = true } },
        ["o3-pro-2025-06-10"] = { formatted_name = "o3-pro", opts = { has_function_calling = false, has_vision = true, can_reason = true, stream = false } },
        ["o1-pro-2025-03-19"] = { formatted_name = "o1-pro", opts = { has_function_calling = true, has_vision = true, can_reason = true, stream = false } },
      },
    },
    ["reasoning.effort"] = {
      order = 2,
      mapping = "parameters",
      type = "string",
      optional = true,
      enabled = function(self)
        local opts = resolve_model_opts(self)
        return opts and opts.can_reason == true or false
      end,
      desc = "Constrains effort on reasoning for reasoning models.",
      choices = { "high", "medium", "low", "minimal" },
    },
    ["reasoning.summary"] = {
      order = 3,
      mapping = "parameters",
      type = "string",
      optional = true,
      enabled = function(self)
        local opts = resolve_model_opts(self)
        return opts and opts.can_reason == true or false
      end,
      default = "auto",
      desc = "A summary of the reasoning performed by the model.",
      choices = { "auto", "concise", "detailed" },
    },
    temperature = {
      order = 4,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 1,
      desc = "Sampling temperature between 0 and 2.",
      validate = function(value) return value >= 0 and value <= 2, "Must be between 0 and 2" end,
    },
    top_logprobs = {
      order = 5,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = nil,
      desc = "Number of most likely tokens to return at each token position.",
      validate = function(value) return value >= 0 and value <= 20, "Must be between 0 and 20" end,
    },
    top_p = {
      order = 6,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 1,
      desc = "Nucleus sampling probability mass.",
      validate = function(value) return value >= 0 and value <= 1, "Must be between 0 and 1" end,
    },
    max_output_tokens = {
      order = 7,
      mapping = "parameters",
      type = "integer",
      optional = true,
      default = nil,
      desc = "Maximum response tokens.",
      validate = function(value) return value > 0, "Must be greater than 0" end,
    },
    verbosity = {
      order = 8,
      mapping = "parameters.text",
      type = "string",
      optional = true,
      default = "medium",
      desc = "Determines how many output tokens are generated.",
      choices = { "low", "medium", "high" },
    },
  },
}
