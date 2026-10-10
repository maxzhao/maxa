local session_stats = require("maxa.session.session_stats")

local M = {}

local function fmt_num(n)
  if type(n) ~= "number" then
    return "-"
  end
  local s = tostring(math.floor(n))
  local k
  while true do
    s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    if k == 0 then
      break
    end
  end
  return s
end

local function fmt_ms(n)
  if type(n) ~= "number" or n <= 0 then
    return "-"
  end
  if n >= 1000 then
    return string.format("%.1fs", n / 1000)
  end
  return tostring(math.floor(n)) .. "ms"
end

local function fmt_percent(n)
  if type(n) ~= "number" then
    return "-"
  end
  return tostring(n) .. "%"
end

local function token_state(token)
  local percent = token and token.percent
  if type(percent) ~= "number" then
    return "unknown"
  end
  if percent >= 75 then
    return "warning zone"
  end
  return "ok"
end

local function add_kv(lines, key, value)
  table.insert(lines, string.format("- **%s**: %s", key, value == nil and "-" or tostring(value)))
end

local function sorted_pairs(tbl)
  local list = {}
  for k, v in pairs(tbl or {}) do
    table.insert(list, { key = k, value = v })
  end
  table.sort(list, function(a, b)
    if a.value == b.value then
      return a.key < b.key
    end
    return a.value > b.value
  end)
  return list
end

local function add_table(lines, headers, rows)
  table.insert(lines, "")
  table.insert(lines, "| " .. table.concat(headers, " | ") .. " |")
  local sep = {}
  for _ = 1, #headers do
    table.insert(sep, "---")
  end
  table.insert(lines, "| " .. table.concat(sep, " | ") .. " |")
  if #rows == 0 then
    local empty = {}
    for i = 1, #headers do
      empty[i] = i == 1 and "-" or ""
    end
    table.insert(lines, "| " .. table.concat(empty, " | ") .. " |")
    return
  end
  for _, row in ipairs(rows) do
    table.insert(lines, "| " .. table.concat(row, " | ") .. " |")
  end
end

local function render_bucket_rows(bucket_map, order)
  local rows = {}
  local used = {}
  local function add(name)
    local item = bucket_map and bucket_map[name]
    if not item then
      return
    end
    used[name] = true
    table.insert(rows, {
      name,
      fmt_num(item.count or 0),
      fmt_num(item.estimated_tokens or 0),
      fmt_num(item.content_bytes or 0),
      fmt_num(item.json_bytes or 0),
    })
  end

  for _, name in ipairs(order or {}) do
    add(name)
  end

  local rest = {}
  for name, item in pairs(bucket_map or {}) do
    if not used[name] and name ~= "total" then
      table.insert(rest, { name = name, item = item })
    end
  end
  table.sort(rest, function(a, b)
    local at = a.item.estimated_tokens or 0
    local bt = b.item.estimated_tokens or 0
    if at == bt then
      return a.name < b.name
    end
    return at > bt
  end)
  for _, entry in ipairs(rest) do
    add(entry.name)
  end

  return rows
end

local function render_tool_rows(stats, limit)
  local rows = {}
  for i, stat in ipairs(stats or {}) do
    if i > (limit or 12) then
      break
    end
    local flags = {}
    if stat.ttl_notices and stat.ttl_notices > 0 then
      table.insert(flags, "ttl=" .. stat.ttl_notices)
    end
    if stat.discarded and stat.discarded > 0 then
      table.insert(flags, "discard=" .. stat.discarded)
    end
    if stat.oversized and stat.oversized > 0 then
      table.insert(flags, "large=" .. stat.oversized)
    end
    table.insert(rows, {
      stat.name,
      fmt_num(stat.calls),
      fmt_num(stat.success),
      fmt_num(stat.failed),
      fmt_num(stat.input_tokens),
      fmt_num(stat.output_tokens),
      fmt_num((stat.input_tokens or 0) + (stat.output_tokens or 0)),
      fmt_ms(stat.duration_ms),
      fmt_ms(stat.avg_duration_ms),
      fmt_ms(stat.max_duration_ms),
      fmt_ms(stat.latest_duration_ms),
      stat.latest_index and tostring(stat.latest_index) or "-",
      table.concat(flags, " "),
    })
  end
  return rows
end

