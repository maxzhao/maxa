local api = vim.api
local config = require("maxa.config")
local catalog = require("maxa.abilities.catalog")
local completion = require("maxa.providers.completion")
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local injector = require("maxa.interactions.chat.tools.builtin.runtime.context_injector")
local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")

local SlashCommand = {}
SlashCommand.__index = SlashCommand

function SlashCommand.new(args)
  return setmetatable({ Chat = args.Chat }, SlashCommand)
end

local function live(chat)
  return chat and not chat._closed and chat.bufnr and api.nvim_buf_is_valid(chat.bufnr)
    and api.nvim_buf_is_loaded(chat.bufnr)
end

local function busy(chat)
  return chat.current_request or chat.current_tool or chat._tool_input or chat._slash_load
    or not vim.bo[chat.bufnr].modifiable
end

local function notify(message, level)
  vim.notify("/load: " .. message, level or vim.log.levels.ERROR)
end

local function textual(resource)
  local mime = resource.mimeType
  if not mime or mime == "" then return true end
  mime = mime:lower():match("^[^;]+")
  return mime:match("^text/") or mime == "application/json" or mime:match("%+json$")
    or mime == "application/xml" or mime:match("%+xml$") or mime == "application/yaml"
end

local function candidates(chat)
  local cwd = chat.opts and chat.opts.cwd
  if type(cwd) ~= "string" or cwd == "" then
    return nil, "Exact Chat working directory is unavailable"
  end
  local discovered, err = catalog.list(chat.opts.project_root or cwd)
  if not discovered then return nil, err end
  local items, seen = {}, {}
  local function add(target, kind, description, path, load_ability)
    if seen[target] then return end
    seen[target] = true
    items[#items + 1] = {
      target = target, kind = kind, description = description or "", path = path, load_ability = load_ability,
      text = target .. " " .. (description or ""),
    }
  end
  for _, ability in ipairs(discovered.abilities or {}) do
    if ability.visibility ~= "hidden" then
      add(ability.name, "Ability", ability.description, ability.skill and ability.skill.path)
      for _, reference in ipairs(ability.references or {}) do
        if reference.target:match("%.md$") then
          add(catalog.format_reference(ability.name, reference.target), "Markdown", ability.name, reference.path)
        end
      end
    end
  end
  local mentions = completion.mentions(chat.bufnr)
  if mentions.error then return nil, mentions.error end
  for _, item in ipairs(mentions.hash) do
    if item.type == "ability_resource" and textual(item) then
      add(item.label, "Resource", item.detail, nil, item.load_ability)
    end
  end
  table.sort(items, function(a, b) return a.target < b.target end)
  return items
end

local function save(chat)
  local ok, history = pcall(function() return require("maxa.session").history() end)
  if ok and history and history.save_chat then
    local saved, err = pcall(history.save_chat, chat)
    if not saved then notify("History save failed: " .. tostring(err)) end
  end
end

