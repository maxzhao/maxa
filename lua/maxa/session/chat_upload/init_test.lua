-- Run: nvim --headless -l lua/maxa/session/chat_upload/init_test.lua

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or "values differ") .. "\nactual=" .. vim.inspect(actual) .. "\nexpected=" .. vim.inspect(expected))
end

local upload = require("maxa.session.chat_upload")
local runtime = require("maxa.config")
runtime.configure_early({ presets = { default = { adapter = "test" } }, chat_upload = { hostname = "upload.example.com" } })

local function chat(bufnr)
  local value = {
    bufnr = bufnr,
    status = "",
    ui = { locked = false },
    inserted = {},
  }
  function value.ui:lock_buf() self.locked = true end
  function value.ui:unlock_buf() self.locked = false end
  function value:add_buf_message(message, opts)
    table.insert(self.inserted, message.content)
    if opts and type(opts.insert_at) == "table" then
      local start = opts.insert_at
      local lines = vim.split(message.content, "\n", { plain = true, trimempty = false })
      vim.api.nvim_buf_set_text(self.bufnr, start.row, start.col, start.row, start.col, lines)
      local finish = {
        row = start.row + #lines - 1,
        col = #lines == 1 and (start.col + #lines[1]) or #lines[#lines],
      }
      return finish.row + 1, nil, { start = vim.deepcopy(start), ["end"] = finish }
    end
    local count = vim.api.nvim_buf_line_count(self.bufnr)
    local first = vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1]
    if count == 1 and first == "" then
      vim.api.nvim_buf_set_lines(self.bufnr, 0, 1, false, { message.content })
      return 1
    end
    vim.api.nvim_buf_set_lines(self.bufnr, count, count, false, { message.content })
    return count + 1
  end
  return value
end

local original_notify = vim.notify
vim.notify = function() end

test("loopback mode accepts only matching HTTP ready fields", function()
  runtime.configure_early({ presets = { default = { adapter = "test" } } })
  local ready = { event = "ready", bind = "127.0.0.1", host = "127.0.0.1", port = 43127,
    url = "http://127.0.0.1:43127/session/token/", session_id = "local-session" }
  local c = chat(vim.api.nvim_create_buf(false, true))
  local state = { chat = c, bufnr = c.bufnr, project_root = ".", stdout = "", locked = false, finished = false }
  upload._handle_event(state, ready)
  assert(state.ready and c.ui.locked)
  upload._finish(state, "cancelled")
  local bad = vim.deepcopy(ready)
  bad.bind = "0.0.0.0"
  local denied = { chat = c, bufnr = c.bufnr, project_root = ".", stdout = "", locked = false, finished = false }
  upload._handle_event(denied, bad)
  assert(denied.finished and not denied.ready)
  runtime.configure_early({ presets = { default = { adapter = "test" } }, chat_upload = { hostname = "upload.example.com" } })
end)
test("ready locks and submitted inserts paths", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.maxa/upload/session-a", "p")
  vim.fn.writefile({ "a" }, root .. "/.maxa/upload/session-a/a.txt")
  local c = chat(vim.api.nvim_create_buf(false, true))
  local state = { chat = c, bufnr = c.bufnr, project_root = root, stdout = "", locked = false, finished = false }
  upload._handle_event(state, { event = "ready", bind = "0.0.0.0", host = "upload.example.com", port = 43127, url = "https://upload.example.com:43127/session/token/", session_id = "session-a" })
  assert(c.ui.locked)
  upload._handle_event(state, { event = "submitted", paths = { ".maxa/upload/session-a/a.txt" } })
  assert(c.ui.locked and state.pending_terminal.kind == "submitted")
  upload._finish(state, state.pending_terminal.kind, state.pending_terminal.detail)
  assert(not c.ui.locked)
  eq(vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false), { ".maxa/upload/session-a/a.txt" })
  vim.fn.delete(root, "rf")
end)

test("inline placeholder replaces only its captured range", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.maxa/upload/session-inline", "p")
  vim.fn.writefile({ "a" }, root .. "/.maxa/upload/session-inline/a.txt")
  local c = chat(vim.api.nvim_create_buf(false, true))
  vim.api.nvim_buf_set_lines(c.bufnr, 0, -1, false, { "before  after" })
  local state = {
    chat = c,
    bufnr = c.bufnr,
    project_root = root,
    stdout = "",
    locked = false,
    finished = false,
    insertion_context = { slash_anchor = { row = 0, col = #"before " } },
  }
  upload._handle_event(state, { event = "ready", bind = "0.0.0.0", host = "upload.example.com", port = 43127, url = "https://upload.example.com:43127/session/token/", session_id = "session-inline" })
  upload._handle_event(state, { event = "submitted", paths = { ".maxa/upload/session-inline/a.txt" } })
  upload._finish(state, state.pending_terminal.kind, state.pending_terminal.detail)
  eq(vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false), { "before .maxa/upload/session-inline/a.txt after" })
  vim.fn.delete(root, "rf")
end)

test("cancel unlocks without insertion", function()
  local c = chat(vim.api.nvim_create_buf(false, true))
  local state = { chat = c, bufnr = c.bufnr, project_root = ".", stdout = "", locked = false, finished = false }
  upload._handle_event(state, { event = "ready", bind = "0.0.0.0", host = "upload.example.com", port = 43127, url = "https://upload.example.com:43127/session/token/", session_id = "session-b" })
  upload._handle_event(state, { event = "cancelled" })
  assert(c.ui.locked and state.pending_terminal.kind == "cancelled")
  upload._finish(state, state.pending_terminal.kind, state.pending_terminal.detail)
  assert(not c.ui.locked)
  eq(vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false), { "" })
end)

