-- Windows backend for run; the bridge owns native process execution/lifetimes.
local Path = require("plenary.path")
local params = require("maxa.mcphub.native_servers.shared.params")
local registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")
local utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local Collector = require("maxa.interactions.chat.tools.builtin.runtime.output_collector")
local M = {}

function M.is_windows_path(path)
  return path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
end

local function windows_cwd(cwd)
  if M.is_windows_path(cwd) then
    return cwd
  end
  local path = Path:new(cwd)
  if not path:exists() or not path:is_dir() then
    return nil, "Working directory is not an accessible directory: " .. cwd
  end
  local converted = vim.fn.system({ "wslpath", "-w", path:absolute() })
  if vim.v.shell_error ~= 0 then
    return nil, "Failed to convert Windows cwd: " .. cwd .. ": " .. converted
  end
  return converted:gsub("[\r\n]+$", "")
end

function M.run(context, response, environment)
  local p = context.params
  if p.args ~= nil and not (vim.islist or vim.tbl_islist)(p.args) then
    return response:error("win args must be a string array or null.")
  end
  local opts = p.opts or {}
  for key, value in pairs(opts) do
    if key ~= "async" and key ~= "detach" then
      return response:error("Unsupported win option: " .. tostring(key))
    end
    if not params.is_absent(value) and type(value) ~= "boolean" then
      return response:error("opts." .. key .. " must be a boolean or null.")
    end
  end
  local detached = params.boolean(opts.detach, false)
  local asynchronous = params.boolean(opts.async, false)
  if detached and asynchronous then
    return response:error("win opts.async and opts.detach cannot both be true.")
  end
  local cwd, err = windows_cwd(p.cwd)
  if not cwd then
    return response:error(err)
  end
  local literal = p.args ~= nil
  if not literal and cwd:match("^\\\\") then
    return response:error("Windows cmd shell cannot use UNC cwd: " .. cwd .. "; supply array args for native execution or a drive-path cwd.")
  end
  local timeout = params.default(p.timeout, 300)
  local argv = { "runwingui", "--strict", "--timeout", tostring(timeout), "--cwd", cwd }
  for _, name in ipairs({ "MAXA_AI_PROJECT_ROOT", "MAXA_AI_SAVE_ID" }) do
    vim.list_extend(argv, { "--env", name .. "=" .. (environment[name] or "") })
  end
  if detached then argv[#argv + 1] = "--detach" end
  if not literal then argv[#argv + 1] = "--shell" end
  argv[#argv + 1] = "--"
  argv[#argv + 1] = p.command
  if literal then vim.list_extend(argv, p.args) end

  local preview = literal and vim.inspect(vim.list_extend({ p.command }, p.args)) or p.command
  local task = asynchronous and registry.create({ tool = "run", label = p.title or utils.format_command_preview(preview), context = context }) or nil
  local collector = Collector.new({ log_prefix = "mcpx_wincmd", max_chars = utils.MAX_OUTPUT_CHARS })
  local timed_out, timer = false, nil
  local function finish(failed, result)
    if task then
      if failed then registry.fail(task.id, result, timed_out and "timed_out" or "failed")
      else registry.succeed(task.id, result) end
      return
    end
    if failed then return response:error(result) end
    return response:text(result):send()
  end
  local job = vim.fn.jobstart(argv, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data) collector:append_lines("stdout", data) end,
    on_stderr = function(_, data)
      collector:append_lines("stderr", data, { filter_line = function(line)
        if line == "__MCPX_COMMAND_TIMEOUT__" then timed_out = true; return false end
        return true
      end })
    end,
    on_exit = function(_, code)
      if timer then vim.fn.timer_stop(timer); timer = nil end
      collector:close()
      if collector:error() then
        return finish(true, "Failed to write Windows output log: " .. tostring(collector:error()))
      end
      local failed = timed_out or code ~= 0
      local header = failed and string.format("Status: %s\nExit Code: %s\nWindows CWD: %s\n", timed_out and "timeout" or "failed", code, cwd) or ""
      if timed_out then header = header .. "Timeout: " .. timeout .. "s\n" end
      if detached and not failed then header = header .. "Mode: detach (launch acknowledged; remote process id)\n" end
      if collector:exceeded() then
        local result, overflow_err = collector:overflow_result((failed and "" or "Status: success\n") .. header)
        return finish(failed or result == nil, result or tostring(overflow_err))
      end
      local out, stderr = collector:stdout(), collector:stderr()
      local result = out ~= "" and out or (failed and "" or "Success (no output)")
      if stderr ~= "" then result = (out ~= "" and "Stdout:\n" .. out or "") .. "Stderr:\n" .. stderr end
      return finish(failed, header .. result)
    end,
  })
  if job <= 0 then
    collector:close()
    local message = "runwingui is not executable or failed to start."
    if task then
      registry.fail(task.id, message)
      return response:text(require("maxa.interactions.chat.tools.builtin.runtime.async_result").state(task, { submitted = true })):send()
    end
    return response:error(message)
  end
  local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
  local wrapper = bridge.current()
  local function cancel(reason)
    if job > 0 and vim.fn.jobwait({ job }, 0)[1] == -1 then vim.fn.jobstop(job) end
    -- Preserve already captured output before the shared terminal latch is set.
    -- The later exit callback cannot replace this cancelled result.
    if not timed_out then
      local id = task and task.id or (wrapper and wrapper.async_id)
      if id then
        local header = "Status: cancelled\nWindows CWD: " .. cwd .. "\n" .. (reason or "Windows command cancelled.") .. "\n"
        local result
        if collector:exceeded() then
          result = collector:overflow_result(header)
        else
          local out, stderr = collector:stdout(), collector:stderr()
          result = header .. (out ~= "" and "Stdout:\n" .. out or "") .. (stderr ~= "" and "Stderr:\n" .. stderr or "")
        end
        registry.fail(id, result or header, "cancelled")
      end
    end
  end
  bridge.register_handle({ cancel = cancel })
  if task then
    registry.set_canceller(task.id, cancel)
    response:text(require("maxa.interactions.chat.tools.builtin.runtime.async_result").state(task, { submitted = true })):send()
  end
  -- Server enforces the process deadline. This protects startup/transport hangs.
  -- Detached commands return on acknowledgement, so this timer never owns their lifetime.
  if job > 0 and timeout > 0 then
    timer = vim.fn.timer_start((detached and timeout or timeout + 20) * 1000, function()
      if vim.fn.jobwait({ job }, 0)[1] == -1 then timed_out = true; cancel() end
    end)
  end
end

return M
