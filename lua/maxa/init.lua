local _extensions = require("maxa._extensions")
local runtime_state = require("maxa.state")

-- Keep the public module loadable before optional runtime dependencies are on
-- runtimepath. setup() preflights those dependencies and only then resolves the
-- Plenary-dependent config/UI chain.
local config = setmetatable({}, {
  __index = function(_, key)
    return require("maxa.config")[key]
  end,
  __newindex = function(_, key, value)
    require("maxa.config")[key] = value
  end,
})

local function get_log()
  return require("maxa.utils.log")
end

local api = vim.api

local setup_state = "idle"
local setup_error

-- Lazy load context_utils
local context_utils
local function get_context(bufnr, args)
  if not context_utils then
    context_utils = require("maxa.utils.context")
  end
  return context_utils.get(bufnr, args)
end

---@class MaxaAI
local MaxaAI = {
  ---@type table Access to extension exports via extensions.foo
  extensions = _extensions.manager,
}

---Register an extension with setup and exports
---@param name string The name of the extension
---@param extension MaxaAI.Extension The extension implementation
---@return nil
MaxaAI.register_extension = function(name, extension)
  local ok, ext_error = pcall(_extensions.register_extension, name, extension)
  if not ok then
    get_log():error("Error loading extension %s: %s", name, ext_error)
  end
end

---Add visually selected code to the current chat buffer
---@param args table
---@return nil
MaxaAI.add = function(args)
  if not config.can_send_code() then
    return get_log():warn("Sending of code has been disabled")
  end

  local context = get_context(api.nvim_get_current_buf(), args)
  local content = table.concat(context.lines, "\n")

  local chat = MaxaAI.last_chat()
  if not chat then
    -- add() owns insertion of the selected text. When it has to create a chat,
    -- suppress the generic initial render's visual-context insertion so the
    -- same selection is not added once by each path.
    chat = MaxaAI.chat({
      context = context,
      stop_context_insertion = true,
    })

    if not chat then
      return get_log():warn("Could not create chat buffer")
    end
  end

  chat:add_buf_message({
    role = config.constants.USER_ROLE,
    content = "Here is some code from "
      .. context.filename
      .. ":\n\n```"
      .. context.filetype
      .. "\n"
      .. content
      .. "\n```\n",
  })
  chat.ui:open()
end

---Open a chat buffer and converse with an LLM
---@param args? { auto_submit: boolean, params: table, subcommand: table, callbacks: table, context: table, messages: MaxaAI.Chat.Messages, stop_context_insertion: boolean, user_prompt: table, window_opts: table }
---@return MaxaAI.Chat|nil
MaxaAI.chat = function(args)
  args = args or {}

  local adapter
  local messages = args.messages or {}
  local context = args.context or get_context(api.nvim_get_current_buf(), args)

  -- Set the adapter and model if provided
  if args.params and args.params.adapter then
    local adapter_name = args.params.adapter
    local adapter_config = config.adapters.http[adapter_name]
    if not adapter_config then
      return get_log():error("Adapter not found: %s", adapter_name)
    end
    adapter = require("maxa.adapters").resolve(adapter_config)
    if not adapter then
      return nil
    end
    if args.params.model then
      adapter.schema.model.default = args.params.model
    end
  end

  if args.subcommand then
    if args.subcommand == "add" then
      return MaxaAI.add(args)
    elseif args.subcommand == "toggle" then
      return MaxaAI.toggle(args)
    elseif args.subcommand == "refreshcache" then
      return MaxaAI.chat_refresh_cache()
    end
  end

  -- Manage user prompts
  if args.user_prompt and #args.user_prompt > 0 then
    table.insert(messages, {
      role = config.constants.USER_ROLE,
      content = args.user_prompt,
    })
  end

  local has_messages = not vim.tbl_isempty(messages)
  local auto_submit = has_messages -- Don't auto submit if there are no messages
  if args.auto_submit ~= nil then
    auto_submit = args.auto_submit
  end

  return require("maxa.interactions.chat").new({
    adapter = adapter,
    auto_submit = auto_submit,
    buffer_context = context,
    callbacks = args.callbacks,
    messages = has_messages and messages or nil,
    stop_context_insertion = args.stop_context_insertion,
    window_opts = args.window_opts,
  })
end

