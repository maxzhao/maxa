-- Shared nested tool-call logic for Chat builtins and Ability targets.
-- run and multicall use this owner for validation, dispatch,
-- output limiting, side effects, and error normalization.
local Path = require("plenary.path")
local builtin_utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

local M = {}

local IMAGE_OUTPUT_DIR = "/tmp/mcpx_tool_images"

-- Administrator/tool policy lives in the exact workspace catalog. Keep this
-- optional local deny-list in canonical Ability address form only.
local DISABLED_COMMANDS = {}

local HIDDEN_IMAGE_ANALYSIS_BLOCKED_TOOLS = {
  ["analyze"] = true,
  ["@subagent:fork_agent"] = true,
  ["@subagent:multi_agent"] = true,
  ["@subagent:resume_agent"] = true,
  ["@subagent:run_agent"] = true,
}

local HIDDEN_IMAGE_ANALYSIS_WRAPPERS = {
  ["multicall"] = true,
}

-- Output limiting rules. First match wins and uses canonical builtin or
-- `@ability:target` addresses.
local OUTPUT_LIMIT_EXEMPT_RULES = {
  "analyze",
  "multicall",
  "kill",
  "delete",
  "edit",
  "run",
  "fire",
  "wait",
  "keep",
  "load",
  "move",
  "read",
  "write",
  "search",
  "glob",
  "@browser:*",
  "@subagent:*",
}
local function matches_pattern(tool_full_name, pattern)
  local escaped = pattern:gsub("([%-%.%+%[%]%(%)%$%^%%])", "%%%1")
  local lua_pattern = "^" .. escaped:gsub("%*", ".*") .. "$"
  return tostring(tool_full_name or ""):match(lua_pattern) ~= nil
end

local function matches_pattern_list(tool_full_name, patterns)
  for _, pattern in ipairs(patterns) do
    if matches_pattern(tool_full_name, pattern) then
      return true
    end
  end
  return false
end

function M.is_command_disabled(tool_full_name)
  return matches_pattern_list(tool_full_name, DISABLED_COMMANDS)
end

function M.hidden_image_analysis_guard(context, tool_full_name)
  local chat = context
    and context.caller
    and context.caller.maxa_ai
    and context.caller.maxa_ai.chat
    or nil
  if not (chat and chat._maxa_hidden_image_analysis) then
    return nil
  end
  local blocked = HIDDEN_IMAGE_ANALYSIS_BLOCKED_TOOLS[tool_full_name]
  if not blocked and HIDDEN_IMAGE_ANALYSIS_WRAPPERS[tool_full_name] then
    blocked = true
  end
  if blocked then
    return string.format(
      "Hidden image-analysis child cannot call '%s'; delegation, recursive analyze, and wrapper bypasses are disabled for its hard max_steps budget.",
      tostring(tool_full_name)
    )
  end
  return nil
end

local function needs_output_limit(tool_full_name)
  for _, rule in ipairs(OUTPUT_LIMIT_EXEMPT_RULES) do
    local is_default_rule = rule:sub(1, 1) == "!"
    local pattern = is_default_rule and rule:sub(2) or rule

    if matches_pattern(tool_full_name, pattern) then
      return is_default_rule
    end
  end

  return true
end

local function write_limited_output_file(output, prefix)
  local timestamp = os.time()
  local log_file = string.format("/tmp/%s_%d_%s.log", prefix or "mcpx_call", timestamp, tostring(vim.uv.hrtime()))
  local log_path = Path:new(log_file)
  log_path:write(output, "w")
  return log_file
end

local function output_stats(output)
  local lines = vim.split(output, "\n", { plain = true })
  local line_count = #lines
  local max_line_chars = 0
  for _, line in ipairs(lines) do
    if #line > max_line_chars then
      max_line_chars = #line
    end
  end
  return {
    chars = #output,
    lines = line_count,
    max_line_chars = max_line_chars,
  }
end

