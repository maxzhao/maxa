local ability_catalog = require("maxa.abilities.catalog")
local abilities = require("maxa.session.abilities")
local ability_utils = require("maxa.interactions.chat.tools.builtin.runtime.ability_utils")
local builtin_utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

-- Complete catalogs are protected from ordinary wrapper output truncation. Keep
-- only a hard transport guard for pathological schemas.
local MAX_CATALOG_CHARS = 1024 * 1024
local pending_revisions = {}

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local content = file:read("*a") or ""
  file:close()
  return content
end


local function chat_key(chat, cwd)
  return tostring(chat and (chat.id or chat.bufnr or chat) or "missing") .. "\0" .. tostring(cwd)
end

local function pending_for(chat, cwd)
  local key = chat_key(chat, cwd)
  pending_revisions[key] = pending_revisions[key] or {}
  return pending_revisions[key], key
end

local function clear_pending(key, name)
  if pending_revisions[key] then
    pending_revisions[key][name] = nil
    if next(pending_revisions[key]) == nil then
      pending_revisions[key] = nil
    end
  end
end

local function synthetic_tool_ids(kind, seed)
  local digest = vim.fn.sha256(tostring(seed)):sub(1, 32)
  return string.format("fc_ability_%s_%s", kind, digest), string.format("call_ability_%s_%s", kind, digest)
end

local function synthetic_tool_call_id(kind, seed)
  local _, call_id = synthetic_tool_ids(kind, seed)
  return call_id
end

local function tool_call_id(agent, ability_name)
  local id = ability_utils.get_tool_call_id(agent)
  if id and id ~= "" then
    return id
  end
  return synthetic_tool_call_id("load", ability_name .. "\n" .. tostring(vim.uv.hrtime()))
end

local function provenance(resolved)
  return {
    workspace_key = resolved.workspace_key,
    workspace_root = resolved.workspace_root,
    config_files = vim.deepcopy(resolved.config_files or {}),
  }
end

local function apply_mcp_overrides(ability, tools)
  local overrides = ability.mcp_overrides and ability.mcp_overrides.tools
  if not overrides then
    return tools
  end
  local result = vim.deepcopy(tools)
  local by_name = {}
  for _, tool in ipairs(result) do
    by_name[tool.name] = tool
  end
  for tool_name, override in pairs(overrides) do
    local tool = by_name[tool_name]
    if not tool then
      return nil, "MCP overrides reference unknown allowed tool " .. tool_name
    end
    if override.description then
      tool.description = override.description
    end
    for parameter_name, parameter_override in pairs(override.parameters or {}) do
      local properties = tool.inputSchema and tool.inputSchema.properties
      local parameter = type(properties) == "table" and properties[parameter_name] or nil
      if type(parameter) ~= "table" then
        return nil, string.format("MCP overrides for %s reference unknown parameter %s", tool_name, parameter_name)
      end
      parameter.description = parameter_override.description
    end
  end
  return result
end

local function prepare_hooks(ability, cwd)
  if #ability.layers == 0 then
    return {}
  end
  local ok, hooks = pcall(require, "maxa.abilities.hooks")
  if not ok or type(hooks.prepare_on_load_hooks) ~= "function" then
    return {}
  end
  return hooks.prepare_on_load_hooks(ability, cwd)
end

local function commit_hooks(chat, ability, prepared_hooks)
  local hooks = require("maxa.abilities.hooks")
  if type(hooks.commit_on_load_hooks) == "function" then
    hooks.commit_on_load_hooks(chat, ability.name, prepared_hooks)
  end
  local fire = require("maxa.abilities.hooks.fire")
  fire.fire("AbilityLoaded", { bufnr = chat and chat.bufnr or nil, ability_name = ability.name })
end

