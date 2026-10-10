-- filepath: lua/maxa/session/tools/transfer_chat_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/tools/transfer_chat_test.lua

package.preload["plenary.path"] = package.preload["plenary.path"] or function()
  local Path = {}
  Path.__index = Path
  function Path:new(path)
    return setmetatable({ path = path }, self)
  end
  setmetatable(Path, { __call = function(cls, path) return cls:new(path) end })
  function Path:exists()
    return vim.fn.filereadable(self.path) == 1 or vim.fn.isdirectory(self.path) == 1
  end
  function Path:parent()
    return Path:new(vim.fn.fnamemodify(self.path, ":h"))
  end
  function Path:mkdir(opts)
    vim.fn.mkdir(self.path, opts and opts.parents and "p" or "")
  end
  function Path:read()
    return table.concat(vim.fn.readfile(self.path), "\n")
  end
  function Path:write(content, _)
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), self.path)
    return true
  end
  function Path:rm()
    vim.fn.delete(self.path)
  end
  return Path
end

local utils = require("maxa.session.history.utils")
local history_core = require("maxa.session.history_core")
local transfer_tool = require("maxa.session.tools.transfer_chat")

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

local function assert_true(value, msg)
  if not value then
    error(msg or "expected true")
  end
end

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local function fake_res()
  local state = { text_body = nil, error_msg = nil }
  local res = {}
  function res:error(msg)
    state.error_msg = msg
    return msg
  end
  function res:text(body)
    state.text_body = body
    return {
      send = function()
        return body
      end,
    }
  end
  return res, state
end

local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, "p")

local function project(name)
  local root = tmp_root .. "/" .. name
  vim.fn.mkdir(root .. "/.maxa/history/chats", "p")
  utils.write_json(root .. "/.maxa/history/index.json", vim.empty_dict())
  return root, root .. "/.maxa/history"
end

local function seed(history_dir, project_root, save_id)
  local chat = {
    save_id = save_id,
    title = "MCP Source",
    messages = { { role = "user", content = "secret body must not be returned" } },
    settings = { model = "m" },
    adapter = "a",
    updated_at = 1,
    cwd = project_root,
    project_root = project_root,
  }
  utils.write_json(history_dir .. "/chats/" .. save_id .. ".json", chat)
  utils.write_json(history_dir .. "/index.json", {
    [save_id] = {
      save_id = save_id,
      title = chat.title,
      updated_at = chat.updated_at,
      model = "m",
      adapter = "a",
      message_count = 1,
      token_estimate = 8,
      cwd = project_root,
      project_root = project_root,
    },
  })
end

print("\n=== Testing session transfer tools ===\n")

test("transfer_chat copy returns metadata only and leaves source", function()
  local source_root, source_history = project("source-copy-tool")
  local target_root = project("target-copy-tool")
  seed(source_history, source_root, "copy_tool_source")

  local original_get_history_dir = history_core.get_history_dir
  history_core.get_history_dir = function()
    return source_history
  end

  local res, state = fake_res()
  transfer_tool.handler({ params = { mode = "copy", save_id = "copy_tool_source", target_project_root = target_root } }, res)
  history_core.get_history_dir = original_get_history_dir

  assert_equal(nil, state.error_msg, "tool should not error")
  local decoded = vim.json.decode(state.text_body)
  assert_equal("copy", decoded.data.mode, "mode")
  assert_true(decoded.data.target_save_id ~= "copy_tool_source", "target save_id should be fresh")
  assert_equal(nil, decoded.data.messages, "response should not include messages")
  assert_true(vim.fn.filereadable(source_history .. "/chats/copy_tool_source.json") == 1, "source remains")
end)

test("transfer_chat move deletes source after target success", function()
  local source_root, source_history = project("source-move-tool")
  local target_root = project("target-move-tool")
  seed(source_history, source_root, "move_tool_source")

  local original_get_history_dir = history_core.get_history_dir
  history_core.get_history_dir = function()
    return source_history
  end

  local res, state = fake_res()
  transfer_tool.handler({ params = { mode = "move", save_id = "move_tool_source", target_project_root = target_root } }, res)
  history_core.get_history_dir = original_get_history_dir

  assert_equal(nil, state.error_msg, "tool should not error")
  local decoded = vim.json.decode(state.text_body)
  assert_equal("move", decoded.data.mode, "mode")
  assert_equal(true, decoded.data.source_deleted, "source_deleted")
  assert_true(vim.fn.filereadable(source_history .. "/chats/move_tool_source.json") == 0, "source deleted")
end)

test("transfer_chat validates target_project_root", function()
  local source_root, source_history = project("source-invalid-tool")
  seed(source_history, source_root, "invalid_tool_source")

  local original_get_history_dir = history_core.get_history_dir
  history_core.get_history_dir = function()
    return source_history
  end

  local res, state = fake_res()
  transfer_tool.handler({ params = { mode = "copy", save_id = "invalid_tool_source" } }, res)
  history_core.get_history_dir = original_get_history_dir

  assert_true(state.error_msg and state.error_msg:match("target_project_root is required"), "missing target should error")
end)

vim.fn.delete(tmp_root, "rf")

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
