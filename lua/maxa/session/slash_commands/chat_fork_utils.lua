-- Shared helpers for session chat fork/scratch/merge/summarize slash commands.
local history_core = require("maxa.session.history_core")
local compaction_messages = require("maxa.session.compaction_messages")
local session_trace = require("maxa.session.session_trace")
local M = {}

local cc_config = require("maxa.config")

local META_KEY = "session_scratch"
local SUMMARIZE_INPUT_STATE_KEY = "_session_summarize_input_state"
local SUMMARIZE_PLACEHOLDER = "⏳ 正在摘要..."

local function notify(msg, level)
  vim.notify("[session] " .. msg, level or vim.log.levels.INFO)
end

local function visible_message(msg)
  return type(msg) == "table" and not (msg.opts and msg.opts.visible == false)
end

local function display_content(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    if type(value.content) == "string" then
      return value.content
    end
    local ok, encoded = pcall(vim.json.encode, value)
    if ok then
      return encoded
    end
  end
  if value == nil then
    return ""
  end
  return tostring(value)
end

local function short_text(text, max_len)
  text = display_content(text):gsub("%s+", " ")
  text = vim.trim(text)
  max_len = max_len or 90
  if #text <= max_len then
    return text
  end
  return text:sub(1, max_len - 1) .. "…"
end

local function clone_messages(messages)
  return vim.deepcopy(messages or {})
end

local function ensure_hidden_tail(messages)
  local cloned = clone_messages(messages)
  table.insert(cloned, {
    role = cc_config.constants.LLM_ROLE,
    content = "",
    opts = { visible = false },
    _meta = { tag = "session_hidden_tail_placeholder" },
  })
  return cloned
end

local function copy_tool_registry(source, target)
  if not (source and target and source.tool_registry and target.tool_registry) then
    return
  end
  target.tool_registry.schemas = vim.deepcopy(source.tool_registry.schemas or {})
  target.tool_registry.in_use = vim.deepcopy(source.tool_registry.in_use or {})
  if target.tools then
    target.tools.messages = target.messages
  end
end

local function sync_edit_area_header(chat)
  if not (chat and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr)) then
    return
  end

  local ok_parser, parser = pcall(require, "maxa.interactions.chat.parser")
  if ok_parser and parser and type(parser.headers) == "function" then
    local ok_header, header_row = pcall(parser.headers, chat)
    if ok_header and header_row then
      chat.header_line = header_row + 1
      return
    end
  end

  chat.header_line = math.max(1, vim.api.nvim_buf_line_count(chat.bufnr) - 1)
end

local function ensure_edit_area(chat)
  if not (chat and type(chat.add_buf_message) == "function") then
    return
  end
  pcall(function()
    chat:add_buf_message({
      role = cc_config.constants.USER_ROLE,
      content = "",
    }, { force_role = true })
  end, { mode = "merge" })
  sync_edit_area_header(chat)
  if chat.ui and type(chat.ui.follow) == "function" then
    pcall(function()
      chat.ui:follow()
    end)
  end
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(chat.bufnr) then
        sync_edit_area_header(chat)
        pcall(vim.api.nvim_set_current_buf, chat.bufnr)
        pcall(vim.cmd, "startinsert")
      end
    end)
  end
end

local function copy_context_items(source, target)
  if not (source and target) then
    return
  end
  local items = source.context_items or {}
  for _, item in ipairs(items) do
    pcall(function()
      target.context:add(vim.deepcopy(item))
    end)
  end
end

local function make_chat_title(parent, mode)
  local base = parent and parent.opts and parent.opts.title or parent and parent.title or "Chat"
  local suffix = mode == "scratch" and " Scratch" or " Fork"
  return tostring(base or "Chat") .. suffix
end

local function get_parent_key(chat)
  if not chat then
    return nil
  end
  local save_id = chat.opts and chat.opts.save_id
  if type(save_id) == "string" and save_id ~= "" and not history_core.is_unsavable_save_id(save_id) then
    return "save_id:" .. save_id
  end
  if chat.id then
    return "id:" .. tostring(chat.id)
  end
  if chat.bufnr then
    return "bufnr:" .. tostring(chat.bufnr)
  end
  return nil
end

local function find_open_chat_by_key(key)
  if not key then
    return nil
  end
  local ok_chat, Chat = pcall(require, "maxa.interactions.chat")
  if not ok_chat or type(Chat.buf_get_chat) ~= "function" then
    return nil
  end
  local ok_list, chats = pcall(Chat.buf_get_chat)
  if not ok_list or type(chats) ~= "table" then
    return nil
  end
  for _, item in ipairs(chats) do
    local chat = item and item.chat
    if chat and get_parent_key(chat) == key then
      return chat
    end
  end
  return nil
end

function M.get_scratch_meta(chat)
  return chat and chat._meta and chat._meta[META_KEY] or nil
end

function M.is_scratch_chat(chat)
  local save_id = chat and chat.opts and chat.opts.save_id
  return history_core.is_unsavable_save_id(save_id, "scratch") and type(M.get_scratch_meta(chat)) == "table"
end

local function get_history_api()
  local ok, session = pcall(require, "maxa.session")
  return ok and session.history() or nil
end

local function scalar_or_nil(value)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return value
  end
  return nil
end

local function chat_identity(chat)
  if type(chat) ~= "table" then
    return nil
  end
  return {
    save_id = chat.opts and scalar_or_nil(chat.opts.save_id) or nil,
    bufnr = scalar_or_nil(chat.bufnr),
    id = scalar_or_nil(chat.id),
    title = chat.opts and scalar_or_nil(chat.opts.title) or scalar_or_nil(chat.title),
  }
end

local function save_trace_chat_if_possible(chat)
  local history_api = get_history_api()
  if history_api and type(history_api.save_chat) == "function" then
    pcall(history_api.save_chat, chat)
  end
end

local function append_trace_event(root_trace_id, event)
  if type(root_trace_id) ~= "string" or root_trace_id == "" then
    return nil, "missing root_trace_id"
  end
  local result, err = session_trace.append_event(root_trace_id, event)
  if not result then
    notify("failed to append trace event: " .. tostring(err), vim.log.levels.WARN)
  end
  return result, err
end

local function default_close_chat(chat)
  if not chat then
    return
  end

  local was_main = require("maxa.session.agent_identity").is_main(chat)
  chat:close()
  if not was_main then return end
  local Chat = require("maxa.interactions.chat")
  local next_chat = Chat.last_main_chat()
  if next_chat and next_chat.ui then
    next_chat.ui:open({ window_opts = { layout = "vertical", position = "right" } })
  end
end

local function is_callable(value)
  if type(value) == "function" then
    return true
  end
  local mt = type(value) == "table" and getmetatable(value) or nil
  return type(mt) == "table" and type(mt.__call) == "function"
end

local function show_scratch_close_confirm(opts)
  opts = opts or {}
  local on_confirm = opts.on_confirm
  local on_cancel = opts.on_cancel

  local win_factory = opts.win_factory
  if win_factory == nil then
    local ok_snacks, snacks = pcall(require, "snacks")
    win_factory = ok_snacks and snacks and snacks.win or nil
  end
  if not is_callable(win_factory) then
    return false
  end

  local confirmed = false
  local win
  local function confirm()
    confirmed = true
    if win and type(win.close) == "function" then
      win:close()
    end
    if type(on_confirm) == "function" then
      on_confirm()
    end
  end
  local function cancel()
    if win and type(win.close) == "function" then
      win:close()
    end
  end

  win = win_factory({
    title = " Scratch 会话未保存 ",
    title_pos = "center",
    border = "rounded",
    backdrop = 60,
    width = 58,
    height = 6,
    enter = true,
    text = {
      "Scratch 会话不会保存到历史。",
      "关闭后将无法恢复，也无法再 merge 回父会话。",
      "",
      "按大写 Y 确认关闭；按 n、q 或 Esc 取消。",
    },
    footer_keys = { "Y", "n", "q", "<esc>" },
    keys = {
      Y = { "Y", confirm, desc = "确认关闭" },
      n = { "n", cancel, desc = "取消" },
      q = { "q", cancel, desc = "取消" },
      esc = { "<esc>", cancel, desc = "取消" },
    },
    on_close = function()
      if not confirmed and type(on_cancel) == "function" then
        on_cancel()
      end
    end,
    wo = {
      wrap = true,
      linebreak = true,
    },
    bo = {
      modifiable = false,
      filetype = "maxa_scratch_close_confirm",
    },
  })

  return true
