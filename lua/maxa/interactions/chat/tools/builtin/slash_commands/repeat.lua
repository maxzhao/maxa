-- repeat: 重复发送当前用户消息
--
-- 使用流程:
-- 1. 用户在 chat buffer 中写好消息
-- 2. 执行 /repeat 命令
-- 3. 命令提取用户消息，提交到 LLM
-- 4. LLM 回复完成后，自动重新发送相同消息
-- 5. 循环直到用户按 Ctrl+C 中断
--
-- 设计要点:
-- - 不修改 chat 方法（不 monkey-patch done/submit），使用回调机制
-- - 通过 on_completed 回调实现循环（成功时继续，错误时退避重试）
-- - 通过 on_cancelled 回调停止循环（用户 Ctrl+C）
-- - 最小发送间隔 2s，避免快速响应时刷屏
-- - 连续错误指数退避（2s → 4s → 8s），超过 3 次自动停止
-- - 首轮发送原始用户消息，后续发送基于“任务锚点”的自包含检查消息

local cc_config = require("maxa.config")
local log = require("maxa.utils.log")

-- ─── Constants ──────────────────────────────────────────────────────────────

local STATE_KEY = "_repeat_state"
local NS_REPEAT = vim.api.nvim_create_namespace("repeat_indicator")
local LOOP_INDICATOR = " 🔁"

local MIN_INTERVAL_MS = 2000 -- 最小发送间隔（毫秒）
local MAX_CONSECUTIVE_ERRORS = 3 -- 连续错误上限，超过自动停止
local BASE_BACKOFF_MS = 2000 -- 退避基数（毫秒），指数退避: base * 2^(errors-1)

-- ─── State management ───────────────────────────────────────────────────────

---@class RepeatState
---@field active boolean Whether repeat mode is active
---@field initial_message string The original user message submitted in the first cycle
---@field task_anchor string Short self-contained task anchor for follow-up checks
---@field last_submitted_message string|nil The actual user message submitted most recently
---@field cycle_count number Number of submitted repeat cycles
---@field consecutive_errors number Number of consecutive errors
---@field last_submit_time number|nil Timestamp (ms) of last submit

--- Get repeat state
---@param chat table
---@return RepeatState|nil
local function get_state(chat)
  return chat[STATE_KEY]
end

--- Check if repeat is active
---@param chat table
---@return boolean
local function is_active(chat)
  local state = get_state(chat)
  return state ~= nil and state.active
end

-- ─── Header indicators (extmark-based) ──────────────────────────────────────

--- Check if a line is a role header
---@param line string
---@return boolean
local function is_header_line(line)
  return line:match("^## ") ~= nil
end

