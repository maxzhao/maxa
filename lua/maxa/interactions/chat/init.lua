local runtime_state = require("maxa.state")
--=============================================================================
-- The Chat Buffer - Where all of the logic for conversing with an LLM sits
--=============================================================================

---@class MaxaAI.Chat
---@field adapter MaxaAI.HTTPAdapter The adapter to use for the chat
---@field aug number The ID for the autocmd group
---@field buffer_context table The context of the buffer that the chat was initiated from
---@field bufnr number The buffer number of the chat
---@field builder MaxaAI.Chat.UI.Builder The builder for the chat UI
---@field callbacks table<string, fun(chat: MaxaAI.Chat)[]> A table of callback functions that are executed at various points
---@field chat_parser vim.treesitter.LanguageTree The Markdown Tree-sitter parser for the chat buffer
---@field context MaxaAI.Chat.Context
---@field context_items? table<MaxaAI.Chat.Context> Context which is sent to the LLM e.g. buffers, slash command output
---@field current_request table|nil The current request being executed
---@field current_tool table The current tool being executed
---@field cycle number Records the number of turn-based interactions (User -> LLM) that have taken place
---@field create_buf fun(): number The function that creates a new buffer for the chat
---@field from_prompt_library? boolean Whether the chat was initiated from the prompt library
---@field header_line number The line number of the user header that any Tree-sitter parsing should start from
---@field header_ns number The namespace for the virtual text that appears in the header
---@field id number The unique identifier for the chat
---@field intro_message? string The welcome message that is displayed in the chat buffer
---@field messages? MaxaAI.Chat.Messages The messages in the chat buffer
---@field opts MaxaAI.ChatArgs Store all arguments in this table
---@field settings? table The settings that are used in the adapter of the chat buffer
---@field title? string The title of the chat buffer
---@field tokens? nil|number The number of tokens in the chat
---@field tools MaxaAI.Tools The tools coordinator that executes available tools
---@field tool_registry MaxaAI.Chat.ToolRegistry Methods for handling interactions between the chat buffer and tools
---@field ui MaxaAI.Chat.UI The UI of the chat buffer
---@field window_opts? table Window configuration options for the chat buffer
---@field _last_role string The last role that was rendered in the chat buffer
---@field _tool_monitors? table A table of tool monitors that are currently running in the chat buffer

---@class MaxaAI.ChatArgs Arguments that can be injected into the chat
---@field adapter? MaxaAI.HTTPAdapter The adapter used in this chat buffer
---@field auto_submit? boolean Automatically submit the chat when the chat buffer is created
---@field buffer_context? table Context of the buffer that the chat was initiated from
---@field cwd? string Exact working directory owned by this Chat
---@field project_root? string Exact project root owned by this Chat
---@field callbacks table<string, fun(chat: MaxaAI.Chat)[]> A table of callback functions that are executed at various points
---@field from_prompt_library? boolean Whether the chat was initiated from the prompt library
---@field ignore_system_prompt? boolean Do not send the default system prompt with the request
---@field last_role string The last role that was rendered in the chat buffer-
---@field messages? MaxaAI.Chat.Messages The messages to display in the chat buffer
---@field settings? table The settings that are used in the adapter of the chat buffer
---@field status? string The status of any running jobs in the chat buffe
---@field stop_context_insertion? boolean Stop any visual selection from being automatically inserted into the chat buffer
---@field title? string The title of the chat buffer
---@field tokens? table Total tokens spent in the chat buffer so far
---@field intro_message? string The welcome message that is displayed in the chat buffer
---@field window_opts? table Window configuration options for the chat buffer

local adapters = require("maxa.adapters")
local completion = require("maxa.providers.completion")
local config = require("maxa.config")
local hash = require("maxa.utils.hash")
local helpers = require("maxa.interactions.chat.helpers")
local buffer_guard = require("maxa.interactions.chat.ui.buffer_guard")
local keymaps = require("maxa.utils.keymaps")
local log = require("maxa.utils.log")
local parser = require("maxa.interactions.chat.parser")
local schema = require("maxa.schema")
local utils = require("maxa.utils")

local api = vim.api
local fmt = string.format

local CONSTANTS = {
  AUTOCMD_GROUP = "maxa.ai.chat",

  STATUS_CANCELLING = "cancelling",
  STATUS_ERROR = "error",
  STATUS_SUCCESS = "success",

  BLANK_DESC = "[No messages]",

  SYSTEM_PROMPT = [[You are an AI programming assistant named "MaxaAI", working within the Neovim text editor.

You can perform the following tasks:
* Answer general programming questions.
* Explain how the code in a Neovim buffer works.
* Review the selected code from a Neovim buffer.
* Generate unit tests for the selected code.
* Propose fixes for problems in the selected code.
* Scaffold code for a new workspace.
* Find relevant code to the user's query.
* Propose fixes for test failures.
* Answer questions about Neovim.
* Prefer vim.api* methods where possible.

Follow the user's requirements carefully and to the letter.
Use the context and attachments the user provides.
Keep your answers short and impersonal, especially if the user's context is outside your core tasks.
Use Markdown formatting in your answers.
DO NOT use H1 or H2 headers in your response.
When suggesting code changes or new content, use Markdown code blocks.
To start a code block, use 4 backticks.
After the backticks, add the programming language name as the language ID and the file path within curly braces if available.
To close a code block, use 4 backticks on a new line.
If you want the user to decide where to place the code, do not add the file path.
In the code block, use a line comment with '...existing code...' to indicate code that is already present in the file. Ensure this comment is specific to the programming language.
Code block example:
````languageId {path/to/file}
// ...existing code...
{ changed code }
// ...existing code...
{ changed code }
// ...existing code...
````
Ensure line comments use the correct syntax for the programming language (e.g. "#" for Python, "--" for Lua).
Avoid wrapping the whole response in triple backticks.
Do not include diff formatting unless explicitly asked.
Do not include line numbers unless explicitly asked.

When given a task:
1. Plan multi-step work unless the user requests otherwise or the task is very simple. For complex architectural changes, describe your plan in pseudocode first.
2. Include only relevant code in code blocks.
3. Offer a next step only when it directly helps the user's current task.

]],
}

local clients = {} -- Cache for HTTP clients
local llm_role = config.interactions.chat.roles.llm
local user_role = config.interactions.chat.roles.user

--=============================================================================
-- Private methods
--=============================================================================

---Get the HTTP client
---@return table
local function get_client()
  if not clients.http then
    clients.http = require("maxa.http")
  end
  return clients.http
end

---Find a message in the table that has a specific tool call ID
---@param id string
---@param messages MaxaAI.Chat.Messages
---@return table|nil
local function find_tool_call(id, messages)
  for _, msg in ipairs(messages) do
    if msg.tools and msg.tools.call_id and msg.tools.call_id == id then
      return msg
    end
  end
  return nil
end

---Increment the cycle count in the chat buffer
---@param chat MaxaAI.Chat
---@return nil
local function increment_cycle(chat)
  chat.cycle = chat.cycle + 1
end

---Make an id from a string or table
---@param val string|table
---@return number
local function make_id(val)
  return hash.hash(val)
end

---Reject work belonging to a closed or destroyed Chat.
local function chat_is_live(chat)
  if chat._closed then
    return false
  end
  if not buffer_guard.valid(chat.bufnr) then
    buffer_guard.abort(chat, "Chat buffer is unavailable")
    return false
  end
  return true
end

---Set the editable text area. This allows us to scope the Tree-sitter queries to a specific area
---@param chat MaxaAI.Chat
---@param modifier? number
---@return nil
local function set_text_editing_area(chat, modifier)
  modifier = modifier or 0
  chat.header_line = api.nvim_buf_line_count(chat.bufnr) + modifier
end

