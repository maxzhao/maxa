-- filepath: lua/maxa/project/drafts_test.lua
-- 运行方式: nvim --headless -l lua/maxa/project/drafts_test.lua

local drafts = require("maxa.project.drafts")
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
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function temp_root()
  local path = vim.fn.tempname()
  vim.fn.delete(path, "rf")
  vim.fn.mkdir(path, "p")
  return path
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
end

local function set_mtime(path, timestamp)
  local ok, err = vim.uv.fs_utime(path, timestamp, timestamp)
  if not ok then
    error("failed to set mtime for " .. path .. ": " .. tostring(err))
  end
end

print("\n=== Testing maxa_drafts ===\n")

test("list_files should sort drafts by most recent modification time", function()
  local root = temp_root()
  local old_path = root .. "/.maxa/drafts/old.md"
  local newest_path = root .. "/.maxa/drafts/newest.md"
  local middle_path = root .. "/.maxa/drafts/nested/middle.md"
  write_file(old_path, "old\n")
  write_file(newest_path, "newest\n")
  write_file(middle_path, "middle\n")
  set_mtime(old_path, 100)
  set_mtime(newest_path, 300)
  set_mtime(middle_path, 200)

  local items = drafts.list_files({ project_root = root })
  assert_equal(".maxa/drafts/newest.md", items[1].rel_path, "newest draft should be first")
  assert_equal(".maxa/drafts/nested/middle.md", items[2].rel_path, "middle mtime draft")
  assert_equal(".maxa/drafts/old.md", items[3].rel_path, "oldest draft should be last")
  assert_equal(
    ".maxa/drafts/newest.md",
    drafts.latest_file({ project_root = root }).rel_path,
    "latest_file should return newest draft"
  )

  vim.fn.delete(root, "rf")
end)

print(string.format("\nResults: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
