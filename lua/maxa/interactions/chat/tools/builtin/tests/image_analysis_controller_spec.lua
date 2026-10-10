-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/image_analysis_controller_spec.lua
-- Run: nvim --headless -l lua/maxa/interactions/chat/tools/builtin/tests/image_analysis_controller_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name .. ": " .. tostring(err))
  end
end
local function eq(expected, actual)
  assert(expected == actual, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

local scheduled = {}
local original_schedule = vim.schedule
local original_uv = vim.uv
local timers = {}
vim.schedule = function(fn)
  scheduled[#scheduled + 1] = fn
end
vim.uv = vim.tbl_extend("force", vim.uv or vim.loop, {
  new_timer = function()
    local timer = { stopped = false, closed = false }
    function timer:start(timeout, repeat_interval, callback)
      self.timeout = timeout
      self.repeat_interval = repeat_interval
      self.callback = callback
    end
    function timer:stop()
      self.stopped = true
    end
    function timer:close()
      self.closed = true
    end
    function timer:is_closing()
      return self.closed
    end
    timers[#timers + 1] = timer
    return timer
  end,
})
local function flush()
  while #scheduled > 0 do
    table.remove(scheduled, 1)()
  end
end

local controller = require("maxa.interactions.chat.tools.builtin.runtime.image_analysis_controller")
local function reset_timers()
  timers = {}
end
local function chat()
  local value = {
    status = "success",
    messages = {},
    context_items = {},
    callbacks = {},
    tool_registry = { schemas = {}, in_use = {} },
    tools = { messages = {}, tool = nil },
    dispatches = 0,
    closes = 0,
    stops = 0,
  }
  value._submit_http = function(self)
    self.dispatches = self.dispatches + 1
    self.current_request = {}
  end
  value.submit = function(self, opts)
    if self.current_request or (opts and opts.noop) then
      return
    end
    if opts and opts.throw_before_dispatch then
      error("pre-dispatch")
    end
    if opts and opts.callback then
      opts.callback()
    end
    return self:_submit_http({})
  end
  value.done = function(self, output, _, tools)
    self.current_request = nil
    local content = vim.trim(table.concat(output or {}, ""))
    if content ~= "" then
      self.messages[#self.messages + 1] = { role = "assistant", content = content }
    end
    if tools then
      self.tools.tool = { name = "batch" }
    end
  end
  value.tools_done = function(self)
    self.tools.tool = nil
    return "continued"
  end
  value.stop = function(self)
    self.stops = self.stops + 1
    self.current_request = nil
  end
  value.close = function(self)
    self.closes = self.closes + 1
  end
  return value
end
test("default timeout fails, stops active work, and cleans up", function()
  reset_timers()
  local child, terminal = chat(), nil
  controller.install({
    chat = child,
    max_steps = 2,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  eq(1, #timers)
  eq(300000, timers[1].timeout)
  eq(0, timers[1].repeat_interval)
  child:submit()
  timers[1].callback()
  flush()
  eq("timed_out", terminal[1])
  eq("image analysis exceeded 300 seconds", terminal[2])
  eq(1, terminal[3])
  eq(1, child.stops)
  eq(1, child.closes)
  eq(true, timers[1].stopped)
  eq(true, timers[1].closed)
end)

test("explicit timeout is armed and final text completion closes its timer", function()
  reset_timers()
  local child, terminal = chat(), nil
  controller.install({
    chat = child,
    max_steps = 1,
    timeout = 1.5,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  eq(1500, timers[1].timeout)
  child:submit()
  child:done({ "done" }, nil, nil)
  flush()
  eq("completed", terminal[1])
  eq("done", terminal[2])
  eq(true, timers[1].stopped)
  eq(true, timers[1].closed)
  timers[1].callback()
  flush()
  eq("completed", terminal[1])
  eq(0, child.stops)
end)

test("counts actual dispatch; busy/no-op do not count and retry does", function()
  local child, terminal = chat(), nil
  local state = controller.install({
    chat = child,
    max_steps = 2,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit({ noop = true })
  eq(0, state.steps_used)
  child:submit()
  eq(1, state.steps_used)
  child:submit() -- busy
  eq(1, state.steps_used)
  child:done(nil, nil, { { name = "tool" } })
  child.tools.tool = nil
  child:tools_done()
  child:submit({ auto_submit = true }) -- retry/continuation dispatch
  eq(2, state.steps_used)
  child:done(nil, nil, { { name = "tool" } })
  child.tools.tool = nil
  child:tools_done()
  flush()
  eq(2, child.dispatches)
  eq("STEP_LIMIT_EXCEEDED", terminal[2])
end)

test("pre-dispatch throw is bounded failure and not counted", function()
  local child, terminal = chat(), nil
  local state = controller.install({
    chat = child,
    max_steps = 2,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit({ throw_before_dispatch = true })
  flush()
  eq(0, state.steps_used)
  eq("failed", terminal[1])
  assert(terminal[2]:find("MODEL_REQUEST_FAILED", 1, true))
end)

test("one-step final text completes with exact trimmed content", function()
  local child, terminal = chat(), nil
  controller.install({
    chat = child,
    max_steps = 1,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit()
  flush()
  eq(nil, terminal)
  child:done({ "# result\n", "\nBody" }, { "private reasoning" }, nil)
  flush()
  eq("completed", terminal[1])
  eq("# result\n\nBody", terminal[2])
  eq(1, terminal[3])
  eq(1, child.closes)
end)

test("last-step tool batch settles before exhaustion", function()
  local child, terminal = chat(), nil
  controller.install({
    chat = child,
    max_steps = 1,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit()
  child:done(nil, nil, { { name = "other" } })
  eq(nil, terminal)
  child.tools.tool = nil
  child:tools_done()
  flush()
  eq("STEP_LIMIT_EXCEEDED", terminal[2])
end)

test("cancellation waits for active request completion", function()
  local child, terminal = chat(), nil
  local state = controller.install({
    chat = child,
    max_steps = 2,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit()
  state.cancel("outer")
  flush()
  eq(nil, terminal)
  eq(0, child.closes)
  child:done({ "partial output must not win" }, nil, nil)
  flush()
  eq("cancelled", terminal[1])
  eq(1, child.closes)
end)

test("cancellation during a tool batch settles the reset callback without dispatch", function()
  local child, terminal = chat(), nil
  local state = controller.install({
    chat = child,
    max_steps = 2,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit()
  child:done({ "working" }, nil, { { name = "lookup" } })
  state.cancel("outer")
  flush()
  eq(nil, terminal)
  child:submit({
    auto_submit = true,
    callback = function()
      child:tools_done()
    end,
  })
  flush()
  eq("cancelled", terminal[1])
  eq(1, child.dispatches)
  eq(1, child.closes)
end)

test("plain final text completes for every regular budget", function()
  for _, budget in ipairs({ 1, 2 }) do
    local child, terminal = chat(), nil
    controller.install({
      chat = child,
      max_steps = budget,
      on_terminal = function(...)
        terminal = { ... }
      end,
    })
    child:submit()
    child:done({ "plain answer" }, nil, nil)
    flush()
    eq("completed", terminal[1])
    eq("plain answer", terminal[2])
    eq(1, child.closes)
    eq(1, child.dispatches)
  end
end)

test("tool continuation accepts the later tool-free final text", function()
  local child, terminal = chat(), nil
  child.messages = { { role = "assistant", content = "inherited answer" } }
  controller.install({
    chat = child,
    max_steps = 2,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit()
  child:done({ "intermediate commentary" }, nil, { { name = "lookup" } })
  flush()
  eq(nil, terminal)
  child:tools_done()
  child:submit()
  child:done({ "final ", "answer" }, nil, {})
  flush()
  eq("completed", terminal[1])
  eq("final answer", terminal[2])
  eq(2, terminal[3])
  child:submit()
  child:_submit_http({})
  eq(2, child.dispatches)
  eq(1, child.closes)
end)

test("first empty response gets one corrective request beyond max_steps", function()
  local child, terminal = chat(), nil
  local state = controller.install({
    chat = child,
    max_steps = 1,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit()
  child:done({ " \n " }, { "reasoning is not a final answer" }, nil)
  flush()
  eq(nil, terminal)
  eq(2, child.dispatches)
  eq(2, state.steps_used)
  eq(1, state.regular_steps_used)
  eq(true, state.empty_retry_used)
  local correction = child.messages[#child.messages]
  eq("user", correction.role)
  assert(correction.content:find("one nonempty final assistant text response", 1, true))
  child:done({ " corrected answer " }, nil, nil)
  flush()
  eq("completed", terminal[1])
  eq("corrected answer", terminal[2])
  eq(2, terminal[3])
  eq(1, terminal[4])
end)

test("second tool-free empty response fails with FINAL_RESPONSE_REQUIRED", function()
  local child, terminal = chat(), nil
  controller.install({
    chat = child,
    max_steps = 1,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit()
  child:done(nil, nil, nil)
  flush()
  eq(nil, terminal)
  child:done({ " \n " }, nil, nil)
  flush()
  eq("failed", terminal[1])
  eq("FINAL_RESPONSE_REQUIRED", terminal[2])
  eq(2, terminal[3])
  eq(1, terminal[4])
  eq(2, child.dispatches)
end)

test("corrective request with tools exhausts the total request limit", function()
  local child, terminal = chat(), nil
  controller.install({
    chat = child,
    max_steps = 2,
    on_terminal = function(...)
      terminal = { ... }
    end,
  })
  child:submit()
  child:done(nil, nil, nil)
  child:done({ "not final" }, nil, { { name = "lookup" } })
  eq(nil, terminal)
  child.tools.tool = nil
  child:tools_done()
  flush()
  eq("failed", terminal[1])
  eq("STEP_LIMIT_EXCEEDED", terminal[2])
  eq(2, terminal[3])
  eq(2, terminal[4])
end)

test("stopped and failed requests do not return partial text as success", function()
  for _, status in ipairs({ "stopped", "error" }) do
    local child, terminal = chat(), nil
    controller.install({
      chat = child,
      max_steps = 1,
      on_terminal = function(...)
        terminal = { ... }
      end,
    })
    child:submit()
    if status == "error" then
      child.status = "error"
    end
    child:done({ "partial answer" }, nil, nil, nil, { status = status })
    flush()
    eq(status == "stopped" and "cancelled" or "failed", terminal[1])
    eq(1, child.closes)
  end
end)

vim.schedule = original_schedule
vim.uv = original_uv
print(string.format("image_analysis_controller tests: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
