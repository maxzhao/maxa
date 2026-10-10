-- Run: nvim --headless -l lua/maxa/interactions/chat/tools/orchestrator_queue_guard_test.lua
-- Exercises the canonical Orchestrator owner directly.
package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim/lua/?.lua",
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim/lua/?/init.lua",
  package.path,
}, ";")

local Orchestrator = require("maxa.interactions.chat.tools.orchestrator")

local queue = { items = { { name = "queued-one" }, { name = "queued-two" } } }
function queue:is_empty()
  return #self.items == 0
end
function queue:pop()
  return table.remove(self.items, 1)
end

local finished, cancelled, finalized_current = 0, 0, 0
local tools = {
  chat = { _maxa_image_analysis_terminal = "cancelled" },
  bufnr = 1,
}
local orchestrator = Orchestrator.new(tools, 1)
orchestrator.queue = queue
orchestrator.tool = { name = "running", cmds = {}, handlers = {} }
orchestrator.finalize_tool = function(self)
  finalized_current = finalized_current + 1
  self.tool = nil
end
orchestrator.cancel_pending_tools = function(self)
  while not self.queue:is_empty() do
    self.queue:pop()
    cancelled = cancelled + 1
  end
end
orchestrator._finalize_tools = function()
  finished = finished + 1
end

orchestrator:setup_next_tool()
assert(finalized_current == 1, "in-flight tool should settle/finalize")
assert(cancelled == 2, "queued sibling tools must be suppressed")
assert(finished == 1, "tool batch must finalize once")

local executed_sibling, cancelled_sibling, cancelled_finished = 0, 0, 0
local cancel_chat = {
  add_tool_output = function(_, tool)
    if tool.name == "queued-side-effect" then
      cancelled_sibling = cancelled_sibling + 1
    end
  end,
}
local cancel_tools = { chat = cancel_chat, bufnr = 2 }
local cancelled_orchestrator = Orchestrator.new(cancel_tools, 2)
cancelled_orchestrator.queue = {
  items = {
    {
      name = "queued-side-effect",
      cmds = {
        function()
          executed_sibling = executed_sibling + 1
        end,
      },
      handlers = {},
    },
  },
  is_empty = queue.is_empty,
  pop = queue.pop,
}
cancelled_orchestrator.tool = { name = "ask", cmds = {}, handlers = {} }
cancelled_orchestrator.finalize_tool = function(self)
  self.tool = nil
end
cancelled_orchestrator._finalize_tools = function(self)
  cancelled_finished = cancelled_finished + 1
  if self.tools.chat.current_tool == self.cancel_handle then
    self.tools.chat.current_tool = nil
  end
end
cancel_chat.current_tool = cancelled_orchestrator.cancel_handle
assert(cancel_chat.current_tool.cancel("ask cancelled"), "tool batch cancellation was not accepted")
cancelled_orchestrator:setup_next_tool()
assert(executed_sibling == 0, "queued side-effect tool executed after cancellation")
assert(cancelled_sibling == 1, "queued side-effect tool was not cancelled")
assert(cancelled_finished == 1, "cancelled tool batch did not finalize once")
assert(cancel_chat.current_tool == nil, "cancel handle remained attached after finalization")

local tools_source = table.concat(vim.fn.readfile("lua/maxa/interactions/chat/tools/init.lua"), "\n")
assert(
  tools_source:find("chat.current_tool = orchestrator.cancel_handle", 1, true),
  "Tools:execute does not expose the active orchestrator cancellation handle"
)

local Tools = require("maxa.interactions.chat.tools")
local tools_bufnr = vim.api.nvim_create_buf(false, true)
local reset_count, submit_count = 0, 0
local tools_instance = setmetatable({
  aug = vim.api.nvim_create_augroup("MaxaCancelledToolsTest", { clear = true }),
  bufnr = tools_bufnr,
  chat = {
    submit = function()
      submit_count = submit_count + 1
    end,
  },
  status = "error",
  tools_config = { opts = { auto_submit_errors = true, auto_submit_success = true } },
}, { __index = Tools })
function tools_instance:reset(opts)
  reset_count = reset_count + 1
  assert(opts.auto_submit == false, "cancelled batch reset as auto-submit")
end
tools_instance:set_autocmds()
vim.api.nvim_exec_autocmds("User", {
  pattern = "MaxaAIToolsFinished",
  data = { bufnr = tools_bufnr, id = 3, cancelled = true },
})
vim.wait(20, function()
  return reset_count == 1
end)
assert(reset_count == 1, "cancelled tool batch did not reset")
assert(submit_count == 0, "cancelled tool batch auto-submitted to the model")
vim.api.nvim_buf_delete(tools_bufnr, { force = true })