function M.handle_output_limit(output, tool_full_name)
  local output_char_count = #output
  local MAX_OUTPUT_CHARS = builtin_utils.MAX_OUTPUT_CHARS

  if output_char_count <= MAX_OUTPUT_CHARS then
    return output
  end

  local log_file = write_limited_output_file(output, "mcpx_call")
  local preview = vim.fn.strcharpart(output, 0, 240):gsub("\r", "\\r"):gsub("\n", "\\n")
  return string.format("Preview: %s…\nFull output: %s\nSize: %d chars", preview, log_file, output_char_count)
end

local function trim_to_chars(text, max_chars)
  text = tostring(text or "")
  max_chars = tonumber(max_chars) or 0
  if max_chars <= 0 or #text <= max_chars then
    return text
  end
  return text:sub(1, max_chars) .. "\n... <truncated>"
end

function M.handle_error_output_limit(error_text, tool_full_name, opts)
  opts = opts or {}
  error_text = tostring(error_text or "")

  local max_chars = opts.max_chars or builtin_utils.MAX_ERROR_OUTPUT_CHARS or builtin_utils.MAX_OUTPUT_CHARS
  if #error_text <= max_chars then
    return error_text
  end

  local stats = output_stats(error_text)
  local log_file = write_limited_output_file(error_text, "mcpx_call_error")
  local preview = trim_to_chars(error_text, opts.preview_chars or builtin_utils.MAX_ERROR_PREVIEW_CHARS or max_chars)

  local lines = {
    "Error output exceeds limit.",
    "Full error: " .. log_file,
    string.format("Size: %d bytes; %d lines", stats.chars, stats.lines),
    "---",
    preview,
  }

  return table.concat(lines, "\n")
end

local function compact_hook_reason(reason)
  reason = tostring(reason or "")
  local max_chars = builtin_utils.MAX_ERROR_OUTPUT_CHARS or 4096
  if #reason <= max_chars then
    return reason
  end
  return trim_to_chars(reason, builtin_utils.MAX_ERROR_PREVIEW_CHARS or 2048)
end

local function image_ext_from_mime(mime_type)
  local mime = tostring(mime_type or "image/png"):lower()
  local subtype = mime:match("^image/([^;%s]+)") or "png"
  subtype = subtype:gsub("%+xml$", "")
  if subtype == "jpg" then
    return "jpeg"
  end
  subtype = subtype:gsub("[^%w]+", "")
  if subtype == "" then
    return "png"
  end
  return subtype
end

local function sanitize_filename_part(value, fallback)
  local part = tostring(value or "")
  part = part:gsub("^%s+", ""):gsub("%s+$", "")
  part = part:gsub("[^%w%._%-]+", "_")
  part = part:gsub("_+", "_")
  part = part:gsub("^[_%.%-]+", ""):gsub("[_%.%-]+$", "")
  if part == "" then
    return fallback
  end
  return part
end

local function save_mcp_image_content(item, tool_full_name, index)
  local image_data = item and item.data
  if type(image_data) ~= "string" or vim.trim(image_data) == "" then
    return nil, "MCP image content is missing base64 data"
  end

  local mime_type = item.mimeType or item.mime_type or "image/png"
  local ext = image_ext_from_mime(mime_type)
  local output_dir = IMAGE_OUTPUT_DIR
  local dir = Path:new(output_dir)
  if not dir:exists() then
    local ok, mkdir_err = pcall(function()
      dir:mkdir({ parents = true })
    end)
    if not ok then
      return nil, "Failed to create MCP image output directory: " .. tostring(mkdir_err)
    end
  elseif not dir:is_dir() then
    return nil, "MCP image output path exists but is not a directory: " .. output_dir
  end

  local raw_b64 = image_data:match("^data:[^,]+,(.+)$") or image_data
  local ok, decoded = pcall(vim.base64.decode, raw_b64)
  if not ok or type(decoded) ~= "string" then
    return nil, "Failed to decode MCP image base64 data"
  end

  local prefix = sanitize_filename_part(tool_full_name, "mcp_tool_image")
  local stamp = os.date("%Y%m%d_%H%M%S")
  local hr = tostring(vim.uv.hrtime())
  local output_path = string.format("%s/%s_%s_%s_%02d.%s", output_dir, prefix, stamp, hr, index or 1, ext)

  local file, open_err = io.open(output_path, "wb")
  if not file then
    return nil, "Failed to open MCP image output file: " .. tostring(open_err)
  end
  local write_ok, write_err = file:write(decoded)
  file:close()
  if not write_ok then
    return nil, "Failed to write MCP image output file: " .. tostring(write_err)
  end

  return {
    path = output_path,
    bytes = #decoded,
    mime_type = tostring(mime_type),
    format = ext,
    base64_chars = #image_data,
  },
    nil
