-- Maxa AI project/default interaction state.
--
-- Global adapter/model overrides live in the runtime repository `.env`.
-- Optional project adapter/model and Soul defaults live in
-- `<project>/.maxa/_meta.yaml`. They affect only newly created
-- interactions; existing/restored chats keep their composed prompt/config.

local M = {}
local settings = require("maxa.project.settings")

local ENV_ADAPTER_KEY = "MAXA_AI_DEFAULT_ADAPTER"
local ENV_MODEL_KEY = "MAXA_AI_DEFAULT_MODEL"
local PROJECT_ADAPTER_KEY = "default_adapter"
local PROJECT_MODEL_KEY = "default_model"

local function config_root()
  return vim.fn.stdpath("config")
end

function M.env_path()
  return vim.fs.joinpath(config_root(), ".env")
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function unquote_scalar(value)
  value = trim(value)
  local first = value:sub(1, 1)
  local last = value:sub(-1)
  if #value >= 2 and first == '"' and last == '"' then
    return value:sub(2, -2):gsub('\\"', '"'):gsub("\\\\", "\\")
  end
  if #value >= 2 and first == "'" and last == "'" then
    return value:sub(2, -2):gsub("''", "'")
  end
  return value
end

local function quote_env_value(value)
  value = tostring(value or "")
  if value:match("^[A-Za-z0-9_./:@%+%-]+$") then
    return value
  end
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "file not found: " .. path
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil, "failed to read: " .. path
  end
  return lines
end

local function read_env_lines()
  local lines = read_lines(M.env_path())
  return lines or {}
end

local function parse_env(lines)
  local values = {}
  for _, line in ipairs(lines or {}) do
    local key, value = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.-)%s*$")
    if key then
      values[key] = unquote_scalar(value)
    end
  end
  return values
end

function M.read_global_override()
  local values = parse_env(read_env_lines())
  local adapter = trim(values[ENV_ADAPTER_KEY])
  local model = trim(values[ENV_MODEL_KEY])
  if adapter == "" and model == "" then
    return nil
  end
  if adapter == "" or model == "" then
    return nil, "global default adapter/model override is incomplete"
  end
  return { adapter = adapter, model = model, scope = "global", source = M.env_path() }
end

M.read_persisted = M.read_global_override

function M.project_root(bufnr, cwd)
  local root
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    root = vim.fs.root(bufnr, { ".maxa" })
  end
  if root then
    return root
  end
  cwd = cwd or (vim.uv and vim.uv.cwd()) or vim.fn.getcwd()
  if cwd and cwd ~= "" then
    return vim.fs.root(cwd, { ".maxa" })
  end
end

function M.project_meta_path(project_root)
  if not project_root or project_root == "" then
    return nil
  end
  return vim.fs.joinpath(project_root, ".maxa", "_meta.yaml")
end

---Read project Soul from the root metadata; legacy wrappers are read-only views.
function M.read_project_soul(project_root)
  if not project_root then return nil end
  local record, err = settings.read(project_root)
  if not record then return nil, err end
  return record.data.soul
end

function M.read_project_override(project_root)
  if not project_root then return nil, "Maxa project root not found" end
  local record, err = settings.read(project_root)
  if not record then return nil, err end
  if record.missing then return nil, "file not found: " .. record.path end
  if not record.data.default_adapter then return nil end
  return {
    adapter = record.data.default_adapter,
    model = record.data.default_model,
    scope = "project",
    project_root = project_root,
    source = record.path,
  }
end

function M.get_initial_config(fallback)
  fallback = fallback or {}
  local persisted, persisted_err = M.read_global_override()
  if persisted then
    return {
      adapter = persisted.adapter,
      model = persisted.model,
      temperature = fallback.temperature,
      source = persisted.source,
    }
  end
  if persisted_err then
    vim.schedule(function()
      vim.notify("[Maxa AI] Ignoring invalid default adapter override: " .. persisted_err, vim.log.levels.WARN)
    end)
  end
  return vim.tbl_deep_extend("force", {}, fallback)
end

function M.resolve_effective(project_root, fallback)
  fallback = fallback or {}
  if project_root then
    local project, project_err = M.read_project_override(project_root)
    if project then
      return project
    end
    if project_err then
      return nil, project_err
    end
  end

  local global, global_err = M.read_global_override()
  if global then
    global.inherited = project_root ~= nil
    return global
  end
  if global_err then
    return nil, global_err
  end
  if trim(fallback.adapter) == "" or trim(fallback.model) == "" then
    return nil, "shared default adapter/model is unavailable"
  end
  return {
    adapter = fallback.adapter,
    model = fallback.model,
    temperature = fallback.temperature,
    scope = "shared",
    inherited = project_root ~= nil,
    source = fallback.source or "config",
  }
end

function M.write_global_override(adapter, model)
  adapter, model = trim(adapter), trim(model)
  if adapter == "" or model == "" then
    return false, "adapter and model are required"
  end
  local path = M.env_path()
  local lines = read_env_lines()
  local seen_adapter, seen_model = false, false
  for index, line in ipairs(lines) do
    local key = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=")
    if key == ENV_ADAPTER_KEY then
      lines[index] = ENV_ADAPTER_KEY .. "=" .. quote_env_value(adapter)
      seen_adapter = true
    elseif key == ENV_MODEL_KEY then
      lines[index] = ENV_MODEL_KEY .. "=" .. quote_env_value(model)
      seen_model = true
    end
  end
  if #lines > 0 and (not seen_adapter or not seen_model) and trim(lines[#lines]) ~= "" then
    table.insert(lines, "")
  end
  if not seen_adapter then
    table.insert(lines, ENV_ADAPTER_KEY .. "=" .. quote_env_value(adapter))
  end
  if not seen_model then
    table.insert(lines, ENV_MODEL_KEY .. "=" .. quote_env_value(model))
  end
  local ok, err = pcall(vim.fn.writefile, lines, path)
  return ok, err
