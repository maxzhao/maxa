-- Compose provider-owned HTTP and independent GenAI service declarations.
-- Consumers select declared names; omitted media names default to provider IDs.
local M = {}
local declarations = {}
local media = {}
local owners = {}
local provider_defs = {}
local PROTOCOLS = require("maxa.model_catalog").protocols()
local MEDIA = { image = true, tts = true, video = true }
local function nonblank(value)
  return type(value) == "string" and value ~= ""
end

local function media_name(provider_id, medium, capability)
  assert(
    MEDIA[medium] and type(capability) == "table"
      and (capability.adapter == nil or (nonblank(capability.adapter) and capability.adapter:match("%S"))),
    "invalid genai capability for " .. provider_id
  )
  return capability.adapter or provider_id
end

local function root(value)
  return tostring(value or ""):gsub("/+$", "")
end

local function key_of(value)
  if type(value) == "function" then
    return value()
  end
  return value
end

local function has_items(value)
  return type(value) == "table" and next(value) ~= nil
end

local function remove_parameter(params, path)
  if type(params) ~= "table" or not nonblank(path) then
    return
  end
  local parts = vim.split(path, ".", { plain = true })
  local node, parents = params, {}
  for i = 1, #parts - 1 do
    if type(node) ~= "table" then
      return
    end
    parents[#parents + 1] = { node, parts[i] }
    node = node[parts[i]]
  end
  if type(node) ~= "table" then
    return
  end
  node[parts[#parts]] = nil
  for i = #parents, 1, -1 do
    local parent, key = parents[i][1], parents[i][2]
    if type(parent[key]) ~= "table" or not vim.tbl_isempty(parent[key]) then
      break
    end
    parent[key] = nil
  end
end

local function model_choices(provider_id, provider, protocol, llm, api_key, base_url, defaults)
  local catalog = require("maxa.model_catalog")
  local custom = llm.schema and llm.schema.model and llm.schema.model.choices or {}
  local discovery = provider.models
  if discovery == nil then
    -- Explicit adapter choices must not acquire unrelated protocol fallback models.
    discovery = has_items(custom) and {} or defaults.models or {}
  end
  local source = discovery.source or "api"
  local fallback = source == "static" and discovery.choices or discovery.fallback
  local cached, retry_at, failures
  failures, retry_at = 0, 0

  local function filtered(ids, discovered)
    if llm.model_choices == "replace" then
      return vim.deepcopy(custom)
    end
    local known = assert(catalog.choices(protocol))
    local known_elsewhere = {}
    for other in pairs(PROTOCOLS) do
      if other ~= protocol then
        for id in pairs(catalog.choices(other)) do
          known_elsewhere[id] = true
        end
      end
    end
    local result = {}
    for id, detail in pairs(ids or {}) do
      if known[id] or custom[id] or (discovered and not known_elsewhere[id]) then
        local choice = type(detail) == "table" and detail or {}
        result[id] = vim.tbl_deep_extend("force", {}, known[id] or {}, custom[id] or {}, choice)
      end
    end
    -- A protocol-specific explicit choice corrects an incomplete provider listing.
    for id, choice in pairs(custom) do
      if not result[id] then
        result[id] = vim.tbl_deep_extend("force", {}, known[id] or {}, choice)
      end
    end
    return result
  end

  local function from_response(json)
    if type(json) ~= "table" or type(json.data) ~= "table" then
      return nil
    end
    local choices = {}
    for _, entry in ipairs(json.data) do
      local id = type(entry) == "table" and entry.id or entry
      if nonblank(id) then
        local display = type(entry) == "table" and (entry.display_name or entry.name or entry.formatted_name)
        choices[id] = { formatted_name = nonblank(display) and display or id }
      end
    end
    return has_items(choices) and choices or nil
  end

  local function fail(reason)
    failures = failures + 1
    retry_at = vim.uv.now() + math.min(30000 * 2 ^ math.min(failures - 1, 8), 300000)
    require("maxa.utils.log"):warn("Provider models unavailable at %s: %s", base_url, tostring(reason))
    return filtered(fallback)
  end

  return function()
    if source == "static" then
      return filtered(fallback)
    end
    if cached then
      return vim.deepcopy(cached)
    end
    if not nonblank(api_key) then
      return fail("API key is missing")
    end
    if vim.uv.now() < retry_at then
      return filtered(fallback)
    end
    local headers = discovery.headers
      or (
        protocol == "anthropic_messages"
          and {
            ["x-api-key"] = api_key,
            ["anthropic-version"] = "2023-06-01",
          }
        or { Authorization = "Bearer " .. api_key }
      )
    local url = discovery.url or (base_url .. "/models")
    local request_proxy = require("maxa.adapters.proxy").resolve({ backend = { id = provider_id } })
    local direct_args
    if not request_proxy then direct_args = { "--noproxy", "*" } end
    local ok, response = pcall(require("plenary.curl").get, url, {
      sync = true,
      headers = headers,
      insecure = require("maxa.config").adapters.http.opts.allow_insecure,
      proxy = request_proxy,
      raw = direct_args,
      timeout = 3000,
    })
    if not ok or type(response) ~= "table" or (response.status or 0) >= 400 then
      return fail(ok and ("HTTP " .. tostring(response.status)) or response)
    end
    local parsed, json = pcall(vim.json.decode, response.body or "")
    local found = parsed and from_response(json)
    if not found then
      return fail("invalid or empty model list")
    end
    cached = filtered(found, true)
    failures, retry_at = 0, 0
    return vim.deepcopy(cached)
  end
end

local function quota_config(provider)
  if provider.quota == nil or provider.quota == false then
    return nil
  end
  local kind = provider.type
  assert(nonblank(kind), "provider.type is required for quota")
  local quota = type(provider.quota) == "table" and vim.deepcopy(provider.quota) or {}
  assert(
    type(provider.quota) == "boolean" or type(provider.quota) == "table",
    "provider.quota must be boolean or table"
  )
  quota.provider = kind
  quota.api_base = quota.api_base
    or ((kind == "newapi") and root(provider.base_url):gsub("/v1$", "") or provider.base_url)
  if kind == "newapi" then
    -- Missing local secrets disable the balance query, not editor startup.
  elseif kind == "sub2api" or kind == "deepseek" or kind == "local" then
    quota.api_key = quota.api_key or key_of(provider.api_key)
  else
    error("unsupported quota provider: " .. tostring(kind))
  end
  return quota
end

local function build_llm(provider_id, provider, protocol, llm, quota, protocol_defaults)
  local base_url = root(llm.base_url or provider.base_url)
  local api_key = key_of(llm.api_key or (llm.env and llm.env.api_key) or provider.api_key)
  local defaults = protocol_defaults[protocol] or {}
  local choices = model_choices(provider_id, provider, protocol, llm, api_key, base_url, defaults)
  local configured_schema = vim.deepcopy(llm.schema or {})
  local configured_model = configured_schema.model or {}
  configured_schema.model = nil
  local default_model = configured_model.default
  local existing = require("maxa.adapters.http." .. PROTOCOLS[protocol])
  local inherited = existing.schema and existing.schema.model and existing.schema.model.default
  if default_model == nil then
    default_model = defaults.default_model or (type(inherited) == "string" and inherited or nil)
  end
  local extension = llm.extend
  local opts = vim.deepcopy(llm)
  for _, field in ipairs({ "api_key", "base_url", "model_choices", "extend" }) do
    opts[field] = nil
  end
  if opts.raw == nil then opts.raw = vim.deepcopy(defaults.raw) end
  if opts.thinking_mode == nil then opts.thinking_mode = defaults.thinking_mode end
  opts.name = llm.name
  opts.url = opts.url
    or (
      protocol == "openai_responses" and base_url .. "/responses"
      or protocol == "anthropic_messages" and base_url .. "/messages"
      or protocol == "gemini" and base_url .. "/chat/completions"
      or nil
    )
  opts.env = vim.tbl_deep_extend("force", { api_key = api_key }, vim.deepcopy(opts.env or {}))
  if protocol == "openai_compatible" then
    opts.env.url = opts.env.url or base_url
    opts.env.chat_url = opts.env.chat_url or "/chat/completions"
    opts.env.models_endpoint = opts.env.models_endpoint or "/models"
  end
  opts.backend = { provider = provider.type, protocol = protocol, api_root = base_url, id = provider_id }
  opts.quota = quota and vim.deepcopy(quota) or nil
  local compact_model = defaults.compact_model or default_model
  local extra = opts.maxa or {}
  opts.maxa = {
    compact = { adapter = "inherit", model = compact_model },
  }
  for key, value in pairs(extra) do
    opts.maxa[key] = vim.deepcopy(value)
  end
  opts.schema = configured_schema
  opts.schema.model = { default = default_model, choices = choices }
  if protocol == "openai_responses" then
    local original = existing.handlers.request.build_parameters
    local custom = opts.handlers and opts.handlers.request and opts.handlers.request.build_parameters
    if not custom then
      local unsupported = llm.unsupported_parameters
      if unsupported == nil then
        unsupported = { "top_p", "temperature" }
      end
      opts.handlers = opts.handlers or {}
      opts.handlers.request = opts.handlers.request or {}
      opts.handlers.request.build_parameters = function(self, params, messages)
        local result = original(self, params, messages)
        for _, key in ipairs(unsupported) do
          remove_parameter(result, key)
        end
        local model = self.model and self.model.name or default_model
        local seed = table.concat({ tostring(model or ""), vim.uv.cwd() or "", os.date("%Y-%m-%d"), "01" }, "|")
        local digest = vim.fn.sha256(seed)
        result.prompt_cache_key = string.format(
          "%s-%s-%s-%s-%s",
          digest:sub(1, 8),
          digest:sub(9, 12),
          digest:sub(13, 16),
          digest:sub(17, 20),
          digest:sub(21, 32)
        )
        return result
      end
    end
  end
  if protocol == "openai_responses" then
    opts.schema["reasoning.effort"] = opts.schema["reasoning.effort"]
      or {
        order = 2,
        mapping = "parameters",
        type = "string",
        optional = true,
        default = opts.thinking_mode,
        choices = { "ultra", "max", "xhigh", "high", "medium", "low", "none" },
      }
    opts.schema.max_output_tokens = opts.schema.max_output_tokens
      or {
        order = 7,
        mapping = "parameters",
        type = "integer",
        optional = true,
        default = function(adapter)
          local limits = require("maxa.model_catalog").get(
            adapter.model and adapter.model.name or default_model,
            protocol,
            adapter.name
          )
          return limits and limits.limits and limits.limits.max_output_tokens
        end,
      }
    opts.schema.verbosity = opts.schema.verbosity
      or {
        order = 8,
        mapping = "parameters.text",
        type = "string",
        optional = true,
        default = "low",
        choices = { "low", "medium", "high" },
      }
  end
  local base_factory = function()
    local adapter = require("maxa.adapters").extend(PROTOCOLS[protocol], opts)
    assert(adapter, "failed to extend adapter " .. llm.name)
    local resolved = choices()
    -- The provider list is authoritative; extending the adapter prototype must
    -- not leak official models that this provider did not advertise.
    adapter.schema.model.choices = resolved
    local chosen = default_model
    if not chosen or not resolved[chosen] then
      local ids = vim.tbl_keys(resolved)
      table.sort(ids)
      chosen = ids[1]
    end
    if not chosen then
      error("no models available for " .. llm.name)
    end
    adapter.schema.model.default = chosen
    if extra.compact == nil then
      adapter.maxa.compact.model = compact_model and resolved[compact_model] and compact_model or chosen
    end
    adapter.model = {
      name = chosen,
      opts = chosen and adapter.schema.model.choices[chosen] and adapter.schema.model.choices[chosen].opts,
    }
    return adapter
  end
  return extension and extension(base_factory) or base_factory
end

local function resolve_model_preset(llm, presets)
  local model = llm.schema and llm.schema.model
  if not model or model.preset == nil then
    return llm
  end
  assert(
    model.default == nil and model.choices == nil,
    "provider schema.model.preset cannot be combined with default or choices"
  )
  local preset = presets and presets[model.preset]
  assert(
    type(preset) == "table" and type(preset.model) == "string" and preset.model ~= "",
    "provider model preset requires a configured model: " .. tostring(model.preset)
  )
  local resolved = vim.deepcopy(llm)
  resolved.schema.model = { default = preset.model, choices = { [preset.model] = {} } }
  return resolved
end

function M.configure(providers, presets, protocol_defaults)
  assert(type(providers) == "table", "maxa.providers must be a table")
  protocol_defaults = protocol_defaults or {}
  assert(type(protocol_defaults) == "table", "maxa.protocol_defaults must be a table")
  for protocol, defaults in pairs(protocol_defaults) do
    assert(PROTOCOLS[protocol] and type(defaults) == "table", "invalid maxa.protocol_defaults protocol")
    assert(defaults.model == nil, "protocol_defaults." .. protocol .. ".model is invalid; use default_model")
    for _, field in ipairs({ "default_model", "compact_model", "thinking_mode" }) do
      assert(defaults[field] == nil or nonblank(defaults[field]), "protocol_defaults." .. protocol .. "." .. field .. " must be a nonempty string")
    end
    assert(defaults.raw == nil or type(defaults.raw) == "table", "protocol_defaults." .. protocol .. ".raw must be a table")
    assert(defaults.models == nil or type(defaults.models) == "table", "protocol_defaults." .. protocol .. ".models must be a table")
    assert(defaults.models == nil or defaults.models.fallback == nil or type(defaults.models.fallback) == "table",
      "protocol_defaults." .. protocol .. ".models.fallback must be a table")
  end
  -- Validate identities before registering any adapter, quota or media capability.
  local planned, llm_names = {}, {}
  for id, provider in pairs(providers) do
    assert(
      nonblank(id) and type(provider) == "table" and nonblank(root(provider.base_url)),
      "provider id and base_url are required"
    )
    assert(
      provider.proxy == nil
        or type(provider.proxy) == "function"
        or type(provider.proxy) == "boolean"
        or (type(provider.proxy) == "string" and provider.proxy:match("%S")),
      "provider " .. id .. " proxy must be false, true, a nonempty address or function"
    )
    assert(
      type(provider.quota) ~= "table" or provider.quota.proxy == nil,
      "provider " .. id .. " quota proxy must be declared on the provider"
    )
    local model_source = provider.models and provider.models.source or "api"
    assert(model_source == "api" or model_source == "static", "unsupported provider models.source")
    if model_source == "static" then
      assert(has_items(provider.models.choices), "static provider models require choices")
    end
    for protocol, llm in pairs(provider.llm or {}) do
      assert(
        PROTOCOLS[protocol] and type(llm) == "table" and nonblank(llm.name),
        "invalid llm protocol/adapter for " .. id
      )
      assert(llm.extend == nil or type(llm.extend) == "function", "llm.extend must be a code extension function")
      assert(
        llm.proxy == nil and not (type(llm.maxa) == "table" and llm.maxa.proxy ~= nil),
        "provider " .. id .. " proxy must be declared on the provider, not the LLM"
      )
      assert(not llm_names[llm.name], "duplicate LLM adapter name: " .. llm.name)
      llm_names[llm.name] = true
      assert(not planned[llm.name] or planned[llm.name] == id, "adapter name belongs to another provider: " .. llm.name)
      planned[llm.name] = id
      if llm.model_choices ~= nil then
        assert(
          llm.model_choices == "replace" and has_items(llm.schema and llm.schema.model and llm.schema.model.choices),
          "model_choices=replace requires nonempty schema.model.choices"
        )
      end
    end
    for medium, capability in pairs(provider.genai or {}) do
      local name = media_name(id, medium, capability)
      assert(capability.proxy == nil, "provider " .. id .. " genai proxy must be declared on the provider")
      assert(not planned[name] or planned[name] == id, "adapter name belongs to another provider: " .. name)
      planned[name] = id
    end
    quota_config(provider)
  end
  local registry = require("maxa.mcphub.native_servers.genai.capability_registry")
  declarations, media, owners, provider_defs = {}, {}, {}, vim.deepcopy(providers)
  for provider_id, provider in pairs(providers) do
    assert(nonblank(provider_id) and type(provider) == "table", "provider id must name a table")
    local api_root = root(provider.base_url)
    assert(nonblank(api_root), "provider " .. provider_id .. " requires base_url")
    local by_name = {}
    for medium, capability in pairs(provider.genai or {}) do
      local name = media_name(provider_id, medium, capability)
      assert(not owners[name] or owners[name] == provider_id, "adapter name belongs to another provider: " .. name)
      owners[name] = provider_id
      by_name[name] = by_name[name] or {}
      by_name[name][medium] = vim.deepcopy(capability)
    end
    local quota = quota_config(provider)
    for protocol, llm in pairs(provider.llm or {}) do
      assert(
        PROTOCOLS[protocol] and type(llm) == "table" and nonblank(llm.name),
        "invalid llm protocol/adapter for " .. provider_id
      )
      assert(declarations[llm.name] == nil, "duplicate LLM adapter name: " .. llm.name)
      assert(
        not owners[llm.name] or owners[llm.name] == provider_id,
        "adapter name belongs to another provider: " .. llm.name
      )
      owners[llm.name] = provider_id
      declarations[llm.name] =
        build_llm(provider_id, provider, protocol, resolve_model_preset(llm, presets), quota, protocol_defaults)
      if quota then
        require("maxa.session.status.billing").register_adapter_quota(
          llm.name,
          quota,
          { name = llm.name, backend = { id = provider_id } }
        )
      end
    end
    for name, capabilities in pairs(by_name) do
      assert(not media[name], "duplicate media adapter name: " .. name)
      media[name] = {
        provider = provider_id,
        api_root = api_root,
        api_key = key_of(provider.api_key),
        capabilities = capabilities,
      }
      local ok, err = registry.register(name, name, capabilities)
      assert(ok, err)
    end
  end
  return vim.deepcopy(declarations)
end

function M.adapters()
  return vim.deepcopy(declarations)
end

function M.provider(id)
  local provider = provider_defs[id]
  if not provider then
    return nil
  end
  local context = vim.deepcopy(provider)
  context.id = id
  return context
end

function M.owner(name)
  return owners[name]
end

function M.media(name, medium)
  local item = media[name]
  if not item or not item.capabilities[medium] then
    return nil
  end
  local resolved = vim.deepcopy(item)
  resolved.name = name
  resolved.api_root = root(resolved.capabilities[medium].base_url or resolved.api_root)
  resolved.api_key = key_of(resolved.capabilities[medium].api_key) or resolved.api_key
  return resolved
end

return M
