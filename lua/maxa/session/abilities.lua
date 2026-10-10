local cc_config = require("maxa.config")

local M = {}

M.REVISION_PREFIX = "ability:revision:"
M.INSTRUCTIONS_PREFIX = "ability:instructions:"
M.GUIDANCE_PREFIX = "ability:guidance:"
M.REFERENCE_PREFIX = "ability:reference:"

local function deepcopy(value)
  return vim.deepcopy(value)
end

local function tool_result_call_id(message)
  return message and ((message.tools and message.tools.call_id) or message.tool_call_id) or nil
end

local function context_message(id, tag, content, ability)
  return {
    role = cc_config.constants.USER_ROLE,
    content = content,
    context = { id = id },
    _meta = { tag = tag, ability = ability },
    opts = { visible = false },
  }
end

local function normalize_tool(tool)
  if type(tool) ~= "table" or type(tool.name) ~= "string" or vim.trim(tool.name) == "" then
    return nil, "MCP tool name must be nonblank"
  end
  if tool.name:sub(1, 1) == "/" then
    return nil, "MCP tool name must not begin with /: " .. tool.name
  end
  local description = tool.description
  if type(description) == "function" then
    local ok, value = pcall(description, tool)
    if not ok then
      return nil, "MCP tool description failed: " .. tostring(value)
    end
    description = value
  end
  local input_schema = tool.inputSchema
  if type(input_schema) == "function" then
    local ok, value = pcall(input_schema, tool)
    if not ok then
      return nil, "MCP tool inputSchema failed: " .. tostring(value)
    end
    input_schema = value
  end
  if type(input_schema) ~= "table" then
    return nil, "MCP tool inputSchema must be an object: " .. tool.name
  end
  return {
    name = tool.name,
    description = type(description) == "string" and description or "",
    inputSchema = deepcopy(input_schema),
  }
end

