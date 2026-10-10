-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/display_test.lua
-- Canonical tool display owner regression.

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name)
    print("  Error: " .. tostring(err))
  end
end

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %q, got %q", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
package.loaded["maxa.config"] = {
  constants = { LLM_ROLE = "llm", USER_ROLE = "user" },
  interactions = { chat = { roles = { llm = "Assistant", user = "User" } } },
  runtime = function() return { presets = {}, telegram_bridge = {} } end,
}
local tool_display = require("maxa.interactions.chat.tools.display")
local presentation = require("maxa.interactions.chat.tools.presentation")

print("\n=== Testing tool_display ===\n")

test("format_tool_detail should show Ability target for load", function()
  local actual = tool_display.format_tool_detail("load", { target = "task-admin" })
  assert_equal("load task-admin", actual)
end)

test("format_tool_detail should show wait and keep titles with historical fallbacks", function()
  assert_equal('wait "Inspect image analysis"', tool_display.format_tool_detail("wait", {
    title = "Inspect image analysis",
  }))
  assert_equal("wait", tool_display.format_tool_detail("wait", {}))
  assert_equal('keep "Preserve tool result"', tool_display.format_tool_detail("keep", {
    title = "Preserve tool result",
  }))
  assert_equal("keep", tool_display.format_tool_detail("keep", {}))
end)

test("analyze display should show a bounded title and preserve untitled history", function()
  local args = { title = "Inspect\n prepared images" }
  local icon, detail = tool_display.get_display("analyze", args)
  assert_equal("⚡", icon)
  assert_equal('analyze "Inspect prepared images"', detail)
  assert_equal('analyze "' .. string.rep("图", 100) .. '…"', tool_display.format_tool_detail("analyze", {
    title = string.rep("图", 101),
  }))
  assert_equal("analyze", tool_display.format_tool_detail("analyze", {}), "untitled history fallback")
  assert_equal("analyze", tool_display.format_tool_detail("analyze", { title = " \t" }), "blank title fallback")
  local summary = tool_display.build_tool_summary_text({
    ["function"] = { name = "analyze", arguments = vim.json.encode(args) },
  }, { duration_ms = 1200 })
  assert_equal('⚡ analyze "Inspect prepared images" (1.2s)', summary)
end)

test("run display should show Lua scope title and fire event", function()
  assert_equal('@neovim:lua "Inspect runtime"', tool_display.format_tool_detail("run", {
    scope = "@neovim:lua", title = "Inspect runtime", command = "vim.print(1)",
  }))
  assert_equal("lua", tool_display.format_tool_detail("lua", { title = "Inspect runtime" }), "retired tool fallback")
  assert_equal("fire TaskPhaseChanged", tool_display.format_tool_detail("fire", { event = "TaskPhaseChanged" }))
  assert_equal("fire", tool_display.format_tool_detail("fire", {}), "historical fire fallback")
end)

