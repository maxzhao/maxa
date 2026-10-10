local utils = require("maxa.session.history.utils")
local project_registry = require("maxa.session.history.project_registry")

local M = {}

local function now()
    return os.time()
end

local function empty_index()
    return vim.empty_dict and vim.empty_dict() or {}
end

local function normalize_project_root(project_root)
    return project_registry.normalize_project_root(project_root)
end

local function history_dir_for_project(project_root)
    return project_root .. "/.maxa/history"
end

local function ensure_history_dir(history_dir)
    local ok_base = vim.fn.mkdir(history_dir, "p")
    local ok_chats = vim.fn.mkdir(history_dir .. "/chats", "p")
    if ok_base == 0 or ok_chats == 0 then
        -- mkdir() returns 0 when directory already exists on some Vim builds;
        -- verify actual directories instead of trusting the return value.
    end
    if vim.fn.isdirectory(history_dir) ~= 1 then
        return false, "failed to create history directory: " .. history_dir
    end
    if vim.fn.isdirectory(history_dir .. "/chats") ~= 1 then
        return false, "failed to create chats directory: " .. history_dir .. "/chats"
    end
    local index_path = history_dir .. "/index.json"
    if vim.fn.filereadable(index_path) == 0 then
        local result = utils.write_json(index_path, empty_index())
        if not result.ok then
            return false, result.error
        end
    end
    return true, nil
end

---@param project_root string
---@param opts? {create?: boolean}
---@return {project_root:string, history_dir:string, index_path:string, chats_dir:string}|nil
---@return string? err
function M.resolve_project_history(project_root, opts)
    opts = opts or {}
    local root, err = normalize_project_root(project_root)
    if not root then
        return nil, err
    end
    if vim.fn.isdirectory(root) ~= 1 then
        return nil, "target project root does not exist: " .. root
    end
    if vim.fn.isdirectory(root .. "/.maxa") ~= 1 then
        return nil, "target project root is not a Maxa project: " .. root
    end

    local history_dir = history_dir_for_project(root)
    if opts.create then
        local ok, ensure_err = ensure_history_dir(history_dir)
        if not ok then
            return nil, ensure_err
        end
    elseif vim.fn.isdirectory(history_dir) ~= 1 then
        return nil, "history directory does not exist: " .. history_dir
    end

    return {
        project_root = root,
        history_dir = history_dir,
        index_path = history_dir .. "/index.json",
        chats_dir = history_dir .. "/chats",
    }, nil
end

---@param history_dir string
---@return {project_root:string, history_dir:string, index_path:string, chats_dir:string}|nil
---@return string? err
function M.resolve_history_dir(history_dir)
    if type(history_dir) ~= "string" or history_dir == "" then
        return nil, "history_dir must be a non-empty string"
    end
    local normalized = vim.fn.fnamemodify(vim.fn.expand(history_dir), ":p"):gsub("/+$", "")
    if vim.fs and vim.fs.normalize then
        normalized = vim.fs.normalize(normalized):gsub("/+$", "")
    end
    local project_root = normalized:match("^(.*)/%.maxa/history$")
    if not project_root or project_root == "" then
        return nil, "history_dir is not a project .maxa/history directory: " .. normalized
    end
    local resolved, err = M.resolve_project_history(project_root, { create = true })
    if not resolved then
        return nil, err
    end
    return resolved, nil
end

local function safe_read_index(index_path)
    local result = utils.read_json(index_path)
    if not result.ok then
        return nil, result.error
    end
    if type(result.data) ~= "table" then
        return nil, "index JSON must decode to an object"
    end
    return result.data, nil
end

local function write_index(index_path, index)
    return utils.write_json(index_path, utils.remove_functions(index))
end

local function update_index_entry(index_path, chat_data)
    local index, err = safe_read_index(index_path)
    if not index then
        return { ok = false, error = err }
    end

    local message_count = #(chat_data.messages or {})
    local total_chars = 0
    for _, msg in ipairs(chat_data.messages or {}) do
        if type(msg.content) == "string" then
            total_chars = total_chars + #msg.content
        end
    end

    index[chat_data.save_id] = {
        save_id = chat_data.save_id,
        title = chat_data.title,
        updated_at = chat_data.updated_at,
        model = chat_data.settings and chat_data.settings.model or "unknown",
        adapter = chat_data.adapter or "unknown",
        message_count = message_count,
        token_estimate = math.floor(total_chars / 4),
        cwd = chat_data.cwd,
        project_root = chat_data.project_root,
        compact_protected_prefix_count = chat_data.compact_protected_prefix_count or 0,
        agent = require("maxa.session.agent_identity").index_fields(chat_data).agent,
        last_dialogue_at = chat_data._meta and chat_data._meta.last_dialogue_at,
        session_trace = chat_data._meta and chat_data._meta.session_trace,
    }

    return write_index(index_path, index)