function M.normalize_tools(tools)
  local result, seen = {}, {}
  for _, tool in ipairs(tools or {}) do
    local normalized, err = normalize_tool(tool)
    if not normalized then
      return nil, err
    end
    if seen[normalized.name] then
      return nil, "duplicate MCP tool name: " .. normalized.name
    end
    seen[normalized.name] = true
    result[#result + 1] = normalized
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

function M.normalize_resources(ability_name, resources)
  local result, seen = {}, {}
  for _, resource in ipairs(resources or {}) do
    if type(resource) ~= "table" or type(resource.uri) ~= "string" or vim.trim(resource.uri) == "" or resource.uri:find("[\r\n]") then
      return nil, "MCP concrete resource URI must be nonblank and single-line"
    end
    if seen[resource.uri] then
      return nil, "duplicate MCP resource URI: " .. resource.uri
    end
    seen[resource.uri] = true
    result[#result + 1] = {
      uri = resource.uri,
      name = type(resource.name) == "string" and resource.name or "",
      description = type(resource.description) == "string" and resource.description or "",
      mimeType = type(resource.mimeType) == "string" and resource.mimeType or nil,
    }
  end
  table.sort(result, function(a, b)
    return a.uri < b.uri
  end)
  return result
end

local function compact_description(value)
  return vim.trim(tostring(value or ""):gsub("%s+", " "))
end

function M.render_catalog(revision)
  local lines = { "ability: " .. revision.name, "", string.format("roots[%d]:", #(revision.roots or {})) }
  for _, root in ipairs(revision.roots or {}) do
    lines[#lines + 1] = "  " .. root
  end
  if #(revision.scripts or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("scripts[%d]:", #revision.scripts)
    for _, script in ipairs(revision.scripts) do
      lines[#lines + 1] = "  " .. script.target
    end
  end
  if #(revision.tools or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("tools[%d]{name,description,inputSchema}:", #revision.tools)
    for _, tool in ipairs(revision.tools) do
      lines[#lines + 1] = string.format(
        "  %s,%s,%s",
        vim.json.encode(tool.name),
        vim.json.encode(compact_description(tool.description)),
        vim.json.encode(tool.inputSchema)
      )
    end
  end
  local references = {}
  for _, reference in ipairs(revision.references or {}) do
    references[#references + 1] = require("maxa.abilities.catalog").format_reference(revision.name, reference.target)
  end
  for _, resource in ipairs(revision.resources or {}) do
    references[#references + 1] = require("maxa.abilities.catalog").format_reference(revision.name, resource.uri)
  end
  if #references > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("references[%d]:", #references)
    for _, reference in ipairs(references) do
      lines[#lines + 1] = "  " .. reference
    end
  end
  return table.concat(lines, "\n")
end

local function serializable_script(entry)
  return {
    target = entry.target,
    path = entry.path,
    root = entry.root,
    executable = entry.executable == true,
    executor = entry.executor and { match = entry.executor.match, command = deepcopy(entry.executor.command) } or nil,
  }
end

local function serializable_reference(entry)
  return { target = entry.target, path = entry.path, root = entry.root }
end

function M.build_revision(opts)
  local ability = assert(opts.ability)
  local revision = {
    name = ability.name,
    roots = deepcopy(ability.roots or {}),
    visibility = ability.visibility,
    triggers = deepcopy(ability.triggers or {}),
    dependencies = deepcopy(ability.dependencies or {}),
    builtin_extensions = deepcopy(ability.builtin_extensions or {}),
    scripts = {},
    references = {},
    hidden_references = {},
    tools = deepcopy(opts.tools or {}),
    resources = deepcopy(opts.resources or {}),
    provenance = deepcopy(opts.provenance),
    has_mcp = ability.mcp ~= nil,
    instructions_sha256 = opts.instructions and vim.fn.sha256(opts.instructions) or nil,
    guidance_sha256 = opts.guidance and vim.fn.sha256(opts.guidance) or nil,
    hooks = deepcopy(opts.hooks or {}),
  }
  for _, script in ipairs(ability.scripts or {}) do
    revision.scripts[#revision.scripts + 1] = serializable_script(script)
  end
  for _, reference in ipairs(ability.references or {}) do
    revision.references[#revision.references + 1] = serializable_reference(reference)
  end
  for _, reference in pairs(ability.hidden_references or {}) do
    revision.hidden_references[#revision.hidden_references + 1] = serializable_reference(reference)
  end
  table.sort(revision.hidden_references, function(a, b) return a.target < b.target end)
  revision.digest = vim.fn.sha256(vim.json.encode(revision))
  revision.catalog = M.render_catalog(revision)
  return revision
end

local function result_has_catalog(message, catalog)
  if not message or message.role ~= "tool" or type(message.content) ~= "string" then
    return false
  end
  if message.content:find(catalog, 1, true) then
    return true
  end
  local encoded = vim.json.encode(catalog)
  local escaped_body = encoded:sub(2, -2)
  return escaped_body ~= "" and message.content:find(escaped_body, 1, true) ~= nil
end

function M.find_catalog_result(messages, call_id, catalog)
  if not call_id then
    return nil
  end
  for index = #(messages or {}), 1, -1 do
    local message = messages[index]
    if tool_result_call_id(message) == call_id and result_has_catalog(message, catalog) then
      return message
    end
  end
  return nil
end

function M.mark_catalog_result(message, revision)
  message._meta = message._meta or {}
  message._meta.tag = "ability_catalog"
  message._meta.ability_catalogs = message._meta.ability_catalogs or {}
  message._meta.ability_catalogs[revision.name] = {
    name = revision.name,
    digest = revision.digest,
    catalog = revision.catalog,
  }
end

function M.synthetic_catalog_pair(revision, call_id, item_id)
  local arguments = vim.json.encode({ target = revision.name })
  local call = {
    id = item_id or call_id,
    call_id = call_id,
    type = "function",
    ["function"] = { name = "load", arguments = arguments },
  }
  local assistant = {
    role = cc_config.constants.LLM_ROLE or "assistant",
    content = "",
    tools = { calls = { call } },
    _meta = { ability_dependency_catalog = revision.name },
    opts = { visible = false },
  }
  local result = {
    role = "tool",
    content = revision.catalog,
    tools = { id = item_id or call_id, call_id = call_id, type = "tool_result" },
    _meta = { ability_dependency_catalog = revision.name },
    opts = { visible = false },
  }
  M.mark_catalog_result(result, revision)
  return assistant, result
end

function M.build_context_batch(revision, instructions, guidance, call_id)
  local base = {
    name = revision.name,
    digest = revision.digest,
    catalog_call_id = call_id,
    revision = deepcopy(revision),
  }
  local batch = {
    context_message(
      M.REVISION_PREFIX .. revision.name,
      "ability_revision",
      string.format("Ability revision committed: %s (%s)", revision.name, revision.digest),
      vim.tbl_extend("force", deepcopy(base), { kind = "revision" })
    ),
  }
  if instructions and instructions ~= "" then
    batch[#batch + 1] = context_message(
      M.INSTRUCTIONS_PREFIX .. revision.name,
      "ability_instructions",
      instructions,
      vim.tbl_extend("force", deepcopy(base), { kind = "instructions" })
    )
  end
  if guidance and guidance ~= "" then
    batch[#batch + 1] = context_message(
      M.GUIDANCE_PREFIX .. revision.name,
      "ability_guidance",
      guidance,
      vim.tbl_extend("force", deepcopy(base), { kind = "guidance" })
    )
  end
  return batch
end

local function latest_revision_messages(messages)
  local latest = {}
  for index = #(messages or {}), 1, -1 do
    local message = messages[index]
    local ability = message._meta and message._meta.ability
    if ability and ability.kind == "revision"
      and require("maxa.abilities.catalog").valid_identifier(ability.name) and latest[ability.name] == nil then
      latest[ability.name] = message
    end
  end
  return latest
end

local function provenance_matches(provenance, cwd)
  if provenance == nil then
    return true
  end
  local transport = require("maxa.mcphub").get_project_transport()
  local resolved, err = transport.resolve(cwd)
  if not resolved then
    return false, err
  end
  return provenance.workspace_key == resolved.workspace_key, nil, resolved.catalog
end

function M.catalog(chat, cwd)
  local result = { abilities = {}, order = {} }
  for name, message in pairs(latest_revision_messages(chat and chat.messages)) do
    local meta = message._meta.ability
    local revision = meta.revision
    local result_message = revision and M.find_catalog_result(chat.messages, meta.catalog_call_id, revision.catalog) or nil
    local provenance_ok, provenance_err, effective = false, nil, nil
    if revision then provenance_ok, provenance_err, effective = provenance_matches(revision.provenance, cwd) end
    if provenance_ok == false and type(provenance_err) == "string" then
      return nil, provenance_err
    end
    local root = chat and chat.opts and chat.opts.project_root or cwd
    local enabled, policy_err = require("maxa.project.settings").ability_enabled(root, name)
    if enabled == nil then return nil, policy_err end
    if enabled and revision and revision.has_mcp and effective then
      local source = effective.servers and effective.servers[name]
      enabled = source ~= nil
    end
    if revision and result_message and provenance_ok and enabled then
      result.abilities[name] = {
        name = name,
        revision = revision,
        revision_message = message,
        result_message = result_message,
      }
    end
  end
  local seen = {}
  for _, message in ipairs(chat and chat.messages or {}) do
    local meta = message._meta and message._meta.ability
    if meta and meta.kind == "revision" and result.abilities[meta.name] and not seen[meta.name] then
      seen[meta.name] = true
      result.order[#result.order + 1] = meta.name
    end
  end
  return result
end

function M.get_ready(chat, cwd, name)
  local allowed, policy_err = require("maxa.project.settings").check_ability(chat and chat.opts and chat.opts.project_root or cwd, name)
  if not allowed then return nil, policy_err end
  local catalog, err = M.catalog(chat, cwd)
  if not catalog then
    return nil, err
  end
  return catalog.abilities[name], nil
end

function M.resolve_tool(chat, cwd, ability_name, tool_name)
  local ready, err = M.get_ready(chat, cwd, ability_name)
  if not ready then
    return nil, err or string.format("Ability '%s' is not ready in this Chat/workspace; use load(target=%q)", ability_name, ability_name)
  end
  for _, tool in ipairs(ready.revision.tools or {}) do
    if tool.name == tool_name then
      if not ready.revision.has_mcp then
        break
      end
      return {
        ability_name = ability_name,
        server_name = ability_name,
        tool_name = tool_name,
        tool = tool,
        provenance = ready.revision.provenance,
      }
    end
  end
  return nil, string.format("MCP tool is not cataloged for Ability '%s': %s", ability_name, tool_name)
end

function M.resolve_resource(chat, cwd, ability_name, target)
  local ready, err = M.get_ready(chat, cwd, ability_name)
  if not ready then
    return nil, err or string.format("Ability '%s' is not ready in this Chat/workspace; use load(target=%q)", ability_name, ability_name)
  end
  for _, resource in ipairs(ready.revision.resources or {}) do
    if resource.uri == target then
      return {
        ability_name = ability_name,
        server_name = ability_name,
        uri = resource.uri,
        resource = resource,
        provenance = ready.revision.provenance,
      }
    end
  end
  return nil, string.format("Content is not cataloged for Ability '%s': %s", ability_name, target)
end

function M.resolve_script(chat, cwd, ability_name, target)
  local ready, err = M.get_ready(chat, cwd, ability_name)
  if not ready then
    return nil, err or string.format("Ability '%s' is not ready in this Chat/workspace; use load(target=%q)", ability_name, ability_name)
  end
  for _, script in ipairs(ready.revision.scripts or {}) do
    if script.target == target then
      local resolved = vim.uv.fs_realpath(script.path)
      local root = vim.uv.fs_realpath(script.root)
      local stat = resolved and vim.uv.fs_stat(resolved) or nil
      local root_prefix = root and (root:sub(-1) == "/" and root or root .. "/") or nil
      if not resolved or not root or (resolved ~= root and resolved:sub(1, #root_prefix) ~= root_prefix) or not stat or stat.type ~= "file" then
        return nil, "Ability script is missing, replaced or outside its owning root: " .. target
      end
      return vim.tbl_extend("force", deepcopy(script), { path = resolved, root = root })
    end
  end
  return nil, string.format("script is not cataloged for Ability '%s': %s", ability_name, target)
end

function M.rehydrate(chat)
  local cwd = chat and chat.opts and chat.opts.cwd
  if type(cwd) ~= "string" or cwd == "" then
    return nil
  end
  local catalog, err = M.catalog(chat, cwd)
  if not catalog then
    vim.notify("[Maxa AI] Ability restore skipped: " .. tostring(err), vim.log.levels.WARN)
    return nil
  end
  return catalog
end

return M