end

function M.close_chat_with_scratch_guard(chat, opts)
  opts = opts or {}
  local close_fn = opts.close_fn or default_close_chat

  if not M.is_scratch_chat(chat) then
    return close_fn(chat)
  end

  local notify_fn = opts.notify or vim.notify
  local shown = show_scratch_close_confirm({
    win_factory = opts.win_factory,
    on_confirm = function()
      close_fn(chat)
    end,
    on_cancel = function()
      if type(notify_fn) == "function" then
        notify_fn("[scratch] 已取消关闭 scratch 会话", vim.log.levels.INFO)
      end
    end,
  })

  if not shown then
    if type(notify_fn) == "function" then
      notify_fn("[scratch] Scratch 会话未保存历史，关闭后无法恢复；当前 UI 不支持确认窗口，已取消关闭。", vim.log.levels.WARN)
    end
    return false
  end

  return true
end

local function get_chat_for_buf(bufnr)
  local ok_cc, maxa_ai = pcall(require, "maxa")
  if ok_cc and type(maxa_ai.buf_get_chat) == "function" then
    local ok_chat, chat = pcall(maxa_ai.buf_get_chat, bufnr or 0)
    if ok_chat and type(chat) == "table" then
      return chat
    end
  end
  return nil
end

function M.get_active_chat(fallback)
  local current = get_chat_for_buf(0)
  if current then
    return current
  end
  return fallback
end

function M.get_active_scratch_chat(fallback)
  local current = get_chat_for_buf(0)
  if M.is_scratch_chat(current) then
    return current
  end
  if M.is_scratch_chat(fallback) then
    return fallback
  end
  return current or fallback
end

function M.fork_current_chat(parent, opts)
  opts = opts or {}
  if not parent then
    return nil, "No active chat"
  end

  local Chat = require("maxa.interactions.chat")
  local tool_display = require("maxa.interactions.chat.tools.display")
  local original_messages = clone_messages(parent.messages)
  local render_messages = tool_display.build_render_messages(original_messages)
  local save_id = opts.scratch and history_core.make_unsavable_save_id("scratch") or history_core.generate_save_id()
  local fork_start_index = #original_messages
  local parent_key = get_parent_key(parent)
  local parent_save_id = parent.opts and parent.opts.save_id or nil

  local chat_opts = {
    adapter = parent.adapter,
    buffer_context = parent.buffer_context and vim.deepcopy(parent.buffer_context) or nil,
    cwd = parent.opts and parent.opts.cwd or nil,
    project_root = parent.opts and parent.opts.project_root or nil,
    messages = ensure_hidden_tail(render_messages),
    settings = parent.settings and vim.deepcopy(parent.settings) or nil,
    save_id = save_id,
    title = make_chat_title(parent, opts.scratch and "scratch" or "fork"),
    auto_submit = false,
    compact_protected_prefix_count = compaction_messages.get_protected_prefix_count(parent),
    stop_context_insertion = true,
    ignore_system_prompt = true,
  }

  local ok, child = pcall(Chat.new, chat_opts)
  if not ok or not child then
    return nil, "Failed to create chat: " .. tostring(child)
  end

  child.messages = original_messages
  if child.tools then
    child.tools.messages = child.messages
  end
  child.cycle = parent.cycle or child.cycle or 1
  compaction_messages.set_protected_prefix_count(child, compaction_messages.get_protected_prefix_count(parent))
  copy_tool_registry(parent, child)
  copy_context_items(parent, child)
  tool_display.apply_render_postprocess(child, render_messages)
  ensure_edit_area(child)

  child._meta = vim.deepcopy(parent._meta or {})
  require("maxa.session.agent_identity").reidentify(child, true)
  if opts.scratch then
    child._session_scratch_parent_chat = parent
    child._meta[META_KEY] = {
      parent_key = parent_key,
      parent_save_id = parent_save_id,
      parent_bufnr = parent.bufnr,
      parent_id = parent.id,
      fork_start_index = fork_start_index,
      created_at = os.time(),
    }
  end

  local parent_trace = session_trace.get_membership(parent)
  if parent_trace then
    local session_role = opts.scratch and "scratch" or "fork"
    local event_id = session_trace.new_event_id("evt")
    local child_trace, trace_err = session_trace.copy_membership(parent, child, {
      new_span = true,
      session_role = session_role,
      source_event_id = event_id,
    })
    if child_trace then
      append_trace_event(child_trace.root_trace_id, {
        event_id = event_id,
        kind = opts.scratch and "scratch.created" or "fork.created",
        span_id = child_trace.span_id,
        parent_span_id = parent_trace.span_id,
        session = session_trace.session_info(child, child_trace),
        parent_session = session_trace.session_info(parent, parent_trace),
        parent = chat_identity(parent),
        child = chat_identity(child),
        fork = {
          start_index = fork_start_index,
          message_count = #original_messages,
        },
        dedupe_key = table.concat({
          opts.scratch and "scratch.created" or "fork.created",
          tostring(parent_trace.span_id or "parent"),
          tostring(child_trace.span_id or "child"),
          tostring(save_id or "no-save-id"),
          tostring(fork_start_index),
        }, ":"),
      })
      if not opts.scratch then
        save_trace_chat_if_possible(child)
      end
    else
      notify("failed to propagate trace membership: " .. tostring(trace_err), vim.log.levels.WARN)
    end
  end

  return child, nil
end

local function message_role_label(role)
  if role == cc_config.constants.USER_ROLE then
    return "User"
  elseif role == cc_config.constants.LLM_ROLE then
    return "Assistant"
  elseif role == cc_config.constants.SYSTEM_ROLE then
    return "System"
  elseif role == "tool" then
    return "Tool"
  end
  return tostring(role or "Message")
end