test("delete display should stay inline for one path and fold bounded path lists", function()
  assert_equal("delete one.txt", tool_display.format_tool_detail("delete", { paths = { "one.txt" } }))
  assert_equal(0, #presentation.builtin("delete", { paths = { "one.txt" } }).blocks, "single path fold")
  assert_equal("delete (2 items)", tool_display.format_tool_detail("delete", { paths = { "one.txt", "two.txt" } }))
  assert_equal(
    "1. one.txt\n2. two.txt",
    presentation.builtin("delete", { paths = { "one.txt", "two.txt" } }).blocks[1].content,
    "two path fold"
  )

  local ten_paths = {}
  local eleven_paths = {}
  for index = 1, 11 do
    eleven_paths[index] = "file" .. index .. ".txt"
    if index <= 10 then
      ten_paths[index] = eleven_paths[index]
    end
  end
  local ten = presentation.builtin("delete", { paths = ten_paths }).blocks[1].content
  assert(not ten:find("more items", 1, true), "ten paths should not show an omitted count")
  local eleven = presentation.builtin("delete", { paths = eleven_paths }).blocks[1].content
  assert(eleven:find("10. file10.txt", 1, true), "tenth path missing")
  assert(not eleven:find("file11.txt", 1, true), "eleventh path should be omitted")
  assert(eleven:find("… and 1 more items", 1, true), "omitted count missing")

  local wrapped = presentation.builtin("run", {
    scope = "tool", command = "delete",
    args = vim.json.encode({ paths = { "one.txt", "two.txt" } }),
  })
  assert_equal("fold", wrapped.blocks[1].kind, "wrapped delete fold kind")
  assert_equal("1. one.txt\n2. two.txt", wrapped.blocks[1].content, "wrapped delete fold")
end)

test("get_display should show Ability target for titleless run with stringified args", function()
  local icon, actual = tool_display.get_display("run", {
    scope = "tool", command = "load",
    args = vim.json.encode({ target = "task-admin" }),
  })
  assert_equal("🔗", icon)
  assert_equal("load task-admin", actual)
end)

test("run display should show Windows execution title", function()
  local actual = tool_display.format_tool_detail("run", {
    scope = "win", title = "Inspect Windows", command = 'powershell -NoProfile -Command "Write-Host hi"',
  })
  assert_equal('win "Inspect Windows"', actual)
  assert_equal("winrun", tool_display.format_tool_detail("winrun", { command = "Write-Host hi" }), "retired tool fallback")
end)

test("get_display should keep MCP-backed Ability target for titleless run", function()
  local icon, actual = tool_display.get_display("run", {
    scope = "tool", command = "@time:get_current_time", args = "{}",
  })
  assert_equal("🔗", icon)
  assert_equal("@time:get_current_time", actual)
end)

test("runtime ask display renders assistant request, transient status, and user response", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "base" })
  local args = { mode = "choice", message = "Choose", choices = { { { label = "Retry", value = "retry" } } } }
  local call = { id = "ask-live", ["function"] = { name = "ask", arguments = args } }
  local chat = { bufnr = bufnr, _last_role = "llm", messages = { { role = "llm", tools = { calls = { call } } } },
    ui = { last_role = "llm", set_header = function(_, lines, role)
      lines[#lines + 1], lines[#lines + 2] = "## " .. role, ""
    end },
  }
  local ask = require("maxa.interactions.chat.tools.builtin.runtime.ask_display")
  local handle = tool_display.create_ui(chat, call.id, "ask", args)
  tool_display.set_request_view(handle, ask.display(args))
  assert(handle:show(ask.request(args, "等待 Chat / Telegram 响应")))
  local buffer = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  assert(buffer:find("## Assistant", 1, true), "request visual role")
  assert(buffer:find("Retry", 1, true), "request choices")
  assert(buffer:find("等待 Chat / Telegram 响应", 1, true), "transient status missing")
  assert(handle:show(ask.request(args, "Telegram 不可用，等待 Chat 响应")))
  buffer = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  assert(buffer:find("Telegram 不可用，等待 Chat 响应", 1, true), "channel status not replaced")
  tool_display.clear_transient_ui(handle)
  tool_display.add_tool_output(chat, { name = "ask", args = args, function_call = call }, "retry", "", function(self, _, text)
    self.messages[#self.messages + 1] = { role = "tool", content = text, tools = { call_id = call.id } }
  end)
  buffer = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local request = assert(buffer:find("## Assistant", 1, true), "final request role")
  local response = assert(buffer:find("## User", 1, true), "response visual role")
  assert(request < response and buffer:sub(response):find("retry", 1, true), "request/response layout")
  assert_equal("tool", chat.messages[2].role, "visual response must retain canonical role")
  assert_equal("retry", chat.messages[2].content, "canonical response")
  assert(not buffer:find("等待 Chat", 1, true), "transient channel status remained")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("ask render copy uses assistant request and user result without mutating canonical history", function()
  local messages = {
    {
      role = "llm",
      content = "",
      tools = {
        calls = {
          {
            call_id = "ask-1",
            ["function"] = {
              name = "ask",
              arguments = vim.json.encode({
                mode = "choice",
                message = "Choose **one**",
                choices = { { { label = "Retry", value = "retry" } } },
              }),
            },
          },
        },
      },
    },
    { role = "tool", content = '用户选择了"retry"', tools = { call_id = "ask-1" }, _meta = {} },
    { role = "user", content = "" },
  }
  local canonical = vim.deepcopy(messages)
  local rendered = tool_display.build_render_messages(messages)
  assert(vim.deep_equal(canonical, messages), "canonical transcript changed")

  local request_found, response_found = false, false
  for _, message in ipairs(rendered) do
    if message.role == "llm" and message.opts and message.opts._presentation_display then
      request_found = message.content:match("Choose %*%*one%*%*") ~= nil
        and message.content:match("Retry") ~= nil
        and message.content:match("`retry`") ~= nil
    elseif message.role == "user" and message.opts and message.opts._presentation_display then
      response_found = message.content == '用户选择了"retry"'
    end
  end
  assert(request_found, "assistant-style ask request missing")
  assert(response_found, "user-style ask response missing")
  assert(rendered[#rendered].opts.force_role == true, "restored Chat input needs a distinct user header")
end)

test("multiple asks restore in request-result order", function()
  local function ask_call(call_id, message)
    return {
      call_id = call_id,
      ["function"] = {
        name = "ask",
        arguments = vim.json.encode({ mode = "input", message = message }),
      },
    }
  end
  local messages = {
    { role = "llm", content = "", tools = { calls = { ask_call("ask-a", "First?"), ask_call("ask-b", "Second?") } } },
    { role = "tool", content = "one", tools = { call_id = "ask-a" }, _meta = {} },
    { role = "tool", content = "two", tools = { call_id = "ask-b" }, _meta = {} },
  }
  local canonical = vim.deepcopy(messages)
  local rendered = tool_display.build_render_messages(messages)
  assert(vim.deep_equal(canonical, messages), "canonical transcript changed")
  local displays = {}
  for _, message in ipairs(rendered) do
    if message.opts and message.opts._presentation_display then
      table.insert(displays, { role = message.role, content = message.content })
    end
  end
  assert_equal(4, #displays)
  assert(displays[1].content:find("First?", 1, true), "first request is out of order")
  assert_equal("one", displays[2].content, "first response is out of order")
  assert(displays[3].content:find("Second?", 1, true), "second request is out of order")
  assert_equal("two", displays[4].content, "second response is out of order")
end)

test("multicall declaration keeps identity and closure facts separate from member results", function()
  local args = { title = "Inspect tools" }
  local raw = vim.json.encode({ status = "completed", mode = "parallel", members = 1, succeeded = 1, failed = 0, not_executed = 0 })
  local payload = require("maxa.interactions.chat.tools.display_helpers").decode_payload(raw)
  assert(payload and payload.status == "completed" and payload.results == nil)
  local view = presentation.builtin("multicall", args, { ok = true, text = raw })
  assert_equal('multicall "Inspect tools"', view.summary)
  assert_equal(0, #view.blocks, "declaration must not duplicate member outputs")
end)

test("SubAgent answer display should extract raw and fenced JSON results", function()
  local answer = require("maxa.mcphub.native_servers.subagent.tools.presentation").answer("@subagent:run_agent")
  local raw = vim.json.encode({ content = "run result" })
  local fenced = "````\n" .. vim.json.encode({ content = "subagent result" }) .. "\n````"
  assert_equal("run result", answer({}, { ok = true, text = raw }).blocks[1].content, "raw subagent content")
  assert_equal("subagent result", answer({}, { ok = true, text = fenced }).blocks[1].content, "fenced subagent content")
end)

test("resume_agent should use the SubAgent answer fold view", function()
  local definition = require("maxa.mcphub.native_servers.subagent.tools.resume_agent")
  local view = presentation.view(definition, {}, { ok = true, text = vim.json.encode({ content = "resumed answer" }) }, "@subagent:resume_agent")
  assert_equal("@subagent:resume_agent", view.summary, "resume identity")
  assert_equal("fold", view.blocks[1].kind, "resume answer fold")
  assert_equal("resumed answer", view.blocks[1].content, "resume answer content")
end)


test("pending tool display should animate and be replaced on completion", function()
  local Chat = {}
  Chat.__index = Chat
  function Chat:add_tool_output(tool, for_llm, for_user)
    self.messages = self.messages or {}
    table.insert(self.messages, { role = "tool", content = for_llm, tools = { call_id = tool.function_call.id } })
    return true
  end

  local by_buf = {}
  function Chat.buf_get_chat(bufnr) return by_buf[bufnr] end
  local previous_chat = package.loaded["maxa.interactions.chat"]
  package.loaded["maxa.interactions.chat"] = Chat

  tool_display.setup()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "chat", "", "", "", "" })
  local chat = setmetatable({ bufnr = bufnr, messages = {}, tools = { status = "success" } }, Chat)
  by_buf[bufnr] = chat
  tool_display.push_pending_tool(bufnr, "run", { command = "sleep 1" }, 0, "call1")

  vim.api.nvim_exec_autocmds("User", {
    pattern = "MaxaAIToolStarted",
    data = { bufnr = bufnr },
  })

  local pending_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pending = pending_lines[#pending_lines]
  assert_equal(3, #pending_lines, "pending summary should collapse trailing blank lines")
  assert_equal("", pending_lines[2], "pending summary should keep one blank separator")
  if not pending or pending:match("^⏳ ") or not pending:match("^⠋ ") or not pending:match("run") or not pending:match("%s%d+s$") then
    error("pending spinner line not inserted correctly: " .. tostring(pending))
  end

  local handle = tool_display.create_ui(chat, "call1", "run", { command = "sleep 1" })
  assert(handle:detail("first child tool"))
  assert(handle:detail("second child tool"))
  assert_equal(4, vim.api.nvim_buf_line_count(bufnr), "detail update must replace its one row")
  assert_equal(2, tool_display.get_tool_summary_line(bufnr, "call1"), "detail must not move the parent mark")

  vim.wait(180, function()
    return false
  end)

  assert_equal(2, tool_display.get_tool_summary_line(bufnr, "call1"), "spinner must keep the parent mark")
  local running_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert_equal(4, #running_lines, "spinner must not append another detail row")
  assert_equal("   └─ second child tool", running_lines[4], "spinner must not overwrite the detail")
  local animated = running_lines[3]
  if not animated or animated:match("^⏳ ") or not animated:match("%s%d+s$") or not animated:match("^⠋ ") and not animated:match("^⠙ ") and not animated:match("^⠹ ") and not animated:match("^⠸ ") and not animated:match("^⠼ ") and not animated:match("^⠴ ") and not animated:match("^⠦ ") and not animated:match("^⠧ ") and not animated:match("^⠇ ") and not animated:match("^⠏ ") then
    error("pending spinner line disappeared before completion: " .. tostring(animated))
  end

  tool_display.add_tool_output(chat, {
    name = "run",
    args = { command = "sleep 1" },
    function_call = { id = "call1" },
  }, "ok", "ok", Chat.add_tool_output)

  local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert_equal(3, #final_lines, "completion must remove only the transient detail")
  assert_equal("chat", final_lines[1], "completion must preserve preceding Chat content")
  local final = final_lines[3]
  if not final or not final:match("^⚡ ") or final:match("^⏳ ") or final:match("^⠋ ") then
    error("pending spinner line not replaced by final summary: " .. tostring(final))
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, { "", "", "", "" })
  tool_display.push_pending_tool(bufnr, "edit", { path = "next.lua" }, 1, "call2")
  vim.api.nvim_exec_autocmds("User", {
    pattern = "MaxaAIToolStarted",
    data = { bufnr = bufnr },
  })

  local consecutive_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert_equal(5, #consecutive_lines, "consecutive summaries should have one separator")
  assert_equal("", consecutive_lines[4], "consecutive summary separator")
  assert(consecutive_lines[3]:match("^⚡ "), "first completed summary should remain intact")
  assert(consecutive_lines[5]:match("^⠋ "), "second pending summary should follow one blank line")

  tool_display.add_tool_output(chat, {
    name = "edit",
    args = { path = "next.lua" },
    function_call = { id = "call2" },
  }, "ok", "ok", Chat.add_tool_output)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  package.loaded["maxa.interactions.chat"] = previous_chat
end)

test("completed tool fallback should normalize trailing blank lines", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "response", "", "", "" })
  local chat = { bufnr = bufnr, messages = {}, tools = { status = "success" } }
  local function store_output(self, tool, for_llm)
    table.insert(self.messages, { role = "tool", content = for_llm, tools = { call_id = tool.function_call.id } })
  end

  tool_display.add_tool_output(chat, {
    name = "edit",
    args = { path = "fallback.lua" },
    function_call = { id = "fallback-call" },
  }, "ok", "ok", store_output)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert_equal(3, #lines, "fallback summary should collapse trailing blank lines")
  assert_equal("", lines[2], "fallback summary should keep one blank separator")
  assert(lines[3]:match("^⚡ "), "fallback summary should follow the separator")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("restored delete summaries should rebuild bounded fold content", function()
  local messages = {
    {
      role = "llm",
      tools = {
        calls = {
          {
            id = "delete_call",
            ["function"] = {
              name = "delete",
              arguments = vim.json.encode({ paths = { "one.txt", "two.txt" } }),
            },
          },
        },
      },
    },
    {
      role = "tool",
      content = "Successfully deleted 2 items",
      tools = { call_id = "delete_call" },
      _meta = {},
    },
  }

  local canonical = vim.deepcopy(messages)
  local rendered = tool_display.build_render_messages(messages)
  assert(vim.deep_equal(canonical, messages), "canonical transcript changed")
  local restored
  for _, message in ipairs(rendered) do
    if message.opts and message.opts._presentation_display then restored = message end
  end
  assert(restored, "restored delete display missing")
  assert(restored.content:find("⚡ delete (2 items)", 1, true), "restored delete summary missing")
  assert(restored.content:find("1. one.txt\n2. two.txt", 1, true), "restored delete fold content missing")
  assert(restored._meta._presentation_fold, "restored delete fold metadata missing")
  assert_equal("result", restored.opts._display_origin.phase, "restored result provenance")
  assert_equal("delete_call", restored.opts._display_origin.call_id, "restored call provenance")
  assert_equal(true, restored._meta._presentation_fold.collapsed, "restored fold defaults collapsed")
end)

test("highlight ignores stale summary line after rerender", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "chat" })

  local ok, err = pcall(tool_display.apply_highlight, bufnr, 1, true)
  assert_equal(true, ok, "stale highlight must not raise")
  assert_equal(nil, err, "stale highlight error")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
