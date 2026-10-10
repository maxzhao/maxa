local config = require("maxa.config")
local markdown = require("maxa.prompts.markdown")

local M = {}
local catalogs = {}
local global_root = assert(require("maxa.version").runtime_root, "runtime-root-unavailable")

function M.project_root(context)
  context = context or {}
  local chat
  local runtime = package.loaded["maxa"]
  if context.bufnr and runtime and runtime.buf_get_chat then
    chat = runtime.buf_get_chat(context.bufnr)
  end
  local root = chat and chat.opts and (chat.opts.project_root or chat.opts.cwd)
    or context.project_root
    or context.cwd
    or vim.fn.getcwd()
  return vim.fs.normalize(vim.uv.fs_realpath(root) or root)
end

local function reserved_names()
  local reserved = {}
  for name in pairs(config.interactions.chat.slash_commands) do
    if name ~= "opts" then reserved[name:lower()] = true end
  end
  return reserved
end

local function warn(message)
  vim.notify("[Prompt Library] " .. message, vim.log.levels.WARN)
end

local function build(root, context)
  local candidates = {}
  local function add(prompt, rank)
    local name = prompt.name
    if type(name) ~= "string" or name == "" then return end
    prompt.source_priority = rank
    prompt.command_name = prompt.ability and (prompt.ability .. ":" .. name) or name
    local key = prompt.command_name:lower()
    local group = candidates[key]
    if not group or rank < group.rank then
      candidates[key] = { rank = rank, prompts = { prompt } }
    elseif rank == group.rank then
      group.prompts[#group.prompts + 1] = prompt
    end
  end

  for _, source in ipairs({
    { dir = vim.fs.joinpath(root, ".maxa", "prompts"), rank = 1 },
    { dir = vim.fs.joinpath(global_root, "prompts", "commands"), rank = 3 },
  }) do
    for _, prompt in ipairs(markdown.load_from_dir(source.dir, context)) do add(prompt, source.rank) end
  end

  local ability_catalog = require("maxa.abilities.catalog")
  local ok, discovered, err = pcall(ability_catalog.list, root, {
    global_root = vim.fs.joinpath(global_root, "abilities"), catalog_files = false,
  })
  if not ok or not discovered then
    warn("Could not discover Ability prompts: " .. tostring(ok and err or discovered))
  else
    for _, ability in ipairs(discovered.abilities) do
      if ability.enabled ~= false and ability.prompts then
        local names = {}
        for _, layer in ipairs(ability.layers) do
          local dir = vim.fs.joinpath(layer.root, "prompts")
          local owner = vim.uv.fs_lstat(dir)
          local resolved = owner and vim.uv.fs_realpath(dir)
          local stat = resolved and vim.uv.fs_stat(resolved)
          if stat and stat.type == "directory" and resolved:sub(1, #layer.root + 1) == layer.root .. "/" then
            local scan = vim.uv.fs_scandir(resolved)
            if scan then
              while true do
                local name = vim.uv.fs_scandir_next(scan)
                if not name then break end
                if name:match("%.md$") then names[name] = true end
              end
            end
          end
          -- A non-directory/symlink upper owner blocks the lower subtree.
          if owner and owner.type ~= "directory" then break end
        end
        local targets = vim.tbl_keys(names)
        table.sort(targets)
        for _, name in ipairs(targets) do
          local target = "/prompts/" .. name
          local entry, file_err = ability_catalog.resolve_file_reference(
            ability_catalog.format_reference(ability.name, target), root,
            { global_root = vim.fs.joinpath(global_root, "abilities") }
          )
          if entry then
            local ok, prompt = pcall(markdown.parse_file, entry.path, context)
            if ok and prompt then
              local rank = 4
              for _, layer in ipairs(ability.layers) do
                if layer.root == entry.root and layer.source == "project" then rank = 2; break end
              end
              prompt.ability = ability.name
              add(prompt, rank)
            elseif not ok then
              warn("Could not parse " .. entry.path .. ": " .. tostring(prompt))
            end
          else
            warn(ability.name .. target .. ": " .. tostring(file_err))
          end
        end
      end
    end
  end

  local prompts = {}
  local reserved = reserved_names()
  local keys = vim.tbl_keys(candidates)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local group = candidates[key]
    if #group.prompts > 1 then
      local paths = {}
      for i = 1, math.min(4, #group.prompts) do paths[#paths + 1] = group.prompts[i].path end
      warn(string.format("Conflicting /%s at priority %d; skipped: %s%s", key, group.rank,
        table.concat(paths, ", "), #group.prompts > 4 and ", ..." or ""))
    else
      if not reserved[key] then prompts[#prompts + 1] = group.prompts[1] end
    end
  end
  return prompts
end

function M.get(context)
  local root = M.project_root(context)
  local record, err = require("maxa.project.settings").read(root)
  if not record then warn(tostring(err)); return {} end
  local stamp = record.text or ""
  if not catalogs[root] or catalogs[root].stamp ~= stamp then
    catalogs[root] = { stamp = stamp, prompts = build(root, context) }
  end
  return vim.deepcopy(catalogs[root].prompts)
end

function M.refresh(context)
  catalogs[M.project_root(context)] = nil
  return M.get(context)
end

return M
