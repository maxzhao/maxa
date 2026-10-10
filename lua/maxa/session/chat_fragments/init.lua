-- Maxa AI chat fragments: save/load reusable full-message snippets.
local M = {}

local session_trace = require("maxa.session.session_trace")

local SCHEMA_VERSION = 1
local FRAGMENT_DIR = ".maxa/fragments"

local function notify(msg, level)
  vim.notify("[chat_fragments] " .. msg, level or vim.log.levels.INFO)
end

local function project_root()
  local cwd = vim.fn.getcwd()
  local git_root = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })[1]
  if vim.v.shell_error == 0 and type(git_root) == "string" and git_root ~= "" then
    return git_root
  end
  return cwd
end

local function joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local parts = { ... }
  return table.concat(parts, "/")
end

local function json_encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

local function json_decode(text)
  if vim.json and vim.json.decode then
    return vim.json.decode(text)
  end
  return vim.fn.json_decode(text)
end

local function display_content(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    if type(value.content) == "string" then
      return value.content
    end
    local ok, encoded = pcall(json_encode, value)
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

local function role_label(role)
  local ok_config, cc_config = pcall(require, "maxa.config")
  if ok_config and cc_config and cc_config.constants then
    if role == cc_config.constants.USER_ROLE then
      return "User"
    elseif role == cc_config.constants.LLM_ROLE then
      return "Assistant"
    elseif role == cc_config.constants.SYSTEM_ROLE then
      return "System"
    end
  end
  if role == "tool" then
    return "Tool"
  end
  return tostring(role or "Message")
end

local function slugify(value)
  value = tostring(value or "fragment")
  value = value:lower():gsub("[^%w%-_]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if value == "" then
    value = "fragment"
  end
  return value
end

local function now_utc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

function M.fragment_dir(root)
  return joinpath(root or project_root(), FRAGMENT_DIR)
end

function M.make_fragment_id(title, created_at)
  local stamp = tostring(created_at or now_utc()):gsub("[^%d]", ""):sub(1, 14)
  if stamp == "" then
    stamp = os.date("!%Y%m%d%H%M%S")
  end
  return stamp .. "-" .. slugify(title)
end

function M.fragment_path(id, root)
  id = slugify(id)
  return joinpath(M.fragment_dir(root), id .. ".json")
end

function M.message_summary(msg, index)
  return string.format("%03d  %-9s  %s", tonumber(index) or 0, role_label(msg and msg.role), short_text(msg and msg.content, 100))
end

function M.message_preview_lines(msg, index)
  local lines = {
    string.format("# Message %d", tonumber(index) or 0),
    "",
    "```json",
  }
  local ok, encoded = pcall(json_encode, msg or {})
  table.insert(lines, ok and encoded or tostring(encoded))
  table.insert(lines, "```")
  table.insert(lines, "")
  table.insert(lines, "## Content")
  table.insert(lines, "")
  local content = display_content(msg and msg.content)
  if content == "" then
    content = "(empty)"
  end
  for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
    table.insert(lines, line)
  end
  return lines
end

function M.build_fragment(chat, messages, meta)
  meta = meta or {}
  local created_at = meta.created_at or now_utc()
  local title = vim.trim(tostring(meta.title or ""))
  if title == "" then
    title = "Chat Fragment " .. created_at
  end
  local id = meta.id or M.make_fragment_id(title, created_at)
  return {
    schema_version = SCHEMA_VERSION,
    id = id,
    title = title,
    description = tostring(meta.description or ""),
    created_at = created_at,
    source_chat = {
      title = chat and chat.opts and chat.opts.title or chat and chat.title or nil,
      bufnr = chat and chat.bufnr or nil,
      id = chat and chat.id or nil,
    },
    source_session = {
      save_id = chat and chat.opts and chat.opts.save_id or nil,
    },
    tags = vim.deepcopy(meta.tags or {}),
    messages = vim.deepcopy(messages or {}),
  }
end

function M.validate_fragment(fragment)
  if type(fragment) ~= "table" then
    return false, "fragment must be a JSON object"
  end
  if type(fragment.messages) ~= "table" then
    return false, "fragment.messages must be an array"
  end
  if fragment.schema_version ~= nil and tonumber(fragment.schema_version) ~= SCHEMA_VERSION then
    return false, "unsupported fragment schema_version: " .. tostring(fragment.schema_version)
  end
  return true, nil
end

function M.write_fragment(fragment, opts)
  opts = opts or {}
  local ok, err = M.validate_fragment(fragment)
  if not ok then
    return nil, err
  end
  local root = opts.root or project_root()
  ensure_dir(M.fragment_dir(root))
  local path = opts.path or M.fragment_path(fragment.id, root)
  local serializable = vim.deepcopy(fragment)
  local ok_utils, history_utils = pcall(require, "maxa.session.history.utils")
  if ok_utils and history_utils and type(history_utils.remove_functions) == "function" then
    serializable = history_utils.remove_functions(serializable)
  end
  local encoded = json_encode(serializable)
  local formatted = vim.fn.has("nvim-0.11") == 1 and encoded or encoded
  local write_ok, write_err = pcall(vim.fn.writefile, vim.split(formatted .. "\n", "\n", { plain = true }), path)
  if not write_ok then
    return nil, tostring(write_err)
  end
  return path, nil
end

function M.read_fragment(path)
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    return nil, tostring(lines)
  end
  local ok_json, decoded = pcall(json_decode, table.concat(lines, "\n"))
  if not ok_json then
    return nil, "invalid JSON: " .. tostring(decoded)
  end
  local ok_valid, err = M.validate_fragment(decoded)
  if not ok_valid then
    return nil, err
  end
  decoded._path = path
  return decoded, nil
end

function M.list_fragments(opts)
  opts = opts or {}
  local dir = opts.dir or M.fragment_dir(opts.root)
  local pattern = joinpath(dir, "*.json")
  local paths = vim.fn.glob(pattern, false, true)
  table.sort(paths)
  local items = {}
  for _, path in ipairs(paths) do
    local fragment, err = M.read_fragment(path)
    if fragment then
      table.insert(items, {
        path = path,
        id = fragment.id,
        title = fragment.title or fragment.id or vim.fn.fnamemodify(path, ":t:r"),
        description = fragment.description or "",
        tags = fragment.tags or {},
        message_count = #(fragment.messages or {}),
        fragment = fragment,
      })
    else
      table.insert(items, {
        path = path,
        id = vim.fn.fnamemodify(path, ":t:r"),
        title = vim.fn.fnamemodify(path, ":t"),
        description = "Invalid fragment: " .. tostring(err),
        tags = {},
        message_count = 0,
        invalid = true,
        error = err,
      })
    end
  end
  return items
end

function M.prepare_inserted_messages(fragment, start_index)
  local messages = vim.deepcopy(fragment.messages or {})
  local inserted_at = now_utc()
  for offset, msg in ipairs(messages) do
    if type(msg) == "table" then
      msg._meta = type(msg._meta) == "table" and msg._meta or {}
      local new_index = (start_index or 0) + offset
      msg._meta.index = new_index
      msg._meta.inserted_at = inserted_at
      msg._meta.inserted_from_fragment = fragment.id or fragment._path or true
      if msg.id ~= nil then
        msg.id = string.format("fragment:%s:%d", tostring(fragment.id or fragment._path or "unknown"), new_index)
      end
      if msg.timestamp ~= nil then
        msg.timestamp = inserted_at
      end
      if msg.created_at ~= nil then
        msg.created_at = inserted_at
      end
    end
  end
  return messages
end

local function save_chat_if_possible(chat)
  local ok_history, history_api = pcall(function()
    return require("maxa.session").history()
  end)
  if ok_history and history_api and type(history_api.save_chat) == "function" then
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

local function sync_chat_message_refs(chat)
  if chat and chat.tools then
    chat.tools.messages = chat.messages
  end
end

local function render_chat(chat)
  if not (chat and chat.ui and type(chat.ui.render) == "function") then
    return true, nil
  end
  local tool_display = require("maxa.interactions.chat.tools.display")
  local render_messages = tool_display.build_render_messages(chat.messages or {})
  local ok, err = pcall(function()
    chat.ui:render(chat.buffer_context, render_messages, { stop_context_insertion = true })
  end)
  if not ok then
    return false, tostring(err)
  end
  pcall(tool_display.apply_render_postprocess, chat, render_messages)
  return true, nil
end

function M.append_fragment_to_chat(chat, fragment, opts)
  opts = opts or {}
  if not chat then
    return false, "No active chat"
  end
  if chat.current_request or chat.current_tool then
    return false, "Chat request is in progress; stop or wait for it before inserting a fragment"
  end
  local ok, err = M.validate_fragment(fragment)
  if not ok then
    return false, err
  end
  local snapshot = vim.deepcopy(chat.messages or {})
  local start_index = #(chat.messages or {})
  local messages = M.prepare_inserted_messages(fragment, start_index)
  chat.messages = chat.messages or {}
  for _, msg in ipairs(messages) do
    table.insert(chat.messages, msg)
  end
  sync_chat_message_refs(chat)
  local render_ok, render_err = render_chat(chat)
  if not render_ok then
    chat.messages = snapshot
    sync_chat_message_refs(chat)
    return false, render_err
  end
  if not opts.skip_save then
    save_chat_if_possible(chat)
  end

  local membership = session_trace.get_membership(chat)
  local first_index = start_index + 1
  local end_index = start_index + #messages
  if membership then
    append_trace_event(membership.root_trace_id, {
      kind = "fragment.inserted",
      span_id = membership.span_id,
      parent_span_id = membership.parent_span_id,
      session = session_trace.session_info(chat, membership),
      fragment = {
        id = fragment.id,
        path = fragment._path,
        title = fragment.title,
      },
      inserted_range = {
        start_index = first_index,
        end_index = end_index,
      },
      appended_count = #messages,
      dedupe_key = table.concat({
        "fragment",
        tostring(membership.span_id or "span"),
        tostring(fragment.id or fragment._path or "unknown"),
        tostring(first_index),
        tostring(#messages),
      }, ":"),
    })
  end

  return true, {
    appended = #messages,
    fragment_id = fragment.id,
    fragment_path = fragment._path,
    start_index = first_index,
    end_index = end_index,
  }
end

function M.collect_metadata(callback)
  vim.ui.input({ prompt = "Fragment title: " }, function(title)
    title = vim.trim(tostring(title or ""))
    if title == "" then
      notify("fragment title is required", vim.log.levels.WARN)
      return
    end
    vim.ui.input({ prompt = "Description: " }, function(description)
      vim.ui.input({ prompt = "Tags (comma separated): " }, function(tags_input)
        local tags = {}
        for _, tag in ipairs(vim.split(tags_input or "", ",", { plain = true })) do
          tag = vim.trim(tag)
          if tag ~= "" then
            table.insert(tags, tag)
          end
        end
        callback({ title = title, description = description or "", tags = tags })
      end)
    end)
  end)
end

function M.open_save_picker(chat)
  if not chat then
    notify("No active Maxa AI chat", vim.log.levels.ERROR)
    return
  end
  local draft_messages = vim.deepcopy(chat.messages or {})
  if #draft_messages == 0 then
    notify("Current chat has no messages to save", vim.log.levels.WARN)
    return
  end

  local function build_items()
    local items = {}
    for index, msg in ipairs(draft_messages) do
      table.insert(items, {
        index = index,
        msg = msg,
        text = M.message_summary(msg, index),
      })
    end
    return items
  end

  local function open_picker()
    require("snacks.picker").pick({
      title = "Save chat fragment: select messages",
      items = build_items(),
      main = { file = false, float = true },
      format = function(item)
        return { { item.text } }
      end,
      preview = function(ctx)
        local buf = ctx.preview:scratch()
        vim.bo[buf].filetype = "markdown"
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.message_preview_lines(ctx.item.msg, ctx.item.index))
      end,
      confirm = function(picker)
        local selections = picker:selected({ fallback = true })
        if #selections == 0 then
          notify("No messages selected", vim.log.levels.WARN)
          return
        end
        table.sort(selections, function(a, b)
          return a.index < b.index
        end)
        local selected_messages = {}
        for _, item in ipairs(selections) do
          table.insert(selected_messages, vim.deepcopy(item.msg))
        end
        picker:close()
        M.collect_metadata(function(meta)
          local fragment = M.build_fragment(chat, selected_messages, meta)
          local path, err = M.write_fragment(fragment)
          if not path then
            notify("failed to save fragment: " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          notify("saved fragment: " .. path)
        end)
      end,
      actions = {
        delete_from_draft = function(picker)
          local selections = picker:selected({ fallback = true })
          if #selections == 0 then
            return
          end
          table.sort(selections, function(a, b)
            return a.index > b.index
          end)
          for _, item in ipairs(selections) do
            table.remove(draft_messages, item.index)
          end
          picker:close()
          if #draft_messages == 0 then
            notify("fragment draft is empty after delete", vim.log.levels.WARN)
            return
          end
          open_picker()
        end,
      },
      win = {
        input = { keys = { d = { "delete_from_draft", mode = "n" }, ["<M-d>"] = { "delete_from_draft", mode = "i" } } },
        list = { keys = { d = { "delete_from_draft", mode = "n" }, ["<M-d>"] = { "delete_from_draft", mode = "i" } } },
      },
    })
  end

  open_picker()
end

function M.open_insert_picker(chat)
  if not chat then
    notify("No active Maxa AI chat", vim.log.levels.ERROR)
    return
  end
  local items = M.list_fragments()
  if #items == 0 then
    notify("No fragments found in " .. M.fragment_dir(), vim.log.levels.WARN)
    return
  end
  require("snacks.picker").pick({
    title = "Insert chat fragment",
    items = items,
    main = { file = false, float = true },
    format = function(item)
      local tags = #item.tags > 0 and (" [" .. table.concat(item.tags, ",") .. "]") or ""
      return { { string.format("%s  (%d messages)%s", item.title, item.message_count, tags) } }
    end,
    preview = function(ctx)
      local item = ctx.item
      local lines = {
        "# " .. tostring(item.title),
        "",
        "- path: " .. tostring(item.path),
        "- id: " .. tostring(item.id),
        "- messages: " .. tostring(item.message_count),
        "- tags: " .. table.concat(item.tags or {}, ", "),
        "",
        tostring(item.description or ""),
        "",
      }
      if item.invalid then
        table.insert(lines, "ERROR: " .. tostring(item.error))
      elseif item.fragment then
        table.insert(lines, "## Messages")
        for index, msg in ipairs(item.fragment.messages or {}) do
          table.insert(lines, M.message_summary(msg, index))
        end
      end
      local buf = ctx.preview:scratch()
      vim.bo[buf].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end,
    confirm = function(picker)
      local selections = picker:selected({ fallback = true })
      local item = selections and selections[1]
      if not item then
        return
      end
      picker:close()
      if item.invalid then
        notify("cannot load invalid fragment: " .. tostring(item.error), vim.log.levels.ERROR)
        return
      end
      local ok, result = M.append_fragment_to_chat(chat, item.fragment)
      if not ok then
        notify("failed to insert fragment: " .. tostring(result), vim.log.levels.ERROR)
        return
      end
      notify(string.format("inserted fragment %s (%d messages)", result.fragment_id or item.id, result.appended or 0))
    end,
  })
end

function M.get_active_chat(fallback)
  local ok, maxa_ai = pcall(require, "maxa")
  if ok and maxa_ai and type(maxa_ai.buf_get_chat) == "function" then
    local ok_chat, chat = pcall(maxa_ai.buf_get_chat, 0)
    if ok_chat and type(chat) == "table" then
      return chat
    end
  end
  return fallback
end

return M