function M.messages_to_markdown(messages, start_index, end_index, opts)
  opts = opts or {}
  local lines = {}
  start_index = math.max(1, start_index or 1)
  end_index = math.min(#(messages or {}), end_index or #(messages or {}))
  for i = start_index, end_index do
    local msg = messages[i]
    if opts.include_hidden or visible_message(msg) then
      table.insert(lines, string.format("## %s [%d]", message_role_label(msg.role), i))
      table.insert(lines, "")
      if opts.include_tools and msg.tools and msg.tools.calls then
        table.insert(lines, vim.json.encode(msg.tools.calls))
      end
      local content = opts.include_tools and require("maxa.session.slash_commands.compact_utils").is_image_message(msg)
        and "[Image content]" or display_content(msg.content)
      if content == "" then
        content = "(empty)"
      end
      for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
        table.insert(lines, line)
      end
      table.insert(lines, "")
    end
  end
  return table.concat(lines, "\n")
end

local function is_wrapped_agent_user_message(content)
  return type(content) == "string"
    and (
      content:match("^%[RESUME AGENT %- CONTINUE RESTORED SESSION%]")
      or content:match("^%[RUN AGENT%]")
      or content:match("^%[FORKED TASK%]")
    )
end

function M.is_manual_user_message(msg)
  if not (msg and msg.role == cc_config.constants.USER_ROLE and visible_message(msg)) then
    return false
  end
  -- Slash-command generated summaries, restart-resume prompts, loaded context/rules/files,
  -- warmup prompts and other injected user messages carry metadata tags or context links.
  -- `/summarize` should list only real user-submitted prompts.
  if msg._meta and msg._meta.tag then
    return false
  end
  if msg.context ~= nil then
    return false
  end
  local content = display_content(msg.content)
  if is_wrapped_agent_user_message(content) then
    return false
  end
  return true
end

function M.find_latest_manual_user_message(chat)
  local messages = chat and chat.messages or {}
  for index = #messages, 1, -1 do
    local msg = messages[index]
    if M.is_manual_user_message(msg) then
      return {
        index = index,
        role = msg.role,
        content = display_content(msg.content),
        text = short_text(msg.content, 100),
        message = msg,
      }
    end
  end
  return nil
end

function M.collect_user_message_items(chat)
  local items = {}
  for index, msg in ipairs(chat and chat.messages or {}) do
    if M.is_manual_user_message(msg) then
      table.insert(items, {
        index = index,
        role = msg.role,
        content = display_content(msg.content),
        text = short_text(msg.content, 100),
      })
    end
  end
  table.sort(items, function(a, b)
    return a.index > b.index
  end)
  return items
end

-- Ask replies are user interactions, but remain canonical tool results.
function M.rewind_user_input(chat, index)
  local msg = chat and chat.messages and chat.messages[index]
  if M.is_manual_user_message(msg) then
    return { index = index, role = msg.role, content = display_content(msg.content),
      text = short_text(msg.content, 100), message = msg }
  end
  if not (msg and msg.role == "tool" and msg.tools and msg.tools.call_id) then
    return nil
  end
  local meta = msg._meta or {}
  if meta.is_error or msg.tools.is_error or meta.status == "cancelled" or meta.status == "not-executed" then
    return nil
  end
  local normalize_args = require("maxa.interactions.chat.tools.display_helpers").normalize_args
  for i = 1, index - 1 do
    for _, call in ipairs(chat.messages[i].tools and chat.messages[i].tools.calls or {}) do
      if (call.call_id or call.id) == msg.tools.call_id then
        local fn = call["function"] or {}
        local args = normalize_args(fn.arguments)
        local name = fn.name
        if name == "run" and args.scope == "tool" and args.command == "ask"
          and normalize_args(args.opts).async ~= true then
          name, args = "ask", normalize_args(args.args)
        end
        if name == "ask" and (args.mode == "input" or args.mode == "choice") then
          return { index = index, role = msg.role, content = display_content(msg.content),
            text = short_text(msg.content, 100), message = msg, call_id = msg.tools.call_id, ask_args = args }
        end
        return nil
      end
    end
  end
end

function M.collect_rewind_message_items(chat)
  local items = {}
  for index = #(chat and chat.messages or {}), 1, -1 do
    local item = M.rewind_user_input(chat, index)
    if item then items[#items + 1] = item end
  end
  return items
end

function M.build_preview_lines(chat, focus_index)
  local lines = {}
  local focus_line = 1
  for index, msg in ipairs(chat and chat.messages or {}) do
    if visible_message(msg) then
      if index == focus_index then
        focus_line = #lines + 1
        table.insert(lines, "▶ " .. string.rep("━", 50))
      end
      table.insert(lines, string.format("## %s [%d]", message_role_label(msg.role), index))
      table.insert(lines, "")
      for _, line in ipairs(vim.split(display_content(msg.content), "\n", { plain = true })) do
        table.insert(lines, line)
      end
      table.insert(lines, "")
    end
  end
  if #lines == 0 then
    lines = { "(No visible messages)" }
  end
  return lines, focus_line
end

local function collect_responses_output_text(output)
  if type(output) ~= "table" then
    return nil
  end

  local chunks = {}
  local function add_text(text)
    if type(text) == "string" and vim.trim(text) ~= "" then
      table.insert(chunks, text)
    end
  end

  for _, item in ipairs(output) do
    if type(item) == "table" then
      if item.type == "message" and type(item.content) == "table" then
        for _, block in ipairs(item.content) do
          if type(block) == "table" then
            local text = block.text or block.output_text
            if (block.type == "output_text" or block.type == "text") and type(text) == "string" then
              add_text(text)
            end
          elseif type(block) == "string" then
            add_text(block)
          end
        end
      elseif item.type == "output_text" or item.type == "text" then
        add_text(item.text or item.output_text or item.content)
      end
    elseif type(item) == "string" then
      add_text(item)
    end
  end

  if #chunks == 0 then
    return nil
  end
  return vim.trim(table.concat(chunks, "\n"))
end

local function table_keys(value, limit)
  if type(value) ~= "table" then
    return nil
  end
  local keys = {}
  for key, _ in pairs(value) do
    table.insert(keys, tostring(key))
    if limit and #keys >= limit then
      break
    end
  end
  table.sort(keys)
  return table.concat(keys, ",")
end

local function short_diag_text(value, max_len)
  if type(value) ~= "string" then
    return nil
  end
  value = vim.trim(value:gsub("%s+", " "))
  max_len = max_len or 240
  if #value > max_len then
    value = value:sub(1, max_len) .. "…"
  end
  return value
end

function M.summary_result_diagnostic(result)
  local parts = { "output_type=" .. tostring(type(result) == "table" and type(result.output) or type(result)) }
  if type(result) ~= "table" then
    return table.concat(parts, "; ")
  end

  if result.status ~= nil then
    table.insert(parts, "status=" .. tostring(result.status))
  end
  if result.error ~= nil then
    local err = result.error
    if type(err) == "table" then
      table.insert(parts, "error_keys=" .. tostring(table_keys(err, 8)))
      table.insert(parts, "error=" .. tostring(short_diag_text(err.message or err.code or err.type) or vim.inspect(err):sub(1, 240)))
    else
      table.insert(parts, "error=" .. tostring(short_diag_text(tostring(err))))
    end
  end
  if type(result.output) == "table" then
    table.insert(parts, "output_keys=" .. tostring(table_keys(result.output, 12)))
    if result.output.error ~= nil then
      local err = result.output.error
      if type(err) == "table" then
        table.insert(parts, "output_error=" .. tostring(short_diag_text(err.message or err.code or err.type) or vim.inspect(err):sub(1, 240)))
      else
        table.insert(parts, "output_error=" .. tostring(short_diag_text(tostring(err))))
      end
    end
    if type(result.output.content) == "table" then
      table.insert(parts, "output_content_keys=" .. tostring(table_keys(result.output.content, 12)))
    end
  end
  if type(result.response) == "table" then
    table.insert(parts, "response_keys=" .. tostring(table_keys(result.response, 12)))
    if result.response.status ~= nil then
      table.insert(parts, "response_status=" .. tostring(result.response.status))
    end
    if result.response.error ~= nil then
      local err = result.response.error
      if type(err) == "table" then
        table.insert(parts, "response_error=" .. tostring(short_diag_text(err.message or err.code or err.type) or vim.inspect(err):sub(1, 240)))
      else
        table.insert(parts, "response_error=" .. tostring(short_diag_text(tostring(err))))
      end
    end
  end

  return table.concat(parts, "; ")
end

function M.extract_summary_content(result)
  if type(result) == "string" then
    local parsed_ok, parsed = pcall(vim.json.decode, result)
    if parsed_ok then
      return M.extract_summary_content(parsed)
    end
    local content = vim.trim(result)
    return content ~= "" and content or nil
  end
  if type(result) ~= "table" then
    return nil
  end

  if type(result.output) == "string" then
    local content = vim.trim(result.output)
    if content ~= "" then
      return content
    end
  end
  if type(result.output) == "table" and type(result.output.content) == "string" then
    local content = vim.trim(result.output.content)
    if content ~= "" then
      return content
    end
  end
  if type(result.content) == "string" then
    local content = vim.trim(result.content)
    if content ~= "" then
      return content
    end
  end
  if type(result.output_text) == "string" then
    local content = vim.trim(result.output_text)
    if content ~= "" then
      return content
    end
  end

  local responses_text = collect_responses_output_text(result.output)
  if responses_text and responses_text ~= "" then
    return responses_text
  end
  if type(result.response) == "table" then
    responses_text = collect_responses_output_text(result.response.output)
    if responses_text and responses_text ~= "" then
      return responses_text
    end
  end

  return nil
end

function M.summarize_range(chat, start_index, end_index, callback, opts)
  opts = opts or {}
  if not chat then
    callback(nil, "No active chat")
    return
  end
  start_index = math.max(1, start_index or 1)
  end_index = math.min(#chat.messages, end_index or #chat.messages)
  if start_index > end_index then
    callback(nil, "Empty summary range")
    return
  end
  local conversation = M.messages_to_markdown(chat.messages, start_index, end_index, opts)
  if vim.trim(conversation) == "" then
    callback(nil, "No visible content in selected range")
    return
  end

  local prompt = table.concat({
    "请总结以下会话片段，输出中文。",
    "要求：",
    "- 保留用户目标、关键决策、已完成事项、当前结论和后续待办。",
    "- 忽略无关寒暄、重复日志和细枝末节。",
    "- 不要编造片段中没有的信息。",
    opts.requirements or "",
    "",
    "会话片段：",
    conversation,
  }, "\n")

  local ok_bg, Background = pcall(require, "maxa.interactions.background")
  if not ok_bg or not Background then
    callback(nil, "Background interaction is not available")
    return
  end
  local background, adapter_err = Background.new({ default_role = "compact", chat = chat })
  if not background then
    callback(nil, adapter_err)
    return
  end

  local attempts = 0
  local last_empty_diag = nil
  local function ask_summary()
    attempts = attempts + 1
    background:ask({
      { role = cc_config.constants.USER_ROLE, content = prompt },
    }, {
      method = "async",
      timeout = 120000,
      on_done = function(result)
        local content = M.extract_summary_content(result)
        if not content or content == "" then
          last_empty_diag = M.summary_result_diagnostic(result)
          if attempts < 2 then
            notify("summary result was empty; retrying once", vim.log.levels.WARN)
            ask_summary()
            return
          end
          callback(nil, "Summary result is empty after retry (" .. tostring(last_empty_diag) .. ")")
          return
        end
        callback(content, nil)
      end,
      on_error = function(err)
        local message = type(err) == "table" and (err.message or err.stderr or err.body) or err
        callback(nil, tostring(message))
      end,
    })
  end

  ask_summary()
end

local function capture_current_input(chat)
  if not (chat and chat.header_line and chat.chat_parser) then
    return nil
  end
  local ok_parser, parser = pcall(require, "maxa.interactions.chat.parser")
  if not ok_parser then
    return nil
  end
  local ok_msg, message = pcall(parser.messages, chat, chat.header_line)
  if ok_msg and message and type(message.content) == "string" then
    return message.content
  end
  return nil
end

local function clear_current_input_area(chat)
  if not (chat and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) and chat.header_line) then
    return false
  end
  local start_row = math.max(0, chat.header_line - 1)
  local was_modifiable = vim.bo[chat.bufnr].modifiable
  if not was_modifiable and chat.ui and type(chat.ui.unlock_buf) == "function" then
    pcall(function()
      chat.ui:unlock_buf()
    end)
  end
  local ok = pcall(vim.api.nvim_buf_set_lines, chat.bufnr, start_row, -1, false, {})
  if not was_modifiable and chat.ui and type(chat.ui.lock_buf) == "function" then
    pcall(function()
      chat.ui:lock_buf()
    end)
  end
  return ok
end

local function valid_chat_buf(chat)
  return type(chat) == "table"
    and type(chat.bufnr) == "number"
    and vim.api.nvim_buf_is_valid(chat.bufnr)
    and vim.api.nvim_buf_is_loaded(chat.bufnr)
end

local function lock_chat_buffer(chat)
  if not valid_chat_buf(chat) then
    return
  end
  if chat.ui and type(chat.ui.lock_buf) == "function" then
    pcall(function()
      chat.ui:lock_buf()
    end)
  else
    vim.bo[chat.bufnr].modifiable = false
  end
end

local function unlock_chat_buffer(chat)
  if not valid_chat_buf(chat) then
    return
  end
  if chat.ui and type(chat.ui.unlock_buf) == "function" then
    pcall(function()
      chat.ui:unlock_buf()
    end)
  else
    vim.bo[chat.bufnr].modifiable = true
  end
end

local function stop_insert_if_current(chat)
  if not valid_chat_buf(chat) or vim.api.nvim_get_current_buf() ~= chat.bufnr then
    return
  end
  local mode = vim.api.nvim_get_mode().mode or ""
  if mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R" then
    pcall(vim.cmd, "stopinsert")
  end
end

local function editable_input_range(chat)
  if not valid_chat_buf(chat) then
    return nil
  end
  local header_line = tonumber(chat.header_line)
  if not header_line or header_line < 1 then
    return nil
  end
  local line_count = vim.api.nvim_buf_line_count(chat.bufnr)
  local start_row = math.max(header_line - 1, 0)
  if start_row >= line_count then
    return nil
  end
  return start_row, line_count
end

local function replace_editable_input_lines(chat, lines)
  local start_row, end_row = editable_input_range(chat)
  if not start_row then
    return false
  end
  unlock_chat_buffer(chat)
  local ok = pcall(vim.api.nvim_buf_set_lines, chat.bufnr, start_row, end_row, false, lines)
  return ok, start_row
end

local function restore_current_input_area(chat, content)
  if not (chat and type(chat.add_buf_message) == "function") then
    return
  end
  pcall(function()
    chat:add_buf_message({
      role = cc_config.constants.USER_ROLE,
      content = content or "",
    }, { force_role = true })
  end)
  local ok_parser, parser = pcall(require, "maxa.interactions.chat.parser")
  if ok_parser then
    local ok_header, header_row = pcall(parser.headers, chat)
    if ok_header and header_row then
      chat.header_line = header_row + 1
    elseif chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
      chat.header_line = math.max(1, vim.api.nvim_buf_line_count(chat.bufnr) - 1)
    end
  end
  if chat.ui and type(chat.ui.display_tokens) == "function" then
    pcall(function()
      chat.ui:display_tokens(chat.chat_parser, chat.header_line)
    end)
  end
  if chat.ui and type(chat.ui.follow) == "function" then
    pcall(function()
      chat.ui:follow()
    end)
  end
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(chat.bufnr) then
        pcall(vim.api.nvim_set_current_buf, chat.bufnr)
        pcall(vim.cmd, "startinsert")
      end
    end)
  end
end

local function build_summary_content(summary, opts)
  opts = opts or {}
  return opts.content or table.concat({
    "以下是会话片段摘要：",
    "",
    summary,
  }, "\n")
end

local function build_summary_message(content, opts)
  opts = opts or {}
  return {
    role = opts.role or cc_config.constants.USER_ROLE,
    content = content,
    _meta = {
      tag = opts.tag or "session_summary",
      source = opts.source,
      range = opts.range,
    },
  }
end

function M.append_summary_message(chat, summary, opts)
  opts = opts or {}
  if not chat then
    return false, "No target chat"
  end
  local content = build_summary_content(summary, opts)
  chat:add_message({
    role = cc_config.constants.USER_ROLE,
    content = content,
  }, {
    visible = true,
    _meta = {
      tag = opts.tag or "session_summary",
      source = opts.source,
      range = opts.range,
    },
  })
  -- Show it in the buffer without making it part of the editable input area.
  -- Then always restore a separate user edit area. Without this blank tail,
  -- the summary becomes the last user block visually and future input can be
  -- mixed into the summary block.
  local pending_input = nil
  if opts.preserve_current_input then
    pending_input = capture_current_input(chat)
  end
  clear_current_input_area(chat)
  chat:add_buf_message({
    role = cc_config.constants.USER_ROLE,
    content = content,
  }, { force_role = true })
  restore_current_input_area(chat, pending_input or "")
  local ok_history, history_api = pcall(function()
    return require("maxa.session").history()
  end)
  if ok_history and history_api and type(history_api.save_chat) == "function" then
    pcall(history_api.save_chat, chat)
  end
  return true, nil
end

local function show_scratch_merge_status(chat, text)
  if not (chat and type(chat.add_buf_message) == "function") then
    return
  end
  pcall(function()
    chat:add_buf_message({
      role = cc_config.constants.USER_ROLE,
      content = text,
    }, { force_role = true })
  end)
end

local function focus_chat(chat)
  if not chat then
    return
  end
  if chat.ui and type(chat.ui.open) == "function" then
    pcall(function()
      chat.ui:open()
    end)
  elseif type(chat.open) == "function" then
    pcall(function()
      chat:open()
    end)
  end
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    pcall(vim.api.nvim_set_current_buf, chat.bufnr)
    if chat.ui and type(chat.ui.follow) == "function" then
      pcall(function()
        chat.ui:follow()
      end)
    end
  end
end

local function close_chat(chat, on_closed)
  vim.defer_fn(function()
    if chat and chat.ui and chat.ui.winnr and vim.api.nvim_win_is_valid(chat.ui.winnr) then
      pcall(vim.api.nvim_win_close, chat.ui.winnr, true)
    end
    if chat and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
      pcall(function()
        chat:close()
      end)
    end
    if type(on_closed) == "function" then
      vim.schedule(on_closed)
    end
  end, 100)
end

local function merge_context_state(parent, scratch)
  if not (parent and scratch) then
    return
  end
  local seen = {}
  for _, item in ipairs(parent.context_items or {}) do
    if item and item.id then
      seen[item.id] = true
    end
  end
  parent.context_items = parent.context_items or {}
  for _, item in ipairs(scratch.context_items or {}) do
    if item and item.id and not seen[item.id] then
      table.insert(parent.context_items, vim.deepcopy(item))
      seen[item.id] = true
    end
  end
  if parent.tool_registry and scratch.tool_registry then
    parent.tool_registry.schemas = vim.deepcopy(scratch.tool_registry.schemas or parent.tool_registry.schemas or {})
    parent.tool_registry.in_use = vim.deepcopy(scratch.tool_registry.in_use or parent.tool_registry.in_use or {})
  end
  if parent.tools then
    parent.tools.messages = parent.messages
  end
end

local function save_chat_if_possible(chat)
  local history_api = get_history_api()
  if history_api and type(history_api.save_chat) == "function" then
    pcall(history_api.save_chat, chat)
  end
end

local function sync_chat_message_refs(chat)
  if chat and chat.tools then
    chat.tools.messages = chat.messages
  end
end

local function normalize_message_indices(messages, start_index)
  for index = start_index or 1, #(messages or {}) do
    local msg = messages[index]
    if type(msg) == "table" and type(msg._meta) == "table" then
      msg._meta.index = index
    end
  end
end

local function prune_context_items_to_messages(chat)
  if not (chat and type(chat.context_items) == "table") then
    return
  end
  local ids = {}
  for _, msg in ipairs(chat.messages or {}) do
    if msg and msg.context and msg.context.id then
      ids[msg.context.id] = true
    end
  end
  chat.context_items = vim
    .iter(chat.context_items)
    :filter(function(item)
      return item and item.id and ids[item.id] == true
    end)
    :totable()
end

local function clamp_protected_prefix(chat)
  local count = compaction_messages.get_protected_prefix_count(chat)
  if count > #(chat and chat.messages or {}) then
    compaction_messages.set_protected_prefix_count(chat, #(chat.messages or {}))
  end
end

local function focus_edit_area(chat)
  if chat and chat.ui and type(chat.ui.follow) == "function" then
    pcall(function()
      chat.ui:follow()
    end)
  end
  if chat and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(chat.bufnr) then
        pcall(vim.api.nvim_set_current_buf, chat.bufnr)
        pcall(vim.cmd, "startinsert")
      end
    end)
  end
end

local function clear_chat_folds(chat)
  if not (chat and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr)) then
    return
  end

  local function clear_window_folds()
    pcall(vim.api.nvim_set_option_value, "foldmethod", "manual", { win = 0 })
    pcall(vim.cmd, "silent! normal! zE")
  end

  local wins = vim.fn.win_findbuf(chat.bufnr) or {}
  if #wins > 0 then
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_call, win, clear_window_folds)
      end
    end
  else
    pcall(function()
      vim.api.nvim_buf_call(chat.bufnr, clear_window_folds)
    end)
  end

  local ok_folds, folds = pcall(require, "maxa.interactions.chat.ui.folds")
  if ok_folds and folds and type(folds.fold_summaries) == "table" then
    folds.fold_summaries[chat.bufnr] = nil
  end

  for _, ns_name in ipairs({
    "MaxaAI-tool_fold_marks",
    "MaxaAI-context_fold_marks",
    "MaxaAI-reasoning_fold_marks",
  }) do
    local ns = vim.api.nvim_create_namespace(ns_name)
    pcall(vim.api.nvim_buf_clear_namespace, chat.bufnr, ns, 0, -1)
  end
