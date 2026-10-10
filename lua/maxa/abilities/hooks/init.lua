local parser = require("maxa.abilities.hooks.parser")
local registry = require("maxa.abilities.hooks.registry")

local M = {}

local function get_project_root()
  local ok, root = pcall(require, "lazyvim.util.root")
  if ok and root and root.get then
    return root.get()
  end
  return vim.uv.cwd() or vim.fn.getcwd(-1, -1)
end

local function effective_hook_files(ability)
  local owners = {}
  for _, layer in ipairs(ability.layers or {}) do
    local hooks_dir = layer.root .. "/hooks"
    local handle = vim.uv.fs_scandir(hooks_dir)
    if handle then
      while true do
        local name, kind = vim.uv.fs_scandir_next(handle)
        if not name then
          break
        end
        if kind == "file" and name:match("^.+%.[^.]+$") and not owners[name] then
          owners[name] = { path = hooks_dir .. "/" .. name, root = layer.root }
        end
      end
    end
  end
  local by_event = {}
  for name, owner in pairs(owners) do
    local event, extension = name:match("^(.+)%.([^.]+)$")
    if extension == "md" or extension == "lua" then
      by_event[event] = by_event[event] or {}
      by_event[event][extension] = owner
    end
  end
  return by_event
end

local function parse_hooks(ability)
  local parsed = {}
  local by_event = effective_hook_files(ability)
  local events = vim.tbl_keys(by_event)
  table.sort(events)
  for _, event in ipairs(events) do
    local files = by_event[event]
    if files.md and files.lua then
      return nil, string.format("Ability %s defines incompatible Markdown and Lua hooks for %s", ability.name, event)
    end
    local owner = files.md or files.lua
    local hook, parse_status
    if files.md then
      hook, parse_status = parser.parse_hook_file(owner.path, owner.root)
    else
      hook, parse_status = parser.parse_lua_hook_file(owner.path, owner.root)
    end
    if hook then
      hook.ability_name = ability.name
      parsed[#parsed + 1] = hook
    elseif parse_status ~= "disabled" then
      return nil, string.format("Ability %s has invalid hook %s", ability.name, owner.path)
    end
  end
  return parsed
end

function M.prepare_on_load_hooks(ability, project_root)
  if not ability or not require("maxa.abilities.catalog").valid_identifier(ability.name) then
    return {}
  end
  if project_root then
    local allowed, err = require("maxa.project.settings").check_ability(project_root, ability.name)
    if not allowed then return nil, err end
  end
  local hooks, err = parse_hooks(ability)
  if not hooks then
    return nil, err
  end
  local result = {}
  for _, hook in ipairs(hooks) do
    if hook.load == "on_load" then
      result[#result + 1] = hook
    end
  end
  return result
end

function M.commit_on_load_hooks(chat, ability_name, hooks)
  local root = chat and chat.opts and (chat.opts.project_root or chat.opts.cwd)
  if root then
    local allowed = require("maxa.project.settings").check_ability(root, ability_name)
    if not allowed then return 0 end
  end
  local chat_id = chat and chat.id or nil
  if chat_id and type(registry.unregister_ability) == "function" then
    registry.unregister_ability(chat_id, ability_name)
  end
  local count = 0
  for _, hook in ipairs(hooks or {}) do
    local bind_id = (hook.scope == "session" or hook.scope == "cascade") and chat_id or nil
    if registry.register(hook, bind_id) then
      count = count + 1
    end
  end
  return count
end

function M.setup_startup_hooks()
  local catalog, err = require("maxa.abilities.catalog").list(get_project_root())
  if not catalog then
    vim.notify("[ability_hooks] Startup discovery failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local count = 0
  for _, ability in ipairs(catalog.abilities or {}) do
    if ability.enabled ~= false and #ability.layers > 0 then
      local hooks, hook_err = parse_hooks(ability)
      if not hooks then
        vim.notify("[ability_hooks] " .. tostring(hook_err), vim.log.levels.ERROR)
      else
        for _, hook in ipairs(hooks) do
          if hook.load == "startup" and registry.register(hook, nil) then
            count = count + 1
          end
        end
      end
    end
  end
  if count > 0 then
    vim.notify(string.format("[ability_hooks] Registered %d startup hook(s)", count), vim.log.levels.DEBUG)
  end
end

function M.restore_hooks_from_messages(chat)
  if not chat or not chat.messages then
    return
  end
  require("maxa.abilities.hooks.injector").restore_once_state(chat.id, chat.messages)
  local root = chat.opts and (chat.opts.project_root or chat.opts.cwd)
  local catalog, catalog_err = require("maxa.session.abilities").catalog(chat, chat.opts and chat.opts.cwd)
  if not catalog then
    vim.notify("[ability_hooks] Restore skipped: " .. tostring(catalog_err), vim.log.levels.WARN)
    return
  end
  for name, ready in pairs(catalog.abilities) do
    local revision = ready.revision
    if not root or not require("maxa.project.settings").check_ability(root, name) then goto continue end
    local layers = {}
    for _, root in ipairs(revision.roots or {}) do
      layers[#layers + 1] = { root = root }
    end
    local ability = { name = name, layers = layers }
    local hooks, err = M.prepare_on_load_hooks(ability)
    if hooks then
      M.commit_on_load_hooks(chat, name, hooks)
    else
      vim.notify("[ability_hooks] Restore skipped for " .. name .. ": " .. tostring(err), vim.log.levels.WARN)
    end
    ::continue::
  end
end

if vim.v.vim_did_enter == 1 then
  vim.schedule(M.setup_startup_hooks)
else
  vim.api.nvim_create_autocmd("User", { pattern = "VeryLazy", once = true, callback = M.setup_startup_hooks })
end

return M