function M.render(stats)
  local lines = {}
  local token = stats.token or {}

  table.insert(lines, "# MaxaAI Session Status")
  table.insert(lines, "")
  table.insert(lines, "## Session")
  add_kv(lines, "save_id", stats.save_id)
  add_kv(lines, "title", stats.title)
  add_kv(lines, "adapter", stats.adapter)
  add_kv(lines, "model", stats.model)
  add_kv(lines, "messages", fmt_num(stats.message_counts and stats.message_counts.total or 0))
  add_kv(lines, "messages JSON bytes", fmt_num(stats.messages_json_bytes))
  add_kv(lines, "message content bytes", fmt_num(stats.message_content_bytes))

  table.insert(lines, "")
  table.insert(lines, "## Token")
  add_kv(lines, "session tokens", fmt_num(token.used) .. " / " .. fmt_num(token.limit))
  add_kv(lines, "session token percent", fmt_percent(token.percent))
  add_kv(lines, "session token source", token.source or "unknown")
  add_kv(lines, "state", token_state(token))
  add_kv(lines, "tool tokens", "estimated from JSON/content bytes, not provider exact usage")

  local message_stats = stats.message_stats or {}
  local function message_row(kind)
    local item = message_stats[kind] or {}
    return {
      kind,
      fmt_num(item.count or 0),
      fmt_num(item.estimated_tokens or 0),
      fmt_num(item.content_bytes or 0),
      fmt_num(item.json_bytes or 0),
    }
  end
  table.insert(lines, "")
  table.insert(lines, "## Messages")
  add_table(lines, { "kind", "count", "est tok", "content bytes", "json bytes" }, {
    message_row("system"),
    message_row("user"),
    message_row("assistant text"),
    message_row("assistant tool_call"),
    message_row("tool_result"),
    message_row("other"),
    message_row("total"),
  })

  table.insert(lines, "")
  table.insert(lines, "## Meta Tags")
  local tag_rows = {}
  for _, item in ipairs(sorted_pairs(stats.meta_tags)) do
    local tag_stat = stats.meta_tag_stats and stats.meta_tag_stats[item.key] or {}
    table.insert(tag_rows, {
      item.key,
      fmt_num(item.value),
      fmt_num(tag_stat.estimated_tokens or 0),
      fmt_num(tag_stat.content_bytes or 0),
      fmt_num(tag_stat.json_bytes or 0),
    })
  end
  add_table(lines, { "tag", "count", "est tok", "content bytes", "json bytes" }, tag_rows)

  table.insert(lines, "")
  table.insert(lines, "## Loaded Items")
  local loaded = stats.loaded or {}
  add_table(lines, { "kind", "items" }, {
    { "abilities", #(loaded.abilities or {}) > 0 and table.concat(loaded.abilities, ", ") or "-" },
    { "contexts", #(loaded.contexts or {}) > 0 and table.concat(loaded.contexts, ", ") or "-" },
    { "rules", #(loaded.rules or {}) > 0 and table.concat(loaded.rules, ", ") or "-" },
  })

  table.insert(lines, "")
  table.insert(lines, "## Compact Retention")
  local compact = stats.compact_retention or {}
  local preserved_total = compact.preserved and compact.preserved.total or {}
  local cleaned_total = compact.cleaned and compact.cleaned.total or {}
  add_kv(lines, "protected prefix messages", fmt_num(compact.protected_prefix_count or 0))
  add_kv(
    lines,
    "preserved total",
    string.format(
      "%s messages / %s est tok / %s json bytes",
      fmt_num(preserved_total.count or 0),
      fmt_num(preserved_total.estimated_tokens or 0),
      fmt_num(preserved_total.json_bytes or 0)
    )
  )
  add_kv(
    lines,
    "cleaned total",
    string.format(
      "%s messages / %s est tok / %s json bytes",
      fmt_num(cleaned_total.count or 0),
      fmt_num(cleaned_total.estimated_tokens or 0),
      fmt_num(cleaned_total.json_bytes or 0)
    )
  )
  table.insert(lines, "")
  table.insert(lines, "### Explicit compact tools — preserved categories")
  add_table(lines, { "category", "count", "est tok", "content bytes", "json bytes" }, render_bucket_rows(
    compact.preserved,
    {
      "total",
      "protected_prefix",
      "system_message",
      "initial_rules_context",
      "compact_summary",
      "loaded_item_context",
      "prompt_cache_warmup",
    }
  ))
  table.insert(lines, "")
  table.insert(lines, "### Compression control artifacts")
  add_table(lines, { "category", "count", "est tok", "content bytes", "json bytes" }, render_bucket_rows(
    compact.cleaned,
    {
      "total",
      "token_warning",
      "compact_self_tool_call",
      "compact_self_tool_result",
    }
  ))

  table.insert(lines, "")
  table.insert(lines, "## Tool Analytics — outer wrapper calls")
  add_kv(lines, "orphan tool results", fmt_num(stats.tools and stats.tools.orphan_results or 0))
  add_kv(lines, "pending tool calls", fmt_num(stats.tools and stats.tools.pending_calls or 0))
  add_table(lines, {
    "tool", "calls", "ok", "fail", "in tok", "out tok", "total tok", "total ms", "avg", "max", "latest", "last", "flags",
  }, render_tool_rows(stats.tools and stats.tools.outer or {}, 14))

  table.insert(lines, "")
  table.insert(lines, "## Tool Analytics — inner targets")
  table.insert(lines, "")
  table.insert(lines, "Inner tools are expanded from tool-mode `run.command`; multicall members have separate call/result records. Legacy nested history remains readable.")
  add_table(lines, {
    "tool", "calls", "ok", "fail", "in tok", "out tok", "total tok", "total ms", "avg", "max", "latest", "last", "flags",
  }, render_tool_rows(stats.tools and stats.tools.inner or {}, 18))

  table.insert(lines, "")
  table.insert(lines, "## Notes")
  table.insert(lines, "")
  table.insert(lines, "- Session token usage uses MaxaAI/runtime usage when available.")
  table.insert(lines, "- Message/meta/tool token usage is estimated from JSON/content bytes using the shared bytes/2.5 heuristic.")
  table.insert(lines, "- Compact Retention lists structural categories for explicit compact tools, not the handoff planner's selected intervals. `/compact_silent` uses configured tiers; `/compact_rescue` waits for a user-selected tier.")
  table.insert(lines, "- Tool duration uses tool result `_meta.duration_ms`; parallel inner duration uses child `duration_ms` when present, otherwise apportions aggregate duration.")
  table.insert(lines, "- Batch inner output bytes are apportioned across members when only one aggregate tool result exists.")
  table.insert(lines, "- This panel is read-only and does not mutate `chat.messages`.")

  return lines
end

local function set_panel_keymaps(win, refresh_stats)
  local bufnr = win and win.buf
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local function close()
    if win and not win.closed then
      win:close()
    end
  end

  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, desc = "Close session status panel" })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true, desc = "Close session status panel" })
  vim.keymap.set("n", "r", function()
    local stats, err = refresh_stats()
    if not stats then
      vim.notify(err or "Failed to collect session stats", vim.log.levels.ERROR)
      return
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.render(stats))
    vim.bo[bufnr].modifiable = false
  end, { buffer = bufnr, silent = true, desc = "Refresh session status panel" })