end

local function sync_header_and_context(chat)
  local ok_parser, parser = pcall(require, "maxa.interactions.chat.parser")
  if ok_parser then
    local ok_header, header_row = pcall(parser.headers, chat)
    if ok_header and header_row then
      chat.header_line = header_row + 1
    elseif chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
      chat.header_line = math.max(1, vim.api.nvim_buf_line_count(chat.bufnr) - 1)
    end
  elseif chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    chat.header_line = math.max(1, vim.api.nvim_buf_line_count(chat.bufnr) - 1)
  end

  if chat and chat.ui and type(chat.ui.display_tokens) == "function" then
    pcall(function()
      chat.ui:display_tokens(chat.chat_parser, chat.header_line)
    end)
  end
end

local function render_chat_with_recovered_input(chat, input)
  if not (chat and chat.ui and type(chat.ui.render) == "function") then
    return false, "Chat UI cannot render recovered input"
  end

  local tool_display = require("maxa.interactions.chat.tools.display")
  local render_messages = tool_display.build_render_messages(chat.messages or {})
  local reply = chat._session_rewind_reply
  if reply then
    render_messages = vim.iter(render_messages):filter(function(msg)
      local origin = msg.opts and msg.opts._display_origin
      return not (origin and origin.call_id == reply.call_id and origin.phase == "result")
    end):totable()
  end
  local render_with_input = vim.deepcopy(render_messages)
  for i, rendered in ipairs(render_with_input) do
    local origin = render_messages[i].opts and render_messages[i].opts._display_origin
    if origin then
      rendered.opts = rendered.opts or {}
      rendered.opts._display_origin = origin
    end
  end
  table.insert(render_with_input, {
    role = cc_config.constants.USER_ROLE,
    content = input or "",
    opts = { force_role = true, _preserve_empty = true },
  })

  clear_chat_folds(chat)
  local ok, err = pcall(function()
    chat.ui:render(chat.buffer_context, render_with_input, { stop_context_insertion = true })
  end)
  if not ok then
    return false, tostring(err)
  end
  clear_chat_folds(chat)

  chat._last_role = cc_config.constants.USER_ROLE
  if chat.builder and chat.builder.state then
    chat.builder.state.last_role = cc_config.constants.USER_ROLE
  end
  sync_header_and_context(chat)
  if reply and valid_chat_buf(chat) then
    reply.input_row = vim.api.nvim_buf_line_count(chat.bufnr) - #vim.split(input or "", "\n", { plain = true })
  end
  tool_display.apply_render_postprocess(chat, render_messages)
  focus_edit_area(chat)
  return true, nil
