-- One Session-owned handoff compaction workflow; legacy compact commands stay independent.
local M = {}
local identity = require("maxa.session.agent_identity")
local history = require("maxa.session.history_session")
local history_core = require("maxa.session.history_core")
local protection = require("maxa.session.compaction_messages")
local soft_stop = require("maxa.lifecycle.chat_soft_stop")
local transfer = require("maxa.mcphub.native_servers.subagent.session_handoff")
local utils = require("maxa.mcphub.native_servers.subagent.utils")
local ranks = { conservative = 1, balanced = 2, aggressive = 3, delete = 4 }
local labels = { conservative = "保守", balanced = "平衡", aggressive = "激进", delete = "删除" }

local function live(chat)
  return chat and not chat._closed and vim.api.nvim_buf_is_valid(chat.bufnr)
end

local function append(chat, content, tag)
  chat:add_message({ role = "user", content = content }, { visible = false, _meta = { tag = tag } })
end

local function material(params, field, root)
  local text = params[field .. "_text"]
  local path = params[field .. "_file"]
  if text and path then return nil, "provide either " .. field .. "_text or " .. field .. "_file" end
  if path then
    path = vim.fn.expand(path)
    if not path:match("^/") and not path:match("^%a:[/\\]") then path = vim.fs.joinpath(root, path) end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then return nil, "cannot read " .. field .. "_file: " .. tostring(lines) end
    text = table.concat(lines, "\n")
  end
  return text
end

-- Segment intervals are the only historical payload accepted from the LLM.
function M.select_messages(messages, segments, profile)
  local rank = ranks[profile]
  if not rank or profile == "delete" then return nil, "invalid compaction profile" end
  local selected, output, omitted = {}, {}, {}
  local previous = 0
  for i, segment in ipairs(segments or {}) do
    local first, last = segment.start_index, segment.end_index
    if type(first) ~= "number" or type(last) ~= "number" or first % 1 ~= 0 or last % 1 ~= 0
      or first <= previous or last < first or last > #messages or not ranks[segment.profile] then
      return nil, "invalid or overlapping segment " .. i
    end
    if first ~= previous + 1 then return nil, "segments must cover source history without gaps" end
    previous = last
    if ranks[segment.profile] >= rank and segment.profile ~= "delete" then
      for index = first, last do selected[index] = true end
    end
  end
  if previous ~= #messages then return nil, "segments must cover the entire source history" end
  -- Reject a split structural record rather than copying an omitted/delete tier.
  local tool_pairs = protection.analyze_tool_pairs(messages)
  for _, pair in pairs(tool_pairs) do
    if (pair.call_index and selected[pair.call_index]) or (pair.response_index and selected[pair.response_index]) then
      if not pair.call_index or not pair.response_index or not selected[pair.call_index] or not selected[pair.response_index] then
        return nil, "retention tiers split a tool call/result; keep the complete pair in one tier"
      end
    end
  end
  for index, message in ipairs(messages) do
    local ability = message._meta and message._meta.ability
    if selected[index] and ability then
      for related_index, related in ipairs(messages) do
        local related_ability = related._meta and related._meta.ability
        local call_id = related.tools and related.tools.call_id or related.tool_call_id
        if (related_ability and related_ability.name == ability.name and related_ability.digest == ability.digest)
          or (ability.catalog_call_id and call_id == ability.catalog_call_id) then
          if not selected[related_index] then return nil, "retention tiers split Ability context/catalog: " .. ability.name end
        end
      end
    end
  end
  for index, message in ipairs(messages) do
    if selected[index] then output[#output + 1] = vim.deepcopy(message)
    else omitted[#omitted + 1] = index end
  end
  return output, nil, omitted
end

local progress_ns = vim.api.nvim_create_namespace("MaxaHandoffCompactionProgress")

local function show_progress(state)
  if state.interactive then return end
  local source = state.source
  local bufnr = source.ui and source.ui.chat_bufnr or source.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local row = vim.api.nvim_buf_line_count(bufnr)
  local progress = { bufnr = bufnr, dots = 1, modifiable = vim.bo[bufnr].modifiable }
  source.ui:unlock_buf()
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "", "⏳ 压缩中." })
  progress.mark = vim.api.nvim_buf_set_extmark(bufnr, progress_ns, row, 0, { right_gravity = false })
  state.progress = progress
  source.ui:lock_buf()
  vim.cmd("redraw!")