local function prepare_skill_instructions(ability)
  if not ability.skill then
    return nil
  end
  local content, read_err = read_file(ability.skill.path)
  if not content then
    return nil, "cannot read Ability instructions: " .. tostring(read_err)
  end
  local sanitized, sanitize_err = ability_utils.sanitize_context_markdown(content, {
    kind = "ability",
    absolute_path = ability.skill.path,
    display_name = ability.name,
  })
  if not sanitized then
    return nil, sanitize_err
  end
  return sanitized.body
end

local function prepare_mcp(ability, cwd, callback)
  local transport = require("maxa.mcphub").get_project_transport()
  if not ability.mcp then
    local resolved, resolve_err = transport.resolve(cwd)
    if not resolved then
      return callback(nil, tostring(resolve_err))
    end
    return callback({ tools = {}, resources = {}, provenance = provenance(resolved), guidance = nil })
  end
  transport.ensure_server(cwd, ability.name, function(server, ensure_err, resolved)
    if not server then
      return callback(nil, tostring(ensure_err), resolved)
    end
    local config_manager = require("maxa.mcphub.utils.config_manager")
    local capabilities, capability_err = config_manager.filter_effective_capabilities(
      resolved.catalog,
      ability.name,
      server.capabilities or {}
    )
    if not capabilities then
      return callback(nil, tostring(capability_err), resolved)
    end
    local live_tools, tool_err = abilities.normalize_tools(capabilities.tools or {})
    if not live_tools then
      return callback(nil, tool_err, resolved)
    end
    local tools, override_err = apply_mcp_overrides(ability, live_tools)
    if not tools then
      return callback(nil, override_err, resolved)
    end
    local resources, resource_err = abilities.normalize_resources(ability.name, capabilities.resources or {})
    if not resources then
      return callback(nil, resource_err, resolved)
    end
    callback({
      tools = tools,
      resources = resources,
      provenance = provenance(resolved),
      guidance = nil,
    }, nil, resolved)
  end)
end

local function prepare_revision(ability, cwd, callback)
  local instructions, instruction_err = prepare_skill_instructions(ability)
  if ability.skill and not instructions then
    return callback(nil, instruction_err)
  end
  local hooks, hook_err = prepare_hooks(ability, cwd)
  if hooks == nil then
    return callback(nil, hook_err)
  end
  prepare_mcp(ability, cwd, function(mcp, mcp_err, resolved)
    if not mcp then
      return callback(nil, mcp_err, { transport = resolved and resolved.workspace_key or nil })
    end
    local hook_fingerprints = {}
    for _, hook in ipairs(hooks or {}) do
      local source = hook.path and read_file(hook.path) or ""
      hook_fingerprints[#hook_fingerprints + 1] = {
        path = hook.path,
        event_name = hook.event_name,
        load = hook.load,
        scope = hook.scope,
        sha256 = vim.fn.sha256(source or ""),
      }
    end
    local revision = abilities.build_revision({
      ability = ability,
      tools = mcp.tools,
      resources = mcp.resources,
      provenance = mcp.provenance,
      instructions = instructions,
      guidance = mcp.guidance,
      hooks = hook_fingerprints,
    })
    if #revision.catalog > MAX_CATALOG_CHARS then
      return callback(
        nil,
        string.format(
          "Ability catalog-size error for %s: %d chars exceeds hard result limit %d; no revision committed",
          ability.name,
          #revision.catalog,
          MAX_CATALOG_CHARS
        ),
        { transport = resolved and resolved.workspace_key or nil }
      )
    end
    callback({
      ability = ability,
      revision = revision,
      instructions = instructions,
      guidance = mcp.guidance,
      hooks = hooks,
    })
  end)
end

local function find_result_by_call_id(messages, call_id)
  for index = #(messages or {}), 1, -1 do
    local message = messages[index]
    local current = message and ((message.tools and message.tools.call_id) or message.tool_call_id)
    if current == call_id and message.role == "tool" then
      return message
    end
  end
  return nil
end