end

function M.resolve_call_params(raw_params)
  for _, key in ipairs({ "json_patches", "json", "json_path" }) do
    if raw_params[key] ~= nil then return nil, key .. " is no longer supported." end
  end
  local params = raw_params.params
  if params == nil or params == vim.NIL then return {} end
  if type(params) == "string" then
    local ok, parsed = pcall(vim.json.decode, params)
    if not ok or type(parsed) ~= "table" or not params:match("^%s*{") then
      return nil, "params must decode to a JSON object."
    end
    return parsed
  end
  if type(params) ~= "table" then return nil, "params must be an object." end
  return params
end

local function build_saved_image_text(saved, tool_full_name, index)
  local lines = {
    "🖼️ MCP image content saved to local file",
    "",
    "- Tool: " .. tostring(tool_full_name),
    "- Image index: " .. tostring(index or 1),
    "- Path: `" .. saved.path .. "`",
    "- MIME type: " .. tostring(saved.mime_type),
    "- Format: " .. tostring(saved.format),
    "- Bytes: " .. tostring(saved.bytes or 0),
    "- Original base64 chars: " .. tostring(saved.base64_chars or 0),
    "",
    "To analyze it with image-aware context:",
    '`analyze(images={{path="'
      .. saved.path
      .. '", target_long_edge=760}}, analysis_prompt="Describe the task-relevant visible evidence and any uncertainty.", max_steps=1)`',
  }
  return table.concat(lines, "\n")
end

local function fire_tool_call_error(caller_bufnr, tool_full_name, reason, params)
  local fire_ok, fire = pcall(require, "maxa.abilities.hooks.fire")
  if fire_ok and caller_bufnr then
    fire.fire("ToolCallError", {
      bufnr = caller_bufnr,
      tool_id = tool_full_name,
      reason = compact_hook_reason(reason),
      params = vim.inspect(params):sub(1, 500),
    })
  end
end

function M.get_caller_bufnr(context)
  return context and context.bufnr or nil
end

local function fail(done, message, tool_full_name)
  if tool_full_name then
    message = M.handle_error_output_limit(message, tool_full_name)
  end
  return done({ ok = false, error = message })
end

function M.with_wrapper_context(context, tool_full_name, opts, fn)
  local wrapped_registry_ok, wrapped_registry = pcall(
    require,
    "maxa.interactions.chat.tools.builtin.runtime.wrapped_side_effect_registry"
  )
  local wrapped_ctx = wrapped_registry_ok and wrapped_registry.context_for(context, tool_full_name, opts) or nil
  local cancel_bridge_ok, cancel_bridge = pcall(
    require,
    "maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge"
  )
  local cancel_ctx = cancel_bridge_ok and opts.async_id and {
    async_id = opts.async_id,
    outer_tool_name = opts.outer_tool_name,
    inner_tool_name = tool_full_name,
    label = opts.label,
    index = opts.index,
  } or (context and context.cancel_context)

  if wrapped_ctx and wrapped_registry.with_context then
    local inner = fn
    fn = function()
      return wrapped_registry.with_context(wrapped_ctx, inner)
    end
  end
  if cancel_ctx and cancel_bridge.with_context then
    local inner = fn
    fn = function()
      return cancel_bridge.with_context(cancel_ctx, inner)
    end
  end
  return fn()
end

