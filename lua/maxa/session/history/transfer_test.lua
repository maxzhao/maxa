-- filepath: lua/maxa/session/history/transfer_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/history/transfer_test.lua

package.preload["plenary.path"] = package.preload["plenary.path"] or function()
    local Path = {}
    Path.__index = Path

    function Path:new(path)
        return setmetatable({ path = path }, self)
    end

    setmetatable(Path, {
        __call = function(cls, path)
            return cls:new(path)
        end,
    })

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
        local lines = vim.fn.readfile(self.path)
        return table.concat(lines, "\n")
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

local transfer = require("maxa.session.history.transfer")
local utils = require("maxa.session.history.utils")

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

local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, "p")

local function project(name, with_maxa)
    local root = tmp_root .. "/" .. name
    vim.fn.mkdir(root, "p")
    if with_maxa ~= false then
        vim.fn.mkdir(root .. "/.maxa", "p")
    end
    return root
end

local function make_history(root)
    local history = root .. "/.maxa/history"
    vim.fn.mkdir(history .. "/chats", "p")
    utils.write_json(history .. "/index.json", vim.empty_dict())
    return history
end

local function seed_chat(root, save_id)
    local history = make_history(root)
    local chat = {
        save_id = save_id,
        title = "Source Chat",
        messages = {
            { role = "user", content = "hello" },
            { role = "llm", content = "world" },
        },
        settings = { model = "test-model" },
        adapter = "test-adapter",
        updated_at = 100,
        context_items = { { id = "ctx" } },
        schemas = {},
        in_use = {},
        cycle = 1,
        title_refresh_count = 2,
        compact_protected_prefix_count = 1,
        cwd = root,
        project_root = root,
    }
    utils.write_json(history .. "/chats/" .. save_id .. ".json", chat)
    utils.write_json(history .. "/index.json", {
        [save_id] = {
            save_id = save_id,
            title = chat.title,
            updated_at = chat.updated_at,
            model = "test-model",
            adapter = "test-adapter",
            message_count = 2,
            token_estimate = 2,
            cwd = root,
            project_root = root,
            compact_protected_prefix_count = 1,
        },
    })
    return history, chat
end

print("\n=== Testing cross-project chat transfer ===\n")

test("copy creates target history, new save_id, metadata, and keeps source", function()
    local source_root = project("source-copy")
    local target_root = project("target-copy")
    local source_history = seed_chat(source_root, "source_save")

    local result, err = transfer.copy_chat({
        source_history_dir = source_history,
        source_save_id = "source_save",
        target_project_root = target_root,
    })

    assert_true(result ~= nil, err)
    assert_equal("copy", result.mode, "mode")
    assert_true(result.target_save_id ~= "source_save", "target save_id should be fresh")
    assert_true(vim.fn.filereadable(source_history .. "/chats/source_save.json") == 1, "source chat should remain")
    assert_true(vim.fn.filereadable(result.target_chat_path) == 1, "target chat should be written")

    local target_chat = assert(utils.read_json(result.target_chat_path).data)
    assert_equal(result.target_save_id, target_chat.save_id, "target chat save_id")
    assert_equal(target_root, target_chat.project_root, "target project_root")
    assert_equal(source_root, target_chat.transfer.source_project_root, "transfer source root")
    assert_equal("source_save", target_chat.transfer.source_save_id, "transfer source save_id")

    local target_index = assert(utils.read_json(target_root .. "/.maxa/history/index.json").data)
    assert_true(target_index[result.target_save_id] ~= nil, "target index should contain new chat")
end)

test("move deletes source only after target success", function()
    local source_root = project("source-move")
    local target_root = project("target-move")
    local source_history = seed_chat(source_root, "source_move")

    local result, err = transfer.move_chat({
        source_history_dir = source_history,
        source_save_id = "source_move",
        target_project_root = target_root,
    })

    assert_true(result ~= nil, err)
    assert_equal(true, result.source_deleted, "source_deleted")
    assert_true(vim.fn.filereadable(source_history .. "/chats/source_move.json") == 0, "source file should be deleted")
    local source_index = assert(utils.read_json(source_history .. "/index.json").data)
    assert_equal(nil, source_index.source_move, "source index entry should be removed")
    assert_true(vim.fn.filereadable(result.target_chat_path) == 1, "target chat should exist")
end)

test("invalid target is rejected before source deletion", function()
    local source_root = project("source-invalid")
    local target_root = project("target-invalid", false)
    local source_history = seed_chat(source_root, "source_invalid")

    local result, err = transfer.move_chat({
        source_history_dir = source_history,
        source_save_id = "source_invalid",
        target_project_root = target_root,
    })

    assert_equal(nil, result, "result should be nil")
    assert_true(tostring(err):match("not a Maxa project") ~= nil, "error should mention Maxa project")
    assert_true(vim.fn.filereadable(source_history .. "/chats/source_invalid.json") == 1, "source should remain")
end)

vim.fn.delete(tmp_root, "rf")

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
    os.exit(1)
else
    os.exit(0)
end