end

local function render_chat_with_blank_edit_area(chat)
  if not (chat and chat.ui and type(chat.ui.render) == "function") then
    return false, "Chat UI cannot render summary replacement"
  end

  local tool_display = require("maxa.interactions.chat.tools.display")
  local render_messages = tool_display.build_render_messages(chat.messages or {})

  clear_chat_folds(chat)
  local ok, err = pcall(function()
    chat.ui:render(chat.buffer_context, render_messages, { stop_context_insertion = true })
  end)
  if not ok then
    return false, tostring(err)
  end
  clear_chat_folds(chat)

  chat._last_role = cc_config.constants.USER_ROLE
  if chat.builder and chat.builder.state then
    chat.builder.state.last_role = cc_config.constants.USER_ROLE
  end
  tool_display.apply_render_postprocess(chat, render_messages)
  restore_current_input_area(chat, "")
  return true, nil
end

local function chat_is_busy(chat)
  if not chat then
    return false
  end
  if chat.current_request or chat.current_tool then
    return true
  end
  return type(chat.status) == "string" and chat.status ~= ""
end

---Promote the current scratch chat into a normal saved history chat.
---@param chat table? Maxa AI chat
---@param opts? {history_api?: table, generate_save_id?: fun(): string, now?: fun(): integer}
---@return table? result {save_id: string, previous_save_id: string}
---@return string? error
function M.save_scratch_chat(chat, opts)
  opts = opts or {}
  if not M.is_scratch_chat(chat) then
    return nil, "Only scratch chats can be saved"
  end
  if chat_is_busy(chat) then
    return nil, "Chat is busy; wait for the current request or tool to finish"
  end
  if type(chat.opts) ~= "table" then
    return nil, "Chat is missing opts"
  end

  local history_api = opts.history_api or get_history_api()
  if type(history_api) ~= "table" or type(history_api.save_chat) ~= "function" then
    return nil, "History API is unavailable"
  end

  local generate_save_id = opts.generate_save_id or history_core.generate_save_id
  if type(generate_save_id) ~= "function" then
    return nil, "Save id generator is unavailable"
  end
  local new_save_id = generate_save_id()
  if type(new_save_id) ~= "string" or new_save_id == "" or history_core.is_unsavable_save_id(new_save_id) or new_save_id:match("[/\\]") then
    return nil, "Generated save_id is invalid"
  end

  local previous_save_id = chat.opts.save_id
  local previous_meta = vim.deepcopy(chat._meta or {})
  local previous_parent_ref = chat._session_scratch_parent_chat
  local scratch_meta = vim.deepcopy(M.get_scratch_meta(chat) or {})
  local previous_trace = session_trace.get_membership({ _meta = previous_meta })
  local trace_event_id = previous_trace and session_trace.new_event_id("evt") or nil
  local trace_membership = nil
  local now = type(opts.now) == "function" and opts.now() or os.time()

  local function restore()
    chat.opts.save_id = previous_save_id
    chat._meta = vim.deepcopy(previous_meta)
    chat._session_scratch_parent_chat = previous_parent_ref
  end

  local new_meta = vim.deepcopy(previous_meta)
  new_meta.session_scratch = nil
  new_meta.session_saved_from_scratch = {
    previous_save_id = scalar_or_nil(previous_save_id),
    parent_key = scalar_or_nil(scratch_meta.parent_key),
    parent_save_id = scalar_or_nil(scratch_meta.parent_save_id),
    parent_bufnr = scalar_or_nil(scratch_meta.parent_bufnr),
    parent_id = scalar_or_nil(scratch_meta.parent_id),
    fork_start_index = scalar_or_nil(scratch_meta.fork_start_index),
    scratch_created_at = scalar_or_nil(scratch_meta.created_at),
    saved_at = scalar_or_nil(now),
  }
  if previous_trace then
    local holder = { _meta = new_meta }
    local promoted_trace = vim.deepcopy(previous_trace)
    promoted_trace.session_role = "promoted_scratch"
    promoted_trace.source_event_id = trace_event_id
    promoted_trace.active = true
    trace_membership = session_trace.set_membership(holder, promoted_trace)
    new_meta = holder._meta
  end

  chat.opts.save_id = new_save_id
  chat._meta = new_meta
  require("maxa.session.agent_identity").reidentify(chat, true)
  chat._session_scratch_parent_chat = nil

  local ok_save, save_err = pcall(history_api.save_chat, chat)
  if not ok_save then
    restore()
    return nil, "Failed to save chat: " .. tostring(save_err)
  end

  if type(history_api.load_chat) == "function" then
    local ok_load, saved_chat = pcall(history_api.load_chat, new_save_id)
    if not ok_load or not saved_chat then
      restore()
      if ok_load then
        return nil, "Failed to verify saved chat: " .. new_save_id
      end
      return nil, "Failed to verify saved chat: " .. tostring(saved_chat)
    end
  end

  if trace_membership then
    append_trace_event(trace_membership.root_trace_id, {
      event_id = trace_event_id,
      kind = "scratch.saved",
      span_id = trace_membership.span_id,
      parent_span_id = trace_membership.parent_span_id,
      session = session_trace.session_info(chat, trace_membership),
      previous_session = {
        save_id = previous_save_id,
        temporary = previous_save_id and history_core.is_unsavable_save_id(previous_save_id) or false,
        role = previous_trace and previous_trace.session_role or "scratch",
      },
      scratch = {
        previous_save_id = previous_save_id,
        parent_key = scalar_or_nil(scratch_meta.parent_key),
        parent_save_id = scalar_or_nil(scratch_meta.parent_save_id),
        fork_start_index = scalar_or_nil(scratch_meta.fork_start_index),
        created_at = scalar_or_nil(scratch_meta.created_at),
      },
      saved = {
        save_id = new_save_id,
        saved_at = scalar_or_nil(now),
      },
      dedupe_key = table.concat({
        "scratch.saved",
        tostring(trace_membership.span_id or "span"),
        tostring(previous_save_id or "previous"),
        tostring(new_save_id),
      }, ":"),
    })
  end

  return {
    save_id = new_save_id,
    previous_save_id = previous_save_id,
    trace_event_id = trace_event_id,
  }, nil