local setup_error_bufnr = vim.api.nvim_create_buf(false, true)
local setup_error_finished = 0
local setup_error_group = vim.api.nvim_create_augroup("MaxaToolsSetupErrorTest", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = setup_error_group,
  pattern = "MaxaAIToolsFinished",
  callback = function(args)
    if args.data and args.data.bufnr == setup_error_bufnr then
      setup_error_finished = setup_error_finished + 1
    end
  end,
})
local setup_error_tools = setmetatable({
  bufnr = setup_error_bufnr,
  status = "success",
  messages = {},
}, { __index = Tools })
function setup_error_tools:set_autocmds()
  error("setup failed")
end
local setup_error_chat = { bufnr = setup_error_bufnr, messages = {} }
local setup_ok, setup_err = pcall(setup_error_tools.execute, setup_error_tools, setup_error_chat, {})
assert(setup_ok, "Tools:execute leaked setup error: " .. tostring(setup_err))
assert(setup_error_tools.status == "error", "Tools:execute did not record setup failure")
vim.wait(50, function()
  return setup_error_finished == 1
end)
assert(setup_error_finished == 1, "Tools:execute setup failure bypassed ToolsFinished cleanup")
assert(setup_error_chat.current_tool == nil, "setup failure left an invalid cancellation handle")
vim.api.nvim_del_augroup_by_id(setup_error_group)
vim.api.nvim_buf_delete(setup_error_bufnr, { force = true })

