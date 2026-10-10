-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/delete_items_test.lua
-- 单元测试: builtin_delete.lua 删除目录时必须真正删除，而不是静默误报成功
-- 运行方式: nvim --headless -l lua/maxa/interactions/chat/tools/builtin/tests/delete_items_test.lua

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('✓ ' .. name)
  else
    failed = failed + 1
    print('✗ ' .. name)
    print('  Error: ' .. tostring(err))
  end
end

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format('%s: expected %s, got %s', msg or 'assertion failed', tostring(expected), tostring(actual)))
  end
end

local function assert_false(value, msg)
  if value then
    error((msg or 'assertion failed') .. ': expected false, got true')
  end
end

local plenary_root = vim.fn.stdpath('data') .. '/lazy/plenary.nvim'
vim.opt.runtimepath:prepend(plenary_root)
package.path = table.concat({
  plenary_root .. '/lua/?.lua',
  plenary_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local tool = dofile(vim.fn.stdpath('config') .. '/lua/maxa/interactions/chat/tools/builtin/tools/builtin_delete.lua')

local function make_res(captured)
  return {
    error = function(_, msg)
      captured.kind = 'error'
      captured.msg = msg
      return captured
    end,
    text = function(_, msg)
      captured.kind = 'text'
      captured.msg = msg
      return {
        send = function()
          return captured
        end,
      }
    end,
  }
end

print('\n=== Testing mcpx delete_items ===\n')

test('should recursively delete directory and report success', function()
  local base = '/tmp/smx_delete_items_test_dir'
  vim.fn.delete(base, 'rf')
  vim.fn.mkdir(base .. '/sub', 'p')
  vim.fn.writefile({ 'x' }, base .. '/sub/a.txt')

  local captured = {}
  local out = tool.run({ params = { paths = { base } } }, make_res(captured))

  assert_equal('text', out.kind, 'handler should return success response')
  assert_false(vim.loop.fs_stat(base) ~= nil, 'directory should be deleted')
end)

test('should report error when path still does not exist', function()
  local missing = '/tmp/smx_delete_items_missing'
  vim.fn.delete(missing, 'rf')

  local captured = {}
  local out = tool.run({ params = { paths = { missing } } }, make_res(captured))

  assert_equal('error', out.kind, 'handler should return error response')
end)

print(string.format('\n=== Results: %d passed, %d failed ===\n', passed, failed))

if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
