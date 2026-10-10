-- filepath: lua/maxa/project/articles_test.lua
-- 运行方式: nvim --headless -l lua/maxa/project/articles_test.lua

local articles = require("maxa.project.articles")
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

local function assert_true(value, msg)
  if not value then
    error(msg or "expected true")
  end
end

local function assert_match(pattern, value, msg)
  if type(value) ~= "string" or not value:match(pattern) then
    error(string.format("%s: pattern %q not found in %q", msg or "assertion failed", pattern, tostring(value)))
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

local function item_by_rel(items, rel_path)
  for _, item in ipairs(items) do
    if item.rel_path == rel_path then
      return item
    end
  end
  return nil
end

print("\n=== Testing maxa_articles ===\n")

test("list_items should scan allowed roots and exclude indexes logs and non-markdown", function()
  local root = temp_root()
  write_file(root .. "/.maxa/reports/report-one.md", [[---
title: Report One
---
# Report Heading
]])
  write_file(root .. "/.maxa/ideas/index.md", "# Ideas Index\n")
  write_file(root .. "/.maxa/ideas/log.md", "# Ideas Log\n")
  write_file(root .. "/.maxa/ideas/kanban/index.md", "# Nested Index\n")
  write_file(root .. "/.maxa/ideas/kanban/01-architecture.md", "# Kanban Architecture\n")
  write_file(root .. "/.maxa/ideas/kanban/diagram.png", "not markdown")
  write_file(root .. "/.maxa/specs/ignored/spec.md", "# Not Article\n")

  local items = articles.list_items({ project_root = root })
  assert_true(item_by_rel(items, ".maxa/reports/report-one.md"), "report should be listed")
  assert_true(item_by_rel(items, ".maxa/ideas/kanban/01-architecture.md"), "nested idea should be listed")
  assert_equal(nil, item_by_rel(items, ".maxa/ideas/index.md"), "root index should be excluded")
  assert_equal(nil, item_by_rel(items, ".maxa/ideas/log.md"), "root log should be excluded")
  assert_equal(nil, item_by_rel(items, ".maxa/ideas/kanban/index.md"), "nested index should be excluded")
  assert_equal(nil, item_by_rel(items, ".maxa/specs/ignored/spec.md"), "spec root should not be scanned")

  vim.fn.delete(root, "rf")
end)

test("list_items should sort articles by most recent modification time across roots", function()
  local root = temp_root()
  local report_path = root .. "/.maxa/reports/report-one.md"
  local idea_path = root .. "/.maxa/ideas/idea-one.md"
  local rule_path = root .. "/.maxa/rules/rule-one.md"
  write_file(report_path, "# Report\n")
  write_file(idea_path, "# Idea\n")
  write_file(rule_path, "# Rule\n")
  set_mtime(report_path, 100)
  set_mtime(idea_path, 300)
  set_mtime(rule_path, 200)

  local items = articles.list_items({ project_root = root })
  assert_equal(".maxa/ideas/idea-one.md", items[1].rel_path, "newest article should be first")
  assert_equal(".maxa/rules/rule-one.md", items[2].rel_path, "middle mtime article")
  assert_equal(".maxa/reports/report-one.md", items[3].rel_path, "oldest article should be last")

  vim.fn.delete(root, "rf")
end)

test("nested ideas should keep IDEA badge and category-relative display path", function()
  local root = temp_root()
  write_file(root .. "/.maxa/ideas/kanban/01-architecture.md", "# Kanban Architecture\n")
  local items = articles.list_items({ project_root = root })
  local item = item_by_rel(items, ".maxa/ideas/kanban/01-architecture.md")
  assert_true(item, "nested idea should exist")
  assert_equal("[IDEA]", item.badge, "badge should remain top-level category")
  assert_equal("kanban/01-architecture.md", item.category_rel_path, "category relative path should include subdir")
  assert_equal("kanban/01-architecture", item.display_name, "display name should omit extension")
  assert_match("^%[IDEA%] kanban/01%-architecture", articles.format_entry(item), "row should show stable badge and nested display")
  vim.fn.delete(root, "rf")
end)

test("title should prefer frontmatter then heading then display name", function()
  local root = temp_root()
  write_file(root .. "/.maxa/rules/frontmatter.md", [[---
title: Frontmatter Title
---
# Heading Title
]])
  write_file(root .. "/.maxa/research/heading.md", "# Heading Title\nBody\n")
  write_file(root .. "/.maxa/research/no-title.md", "Body only\n")
  local items = articles.list_items({ project_root = root })
  assert_equal("Frontmatter Title", item_by_rel(items, ".maxa/rules/frontmatter.md").title, "frontmatter title")
  assert_equal("Heading Title", item_by_rel(items, ".maxa/research/heading.md").title, "heading title")
  assert_equal("no-title", item_by_rel(items, ".maxa/research/no-title.md").title, "display fallback")
  vim.fn.delete(root, "rf")
end)

test("preview_lines should include metadata and fallback for empty files", function()
  local root = temp_root()
  write_file(root .. "/.maxa/research/empty.md", "")
  local item = item_by_rel(articles.list_items({ project_root = root }), ".maxa/research/empty.md")
  local preview = table.concat(articles.preview_lines(item), "\n")
  assert_match("category: research", preview, "category metadata")
  assert_match("path: %.maxa/research/empty%.md", preview, "path metadata")
  assert_match("%(empty article%)", preview, "empty fallback")
  vim.fn.delete(root, "rf")
end)

test("missing roots should return no items and not create directories", function()
  local root = temp_root()
  local items = articles.list_items({ project_root = root })
  assert_equal(0, #items, "missing roots should return empty list")
  assert_equal(false, vim.uv.fs_stat(root .. "/.maxa/ideas") ~= nil, "missing roots should not be created")
  vim.fn.delete(root, "rf")
end)

print(string.format("\nResults: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