--- Apply 🔁 extmark to all header lines
---@param bufnr number
local function apply_header_marks(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, NS_REPEAT, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if is_header_line(line) then
      vim.api.nvim_buf_set_extmark(bufnr, NS_REPEAT, i - 1, 0, {
        virt_text = { { LOOP_INDICATOR, "MaxaAIChatHeader" } },
        virt_text_pos = "eol",
        priority = 200,
      })
    end
  end
end

--- Start watching buffer for new header lines
---@param chat table
local function start_header_watch(chat)
  local state = get_state(chat)
  if not state or state._header_autocmd then
    return
  end
  state._header_autocmd = vim.api.nvim_buf_attach(chat.bufnr, false, {
    on_lines = function(_, bufnr, _, first, _, last)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return true
      end
      local s = get_state(chat)
      if not s or not s.active then
        return true -- detach
      end
      local changed = vim.api.nvim_buf_get_lines(bufnr, first, last, false)
      for i, line in ipairs(changed) do
        if is_header_line(line) then
          local existing = vim.api.nvim_buf_get_extmarks(
            bufnr, NS_REPEAT,
            { first + i - 1, 0 }, { first + i - 1, -1 }, {}
          )
          if #existing == 0 then
            vim.api.nvim_buf_set_extmark(bufnr, NS_REPEAT, first + i - 1, 0, {
              virt_text = { { LOOP_INDICATOR, "MaxaAIChatHeader" } },
              virt_text_pos = "eol",
              priority = 200,
            })
          end
        end
      end
    end,
  })
end

--- Add repeat indicator to headers
---@param chat table
local function mark_roles(chat)
  if not chat.bufnr or not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return
  end
  apply_header_marks(chat.bufnr)
  start_header_watch(chat)
end

--- Remove repeat indicator extmarks
---@param chat table
local function unmark_roles(chat)
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.api.nvim_buf_clear_namespace(chat.bufnr, NS_REPEAT, 0, -1)
  end
  local state = get_state(chat)
  if state then
    state._header_autocmd = nil
  end
end

-- ─── Repeat prompt helpers ───────────────────────────────────────────────────

---@param text string
---@return string
local function first_meaningful_line(text)
  for line in vim.gsplit(text or "", "\n", { plain = true }) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      return trimmed
    end
  end
  return ""
end

---@param line string
---@return string
local function normalize_anchor_line(line)
  line = vim.trim(line or "")
  line = line:gsub("^#+%s*", "")
  line = line:gsub("^[-*+]%s*", "")
  line = line:gsub("^%d+[.)]%s*", "")
  line = line:gsub("%s+", " ")
  return vim.trim(line)
end

---@param text string
---@return string
local function derive_default_anchor(text)
  local line = normalize_anchor_line(first_meaningful_line(text))
  if line == "" then
    return "继续推进当前任务直到完成"
  end

  if vim.fn.strdisplaywidth(line) > 80 then
    line = vim.fn.strcharpart(line, 0, 80) .. "…"
  end

  return line
end

---@param anchor string
---@param cycle_no number
---@return string
local function build_repeat_message(anchor, cycle_no)
  return string.format(
    table.concat({
      "【循环检查｜第 %d 轮】",
      "",
      "当前持续推进的任务：",
      "%s",
      "",
      "请先判断该任务是否已经完成：",
      "- 如果未完成：继续执行下一步，必要时调用工具，不要只做总结",
      "- 如果已完成：不要再调用工具，只简短说明完成结果",
      "- 如果存在阻塞：明确说明阻塞点",
    }, "\n"),
    cycle_no,
    anchor
  )
end

-- ─── Deactivate ─────────────────────────────────────────────────────────────

--- Stop the repeat loop
---@param chat table
---@param reason? string
local function deactivate(chat, reason)
  local state = get_state(chat)
  if not state then
    return
  end

  local cycles = state.cycle_count
  state.active = false
  chat[STATE_KEY] = nil
  unmark_roles(chat)

  -- Deferred extmark cleanup.
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    local bufnr = chat.bufnr
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, NS_REPEAT, 0, -1)
      end
    end)
  end

  reason = reason or "stopped"
  vim.notify(
    string.format("[repeat] 已停止 (%s)，共完成 %d 轮", reason, cycles),
    vim.log.levels.INFO
  )
end

-- ─── Core: repeat cycle ─────────────────────────────────────────────────────

--- Calculate delay for next cycle, respecting min interval and error backoff
---@param state RepeatState
---@return number delay_ms
local function calc_next_delay(state)
  -- Enforce minimum interval since last submit
  local elapsed = 0
  if state.last_submit_time then
    elapsed = vim.uv.now() - state.last_submit_time
  end
  local min_wait = math.max(0, MIN_INTERVAL_MS - elapsed)

  -- Add exponential backoff if there were consecutive errors
  local backoff = 0
  if state.consecutive_errors > 0 then
    -- 2s → 4s → 8s (base * 2^(n-1))
    backoff = BASE_BACKOFF_MS * math.pow(2, state.consecutive_errors - 1)
  end

  return math.max(min_wait, backoff)
end

--- Submit the repeated message (shared by schedule_next_cycle and retry)
---@param chat table
local function do_submit(chat)
  local s = get_state(chat)
  if not s or not s.active then
    return
  end

  local ok_soft_stop, soft_stop = pcall(require, "maxa.lifecycle.chat_soft_stop")
  if ok_soft_stop and soft_stop and type(soft_stop.is_latched) == "function" and soft_stop.is_latched(chat) then
    deactivate(chat, "soft stop")
    return
  end

  if not vim.api.nvim_buf_is_valid(chat.bufnr) then
    chat[STATE_KEY] = nil
    return
  end

  -- Guard: don't submit if a request is somehow still in progress
  if chat.current_request then
    log:debug("[repeat] Request still in progress, waiting...")
    return
  end

  s.last_submit_time = vim.uv.now()
  s.cycle_count = s.cycle_count + 1

  local repeat_message = build_repeat_message(s.task_anchor, s.cycle_count)
  s.last_submitted_message = repeat_message

  -- Add the repeated user message to messages array
  chat:add_message({
    role = cc_config.constants.USER_ROLE,
    content = repeat_message,
  })

  -- Write the user message to the buffer so it's visible
  chat:add_buf_message({
    role = cc_config.constants.USER_ROLE,
    content = repeat_message,
  })

  -- Lock buffer during LLM response (auto_submit skips lock_buf in submit())
  chat.ui:lock_buf()

  -- Submit with auto_submit to bypass buffer parsing (message already added above)
  chat:submit({ auto_submit = true })