end

local function set_summarize_input_pending(chat)
  if type(chat) ~= "table" or chat_is_busy(chat) then
    return false
  end
  local start_row, end_row = editable_input_range(chat)
  if not start_row then
    return false
  end
  local state = chat[SUMMARIZE_INPUT_STATE_KEY]
  if type(state) == "table" and state.active then
    lock_chat_buffer(chat)
    stop_insert_if_current(chat)
    return true
  end

  chat[SUMMARIZE_INPUT_STATE_KEY] = {
    active = true,
    start_row = start_row,
    header_line = chat.header_line,
    lines = vim.api.nvim_buf_get_lines(chat.bufnr, start_row, end_row, false),
  }
  local ok = replace_editable_input_lines(chat, { SUMMARIZE_PLACEHOLDER })
  if not ok then
    chat[SUMMARIZE_INPUT_STATE_KEY] = nil
    return false
  end
  lock_chat_buffer(chat)
  stop_insert_if_current(chat)
  return true
end

local function clear_summarize_input_pending(chat, opts)
  opts = opts or {}
  if type(chat) ~= "table" then
    return false
  end
  local state = chat[SUMMARIZE_INPUT_STATE_KEY]
  if type(state) ~= "table" or not state.active then
    if opts.blank then
      restore_current_input_area(chat, "")
    end
    return true
  end
  chat[SUMMARIZE_INPUT_STATE_KEY] = nil

  if valid_chat_buf(chat) then
    local lines = opts.blank and {} or (state.lines or {})
    local start_row = math.max(tonumber(state.start_row) or ((tonumber(state.header_line) or 1) - 1), 0)
    local end_row = vim.api.nvim_buf_line_count(chat.bufnr)
    unlock_chat_buffer(chat)
    pcall(vim.api.nvim_buf_set_lines, chat.bufnr, start_row, end_row, false, lines)
    chat.header_line = state.header_line or chat.header_line
  end
  unlock_chat_buffer(chat)
  if opts.blank then
    restore_current_input_area(chat, "")
  else
    sync_header_and_context(chat)
    focus_edit_area(chat)
  end
  return true
