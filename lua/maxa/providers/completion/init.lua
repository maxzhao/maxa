local config = require("maxa.config")
local slash_command_filter = require("maxa.interactions.chat.slash_commands.filter")

local api = vim.api
local trigger = {
  slash_commands = "/",
  tools = "@",
  variables = "#",
}

local M = {}
local adapter_cache = {}

---Find the literal completion token ending at a byte column.
---@param line string
---@param col number zero-based byte column
---@return table|nil { trigger: string, start_col: number, text: string }
function M.token_at_cursor(line, col, bufnr)
  local before = tostring(line or ""):sub(1, col)
  -- Bracket targets may contain spaces and their own #/@ trigger characters.
  local scan = 1
  while true do
    local start, opening_end, name = before:find("#([%w-]+)%[", scan)
    if not start then break end
    if require("maxa.abilities.catalog").valid_identifier(name) then
      local text = before:sub(start)
      local tail = before:sub(opening_end + 1)
      local closed = tail:find("%][%p]*%s") or tail:find("%][%p]+$")
      local active = not closed
      if not active then
        -- A known target may itself contain '] '; don't mistake it for framing.
        for _, item in ipairs(M.variables(bufnr)) do
          if item.label:sub(1, #text) == text then active = true; break end
        end
      end
      if active then
        return { trigger = "#", start_col = start - 1, text = text }
      end
    end
    scan = opening_end + 1
  end
  local start_col = before:find("[@#][^%s]*$")
  if not start_col then
    start_col = before:find("/[%w_:%-]*$")
  end
  if not start_col then
    return nil
  end
  local text = before:sub(start_col)
  return { trigger = text:sub(1, 1), start_col = start_col - 1, text = text }
end
local aug = api.nvim_create_augroup("maxa.ai.completion", { clear = true })

api.nvim_create_autocmd("User", {
  group = aug,
  pattern = { "MaxaAIChatAdapter", "MaxaAIChatModel" },
  callback = function(args)
    local bufnr = args.data.bufnr
    local has_adapter_field = false
    for k in pairs(args.data) do
      if k == "adapter" then
        has_adapter_field = true
        break
      end
    end
    if has_adapter_field then
      if args.data.adapter then
        slash_command_filter.refresh_cache()
        adapter_cache[bufnr] = args.data.adapter
      else
        adapter_cache[bufnr] = nil
      end
    end
  end,
})

api.nvim_create_autocmd("User", {
  group = aug,
  pattern = "MaxaAIChatClosed",
  callback = function(args)
    adapter_cache[args.data.bufnr] = nil
  end,
})

---@param bufnr? integer
function M.slash_commands(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local adapter_info = adapter_cache[bufnr]
  local filtered = slash_command_filter.filter_enabled_slash_commands(
    config.interactions.chat.slash_commands,
    { adapter = adapter_info }
  )
  local slash_commands = vim
    .iter(filtered)
    :filter(function(name)
      return name ~= "opts"
    end)
    :map(function(label, value)
      return {
        label = trigger.slash_commands .. label,
        detail = value.description,
        config = value,
        type = "slash_command",
      }
    end)
    :totable()

  local reserved = {}
  for name in pairs(config.interactions.chat.slash_commands) do
    if name ~= "opts" then reserved[("/" .. name):lower()] = true end
  end

  for _, value in ipairs(require("maxa.helpers").get_prompts(bufnr)) do
    local prompt = {
      detail = value.description,
      config = value,
      type = "slash_command",
      from_prompt_library = true,
      label = "/" .. value.command_name,
    }
    if not reserved[prompt.label:lower()] then table.insert(slash_commands, prompt) end
  end
  return slash_commands
end

local SNAPSHOT_COMMANDS = { compact_silent = true, compact_rescue = true }

local function valid_position(bufnr, position)
  if type(position) ~= "table" then
    return nil
  end
  local row = tonumber(position.row)
  local col = tonumber(position.col)
  if not row or not col or row < 0 or col < 0 or row >= api.nvim_buf_line_count(bufnr) then
    return nil
  end
  local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if type(line) ~= "string" or col > #line then
    return nil
  end
  return { row = row, col = col }
end

---@param selected table
---@param chat MaxaAI.Chat
---@param bufnr integer
---@param range { start: MaxaAI.SlashCommandAnchor, end: MaxaAI.SlashCommandAnchor, revalidate_selection?: boolean }
---@return boolean, string|nil
function M.prepare_slash_command(selected, chat, bufnr, range)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return false, "invalid slash command buffer"
  end

  local start_pos = valid_position(bufnr, range and range.start)
  local end_pos = valid_position(bufnr, range and range["end"])
  if not start_pos or not end_pos then
    return false, "invalid slash command range"
  end
  if end_pos.row < start_pos.row or (end_pos.row == start_pos.row and end_pos.col < start_pos.col) then
    return false, "reversed slash command range"
  end
  if start_pos.row ~= end_pos.row then
    return false, "slash command range must stay on one line"
  end
  if chat and chat.bufnr == bufnr and tonumber(chat.header_line) and start_pos.row < chat.header_line then
    return false, "slash command range is outside the editable user area"
  end

  local token_lines = api.nvim_buf_get_text(
    bufnr,
    start_pos.row,
    start_pos.col,
    end_pos.row,
    end_pos.col,
    {}
  )
  local token = table.concat(token_lines, "\n")
  if not token:match("^/[%w_:%-]*$") then
    return false, string.format("slash command range contains invalid token `%s`", token)
  end

  local command_label = selected.command or selected.label
  if type(command_label) ~= "string" or command_label == "" then
    return false, "slash command selection is unavailable"
  end
  if command_label:sub(1, 1) ~= "/" then
    command_label = "/" .. command_label
  end

  if range.revalidate_selection then
    local current = vim.iter(M.slash_commands(bufnr)):find(function(item)
      return item.label == command_label
    end)
    if not current then
      return false, string.format("slash command `%s` is no longer available", command_label)
    end
    selected.label = current.label
    selected.config = current.config
    selected.type = current.type
    selected.from_prompt_library = current.from_prompt_library
  end

  selected.context = selected.context or {}
  selected.context.bufnr = bufnr
  selected.context.cursor = { row = end_pos.row + 1, col = end_pos.col }
  selected.context.slash_anchor = vim.deepcopy(start_pos)
  selected.context.slash_token = token
  selected.context.slash_range = { start = vim.deepcopy(start_pos), ["end"] = vim.deepcopy(end_pos) }

  if selected.from_prompt_library and selected.config.snip then
    local prepared, prepare_err = require("maxa.interactions.chat.snippets").prepare(selected, chat)
    if not prepared then return false, prepare_err end
  end
  M.capture_slash_command_input(selected, chat, bufnr, selected.context.cursor)

  local ok, err = pcall(
    api.nvim_buf_set_text,
    bufnr,
    start_pos.row,
    start_pos.col,
    end_pos.row,
    end_pos.col,
    {}
  )
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

function M.capture_slash_command_input(selected, chat, bufnr, cursor)
  local label = selected and selected.label
  local name = type(label) == "string" and label:gsub("^/", "") or nil
  if not name or not SNAPSHOT_COMMANDS[name] or not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local text
  if chat and chat.header_line and chat.chat_parser then
    local ok, message = pcall(require("maxa.interactions.chat.parser").messages, chat, chat.header_line)
    if ok and message and type(message.content) == "string" and vim.trim(message.content) ~= "" then
      text = message.content
    end
  end
  if not text then
    local start_line = math.max(1, tonumber(chat and chat.header_line) or 1)
    local end_line = cursor and (cursor.row or cursor[1]) or api.nvim_buf_line_count(bufnr)
    local ok, lines = pcall(api.nvim_buf_get_lines, bufnr, start_line - 1, math.max(start_line, end_line), false)
    text = ok and lines and table.concat(lines, "\n") or nil
  end
  if text and vim.trim(text) ~= "" then
    selected.context = selected.context or {}
    selected.context.bufnr = selected.context.bufnr or bufnr
    selected.context.cursor = selected.context.cursor or cursor
    selected.context.pre_slash_command_input = text
    selected.context.pre_slash_command_name = name
  end
end

local function execute_markdown_slash(selected, chat, prompts)
  local saw_user = false
  local has_llm = false
  for _, prompt in ipairs(prompts or {}) do
    if prompt.role == config.constants.USER_ROLE then
      saw_user = true
    elseif prompt.role == config.constants.LLM_ROLE then
      if not saw_user then
        vim.notify("[Prompt Library] `## llm` must follow a `## user` section", vim.log.levels.ERROR)
        return false
      end
      has_llm = true
    else
      vim.notify(
        string.format("[Prompt Library] Unsupported slash prompt role `%s`", tostring(prompt.role)),
        vim.log.levels.ERROR
      )
      return false
    end
  end

  if not saw_user then
    vim.notify("[Prompt Library] Markdown slash command has no `## user` section", vim.log.levels.ERROR)
    return false
  end

  if has_llm then
    require("maxa.interactions.chat.slash_commands.insertion").discard_anchor(chat, selected.context)
    local ok, err = chat:add_visible_history(prompts)
    if not ok then
      vim.notify("[Prompt Library] Could not insert visible prompt history: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    return true
  end

  local content = vim
    .iter(prompts)
    :filter(function(prompt)
      return prompt.role == config.constants.USER_ROLE
    end)
    :map(function(prompt)
      return prompt.content
    end)
    :totable()
  local inserted = require("maxa.interactions.chat.slash_commands.insertion").add_prompt(
    chat, selected.context, table.concat(content, "\n\n"), selected.config.insert
  )
  return inserted ~= nil
end

function M.slash_commands_execute(selected, chat)
  if selected.from_prompt_library then
    if selected.config.snip then
      local snippets = require("maxa.interactions.chat.snippets")
      local ok, err = snippets.expand(selected, chat)
      if not ok then
        vim.notify("[Prompt Library] " .. tostring(err), vim.log.levels.ERROR)
      elseif selected.config.context then
        require("maxa.interactions.chat.slash_commands").add_prompt_context(selected.config, chat)
      end
      return
    end
    local prompt_config = vim.deepcopy(selected.config)
    local prompts = require("maxa.prompts.markdown").resolve_placeholders(prompt_config, selected.context).prompts
    local inserted = execute_markdown_slash(selected, chat, prompts)
    if inserted and selected.config.context then
      require("maxa.interactions.chat.slash_commands").add_prompt_context(selected.config, chat)
    end
  else
    require("maxa.interactions.chat.snippets").stop(chat.bufnr)
    require("maxa.interactions.chat.slash_commands"):execute(selected, chat)
  end
end

local function exact_chat(bufnr)
  local ok, maxa_ai = pcall(require, "maxa")
  return ok and maxa_ai.buf_get_chat and maxa_ai.buf_get_chat(bufnr) or nil
end

local function add_candidate(index, prefix, name, kind, detail)
  if type(name) ~= "string" or name == "" or name:find("[\r\n]") or (prefix ~= "#" and name:find("%s")) then
    return
  end
  local label = prefix .. name
  local item = index[label]
  if not item then
    item = { label = label, name = name, type = kind, kinds = {}, details = {} }
    index[label] = item
  end
  if not vim.tbl_contains(item.kinds, kind) then
    item.kinds[#item.kinds + 1] = kind
  end
  if type(detail) == "string" and detail ~= "" and not vim.tbl_contains(item.details, detail) then
    item.details[#item.details + 1] = detail
  end
  return item
end

local function finalize_candidates(index)
  local labels = vim.tbl_keys(index)
  table.sort(labels)
  local result = {}
  for _, label in ipairs(labels) do
    local item = index[label]
    item.detail = table.concat(item.details, " | ")
    item.description = table.concat(item.kinds, ", ")
    result[#result + 1] = item
  end
  return result
end

---Build the shared side-effect-free literal @/# catalog for one exact Chat.
---@param bufnr? integer
---@return table
function M.mentions(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local chat = exact_chat(bufnr)
  local cwd = chat and chat.opts and chat.opts.cwd
  if not chat or type(cwd) ~= "string" or cwd == "" then
    return { at = {}, hash = {} }
  end

  local at, hash = {}, {}
  for name in pairs((chat.tool_registry and chat.tool_registry.in_use) or {}) do
    if type(name) == "string" and not name:find("__", 1, true) then
      local tool_config = config.interactions.chat.tools[name] or {}
      add_candidate(at, "@", name, "tool", tool_config.description)
    end
  end

  local visible_abilities = {}
  local discovered = require("maxa.abilities.catalog").list(chat.opts.project_root or cwd)
  if discovered then
    for _, ability in ipairs(discovered.abilities or {}) do
      if ability.enabled ~= false and ability.visibility ~= "hidden" then
        visible_abilities[ability.name] = ability
        add_candidate(at, "@", ability.name, "ability", ability.skill and ability.skill.description or "MCP-backed Ability")
        for _, reference in ipairs(ability.references or {}) do
          if reference.target:match("%.md$") then
            local label = require("maxa.abilities.catalog").format_reference(ability.name, reference.target)
            add_candidate(hash, "#", label:sub(2), "ability_file", "Ability content")
          end
        end
      end
    end
  end

  local config_manager = require("maxa.mcphub.utils.config_manager")
  local configured, config_err = config_manager.get_effective_catalog(cwd)
  local loaded, load_err = require("maxa.session.abilities").catalog(chat, cwd)
  if loaded then
    local names = vim.tbl_keys(loaded.abilities)
    table.sort(names)
    for _, ability_name in ipairs(names) do
      local revision = loaded.abilities[ability_name].revision
      local disabled = revision.has_mcp and configured and config_manager.is_server_disabled(configured, ability_name)
      if disabled then
        goto continue_ability
      end
      local capabilities = revision
      local source = configured and configured.servers[ability_name]
      if revision.has_mcp and source and source.is_native then
        local ability = visible_abilities[ability_name]
        if not ability or not ability.mcp then
          goto continue_ability
        end
        capabilities = config_manager.filter_effective_capabilities(configured, ability_name, {
          tools = revision.tools, resources = revision.resources,
        }) or {}
      end
      for _, script in ipairs(revision.scripts or {}) do
        add_candidate(at, "@", ability_name .. ":" .. script.target, "ability_script", "External-process Ability entrypoint")
      end
      for _, tool in ipairs(capabilities.tools or {}) do
        add_candidate(at, "@", ability_name .. ":" .. tool.name, "ability_tool", tool.description)
      end
      for _, reference in ipairs(revision.references or {}) do
        local label = require("maxa.abilities.catalog").format_reference(ability_name, reference.target)
        add_candidate(hash, "#", label:sub(2), "ability_file", "Ability content")
      end
      for _, resource in ipairs(capabilities.resources or {}) do
        local label = require("maxa.abilities.catalog").format_reference(ability_name, resource.uri)
        if not hash[label] then
          local item = add_candidate(hash, "#", label:sub(2), "ability_resource", resource.description)
          if item then item.mimeType = resource.mimeType end
        end
      end
      ::continue_ability::
    end
  end

  -- Native definitions are already local; preview them without loading or
  -- connecting the source. Committed candidates retain their descriptions.
  for _, ability in ipairs(discovered and discovered.abilities or {}) do
    local source = configured and configured.servers[ability.name]
    if ability.enabled ~= false and ability.visibility ~= "hidden" and ability.mcp and source and source.is_native
      and not config_manager.is_server_disabled(configured, ability.name) then
      local server = require("maxa.mcphub.native").is_native_server(ability.name)
      local capabilities = server and config_manager.filter_effective_capabilities(configured, ability.name, server.capabilities)
      for _, tool in ipairs(capabilities and capabilities.tools or {}) do
        local name = ability.name .. ":" .. tool.name
        if not at["@" .. name] then
          add_candidate(at, "@", name, "ability_tool", type(tool.description) == "string" and tool.description or nil)
        end
      end
      for _, resource in ipairs(capabilities and capabilities.resources or {}) do
        if type(resource.uri) == "string" and vim.trim(resource.uri) ~= "" then
          local label = require("maxa.abilities.catalog").format_reference(ability.name, resource.uri)
          if not hash[label] then
            local item = add_candidate(hash, "#", label:sub(2), "ability_resource", type(resource.description) == "string" and resource.description or nil)
            if item then
              item.mimeType = resource.mimeType
              item.load_ability = not (loaded and loaded.abilities[ability.name]) and ability.name or nil
            end
          end
        end
      end
    end
  end

  return { at = finalize_candidates(at), hash = finalize_candidates(hash), error = load_err or config_err }
end

function M.tools(bufnr)
  return M.mentions(bufnr).at
end

function M.variables(bufnr)
  return M.mentions(bufnr).hash
end

return M