local function execute_builtin(context, definition, tool_full_name, params, done, opts)
  local active = context and context.active_wrappers or {}
  if active[tool_full_name] then
    return fail(done, "Recursive wrapper call is not allowed: " .. tool_full_name, tool_full_name)
  end

  -- Capture original target arguments before execution-only title inheritance.
  local display_args = vim.deepcopy(params)
  if context.ui then
    require("maxa.interactions.chat.tools.display").bind_target(context.ui, definition, display_args)
  end
  -- Only first-party required display titles inherit; MCP business fields stay untouched.
  local schema = definition.inputSchema
  local title = context and context.params and context.params.title
  if schema and schema.properties and schema.properties.title
    and vim.tbl_contains(schema.required or {}, "title") and param_utils.is_absent(params.title)
    and type(title) == "string" and title:find("%S") then
    params = vim.tbl_extend("force", {}, params, { title = title })
  end

  local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
  local child = adapter.child_context(context, tool_full_name, params)
  local cached = context.native_prepared_target
  local prepared = cached and cached.name == tool_full_name and cached.definition == definition
    and vim.deep_equal(cached.raw_params, params)
  if prepared then child.params = cached.context.params end
  local called = false
  return M.with_wrapper_context(context, tool_full_name, opts, function()
    return adapter.invoke(definition, child, function(result)
      if called then
        return nil
      end
      called = true
      if not result.ok then
        return fail(done, result.error or "Unknown error", tool_full_name)
      end
      local content = result.content or {}
      if needs_output_limit(tool_full_name) then
        for _, item in ipairs(content) do
          if item.type == "text" and item.text then
            item.text = M.handle_output_limit(item.text, tool_full_name)
          end
        end
      end
      return done({ ok = true, tool = tool_full_name, content = content })
    end, prepared == true)
  end)
end

local function parse_ability_target(target)
  if type(target) ~= "string" or target:sub(1, 1) ~= "@" then
    return nil, nil, "Ability target must begin with @"
  end
  local ability_name, suffix = target:sub(2):match("^([^:]+):(.+)$")
  local catalog = require("maxa.abilities.catalog")
  if not ability_name or not suffix or not catalog.valid_identifier(ability_name) then
    return nil, nil, "Invalid Ability target; expected @<ability>:<nonempty-target>"
  end
  return ability_name, suffix
end