end

local function open_stats(stats, err)
  if not stats then
    vim.notify(err or "No Maxa AI chat found", vim.log.levels.ERROR)
    return
  end

  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.win then
    vim.notify("Snacks.win is not available", vim.log.levels.ERROR)
    return
  end

  local win = snacks.win({
    text = M.render(stats),
    title = stats.source == "history" and " MaxaAI History Session Status " or " MaxaAI Session Status ",
    width = 0.82,
    height = 0.82,
    border = "rounded",
    fixbuf = true,
    bo = {
      filetype = "markdown",
      buftype = "nofile",
      bufhidden = "wipe",
      swapfile = false,
      modifiable = false,
      readonly = true,
    },
    wo = {
      wrap = false,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      statuscolumn = "",
      cursorline = true,
    },
  })

  return win
end

function M.open(chat)
  if type(chat) ~= "table" then
    local ok, maxa_ai = pcall(require, "maxa")
    if ok and type(maxa_ai.buf_get_chat) == "function" then
      local success, current = pcall(maxa_ai.buf_get_chat, 0)
      if success then
        chat = current
      end
    end
  end

  local function refresh_stats()
    return session_stats.collect(chat)
  end
  local stats, err = refresh_stats()
  local win = open_stats(stats, err)
  set_panel_keymaps(win, refresh_stats)
  return win
end

function M.open_chat_data(chat_data, save_id)
  local function refresh_stats()
    return session_stats.collect_chat_data(chat_data, save_id)
  end
  local stats, err = refresh_stats()
  local win = open_stats(stats, err)
  set_panel_keymaps(win, refresh_stats)
  return win
end

return M
