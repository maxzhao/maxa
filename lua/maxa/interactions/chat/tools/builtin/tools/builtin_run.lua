-- Execute shell command using vim.fn.jobstart
-- 迁移自: mcphub.nvim/lua/maxa/mcphub/native/neovim/terminal.lua

local param_utils = require("maxa.mcphub.native_servers.shared.params")
local async_registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")
local session_identity = require("maxa.session.session_identity")

local PROJECT_ROOT_ENV = "MAXA_AI_PROJECT_ROOT"
local SAVE_ID_ENV = "MAXA_AI_SAVE_ID"

local function caller_environment(context)
  local chat = context
    and context.caller
    and context.caller.maxa_ai
    and context.caller.maxa_ai.chat
  local identity = session_identity.resolve(chat)
  return {
    [PROJECT_ROOT_ENV] = identity and identity.project_root or "",
    [SAVE_ID_ENV] = identity and identity.save_id or "",
  }
end

local function decode_object(value, field)
  if param_utils.is_absent(value) then
    return nil
  end
  if type(value) ~= "string" then
    return nil, field .. " must be a JSON object string or null."
  end
  local ok, decoded = pcall(vim.json.decode, value)
  if not ok or type(decoded) ~= "table" or not value:match("^%s*{") then
    return nil, field .. " must decode to a JSON object."
  end
  return decoded
end