local function script_argv(script, args)
  local argv = {}
  if script.executor then
    for _, token in ipairs(script.executor.command or {}) do
      token = token:gsub("{root}", function()
        return script.root
      end):gsub("{script}", function()
        return script.path
      end)
      argv[#argv + 1] = token
    end
  else
    argv[1] = script.path
  end
  vim.list_extend(argv, args or {})
  return argv
end

local function execute_ability_script(context, tool_full_name, script, params, done, opts)
  for key in pairs(params or {}) do
    if key ~= "args" then
      return fail(done, "Ability script params accept only args: string[]", tool_full_name)
    end
  end
  local args = params and params.args or {}
  if type(args) ~= "table" or not (vim.islist or vim.tbl_islist)(args) then
    return fail(done, "Ability script args must be a string array", tool_full_name)
  end
  for index, value in ipairs(args) do
    if type(value) ~= "string" then
      return fail(done, string.format("Ability script args[%d] must be a string", index), tool_full_name)
    end
  end

  local definition = require("maxa.interactions.chat.tools.builtin.tools.builtin_run")
  local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
  local child = adapter.child_context(context, tool_full_name, {
    argv = script_argv(script, args),
    cwd = context.cwd,
    timeout = 300,
    opts = vim.json.encode({ pty = false, async = false }),
  })
  child.ability_script = true
  local called = false
  return M.with_wrapper_context(context, tool_full_name, opts, function()
    return adapter.invoke(definition, child, function(result)
      if called then
        return nil
      end
      called = true
      if not result.ok then
        return fail(done, result.error or "Unknown script error", tool_full_name)
      end
      return done({ ok = true, tool = tool_full_name, content = result.content or {} })
    end)
  end)
end

-- Side-effect-free target resolution. Shared by batch preflight and dispatch;
-- a disconnected authorized source is resolved without starting it.
function M.resolve_target(context, tool_full_name, done)
  local function reject(message) return done(nil, message) end
  if tool_full_name == "run" or tool_full_name == "multicall" then
    return reject("run cannot call " .. tool_full_name .. ".")
  end
  local valid, error_msg = builtin_utils.validate_required_string(tool_full_name, "tool")
  if not valid then return reject(error_msg or "Invalid tool") end
  local blocked_error = M.hidden_image_analysis_guard(context, tool_full_name)
  if blocked_error then return reject(blocked_error) end
  if tool_full_name:sub(1, 1) ~= "@" then
    local definition = require("maxa.interactions.chat.tools.builtin").resolve(tool_full_name)
    if not definition then return reject("Unknown Chat builtin: " .. tool_full_name) end
    return done({ kind = "builtin", definition = definition })
  end
  if M.is_command_disabled(tool_full_name) then
    return reject(string.format("Command '%s' is disabled. This command has been blocked for security or policy reasons.", tool_full_name))
  end

  local chat = context and (context.chat or (context.caller and context.caller.maxa_ai and context.caller.maxa_ai.chat))
  local cwd = context and context.cwd
  if not chat or type(cwd) ~= "string" or cwd == "" then
    return reject("Exact Chat/workspace context is unavailable for MCP dispatch")
  end
  local ability_name, target, target_err = parse_ability_target(tool_full_name)
  if not ability_name then
    return reject(target_err)
  end
  local ability_state = require("maxa.session.abilities")
  if target:sub(1, 1) == "/" then
    local script, script_err = ability_state.resolve_script(chat, cwd, ability_name, target)
    if not script then
      return reject(script_err)
    end
    return done({ kind = "script", script = script })
  end
  local matched, match_err = ability_state.resolve_tool(chat, cwd, ability_name, target)
  if not matched then
    return reject(match_err)
  end

  local server_name = matched.server_name
  local tool_name = matched.tool_name
  local transport = require("maxa.mcphub").get_project_transport()

  transport.inspect_server(cwd, server_name, function(connection, inspect_err, current_resolved)
    if inspect_err or not connection then
      return reject(string.format("Failed to inspect authorized MCP Server '%s': %s", server_name, tostring(inspect_err)))
    end

    local config_err
    if not current_resolved then
      current_resolved, config_err = transport.resolve(cwd)
    end
    local effective = current_resolved and current_resolved.catalog
    if not effective then return reject("Failed to revalidate MCP tool configuration: " .. tostring(config_err)) end
    local configured = effective.servers[server_name]
    if not configured then
      return reject("Authorized MCP Server is no longer configured: " .. server_name)
    end
    local config_manager = require("maxa.mcphub.utils.config_manager")
    local allowed, policy_err = require("maxa.project.settings").check_ability(chat.opts.project_root or cwd, server_name)
    if not allowed then return reject(policy_err) end
    if config_manager.is_effective_tool_disabled(effective, server_name, tool_name) then
      return reject(string.format("MCP tool '%s' is currently disabled by the exact workspace configuration", tool_full_name))
    end

    local definition
    if configured.is_native then
      for _, candidate in ipairs(connection.server and connection.server.capabilities.tools or {}) do
        if candidate.name == tool_name then definition = candidate; break end
      end
      if not definition then return reject("Authorized Native tool definition unavailable: " .. tool_full_name) end
    end
    return done({ kind = "mcp", definition = definition, tool = matched.tool, connected = connection.connected == true,
      transport = transport, cwd = cwd, server_name = server_name, tool_name = tool_name })
  end)
end

-- Validate a native member's nested target without executing/reconnecting it.
function M.preflight(context, tool_name, target_params, done)
  return M.resolve_target(context, tool_name, function(target, err)
    if not target then return done(err) end
    if target.definition and target.definition.interactive then
      return done("Interactive tool is prohibited in multicall: " .. tool_name)
    end
    if target.kind == "builtin" then
      local schema = target.definition.inputSchema
      local title = context.params.title
      if schema and schema.properties and schema.properties.title
        and vim.tbl_contains(schema.required or {}, "title") and param_utils.is_absent(target_params.title) then
        target_params = vim.tbl_extend("force", {}, target_params, { title = title })
      end
      local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
      local child = adapter.child_context(context, tool_name, target_params)
      local prepared, prepare_err = adapter.prepare(target.definition, child)
      if not prepared then return done(prepare_err) end
      local _, extension_err = require("maxa.interactions.chat.tools.builtin.runtime.extensions").select(tool_name, prepared)
      if extension_err then return done(extension_err) end
      context.native_prepared_target = { name = tool_name, definition = target.definition,
        raw_params = vim.deepcopy(target_params), context = prepared }
      if target.definition.preflight then return target.definition.preflight(prepared, done) end
    elseif target.kind == "script" then
      for key in pairs(target_params) do
        if key ~= "args" then return done("Ability script params accept only args: string[]") end
      end
      local args = target_params.args or {}
      if type(args) ~= "table" or not vim.islist(args) then return done("Ability script args must be a string array") end
      for _, value in ipairs(args) do if type(value) ~= "string" then return done("Ability script args must be strings") end end
    elseif target.tool and target.tool.inputSchema then
      local validator = require("maxa.interactions.chat.tools.schema_validation")
      local valid, validation_err = validator.validate(target.tool.inputSchema, target_params, { object_root = true })
      if not valid then return done(validator.format_error(validation_err)) end
    end
    done()
  end)
end

--- Resolve policy again at dispatch; preflight is not an authorization grant.
function M.execute(context, raw_params, done, opts)
  raw_params, opts = raw_params or {}, opts or {}
  local tool_full_name = raw_params.tool
  local params, params_err = M.resolve_call_params(raw_params)
  if not params then return fail(done, params_err or "Invalid params", tool_full_name) end
  local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
  local chat = context.chat or (context.caller and context.caller.maxa_ai and context.caller.maxa_ai.chat)
  local cancelled, connecting = false, false
  local function inactive()
    return cancelled or (chat and chat._closed) or bridge.is_cancelled(opts.async_id)
      or (context.ui and context.ui._state.terminal)
  end
  local function validate_target(target)
    if context.batch_parent and target.definition and target.definition.interactive == true then
      return "Interactive tool is prohibited in multicall: " .. tool_full_name
    end
    if target.tool and target.tool.inputSchema then
      local validator = require("maxa.interactions.chat.tools.schema_validation")
      local valid, validation_err = validator.validate(target.tool.inputSchema, params, { object_root = true })
      if not valid then return validator.format_error(validation_err) end
    end
  end
  return M.resolve_target(context, tool_full_name, function(target, err)
    if inactive() then return end
    if not target then return fail(done, err, tool_full_name) end
    local validation_err = validate_target(target)
    if validation_err then return fail(done, validation_err, tool_full_name) end
    if target.kind == "builtin" then return execute_builtin(context, target.definition, tool_full_name, params, done, opts) end
    if target.kind == "script" then return execute_ability_script(context, tool_full_name, target.script, params, done, opts) end
    local server_name, tool_name = target.server_name, target.tool_name
    local caller_bufnr = M.get_caller_bufnr(context)
    local function dispatch_tool_call()
      if inactive() then return end
      local allowed, policy_err = require("maxa.project.settings").check_ability(context.project_root or target.cwd, server_name)
      if not allowed then return fail(done, policy_err, tool_full_name) end
      connecting = false
      if context.ui and target.definition then
        require("maxa.interactions.chat.tools.display").bind_target(context.ui, target.definition, params)
      end
      return target.transport.call_tool(target.cwd, server_name, tool_name, params, {
        ui = context.ui,
        caller = context and context.caller,
        callback = function(result, err)
          if err then
            fire_tool_call_error(caller_bufnr, tool_full_name, err, params)
            local error_text = string.format("Failed to call %s.%s: %s", server_name, tool_name, tostring(err))
            return fail(done, error_text, tool_full_name)
          end

          if not result then
            return fail(done, string.format("No response from %s.%s", server_name, tool_name), tool_full_name)
          end

          local inner_result = result.result or result
          if inner_result.isError then
            local error_content = "Unknown error"
            if inner_result.content and inner_result.content[1] and inner_result.content[1].text then
              error_content = inner_result.content[1].text
            end
            fire_tool_call_error(caller_bufnr, tool_full_name, error_content, params)
            local error_text = string.format("Tool %s.%s returned error: %s", server_name, tool_name, error_content)
            return fail(done, error_text, tool_full_name)
          end

          local apply_limit = needs_output_limit(tool_full_name)
          local content = {}
          if inner_result.content then
            local image_index = 1
            for _, item in ipairs(inner_result.content) do
              if item.type == "text" and item.text then
                local text = item.text
                if apply_limit then
                  text = M.handle_output_limit(text, tool_full_name)
                end
                table.insert(content, { type = "text", text = text })
              elseif item.type == "image" then
                local saved, save_err = save_mcp_image_content(item, tool_full_name, image_index)
                if not saved then
                  return fail(done, save_err or "Failed to save MCP image content", tool_full_name)
                end
                table.insert(content, { type = "text", text = build_saved_image_text(saved, tool_full_name, image_index) })
                image_index = image_index + 1
              elseif item.type == "resource" then
                table.insert(content, { type = "resource", resource = item.resource })
              end
            end
          end
          return done({ ok = true, tool = tool_full_name, content = content })
        end,
      })
    end

    local function dispatch()
      local call_ok, call_err = pcall(M.with_wrapper_context, context, tool_full_name, opts, dispatch_tool_call)
      if not call_ok then
        return fail(done, string.format("Failed to dispatch %s.%s: %s", server_name, tool_name, tostring(call_err)), tool_full_name)
      end
    end
    if target.connected then return dispatch() end

    connecting = true
    local connect_ok, connect_err = pcall(M.with_wrapper_context, context, tool_full_name, opts, function()
      bridge.register_handle({ cancel = function(reason)
        if not connecting then return end
        cancelled, connecting = true, false
        -- Let the wrapper record its cancelled terminal state before completion.
        vim.schedule(function() fail(done, reason or "MCP tool connection wait cancelled.", tool_full_name) end)
      end })
      if inactive() then return end
      return target.transport.ensure_server(target.cwd, server_name, function(server, ensure_err)
        if inactive() then return end
        if not server then
          connecting = false
          return fail(done, string.format("Failed to connect authorized MCP Server '%s': %s", server_name, tostring(ensure_err)), tool_full_name)
        end
        -- Connection is shared transport state, not a fresh authorization grant.
        return M.resolve_target(context, tool_full_name, function(current, resolve_err)
          if inactive() then return end
          if not current then
            connecting = false
            return fail(done, resolve_err, tool_full_name)
          end
          if current.kind ~= "mcp" or not current.connected then
            connecting = false
            return fail(done, "Authorized MCP Server is not connected after startup: " .. server_name, tool_full_name)
          end
          local current_err = validate_target(current)
          if current_err then
            connecting = false
            return fail(done, current_err, tool_full_name)
          end
          target = current
          return dispatch()
        end)
      end)
    end)
    if not connect_ok then
      connecting = false
      return fail(done, string.format("Failed to connect authorized MCP Server '%s': %s", server_name, tostring(connect_err)), tool_full_name)
    end
  end)
end

local function encode_resource(resource)
  local ok, encoded = pcall(vim.json.encode, resource)
  if ok and type(encoded) == "string" then
    return encoded
  end
  return vim.inspect(resource)
end

--- Convert normalized content to the compact agent-facing result string.
---@param content table|nil
---@return string
function M.content_to_result(content)
  local parts = {}
  for _, item in ipairs(content or {}) do
    if item.type == "text" then
      table.insert(parts, tostring(item.text or ""))
    elseif item.type == "resource" then
      table.insert(parts, "MCP resource: " .. encode_resource(item.resource))
    end
  end
  return table.concat(parts, "\n")
end

return M