end

M.write_persisted = M.write_global_override

function M.clear_global_override()
  local path = M.env_path()
  local lines = read_env_lines()
  local kept = {}
  for _, line in ipairs(lines) do
    local key = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=")
    if key ~= ENV_ADAPTER_KEY and key ~= ENV_MODEL_KEY then
      table.insert(kept, line)
    end
  end
  local ok, err = pcall(vim.fn.writefile, kept, path)
  return ok, err
end

function M.write_project_override(project_root, adapter, model)
  adapter, model = trim(adapter), trim(model)
  if adapter == "" or model == "" then return false, "adapter and model are required" end
  local ok, err = settings.update_many(project_root, {
    { path = { PROJECT_ADAPTER_KEY }, value = adapter },
    { path = { PROJECT_MODEL_KEY }, value = model },
  })
  return ok == true, err
end

function M.clear_project_override(project_root)
  local ok, err = settings.update_many(project_root, {
    { path = { PROJECT_ADAPTER_KEY } },
    { path = { PROJECT_MODEL_KEY } },
  })
  return ok == true, err
end

local function adapter_exists(config, name)
  return config.adapters.http and config.adapters.http[name] ~= nil
end

local function model_id(model)
  return type(model) == "table" and (model.id or model.modelId or model.name) or model
end

local function table_contains_model(choices, expected)
  for key, value in pairs(choices or {}) do
    if (type(key) == "string" and key == expected) or model_id(value) == expected then
      return true
    end
  end
  return false
end

local function validate_http_model(adapter, model)
  if not adapter.schema or not adapter.schema.model then
    return false, "adapter has no model schema"
  end
  local default_model = adapter.schema.model.default
  if type(default_model) == "function" then
    default_model = default_model(adapter)
  end
  if model == default_model then
    return true
  end
  local choices = adapter.schema.model.choices
  if type(choices) == "function" then
    local ok, result = pcall(choices, adapter, { async = false })
    if not ok then
      return false, "failed to load model choices: " .. tostring(result)
    end
    choices = result
  end
  if type(choices) ~= "table" then
    return false, "adapter does not expose model choices"
  end
  if table_contains_model(choices, model) then
    return true
  end
  return false, string.format("model '%s' is not registered for adapter '%s'", model, adapter.name or "?")
end

function M.validate(adapter_name, model)
  adapter_name, model = trim(adapter_name), trim(model)
  if adapter_name == "" or model == "" then
    return false, "adapter and model are required"
  end
  local ok_config, config = pcall(require, "maxa.config")
  if not ok_config then
    return false, "maxa.config is not available"
  end
  if not adapter_exists(config, adapter_name) then
    return false, string.format("adapter '%s' is not registered", adapter_name)
  end
  local ok_resolve, resolved = pcall(require("maxa.adapters").resolve, adapter_name)
  if not ok_resolve or not resolved then
    return false, "failed to resolve adapter: " .. tostring(resolved)
  end
  return validate_http_model(resolved, model)
end

function M.apply_to_maxa_ai_config(adapter, model)
  local ok_config, config = pcall(require, "maxa.config")
  if not ok_config or type(config) ~= "table" then
    return false, "maxa.config is not available"
  end
  local adapter_config = { name = adapter, model = model }
  config.interactions.chat.adapter = vim.deepcopy(adapter_config)
  return true
end

function M.persist(adapter, model, opts)
  opts = opts or {}
  local valid, err = M.validate(adapter, model)
  if not valid then
    return false, err
  end
  if opts.scope == "project" then
    return M.write_project_override(opts.project_root, adapter, model)
  end
  local ok, write_err = M.write_global_override(adapter, model)
  if not ok then
    return false, write_err
  end
  return M.apply_to_maxa_ai_config(adapter, model)
end

function M.persist_and_apply(adapter, model)
  return M.persist(adapter, model, { scope = "global" })
end

function M.clear(opts, fallback)
  opts = opts or {}
  if opts.scope == "project" then
    return M.clear_project_override(opts.project_root)
  end
  local ok, err = M.clear_global_override()
  if not ok then
    return false, err
  end
  fallback = fallback or {}
  if fallback.adapter and fallback.model then
    return M.apply_to_maxa_ai_config(fallback.adapter, fallback.model)
  end
  return true
end

function M.current(fallback)
  local persisted = M.read_global_override()
  if persisted then
    return persisted
  end
  fallback = fallback or {}
  return { adapter = fallback.adapter, model = fallback.model, source = fallback.source or "config", scope = "shared" }
end

function M.current_scope(scope, project_root, fallback)
  if scope == "project" then
    local project, err = M.read_project_override(project_root)
    if project then
      return project
    end
    if err then
      return nil, err
    end
    local effective, effective_err = M.resolve_effective(nil, fallback)
    if effective then
      effective.inherited = true
      effective.project_root = project_root
    end
    return effective, effective_err
  end
  return M.current(fallback)
end

return M