test("malformed stdout fails and unlocks", function()
  local c = chat(vim.api.nvim_create_buf(false, true))
  c.ui.locked = true
  local killed = false
  local state = {
    chat = c,
    bufnr = c.bufnr,
    project_root = ".",
    stdout = "",
    locked = true,
    finished = false,
    handle = { kill = function() killed = true end },
  }
  upload._consume_stdout(state, "not-json\n")
  assert(state.finished and killed and not c.ui.locked)
end)

test("startup error is accepted before ready", function()
  local c = chat(vim.api.nvim_create_buf(false, true))
  local state = { chat = c, bufnr = c.bufnr, project_root = ".", stdout = "", locked = false, finished = false }
  upload._handle_event(state, { event = "error", code = "no_private_lan_ipv4", message = "No private address" })
  assert(state.finished and not c.ui.locked)
end)

test("invalid ready host is rejected", function()
  local c = chat(vim.api.nvim_create_buf(false, true))
  local state = { chat = c, bufnr = c.bufnr, project_root = ".", stdout = "", locked = false, finished = false }
  upload._handle_event(state, { event = "ready", bind = "0.0.0.0", host = "127.0.0.1", port = 43127, url = "http://127.0.0.1:43127/session/token/", session_id = "session-x" })
  assert(state.finished and not c.ui.locked)
end)

test("busy chat does not spawn", function()
  local c = chat(vim.api.nvim_create_buf(false, true))
  c.current_request = {}
  local spawned = false
  local state = upload.start(c, { spawn = function() spawned = true end })
  assert(state == nil and not spawned)
end)

test("spawn failure clears controller state", function()
  local c = chat(vim.api.nvim_create_buf(false, true))
  local context = { slash_anchor = { row = 0, col = 0 } }
  local state = upload.start(c, { context = context, spawn = function() error("spawn failed") end })
  assert(state == nil and upload.active(c.bufnr) == nil and c.ui.locked == false)
  assert(context.slash_anchor_extmark == nil, "spawn failure must not retain an anchor")
end)

test("nonzero exit after submitted event does not insert", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.maxa/upload/session-d", "p")
  vim.fn.writefile({ "d" }, root .. "/.maxa/upload/session-d/d.txt")
  local c = chat(vim.api.nvim_create_buf(false, true))
  local process = {}
  local context = { slash_anchor = { row = 0, col = 0 } }
  local state = upload.start(c, {
    project_root = root,
    context = context,
    spawn = function(_, options, callback)
      process.options = options
      process.callback = callback
      return { kill = function() end }
    end,
  })
  assert(context.slash_anchor_extmark, "running upload must track its invocation anchor")
  process.options.stdout(nil, vim.json.encode({ event = "ready", bind = "0.0.0.0", host = "upload.example.com", port = 43127, url = "https://upload.example.com:43127/session/token/", session_id = "session-d" }) .. "\n")
  process.options.stdout(nil, vim.json.encode({ event = "submitted", paths = { ".maxa/upload/session-d/d.txt" } }) .. "\n")
  vim.wait(1000, function() return state.pending_terminal ~= nil end)
  process.callback({ code = 1 })
  vim.wait(1000, function() return state.finished end)
  assert(not c.ui.locked)
  assert(context.slash_anchor_extmark == nil, "terminal upload path must release its anchor")
  eq(vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false), { "" })
  vim.fn.delete(root, "rf")
end)

test("chat close kills active service and inserts nothing", function()
  local c = chat(vim.api.nvim_create_buf(false, true))
  local killed = false
  local process = {}
  local state = upload.start(c, {
    spawn = function(_, options, callback)
      process.options = options
      process.callback = callback
      return { kill = function() killed = true end }
    end,
  })
  process.options.stdout(nil, vim.json.encode({ event = "ready", bind = "0.0.0.0", host = "upload.example.com", port = 43127, url = "https://upload.example.com:43127/session/token/", session_id = "session-e" }) .. "\n")
  vim.wait(1000, function() return state.ready end)
  vim.api.nvim_exec_autocmds("User", { pattern = "MaxaAIChatClosed", data = { bufnr = c.bufnr } })
  assert(killed and state.finished and not c.ui.locked)
  eq(vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false), { "" })
end)

test("submitted outside session is rejected", function()
  local c = chat(vim.api.nvim_create_buf(false, true))
  local state = {
    chat = c,
    bufnr = c.bufnr,
    project_root = ".",
    stdout = "",
    locked = false,
    finished = false,
    ready = true,
    session_id = "session-c",
  }
  upload._handle_event(state, { event = "submitted", paths = { ".maxa/upload/other/a.txt" } })
  assert(state.finished)
  eq(c.inserted, {})
end)

vim.notify = original_notify
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then vim.cmd("cquit 1") end