local function enqueue_dependency_commit(chat, prepared, call_id, item_id, key)
  local assistant, result = abilities.synthetic_catalog_pair(prepared.revision, call_id, item_id)
  local batch = { assistant, result }
  vim.list_extend(batch, abilities.build_context_batch(
    prepared.revision,
    prepared.instructions,
    prepared.guidance,
    call_id
  ))
  local injector = require("maxa.interactions.chat.tools.builtin.runtime.context_injector")
  local queued = injector.enqueue_transaction(chat, batch, function(current_chat)
    local allowed, err = require("maxa.project.settings").check_ability(
      current_chat.opts and (current_chat.opts.project_root or current_chat.opts.cwd), prepared.ability.name)
    if not allowed then error(err) end
    return true
  end, function(current_chat)
    clear_pending(key, prepared.ability.name)
    commit_hooks(current_chat, prepared.ability, prepared.hooks)
  end, function()
    clear_pending(key, prepared.ability.name)
  end)
  if not queued then
    clear_pending(key, prepared.ability.name)
    return nil, "cannot queue dependency Ability transaction"
  end
  return true
end

local function enqueue_root_commit(chat, prepared, call_id, key, graph)
  local batch = abilities.build_context_batch(
    prepared.revision,
    prepared.instructions,
    prepared.guidance,
    call_id
  )
  local injector = require("maxa.interactions.chat.tools.builtin.runtime.context_injector")
  local queued = injector.enqueue_transaction(chat, batch, function(current_chat)
    local allowed, err = require("maxa.project.settings").check_ability(
      current_chat.opts and (current_chat.opts.project_root or current_chat.opts.cwd), prepared.ability.name)
    if not allowed then error(err) end
    local settings = require("maxa.project.settings")
    for _, name in ipairs(graph.order) do
      local usable, policy_err = settings.check_ability(current_chat.opts and (current_chat.opts.project_root or current_chat.opts.cwd), name)
      if not usable then error(policy_err) end
      if name ~= prepared.ability.name then
        local ready, ready_err = abilities.get_ready(current_chat, current_chat.opts and current_chat.opts.cwd, name)
        if not ready then error(ready_err or ("Dependency Ability is not ready: " .. name)) end
      end
    end
    local result = find_result_by_call_id(current_chat.messages, call_id)
    local catalog_present = result and type(result.content) == "string" and result.content:find(prepared.revision.catalog, 1, true)
    if not catalog_present and result and type(result.content) == "string" then
      local encoded = vim.json.encode(prepared.revision.catalog)
      catalog_present = result.content:find(encoded:sub(2, -2), 1, true)
    end
    if not catalog_present then
      error("complete catalog-bearing load result is missing for " .. prepared.ability.name)
    end
    abilities.mark_catalog_result(result, prepared.revision)
    return true
  end, function(current_chat)
    clear_pending(key, prepared.ability.name)
    commit_hooks(current_chat, prepared.ability, prepared.hooks)
  end, function()
    clear_pending(key, prepared.ability.name)
  end)
  if not queued then
    clear_pending(key, prepared.ability.name)
    return nil, "cannot queue root Ability transaction"
  end
  return true
end

local function ready_or_pending(chat, cwd, name)
  local ready = abilities.get_ready(chat, cwd, name)
  if ready then
    return ready.revision, "ready"
  end
  local pending = pending_for(chat, cwd)
  if pending[name] then
    return pending[name].revision, "pending"
  end
  return nil, nil
end