end

M.set_summarize_input_pending = set_summarize_input_pending
M.clear_summarize_input_pending = clear_summarize_input_pending

local function restore_chat_snapshot(chat, snapshot)
  chat.messages = snapshot.messages
  chat.context_items = snapshot.context_items
  if snapshot.protected_prefix_count ~= nil then
    compaction_messages.set_protected_prefix_count(chat, snapshot.protected_prefix_count)
  end
  chat._session_rewind_reply = snapshot.rewind_reply
  sync_chat_message_refs(chat)
end

local function rewind_chat_from_index(chat, index, input, reply)
  local snapshot = {
    messages = chat.messages,
    context_items = chat.context_items,
    protected_prefix_count = compaction_messages.get_protected_prefix_count(chat),
    rewind_reply = chat._session_rewind_reply,
  }

  local next_messages = {}
  for i = 1, index - 1 do
    next_messages[i] = chat.messages[i]
  end
  chat.messages = next_messages
  chat._session_rewind_reply = reply
  normalize_message_indices(chat.messages)
  prune_context_items_to_messages(chat)
  clamp_protected_prefix(chat)
  sync_chat_message_refs(chat)

  local ok_render, render_err = render_chat_with_recovered_input(chat, input)
  if not ok_render then
    restore_chat_snapshot(chat, snapshot)
    return false, render_err
  end

  -- Keep the rewound branch in memory until a new user message is submitted.
  -- Storage also checks this flag so unrelated auto-saves cannot persist it.
  chat._session_rewind_pending = true
  return true, {
    index = index,
    content = input,
    removed_count = #snapshot.messages - #chat.messages,
  }
end

-- Keep the selected message and extend through the results of any retained
-- assistant tool calls, including sibling calls in the same batch.
local function complete_rewind_target(messages, selected)
  local last = selected
  local i = 1
  while i <= last do
    local msg = messages[i]
    if (msg.role == cc_config.constants.LLM_ROLE or msg.role == "assistant") and msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        local id = call.call_id or call.id
        if not id then
          return nil, "Retained tool call has no id"
        end
        local result_index
        for j = i + 1, #messages do
          local result = messages[j]
          if (result.role == "tool" or result.role == cc_config.constants.USER_ROLE)
            and result.tools and result.tools.call_id == id then
            result_index = j
            break
          end
        end
        if not result_index then
          return nil, "Retained tool call has no result: " .. tostring(id)
        end
        last = math.max(last, result_index)
      end
    end
    i = i + 1
  end
  return last
end