end

--- Check if auto_compact is handling an abnormal response
--- (compressing, network-retrying, or just exhausted retries for an empty response)
---@param chat table
---@return boolean
local function is_auto_compact_busy(chat)
  return chat._auto_compact_in_progress
    or chat._network_retry_pending
    or (chat._network_retry_timer ~= nil)
    or chat._network_retry_exhausted
end

--- Handle error: retry with backoff or stop after max errors
---@param chat table
---@param err? string
local function handle_error(chat, err)
  local state = get_state(chat)
  if not state or not state.active then
    return
  end

  state.consecutive_errors = state.consecutive_errors + 1
  log:warn("[repeat] Error #%d: %s", state.consecutive_errors, err or "unknown")

  if state.consecutive_errors >= MAX_CONSECUTIVE_ERRORS then
    deactivate(chat, string.format("连续 %d 次错误，最后错误: %s", state.consecutive_errors, err or "unknown"))
    return
  end

  -- Retry with exponential backoff
  local delay = calc_next_delay(state)
  vim.notify(
    string.format("[repeat] 错误 (%s)，%0.1fs 后重试 (%d/%d)",
      err or "unknown", delay / 1000, state.consecutive_errors, MAX_CONSECUTIVE_ERRORS),
    vim.log.levels.WARN
  )

  vim.defer_fn(function()
    do_submit(chat)
  end, delay)
end

--- Check if LLM made any tool calls since the last submitted user message.
--- Scans chat.messages backwards: finds the last user message matching
--- state.last_submitted_message, then checks if any LLM message after it
--- contains tool_calls. If no tool calls were found, LLM replied with pure
--- text — work is done.
---@param chat table
---@return boolean true if tool calls were found since last submitted message
local function had_tool_calls_since_submit(chat)
  local state = get_state(chat)
  if not state or not state.last_submitted_message then
    return true -- safe default: continue
  end

  local messages = chat.messages
  if not messages or #messages == 0 then
    return true
  end

  -- Find the last user message matching the most recently submitted content.
  local anchor_idx = nil
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.role == cc_config.constants.USER_ROLE and msg.content == state.last_submitted_message then
      anchor_idx = i
      break
    end
  end

  if not anchor_idx then
    return true -- can't find anchor, safe default: continue
  end

  -- Scan forward from anchor: LLM message with tool_calls?
  -- CC stores tool calls in msg.tools.calls (after format_calls),
  -- NOT in msg.tool_calls (which is only used during streaming before done()).
  for i = anchor_idx + 1, #messages do
    local msg = messages[i]
    if msg.role == cc_config.constants.LLM_ROLE then
      local calls = msg.tools and msg.tools.calls
      if calls and not vim.tbl_isempty(calls) then
        return true
      end
    end
  end

  return false
end

--- Schedule the next repeat cycle (called on successful completion)
---@param chat table
local function schedule_next_cycle(chat)
  local state = get_state(chat)
  if not state or not state.active then
    return
  end

  -- Reset consecutive errors on success
  state.consecutive_errors = 0

  local next_cycle = state.cycle_count + 1
  local delay = calc_next_delay(state)
  log:debug("[repeat] Scheduling cycle #%d (delay=%dms)", next_cycle, delay)

  vim.defer_fn(function()
    -- Re-check state (user may have cancelled during defer)
    do_submit(chat)
  end, delay)
end

-- ─── Slash Command ──────────────────────────────────────────────────────────

---@class MaxaAI.SlashCommand.Repeat: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommandArgs
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })
  return self
end