local function load_root(context, response, target, force_reload)
  local chat, agent = ability_utils.get_chat_and_agent(context)
  if not chat or not chat.messages then
    return response:error("load: exact Chat session is unavailable")
  end
  local graph, graph_err = ability_catalog.resolve_graph(target, context.cwd)
  if not graph then
    return response:error("load: " .. tostring(graph_err))
  end
  for _, name in ipairs(graph.order) do
    local allowed, err = require("maxa.project.settings").check_ability(context.project_root or context.cwd, name)
    if not allowed then return response:error("load: " .. tostring(err)) end
  end
  local pending, key = pending_for(chat, context.cwd)
  local completed_dependencies, transport_effects = {}, {}
  local root_call_id = tool_call_id(agent, target)
  local cancelled = false
  local bridge_ok, bridge = pcall(require, "maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
  if bridge_ok then
    bridge.register_handle({ cancel = function() cancelled = true end })
  end

  local function fail(message)
    for name in pairs(pending) do
      if pending[name] and pending[name].owner == root_call_id then
        local waiters = pending[name].waiters or {}
        clear_pending(key, name)
        for _, waiter in ipairs(waiters) do waiter(message) end
      end
    end
    local details = {}
    if #completed_dependencies > 0 then
      details[#details + 1] = "completed dependencies: " .. table.concat(completed_dependencies, ", ")
    end
    if #transport_effects > 0 then
      details[#details + 1] = "retained transport effects: " .. table.concat(transport_effects, ", ")
    end
    if #details > 0 then
      message = message .. "\n" .. table.concat(details, "\n")
    end
    return response:error("load: " .. message)
  end

  local function step(index)
    if index > #graph.order then
      return fail("internal dependency traversal did not prepare the requested Ability")
    end
    local name = graph.order[index]
    local allowed, policy_err = require("maxa.project.settings").check_ability(context.project_root or context.cwd, name)
    if not allowed then return fail(policy_err) end
    local is_root = name == target
    local existing, existing_state = ready_or_pending(chat, context.cwd, name)
    if existing_state == "pending" then
      local in_flight = pending[name]
      if not is_root then
        if in_flight and in_flight.revision then
          return step(index + 1)
        end
        if in_flight then
          in_flight.waiters = in_flight.waiters or {}
          in_flight.waiters[#in_flight.waiters + 1] = function(wait_err)
            if wait_err then
              fail(string.format("shared dependency '%s' failed: %s", name, wait_err))
            else
              step(index + 1)
            end
          end
          return
        end
      end
      return response
        :text(string.format("Ability load coalesced: %s (pending)", name))
        :send()
    end
    if existing and (not is_root or not force_reload) then
      if is_root then
        return response
          :text(string.format("Ability ready: %s (unchanged)", name))
          :send()
      end
      return step(index + 1)
    end

    local ability = graph.abilities[name]
    pending[name] = { owner = root_call_id, preparing = true, waiters = {} }
    prepare_revision(ability, context.cwd, function(prepared, prepare_err, side_effect)
      if cancelled then
        local waiters = pending[name] and pending[name].waiters or {}
        clear_pending(key, name)
        for _, waiter in ipairs(waiters) do waiter("load cancelled before commit") end
        return
      end
      local allowed_now, policy_err_now = require("maxa.project.settings").check_ability(context.project_root or context.cwd, name)
      if not allowed_now then return fail(policy_err_now) end
      if not prepared then
        local waiters = pending[name] and pending[name].waiters or {}
        if side_effect and side_effect.transport then
          transport_effects[#transport_effects + 1] = name .. "@" .. tostring(side_effect.transport)
        end
        local message = string.format("Ability '%s' preparation failed: %s", name, tostring(prepare_err))
        fail(message)
        return
      end
      if existing and existing.digest == prepared.revision.digest then
        clear_pending(key, name)
        if is_root then
          return response
            :text(string.format("Ability ready: %s (unchanged after refresh)", name))
            :send()
        end
        return step(index + 1)
      end
      local waiters = pending[name] and pending[name].waiters or {}
      pending[name] = { revision = prepared.revision, owner = root_call_id, waiters = waiters }
      if is_root then
        local queued, queue_err = enqueue_root_commit(chat, prepared, root_call_id, key, graph)
        if not queued then
          return fail(queue_err)
        end
        for _, waiter in ipairs(waiters) do waiter(nil) end
        return response:text(prepared.revision.catalog):send()
      end
      local dependency_item_id, dependency_call_id = synthetic_tool_ids("dependency", root_call_id .. "\n" .. name)
      local queued, queue_err = enqueue_dependency_commit(chat, prepared, dependency_call_id, dependency_item_id, key)
      if not queued then
        return fail(queue_err)
      end
      completed_dependencies[#completed_dependencies + 1] = name
      for _, waiter in ipairs(waiters) do waiter(nil) end
      step(index + 1)
    end)
  end

  step(1)
end

local function inject_reference(chat, content, context_id, display_name)
  local message = ability_utils.build_context_message({
    content = content,
    context_id = context_id,
    tag = "ability_reference",
    title = display_name,
  })
  ability_utils.insert_context_message(chat, nil, message)
end

local function load_file_reference(context, response, resolved, force_reload)
  local ability_name, suffix, entry = resolved.ability_name, resolved.target, resolved.file
  local reference = ability_catalog.format_reference(ability_name, suffix)
  local chat = ability_utils.get_chat_and_agent(context)
  if not chat or not chat.messages then
    return response:error("load: exact Chat session is unavailable")
  end
  if not entry.path:match("%.md$") then
    return response:error("load: Ability file references must be Markdown: " .. suffix)
  end
  local context_id = abilities.REFERENCE_PREFIX .. "file:" .. reference
  if not force_reload and ability_utils.has_context_item(chat.messages, context_id) then
    return response:text("Ability reference already loaded: " .. reference):send()
  end
  local content, read_err = read_file(entry.path)
  if not content then
    return response:error("load: cannot read Ability file: " .. tostring(read_err))
  end
  local sanitized, sanitize_err = ability_utils.sanitize_context_markdown(content, {
    kind = "ability_reference",
    absolute_path = entry.path,
    display_name = reference,
  })
  if not sanitized then
    return response:error("load: " .. tostring(sanitize_err))
  end
  inject_reference(chat, sanitized.body, context_id, sanitized.suppress_title and nil or sanitized.display_name)
  builtin_utils.fire_file_event(context, "read", entry.path, "load")
  return response:text("Ability file reference loaded: " .. reference):send()
end

local function resource_text(result)
  if type(result) == "table" and type(result.result) == "table" then
    result = result.result
  end
  local parts = type(result) == "table" and (result.contents or result.content) or result
  if type(parts) == "string" then
    return parts
  end
  if type(parts) ~= "table" then
    return nil, "MCP resource returned no textual content"
  end
  if not (vim.islist or vim.tbl_islist)(parts) then
    parts = { parts }
  end
  local text = {}
  for index, part in ipairs(parts) do
    if type(part) == "string" then
      text[#text + 1] = part
    elseif type(part) == "table" and (part.type == nil or part.type == "text") and type(part.text) == "string" then
      text[#text + 1] = part.text
    else
      return nil, string.format("MCP resource part %d is non-text and cannot be loaded", index)
    end
  end
  return table.concat(text, "\n")
end

local function load_resource_reference(context, response, content, force_reload)
  local ability_name, suffix, resolved = content.ability_name, content.target, content.resource
  local reference = ability_catalog.format_reference(ability_name, suffix)
  local chat = ability_utils.get_chat_and_agent(context)
  if not chat or not chat.messages then
    return response:error("load: exact Chat session is unavailable")
  end
  local context_id = abilities.REFERENCE_PREFIX .. "resource:" .. reference
  if not force_reload and ability_utils.has_context_item(chat.messages, context_id) then
    return response:text("Ability content reference already loaded: " .. reference):send()
  end
  local cancelled = false
  require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge").register_handle({
    cancel = function() cancelled = true end,
  })
  local transport = require("maxa.mcphub").get_project_transport()
  transport.access_resource(context.cwd, resolved.server_name, resolved.uri, {
    project_root = context.project_root or context.cwd,
    callback = function(result, access_err)
      if cancelled then return end
      local allowed, policy_err = require("maxa.project.settings").check_ability(context.project_root or context.cwd, ability_name)
      if not allowed then return response:error("load: " .. tostring(policy_err)) end
      if not result then
        return response:error("load: " .. tostring(access_err))
      end
      local content, text_err = resource_text(result)
      if not content then
        return response:error("load: " .. tostring(text_err))
      end
      inject_reference(chat, content, context_id, reference)
      response:text("Ability content reference loaded: " .. reference):send()
    end,
  })
end

local function load_reference(context, response, target, force_reload)
  local resolved, err = ability_utils.resolve_reference(context, target)
  if not resolved then
    return response:error("load: " .. tostring(err))
  end
  if resolved.file then
    return load_file_reference(context, response, resolved, force_reload)
  end
  return load_resource_reference(context, response, resolved, force_reload)
end

local function load_markdown_file(context, response, target, force_reload)
  local path = require("plenary.path"):new(target)
  if not path:exists() then
    return response:error("load: file not found: " .. target)
  end
  if path:is_dir() then
    return response:error("load: not a file: " .. target)
  end
  local absolute = path:absolute()
  local info, classify_err = ability_utils.classify_context_path(absolute, context.cwd)
  if not info then
    return response:error("load: " .. tostring(classify_err))
  end
  local chat = ability_utils.get_chat_and_agent(context)
  if not chat or not chat.messages then
    return response:error("load: exact Chat session is unavailable")
  end
  if not force_reload and ability_utils.has_context_item(chat.messages, absolute) then
    return response:text("Context file already loaded: " .. absolute):send()
  end
  local content, read_err = read_file(absolute)
  if not content then
    return response:error("load: cannot read file: " .. tostring(read_err))
  end
  local sanitized, sanitize_err = ability_utils.sanitize_context_markdown(content, info)
  if not sanitized then
    return response:error("load: " .. tostring(sanitize_err))
  end
  local message = ability_utils.build_context_message({
    content = sanitized.body,
    context_id = absolute,
    tag = "context_file",
    title = sanitized.suppress_title and nil or sanitized.display_name,
  })
  ability_utils.insert_context_message(chat, nil, message)
  builtin_utils.fire_file_event(context, "read", absolute, "load")
  return response:text(string.format("Context file loaded: %s", absolute)):send()
end

local function run(context, response)
  if not context or not context.params then
    return response:error("load: invalid request object")
  end
  local params = param_utils.normalize(context.params)
  local target = vim.trim(tostring(params.target or ""))
  local force_reload = param_utils.boolean(params.force_reload, false)
  if target == "" then
    return response:error("load: target is required")
  end
  if ability_catalog.valid_identifier(target) then
    return load_root(context, response, target, force_reload)
  end
  if target:sub(1, 1) == "#" then
    return load_reference(context, response, target, force_reload)
  end
  return load_markdown_file(context, response, target, force_reload)
end

return {
  name = "load",
  display = function(args)
    return { summary = type(args.target) == "string" and args.target ~= "" and ("load " .. args.target) or "load" }
  end,
  description = [[Load an Ability, an Ability reference, or one allowed Markdown context path.

Use an exact Ability identifier for capability loading, `#ability[target]` for Ability content, or an existing whitelisted Markdown path. Leading / targets try a root-confined current package Markdown file without loading/disclosure; only file absence falls back to committed content in the exact Chat/workspace. Other targets resolve directly to committed content with unchanged identifiers. File injection does not load or activate the Ability. First and changed Ability loads return the disclosed directly composable catalog.]],
  inputSchema = {
    type = "object",
    properties = {
      target = { type = "string", description = "Ability identifier, #ability[target] content reference, or allowed Markdown path." },
      force_reload = { type = "boolean", description = "Refresh sources or re-read context even when previously loaded.", default = false },
    },
    required = { "target" },
    additionalProperties = false,
  },
  run = run,
}
