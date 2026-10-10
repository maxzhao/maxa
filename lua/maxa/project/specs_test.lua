-- filepath: lua/maxa/project/specs_test.lua
-- 运行方式: nvim --headless -l lua/maxa/project/specs_test.lua

local specs = require("maxa.project.specs")
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

print("\n=== Testing maxa_specs ===\n")

test("parse_frontmatter should parse scalar and block list fields", function()
  local fm, body = specs.parse_frontmatter([[---
title: Example Spec
status: accepted
merged_to:
  - .maxa/specs/example/spec.md
  - .maxa/specs/other/spec.md
---
# Body
]])
  assert_equal("Example Spec", fm.title, "title should parse")
  assert_equal("accepted", fm.status, "status should parse")
  assert_equal(".maxa/specs/example/spec.md", fm.merged_to[1], "first list value should parse")
  assert_match("# Body", body, "body should be returned")
end)

test("list_items should discover stable specs, changes, and delta specs", function()
  local root = temp_root()
  write_file(root .. "/.maxa/specs/example/spec.md", [[---
title: Example Stable Spec
doc_role: spec
status: experimental
---
# Stable
]])
  write_file(root .. "/.maxa/specs/index.md", [[---
title: Index
---
]])
  write_file(root .. "/.maxa/specs/changes/add-example/proposal.md", [[---
title: Add Example Proposal
status: draft
change_id: add-example
---
# Proposal
]])
  write_file(root .. "/.maxa/specs/changes/add-example/specs/example/spec.md", [[---
title: Add Example Delta
status: draft
change_id: add-example
capability: example
---
# Delta
]])

  local items = specs.list_items({ project_root = root })
  assert_true(item_by_rel(items, ".maxa/specs/example/spec.md"), "stable spec should be listed")
  assert_true(item_by_rel(items, ".maxa/specs/changes/add-example/proposal.md"), "change proposal should be listed")
  assert_true(item_by_rel(items, ".maxa/specs/changes/add-example/specs/example/spec.md"), "delta spec should be listed")
  assert_equal(nil, item_by_rel(items, ".maxa/specs/index.md"), "index should not be listed")

  local change = item_by_rel(items, ".maxa/specs/changes/add-example/proposal.md")
  assert_equal("change", change.kind, "proposal kind")
  assert_equal("draft", change.status, "proposal status")
  assert_equal("add-example", change.change_id, "proposal change id")

  local delta = item_by_rel(items, ".maxa/specs/changes/add-example/specs/example/spec.md")
  assert_equal("delta_spec", delta.kind, "delta kind")
  assert_equal("example", delta.capability, "delta capability")

  vim.fn.delete(root, "rf")
end)

test("list_items should sort by most recent modification time", function()
  local root = temp_root()
  local stable_path = root .. "/.maxa/specs/example/spec.md"
  local change_path = root .. "/.maxa/specs/changes/add-example/proposal.md"
  local delta_path = root .. "/.maxa/specs/changes/add-example/specs/example/spec.md"
  write_file(stable_path, [[---
title: Example Stable Spec
doc_role: spec
---
# Stable
]])
  write_file(change_path, [[---
title: Add Example Proposal
status: draft
change_id: add-example
---
# Proposal
]])
  write_file(delta_path, [[---
title: Add Example Delta
status: draft
change_id: add-example
capability: example
---
# Delta
]])
  set_mtime(stable_path, 100)
  set_mtime(change_path, 300)
  set_mtime(delta_path, 200)

  local items = specs.list_items({ project_root = root })
  assert_equal(".maxa/specs/changes/add-example/proposal.md", items[1].rel_path, "newest item should be first")
  assert_equal(".maxa/specs/changes/add-example/specs/example/spec.md", items[2].rel_path, "middle mtime item")
  assert_equal(".maxa/specs/example/spec.md", items[3].rel_path, "oldest item should be last")

  vim.fn.delete(root, "rf")
end)

test("format_entry should show stable spec lifecycle status", function()
  local root = temp_root()
  write_file(root .. "/.maxa/specs/experimental/spec.md", [[---
title: Experimental Spec
doc_role: spec
status: experimental
---
# Experimental
]])
  write_file(root .. "/.maxa/specs/missing-status/spec.md", [[---
title: Missing Status Spec
doc_role: spec
---
# Missing
]])

  local items = specs.list_items({ project_root = root })
  local experimental = item_by_rel(items, ".maxa/specs/experimental/spec.md")
  local missing = item_by_rel(items, ".maxa/specs/missing-status/spec.md")
  assert_match("^%[SPEC experimental%] Experimental Spec", specs.format_entry(experimental), "explicit status")
  assert_match("^%[SPEC unknown%] Missing Status Spec", specs.format_entry(missing), "missing status fallback")

  vim.fn.delete(root, "rf")
end)

test("preview_lines should show lifecycle guidance for accepted and superseded changes", function()
  local root = temp_root()
  local accepted_path = root .. "/.maxa/specs/changes/accepted/proposal.md"
  write_file(accepted_path, [[---
title: Accepted Change
status: accepted
change_id: accepted
merged_to:
  - .maxa/specs/current/spec.md
---
# Accepted
]])
  local superseded_path = root .. "/.maxa/specs/changes/old/proposal.md"
  write_file(superseded_path, [[---
title: Old Change
status: superseded
change_id: old
superseded_by: .maxa/specs/changes/new/proposal.md
---
# Old
]])

  local items = specs.list_items({ project_root = root })
  local accepted = item_by_rel(items, ".maxa/specs/changes/accepted/proposal.md")
  local superseded = item_by_rel(items, ".maxa/specs/changes/old/proposal.md")
  local accepted_preview = table.concat(specs.preview_lines(accepted), "\n")
  local superseded_preview = table.concat(specs.preview_lines(superseded), "\n")

  assert_match("merged_to", accepted_preview, "accepted merge target field")
  assert_match("%.maxa/specs/current/spec%.md", accepted_preview, "merged_to path")
  assert_match("superseded_by", superseded_preview, "superseded replacement field")
  assert_match("%.maxa/specs/changes/new/proposal%.md", superseded_preview, "superseded_by path")

  vim.fn.delete(root, "rf")
end)

test("missing specs root should return no items and not create directories", function()
  local root = temp_root()
  local items = specs.list_items({ project_root = root })
  assert_equal(0, #items, "missing root should return empty list")
  assert_equal(false, vim.uv.fs_stat(root .. "/.maxa/specs") ~= nil, "missing root should not be created")
  vim.fn.delete(root, "rf")
end)

print(string.format("\nResults: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