--- Execute the slash command
---@param SlashCommands MaxaAI.SlashCommands
---@return nil
function SlashCommand:execute(SlashCommands)
  local chat = self.Chat

  -- Guard: already in repeat mode
  if is_active(chat) then
    vim.notify("[repeat] 已处于 Repeat 模式中，按 Ctrl+C 中断", vim.log.levels.WARN)
    return
  end

  -- Guard: request in progress
  if chat.current_request then
    vim.notify("[repeat] 当前有请求进行中，请等待完成后再执行", vim.log.levels.WARN)
    return
  end

  -- Extract user message from buffer
  local parser = require("maxa.interactions.chat.parser")
  local msg = parser.messages(chat, chat.header_line)

  -- Recalculate header_line if stale
  if not msg or not msg.content or vim.trim(msg.content) == "" then
    local recalculated = parser.headers(chat)
    if recalculated then
      local new_hl = recalculated + 1
      if new_hl ~= chat.header_line then
        chat.header_line = new_hl
        msg = parser.messages(chat, chat.header_line)
      end
    end
  end

  -- Guard: empty message
  if not msg or not msg.content or vim.trim(msg.content) == "" then
    vim.notify("[repeat] 请先输入要重复发送的消息", vim.log.levels.WARN)
    return
  end

  local user_message = msg.content
  local default_anchor = derive_default_anchor(user_message)

  vim.ui.input({
    prompt = "Repeat 任务锚点: ",
    default = default_anchor,
  }, function(input)
    if input == nil then
      vim.notify("[repeat] 已取消", vim.log.levels.INFO)
      return
    end

    local task_anchor = vim.trim(input)
    if task_anchor == "" then
      task_anchor = default_anchor
    end

    log:debug("[repeat] Starting repeat mode with anchor: %s", task_anchor:sub(1, 80))

    -- Initialize state
    chat[STATE_KEY] = {
      active = true,
      initial_message = user_message,
      task_anchor = task_anchor,
      last_submitted_message = user_message,
      cycle_count = 0,
      consecutive_errors = 0,
      last_submit_time = nil,
      _header_autocmd = nil,
    }

    mark_roles(chat)

    -- Register on_completed callback: schedule next cycle or handle error
    -- NOTE: MaxaAI dispatches on_completed for BOTH success and error.
    -- There is no separate on_error event. The status is passed as the 2nd arg:
    --   dispatch("on_completed", { status = "success" | "error" })
    chat:add_callback("on_completed", function(self_chat, info)
      if not is_active(self_chat) then
        return
      end

      -- Guard: auto_compact is handling an abnormal response.
      -- During active compression or network retry, skip to avoid interference.
      -- When network retries are exhausted, stop repeat directly instead of
      -- entering repeat's own backoff, to avoid nested retry loops.
      if is_auto_compact_busy(self_chat) then
        if self_chat._network_retry_exhausted then
          self_chat._network_retry_exhausted = nil
          deactivate(self_chat, "网络重试已耗尽")
        else
          log:debug("[repeat] Skipping on_completed: auto_compact is busy")
        end
        return
      end

      local status = info and info.status
      if status == "error" then
        handle_error(self_chat, "LLM returned error status")
      elseif not had_tool_calls_since_submit(self_chat) then
        -- LLM replied with pure text (no tool calls) since last repeat submit.
        -- This means the work is done — stop repeating.
        deactivate(self_chat, "LLM 无工具调用，任务已完成")
      else
        schedule_next_cycle(self_chat)
      end
    end)

    -- Register on_error callback: handle auto_compact failures etc.
    -- CC itself never dispatches on_error, but llm_error_recovery does
    -- when silent compression fails after token limit detection.
    chat:add_callback("on_error", function(self_chat, err)
      if not is_active(self_chat) then
        return
      end
      handle_error(self_chat, type(err) == "string" and err or "on_error dispatched")
    end)

    -- Register on_cancelled callback: stop repeat on Ctrl+C
    chat:add_callback("on_cancelled", function(self_chat)
      if is_active(self_chat) then
        deactivate(self_chat, "用户中断")
      end
    end)

    -- Register on_closed callback: clean up on buffer close
    chat:add_callback("on_closed", function(self_chat)
      if is_active(self_chat) then
        self_chat[STATE_KEY] = nil
      end
    end)

    -- Submit the first message normally (CC handles buffer parsing and message adding)
    vim.defer_fn(function()
      if not vim.api.nvim_buf_is_valid(chat.bufnr) then
        chat[STATE_KEY] = nil
        return
      end
      chat:submit()
    end, 50)
  end)
end

SlashCommand.deactivate = deactivate

return SlashCommand
