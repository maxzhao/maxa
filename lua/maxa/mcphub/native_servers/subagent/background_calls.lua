-- Execute explicit background calls in the owning Chat before any model request.
local M = {}

function M.execute(chat, messages, done, opts)
  local utils = require("maxa.mcphub.native_servers.subagent.utils")
  local config = require("maxa.config")
  local injector = require("maxa.interactions.chat.tools.builtin.runtime.context_injector")
  local state = { index = 0, finished = false }
  local group = vim.api.nvim_create_augroup("MaxaSubagentBackground" .. chat.bufnr, { clear = true })

  local function finish(err)
    if state.finished then return end
    state.finished = true
    vim.api.nvim_del_augroup_by_id(group)
    if err then injector.discard(chat) end
    done(err)
  end

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group, buffer = chat.bufnr,
    callback = function() finish("background tool execution cancelled: target Chat was destroyed") end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "MaxaAIChatStopped",
    callback = function(event)
      if event.data and event.data.bufnr == chat.bufnr then
        finish("background tool execution cancelled")
      end
    end,
  })

  local function append_background(segment)
    local prepared, _, _, err = utils.prepare_background_messages(segment, chat.opts.project_root or chat.opts.cwd, opts)
    if not prepared then error(err) end
    for _, message in ipairs(prepared) do
      table.insert(chat.messages, message)
      if message.context and message.context.id and chat.context and chat.context.add then
        local tag = message._meta and message._meta.tag
        if tag == "file" or tag == "symbols" then
          local path = message.context.id:match("^<[^>]+>(.*)</[^>]+>$")
          chat.context:add({
            source = "maxa.interactions.chat.slash_commands." .. tag,
            id = message.context.id, path = path, opts = { visible = true },
          })
        end
      end
    end
  end

  local step
  step = function()
    if state.finished then return end
    if chat._closed or not vim.api.nvim_buf_is_valid(chat.bufnr) then
      return finish("background tool execution cancelled: target Chat is unavailable")
    end
    while state.index < #messages do
      local next_message = messages[state.index + 1]
      if next_message.role == "tool_call" then break end
      state.index = state.index + 1
      append_background({ next_message })
    end
    state.index = state.index + 1
    local message = messages[state.index]
    if not message then return finish() end

    local index = state.index
    local function fail(err)
      finish(string.format("messages[%d] tool_call '%s': %s", index, message.name, tostring(err)))
    end
    if not chat.tools or not chat.tool_registry or not chat.tool_registry.in_use[message.name] then
      return fail("tool is unavailable or excluded by restrict_tools")
    end
    local args = vim.deepcopy(message.args)
    if next(args) == nil then args = vim.empty_dict() end
    local encoded, arguments = pcall(vim.json.encode, args)
    if not encoded then return fail(arguments) end
    local seed = vim.fn.sha256(tostring(chat.id) .. ":" .. tostring(vim.uv.hrtime()) .. ":" .. index):sub(1, 32)
    local call = {
      id = "fc_background_" .. seed, call_id = "call_background_" .. seed, type = "function",
      ["function"] = { name = message.name, arguments = arguments },
    }
    local plan = require("maxa.interactions.chat.tools.validator").classify_batch(chat.tools, chat, { call })
    chat:add_message({ role = config.constants.LLM_ROLE, content = "", tool_calls = plan.history_calls },
      { visible = false, _meta = { tag = "subagent_background_call" } })
    chat.tools.status = chat.tools.constants.STATUS_SUCCESS
    chat.tools:execute(chat, plan, {
      on_complete = function(success, err)
        if state.finished then return end
        if not success then
          local last = chat.messages[#chat.messages]
          return fail(err or (last and last.content) or "tool execution failed")
        end
        injector.flush(chat)
        -- A load is ready only after its complete result and transaction commit.
        if message.name == "load" and require("maxa.abilities.catalog").valid_identifier(args.target) then
          local ready, load_error = require("maxa.session.abilities").get_ready(chat, chat.opts.cwd, args.target)
          if not ready then return fail(load_error or "Ability load transaction did not commit") end
        end
        vim.schedule(function()
          local ok, next_error = pcall(step)
          if not ok then fail(next_error) end
        end)
      end,
    })
  end
  local ok, err = pcall(step)
  if not ok then finish(err) end
end

-- Deferred backgrounds are absent from initial history; append the goal only
-- after all real calls and context transactions have settled.
function M.before_agent(chat, deferred, goal, execute_opts, executor)
  if not deferred then return executor.execute(execute_opts) end
  M.execute(chat, deferred, function(err)
    if err then return execute_opts.on_error(err) end
    require("maxa.mcphub.native_servers.subagent.utils").append_sub_agent_tail(chat.messages, goal)
    if execute_opts.fork_start_index == nil then
      require("maxa.session.compaction_messages").mark_current_messages_as_protected_prefix(chat)
    end
    executor.execute(execute_opts)
  end)
end

return M