end

local function delete_from_history(history, save_id)
    local delete_result = utils.delete_file(history.chats_dir .. "/" .. save_id .. ".json")
    if not delete_result.ok then
        return false, delete_result.error
    end
    local index, err = safe_read_index(history.index_path)
    if not index then
        return false, err
    end
    index[save_id] = nil
    local write_result = write_index(history.index_path, index)
    if not write_result.ok then
        return false, write_result.error
    end
    return true, nil
end

local function load_chat(history, save_id)
    if type(save_id) ~= "string" or save_id == "" then
        return nil, "save_id is required"
    end
    if save_id:match("[/\\]") then
        return nil, "save_id contains invalid path characters"
    end
    local result = utils.read_json(history.chats_dir .. "/" .. save_id .. ".json")
    if not result.ok then
        return nil, result.error
    end
    if type(result.data) ~= "table" then
        return nil, "chat JSON must decode to an object"
    end
    return result.data, nil
end

local function write_chat(history, chat_data)
    return utils.write_json(history.chats_dir .. "/" .. chat_data.save_id .. ".json", utils.remove_functions(chat_data))
end

local function prepare_target_chat(source_chat, opts)
    local transferred_at = now()
    local target_save_id = utils.generate_save_id({ history_dir = opts.target.history_dir })
    local target_chat = vim.deepcopy(source_chat)
    target_chat.save_id = target_save_id
    target_chat.updated_at = transferred_at
    target_chat.cwd = opts.target.project_root
    target_chat.project_root = opts.target.project_root
    local identity = require("maxa.session.agent_identity")
    if identity.history(target_chat).kind == "main" then
        identity.reidentify(target_chat, true)
    else
        target_chat._meta = target_chat._meta or {}
        target_chat._meta.agent = { kind = "subagent" }
    end
    if opts.title and opts.title ~= "" then
        target_chat.title = opts.title
    end
    target_chat.transfer = {
        mode = opts.mode,
        source_project_root = opts.source.project_root,
        source_history_dir = opts.source.history_dir,
        source_save_id = opts.source_save_id,
        source_cwd = source_chat.cwd,
        transferred_at = transferred_at,
    }
    return target_chat
end

---@param opts {mode:string, source_history_dir:string, source_save_id:string, target_project_root:string, title?:string}
---@return table|nil result
---@return string? err
function M.transfer_chat(opts)
    opts = opts or {}
    local mode = opts.mode
    if mode ~= "copy" and mode ~= "move" then
        return nil, "mode must be copy or move"
    end

    local source, err = M.resolve_history_dir(opts.source_history_dir)
    if not source then
        return nil, err
    end
    local target, target_err = M.resolve_project_history(opts.target_project_root, { create = true })
    if not target then
        return nil, target_err
    end

    local source_chat, load_err = load_chat(source, opts.source_save_id)
    if not source_chat then
        return nil, "failed to load source chat: " .. (load_err or "unknown error")
    end

    local target_chat = prepare_target_chat(source_chat, {
        mode = mode,
        source = source,
        source_save_id = opts.source_save_id,
        target = target,
        title = opts.title,
    })

    local target_chat_path = target.chats_dir .. "/" .. target_chat.save_id .. ".json"
    local save_result = write_chat(target, target_chat)
    if not save_result.ok then
        return nil, "failed to write target chat: " .. (save_result.error or "unknown error")
    end

    local index_result = update_index_entry(target.index_path, target_chat)
    if not index_result.ok then
        utils.delete_file(target_chat_path)
        return nil, "failed to update target index: " .. (index_result.error or "unknown error")
    end

    local source_deleted = false
    if mode == "move" then
        local ok_delete, delete_err = delete_from_history(source, opts.source_save_id)
        if not ok_delete then
            return nil, "target written but failed to delete source: " .. (delete_err or "unknown error")
        end
        source_deleted = true
    end

    pcall(project_registry.record, source.project_root)
    pcall(project_registry.record, target.project_root)

    return {
        mode = mode,
        source_project_root = source.project_root,
        source_history_dir = source.history_dir,
        source_save_id = opts.source_save_id,
        source_deleted = source_deleted,
        target_project_root = target.project_root,
        target_history_dir = target.history_dir,
        target_save_id = target_chat.save_id,
        target_chat_path = target_chat_path,
        title = target_chat.title,
        transferred_at = target_chat.transfer.transferred_at,
    }, nil
end

function M.copy_chat(opts)
    opts = opts or {}
    opts.mode = "copy"
    return M.transfer_chat(opts)
end

function M.move_chat(opts)
    opts = opts or {}
    opts.mode = "move"
    return M.transfer_chat(opts)
end

return M