---Ready the chat buffer for the next round of conversation
---@param chat MaxaAI.Chat
---@param opts? table
---@return nil
local function ready_chat_buffer(chat, opts)
  if not chat_is_live(chat) then
    return
  end
  opts = opts or {}

  if not opts.auto_submit then
    require("maxa.adapters.metrics").finish_turn(chat)
  end
  if not opts.auto_submit and chat._last_role ~= config.constants.USER_ROLE then
    increment_cycle(chat)
    chat:add_buf_message({ role = config.constants.USER_ROLE, content = "" })

    set_text_editing_area(chat, -2)
    chat.ui:display_tokens(chat.chat_parser, chat.header_line)
    chat:dispatch("on_ready")
  end

  chat:update_metadata()

  -- If we're automatically responding to a tool output, we need to leave some
  -- space for the LLM's response so we can then display the user prompt again
  if opts.auto_submit then
    chat.ui:add_line_break()
    chat.ui:add_line_break()
  end

  log:info("Chat request finished")
  chat:reset()
end

---Used to record the last chat buffer that was opened
---@type MaxaAI.Chat|nil
---@diagnostic disable-next-line: missing-fields
local last_chat = {}
local last_main_chat
local agent_identity = require("maxa.session.agent_identity")

---Set the autocmds for the chat buffer
---@param chat MaxaAI.Chat
---@return nil
local function set_autocmds(chat)
  local bufnr = chat.bufnr

  api.nvim_create_autocmd("BufEnter", {
    group = chat.aug,
    buffer = bufnr,
    desc = "Log the most recent chat buffer",
    callback = function()
      last_chat = chat
      if agent_identity.is_main(chat) and not chat.opts.preserve_main then last_main_chat = chat end
    end,
  })

  api.nvim_create_autocmd("CompleteDone", {
    group = chat.aug,
    buffer = bufnr,
    callback = function()
      local item = vim.v.completed_item
      if item.user_data and item.user_data.type == "slash_command" then
        local row, col = unpack(api.nvim_win_get_cursor(0))
        local selected = item.user_data
        selected.label = selected.label or item.abbr or item.word
        local ok, err = completion.prepare_slash_command(selected, chat, bufnr, {
          start = { row = row - 1, col = col - #item.word },
          ["end"] = { row = row - 1, col = col },
          revalidate_selection = true,
        })
        if not ok then
          return log:error("Could not prepare slash command: %s", err)
        end

        completion.slash_commands_execute(selected, chat)
      end
    end,
  })

end

--=============================================================================
-- Public methods
--=============================================================================

---Methods that are available outside of MaxaAI
---@type table<MaxaAI.Chat>
local chatmap = {}

---@type table
runtime_state.buffers = {}

---@type table
runtime_state.chat_metadata = {}

---@class MaxaAI.Chat
local Chat = {}

Chat.MESSAGE_TYPES = {
  LLM_MESSAGE = "llm_message",
  REASONING_MESSAGE = "reasoning_message",
  SYSTEM_MESSAGE = "system_message",
  TOOL_MESSAGE = "tool_message",
  USER_MESSAGE = "user_message",
}

---@param args MaxaAI.ChatArgs
---@return MaxaAI.Chat
local function fallback_default_adapter()
  local ok, mcp_config = pcall(require, "maxa.mcphub.native_servers.config")
  local name = config.interactions.chat.preset
  return ok and ((name and mcp_config.get_adapter(name) or mcp_config.get_default("chat")) or {}) or {}
end

local function resolve_project_adapter(args)
  if args.adapter ~= nil then
    return args.adapter
  end
  local state = require("maxa.session.default_adapter")
  local context = args.buffer_context or {}
  local project_root = state.project_root(context.bufnr, context.cwd)
  local effective, err = state.resolve_effective(project_root, fallback_default_adapter())
  if not effective then
    if err then
      vim.notify("读取项目默认 adapter 失败，使用 Maxa AI fallback: " .. tostring(err), vim.log.levels.WARN)
    end
    return nil
  end
  local ok, adapter = pcall(adapters.resolve, { name = effective.adapter, model = effective.model })
  if ok then
    return adapter
  end
  vim.notify("解析项目默认 adapter 失败，使用 Maxa AI fallback: " .. tostring(adapter), vim.log.levels.WARN)
  return nil
end

local function intro_message(chat)
  local current = runtime_state.current_context or vim.api.nvim_get_current_buf()
  local project_root = vim.fs.root(current, { ".maxa", ".git", ".svn", ".hg" })
    or vim.uv.cwd()
    or vim.fn.getcwd(-1, -1)
  local adapter = chat and chat.adapter or {}
  local model = adapter.model and adapter.model.name
    or (adapter.schema and adapter.schema.model and adapter.schema.model.default)
    or "未知"
  return "📁 项目根目录: " .. project_root
    .. "\n\n🤖 服务商: " .. (adapter.formatted_name or adapter.name or "未知")
    .. "\n🎯 模型: " .. tostring(model)
end

function Chat.new(args)
  args = args or {}
  args.buffer_context = args.buffer_context or {}
  if type(args.buffer_context.bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(args.buffer_context.bufnr) then
    local current_bufnr = vim.api.nvim_get_current_buf()
    local ok_context, current_context = pcall(require("maxa.utils.context").get, current_bufnr)
    if ok_context and type(current_context) == "table" then
      args.buffer_context = vim.tbl_extend("keep", args.buffer_context, current_context)
    else
      args.buffer_context.bufnr = current_bufnr
    end
  end

  -- Snapshot project location when the Chat is created. Builtins consume this
  -- Chat-owned state later instead of consulting whichever window/cwd happens
  -- to be current when a tool callback runs.
  local context_bufnr = args.buffer_context.bufnr
  local context_winid = type(context_bufnr) == "number" and vim.fn.bufwinid(context_bufnr) or -1
  args.cwd = args.cwd or args.buffer_context.cwd
  if type(args.cwd) ~= "string" or args.cwd == "" then
    args.cwd = context_winid ~= -1 and vim.fn.getcwd(context_winid) or vim.fn.getcwd()
  end
  if type(args.cwd) ~= "string" or args.cwd == "" then
    args.cwd = (vim.uv and vim.uv.cwd()) or vim.fn.getcwd(-1, -1)
  end

  args.project_root = args.project_root
    or args.buffer_context.project_root
    or (type(context_bufnr) == "number" and vim.api.nvim_buf_is_valid(context_bufnr)
        and vim.fs.root(context_bufnr, { ".maxa", ".git", ".svn", ".hg" }))
    or (args.cwd and vim.fs.root(args.cwd, { ".maxa", ".git", ".svn", ".hg" }))
  args.buffer_context.cwd = args.buffer_context.cwd or args.cwd
  args.buffer_context.project_root = args.buffer_context.project_root or args.project_root
  require("maxa.prompts.sources").get({ project_root = args.project_root, cwd = args.cwd })

  -- Only fresh main Chats load the single project-owned rule file.
  local project_rules
  if not args.ignore_system_prompt and not args._history_restored and args.project_root then
    local path = vim.fs.joinpath(args.project_root, ".maxa", "AGENTS.md")
    if vim.uv.fs_lstat(path) then
      local ok, lines = pcall(vim.fn.readfile, path)
      if not ok then
        error("Cannot read project rules " .. path .. ": " .. tostring(lines))
      end
      project_rules = { path = path, content = table.concat(lines, "\n") }
    end
  end

  args.adapter = resolve_project_adapter(args)
  local id = math.random(10000000)
  log:trace("Chat created with ID %d", id)

  local self = setmetatable({
    buffer_context = args.buffer_context,
    callbacks = {},
    context_items = {},
    cycle = 1,
    header_line = 1,
    from_prompt_library = args.from_prompt_library or false,
    id = id,
    intro_message = args.intro_message or config.display.chat.intro_message,
    messages = args.messages or {},
    opts = args,
    status = "",
    title = args.title or nil,
    create_buf = function()
      local bufnr = api.nvim_create_buf(config.display.chat.window.buflisted, true)
      api.nvim_buf_set_name(bufnr, fmt("[Maxa AI] %d", bufnr))

      -- Safely attach treesitter
      vim.schedule(function()
        pcall(vim.treesitter.start, bufnr)
      end)

      -- Set up omnifunc for automatic completion when no other completion provider is active
      local completion_provider = config.interactions.chat.opts.completion_provider
      if completion_provider == "default" then
        vim.bo[bufnr].omnifunc = "v:lua.require'maxa.providers.completion.default.omnifunc'.omnifunc"
      end

      return bufnr
    end,
    _last_role = args.last_role or config.constants.USER_ROLE,
  }, { __index = Chat })
  ---@cast self MaxaAI.Chat

  agent_identity.initialize(self, args)
  self.bufnr = self.create_buf()
  self.aug = api.nvim_create_augroup(CONSTANTS.AUTOCMD_GROUP .. ":" .. self.bufnr, {
    clear = false,
  })

  -- NOTE: Put the parser on the chat buffer for performance reasons
  local ok, chat_parser
  ok, chat_parser = pcall(vim.treesitter.get_parser, self.bufnr, "markdown")
  if not ok then
    return log:error("[chat::init::new] Could not find the Markdown Tree-sitter parser")
  end
  self.chat_parser = chat_parser

  table.insert(runtime_state.buffers, self.bufnr)
  chatmap[self.bufnr] = {
    name = "Chat " .. vim.tbl_count(chatmap) + 1,
    description = CONSTANTS.BLANK_DESC,
    interaction = "chat",
    chat = self,
  }

  if args.adapter and adapters.resolved(args.adapter) then
    self.adapter = args.adapter
  else
    self.adapter = adapters.resolve(args.adapter or config.interactions.chat.adapter)
  end
  if not self.adapter then
    return log:error("No adapter found")
  end
  if not args.intro_message then
    self.intro_message = intro_message(self)
  end
  utils.fire("ChatAdapter", {
    adapter = adapters.make_safe(self.adapter),
    bufnr = self.bufnr,
    id = self.id,
  })
  utils.fire("ChatModel", {
    adapter = adapters.make_safe(self.adapter),
    bufnr = self.bufnr,
    id = self.id,
    model = self.adapter.schema and self.adapter.schema.model.default,
  })

  self:apply_settings(schema.get_default(self.adapter, args.settings))

  -- Initialize components
  self.builder = require("maxa.interactions.chat.ui.builder").new({ chat = self })
  self.context = require("maxa.interactions.chat.context").new({ chat = self })
  self.tools = require("maxa.interactions.chat.tools").new({
    adapter = self.adapter,
    bufnr = self.bufnr,
    messages = self.messages,
  })
  self.tool_registry = require("maxa.interactions.chat.tool_registry").new({ chat = self })

  self.ui = require("maxa.interactions.chat.ui").new({
    chat = self,
    adapter = self.adapter,
    aug = self.aug,
    chat_id = self.id,
    chat_bufnr = self.bufnr,
    roles = { user = user_role, llm = llm_role },
    window_opts = args.window_opts,
  })

  self:update_metadata()

  -- Likely this hasn't been set by the time the user opens the chat buffer
  if not runtime_state.current_context then
    runtime_state.current_context = self.buffer_context.bufnr
  end

  if args.messages then
    self.messages = args.messages
  end

  if not agent_identity.is_subagent(self) and not args.preserve_main then self.close_last_chat() end
  if not args.headless then self.ui:open() end
  self.ui:render(self.buffer_context, self.messages, { stop_context_insertion = args.stop_context_insertion })

  -- Set the header line for the chat buffer
  if args.messages and vim.tbl_count(args.messages) > 0 then
    local header_line = parser.headers(self, self.chat_parser)
    self.header_line = header_line and (header_line + 1) or 1
  end

  if vim.tbl_isempty(self.messages) or not helpers.has_user_messages(args.messages) then
    self.ui:set_intro_msg(self.intro_message)
  end

  if config.interactions.chat.keymaps then
    -- Filter out any private keymaps
    local filtered_keymaps = {}
    for k, v in pairs(config.interactions.chat.keymaps) do
      if k:sub(1, 1) ~= "_" then
        filtered_keymaps[k] = v
      end
    end

    keymaps
      .new({
        bufnr = self.bufnr,
        callbacks = require("maxa.interactions.chat.keymaps"),
        data = self,
        keymaps = filtered_keymaps,
      })
      :set()
  end

  local slash_command_keymaps = helpers.slash_command_keymaps(config.interactions.chat.slash_commands)
  if vim.tbl_count(slash_command_keymaps) > 0 then
    keymaps
      .new({
        bufnr = self.bufnr,
        callbacks = require("maxa.interactions.chat.slash_commands.keymaps"),
        data = self,
        keymaps = slash_command_keymaps,
      })
      :set()
  end

  ---@cast self MaxaAI.Chat
  self:set_system_prompt()
  if project_rules and project_rules.content ~= "" then
    local id = "<rules>" .. project_rules.path .. "</rules>"
    self:add_context({ content = project_rules.content }, "rules", id, { path = project_rules.path })
    -- Keep the initial system block contiguous even when a prompt library provided user messages.
    local rule_message = table.remove(self.messages)
    local index = 1
    while self.messages[index] and self.messages[index].role == config.constants.SYSTEM_ROLE do
      index = index + 1
    end
    table.insert(self.messages, index, rule_message)
  end
  set_autocmds(self)

  if not args.headless then last_chat = self end
  if agent_identity.is_main(self) and not args.preserve_main then last_main_chat = self end

  for _, tool_name in ipairs(config.interactions.chat.tools.opts.default_tools or {}) do
    local tool_config = config.interactions.chat.tools[tool_name]
    if tool_name ~= "groups" and tool_name ~= "opts" and tool_config ~= nil then
      self.tool_registry:add(tool_name, tool_config)
    end
  end

  -- Handle callbacks
  if args.callbacks then
    for event, callback_list in pairs(args.callbacks) do
      if type(callback_list) == "function" then
        -- Single callback
        self:add_callback(event, callback_list)
      elseif type(callback_list) == "table" then
        -- Array of callbacks
        for _, callback in ipairs(callback_list) do
          self:add_callback(event, callback)
        end
      end
    end
  end

  self:dispatch("on_created")

  utils.fire("ChatCreated", { bufnr = self.bufnr, from_prompt_library = self.from_prompt_library, id = self.id })
  if args.auto_submit then
    self:submit()
  end

  return self ---@type MaxaAI.Chat
end

---Add a callback for a specific event
---@param event string The event name
---@param callback fun(chat: MaxaAI.Chat) The callback function
---@return MaxaAI.Chat
function Chat:add_callback(event, callback)
  if not self.callbacks[event] then
    self.callbacks[event] = {}
  end
  if type(callback) == "function" then
    table.insert(self.callbacks[event], callback)
  end
  return self
end

---Dispatch callbacks for a specific event
---@param event string The event name
---@param ... any Additional arguments to pass to callbacks
---@return MaxaAI.Chat
function Chat:dispatch(event, ...)
  local callbacks = self.callbacks[event]
  if not callbacks then
    return self
  end

  for _, callback in ipairs(callbacks) do
    local ok, err = pcall(callback, self, ...)
    if not ok then
      log:error("Callback error for %s: %s", event, err, { silent = true })
    end
  end
  return self
end

---Format and apply settings to the chat buffer
---@param settings? table
---@return MaxaAI.Chat
function Chat:apply_settings(settings)
  self.settings = settings or schema.get_default(self.adapter)
  return self
end

---Change the adapter in the chat buffer
---@param adapter string
function Chat:change_adapter(adapter)
  local function fire()
    return utils.fire("ChatAdapter", { bufnr = self.bufnr, adapter = adapters.make_safe(self.adapter) })
  end

  self.adapter = require("maxa.adapters").resolve(adapter)
  self.ui.adapter = self.adapter

  self:update_metadata()
  self:apply_settings()
  self.intro_message = intro_message(self)
  if self.ui and self.ui.set_intro_msg then
    self.ui:set_intro_msg(self.intro_message)
  end
  fire()
end

---Set a model in the chat buffer
---@param args { model?: string }
---@return MaxaAI.Chat
function Chat:change_model(args)
  self.settings.model = args.model
  self.adapter.schema.model.default = args.model
  self.adapter = adapters.set_model({ adapter = self.adapter, model = args.model })

  self:apply_settings()

  self:update_metadata()
  utils.fire("ChatModel", {
    adapter = adapters.make_safe(self.adapter),
    bufnr = self.bufnr,
    model = args.model,
  })

  return self
end

---@class MaxaAI.SystemPrompt.Context
---@field language string
---@field adapter MaxaAI.HTTPAdapter
---@field date string
---@field nvim_version string
---@field os string the operating system that the user is using
---@field default_system_prompt string
---@field cwd string current working directory
---@field project_root? string The closest parent directory that contains `.maxa`, `.git`, `.svn`, or `.hg`

---@return MaxaAI.SystemPrompt.Context
function Chat:make_system_prompt_ctx()
  ---@type table<string, fun(_chat: MaxaAI.Chat):any>
  local dynamic_ctx = {
    -- These can be slow-to-run or too complex for a one-liner. So wrap them in
    -- functions and use a metatable to handle the eval when needed.
    adapter = function()
      return vim.deepcopy(self.adapter)
    end,
    os = function()
      local machine = vim.uv.os_uname().sysname
      if machine == "Darwin" then
        machine = "Mac"
      end
      if machine:find("Windows") then
        machine = "Windows"
      end
      return machine
    end,
  }

  local bufnr = self.bufnr
  local winid = vim.fn.bufwinid(bufnr)
  local static_ctx = { ---@type MaxaAI.SystemPrompt.Context|{}
    language = config.opts.language or "English",
    date = tostring(os.date("%Y-%m-%d")),
    nvim_version = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
    cwd = self.opts.cwd or vim.fn.getcwd(winid ~= -1 and winid or nil),
    project_root = self.opts.project_root or vim.fs.root(bufnr, { ".maxa", ".git", ".svn", ".hg" }),
    default_system_prompt = CONSTANTS.SYSTEM_PROMPT,
  }

  ---@type MaxaAI.SystemPrompt.Context
  return setmetatable(static_ctx, {
    __index = function(_, key)
      local val = dynamic_ctx[key]
      if type(val) == "function" then
        return val()
      end
      return val
    end,
  })
end

---Set the system prompt in the chat buffer
---@param prompt? string
---@param opts? {opts: table, _meta: table, index?: number}
---@return MaxaAI.Chat
function Chat:set_system_prompt(prompt, opts)
  if self.opts and self.opts.ignore_system_prompt then
    return self
  end

  prompt = prompt or config.interactions.chat.opts.system_prompt
  opts = opts or { visible = false }

  local _meta = { tag = "system_prompt_from_config" }
  if opts._meta then
    _meta = opts._meta
    opts._meta = nil
  end

  if type(prompt) == "function" then
    prompt = prompt(self:make_system_prompt_ctx())
  end

  local parts
  if type(prompt) == "table" then
    if type(prompt.runtime) ~= "string" or prompt.runtime == ""
      or type(prompt.soul) ~= "string" or vim.trim(prompt.soul) == "" then
      error("system_prompt must contain nonempty runtime and soul strings")
    end
    parts = {
      { content = prompt.runtime, tag = _meta.tag },
      { content = prompt.soul, tag = "soul_prompt_from_config" },
    }
  elseif prompt ~= "" then
    parts = { { content = prompt, tag = _meta.tag } }
  end

  -- Replace both halves together, including when changing back to a legacy string.
  if _meta.tag == "system_prompt_from_config" then
    self:remove_tagged_message("soul_prompt_from_config")
  end
  self:remove_tagged_message(_meta.tag)

  for offset, part in ipairs(parts or {}) do
    local index = opts.index and opts.index + offset - 1
    if not index then
      for i = #self.messages, 1, -1 do
        if self.messages[i].role == config.constants.SYSTEM_ROLE then
          index = i + 1
          break
        end
      end
    end
    local system_prompt = {
      role = config.constants.SYSTEM_ROLE,
      content = part.content,
      opts = vim.deepcopy(opts),
    }
    local meta = vim.deepcopy(_meta)
    meta.tag = part.tag
    meta.cycle = self.cycle
    meta.id = make_id(system_prompt)
    meta.index = #self.messages + 1
    system_prompt._meta = meta
    table.insert(self.messages, index or 1, system_prompt)
  end

  return self
end

---Replace only the effective Soul in the initial system prefix.
---@param content string Complete selected Soul
---@return boolean, string|nil
function Chat:replace_soul(content)
  if self.current_request then
    return false, "Cannot change Soul while a Chat request is in progress"
  end
  if type(content) ~= "string" or vim.trim(content) == "" then
    return false, "Selected Soul is empty"
  end

  local runtime_index, soul_index, prefix_end
  for i, msg in ipairs(self.messages) do
    if msg.role ~= config.constants.SYSTEM_ROLE then
      break
    end
    prefix_end = i
    local tag = msg._meta and msg._meta.tag
    if tag == "system_prompt_from_config" then
      if runtime_index then return false, "Ambiguous Runtime messages; Soul unchanged" end
      runtime_index = i
    elseif tag == "soul_prompt_from_config" then
      if soul_index then return false, "Ambiguous Soul messages; Soul unchanged" end
      soul_index = i
    end
  end
  if not runtime_index then
    return false, "Cannot identify the Chat Runtime; Soul unchanged"
  end

  local replacement
  if soul_index then
    if soul_index ~= runtime_index + 1 then
      return false, "Soul is not adjacent to Runtime; Soul unchanged"
    end
    replacement = vim.deepcopy(self.messages[soul_index])
    replacement.content = content
    replacement._meta.id = make_id(replacement)
    self.messages[soul_index] = replacement
    return true
  end

  -- Migrate only a recognizable legacy default composition. Never guess a
  -- boundary inside a custom system prompt or a project-specific Soul.
  if prefix_end ~= runtime_index then
    return false, "Cannot safely split legacy system messages; Soul unchanged"
  end
  local old = self.messages[runtime_index]
  local divider = "\n\n---\n\n"
  local marker = divider .. "# Maxa Soul"
  local boundary = type(old.content) == "string" and old.content:find(marker, 1, true)
  local runtime = boundary and old.content:sub(1, boundary - 1)
  if not runtime or not vim.startswith(runtime, "# Maxa Runtime Contract")
    or old.content:find(marker, boundary + #marker, true) then
    return false, "Cannot safely split legacy system prompt; Soul unchanged"
  end
  local runtime_message = vim.deepcopy(old)
  runtime_message.content = runtime
  runtime_message._meta.id = make_id(runtime_message)
  replacement = vim.deepcopy(old)
  replacement.content = content
  replacement._meta.tag = "soul_prompt_from_config"
  replacement._meta.id = make_id(replacement)
  self.messages[runtime_index] = runtime_message
  table.insert(self.messages, runtime_index + 1, replacement)
  return true
end

---Remove a message with a given tag
---@param tag string
---@return nil
function Chat:remove_tagged_message(tag)
  self.messages = vim
    .iter(self.messages)
    :filter(function(msg)
      if msg._meta and msg._meta.tag == tag then
        return false
      end
      return true
    end)
    :totable()
end

---Add a message to the message table
---@param data { role: string, content: string, reasoning?: MaxaAI.Chat.Reasoning, tool_calls?: MaxaAI.Chat.ToolCall[] }
---@param opts? table Options for the message
---@return MaxaAI.Chat
function Chat:add_message(data, opts)
  data, opts = require("maxa.lifecycle.chat_submitted_event").normalize_message(self, data, opts)
  opts = opts or { visible = true }
  if opts.visible == nil then
    opts.visible = true
  end

  ---@type MaxaAI.Chat.Message
  local message = {
    role = data.role,
    content = data.content,
    reasoning = data.reasoning,
    _meta = { id = 1, cycle = self.cycle },
  }

  -- Map tool_calls to tools.calls
  if data.tool_calls then
    message.tools = message.tools or {}
    message.tools.calls = data.tool_calls
  end

  if opts._meta then
    message._meta = vim.tbl_deep_extend("force", message._meta, opts._meta)
    opts._meta = nil
  end
  if opts.context then
    message.context = opts.context
    opts.context = nil
  end

  message.opts = opts
  message._meta.id = make_id(message)
  message._meta.index = #self.messages + 1

  if opts.index then
    table.insert(self.messages, opts.index, message)
  else
    table.insert(self.messages, message)
  end

  local usage = package.loaded["maxa.session.token_usage"]
  if usage then usage.notify(self) end
  return self
end

---Add an image to the chat buffer
---@param image MaxaAI.Image The image object containing the path and other metadata
---@param opts? {role?: "user"|string, source?: string, bufnr?: integer} Options for adding the image
---@return nil
function Chat:add_image_message(image, opts)
  opts = vim.tbl_deep_extend("force", {
    role = config.constants.USER_ROLE,
    source = "maxa.interactions.chat.slash_commands.image",
    bufnr = image.bufnr,
  }, opts or {})

  local id = "<image>" .. (image.id or image.path) .. "</image>"

  self:add_message({
    role = opts.role,
    content = image.base64,
  }, {
    context = { id = id, mimetype = image.mimetype, path = image.path or image.id },
    _meta = { tag = "image" },
    visible = false,
  })

  self.context:add({
    bufnr = opts.bufnr,
    id = id,
    path = image.path,
    source = opts.source,
  })
end

---Make a request to the LLM using the HTTP client
---@param payload table The payload to send to the LLM
---@return nil
function Chat:_submit_http(payload)
  if not chat_is_live(self) then
    return nil
  end
  local threshold = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
  local allowed, dispatch_token = true, nil
  if threshold and threshold.before_dispatch then
    allowed, dispatch_token = threshold.before_dispatch(self, "_submit_http")
  end
  if not allowed then
    return nil
  end
  local adapter = self.adapter ---@cast adapter MaxaAI.HTTPAdapter
  require("maxa.lifecycle.chat_response_started_event").reset(self)
  adapter._maxa_stream_chat_bufnr = self.bufnr
  adapter._maxa_stream_chat_id = self.id

  local mapped_settings = adapter:map_schema_to_params(self.settings)
  log:trace("Settings:\n%s", mapped_settings)

  local output, reasoning, tools, meta = {}, {}, {}, {}
  local completed = false
  local watchdog = require("maxa.lifecycle.chat_request_watchdog")
  local handle
  local function finish_request(...)
    if completed then
      return
    end
    -- A protocol error may finish before the HTTP transport's on_done callback.
    completed = true
    watchdog.finish(self, handle and handle.id)
    if self.status == CONSTANTS.STATUS_ERROR and handle and handle.cancel then handle.cancel() end
    return self:done(...)
  end

  local function process_chunk(data)
    if completed or not chat_is_live(self) then
      return
    end
    if adapter.features.tokens then
      local tokens = adapters.call_handler(adapter, "parse_tokens", data)
      if tokens then
        self.ui.tokens = tokens
        local usage = package.loaded["maxa.session.token_usage"]
        if usage then usage.notify(self) end
      end
    end

    local result = adapters.call_handler(adapter, "parse_chat", data, tools)
    -- TODO: Rename this to be `parse_extra` for clarity
    local parse_meta = adapters.get_handler(adapter, "parse_meta")
    if result and result.extra and type(parse_meta) == "function" then
      result = parse_meta(adapter, result)
    end

    if result and result.status then
      self.status = result.status
      if self.status == CONSTANTS.STATUS_SUCCESS then
        if result.output.role then
          result.output.role = config.constants.LLM_ROLE
          self._last_role = result.output.role
        end
        if result.output.reasoning then
          table.insert(reasoning, result.output.reasoning)
          if config.display.chat.show_reasoning and result.output.reasoning.content then
            self:add_buf_message({
              role = config.constants.LLM_ROLE,
              content = result.output.reasoning.content,
            }, { type = self.MESSAGE_TYPES.REASONING_MESSAGE, _message_stream = true })
          end
        end
        if result.output.meta then
          meta = vim.tbl_deep_extend("force", meta, result.output.meta)
        end
        table.insert(output, result.output.content)
        self:add_buf_message({
          role = config.constants.LLM_ROLE,
          content = result.output.content,
        }, { type = self.MESSAGE_TYPES.LLM_MESSAGE, _message_stream = true })
      elseif self.status == CONSTANTS.STATUS_ERROR then
        log:error("[chat::_submit_http] Error: %s", result.output)
        finish_request(output)
      end
    end
  end

  handle = get_client(adapter).new({ adapter = mapped_settings }):send(payload, {
    on_progress = function(observation, request)
      if not completed then watchdog.observe(self, request.id, observation) end
    end,
    on_metrics = function(sample)
      require("maxa.adapters.metrics").record_turn(self, sample)
    end,
    on_chunk = function(data)
      process_chunk(data)
    end,
    on_done = function(data)
      if completed or not chat_is_live(self) then
        return
      end
      if data and not adapter.opts.stream then
        process_chunk(data)
      end
      finish_request(output, reasoning, tools, meta)
    end,
    on_error = function(err)
      if completed or not chat_is_live(self) or self.status == CONSTANTS.STATUS_CANCELLING then
        return
      end
      self.status = CONSTANTS.STATUS_ERROR
      log:error("[chat::_submit_http] Error: %s", (err and (err.stderr or err.message)) or "unknown")
      finish_request(output)
    end,
    bufnr = self.bufnr,
    interaction = "chat",
  })

  if not completed then
    self.current_request = handle
    watchdog.start(self, handle, config.runtime().lifecycle.watchdog)
  end
  if threshold and threshold.after_dispatch then
    return threshold.after_dispatch(self, dispatch_token, true, handle)
  end
  return handle
end

---Submit the chat buffer's contents to the LLM
---@param opts? table
---@return nil
function Chat:submit(opts)
  if not chat_is_live(self) then
    return nil
  end
  require("maxa.interactions.chat.snippets").stop(self.bufnr)
  opts = opts or {}
  if self._slash_load then
    return log:warn("Wait for /load to finish before submitting")
  end
  if require("maxa.interactions.chat.tools.input").submit(self, opts) then
    return nil
  end
  require("maxa.interactions.chat.tools.builtin.runtime.ttl_result").before_chat_submit(self)
  local soft_stop = package.loaded["maxa.lifecycle.chat_soft_stop"]
  if soft_stop and soft_stop.before_submit and not soft_stop.before_submit(self, opts) then
    return nil
  end
  local context_stop = require("maxa.lifecycle.chat_context_limit_stop")
  if context_stop.before_submit and not context_stop.before_submit(self, opts) then
    return nil
  end
  if not require("maxa.lifecycle.chat_submitted_event").before_submit(self, opts) then
    return nil
  end
  if self.current_request then
    return log:debug("Chat request already in progress")
  end
  if not opts.auto_submit then self._subagent_interrupted = false end

  if opts.callback then
    opts.callback()
  end

  -- Refresh tools before submitting to pick up any dynamically added tools
  if self.adapter.type == "http" then
    self.tools:refresh({ adapter = self.adapter })
  end

  local added_user_message = false
  local rewind_reply_content
  if not opts.auto_submit then
    local reply = self._session_rewind_reply
    local message_to_submit = not reply and parser.messages(self, self.header_line) or nil
    if reply then
      if type(reply.input_row) ~= "number" or opts.regenerate then
        return log:warn("Rewound ask reply is not ready to submit")
      end
      rewind_reply_content = table.concat(api.nvim_buf_get_lines(self.bufnr, reply.input_row, -1, false), "\n")
      local ok, err = require("maxa.session.slash_commands.chat_fork_utils")
        .commit_rewind_reply(self, rewind_reply_content)
      if not ok then return log:warn(err) end
      if self.ui and self.ui.message_provenance then
        local last_row = api.nvim_buf_line_count(self.bufnr) - 1
        local last_text = api.nvim_buf_get_lines(self.bufnr, last_row, last_row + 1, false)[1] or ""
        self.ui.message_provenance:mark(reply.input_row, 0, last_row, #last_text,
          { call_id = reply.call_id, phase = "result", fragment = 1 })
      end
    end
    if not reply and not message_to_submit and not helpers.has_user_messages(self.messages) then
      return log:warn("No messages to submit")
    end

    -- Allow users to send a blank message to the LLM
    if not opts.regenerate and not reply then
      local chat_opts = config.interactions.chat.opts
      if message_to_submit and message_to_submit.content and chat_opts and chat_opts.prompt_decorator then
        message_to_submit.content =
          chat_opts.prompt_decorator(message_to_submit.content, adapters.make_safe(self.adapter), self.buffer_context)
      end
      self:add_message({
        role = config.constants.USER_ROLE,
        content = (message_to_submit and message_to_submit.content or config.interactions.chat.opts.blank_prompt),
      })
      added_user_message = true
      -- The user typed directly into the editable buffer; mark that committed
      -- text after insertion into the canonical message list.
      if message_to_submit and self.ui and self.ui.message_provenance then
        local start_row = math.max(0, self.header_line + 1)
        local last_row = api.nvim_buf_line_count(self.bufnr) - 1
        if start_row <= last_row then
          local last_text = api.nvim_buf_get_lines(self.bufnr, last_row, last_row + 1, false)[1] or ""
          self.ui.message_provenance:mark(start_row, 0, last_row, #last_text, self.messages[#self.messages])
        end
      end
    end

    -- Check if the user has manually overridden the adapter
    if vim.g.maxa_ai_adapter and self.adapter.name ~= vim.g.maxa_ai_adapter then
      self.adapter = adapters.resolve(config.adapters[vim.g.maxa_ai_adapter])
    end

    if not config.display.chat.auto_scroll then
      vim.cmd("stopinsert")
    end
    self.ui:lock_buf()
    set_text_editing_area(self, 2) -- this accounts for the LLM header
  end

  local payload = {
    messages = self.adapter:map_roles(vim.deepcopy(self.messages)),
    tools = (not vim.tbl_isempty(self.tool_registry.schemas) and { self.tool_registry.schemas } or {}),
  }

  log:trace("Messages:\n%s", payload.messages)
  log:trace("Tools:\n%s", payload.tools)
  log:info("Chat request started")

  self:dispatch("on_submitted", { payload = payload })

  if not opts.auto_submit or not self._request_metrics then require("maxa.adapters.metrics").start_turn(self) end
  local handle = self:_submit_http(payload)
  if handle and (added_user_message or rewind_reply_content ~= nil) then
    self._session_rewind_pending = nil
    self._session_rewind_reply = nil
  elseif not handle and rewind_reply_content ~= nil then
    require("maxa.session.slash_commands.chat_fork_utils").restore_rewind_reply_input(self, rewind_reply_content)
  end

  utils.fire("ChatSubmitted", {
    bufnr = self.bufnr,
    id = self.id,
    type = self.adapter.type,
    is_user_input = handle ~= nil and (added_user_message or rewind_reply_content ~= nil),
  })
end

---Method to fire when all the tools are done
---@param opts? table
---@return nil
function Chat:tools_done(opts)
  opts = opts or {}
  local soft_stop = require("maxa.lifecycle.chat_soft_stop")
  local converted, finalize_soft_stop = soft_stop.before_tools_done(self, opts)
  converted = require("maxa.lifecycle.chat_context_limit_stop").before_tools_done(self, converted)
  local result = ready_chat_buffer(self, converted)
  soft_stop.after_tools_done(self, finalize_soft_stop)
  return result
end

---Label messages that have been sent to the LLM, by the user. For adapters that
---store state on our behalf, this prevents us from sending the same message
---multiple times.
---@return nil
function Chat:label_sent_items()
  vim.iter(self.messages):each(function(msg)
    if msg.role == config.constants.USER_ROLE and (msg._meta and not msg._meta.sent) then
      msg._meta.sent = true
    end
  end)
end

---Method to call after the response from the LLM is received
---@param output? table The message output from the LLM
---@param reasoning? table The reasoning output from the LLM
---@param tools? table The tools output from the LLM
---@param meta? table Any metadata from the LLM
---@param opts? {status: "stopped"} The reason the done method was called
---@return nil
function Chat:done(output, reasoning, tools, meta, opts)
  if not chat_is_live(self) then
    return
  end
  opts = opts or {}
  local threshold = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
  local threshold_state, reset_only
  if threshold and threshold.before_done then
    threshold_state, reset_only = threshold.before_done(self)
  end
  self.current_request = nil

  -- Commonly, a status may not be set if the message exceeds a token limit
  if not self.status or self.status == "" then
    self._display_output_ranges = nil
    local result = self:reset()
    if threshold and threshold.after_done then
      threshold.after_done(self, threshold_state, reset_only)
    end
    return result
  end
  local has_output = output and not vim.tbl_isempty(output)
  local has_tools = tools and not vim.tbl_isempty(tools)
  local has_meta = meta and not vim.tbl_isempty(meta)

  local content, output_message
  if has_output then
    content = vim.trim(table.concat(output or {}, ""))
  end

  local reasoning_content = nil
  if reasoning and not vim.tbl_isempty(reasoning) then
    if vim.iter(reasoning):any(function(item)
      return item and type(item) ~= "string"
    end) then
      reasoning_content = adapters.call_handler(self.adapter, "build_reasoning", reasoning)
    else
      reasoning_content = table.concat(reasoning, "")
    end
  end

  if content and content ~= "" then
    agent_identity.touch_dialogue(self)
    local message = {
      role = config.constants.LLM_ROLE,
      content = content,
      reasoning = reasoning_content,
    }
    self:add_message(message, {
      _meta = has_meta and meta or nil,
    })
    output_message = self.messages[#self.messages]
    require("maxa.session.file_links").track(self, output_message, self._display_output_ranges)
    if self._display_output_ranges then
      local source = self.messages[#self.messages]
      for _, range in ipairs(self._display_output_ranges) do
        self.ui.message_provenance:mark(range[1], range[2], range[3], range[4], source)
      end
    end
    reasoning_content = nil
  end

  -- If a user stops the request, we should be prepared to send the last message
  -- again as we can't be sure what the LLM had actually received
  if not opts.status or opts.status ~= "stopped" then
    self:label_sent_items()
  end

  -- Process tools last
  if has_tools then
    tools = adapters.call_handler(self.adapter, "format_calls", tools)
    if tools then
      local validation_plan = require("maxa.interactions.chat.tools.validator").classify_batch(self.tools, self, tools)
      if #validation_plan.history_calls > 0 or reasoning_content ~= nil then
        local message = {
          role = config.constants.LLM_ROLE,
          reasoning = reasoning_content,
          tool_calls = #validation_plan.history_calls > 0 and validation_plan.history_calls or nil,
          _meta = has_meta and meta or nil,
        }
        self:add_message(message, {
          visible = false,
        })
        if self._display_output_ranges then
          for _, range in ipairs(self._display_output_ranges) do
            self.ui.message_provenance:mark(range[1], range[2], range[3], range[4], self.messages[#self.messages])
          end
        end
      end
      self._display_output_ranges = nil
      return self.tools:execute(self, validation_plan, { model_batch = true })
    end
  end

  self._display_output_ranges = nil
  ready_chat_buffer(self)
  require("maxa.session.file_links").present(self, output_message)

  self:dispatch("on_completed", { status = self.status })
  utils.fire("ChatDone", { bufnr = self.bufnr, id = self.id })
  if threshold and threshold.after_done then
    threshold.after_done(self, threshold_state, reset_only)
  end
end

---Add context to the chat buffer (Useful for user's adding custom Slash Commands)
---@param data { role?: string, content: string }
---@param source string The source of the context
---@param id string The uniqie ID linkin the context to the message
---@param opts? { bufnr: number, context_opts: table, path: string, tag: string, visible: boolean}
function Chat:add_context(data, source, id, opts)
  opts = vim.tbl_extend("force", { visible = false }, opts or {})

  local message = {
    role = data.role or config.constants.USER_ROLE,
    content = data.content,
  }

  -- Context is created by adding it to the context class and linking it to a message on the chat buffer
  self.context:add({ source = source, id = id, bufnr = opts.bufnr, path = opts.path, opts = opts.context_opts })
  self:add_message(message, { visible = opts.visible, context = { id = id }, _meta = { tag = opts.tag or source } })
end

---Regenerate the response from the LLM
---@return nil
function Chat:regenerate()
  if self.messages[#self.messages].role == config.constants.LLM_ROLE then
    table.remove(self.messages, #self.messages)
    self:add_buf_message({ role = config.constants.USER_ROLE, content = "_Regenerating response..._" })
    self:submit({ regenerate = true })
  end
end

---Interrupt active work while retaining a manually resumable Chat/executor.
function Chat:interrupt()
  if self._slash_load then return self._slash_load.cancel("/load cancelled") end
  if not self.current_request and not self.current_tool and not self._tool_input then return end
  local soft_stop = require("maxa.lifecycle.chat_soft_stop")
  soft_stop.latch(self)
  self._subagent_interrupted = true
  self:stop({ interrupted = true })
  soft_stop.latch(self)
end

---Stop streaming the response from the LLM; explicit interruption keeps children alive.
---@param opts? {interrupted?: boolean}
---@return nil
function Chat:stop(opts)
  if self._slash_load then return self._slash_load.cancel("/load cancelled") end
  if self.status == CONSTANTS.STATUS_CANCELLING then return end
  if not (opts and opts.interrupted) then self._subagent_interrupted = false end
  self.status = CONSTANTS.STATUS_CANCELLING
  -- Latch/settle the owning batch before input callbacks can resume its queue.
  if self.current_tool then
    local tool_job = self.current_tool
    self.current_tool = nil
    pcall(function()
      tool_job.cancel("tool input cancelled")
    end)
  end
  require("maxa.interactions.chat.tools.input").cancel(self, "tool input cancelled")
  self:dispatch("on_cancelled")
  utils.fire("ChatStopped", { bufnr = self.bufnr, id = self.id })

  if self.current_request then
    local handle = self.current_request
    self.current_request = nil
    require("maxa.lifecycle.chat_request_watchdog").finish(self, handle.id)

    pcall(function()
      if handle and type(handle.cancel) == "function" then
        handle.cancel()
      end
    end)

    adapters.call_handler(self.adapter, "on_exit")
  end

  vim.schedule(function()
    log:debug("Chat request cancelled")
    self:done(nil, nil, nil, nil, { status = "stopped" })
  end)
end

---Close the current chat buffer and clean up any resources
---@return nil
function Chat:close()
  if self._closed then return end
  require("maxa.interactions.chat.snippets").stop(self.bufnr)
  self._closed = true
  require("maxa.lifecycle.chat_request_watchdog").finish(self)
  require("maxa.interactions.chat.tools.input").cancel(self, "caller Chat was destroyed")
  if self.current_request or self.current_tool or self._tool_input then
    self:stop()
  end

  self:dispatch("on_closed")
  agent_identity.release(self)
  if last_main_chat == self then last_main_chat = nil end

  if last_chat and last_chat.bufnr == self.bufnr then
    last_chat = nil
  end

  utils.fire("ChatClosed", { bufnr = self.bufnr, id = self.id })
  utils.fire("ChatAdapter", { bufnr = self.bufnr, id = self.id, adapter = nil })
  utils.fire("ChatModel", { bufnr = self.bufnr, id = self.id, model = nil })

  table.remove(
    runtime_state.buffers,
    vim.iter(runtime_state.buffers):enumerate():find(function(_, v)
      return v == self.bufnr
    end)
  )
  table.remove(
    runtime_state.chat_metadata,
    vim.iter(runtime_state.chat_metadata):enumerate():find(function(_, v)
      return v == self.bufnr
    end)
  )
  chatmap[self.bufnr] = nil
  pcall(api.nvim_buf_delete, self.bufnr, { force = true })
  if self.aug then
    api.nvim_clear_autocmds({ group = self.aug })
  end
  self = nil
end

---Add a message directly to the chat buffer that will be visible to the user
---This will NOT form part of the message stack that is sent to the LLM
---@param data table
---@param opts? table
---@return number|nil last_line The last line number of the added message, or nil on failure
---@return number|nil icon_id
---@return table|nil write_range Exact 0-based byte range written to the buffer
function Chat:add_buf_message(data, opts)
  assert(type(data) == "table", "data must be a table")
  require("maxa.lifecycle.chat_response_started_event").observe(self, opts)
  if not api.nvim_buf_is_valid(self.bufnr) or not api.nvim_buf_is_loaded(self.bufnr) then
    require("maxa.interactions.chat.ui.buffer_guard").abort(self, "Chat:add_buf_message")
    return nil
  end
  opts = opts or {}

  local last_line, icon_id, range = self.builder:add_message(data, opts)
  if opts._message_stream and range then
    self._display_output_ranges = self._display_output_ranges or {}
    table.insert(self._display_output_ranges, {
      range.start.row, range.start.col, range["end"].row, range["end"].col, opts.type,
    })
  end
  return last_line, icon_id, range
end

---Capture the editable user draft without applying submission-time trimming.
---@return string
function Chat:capture_editable_draft()
  if not api.nvim_buf_is_valid(self.bufnr) or not tonumber(self.header_line) then
    return ""
  end
  local start_row = math.max(0, self.header_line + 1)
  if start_row >= api.nvim_buf_line_count(self.bufnr) then
    return ""
  end
  local lines = api.nvim_buf_get_lines(self.bufnr, start_row, -1, false)
  return table.concat(lines, "\n")
end

---Render canonical history without committing the editable user draft.
---@param draft? string
function Chat:render_history(draft)
  -- During a response the old user header precedes live assistant/tool output,
  -- not an editable draft. Do not copy that output into a new user section.
  local has_input = draft ~= nil or self._last_role == config.constants.USER_ROLE
  draft = draft == nil and (has_input and self:capture_editable_draft() or "") or draft
  local tool_display = require("maxa.interactions.chat.tools.display")
  local render_messages = tool_display.build_render_messages(self.messages)
  local render_with_input = vim.deepcopy(render_messages)
  for i, rendered in ipairs(render_with_input) do
    local original = render_messages[i]
    if original.opts and original.opts._display_origin then
      rendered.opts = rendered.opts or {}
      rendered.opts._display_origin = original.opts._display_origin
    end
  end
  if has_input then
    table.insert(render_with_input, {
      role = config.constants.USER_ROLE,
      content = draft or "",
      opts = { _preserve_empty = true },
    })
  end

  self.ui:render(self.buffer_context, render_with_input, { stop_context_insertion = true })
  self._last_role = self.ui.last_role or (has_input and config.constants.USER_ROLE or config.constants.LLM_ROLE)
  self.builder = require("maxa.interactions.chat.ui.builder").new({ chat = self })
  local header_row = parser.headers(self)
  self.header_line = header_row and (header_row + 1) or self.header_line
  tool_display.apply_render_postprocess(self, render_messages)

  if self.ui:is_active() then
    local last_line, last_column = self.ui:last()
    pcall(api.nvim_win_set_cursor, self.ui.winnr, { last_line + 1, last_column })
  end
end

---Append committed messages to visible history and preserve a separate editable user draft.
---@param messages table[]
---@param draft? string
---@return boolean success
---@return string|nil error
function Chat:add_visible_history(messages, draft)
  if type(messages) ~= "table" or vim.tbl_isempty(messages) then
    return false, "messages must be a non-empty table"
  end
  if not api.nvim_buf_is_valid(self.bufnr) or not api.nvim_buf_is_loaded(self.bufnr) then
    return false, "chat buffer is unavailable"
  end

  local original_messages = vim.deepcopy(self.messages)
  local original_lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  local original_header_line = self.header_line
  local original_last_role = self._last_role
  local original_builder = self.builder
  local was_modifiable = vim.bo[self.bufnr].modifiable
  if draft == nil then
    draft = self:capture_editable_draft()
  end

  local ok, err = pcall(function()
    for _, message in ipairs(messages) do
      self:add_message({
        role = message.role,
        content = message.content,
        reasoning = message.reasoning,
        tool_calls = message.tool_calls,
      }, vim.tbl_deep_extend("force", {}, message.opts or {}, {
        visible = true,
        _meta = { tag = "slash_visible_history" },
      }))
    end

    self:render_history(draft)
  end)

  if ok then
    return true, nil
  end

  self.messages = original_messages
  if self.tools then
    self.tools.messages = self.messages
  end
  self.header_line = original_header_line
  self._last_role = original_last_role
  self.builder = original_builder
  self.ui:unlock_buf()
  if self.ui.write_lines then
    self.ui:write_lines(0, -1, original_lines)
  else
    api.nvim_buf_set_lines(self.bufnr, 0, -1, false, original_lines)
  end
  if not was_modifiable then
    self.ui:lock_buf()
  end
  return false, tostring(err)
end

---Update a specific line in the chat buffer
---@param line_number number The line number to update (1-based)
---@param content string The new content for the line
---@param opts? table Optional parameters
---@return boolean success Whether the update was successful
function Chat:update_buf_line(line_number, content, opts)
  assert(type(content) == "string", "content must be a string")
  if not api.nvim_buf_is_valid(self.bufnr) or not api.nvim_buf_is_loaded(self.bufnr) then
    require("maxa.interactions.chat.ui.buffer_guard").abort(self, "Chat:update_buf_line")
    return false
  end
  opts = opts or {}

  return self.builder:update_line(line_number, content, opts)
end

---Add the output from a tool to the message history and a message to the UI
---@param tool table The Tool that was executed
---@param for_llm string The output to share with the LLM
---@param for_user? string The output to share with the user. If empty will use the LLM's output
---@param opts? {is_error?: boolean}
---@return nil
local function store_tool_output(self, tool, for_llm, for_user, opts)
  local tool_call = tool.function_call
  log:debug("Tool output: %s", tool_call)

  opts = opts or {}
  local output = adapters.call_handler(self.adapter, "format_response", tool_call, for_llm, opts)
  if not output then
    return log:error("Adapter does not support tool response formatting")
  end

  -- Providers may still format legacy item IDs; canonical history correlates
  -- the invocation ID, including runtime-generated background calls.
  output.tools = output.tools or {}
  output.tools.call_id = tool_call.call_id or tool_call.id
  output._meta = { cycle = self.cycle, is_error = opts.is_error == true or nil }
  output._meta.id = make_id({ role = output.role, content = output.content })
  output.opts = vim.tbl_extend("force", output.opts or {}, {
    visible = true,
  })

  -- Ensure that tool output is merged if it has the same tool call ID
  local existing = find_tool_call(tool_call.call_id or tool_call.id, self.messages)
  if existing then
    if existing.content ~= "" then
      existing.content = existing.content .. "\n\n" .. output.content
    else
      existing.content = output.content
    end
  else
    table.insert(self.messages, output)
  end

  -- Allow tools to pass in an empty string to not write any output to the buffer
  if for_user == "" then
    return
  end

  self:add_buf_message({
    role = config.constants.LLM_ROLE,
    content = (for_user or for_llm),
  }, {
    type = self.MESSAGE_TYPES.TOOL_MESSAGE,
  })
end

local function record_tool_output_lifecycle(self, tool, for_llm, for_user)
  local ok, lifecycle = pcall(require, "maxa.lifecycle.tool_calls_completed_event")
  if ok and lifecycle.record_output then
    lifecycle.record_output(self, tool, for_llm, for_user)
  end
end

function Chat:add_tool_output(tool, for_llm, for_user, opts)
  local result = require("maxa.interactions.chat.tools.display").add_tool_output(
    self,
    tool,
    for_llm,
    for_user,
    store_tool_output,
    opts
  )
  record_tool_output_lifecycle(self, tool, for_llm, for_user)
  return result
end

---Store a validation rejection without consuming normal tool display state.
---@param tool table
---@param for_llm string
---@return nil
function Chat:add_validation_error_output(tool, for_llm)
  store_tool_output(self, tool, for_llm, "", { is_error = true })
  record_tool_output_lifecycle(self, tool, for_llm, "")
end

---When a request has finished, reset the chat buffer
---@return nil
function Chat:reset()
  self.status = ""
  self.ui:unlock_buf()
end

---Get currently focused code block or the last one in the chat buffer
---@return TSNode | nil
function Chat:get_codeblock()
  local cursor = api.nvim_win_get_cursor(0)
  return parser.codeblock(self, cursor)
end

---Clear the chat buffer
---@return nil
function Chat:clear()
  self._display_output_ranges = nil
  self._request_metrics, self._last_turn_metrics = nil, nil
  self.cycle = 1
  self.header_line = 1
  self.messages = {}
  self.context_items = {}
  self._session_rewind_reply = nil
  self._session_rewind_pending = nil

  self.tool_registry:clear()

  log:trace("Clearing chat buffer")
  self.ui:render(self.buffer_context, self.messages, self.opts):set_intro_msg(self.intro_message)
  self:set_system_prompt()
  utils.fire("ChatCleared", { bufnr = self.bufnr, id = self.id })
end

---Display the chat buffer's settings and messages
function Chat:debug()
  return self.settings, self.messages
end

---Update a global state object that users can access in their config
---@return nil
function Chat:update_metadata()
  local model = self.adapter.schema and self.adapter.schema.model and self.adapter.schema.model.default

  runtime_state.chat_metadata[self.bufnr] = {
    adapter = {
      name = self.adapter.formatted_name,
      model = model,
      model_info = (self.adapter.model and self.adapter.model.info) and self.adapter.model.info,
    },
    context_items = #self.context_items,
    cycles = self.cycle,
    id = self.id,
    tokens = self.ui.tokens or 0,
    tools = vim.tbl_count(self.tool_registry.in_use) or 0,
  }
end

---Set the title of the chat buffer
---@param title string
---@return MaxaAI.Chat
function Chat:set_title(title)
  assert(type(title) == "string", "title must be a string")

  local previous = self.title
  self.title = title
  chatmap[self.bufnr].description = title
  pcall(function()
    api.nvim_buf_set_name(self.bufnr, title)
  end)
  if title ~= "" and title ~= previous then
    vim.schedule(function()
      local opts = type(self.opts) == "table" and self.opts or {}
      api.nvim_exec_autocmds("User", {
        pattern = "MaxaAIChatTitleChanged",
        data = {
          bufnr = self.bufnr,
          save_id = opts.save_id or self.save_id,
          cwd = opts.cwd or self.cwd,
          title = title,
          previous_title = previous,
        },
      })
    end)
  end

  return self
end

---Returns the chat object(s) based on the buffer number
---@param bufnr? number
---@return MaxaAI.Chat|table
function Chat.buf_get_chat(bufnr)
  if not bufnr then
    return vim
      .iter(pairs(chatmap))
      :map(function(_, v)
        return v
      end)
      :totable()
  end

  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  local entry = chatmap[bufnr]
  return entry and entry.chat or nil
end

---Returns the last chat that was visible
---@return MaxaAI.Chat|nil
function Chat.last_chat()
  if not last_chat or vim.tbl_isempty(last_chat) then
    return nil
  end
  -- if last_chat buffer was deleted, we need to clean it out
  if last_chat and not api.nvim_buf_is_loaded(last_chat.bufnr) then
    last_chat:close()
    last_chat = nil
    return nil
  end
  return last_chat
end

---Close the last chat buffer
---@return nil
function Chat.last_main_chat()
  if last_main_chat and api.nvim_buf_is_loaded(last_main_chat.bufnr) and agent_identity.is_main(last_main_chat) then
    return last_main_chat
  end
  last_main_chat = nil
  for i = #runtime_state.buffers, 1, -1 do
    local chat = Chat.buf_get_chat(runtime_state.buffers[i])
    if agent_identity.is_main(chat) then last_main_chat = chat; return chat end
  end
end

function Chat.close_last_chat()
  local chat = Chat.last_main_chat()
  if chat and chat.ui:is_visible() then chat.ui:hide() end
end

return Chat