local function execute_selection(chat, selected)
  if not live(chat) or busy(chat) then
    return notify("Chat is busy or unavailable; wait before loading")
  end
  -- Confirmation explicitly loads each missing Native Ability before its
  -- resource; use the same real load queue and paired history for both.
  local targets, prepared = {}, {}
  for _, item in ipairs(selected) do
    if item.load_ability and not prepared[item.load_ability] then
      targets[#targets + 1] = { target = item.load_ability }
      prepared[item.load_ability] = true
    end
    targets[#targets + 1] = item
    prepared[item.target] = true
  end
  selected = targets
  local state = { draft = chat:capture_editable_draft(), index = 0 }
  chat._slash_load = state
  local cleanup
  local function store_result(tool, result)
    local output = result.ok and adapter.content_to_result(result.content) or tostring(result.error)
    local message = require("maxa.adapters").call_handler(chat.adapter, "format_response", tool.function_call, output,
      { is_error = not result.ok })
    message._meta = { cycle = chat.cycle, tag = "slash_load", is_error = not result.ok or nil }
    message.tools = message.tools or {}
    message.tools.is_error = not result.ok or nil
    message.opts = { visible = false }
    table.insert(chat.messages, message)
  end
  cleanup = function()
    if chat._slash_load ~= state then return end
    chat._slash_load = nil
    if state.group then api.nvim_del_augroup_by_id(state.group) end
    if state.cancel_id then bridge.clear(state.cancel_id) end
    if not live(chat) then return end
    local ok, err = pcall(chat.render_history, chat, state.draft)
    if not ok then notify("History render failed: " .. tostring(err)) end
    chat.ui:unlock_buf()
    save(chat)
  end
  state.cancel = function(reason)
    if chat._slash_load ~= state then return end
    state.cancelled = true
    if state.cancel_id then bridge.cancel(state.cancel_id, reason) end
    injector.discard(chat)
    if state.active_tool then
      store_result(state.active_tool, { ok = false, error = reason or "/load cancelled" })
      state.active_tool = nil
    end
    cleanup()
  end
  state.group = api.nvim_create_augroup("MaxaSlashLoad" .. chat.bufnr, { clear = true })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = state.group, buffer = chat.bufnr,
    callback = function() state.cancel("caller Chat was destroyed") end,
  })
  chat.ui:lock_buf()
  local definition = require("maxa.interactions.chat.tools.builtin").resolve("load")
  local function step()
    if state.cancelled or chat._slash_load ~= state then return end
    if not live(chat) then return state.cancel("caller Chat was destroyed") end
    state.index = state.index + 1
    local item = selected[state.index]
    if not item then return cleanup() end
    local seed = vim.fn.sha256(tostring(chat.id) .. ":" .. tostring(vim.uv.hrtime()) .. ":" .. state.index):sub(1, 32)
    local call = {
      id = "fc_slash_load_" .. seed, call_id = "call_slash_load_" .. seed, type = "function",
      ["function"] = { name = "load", arguments = vim.json.encode({ target = item.target }) },
    }
    local tool = { name = "load", args = { target = item.target }, function_call = call }
    state.active_tool = tool
    state.cancel_id = call.call_id
    chat:add_message({ role = config.constants.LLM_ROLE, content = "", tool_calls = { call } },
      { visible = false, _meta = { tag = "slash_load" } })
    local context, err = adapter.invocation_from_tools({ chat = chat, tool = tool }, tool.args, definition)
    local function done(result)
      if state.cancelled or chat._slash_load ~= state then return end
      state.active_tool = nil
      bridge.clear(state.cancel_id)
      state.cancel_id = nil
      store_result(tool, result)
      injector.flush(chat)
      vim.schedule(step)
    end
    if not context then return done({ ok = false, error = err }) end
    bridge.with_context({ async_id = state.cancel_id, outer_tool_name = "load" }, function()
      adapter.invoke(definition, context, done)
    end)
  end
    step()
end

function SlashCommand:execute()
  local chat = self.Chat
  if not live(chat) or busy(chat) then
    return notify("Chat is busy or unavailable; wait before loading")
  end
  local items, err = candidates(chat)
  if not items then return notify(tostring(err)) end
  if #items == 0 then return notify("No loadable Abilities or content found", vim.log.levels.INFO) end
  require("snacks.picker").pick({
    title = "Load Abilities / Content",
    items = items,
    main = { file = false, float = true },
    format = function(item)
      return { { "[" .. item.kind .. "] ", "Comment" }, { item.target }, { "  " .. item.description, "Comment" } }
    end,
    preview = function(ctx)
      if ctx.item.path then
        ctx.item.file = ctx.item.path
        return require("snacks.picker.preview").file(ctx)
      end
      ctx.preview:set_lines({ ctx.item.target, "", ctx.item.description, "", "Content is fetched only after confirmation." })
    end,
    confirm = function(picker)
      local selected = picker:selected({ fallback = true })
      if not selected or #selected == 0 then return end
      picker:close()
      execute_selection(chat, selected)
    end,
  })
end

return SlashCommand