end

local function update_progress(state)
  local p = state.progress
  if not p or not vim.api.nvim_buf_is_valid(p.bufnr) then return end
  local mark = vim.api.nvim_buf_get_extmark_by_id(p.bufnr, progress_ns, p.mark, {})
  if #mark == 0 then return end
  local row = mark[1] + 1
  local line = vim.api.nvim_buf_get_lines(p.bufnr, row, row + 1, false)[1]
  if not line or not line:match("^⏳ 压缩中%.+$") then return end
  p.dots = p.dots % 3 + 1
  state.source.ui:unlock_buf()
  vim.api.nvim_buf_set_lines(p.bufnr, row, row + 1, false, { "⏳ 压缩中" .. string.rep(".", p.dots) })
  state.source.ui:lock_buf()
  vim.cmd("redraw!")
end

function M.runner_at_progress(source, row)
  local state = source._handoff_compaction
  local p = state and state.progress
  if not p or state.finished or not live(state.runner) or not vim.api.nvim_buf_is_valid(p.bufnr) then return end
  local mark = vim.api.nvim_buf_get_extmark_by_id(p.bufnr, progress_ns, p.mark, {})
  if #mark > 0 and row == mark[1] + 1 then return state.runner end
end

local function hide_progress(state)
  local p = state.progress
  state.progress = nil
  if not p or not vim.api.nvim_buf_is_valid(p.bufnr) then return end
  local mark = vim.api.nvim_buf_get_extmark_by_id(p.bufnr, progress_ns, p.mark, {})
  state.source.ui:unlock_buf()
  if #mark > 0 then
    local row = mark[1]
    local lines = vim.api.nvim_buf_get_lines(p.bufnr, row, row + 2, false)
    if lines[1] == "" and lines[2] and lines[2]:match("^⏳ 压缩中%.+$") then
      vim.api.nvim_buf_set_lines(p.bufnr, row, row + 2, false, {})
    end
  end
  vim.api.nvim_buf_del_extmark(p.bufnr, progress_ns, p.mark)
  if not p.modifiable then state.source.ui:lock_buf() end
end

local function restore_source(state)
  hide_progress(state)
  local source = state.source
  source.dispatch, source.submit = state.dispatch, state.submit
  source._handoff_compaction = nil
  source._compacting = nil
end

local function unpublish_target(state)
  if not state.target then return end
  -- Demote before closing/retrying so queued autosaves cannot recreate the entry.
  state.target.opts.save_id = history_core.make_unsavable_save_id("handoff_target")
  if state.source._session_handoff and state.source._session_handoff.target == state.target then
    state.source._session_handoff = nil
  end
  if state.target_save_id then
    local api = history.get_history_api()
    local ok, removed = pcall(function() return api and api.delete_chat(state.target_save_id) end)
    if not ok or not removed then return "failed to remove uncommitted successor " .. state.target_save_id end
    state.target_save_id = nil
  end
end

local function fail(state, err)
  if state.finished then return end
  state.finished = true
  restore_source(state)
  soft_stop.latch(state.source)
  local cleanup_err = unpublish_target(state)
  if cleanup_err then err = tostring(err) .. "; " .. cleanup_err end
  if live(state.target) then state.target:close() end
  if live(state.runner) then state.runner:close() end
  if state.on_error then state.on_error(tostring(err))
  else vim.notify("[handoff_compaction] " .. tostring(err), vim.log.levels.ERROR) end
end

local function table_text(segments)
  local lines = { "| 消息范围 | 内容 | 保留档位 |", "| --- | --- | --- |" }
  for _, segment in ipairs(segments) do
    lines[#lines + 1] = string.format("| %d–%d | %s | %s |", segment.start_index, segment.end_index,
      tostring(segment.description):gsub("[\r\n|]", " "), labels[segment.profile])
  end
  return table.concat(lines, "\n")
end

