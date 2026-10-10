--[[
PLEASE NOTE: This adapter is not supported by MaxaAI.nvim.
It is simply provided as an example for how you can connect an OpenAI compatible endpoint
to MaxaAI via an adapter. Send any questions or queries to the discussions.
--]]

local Curl = require("plenary.curl")
local adapter_behavior = require("maxa.adapters.behavior")
local adapter_utils = require("maxa.utils.adapters")
local config = require("maxa.config")
local log = require("maxa.utils.log")
local openai = require("maxa.adapters.http.openai")

local _cache_expires
local _cache_file = vim.fn.tempname()
local _cached_models

---Return the cached models
---@params opts? table
local function models(opts)
  if opts and opts.last then
    return _cached_models[1]
  end
  return _cached_models
end

---Get a list of available OpenAI compatible models
---@params self MaxaAI.Adapter
---@params opts? table
---@return table
local function get_models(self, opts)
  if _cached_models and _cache_expires and _cache_expires > os.time() then
    return models(opts)
  end

  _cached_models = {}

  local adapter = require("maxa.adapters").resolve(self)
  if not adapter then
    log:error("Could not resolve OpenAI compatible adapter in the `get_models` function")
    return {}
  end

  adapter_utils.get_env_vars(adapter, { timeout = config.adapters.opts.cmd_timeout })
  local url = adapter.env_replaced.url .. adapter.env_replaced.models_endpoint

  local headers = adapter_utils.set_env_vars(adapter, adapter.headers) or {}

  local ok, response, json
  local proxy = require("maxa.adapters.proxy").resolve(adapter)
  local direct_args
  if not proxy then direct_args = { "--noproxy", "*" } end

  ok, response = pcall(function()
    return Curl.get(url, {
      sync = true,
      headers = headers,
      insecure = config.adapters.http.opts.allow_insecure,
      proxy = proxy,
      raw = direct_args,
    })
  end)
  if not ok then
    log:error("Could not get the OpenAI compatible models from " .. url .. ".\nError: %s", response)
    return {}
  end

  ok, json = pcall(vim.json.decode, response.body)
  if not ok then
    log:error("Could not parse the response from " .. url)
    return {}
  end

  for _, model in ipairs(json.data) do
    table.insert(_cached_models, model.id)
  end

  _cache_expires = adapter_utils.refresh_cache(_cache_file, config.adapters.http.opts.cache_models_for)

  return models(opts)
end

---@class MaxaAI.HTTPAdapter.OpenAICompatible: MaxaAI.HTTPAdapter
return {
  name = "openai_compatible",
  formatted_name = "OpenAI Compatible",
  roles = {
    llm = "assistant",
    user = "user",
  },
  opts = {
    stream = true,
    tools = true,
    vision = true,
  },
  features = {
    text = true,
    tokens = true,
  },
  url = "${url}${chat_url}",
  env = {
    api_key = "OPENAI_API_KEY",
    url = "http://localhost:11434",
    chat_url = "/v1/chat/completions",
    models_endpoint = "/v1/models",
  },
  headers = {
    ["Content-Type"] = "application/json",
    Authorization = "Bearer ${api_key}",
  },
  handlers = {
    ---@param self MaxaAI.HTTPAdapter
    ---@return boolean
    setup = function(self)
      adapter_behavior.reset_usage(self)
      if self.opts and self.opts.stream then
        self.parameters.stream = true
        self.parameters.stream_options = { include_usage = true }
      end
      return true
    end,

    parse_metrics = openai.handlers.parse_metrics,
    tokens = function(self, data)
      adapter_behavior.record_usage(self, data)
      return openai.handlers.tokens(self, data)
    end,
    form_parameters = function(self, params, messages)
      return openai.handlers.form_parameters(self, params, messages)
    end,
    form_messages = function(self, messages)
      return openai.handlers.form_messages(self, messages)
    end,
    form_tools = function(self, tools)
      return openai.handlers.form_tools(self, tools)
    end,
    chat_output = function(self, data, tools)
      return openai.handlers.chat_output(self, data, tools)
    end,
    tools = {
      can_replay_tool_call = function(self, tool_call)
        return openai.handlers.tools.can_replay_tool_call(self, tool_call)
      end,
      format_tool_calls = function(self, tools)
        return openai.handlers.tools.format_tool_calls(self, tools)
      end,
      output_response = function(self, tool_call, output, opts)
        return openai.handlers.tools.output_response(self, tool_call, output, opts)
      end,
    },
    on_exit = function(self, data)
      return openai.handlers.on_exit(self, data)
    end,
  },
  schema = {
    ---@type MaxaAI.Schema
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "ID of the model to use. See the model endpoint compatibility table for details on which models work with the Chat API.",
      default = function(self)
        return get_models(self, { last = true })
      end,
      choices = function(self)
        return get_models(self)
      end,
    },
  },
}
