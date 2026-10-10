local buf_utils = require("maxa.utils.buffers")
local config = require("maxa.config")
local log = require("maxa.utils.log")

---Resolve the callback to the correct module
---@param callback string The module to get
---@return table|nil
local function resolve(callback)
  local ok, slash_command = pcall(require, "maxa." .. callback)
  if ok then
    log:debug("Calling slash command: %s", callback)
    return slash_command
  end

  -- Try loading the tool from the user's config using a module path
  ok, slash_command = pcall(require, callback)
  if ok then
    log:debug("Calling slash command using a module path: %s", callback)
    return slash_command
  end

  -- Try loading the tool from the user's config using a file path
  local err
  slash_command, err = loadfile(vim.fs.normalize(callback))
  if err then
    return log:error("Could not load the slash command: %s", callback)
  end

  if slash_command then
    log:debug("Calling slash command from a file path: %s", callback)
    return slash_command()
  end
end

---@class MaxaAI.SlashCommands
local SlashCommands = {}

---@class MaxaAI.SlashCommands
function SlashCommands.new()
  return setmetatable({}, { __index = SlashCommands })
end

---Set the provider to use for the Slash Command
---@param SlashCommand MaxaAI.SlashCommand
---@param providers table
---@return function
function SlashCommands:set_provider(SlashCommand, providers)
  if SlashCommand.config.opts and SlashCommand.config.opts.provider then
    if not providers[SlashCommand.config.opts.provider] then
      return log:error(
        "Provider for the symbols slash command could not be found: %s",
        SlashCommand.config.opts.provider
      )
    end
    return providers[SlashCommand.config.opts.provider](SlashCommand) --[[@type function]]
  end
  return providers["default"] --[[@type function]]
end

---Execute the selected slash command
---@param item table The selected item from the completion menu
---@param chat MaxaAI.Chat
---@return nil
function SlashCommands:execute(item, chat)
  local label = item.label:sub(1)
  log:debug("Executing slash command: %s", label)

  -- If the user has provided a callback function, use that
  if type(item.config.callback) == "function" then
    return item.config.callback(chat, item.context)
  end

  local callback = resolve(item.config.callback)
  if not callback then
    return log:error("Slash command not found: %s", label)
  end

  if callback.enabled then
    local enabled, err = callback.enabled(chat)
    if enabled == false then
      return log:warn(err)
    end
  end

  return callback
    .new({
      Chat = chat,
      config = item.config,
      context = item.context,
    })
    :execute(self)
end

---Function for external objects to add file/buffer context via Slash Commands
---@param chat MaxaAI.Chat
---@param slash_command string
---@param opts { path: string, description: string, [any]: any }
---@return nil
function SlashCommands.context(chat, slash_command, opts)
  local slash_commands = {
    buffer = require("maxa.interactions.chat.slash_commands.builtin.buffer").new({
      Chat = chat,
      config = config.interactions.chat.slash_commands["buffer"],
    }),
    file = require("maxa.interactions.chat.slash_commands.builtin.file").new({
      Chat = chat,
    }),
    symbols = require("maxa.interactions.chat.slash_commands.builtin.symbols").new({
      Chat = chat,
    }),
  }

  -- Check if the file is already open as a buffer
  if slash_command == "file" then
    local buffer = {}
    for _, buf in ipairs(buf_utils.get_open()) do
      if buf.relative_path == opts.path then
        buffer = {
          bufnr = buf.bufnr,
          name = buf.path,
          path = buf.path,
        }
        break
      end
    end
    if not vim.tbl_isempty(buffer) then
      return slash_commands["buffer"]:output(buffer, { description = opts.description, silent = true })
    end
  end

  if slash_command == "file" or slash_command == "symbols" then
    return slash_commands[slash_command]:output({ description = opts.description, path = opts.path }, { silent = true })
  end

end

---Attach declared file/symbol context after a Markdown prompt inserts.
function SlashCommands.add_prompt_context(prompt, chat)
  for _, item in ipairs(prompt.context or {}) do
    local paths = type(item.path) == "string" and { item.path } or item.path
    for _, path in ipairs(paths) do SlashCommands.context(chat, item.type, { path = path }) end
  end
end

return SlashCommands
