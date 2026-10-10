-- Run: nvim --headless -l lua/maxa/session/telegram_upload/init_test.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local calls, notifications = {}, {}
local client = {}
function client.create_chat_upload(payload, cb) calls.create = payload; cb(true, { request_id = "r1", session_id = "session123", status = "pending" }, {}) end
function client.poll_chat_upload(_, _, cb) calls.poll = (calls.poll or 0) + 1; client.poll_cb = cb end
function client.cancel_chat_upload(_, payload, cb) calls.cancel = payload; if cb then cb(true, { status = "cancelled" }, {}) end end
package.loaded["maxa.session.telegram_bridge.client"] = client
package.loaded["maxa.session.telegram_bridge.config"] = { is_enabled = function() return true end }
package.loaded["maxa.session.telegram_bridge.hooks"] = {
  instance = function() return "n1" end,
  heartbeat = function(cb) calls.heartbeat = (calls.heartbeat or 0) + 1; cb(true, {}, {}) end,
}
package.loaded["maxa.session.telegram_bridge.status"] = { chat_payload = function() return { project_root = vim.uv.cwd(), save_id = "save1" } end }
local local_upload_active = false
package.loaded["maxa.session.chat_upload"] = { active = function() return local_upload_active and {} or nil end }

vim.notify = function(message) table.insert(notifications, message) end
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "existing" })
local locked, unlocked, submitted = 0, 0, 0
local function make_chat(buffer)
  return {
    bufnr = buffer,
    ui = { lock_buf = function() locked = locked + 1 end, unlock_buf = function() unlocked = unlocked + 1 end },
    add_buf_message = function(_, message, opts)
      if opts and type(opts.insert_at) == "table" then
        local start = opts.insert_at
        local message_lines = vim.split(message.content, "\n", { plain = true, trimempty = false })
        vim.api.nvim_buf_set_text(buffer, start.row, start.col, start.row, start.col, message_lines)
        local finish = {
          row = start.row + #message_lines - 1,
          col = #message_lines == 1 and (start.col + #message_lines[1]) or #message_lines[#message_lines],
        }
        return finish.row + 1, nil, { start = vim.deepcopy(start), ["end"] = finish }
      end
      local line = vim.api.nvim_buf_line_count(buffer) + 1
      vim.api.nvim_buf_set_lines(buffer, -1, -1, false, { message.content })
      return line
    end,
    submit = function() submitted = submitted + 1 end,
  }
end
local chat = make_chat(bufnr)
local upload = require("maxa.session.telegram_upload")
local state = assert(upload.start(chat))
assert(calls.heartbeat == 1 and calls.create.instance_id == "n1" and calls.create.save_id == "save1")
assert(locked == 1 and calls.poll == 1)
assert(vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] == upload.placeholder)
local relative = ".maxa/upload/session123/file.txt"
local absolute = vim.fs.joinpath(vim.uv.cwd(), relative)
vim.fn.mkdir(vim.fs.dirname(absolute), "p")
vim.fn.writefile({ "x" }, absolute)
client.poll_cb(true, { request_id = "r1", session_id = "session123", status = "completed", path = relative, text = "caption" }, {})
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(lines[2] == relative and lines[3] == "caption")
assert(unlocked == 1 and submitted == 0 and upload.active(bufnr) == nil)
vim.fn.delete(vim.fs.joinpath(vim.uv.cwd(), ".maxa/upload/session123"), "rf")