function M.rewind_target_for_message(chat, selected)
  if not chat then
    return nil, "No active chat"
  end
  if chat_is_busy(chat) then
    return nil, "Chat request is in progress; stop or wait for it before rewinding"
  end
  local messages = chat.messages or {}
  if type(selected) ~= "number" or selected % 1 ~= 0 or selected < 1 or selected > #messages then
    return nil, "No displayed message selected to rewind"
  end
  local index, err = complete_rewind_target(messages, selected)
  if not index then
    return nil, err
  end
  return { index = index, selected = selected, removed_count = #messages - index }
end

function M.rewind_chat_to_message(chat, selected)
  local target, err = M.rewind_target_for_message(chat, selected)
  if not target then
    return false, err
  end
  local ok, result = rewind_chat_from_index(chat, target.index + 1, "")
  if ok then
    result.index = target.index
  end
  return ok, result
end

function M.rewind_chat_to_user_message(chat, selected)
  if not chat then
    return false, "No active chat"
  end
  if chat_is_busy(chat) then
    return false, "Chat request is in progress; stop or wait for it before rewinding"
  end
  local index = type(selected) == "table" and selected.index or selected
  if type(index) ~= "number" or index % 1 ~= 0 then
    return false, "No user input selected to rewind"
  end
  selected = M.rewind_user_input(chat, index)
  if not selected then
    return false, "Selected message is not a user input"
  end
  if selected.call_id then
    local target, err = M.rewind_target_for_message(chat, index)
    if not target then return false, err end
    local ok, result = rewind_chat_from_index(chat, target.index + 1, selected.content, selected)
    if ok then result.index = index end
    return ok, result
  end
  return rewind_chat_from_index(chat, index, selected.content)
end

function M.rewind_current_chat(chat)
  if not chat then
    return false, "No active chat"
  end
  if chat_is_busy(chat) then
    return false, "Chat request is in progress; stop or wait for it before rewinding"
  end
  local selected = M.collect_rewind_message_items(chat)[1]
  if not selected then
    return false, "No user input found to rewind"
  end
  return M.rewind_chat_to_user_message(chat, selected)
end

function M.commit_rewind_reply(chat, content)
  local reply = chat._session_rewind_reply
  local selected = reply and M.rewind_user_input(chat, reply.index)
  if not selected or selected.message ~= reply.message or selected.call_id ~= reply.call_id then
    return false, "Rewound ask reply changed; rewind again before submitting"
  end
  if type(content) ~= "string" or not content:find("%S") then
    return false, "Ask reply must contain nonblank text"
  end
  local msg = selected.message
  msg.content = content
  msg._meta = msg._meta or {}
  msg._meta.output_bytes = #content
  msg._meta.presentation = msg._meta.presentation or {}
  msg._meta.presentation.result = require("maxa.interactions.chat.tools.builtin.runtime.ask_display")
    .display(selected.ask_args, { ok = true, text = content })
  -- A synchronous run->ask has the same result; discard its old view snapshot.
  msg._meta.presentation.invocation = nil
  return true
end

function M.restore_rewind_reply_input(chat, content)
  return render_chat_with_recovered_input(chat, content)
end

function M.replace_summary_range(chat, start_index, end_index, summary, opts)
  opts = opts or {}
  if not chat then
    return false, "No target chat"
  end
  if chat_is_busy(chat) then
    return false, "Chat request is in progress; stop or wait for it before summarizing"
  end
  local messages = chat.messages or {}
  start_index = math.max(1, tonumber(start_index) or 1)
  end_index = math.min(#messages, tonumber(end_index) or #messages)
  if start_index > end_index then
    return false, "Empty summary replacement range"
  end

  local snapshot = {
    messages = chat.messages,
    context_items = chat.context_items,
    protected_prefix_count = compaction_messages.get_protected_prefix_count(chat),
  }

  local preserve_indices = opts.preserve_indices or {}
  local previous = start_index - 1
  for _, index in ipairs(preserve_indices) do
    if type(index) ~= "number" or index % 1 ~= 0 or index <= previous or index > end_index then
      return false, "preserve_indices must be ordered indices inside the replacement range"
    end
    previous = index
  end
  local content = build_summary_content(summary, opts)
  local summary_msg = build_summary_message(content, opts)
  local next_messages = {}
  for index = 1, start_index - 1 do
    next_messages[index] = messages[index]
  end
  table.insert(next_messages, summary_msg)
  for _, index in ipairs(preserve_indices) do
    table.insert(next_messages, messages[index])
  end
  if opts.preserve_indices then
    local valid, issues = compaction_messages.validate_tool_pairs(next_messages)
    if not valid then
      return false, "summary replacement splits tool records: " .. vim.json.encode(issues)
    end
  end

  chat.messages = next_messages
  normalize_message_indices(chat.messages, start_index)
  prune_context_items_to_messages(chat)
  clamp_protected_prefix(chat)
  sync_chat_message_refs(chat)

  local ok_render, render_err = render_chat_with_blank_edit_area(chat)
  if not ok_render then
    restore_chat_snapshot(chat, snapshot)
    return false, render_err
  end

  if opts.save then
    local saved, save_err = opts.save(chat)
    if not saved then
      restore_chat_snapshot(chat, snapshot)
      render_chat_with_blank_edit_area(chat)
      opts.save(chat)
      return false, save_err
    end
  else
    save_chat_if_possible(chat)
  end
  return true, {
    start_index = start_index,
    end_index = end_index,
    summary_index = #chat.messages,
    removed_count = end_index - start_index + 1,
    content = content,
  }
end

function M.redo_current_chat(chat, opts)
  opts = opts or {}
  local ok, result = M.rewind_current_chat(chat)
  if not ok then
    return false, result
  end
  if type(chat.submit) ~= "function" then
    return false, "Chat cannot submit recovered input"
  end
  local submit = function()
    if chat.current_request then
      return
    end
    chat:submit()
  end
  if opts.schedule == false then
    submit()
  else
    vim.schedule(submit)
  end
  return true, result
end

local function render_parent_after_merge(parent)
  if not (parent and parent.ui and type(parent.ui.render) == "function") then
    return
  end

  local tool_display = require("maxa.interactions.chat.tools.display")
  local render_messages = tool_display.build_render_messages(parent.messages or {})
  local render_with_input = vim.deepcopy(render_messages)
  table.insert(render_with_input, {
    role = cc_config.constants.USER_ROLE,
    content = "",
  })

  pcall(function()
    parent.ui:render(parent.buffer_context, render_with_input, { stop_context_insertion = true })
  end)

  local ok_parser, parser = pcall(require, "maxa.interactions.chat.parser")
  if ok_parser then
    local ok_header, header_row = pcall(parser.headers, parent)
    if ok_header and header_row then
      parent.header_line = header_row + 1
    elseif parent.bufnr and vim.api.nvim_buf_is_valid(parent.bufnr) then
      parent.header_line = math.max(1, vim.api.nvim_buf_line_count(parent.bufnr) - 1)
    end
  end

  if parent.ui and type(parent.ui.display_tokens) == "function" then
    pcall(function()
      parent.ui:display_tokens(parent.chat_parser, parent.header_line)
    end)
  end
  tool_display.apply_render_postprocess(parent, render_messages)
end

local function append_messages_to_parent(parent, messages)
  for _, msg in ipairs(messages) do
    table.insert(parent.messages, vim.deepcopy(msg))
  end
  if parent.tools then
    parent.tools.messages = parent.messages
  end
  render_parent_after_merge(parent)
  save_chat_if_possible(parent)
end

function M.merge_scratch(chat)
  if not M.is_scratch_chat(chat) then
    return false, "Current chat is not a scratch session"
  end
  local meta = M.get_scratch_meta(chat)
  local parent = chat._session_scratch_parent_chat or find_open_chat_by_key(meta.parent_key)
  if not parent then
    return false, "Parent chat is not open; cannot merge scratch messages"
  end
  local start_index = (tonumber(meta.fork_start_index) or 0) + 1
  if start_index > #chat.messages then
    return false, "No new messages after scratch fork"
  end
  local end_index = #chat.messages
  local new_messages = {}
  for i = start_index, end_index do
    table.insert(new_messages, vim.deepcopy(chat.messages[i]))
  end
  if #new_messages == 0 then
    return false, "No new messages after scratch fork"
  end

  show_scratch_merge_status(
    chat,
    table.concat({
      "正在合并 scratch 会话……",
      "",
      string.format("将完整合并新增消息范围 [%d..%d]，完成后关闭 scratch 并返回原会话。", start_index, end_index),
    }, "\n")
  )
  notify("开始合并 scratch 新增消息...")

  local parent_before_count = #(parent.messages or {})
  local source_trace = session_trace.get_membership(chat)
  local parent_trace = session_trace.get_membership(parent)

  merge_context_state(parent, chat)
  append_messages_to_parent(parent, new_messages)

  if source_trace then
    local parent_span_id = parent_trace and parent_trace.span_id or source_trace.parent_span_id
    append_trace_event(source_trace.root_trace_id, {
      kind = "scratch.merged",
      span_id = source_trace.span_id,
      parent_span_id = parent_span_id,
      session = session_trace.session_info(chat, source_trace),
      parent_session = parent_trace and session_trace.session_info(parent, parent_trace) or nil,
      source = chat_identity(chat),
      parent = chat_identity(parent),
      fork_start_index = tonumber(meta.fork_start_index) or 0,
      merged_range = {
        start_index = start_index,
        end_index = end_index,
      },
      parent_appended_range = {
        start_index = parent_before_count + 1,
        end_index = #(parent.messages or {}),
      },
      appended_count = #new_messages,
      dedupe_key = table.concat({
        "scratch.merged",
        tostring(source_trace.span_id or "source"),
        tostring(parent_span_id or "parent"),
        tostring(start_index),
        tostring(end_index),
        tostring(#new_messages),
      }, ":"),
    })
  end

  show_scratch_merge_status(chat, "scratch 合并完成，正在返回原会话……")
  close_chat(chat, function()
    focus_chat(parent)
  end)
  notify("scratch messages merged to parent chat")
  return true, nil
end

local function open_user_message_picker(chat, opts)
  opts = opts or {}
  local items = (opts.collect or M.collect_user_message_items)(chat)
  if #items == 0 then
    notify(opts.empty_message or "当前会话没有可选择的用户消息", vim.log.levels.WARN)
    return
  end
  require("snacks.picker").pick({
    title = opts.title or "Select user message",
    items = items,
    main = { file = false, float = true },
    format = function(item)
      return { { string.format("[%d] %s", item.index, item.text ~= "" and item.text or "(empty)") } }
    end,
    transform = function(item)
      item.text = item.text or short_text(item.content, 100)
      item.file = "message:" .. tostring(item.index)
      return item
    end,
    preview = function(ctx)
      local lines, focus_line = M.build_preview_lines(chat, ctx.item and ctx.item.index)
      local buf_id = ctx.preview:scratch()
      vim.bo[buf_id].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
      vim.schedule(function()
        local win = ctx.preview and ctx.preview.win and ctx.preview.win.win
        if win and vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, focus_line), 0 })
          pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("normal! zt")
          end)
        end
      end)
    end,
    confirm = function(picker, _)
      local selections = picker:selected({ fallback = true })
      if not selections or #selections == 0 then
        return
      end
      local selected = selections[1]
      picker:close()
      opts.confirm(selected)
    end,
  })
end

function M.open_summarize_picker(chat)
  open_user_message_picker(chat, {
    title = "Summarize from user message",
    empty_message = "当前会话没有可摘要的用户消息",
    confirm = function(selected)
      local end_index = #chat.messages
      notify(string.format("开始摘要消息 [%d] 到会话末尾...", selected.index))
      set_summarize_input_pending(chat)
      M.summarize_range(chat, selected.index, end_index, function(summary, err)
        if err then
          clear_summarize_input_pending(chat, { blank = true })
          notify("summarize failed: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        clear_summarize_input_pending(chat, { blank = false })
        local ok, replace_result = M.replace_summary_range(chat, selected.index, end_index, summary, {
          tag = "session_manual_summary",
          source = "summarize",
          range = { start_index = selected.index, end_index = end_index },
        })
        if not ok then
          clear_summarize_input_pending(chat, { blank = true })
          notify("failed to replace summary range: " .. tostring(replace_result), vim.log.levels.ERROR)
          return
        end
        notify(string.format(
          "summary replaced messages [%d..%d] with summary at [%d]",
          replace_result.start_index or selected.index,
          replace_result.end_index or end_index,
          replace_result.summary_index or 0
        ))
      end)
    end,
  })
end

function M.open_rewind_to_picker(chat)
  open_user_message_picker(chat, {
    title = "Rewind to user message",
    collect = M.collect_rewind_message_items,
    empty_message = "当前会话没有可回退的用户消息",
    confirm = function(selected)
      local ok, result = M.rewind_chat_to_user_message(chat, selected.index)
      if not ok then
        notify("rewind_to failed: " .. tostring(result), vim.log.levels.ERROR)
        return
      end
      notify(string.format("rewound %d message(s); restored user input from [%d]", result.removed_count or 0, result.index or 0))
    end,
  })
end

return M