---Refresh any of the caches used by the plugin
---@return nil
MaxaAI.chat_refresh_cache = function()
  require("maxa.interactions.chat.tools.filter").refresh_cache()
  require("maxa.interactions.chat.slash_commands.filter").refresh_cache()
  require("maxa.prompts.sources").refresh(get_context(api.nvim_get_current_buf()))
  require("maxa.utils").notify("Refreshed Chat filters and current project prompts", vim.log.levels.INFO)
end

---Toggle the chat buffer
---@param args? table
---@return nil
MaxaAI.toggle = function(args)
  local window_opts = args and args.window_opts

  -- Sidebar toggling is independent of the last focused child float.
  local chat = require("maxa.interactions.chat").last_main_chat()
  if not chat then
    local chat_opts = {}
    if args and args.params then
      chat_opts.params = args.params
    end
    if window_opts then
      chat_opts.window_opts = window_opts
    end

    return MaxaAI.chat(chat_opts)
  end

  -- If the chat is visible in a different tab, just hide it there
  if chat.ui:is_visible_non_curtab() then
    chat.ui:hide()
  -- If the chat is visible in the current tab, hide it and return early
  elseif chat.ui:is_visible() then
    return chat.ui:hide()
  end

  chat.buffer_context = get_context(api.nvim_get_current_buf())

  -- At this point, the chat exists but is not visible in the current tab

  -- Close the chat window (if it's open elsewhere)
  MaxaAI.close_last_chat()

  -- Reopen the chat in the current tab with the toggled flag
  local opts = { toggled = true }
  if window_opts then
    opts.window_opts = window_opts
  end
  chat.ui:open(opts)
end

---Make a previously hidden chat buffer, visible again
---@param bufnr number
---@return nil
MaxaAI.restore = function(bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return get_log():error("Chat buffer %d is not valid", bufnr)
  end

  local chat = require("maxa.interactions.chat").buf_get_chat(bufnr)
  if not chat then
    return get_log():error("Could not restore the chat buffer")
  end

  if chat.ui:is_visible() then
    if chat.ui.winnr and api.nvim_win_is_valid(chat.ui.winnr) then
      pcall(api.nvim_set_current_win, chat.ui.winnr)
    end
    return
  end
  chat.ui:open()
end

---Return a chat buffer
---@param bufnr? number
---@return MaxaAI.Chat|table
MaxaAI.buf_get_chat = function(bufnr)
  return require("maxa.interactions.chat").buf_get_chat(bufnr)
end

---Get the last chat buffer
---@return MaxaAI.Chat|nil
MaxaAI.last_chat = function()
  return require("maxa.interactions.chat").last_chat()
end

---Close the last chat buffer
---@return nil
MaxaAI.close_last_chat = function()
  return require("maxa.interactions.chat").close_last_chat()
end

---Check if a feature is available in the plugin's current version
---@param feature? string|table
---@return boolean|table
MaxaAI.has = function(feature)
  local features = {
    "chat",
    "markdown-slash-prompts",
    "function-calling",
    "extensions",
    "rules",
  }

  if type(feature) == "string" then
    return vim.tbl_contains(features, feature)
  end
  if type(feature) == "table" then
    for _, f in ipairs(feature) do
      if not vim.tbl_contains(features, f) then
        return false
      end
    end
    return true
  end
  return features
end

---Read the mother runtime's .version compatibility generation.
---@return string? version
---@return string? error
MaxaAI.version = function()
  return require("maxa.version").read()
end

local REQUIRED_MODULES = {
  "plenary.async",
  "maxa.commands",
  "maxa.providers.completion.default.setup",
  "maxa.interactions.chat",
  "maxa.interactions.chat.tools",
  "maxa.interactions.chat.ui",
  "maxa.lifecycle",
  "maxa.session",
}

local function module_is_available(module_name)
  if package.loaded[module_name] ~= nil or package.preload[module_name] ~= nil then
    return true
  end
  local module_path = module_name:gsub("%.", "/")
  return #api.nvim_get_runtime_file("lua/" .. module_path .. ".lua", false) > 0
    or #api.nvim_get_runtime_file("lua/" .. module_path .. "/init.lua", false) > 0
end

local function preflight(opts)
  local modules = vim.deepcopy(REQUIRED_MODULES)
  local completion = (((opts or {}).interactions or {}).chat or {}).opts
  completion = completion and completion.completion_provider or "default"
  modules[#modules + 1] = "maxa.providers.completion." .. completion .. ".setup"
  for _, module_name in ipairs(modules) do
    if not module_is_available(module_name) then
      error(string.format("Maxa AI setup preflight failed: module %s is unavailable", module_name))
    end
  end
end

local function require_for_setup(module_name)
  local previous = package.loaded[module_name]
  local ok, loaded = pcall(require, module_name)
  if not ok then
    package.loaded[module_name] = previous
    error(string.format("Maxa AI setup failed loading %s: %s", module_name, loaded))
  end
  return loaded
end

local function setup_mcphub()
  local opts = vim.deepcopy(require("maxa.config").runtime().mcphub)
  assert(opts.servers == nil, "maxa.mcphub.servers is unsupported; use the project .maxa/abilities/mcp.json")
  opts.global_env = function(context)
    local project_root = context and context.cwd or vim.uv.cwd() or vim.fn.getcwd(-1, -1)
    return {
      PROJECT_ROOT = project_root,
      ["input:replicate-api-token"] = require("maxa.utils.env").get("REPLICATE_API_TOKEN"),
    }
  end
  local configured_backend_env = opts.backend_env
  opts.backend_env = function(context)
    local values = type(configured_backend_env) == "function" and configured_backend_env(context) or configured_backend_env
    values = vim.tbl_extend("force", {}, values or {})
    values.MAXA_RUNTIME_ROOT = assert(require("maxa.version").runtime_root, "runtime-root-unavailable")
    local env = require("maxa.utils.env")
    for _, key in ipairs({ "SENTRY_ACCESS_TOKEN", "TWITTER_AUTH_TOKEN", "TWITTER_CT0", "TWITTER_MCP_PROJECT_DIR" }) do
      if values[key] == nil then
        local value = env.get(key)
        if value and value ~= "" then
          values[key] = value
        end
      end
    end
    -- Backend lookup inputs only: servers opt in through their own env declarations.
    for _, key in ipairs({ "ALL_PROXY", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY" }) do
      if values[key] == nil then values[key] = env.get(key) or "" end
    end
    return values
  end
  opts.native_servers = vim.tbl_extend("force", opts.native_servers or {}, require_for_setup("maxa.mcphub.native_servers"))
  local hub = require_for_setup("maxa.mcphub")
  hub.setup(opts)
  local state = hub.get_state()
  if state.setup_state == "failed" then
    local errors = state.errors.items
    error("MCPHub setup failed: " .. tostring(errors[#errors] or "unknown error"))
  end
end

local function snapshot_side_effects()
  local commands, autocmds, loaded = {}, {}, {}
  for name in pairs(api.nvim_get_commands({ builtin = false })) do
    commands[name] = true
  end
  for _, autocmd in ipairs(api.nvim_get_autocmds({})) do
    if type(autocmd.id) == "number" then
      autocmds[autocmd.id] = true
    end
  end
  for name, value in pairs(package.loaded) do
    loaded[name] = { value = value }
  end
  local loaded_config = package.loaded["maxa.config"]
  local config_snapshot = loaded_config and loaded_config.snapshot and loaded_config.snapshot() or nil
  return { commands = commands, autocmds = autocmds, loaded = loaded, config = config_snapshot }
end

local function cleanup_bootstrap_side_effects(snapshot)
  snapshot = snapshot or { commands = {}, autocmds = {}, loaded = {} }
  for name in pairs(api.nvim_get_commands({ builtin = false })) do
    if not snapshot.commands[name] then
      pcall(api.nvim_del_user_command, name)
    end
  end
  for _, autocmd in ipairs(api.nvim_get_autocmds({})) do
    if type(autocmd.id) == "number" and not snapshot.autocmds[autocmd.id] then
      pcall(api.nvim_del_autocmd, autocmd.id)
    end
  end
  vim.g.loaded_maxa_ai = nil
end

-- Only core runtime module roots belong to setup rollback. Other maxa.* keys
-- (for example Ability-owned maxa.neovim.* observations) keep their state.
local SETUP_MODULE_ROOTS = {
  _extensions = true, abilities = true, adapters = true, commands = true, config = true,
  deployment = true, health = true, helpers = true, http = true,
  interactions = true, lifecycle = true, mcphub = true, model_catalog = true,
  project = true, prompts = true, provider_config = true, providers = true, schema = true,
  session = true, state = true, task_browser = true, utils = true, version = true,
  setup_fault = true, setup_fault_late = true,
}

local function is_setup_owned_module(module_name)
  local root = module_name:match("^maxa%.([^.]+)")
  return root ~= nil and SETUP_MODULE_ROOTS[root] == true
end

local function restore_setup_modules(snapshot)
  local loaded_snapshot = (snapshot and snapshot.loaded) or {}
  local current_owned = {}
  for module_name, loaded in pairs(package.loaded) do
    if is_setup_owned_module(module_name) then
      current_owned[#current_owned + 1] = module_name
      if type(loaded) == "table" and type(loaded.reset_setup) == "function" then
        pcall(loaded.reset_setup)
      end
    end
  end
  for _, module_name in ipairs(current_owned) do
    if loaded_snapshot[module_name] == nil then
      package.loaded[module_name] = nil
    end
  end
  for module_name, entry in pairs(loaded_snapshot) do
    if is_setup_owned_module(module_name) then
      package.loaded[module_name] = entry.value
    end
  end
end

local function rollback_setup(snapshot)
  cleanup_bootstrap_side_effects(snapshot)
  restore_setup_modules(snapshot)
  local loaded_config = package.loaded["maxa.config"]
  if snapshot and snapshot.config and loaded_config and type(loaded_config.restore) == "function" then
    loaded_config.restore(snapshot.config)
  end
  context_utils = nil
end

function MaxaAI.setup_status()
  return {
    state = setup_state,
    error = setup_error,
  }
end

---Setup the plugin
---@param opts? table
---@return nil
MaxaAI.setup = function(opts)
  if setup_state == "ready" then
    return true
  end
  if setup_state == "setting_up" then
    error("Maxa AI setup is already in progress")
  end
  if vim.fn.has("nvim-0.11") == 0 then
    error("Maxa AI requires Neovim 0.11+")
  end

  opts = opts or {}
  local side_effect_snapshot = snapshot_side_effects()
  setup_state = "setting_up"
  setup_error = nil
  local preflight_ok, preflight_err = xpcall(function()
    preflight(opts)
  end, debug.traceback)
  if not preflight_ok then
    setup_state = "failed"
    setup_error = preflight_err
    rollback_setup(side_effect_snapshot)
    error(preflight_err)
  end

  local setup_ok, setup_result = xpcall(function()
    for _, module_name in ipairs(REQUIRED_MODULES) do
      require_for_setup(module_name)
    end

  local highlights = {
    ChatInfo = "DiagnosticInfo",
    ChatError = "DiagnosticError",
    ChatWarn = "DiagnosticWarn",
    ChatSubtext = "Comment",
    ChatFold = "@markup.quote.markdown",
    ChatHeader = "@markup.heading.2.markdown",
    ChatSeparator = "@punctuation.special.markdown",
    ChatTokens = "Comment",
    ChatTool = "Special",
    ChatToolFailure = "DiagnosticError",
    ChatToolFailureIcon = "Error",
    ChatToolGroup = "Constant",
    ChatToolInProgress = "DiagnosticInfo",
    ChatToolInProgressIcon = "DiagnosticInfo",
    ChatToolPending = "DiagnosticWarn",
    ChatToolPendingIcon = "DiagnosticWarn",
    ChatToolSuccess = "DiagnosticOK",
    ChatToolSuccessIcon = "DiagnosticOK",
    ChatVariable = "Identifier",
    ChatInfoBanner = "WildMenu",
    VirtualText = "Comment",
  }
  for suffix, link in pairs(highlights) do
    api.nvim_set_hl(0, "MaxaAI" .. suffix, { link = link, default = true })
  end
  local visual_hl = api.nvim_get_hl(0, { name = "Visual" })
  pcall(api.nvim_set_hl, 0, "MaxaAIInlineDiffHint", { bg = visual_hl.bg, default = true })

  local syntax_group = api.nvim_create_augroup("maxa.ai.syntax", { clear = true })
  api.nvim_create_autocmd("FileType", {
    pattern = "maxa_ai",
    group = syntax_group,
    callback = vim.schedule_wrap(function(args)
      if not api.nvim_buf_is_valid(args.buf) then
        return
      end
      vim.bo[args.buf].syntax = "ON"
      vim.cmd.syntax([[match MaxaAIChatTool "@\S\+"]])
      vim.cmd.syntax([[match MaxaAIChatVariable "#\S\+"]])
    end),
  })

  local buf_group = api.nvim_create_augroup("maxa.ai.buffers", { clear = true })
  api.nvim_create_autocmd("TermEnter", {
    group = buf_group,
    callback = function(args)
      if api.nvim_buf_is_valid(args.buf) and vim.bo[args.buf].buftype == "terminal" then
        runtime_state.last_terminal = args.buf
      end
    end,
  })
  api.nvim_create_autocmd("BufEnter", {
    group = buf_group,
    callback = function(args)
      if not api.nvim_buf_is_valid(args.buf) then
        return
      end
      local excluded = {
        buftypes = { "nofile", "quickfix", "prompt", "popup" },
        fts = { "maxa_ai", "help", "terminal" },
      }
      if not vim.tbl_contains(excluded.fts, vim.bo[args.buf].filetype)
        and not vim.tbl_contains(excluded.buftypes, vim.bo[args.buf].buftype)
      then
        runtime_state.current_context = args.buf
        require("maxa.utils").fire("ContextChanged", { bufnr = args.buf })
      end
    end,
  })
  vim.treesitter.language.register("markdown", "maxa_ai")

  -- Compose the merged Lazy options before any deployment-dependent consumers.
  config.setup(opts)
  local preset_name = config.interactions.chat.preset
  -- Standalone library setup may omit deployment defaults and retain chat.adapter.
  local chat_default = config.runtime().defaults.chat
  if preset_name or type(chat_default) == "string" or next(chat_default or {}) ~= nil then
    local presets = require("maxa.presets")
    local selected, err
    if preset_name then selected, err = presets.get_preset(preset_name, "chat")
    else selected, err = presets.get_default("chat") end
    assert(selected, err)
    if not (opts.interactions and opts.interactions.chat and opts.interactions.chat.adapter) then
      local initial = require("maxa.session.default_adapter").get_initial_config(selected)
      config.interactions.chat.adapter = { name = initial.adapter, model = initial.model }
    end
  end
  require("maxa.mcphub.native_servers.genai.default_adapter").refresh_loaded(config.runtime().genai)
  require("maxa.prompts.commands").setup()
  require("maxa.project.drafts").setup_commands()
  require("maxa.session.buffer_translate").setup(config.runtime().translate)

  local cmds = require("maxa.commands")
  for _, cmd in ipairs(cmds) do
    api.nvim_create_user_command(cmd.cmd, cmd.callback, cmd.opts)
  end
  local fault = package.loaded["maxa.setup_fault"]
  if type(fault) == "function" then
    fault()
  end

  -- Set up completion. Provider modules own explicit, idempotent setup rather
  -- than performing runtime side effects merely by being required.
  local completion = config.interactions.chat.opts.completion_provider
  local completion_module = require_for_setup("maxa.providers.completion." .. completion .. ".setup")
  if type(completion_module) == "table" and type(completion_module.setup) == "function" then
    completion_module.setup(config)
  end

  -- Set the log root
  local log = get_log()
  log.set_root(log.new({
    handlers = {
      {
        type = "notify",
        level = vim.log.levels.WARN,
      },
      {
        type = "file",
        filename = "maxa.ai.log",
        level = vim.log.levels[config.opts.log_level],
      },
    },
  }))

  -- Preserve third-party extension support without routing repository-owned
  -- session/MCPHub capabilities through an external extension identity.
  for name, schema in pairs(config.extensions) do
    if name ~= "history" and name ~= "mcphub" and schema.enabled ~= false then
      local ok, ext_error = pcall(_extensions.load_extension, name, schema)
      if not ok then
        log:error("Error loading extension %s: %s", name, ext_error)
      end
    end
  end

  local window_config = config.display.chat.window
  require("maxa.utils.images").setup()
  require("maxa.lifecycle").setup(opts.maxa_lifecycle or {})
  require("maxa.session").setup((config.extensions.history and config.extensions.history.opts) or {})
  local late_fault = package.loaded["maxa.setup_fault_late"]
  if type(late_fault) == "function" then
    late_fault()
  end
  if window_config.sticky and (window_config.layout ~= "buffer") then
    api.nvim_create_autocmd("TabEnter", {
      group = api.nvim_create_augroup("maxa.ai.sticky_buffer", { clear = true }),
      callback = function(args)
        local chat = MaxaAI.last_chat()
        if chat and chat.ui:is_visible_non_curtab() then
          chat.buffer_context = get_context(args.buf)
          vim.schedule(function()
            MaxaAI.close_last_chat()
            chat.ui:open({ toggled = true })
          end)
        end
      end,
    })
  end
  setup_mcphub()
  require("maxa.prompts.sources").get(get_context(api.nvim_get_current_buf()))
  end, debug.traceback)

  if not setup_ok then
    setup_state = "failed"
    setup_error = setup_result
    rollback_setup(side_effect_snapshot)
    error(setup_result)
  end

  setup_state = "ready"
  setup_error = nil
  vim.g.loaded_maxa_ai = true
  return true
end

return MaxaAI