-- Inline placeholders replace only their captured token range.
client.create_chat_upload = function(_, cb) cb(true, { request_id = "r-inline", session_id = "sessioninline", status = "pending" }, {}) end
local inline_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(inline_buf, 0, -1, false, { "before  after" })
local inline_chat = make_chat(inline_buf)
upload.start(inline_chat, { context = { slash_anchor = { row = 0, col = #"before " } } })
client.poll_cb(true, { request_id = "r-inline", session_id = "sessioninline", status = "completed", text = "done" }, {})
assert(vim.api.nvim_buf_get_lines(inline_buf, 0, -1, false)[1] == "before done after")

-- Multiline text replaces the one-line placeholder instead of appending beside it.
client.create_chat_upload = function(_, cb) cb(true, { request_id = "r-location", session_id = "sessionloc", status = "pending" }, {}) end
local location_buf = vim.api.nvim_create_buf(false, true)
local location_chat = make_chat(location_buf)
upload.start(location_chat)
client.poll_cb(true, { request_id = "r-location", session_id = "sessionloc", status = "completed", text = "纬度：31.2304\n经度：121.4737" }, {})
local location_lines = vim.api.nvim_buf_get_lines(location_buf, 0, -1, false)
assert(location_lines[#location_lines - 1] == "纬度：31.2304" and location_lines[#location_lines] == "经度：121.4737")
assert(not table.concat(location_lines, "\n"):find(upload.placeholder, 1, true))

-- Create failure must report decoded HTTP detail and must not lock or insert.
client.create_chat_upload = function(_, cb) cb(false, { detail = "caller chat is not active primary" }, { code = 0, http_status = 409, stderr = "" }) end
local bufnr2 = vim.api.nvim_create_buf(false, true)
local chat2 = make_chat(bufnr2)
local locked_before_failure = locked
local failed_context = { slash_anchor = { row = 0, col = 0 } }
assert(upload.start(chat2, { context = failed_context }))
assert(locked == locked_before_failure and vim.api.nvim_buf_line_count(bufnr2) == 1)
assert(failed_context.slash_anchor_extmark == nil, "create failure must release invocation anchor")
assert(notifications[#notifications]:find("caller chat is not active primary", 1, true))

-- Invalid terminal path cancels and never submits.
client.create_chat_upload = function(_, cb) cb(true, { request_id = "r2", session_id = "session456", status = "pending" }, {}) end
local bufnr3 = vim.api.nvim_create_buf(false, true)
local chat3 = make_chat(bufnr3)
upload.start(chat3)
client.poll_cb(true, { request_id = "r2", session_id = "session456", status = "completed", path = "../bad" }, {})
assert(calls.cancel.save_id == "save1" and submitted == 0)

-- Chat close cancels, unlocks, and removes unchanged placeholder.
client.create_chat_upload = function(_, cb) cb(true, { request_id = "r3", session_id = "session789", status = "pending" }, {}) end
local bufnr4 = vim.api.nvim_create_buf(false, true)
local chat4 = make_chat(bufnr4)
upload.start(chat4)
vim.api.nvim_exec_autocmds("User", { pattern = "MaxaAIChatClosed", data = { bufnr = bufnr4 } })
assert(calls.cancel.instance_id == "n1" and upload.active(bufnr4) == nil)
assert(vim.api.nvim_buf_get_lines(bufnr4, 0, -1, false)[1] == "")

-- Changed placeholder is preserved; completed result uses normal insertion fallback.
client.create_chat_upload = function(_, cb) cb(true, { request_id = "r4", session_id = "sessionabc", status = "pending" }, {}) end
local bufnr5 = vim.api.nvim_create_buf(false, true)
local chat5 = make_chat(bufnr5)
upload.start(chat5)
vim.api.nvim_buf_set_lines(bufnr5, 0, 1, false, { "user changed this" })
local fallback_file = ".maxa/upload/sessionabc/f.txt"
vim.fn.mkdir(vim.fs.dirname(vim.fs.joinpath(vim.uv.cwd(), fallback_file)), "p")
vim.fn.writefile({ "x" }, vim.fs.joinpath(vim.uv.cwd(), fallback_file))
client.poll_cb(true, { request_id = "r4", session_id = "sessionabc", status = "completed", path = fallback_file }, {})
local fallback_lines = vim.api.nvim_buf_get_lines(bufnr5, 0, -1, false)
assert(fallback_lines[1] == "user changed this" and fallback_lines[2] == fallback_file)
vim.fn.delete(vim.fs.joinpath(vim.uv.cwd(), ".maxa/upload/sessionabc"), "rf")

-- Existing /upload is mutually exclusive and prevents Bridge creation.
local before_create = calls.create
local_upload_active = true
local bufnr6 = vim.api.nvim_create_buf(false, true)
assert(upload.start(make_chat(bufnr6)) == nil)
assert(calls.create == before_create)
local_upload_active = false

-- Realpath validation rejects symlinks outside the session and malformed shapes.
local outside = vim.fn.tempname()
vim.fn.writefile({ "outside" }, outside)
local symlink_session = vim.fs.joinpath(vim.uv.cwd(), ".maxa/upload/sessionlink")
vim.fn.mkdir(symlink_session, "p")
vim.uv.fs_symlink(outside, vim.fs.joinpath(symlink_session, "escape.txt"))
local validation_state = { request_id = "rv", session_id = "sessionlink", project_root = vim.uv.cwd() }
assert(upload._valid_result(validation_state, { request_id = "rv", session_id = "sessionlink", path = ".maxa/upload/sessionlink/escape.txt" }) == nil)
for _, bad in ipairs({
  ".maxa/upload/sessionlink/../escape.txt",
  ".maxa/upload/sessionlink/./escape.txt",
  ".maxa/upload/sessionlink/nested/escape.txt",
  ".maxa/upload/sessionlink/",
  ".maxa\\upload\\sessionlink\\escape.txt",
}) do
  assert(upload._valid_result(validation_state, { request_id = "rv", session_id = "sessionlink", path = bad }) == nil)
end
vim.fn.delete(symlink_session, "rf")
vim.fn.delete(outside)

-- Session directory redirects are rejected even when targets stay in-project.
for index, target in ipairs({ vim.uv.cwd(), vim.fs.joinpath(vim.uv.cwd(), ".maxa", "internal-upload-target") }) do
  local session_id = "redirectSession" .. index
  local session_path = vim.fs.joinpath(vim.uv.cwd(), ".maxa", "upload", session_id)
  vim.fn.mkdir(target, "p")
  vim.uv.fs_symlink(target, session_path)
  local target_file = vim.fs.joinpath(target, "redirected.txt")
  vim.fn.writefile({ "x" }, target_file)
  assert(upload._valid_result(
    { request_id = "redirect", session_id = session_id, project_root = vim.uv.cwd() },
    { request_id = "redirect", session_id = session_id, path = ".maxa/upload/" .. session_id .. "/redirected.txt" }
  ) == nil)
  vim.fn.delete(session_path)
  vim.fn.delete(target_file)
end
vim.fn.delete(vim.fs.joinpath(vim.uv.cwd(), ".maxa", "internal-upload-target"), "d")

-- A redirected upload root is also rejected.
local upload_root = vim.fs.joinpath(vim.uv.cwd(), ".maxa", "upload")
local upload_backup = upload_root .. "-test-backup"
vim.fn.rename(upload_root, upload_backup)
local redirected_root = vim.fs.joinpath(vim.uv.cwd(), ".maxa", "redirected-upload-root")
vim.fn.mkdir(redirected_root, "p")
vim.uv.fs_symlink(redirected_root, upload_root)
vim.fn.mkdir(vim.fs.joinpath(redirected_root, "rootSession"), "p")
vim.fn.writefile({ "x" }, vim.fs.joinpath(redirected_root, "rootSession", "file.txt"))
assert(upload._valid_result(
  { request_id = "root", session_id = "rootSession", project_root = vim.uv.cwd() },
  { request_id = "root", session_id = "rootSession", path = ".maxa/upload/rootSession/file.txt" }
) == nil)
vim.fn.delete(upload_root)
vim.fn.delete(redirected_root, "rf")
vim.fn.rename(upload_backup, upload_root)

-- Global exit cancellation covers every active Chat, not only current buffer.
local cancelled_ids = {}
client.cancel_chat_upload = function(request_id, _, cb) table.insert(cancelled_ids, request_id); if cb then cb(true, {}, {}) end end
local counter = 0
client.create_chat_upload = function(_, cb) counter = counter + 1; cb(true, { request_id = "exit" .. counter, session_id = "exitSession" .. counter, status = "pending" }, {}) end
local exit_buf1, exit_buf2 = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
upload.start(make_chat(exit_buf1)); upload.start(make_chat(exit_buf2))
upload._cancel_all()
table.sort(cancelled_ids)
assert(cancelled_ids[#cancelled_ids - 1] == "exit1" and cancelled_ids[#cancelled_ids] == "exit2")
assert(upload.active(exit_buf1) == nil and upload.active(exit_buf2) == nil)

print("telegram_upload init tests passed")
