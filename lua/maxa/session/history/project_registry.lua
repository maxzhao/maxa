local utils = require("maxa.session.history.utils")

local M = {}

local function registry_path()
    return vim.fn.stdpath("data") .. "/maxa/known-projects.json"
end

local function normalize_project_root(project_root)
    if type(project_root) ~= "string" or vim.trim(project_root) == "" then
        return nil, "project_root must be a non-empty string"
    end
    if project_root:match("^%w+://") then
        return nil, "project_root must be a local filesystem path"
    end

    local expanded = vim.fn.expand(project_root)
    local absolute = vim.fn.fnamemodify(expanded, ":p")
    if type(absolute) ~= "string" or absolute == "" then
        return nil, "failed to normalize project_root"
    end
    absolute = absolute:gsub("/+$", "")
    if vim.fs and vim.fs.normalize then
        absolute = vim.fs.normalize(absolute):gsub("/+$", "")
    end
    return absolute
end

function M.normalize_project_root(project_root)
    return normalize_project_root(project_root)
end

local function read_registry()
    local path = registry_path()
    if vim.fn.filereadable(path) == 0 then
        return { projects = {} }
    end
    local result = utils.read_json(path)
    if not result.ok or type(result.data) ~= "table" then
        return { projects = {} }
    end
    if type(result.data.projects) ~= "table" then
        result.data.projects = {}
    end
    return result.data
end

local function write_registry(data)
    data.updated_at = os.time()
    return utils.write_json(registry_path(), data)
end

---@param project_root string
---@return boolean ok
---@return string? err
function M.record(project_root)
    local root, err = normalize_project_root(project_root)
    if not root then
        return false, err
    end
    if vim.fn.isdirectory(root) ~= 1 then
        return false, "project_root does not exist: " .. root
    end
    if vim.fn.isdirectory(root .. "/.maxa") ~= 1 then
        return false, "project_root is not a Maxa project: " .. root
    end

    local data = read_registry()
    local projects = data.projects or {}
    local entry = projects[root] or { root = root, first_seen = os.time() }
    entry.root = root
    entry.last_seen = os.time()
    entry.seen_count = (entry.seen_count or 0) + 1
    projects[root] = entry
    data.projects = projects
    local result = write_registry(data)
    if not result.ok then
        return false, result.error
    end
    return true, nil
end

---@param opts? {exclude?: string|string[]}
---@return table[] projects
function M.list(opts)
    opts = opts or {}
    local exclude = {}
    if type(opts.exclude) == "string" then
        local root = normalize_project_root(opts.exclude)
        if root then
            exclude[root] = true
        end
    elseif type(opts.exclude) == "table" then
        for _, item in ipairs(opts.exclude) do
            local root = normalize_project_root(item)
            if root then
                exclude[root] = true
            end
        end
    end

    local data = read_registry()
    local items = {}
    for root, entry in pairs(data.projects or {}) do
        local normalized = normalize_project_root(entry.root or root)
        if normalized and not exclude[normalized] and vim.fn.isdirectory(normalized .. "/.maxa") == 1 then
            table.insert(items, {
                root = normalized,
                last_seen = entry.last_seen or 0,
                first_seen = entry.first_seen or entry.last_seen or 0,
                seen_count = entry.seen_count or 1,
            })
        end
    end
    table.sort(items, function(a, b)
        return (a.last_seen or 0) > (b.last_seen or 0)
    end)
    return items
end

function M.path()
    return registry_path()
end

return M