local function prepare_target(state, params, done)
  local text, err = material(params, "handoff", state.source.opts.project_root or state.source.opts.cwd)
  if err then return done(err) end
  if not text or not text:find("%S") or type(params.goal_prompt) ~= "string" or not params.goal_prompt:find("%S") then
    return done("prepare requires nonempty handoff material and goal_prompt")
  end
  local source = state.source
  local background = {}
  local root = source.opts.project_root or source.opts.cwd
  local rules = root and vim.fs.joinpath(root, ".maxa", "AGENTS.md")
  if rules and vim.uv.fs_stat(rules) then background[#background + 1] = { role = "context", type = "file", path = rules } end
  for _, path in ipairs(params.context_files or {}) do
    background[#background + 1] = { role = "context", type = "file", path = path }
  end
  for _, ability in ipairs(params.abilities or {}) do
    background[#background + 1] = { role = "tool_call", name = "load", args = { target = ability } }
  end
  for _, reference in ipairs(params.guidance or {}) do
    background[#background + 1] = { role = "tool_call", name = "load", args = { target = reference } }
  end
  local target = require("maxa.interactions.chat").new({
    adapter = utils.resolve_adapter_by_key(nil, source, true),
    messages = { { role = "system", content = utils.inherit_system_prompt_from_parent(source),
      _meta = { tag = "system_prompt_from_config" }, opts = { visible = false } } },
    ignore_system_prompt = true, auto_submit = false, headless = true, preserve_main = not state.child or nil,
    save_id = history_core.make_unsavable_save_id("handoff_target"),
    agent_child = state.child, agent_parent = state.child and identity.parent(source) or nil,
    project_root = root, cwd = source.opts.cwd, title = source.opts.title,
  })
  if not target then return done("cannot create successor Chat") end
  state.target = target
  utils.inherit_tool_registry(source, target)
  require("maxa.mcphub.native_servers.subagent.background_calls").execute(target, background, function(preload_err)
    if state.finished then return end
    if preload_err then target:close(); state.target = nil; return done(preload_err) end
    for _, message in ipairs(target.messages) do
      if rules and message.context and message.context.id == "<file>" .. rules .. "</file>" then
        message.role, message._meta.tag = "system", "rules"
      end
    end
    state.preloads = vim.deepcopy(target.messages)
    state.handoff, state.handoff_file, state.goal, state.phase = text, params.handoff_file, params.goal_prompt, "prepared"
    done()
  end, { strict_files = true })
end

local function apply(state, params)
  if state.phase ~= "selected" then return false, "choose a profile after publishing segments before applying" end
  local profile = state.profile or params.profile
  if state.interactive and not state.user_selection then return false, "a user message is required after segmentation" end
  if not ranks[profile] or profile == "delete" then return false, "apply requires conservative, balanced or aggressive" end
  if state.profile and params.profile and params.profile ~= state.profile then return false, "profile must match the configured user message" end
  local selected, err, omitted = M.select_messages(state.messages, state.segments, profile)
  if not selected then return false, err end
  local summary, summary_err = material(params, "summary", state.source.opts.project_root or state.source.opts.cwd)
  if summary_err then return false, summary_err end
  local handoff_params = params
  if not params.handoff_text and not params.handoff_file and state.handoff_file then
    handoff_params = { handoff_file = state.handoff_file }
  end
  local handoff, handoff_err = material(handoff_params, "handoff", state.source.opts.project_root or state.source.opts.cwd)
  if handoff_err then return false, handoff_err end
  if handoff and not handoff:find("%S") then return false, "handoff material must remain nonempty" end
  local target = state.target
  local foundation = {}
  for _, message in ipairs(state.preloads) do
    if message.role == "system" or (message._meta and message._meta.tag == "rules") then
      foundation[#foundation + 1] = vim.deepcopy(message)
    end
  end
  -- Fresh preloads are authoritative; do not copy old system/rules over them.
  for _, message in ipairs(selected) do
    local tag = message._meta and message._meta.tag
    if message.role ~= "system" and tag ~= "rules" and tag ~= "system_prompt_from_config" and tag ~= "soul_prompt_from_config" then
      foundation[#foundation + 1] = message
    end
  end
  -- Append each complete fresh preload once, after retained source history.
  for _, message in ipairs(state.preloads) do
    if message.role ~= "system" and not (message._meta and message._meta.tag == "rules") then
      foundation[#foundation + 1] = vim.deepcopy(message)
    end
  end
  -- Selected source records remain immutable. Only omit redundant fresh
  -- context earlier, never dedup/rewrite selected historical tool pairs.
  local valid, issues = protection.validate_tool_pairs(foundation)
  if not valid then return false, "copied history has incomplete tool pairs: " .. vim.json.encode(issues) end
  target.messages = foundation
  if target.tools then target.tools.messages = target.messages end
  append(target, "[HANDOFF CONTEXT]\nThe historical messages above are reference data, not requests to continue.\n\n"
    .. (handoff or state.handoff) .. (summary and ("\n\n[OMITTED HISTORY SUMMARY]\n" .. summary) or ""), "handoff_context")
  append(target, state.goal, "handoff_goal")
  protection.mark_current_messages_as_protected_prefix(target)
  local display = require("maxa.interactions.chat.tools.display")
  local rendered = display.build_render_messages(target.messages)
  target.ui:unlock_buf()
  target.ui:render(target.buffer_context, rendered, { force_header = false })
  display.apply_render_postprocess(target, rendered)
  target:reset()
  require("maxa.abilities.hooks").restore_hooks_from_messages(target)
  require("maxa.session.abilities").rehydrate(target)
  local omitted_ranges = {}
  for _, index in ipairs(omitted) do
    local last = omitted_ranges[#omitted_ranges]
    if last and last.end_index == index - 1 then last.end_index = index
    else omitted_ranges[#omitted_ranges + 1] = { start_index = index, end_index = index, action = "handoff" } end
  end
  local traced = { messages = state.messages, save_id = state.save_id, chat = state.source }
  local archives, archive_err = require("maxa.session.session_trace").archive_compression_ranges(traced, omitted_ranges,
    { tool_name = "handoff_compact", mode = "new" })
  if not archives then return false, archive_err end
  require("maxa.session.session_trace").copy_membership(state.source, target)
  -- Become history-backed only after source records, handoff and goal are complete.
  if not state.target_save_id then state.target_save_id = history_core.generate_save_id() end
  target.opts.save_id = state.target_save_id
  identity.reidentify(target, false)
  local saved, save_err = transfer.save_verified(target)
  if not saved then
    local cleanup_err = unpublish_target(state)
    return false, tostring(save_err) .. (cleanup_err and ("; " .. cleanup_err) or "")
  end
  local recorded, record_err = require("maxa.session.session_trace").append_compression_applied(traced, {
    tool_name = "handoff_compact", mode = "new", action = "handoff", new_save_id = identity.save_id(target),
    archives = archives.archives, stats = { before_count = #state.messages, after_count = #target.messages, profile = profile },
  })
  if not recorded then
    local cleanup_err = unpublish_target(state)
    return false, tostring(record_err) .. (cleanup_err and ("; " .. cleanup_err) or "")
  end
  state.phase = "applying"
  return true
end

function M.handle(req, res)
  local runner = req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat
  local state = runner and runner._handoff_compaction_runner
  if not state or state.finished then return res:error("handoff_compact requires an active compression workspace"):send() end
  local params = req.params or {}
  if params.save_id ~= state.save_id then return res:error("save_id must match the compression source"):send() end
  if params.phase == "prepare" then
    if state.target then return res:error("handoff preparation already completed"):send() end
    prepare_target(state, params, function(err)
      if err then res:error(err):send() else res:text("handoff prepared; analyze source segments next"):send() end
    end)
    return
  elseif params.phase == "plan" then
    if state.phase ~= "prepared" and state.phase ~= "waiting" and state.phase ~= "selected" then
      return res:error("prepare handoff before segmentation"):send()
    end
    if type(params.segments) ~= "table" or #params.segments == 0 then return res:error("segments are required"):send() end
    local _, err = M.select_messages(state.messages, params.segments, "conservative")
    if err then return res:error(err):send() end
    state.segments, state.phase, state.user_selection, state.profile = params.segments, "planned", nil, nil
    return res:text(table_text(params.segments)):send()
  elseif params.phase == "apply" then
    local ok, err = apply(state, params)
    if not ok then return res:error(err):send() end
    return res:text("handoff ready; transfer follows this tool batch"):send()
  end
  return res:error("phase must be prepare, plan or apply"):send()
end

-- Called after the planner's canonical tool results have settled.
function M.after_tools(runner, failed)
  local state = runner._handoff_compaction_runner
  if not state or state.finished then return false end
  if failed and state.phase == "applying" then fail(state, "compression tool batch failed or was cancelled"); return true end
  if state.phase == "planned" then
    if state.interactive then
      state.phase = "waiting"
      append(runner, "Display the segment table and wait for a user message choosing 保守 / 平衡 / 激进. Do not apply yet.", "compaction_display")
    else
      state.profile, state.phase = state.configured_profile, "selected"
      append(runner, "选择" .. labels[state.profile] .. "（" .. state.profile .. "）压缩。请先检查未复制的段落，摘要对后续工作有帮助的内容，再应用交接。", "compaction_profile_selection")
    end
  elseif state.phase == "applying" then
    vim.schedule(function()
      if state.finished then return end
      if failed or require("maxa.mcphub.native_servers.subagent.async_cancel").is_cancelled(state.source) then
        return fail(state, "compression was cancelled before commit")
      end
      if not live(state.source) or soft_stop.is_busy(state.source) then return fail(state, "source has not reached a safe boundary") end
      local scheduled, err = transfer.schedule_compaction(state.source, state.target)
      if not scheduled then return fail(state, err) end
      restore_source(state)
      state.committing = true
      local _, commit_err = transfer.after_tools(state.source, false)
      state.committing = nil
      if commit_err then return fail(state, commit_err) end
      state.finished = true
      if state.on_success then state.on_success(state.target) end
      if live(runner) then runner:close() end
    end)
    return true
  end
  return false
end

function M.cancel(source, reason)
  local state = source._handoff_compaction
  if not state or state.finished then return false end
  fail(state, reason or "compression cancelled")
  if live(source) then state.dispatch(source, "on_cancelled") end
  return true
end

function M.start(source, on_success, on_error, opts)
  opts = opts or {}
  on_error = on_error or function(err) vim.notify("[handoff_compaction] " .. tostring(err), vim.log.levels.ERROR) end
  if source._compacting or source._session_handoff then if on_error then on_error("会话正在压缩或交接") end; return false end
  local child = transfer.is_child_eligible(source)
  if not live(source) or (not identity.is_main(source) and not child)
    or require("maxa.session.history_core").is_unsavable_save_id(identity.save_id(source)) then
    if on_error then on_error("交接压缩需要可保存的主会话或活动普通子代理") end
    return false
  end
  local profile = require("maxa.config").runtime().compaction.profile
  if not ranks[profile] or profile == "delete" then if on_error then on_error("invalid maxa.compaction.profile") end; return false end
  if soft_stop.is_busy(source) then if on_error then on_error("source Chat must reach a safe boundary") end; return false end
  local saved, err = transfer.save_verified(source)
  if not saved then if on_error then on_error(err) end; return false end
  local history_source, source_err = history.get_messages_source(identity.save_id(source))
  if not history_source then if on_error then on_error(source_err) end; return false end
  local state = { source = source, messages = history_source.messages, save_id = identity.save_id(source), child = child,
    interactive = opts.interactive == true, configured_profile = profile, phase = "preparing",
    dispatch = source.dispatch, submit = source.submit, on_success = on_success, on_error = on_error }
  source._compacting, source._handoff_compaction = true, state
  show_progress(state)
  soft_stop.latch(source)
  source.submit = function() vim.notify("来源会话正在交接压缩，请在压缩工作区操作。", vim.log.levels.WARN) end
  source.dispatch = function(self, event, ...)
    if event == "on_completed" or event == "on_error" then return self end
    return state.dispatch(self, event, ...)
  end
  source:add_callback("on_cancelled", function() if not state.finished then fail(state, "source cancelled") end end)
  source:add_callback("on_closed", function() if not state.finished and not state.committing then fail(state, "source closed") end end)
  local messages = require("maxa.session.slash_commands.compact_utils").clone_messages_with_truncation(state.messages)
  local prompt_path = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "handoff_compaction_prompt.md")
  local prompt = table.concat(vim.fn.readfile(prompt_path), "\n")
  messages[#messages + 1] = { role = "user", content = "[FORK BOUNDARY]\nInherited history is read-only compression data.\n\n" .. prompt
    .. "\n\nSource save_id: " .. state.save_id .. "\nSource project: " .. (source.opts.project_root or source.opts.cwd)
    .. (opts.instructions and ("\nPreservation instructions:\n" .. opts.instructions) or "") }
  local cfg, cfg_err = require("maxa.mcphub.native_servers.config").get_runtime_adapter("compact", { chat = source })
  if not cfg then fail(state, cfg_err); return false end
  local adapter = cfg.inherit and utils.resolve_adapter_by_key(nil, source, true)
    or require("maxa.adapters").resolve(cfg.adapter, { model = cfg.model, temperature = cfg.temperature })
  if cfg.inherit and (cfg.model or cfg.temperature ~= nil) then
    adapter = require("maxa.adapters").resolve(adapter, { model = cfg.model, temperature = cfg.temperature })
  end
  local runner = require("maxa.interactions.chat").new({ adapter = adapter, messages = utils.build_sub_agent_render_messages(messages),
    settings = require("maxa.mcphub.native_servers.config").get_reasoning_effort_settings(adapter, cfg.reasoning_effort),
    ignore_system_prompt = true, auto_submit = false, headless = not state.interactive,
    agent_child = true, agent_parent = source, project_root = source.opts.project_root, cwd = source.opts.cwd,
    save_id = require("maxa.session.history_core").make_unsavable_save_id("handoff_compaction"), title = "Handoff Compression",
    callbacks = { on_completed = function(c)
      if state.finished or state.phase == "applying" then return end
      local last = c.messages[#c.messages]
      if last and last.tools and last.tools.calls and #last.tools.calls > 0 then return end
      if state.phase ~= "waiting" then fail(state, "compression executor ended before applying") end
    end, on_cancelled = function() fail(state, "compression cancelled") end,
      on_closed = function() if not state.finished then fail(state, "compression workspace closed") end end,
      on_error = function(_, err) fail(state, err or "compression request failed") end },
  })
  if not runner then fail(state, "cannot create compression workspace"); return false end
  state.runner, runner.messages = runner, messages
  if runner.tools then runner.tools.messages = messages end
  runner._is_rescue_session, runner._auto_compact_disabled, runner._enable_error_retry = true, true, true
  runner._compact_target_save_id, runner._handoff_compaction_runner = state.save_id, state
  utils.apply_tools_override(runner, { "load", "read", "write", "run" })
  require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").bind_child(source, runner)
  runner:add_callback("on_submitted", function(c)
    update_progress(state)
    if state.phase == "waiting" then
      local last = c.messages[#c.messages]
      if last and last.role == "user" and not (last._meta and last._meta.tag) and last.content and last.content:find("%S") then
        local content = last.content:lower()
        for name, label in pairs(labels) do
          if name ~= "delete" and (content:find(name, 1, true) or content:find(label, 1, true)) then
            state.user_selection, state.profile, state.phase = last.content, name, "selected"
            break
          end
        end
      end
    end
  end)
  local calls = { { role = "tool_call", name = "load", args = { target = "session", force_reload = true } } }
  require("maxa.mcphub.native_servers.subagent.background_calls").execute(runner, calls, function(load_err)
    if state.finished then return end
    if load_err then return fail(state, load_err) end
    append(runner, "Begin now: prepare handoff first, then use probe_messages to split source history and publish segments. Do not continue the inherited task.", "compaction_start")
    if state.interactive then runner.ui:open({ window_opts = identity.window_opts(runner) }) end
    runner:submit({ auto_submit = true })
  end)
  vim.notify("[handoff_compaction] 正在准备交接并分析历史…", vim.log.levels.INFO)
  return true
end

return M