local rejection_order = {}
local rejection_tools = {
  status = "success",
  constants = { STATUS_ERROR = "error", STATUS_SUCCESS = "success" },
  chat = {
    add_validation_error_output = function(_, tool, feedback)
      rejection_order[#rejection_order + 1] = "result"
      assert(tool.function_call.id == "call-rejected")
      assert(feedback == "bounded rejection")
    end,
  },
}
function rejection_tools:mark_error()
  self.status = "error"
end
function rejection_tools:_flush_validation_corrections()
  rejection_order[#rejection_order + 1] = "correction"
end
local rejection_orchestrator = Orchestrator.new(rejection_tools, 4)
rejection_orchestrator.queue:push({
  name = "write",
  function_call = { id = "call-rejected", ["function"] = { name = "write", arguments = "{" } },
  _maxa_validation_rejection = { feedback = "bounded rejection" },
})
rejection_orchestrator._finalize_tools = function(self)
  self.tools:_flush_validation_corrections()
end
rejection_orchestrator:setup_next_tool()
assert(vim.deep_equal(rejection_order, { "result", "correction" }), "validation feedback order changed")
assert(rejection_tools.status == "error", "validation rejection did not latch batch error")

local monotonic_tools = {
  status = "error",
  constants = { STATUS_ERROR = "error", STATUS_SUCCESS = "success" },
  stdout = {},
  chat = {},
}
local monotonic_orchestrator = Orchestrator.new(monotonic_tools, 5)
monotonic_orchestrator.tool = { name = "valid-after-error" }
monotonic_orchestrator.output = { success = function() end }
monotonic_orchestrator:success({ action = {} })
assert(monotonic_tools.status == "error", "later success cleared a latched batch error")

local mixed_order = {}
local mixed_tools = {
  status = "success",
  constants = { STATUS_ERROR = "error", STATUS_SUCCESS = "success" },
  stderr = {},
  stdout = {},
  chat = {
    add_validation_error_output = function(_, tool)
      mixed_order[#mixed_order + 1] = tool.name
    end,
  },
}
function mixed_tools:mark_error()
  self.status = "error"
end
function mixed_tools:_flush_validation_corrections()
  mixed_order[#mixed_order + 1] = "correction"
end
local function valid_action(name)
  return {
    name = name,
    args = {},
    handlers = {},
    cmds = {
      function(_, _, _, cb)
        cb({ status = "success", data = name .. "-ok" })
      end,
    },
    output = {
      success = function()
        mixed_order[#mixed_order + 1] = name
      end,
    },
  }
end
local mixed_orchestrator = Orchestrator.new(mixed_tools, 6)
mixed_orchestrator.queue:push(valid_action("valid-one"))
mixed_orchestrator.queue:push({
  name = "unknown",
  function_call = { id = "call-unknown", ["function"] = { name = "unknown", arguments = "{}" } },
  _maxa_tool_resolution_error = { feedback = "unknown tool" },
})
mixed_orchestrator.queue:push({
  name = "write",
  function_call = { id = "call-rejected", ["function"] = { name = "write", arguments = "{" } },
  _maxa_validation_rejection = { feedback = "bounded rejection" },
})
mixed_orchestrator.queue:push(valid_action("valid-two"))
mixed_orchestrator._finalize_tools = function(self)
  self.tools:_flush_validation_corrections()
end
mixed_orchestrator:setup_next_tool()
assert(
  vim.deep_equal(mixed_order, { "valid-one", "unknown", "write", "valid-two", "correction" }),
  "mixed action order changed"
)
assert(mixed_tools.status == "error", "mixed batch error was cleared by later success")

local correction_messages = {}
local correction_bufnr = vim.api.nvim_create_buf(false, true)
local correction_chat = {
  bufnr = correction_bufnr,
  messages = {},
  add_message = function(_, data, opts)
    correction_messages[#correction_messages + 1] = { data = data, opts = opts }
  end,
}
local correction_tools = setmetatable({
  adapter = require("maxa.adapters.http.openai"),
  aug = vim.api.nvim_create_augroup("MaxaValidationCorrectionTest", { clear = true }),
  bufnr = correction_bufnr,
  constants = { STATUS_ERROR = "error", STATUS_SUCCESS = "success" },
  messages = {},
  status = "success",
  stderr = {},
  stdout = {},
  tools_config = { opts = {} },
}, { __index = Tools })
function correction_tools:set_autocmds() end
function correction_tools:_start_edit_tracking(calls)
  assert(#calls == 0, "unreplayable call entered edit tracking")
end
local correction_entry = {
  kind = "rejected_unreplayable",
  index = 1,
  call = { ["function"] = { arguments = "{" } },
  tool_name = "",
  reason = "Missing tool name",
  reason_code = "missing_name",
  snapshot = "{",
  feedback = "hidden bounded correction",
}
correction_tools:execute(correction_chat, {
  calls = { correction_entry.call },
  entries = { correction_entry },
  history_calls = {},
  corrections = { correction_entry },
})
assert(#correction_messages == 1, "all-unreplayable batch did not append one correction")
assert(correction_messages[1].data.content == "hidden bounded correction")
assert(correction_messages[1].opts.visible == false, "correction became user-visible")
assert(correction_tools.status == "error", "all-unreplayable batch did not latch error")
assert(correction_chat.current_tool == nil, "all-unreplayable batch left a cancel handle")
vim.api.nvim_buf_delete(correction_bufnr, { force = true })

local execute_order = {}
local execute_bufnr = vim.api.nvim_create_buf(false, true)
local execute_chat = {
  bufnr = execute_bufnr,
  messages = {},
  add_validation_error_output = function(_, tool)
    execute_order[#execute_order + 1] = tool.name
  end,
  add_tool_output = function(_, tool)
    execute_order[#execute_order + 1] = tool.name
  end,
}
local execute_tools = setmetatable({
  adapter = require("maxa.adapters.http.openai"),
  aug = vim.api.nvim_create_augroup("MaxaValidationMixedExecuteTest", { clear = true }),
  bufnr = execute_bufnr,
  constants = { STATUS_ERROR = "error", STATUS_SUCCESS = "success" },
  messages = {},
  status = "success",
  stderr = {},
  stdout = {},
  tools_config = {
    opts = {},
    demo = {
      callback = function()
        return {
          cmds = {
            function(_, _, _, cb)
              cb({ status = "success", data = "demo-ok" })
            end,
          },
          handlers = {},
          output = {
            success = function(tool, tools)
              tools.chat:add_tool_output(tool, "demo-ok", "")
            end,
          },
        }
      end,
    },
  },
}, { __index = Tools })
function execute_tools:set_autocmds() end
function execute_tools:_start_edit_tracking() end
local unknown_call = { id = "call-unknown", ["function"] = { name = "unknown", arguments = "{}" } }
local rejected_call = { id = "call-rejected", ["function"] = { name = "write", arguments = "{" } }
local demo_call = { id = "call-demo", ["function"] = { name = "demo", arguments = "{}" } }
execute_tools:execute(execute_chat, {
  calls = { unknown_call, rejected_call, demo_call },
  entries = {
    { kind = "valid", index = 1, call = unknown_call, tool_name = "unknown" },
    {
      kind = "rejected_replayable",
      index = 2,
      call = rejected_call,
      tool_name = "write",
      feedback = "bounded rejection",
      snapshot = "{",
    },
    { kind = "valid", index = 3, call = demo_call, tool_name = "demo" },
  },
  history_calls = { unknown_call, rejected_call, demo_call },
  corrections = {},
})
assert(vim.deep_equal(execute_order, { "unknown", "write", "demo" }), "Tools:execute stopped after an earlier failure")
assert(execute_tools.status == "error", "later valid execution cleared earlier batch error")
assert(execute_chat.current_tool == nil, "mixed Tools:execute left a cancel handle")
vim.api.nvim_buf_delete(execute_bufnr, { force = true })

local old_decision = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
package.loaded["maxa.lifecycle.chat_token_threshold_decision"] = {
  should_cancel_tool_batch = function()
    return true
  end,
}
local cancelled_names, side_effects = {}, 0
local threshold_bufnr = vim.api.nvim_create_buf(false, true)
local threshold_chat = {
  bufnr = threshold_bufnr,
  messages = {},
  add_tool_output = function() end,
  add_validation_error_output = function() end,
}
local function threshold_tool(name)
  return {
    callback = function()
      return {
        cmds = {
          function(_, _, _, cb)
            side_effects = side_effects + 1
            cb({ status = "success" })
          end,
        },
        handlers = {},
        output = {
          cancelled = function()
            cancelled_names[#cancelled_names + 1] = name
          end,
        },
      }
    end,
  }
end
local threshold_tools = setmetatable({
  adapter = require("maxa.adapters.http.openai"),
  aug = vim.api.nvim_create_augroup("MaxaThresholdToolCancelTest", { clear = true }),
  bufnr = threshold_bufnr,
  constants = { STATUS_ERROR = "error", STATUS_SUCCESS = "success" },
  messages = {},
  status = "success",
  stderr = {},
  stdout = {},
  tools_config = { opts = {}, one = threshold_tool("one"), two = threshold_tool("two") },
}, { __index = Tools })
function threshold_tools:set_autocmds() end
function threshold_tools:_start_edit_tracking() end
local one = { id = "call-one", ["function"] = { name = "one", arguments = "{}" } }
local two = { id = "call-two", ["function"] = { name = "two", arguments = "{}" } }
threshold_tools:execute(threshold_chat, {
  calls = { one, two },
  entries = {
    { kind = "valid", index = 1, call = one, tool_name = "one" },
    { kind = "valid", index = 2, call = two, tool_name = "two" },
  },
  history_calls = { one, two },
  corrections = {},
})
assert(side_effects == 0, "threshold-cancelled tool batch executed a side effect")
assert(vim.deep_equal(cancelled_names, { "one", "two" }), "threshold cancellation did not pair every tool result")
assert(threshold_chat.current_tool == nil, "threshold-cancelled batch left a cancel handle")

package.loaded["maxa.lifecycle.chat_token_threshold_decision"].should_resume_cancelled_tool_batch = function()
  return true
end
local resume_bufnr = vim.api.nvim_create_buf(false, true)
local resumed, reset_auto = 0, nil
local resume_chat = {
  submit = function(_, opts)
    resumed = resumed + 1
    opts.callback()
  end,
  tools_done = function(_, opts)
    reset_auto = opts.auto_submit
  end,
}
local resume_tools = setmetatable({
  aug = vim.api.nvim_create_augroup("MaxaThresholdCancelledResumeTest", { clear = true }),
  bufnr = resume_bufnr,
  chat = resume_chat,
  extracted = {},
  constants = { STATUS_ERROR = "error", STATUS_SUCCESS = "success" },
  messages = {},
  status = "success",
  stderr = {},
  stdout = {},
  tools_config = { opts = {} },
}, { __index = Tools })
resume_tools:set_autocmds()
vim.api.nvim_exec_autocmds("User", {
  pattern = "MaxaAIToolsFinished",
  data = { bufnr = resume_bufnr, cancelled = true },
})
vim.wait(20, function()
  return resumed == 1
end)
assert(resumed == 1, "emergency cancelled batch did not resume through the lifecycle policy")
assert(reset_auto == true, "emergency cancelled batch did not finalize as auto-submit")

package.loaded["maxa.lifecycle.chat_token_threshold_decision"] = old_decision
vim.api.nvim_buf_delete(threshold_bufnr, { force = true })
vim.api.nvim_buf_delete(resume_bufnr, { force = true })

print("orchestrator_queue_guard tests: 11 passed, 0 failed")