local function string_array(value, field, executable)
  if type(value) ~= "table" or not (vim.islist or vim.tbl_islist)(value) or (executable and #value == 0) then
    return field .. " must be " .. (executable and "a nonempty" or "a") .. " string array."
  end
  for index, entry in ipairs(value) do
    if type(entry) ~= "string" or (executable and index == 1 and not entry:find("%S")) then
      return string.format("%s[%d] must be %sstring.", field, index, executable and index == 1 and "a nonblank " or "a ")
    end
  end
end

local function prepare(context)
  if type(context.params) ~= "table" then
    return nil, "parameters must be an object."
  end
  local params = vim.deepcopy(context.params)
  if not context.ability_script then
    for _, key in ipairs({ "json_patches", "tool", "params", "json", "json_path" }) do
      if params[key] ~= nil then return nil, key .. " is not supported by run." end
    end
    if not (context.run_member and param_utils.is_absent(params.title))
      and (type(params.title) ~= "string" or not params.title:find("%S")) then
      return nil, "title must be a nonblank string."
    end
  end
  params.scope = param_utils.default(params.scope, "shell")
  if params.scope == "" then params.scope = "shell" end
  if type(params.scope) ~= "string" then
    return nil, "scope must be a string or null."
  end
  if context.ability_script == true then
    local err = string_array(params.argv, "internal argv", true)
    if err then return nil, err end
  elseif type(params.command) ~= "string" or not params.command:find("%S") then
    return nil, "command must be a nonblank string."
  end

  local chat = context.chat or (context.caller and context.caller.maxa_ai and context.caller.maxa_ai.chat)
  if chat and chat._handoff_compaction_runner then
    local allowed = { ["@session:probe_messages"] = true, ["@session:get_messages"] = true,
      ["@session:get_message"] = true, ["@session:get_loaded_items"] = true, ["@session:handoff_compact"] = true }
    if params.scope ~= "tool" or not allowed[params.command] then
      return nil, "Handoff compression allows only source queries and handoff_compact through run."
    end
  end

  local err
  local literal_args = type(params.args) == "table"
  if param_utils.is_absent(params.args) then
    params.args = nil
  elseif type(params.args) == "table" then
    err = string_array(params.args, "args", false)
  else
    params.args, err = decode_object(params.args, "args")
  end
  if err then return nil, err end
  params.opts, err = decode_object(params.opts, "opts")
  if err then return nil, err end

  if params.scope == "tool" then
    if params.command == "run" or params.command == "multicall" then
      return nil, "run cannot call " .. params.command .. "."
    end
    local chat = context.chat or (context.caller and context.caller.maxa_ai and context.caller.maxa_ai.chat)
    if chat and chat._maxa_hidden_image_analysis then
      return nil, "Hidden image-analysis child cannot use run scope tool."
    end
    for _, key in ipairs({ "cwd", "timeout", "async", "pty" }) do
      if not param_utils.is_absent(params[key]) then return nil, "tool scope does not accept outer " .. key .. "." end
    end
    for key, value in pairs(params.opts or {}) do
      if key ~= "async" then return nil, "Unsupported tool option: " .. tostring(key) end
      if not param_utils.is_absent(value) and type(value) ~= "boolean" then
        return nil, "opts.async must be a boolean or null."
      end
    end
    if literal_args then
      if not params.command:match("^@[^:]+:/") then return nil, "tool args must be a JSON object string or null." end
      params.args = { args = params.args }
    end
    params.cwd = context.cwd
    return params
  end

  params.cwd = param_utils.default(params.cwd, context.cwd)
  if type(params.cwd) ~= "string" or not params.cwd:find("%S") then
    return nil, "cwd must be a nonblank string; default Chat project root is unavailable."
  end
  local windows_absolute = params.scope == "win"
    and require("maxa.interactions.chat.tools.builtin.runtime.windows_command").is_windows_path(params.cwd)
  if not windows_absolute then
    params.cwd = vim.fs.normalize(params.cwd)
    if not require("plenary.path"):new(params.cwd):is_absolute() then
      if type(context.cwd) ~= "string" or context.cwd == "" then
        return nil, "Chat project root is unavailable for relative cwd."
      end
      params.cwd = vim.fs.normalize(context.cwd .. "/" .. params.cwd)
    end
  end
  params.timeout = param_utils.default(params.timeout, nil)
  if params.timeout ~= nil and (type(params.timeout) ~= "number" or params.timeout ~= params.timeout
    or params.timeout == math.huge or params.timeout == -math.huge) then
    return nil, "timeout must be a finite number or null."
  end
  return params
end

return {
  name = "run",
  display = function(args, result)
    local helpers = require("maxa.interactions.chat.tools.display_helpers")
    local scope = type(args.scope) == "string" and args.scope ~= "" and args.scope or "shell"
    local cmd = type(args.command) == "string" and args.command or ""
    local view = scope == "tool" and require("maxa.interactions.chat.tools.presentation").builtin(
      cmd, helpers.normalize_args(args.args), result) or { blocks = {} }
    if view.summary == false then return view end
    if type(args.title) == "string" and args.title:find("%S") then
      local target = scope == "tool" and cmd:find("%S") and cmd or scope
      view.summary = target .. ' "' .. helpers.atom(args.title, 100) .. '"'
    elseif scope ~= "tool" then
      view.summary = scope == "shell" and "run" or ("run · " .. helpers.atom(scope, 60))
      if cmd ~= "" then view.summary = view.summary .. ": " .. helpers.atom(cmd, 80) end
      if type(args.args) == "table" and (vim.islist or vim.tbl_islist)(args.args) then
        view.summary = view.summary .. " [argv:" .. #args.args .. "]"
      end
    end
    return view
  end,
  description = [[Execute a titled command or authorized tool. Scope shell (default) uses the configured Shell; win uses Windows cmd.exe or native argv through runwingui; tool dispatches a bare builtin or committed @ability:target and preserves its result. Required builtin target titles omitted/null in args inherit this title; MCP fields stay unchanged. Authorized MCP tools reconnect a disconnected source and wait before execution; this does not load an Ability or grant authorization. Cannot call run or multicall. Arrays are literal argv for commands or Ability scripts; tool parameters use a JSON object string. Command cwd defaults to exact Chat project root; timeout defaults to 300 seconds, nonpositive disables the deadline. Tool mode rejects outer cwd/timeout. opts is a JSON object string: shell pty/async, win async/detach, tool async; boolean/null, default false. Windows async/detach are mutually exclusive; detach acknowledges launch only. Nonzero exits/timeouts preserve bounded output. No JSON-file injection.]],
  inputSchema = {
    type = "object",
    properties = {
      title = { type = "string", minLength = 1, description = "Required nonblank display-only title." },
      scope = { type = { "string", "null" }, description = "Scope: shell (default), win, or tool; other scopes require a loaded matching extension.", default = "shell" },
      command = { type = "string", minLength = 1, description = "Nonblank command/program, extension-defined source code, or, in tool scope, bare builtin or committed @ability:target." },
      args = {
        anyOf = {
          { type = "string" },
          { type = "array", items = { type = "string" } },
          { type = "null" },
        },
        description = "Literal string-array argv, JSON object string, or null; shell/win accept arrays/null, tool accepts encoded parameters or script argv.",
      },
      cwd = { type = { "string", "null" }, description = "Working directory; omitted/null uses the Chat project root, relative paths resolve from it. Win accepts drive/UNC or WSL paths; only native argv supports UNC cwd." },
      timeout = { type = { "number", "null" }, description = "Timeout seconds; shell/monitored win default to 300, nonpositive disables the deadline. Win detach bounds launch only, not the acknowledged application's lifetime." },
      opts = { type = { "string", "null" }, description = "JSON object string: shell pty/async, win async/detach (mutually exclusive), tool async; boolean/null, default false, unknown keys fail." },
    },
    required = { "title", "command" },
  },
  prepare = prepare,
  preflight = function(context, done)
    local p = context.params
    if p.scope == "tool" then
      return require("maxa.interactions.chat.tools.builtin.runtime.tool_call_core").preflight(context, p.command, p.args or {}, done)
    end
    if p.scope ~= "shell" and p.scope ~= "win" then return done() end -- Ability extensions own other scopes.
    if p.args ~= nil and not vim.islist(p.args) then return done(p.scope .. " args must be a string array or null.") end
    local allowed = p.scope == "win" and { async = true, detach = true } or { async = true, pty = true }
    for key, value in pairs(p.opts or {}) do
      if not allowed[key] then return done("Unsupported " .. p.scope .. " option: " .. tostring(key)) end
      if not param_utils.is_absent(value) and type(value) ~= "boolean" then return done("opts." .. key .. " must be a boolean or null.") end
    end
    if p.scope == "win" and (p.opts or {}).async == true and (p.opts or {}).detach == true then
      return done("win opts.async and opts.detach cannot both be true.")
    end
    if p.scope == "shell" or not require("maxa.interactions.chat.tools.builtin.runtime.windows_command").is_windows_path(p.cwd) then
      local path = require("plenary.path"):new(p.cwd)
      if not path:exists() or not path:is_dir() then return done("Working directory is not an accessible directory: " .. p.cwd) end
    elseif p.args == nil and p.cwd:match("^\\\\\\\\") then return done("Windows cmd shell cannot use UNC cwd; supply array args.") end
    done()
  end,
  run = function(context, response)
    local params = context.params
    if params.scope == "tool" then
      return require("maxa.interactions.chat.tools.builtin.runtime.tool_execution").run(context, response)
    end
    if params.scope == "win" and not context.ability_script then
      return require("maxa.interactions.chat.tools.builtin.runtime.windows_command").run(context, response, caller_environment(context))
    end
    if params.scope ~= "shell" then
      return response:error("Unsupported run scope: " .. params.scope)
    end
    local command = params.command
    local argv = context.ability_script == true and params.argv or nil
    if params.args ~= nil then
      if not (vim.islist or vim.tbl_islist)(params.args) then
        return response:error("shell args must be a string array or null.")
      end
      argv = { command }
      vim.list_extend(argv, params.args)
    end
    local opts = params.opts or {}
    for key, value in pairs(opts) do
      if key ~= "pty" and key ~= "async" then
        return response:error("Unsupported shell option: " .. tostring(key))
      end
      if not param_utils.is_absent(value) and type(value) ~= "boolean" then
        return response:error("opts." .. key .. " must be a boolean or null.")
      end
    end
    for _, key in ipairs({ "pty", "async" }) do
      if param_utils.is_absent(opts[key]) and not param_utils.is_absent(params[key]) and type(params[key]) ~= "boolean" then
        return response:error(key .. " must be a boolean or null.")
      end
    end
    local command_preview = argv and vim.inspect(argv) or command
    local cwd = params.cwd

    -- Use Plenary Path to handle the path
    local path = require("plenary.path"):new(cwd)

    -- Check if the directory exists
    if not path:exists() then
      return response:error("Directory does not exist: " .. cwd)
    end

    -- Make sure it's a directory
    if not path:is_dir() then
      return response:error("Path is not a directory: " .. cwd)
    end

    local absolute_path = path:absolute()
    local timeout = param_utils.default(params.timeout, 300)
    local use_pty = param_utils.boolean(param_utils.default(opts.pty, params.pty), false)
    local run_async = param_utils.boolean(param_utils.default(opts.async, params.async), false)
    local task = nil

    local timed_out = false
    local timer_id = nil
    local builtin_utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
    local OutputCollector = require("maxa.interactions.chat.tools.builtin.runtime.output_collector")
    local output_collector = OutputCollector.new({
      log_prefix = "mcpx_cmd",
      max_chars = builtin_utils.MAX_OUTPUT_CHARS,
    })
    local fire_event_json = {}

    local function append_output_lines(stream, data)
      output_collector:append_lines(stream, data, {
        filter_line = function(line)
          if stream == "stderr" and line == "__MCPX_COMMAND_TIMEOUT__" then
            timed_out = true
            return false
          end
          local event_json = stream == "stderr" and line:match("^__FIRE_EVENT__:(.+)$") or nil
          if event_json then
            -- Keep protocol lines out of normal command output on success, as
            -- before. If the command fails, they are appended back in on_exit.
            table.insert(fire_event_json, event_json)
            return false
          end
          return true
        end,
      })
    end

    local function append_deferred_fire_event_lines()
      if #fire_event_json == 0 then
        return
      end
      local lines = {}
      for _, json_str in ipairs(fire_event_json) do
        table.insert(lines, "__FIRE_EVENT__:" .. json_str)
      end
      output_collector:append_lines("stderr", lines)
    end

    -- Every command runs behind the supervisor, including non-PTY commands.
    -- This is a safety boundary: arbitrary descendants must never share Neovim's
    -- session/process group, even when callers choose the wrong PTY mode.
    local supervisor_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
      .. "/execute_command_supervisor.py"
    local supervisor_config_file = vim.fn.tempname()
    local config = {
      command = command,
      argv = argv,
      cwd = absolute_path,
      shell = vim.o.shell ~= "" and vim.o.shell or "/bin/sh",
      shellcmdflag = vim.o.shellcmdflag ~= "" and vim.o.shellcmdflag or "-c",
      pty = use_pty,
      timeout = timeout,
    }
    local ok, encoded = pcall(vim.json.encode, config)
    if not ok then
      return response:error("Failed to encode command supervisor config: " .. tostring(encoded))
    end
    local write_ok, write_err = pcall(vim.fn.writefile, { encoded }, supervisor_config_file)
    if not write_ok then
      return response:error("Failed to write command supervisor config: " .. tostring(write_err))
    end
    local actual_command = { "python3", supervisor_path, supervisor_config_file }

    if run_async then
      task = async_registry.create({
        tool = "run",
        label = params.title or builtin_utils.format_command_preview(command_preview),
        context = context,
      })
    end

    local options = {
      cwd = absolute_path,
      env = caller_environment(context),
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = function(_, data)
        append_output_lines("stdout", data)
      end,
      on_stderr = function(_, data)
        append_output_lines("stderr", data)
      end,
      on_exit = function(_, exit_code)
        -- Cancel timers if still pending
        if timer_id then
          vim.fn.timer_stop(timer_id)
          timer_id = nil
        end
        pcall(vim.fn.delete, supervisor_config_file)

        local failed = timed_out or exit_code ~= 0

        if failed then
          -- Preserve deferred protocol lines in failed command output, matching
          -- the previous behavior where stderr was only filtered on success.
          append_deferred_fire_event_lines()
        elseif #fire_event_json > 0 then
          for _, json_str in ipairs(fire_event_json) do
            local ok, payload = pcall(vim.json.decode, json_str)
            if ok and payload and payload.event then
              local fire_ok, fire = pcall(require, "maxa.abilities.hooks.fire")
              if fire_ok then
                local data = payload.data or {}
                data.bufnr = context.bufnr
                fire.fire(payload.event, data)
              end
            end
          end
        end

        output_collector:close()

        local function finish_result(failed, result)
          if task then
            if failed then
              async_registry.fail(task.id, result, timed_out and "timed_out" or "failed")
            else
              async_registry.succeed(task.id, result)
            end
            return
          end
          if failed then
            return response:error(result)
          end
          return response:text(result):send()
        end

        if output_collector:error() then
          return finish_result(true, "Failed to write command output log: " .. tostring(output_collector:error()))
        end

        local header = ""
        if failed then
          header = string.format("Status: %s\nExit Code: %s\nCWD: %s\n", timed_out and "timeout" or "failed", exit_code, absolute_path)
          if timed_out then
            header = header .. "Timeout: " .. timeout .. "s\n"
          end
        end

        -- Check if output exceeds threshold
        if output_collector:exceeded() then
          -- Build concise LLM-facing result with stats and a continuation path.
          local result, overflow_err = output_collector:overflow_result(failed and header or "Status: success\n")
          if not result then
            return finish_result(true, "Command " .. tostring(overflow_err))
          end

          return finish_result(failed, result)
        else
          -- Output within threshold, return directly. These concatenations are
          -- bounded by MAX_OUTPUT_CHARS.
          local output = output_collector:stdout()
          local stderr_output = output_collector:stderr()
          local result = output ~= "" and output or (failed and "" or "Success (no output)")
          if stderr_output ~= "" then
            result = (output ~= "" and "Stdout:\n" .. output or "") .. "Stderr:\n" .. stderr_output
          end
          return finish_result(failed, header .. result)
        end
      end,
    }

    -- Start the job
    local job_id = vim.fn.jobstart(actual_command, options)

    if job_id <= 0 then
      pcall(vim.fn.delete, supervisor_config_file)
      local error_msg
      if job_id == 0 then
        error_msg = "Invalid arguments for jobstart"
      else -- job_id == -1
        error_msg = "Command is not executable"
      end
      if task then
        async_registry.fail(task.id, error_msg)
        return response:text(require("maxa.interactions.chat.tools.builtin.runtime.async_result").state(task, { submitted = true })):send()
      end
      return response:error(error_msg)
    end

    local function cancel_job()
      if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
        vim.fn.jobstop(job_id)
      end
    end
    local bridge_ok, bridge = pcall(require, "maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
    if bridge_ok then
      bridge.register_handle({ cancel = cancel_job })
    end

    if task then
      async_registry.set_canceller(task.id, cancel_job)
      response:text(require("maxa.interactions.chat.tools.builtin.runtime.async_result").state(task, { submitted = true })):send()
    end

    -- Set timeout timer if specified
    if timeout and timeout > 0 then
      timer_id = vim.fn.timer_start((timeout + 4) * 1000, function()
        if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
          -- The supervisor owns the isolated child process group and normally
          -- enforces this timeout itself. This delayed timer is only a fallback
          -- if the supervisor fails to exit after its own grace period.
          timed_out = true
          vim.fn.jobstop(job_id)
        end
      end)
    end
  end,
}
