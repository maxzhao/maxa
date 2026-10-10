--[[
===============================================================================
    File:       maxa_ai/interactions/background/init.lua
    Author:     Oli Morris
-------------------------------------------------------------------------------
    Description:
      This module implements background interactions for the chat buffer.
      These work on the basis of non-blocking requests which attach to
      callbacks on the chat instance.

      The interactions can self-destruct after running or persist for the
      lifetime of the chat session.

      Background interactions must log or error silently so as not to impact
      the user experience.

      This code is licensed under the MIT License.
-------------------------------------------------------------------------------
    Attribution:
      If you use or distribute this code, please credit:
      Oli Morris (https://github.com/olimorris)
===============================================================================
--]]

local adapters = require("maxa.adapters")
local config = require("maxa.config")
local http = require("maxa.http")
local log = require("maxa.utils.log")
local schema = require("maxa.schema")

---@class MaxaAI.Background
---@field adapter MaxaAI.HTTPAdapter The adapter to use for the background task
---@field id number The unique identifier for the background task
---@field messages MaxaAI.Chat.Messages The messages for the background task
---@field settings table The settings used in the adapter
local Background = {}

---@class MaxaAI.Background.Args
---@field preset? string Named shared preset (defaults to config.interactions.background.preset)
---@field chat? MaxaAI.Chat Parent Chat for runtime preset overrides and inheritance
---@field messages? MaxaAI.Chat.Messages The messages to initialize with
---@field settings? table The settings for the adapter

---@param args MaxaAI.Background.Args
---@return MaxaAI.Background
function Background.new(args)
  args = args or {}

  local self = setmetatable({
    id = math.random(10000000),
    messages = args.messages or {},
  }, { __index = Background })

  if args.adapter ~= nil then
    return nil, "Background.new accepts a preset name, not a raw adapter"
  end

  local name = args.preset or config.interactions.background.preset
  local role = args.default_role or "chat"
  local presets = require("maxa.mcphub.native_servers.config")
  local selected, err
  if name then
    selected, err = presets.get_preset(name, "chat")
  elseif args.chat then
    selected, err = presets.get_runtime_adapter(role, { chat = args.chat })
  else
    selected, err = presets.get_default(role)
  end
  name = name or role
  if not selected then
    return nil, err
  end

  local adapter_name = selected.adapter
  local model = selected.model
  local temperature = selected.temperature
  if selected.inherit then
    adapter_name = args.chat and args.chat.adapter and args.chat.adapter.name
    model = model or (args.chat and args.chat.settings and args.chat.settings.model)
      or (args.chat and args.chat.adapter and args.chat.adapter.model and args.chat.adapter.model.name)
    if not adapter_name then
      return nil, "Background preset requires a parent Chat adapter: " .. name
    end
    if temperature == nil then
      temperature = args.chat and args.chat.settings and args.chat.settings.temperature
    end
  end
  self.adapter = adapters.resolve(adapter_name, { model = model, temperature = temperature })
  if not self.adapter then
    return nil, "Background preset adapter could not be resolved: " .. tostring(adapter_name)
  end
  if self.adapter.type ~= "http" then
    return nil, "Only HTTP adapters are supported for background interactions"
  end

  local settings = presets.get_reasoning_effort_settings(self.adapter, selected.thinking_mode) or {}
  if temperature ~= nil then
    settings.temperature = temperature
  end
  self.settings = schema.get_default(self.adapter, vim.tbl_extend("force", settings, vim.deepcopy(args.settings or {})))
  self.adapter:map_schema_to_params(self.settings)

  return self ---@type MaxaAI.Background
end

---Ask the LLM, synchronously
---@param background MaxaAI.Background
---@param messages MaxaAI.Chat.Messages
---@param opts? { silent?: boolean, parse_handler?: string }
---@return any, table|nil -- parsed response, error
local function ask_sync(background, messages, opts)
  opts = opts or {}

  if background.adapter.type ~= "http" then
    return nil, { message = "[background::init] ask_sync only supports HTTP adapters" }
  end

  local client = http.new({ adapter = background.adapter })
  local payload = {
    messages = background.adapter:map_roles(vim.deepcopy(messages)),
  }

  log:debug("[background::init] Ask Sync Payload:\n%s", payload)
  local response, err = client:send_sync(payload, { silent = opts.silent })

  if err then
    log:debug("[background::init] ask_sync failed: %s", err.stderr or err.message)
    return nil, err
  end

  local parse_handler = opts.parse_handler or "parse_chat"
  local result = adapters.call_handler(background.adapter, parse_handler, response.body)
  return result, nil
end

---Ask the LLM asynchronously
---@param background MaxaAI.Background
---@param messages MaxaAI.Chat.Messages
---@param opts { on_done: function, on_error?: function, on_chunk?: function, silent?: boolean, parse_handler?: string }
---@return MaxaAI.HTTPClient.RequestHandle
local function ask_async(background, messages, opts)
  assert(opts.on_done, "on_done callback is required for ask_async")

  -- Temporarily disable streaming for this request
  local adapter = vim.deepcopy(background.adapter)
  if adapter.opts then
    adapter.opts.stream = false
  end

  local client = http.new({ adapter = adapter })
  local payload = {
    messages = adapter:map_roles(vim.deepcopy(messages)),
  }

  -- Wrap the on_done callback to parse the response
  local parse_handler = opts.parse_handler or "parse_chat"
  local original_on_done = opts.on_done
  opts.on_done = function(response, meta)
    if not response or not response.body then
      original_on_done(nil, meta)
      return
    end

    local result = adapters.call_handler(adapter, parse_handler, response.body)
    original_on_done(result, meta)
  end

  log:trace("[background::init] Ask Async Payload:\n%s", payload)
  return client:send(payload, opts)
end

---Ask the LLM for a specific response
---@param messages MaxaAI.Chat.Message[]
---@param opts? { method?: string, silent?: boolean, parse_handler?: string }
function Background:ask(messages, opts)
  opts = vim.tbl_deep_extend("force", { method = "async" }, opts or {})

  if opts.method == "sync" then
    return ask_sync(self, messages, opts)
  end
  return ask_async(self, messages, opts)
end

return Background
