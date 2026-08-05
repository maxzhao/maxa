-- filepath: lua/maxa/runtime/tools/task.lua
--- Phase-3 W2: async task layer + TTL(result) lifecycle.
---
--- Scope: executor-owned async tasks (tools/init.lua `_make_task`) and the
--- auxiliary-result retention policy (tool-runtime spec §Async and retained
--- results, §Result and UI separation). Task identity:
---   { id, owner = { session_id, request_id, batch_id }, generation }
--- where `generation` is the owning request's generation (async-lifecycle
--- spec: callbacks MUST check generation/request identity before mutating
--- state).
---
--- Task contract:
---   * complete(value[, caller])  -> CAS: the first terminal outcome wins; a
---     late/duplicate completion is ignored with a recorded diagnostic
---     ({ op, reason, detail, at_ms }, bounded). `caller` is an optional
---     identity { session_id, request_id, generation [, batch_id] }; when
---     provided, owner validation (session + request + task generation double
---     check) rejects mismatches BEFORE any mutation.
---   * cancel(reason[, caller])   -> CAS running -> cancelled (+ diagnostics).
---   * poll([caller])             -> non-mutating snapshot (owner-gated).
---   * is_cancelled([caller])     -> boolean (owner-gated).
---   * retain(action, opts) / expire(opts) -> TTL on the terminal task result.
---
--- TTL contract (tool-runtime §Async and retained results / §Result and UI
--- separation):
---   * discard/defer(rounds)/keep/persist change ONLY the auxiliary result
---     payload retention metadata / content ownership: discard removes the
---     auxiliary payload (result.aux); defer/keep/persist only rewrite the
---     retention record. The provider-facing result content and the durable
---     trace (persisted tool messages) are NEVER touched.
---   * Metadata records: action, owner, set_at_ms, source, deadline_ms,
---     rounds/deadline_round (defer), persistent (persist), removed (discard),
---     expired/expired_at_ms (expire).
---   * defer maps the declared availability rounds to a deadline through
---     M.TTL_ROUND_MS (documented wall-time approximation), or uses
---     opts.deadline_ms / opts.round (round counter) when provided.
---   * The compact display summary may expire independently; provider pairing
---     and history retention data are out of TTL scope.
---
--- It never loads codecompanion.* / mcphub.* / lua/util/hooks/*.

local M = {}

M.name = "tools.task"

--- Async task lifecycle states (async-lifecycle spec terminal set).
M.TASK_STATES = {
  running = "running",
  succeeded = "succeeded",
  failed = "failed",
  cancelled = "cancelled",
}

M.TERMINAL_STATES = {
  [M.TASK_STATES.succeeded] = true,
  [M.TASK_STATES.failed] = true,
  [M.TASK_STATES.cancelled] = true,
}

--- TTL retention actions (tool-runtime §Async and retained results).
M.TTL_ACTIONS = {
  discard = "discard",
  defer = "defer",
  keep = "keep",
  persist = "persist",
}

--- Estimated wall time (ms) of one availability round. Used ONLY to derive a
--- deadline for `defer` when no round counter (opts.round) or explicit
--- deadline (opts.deadline_ms) is provided; consumers with a real round
--- counter should pass opts.round so availability is tracked in rounds.
M.TTL_ROUND_MS = 60000

--- Maximum recorded diagnostics per task (bounded memory; overflow drops the
--- oldest entry and sets the `diagnostics_truncated` flag).
M.DIAG_CAP = 16

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

--- Current wall clock (ms) through the deterministic clock seam.
---@param task table task record (task.clock may provide now_ms)
---@return integer
local function now_ms(task)
  if task and task.clock and type(task.clock.now_ms) == "function" then
    return task.clock.now_ms()
  end
  if vim.uv and vim.uv.hrtime then
    return math.floor(vim.uv.hrtime() / 1e6)
  end
  return os.time() * 1000
end

--- Shallow-copy a table (nil-safe).
---@param t table
---@return table
local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

--- Default result normalization (shared contract with the executor's
--- normalize_result: string -> success; { error=true|status="error" } ->
--- error; anything else stringified as success).
---@param value any raw handler completion value
---@return table { status="success"|"error", content=string }
function M.normalize(value)
  if type(value) == "string" then
    return { status = "success", content = value }
  end
  if type(value) == "table" then
    local is_err = value.error == true or value.status == "error"
    return {
      status = is_err and "error" or "success",
      content = tostring(value.content or ""),
    }
  end
  return { status = "success", content = tostring(value or "") }
end

--- Record a bounded diagnostic on a task (late/ignored/rejected operations).
---@param task table task record
---@param op string operation ("complete"|"cancel"|"poll"|"is_cancelled")
---@param reason string stable reason ("late_completion"|"late_cancel"|"owner_mismatch"|"resolve_failed")
---@param detail table|nil extra context
---@param at_ms integer|nil timestamp override
function M._record_diagnostic(task, op, reason, detail, at_ms)
  local d = task.diagnostics
  if #d >= M.DIAG_CAP then
    table.remove(d, 1)
    task._diagnostics_truncated = true
  end
  d[#d + 1] = {
    op = op,
    reason = reason,
    detail = vim.tbl_extend("force", {}, detail or {}),
    at_ms = at_ms or now_ms(task),
  }
end

--- Validate a caller identity against the task owner (session + request +
--- task generation double check; batch_id checked when both sides provide it).
--- A nil caller (internal executor/handler path) always passes: identity
--- validation only applies when the caller declares one.
---@param task table task record
---@param caller table|nil { session_id?, request_id?, generation?, batch_id? }
---@return boolean ok
---@return table|nil err { code="owner_mismatch", cause={ field, expected, got } }
function M.check_owner(task, caller)
  if caller == nil then
    return true
  end
  if type(caller) ~= "table" then
    return false,
      {
        code = "owner_mismatch",
        message = "caller identity must be a table",
        cause = { field = "caller" },
      }
  end
  local owner = task.owner or {}
  local checks = {
    { field = "session_id", want = owner.session_id, got = caller.session_id },
    { field = "request_id", want = owner.request_id, got = caller.request_id },
    { field = "generation", want = task.generation, got = caller.generation },
    { field = "batch_id", want = owner.batch_id, got = caller.batch_id },
  }
  for _, c in ipairs(checks) do
    if c.got ~= nil then
      -- generation/batch_id without a task-side value cannot be verified;
      -- session/request without a task-side value is an identity defect.
      if c.want ~= nil and c.got ~= c.want then
        return false,
          {
            code = "owner_mismatch",
            message = ("owner mismatch at %s (expected %s, got %s)"):format(c.field, tostring(c.want), tostring(c.got)),
            cause = { field = c.field, expected = c.want, got = c.got },
          }
      end
    end
  end
  return true
end

--- CAS terminal transition (runtime-internal; also used by the executor to
--- sync task state from non-task completion paths, e.g. timeout boundaries).
--- The first terminal outcome wins; a second transition is ignored with a
--- late_completion diagnostic.
---@param task table task record
---@param status string "success"|"error"|"cancelled"
---@param result table normalized result { status, content, is_error? }
---@param op string|nil diagnostic op ("complete"|"cancel")
---@param at_ms integer|nil timestamp override
---@return boolean ok
---@return table|nil err when the transition was rejected
function M._set_terminal(task, status, result, op, at_ms)
  if task.state ~= M.TASK_STATES.running then
    M._record_diagnostic(task, op or "complete", "late_completion", { state = task.state }, at_ms)
    return false,
      {
        code = "task_not_running",
        message = "terminal transition rejected: task not running",
        cause = { state = task.state },
      }
  end
  local st = status == "cancelled" and M.TASK_STATES.cancelled
    or (status == "error" and M.TASK_STATES.failed or M.TASK_STATES.succeeded)
  local ts = at_ms or now_ms(task)
  task.state = st
  task.completed_at = ts
  local r = vim.tbl_extend("force", {}, result or {})
  r.status = status == "cancelled" and "error" or status
  r.is_error = (status == "error" or status == "cancelled") or (result and result.is_error == true)
  r.state = st
  r.retention = r.retention
    or M.retention_meta(M.TTL_ACTIONS.keep, {
      owner = task.owner,
      set_at_ms = ts,
      source = "default",
    })
  task.result = r
  return true
end

--- Resolve a raw completion value through the task's resolve hook (default:
--- M.normalize). A throwing resolve hook is isolated: the task still reaches a
--- terminal error result and the failure is recorded as a diagnostic.
---@param task table task record
---@param value any
---@return table result
local function resolve_value(task, value)
  local okr, norm = pcall(task.resolve or M.normalize, value)
  if not okr then
    M._record_diagnostic(task, "complete", "resolve_failed", { error = tostring(norm) })
    return { status = "error", content = "handler returned an invalid result", is_error = true }
  end
  return norm
end

-------------------------------------------------------------------------------
-- Task creation and lifecycle
-------------------------------------------------------------------------------

--- Complete a task (CAS + optional owner validation). Returns true only for
--- the first terminal outcome; late/owner-rejected completions return false
--- and record a diagnostic.
---@param task table task record
---@param value any completion value (string | { content=... } | ...)
---@param caller table|nil owner identity to validate against
---@return boolean accepted
---@return table|nil result normalized terminal result
---@return table|nil err rejection reason (code="owner_mismatch"|"task_not_running")
function M.complete(task, value, caller)
  local ok, oerr = M.check_owner(task, caller)
  if not ok then
    M._record_diagnostic(task, "complete", "owner_mismatch", oerr)
    return false, nil, oerr
  end
  if task.state ~= M.TASK_STATES.running then
    local detail = { state = task.state }
    M._record_diagnostic(task, "complete", "late_completion", detail)
    return false,
      nil,
      {
        code = "task_not_running",
        message = "late completion ignored",
        cause = detail,
      }
  end
  local norm = resolve_value(task, value)
  local trans, terr = M._set_terminal(task, norm.status, norm, "complete")
  if not trans then
    return false, nil, terr
  end
  return true, task.result
end

--- Cancel a task (CAS + optional owner validation).
---@param task table task record
---@param reason string|nil diagnostic reason
---@param caller table|nil owner identity to validate against
---@return boolean cancelled
---@return table|nil err rejection reason
function M.cancel(task, reason, caller)
  local ok, oerr = M.check_owner(task, caller)
  if not ok then
    M._record_diagnostic(task, "cancel", "owner_mismatch", oerr)
    return false, oerr
  end
  if task.state ~= M.TASK_STATES.running then
    local detail = { state = task.state }
    M._record_diagnostic(task, "cancel", "late_cancel", detail)
    return false, {
      code = "task_not_running",
      message = "late cancel ignored",
      cause = detail,
    }
  end
  return M._set_terminal(
    task,
    "cancelled",
    { status = "error", content = reason or "cancelled", is_error = true },
    "cancel"
  )
end

--- Non-mutating snapshot of a task (owner-gated; no mutation).
---@param task table task record
---@param caller table|nil owner identity to validate against
---@return table|nil snapshot
---@return table|nil err owner mismatch
function M.poll(task, caller)
  local ok, oerr = M.check_owner(task, caller)
  if not ok then
    M._record_diagnostic(task, "poll", "owner_mismatch", oerr)
    return nil, oerr
  end
  return M.snapshot(task)
end

---@param task table task record
---@param caller table|nil owner identity to validate against
---@return boolean cancelled
---@return table|nil err owner mismatch
function M.is_cancelled(task, caller)
  local ok, oerr = M.check_owner(task, caller)
  if not ok then
    M._record_diagnostic(task, "is_cancelled", "owner_mismatch", oerr)
    return false, oerr
  end
  return task.state == M.TASK_STATES.cancelled
end

--- Create an async task identity.
---@param opts table {
---   id?: string (default "task:<batch_id>:<n>"),
---   owner: table { session_id, request_id, batch_id },
---   generation?: integer|nil owning request generation,
---   clock?: table|nil { now_ms } deterministic clock seam,
---   resolve?: fun(value): table|nil completion-value normalizer,
--- }
---@return table task (state/result/diagnostics readable; methods below)
function M.create(opts)
  opts = opts or {}
  local task = {
    id = opts.id or ("task:" .. tostring(opts.owner and opts.owner.batch_id or "anon")),
    owner = copy(opts.owner or {}),
    generation = opts.generation,
    clock = opts.clock,
    resolve = opts.resolve,
    state = M.TASK_STATES.running,
    result = nil,
    diagnostics = {},
    _diagnostics_truncated = false,
    created_at = now_ms(opts),
    completed_at = nil,
  }

  --- Complete the task (delegates to M.complete: CAS + optional owner
  --- validation; late/owner-rejected completions return false + diagnostic).
  ---@param value any completion value (string | { content=... } | ...)
  ---@param caller table|nil owner identity to validate against
  ---@return boolean accepted
  ---@return table|nil result normalized terminal result
  ---@return table|nil err rejection reason
  function task.complete(value, caller)
    return M.complete(task, value, caller)
  end

  --- Cancel the task (delegates to M.cancel: CAS + optional owner validation).
  ---@param reason string|nil diagnostic reason
  ---@param caller table|nil owner identity to validate against
  ---@return boolean cancelled
  ---@return table|nil err rejection reason
  function task.cancel(reason, caller)
    return M.cancel(task, reason, caller)
  end

  --- Non-mutating snapshot (owner-gated).
  ---@param caller table|nil owner identity to validate against
  ---@return table|nil snapshot { id, owner, generation, state, is_terminal,
  ---   result, diagnostics, diagnostics_truncated, created_at, completed_at }
  ---@return table|nil err owner mismatch
  function task.poll(caller)
    return M.poll(task, caller)
  end

  ---@param caller table|nil owner identity to validate against
  ---@return boolean cancelled
  ---@return table|nil err owner mismatch
  function task.is_cancelled(caller)
    return M.is_cancelled(task, caller)
  end

  --- TTL convenience on the terminal task result (delegates to M.retain with
  --- the task owner; requires a terminal result).
  ---@param action string TTL action
  ---@param opts table|nil retain options
  ---@return table|nil result
  ---@return table|nil err
  function task.retain(action, opts)
    opts = vim.tbl_extend("force", {}, opts or {})
    opts.owner = opts.owner or task.owner
    return M.retain(task.result, action, opts)
  end

  --- TTL convenience: mark the terminal task result's auxiliary payload
  --- expired (metadata only; provider-facing content untouched).
  ---@param opts table|nil { at_ms?, owner? }
  ---@return table|nil result
  ---@return table|nil err
  function task.expire(opts)
    opts = vim.tbl_extend("force", {}, opts or {})
    opts.owner = opts.owner or task.owner
    return M.expire(task.result, opts)
  end

  return task
end

---@param task table task record
---@return boolean true when the task reached a terminal state
function M.is_terminal(task)
  return M.TERMINAL_STATES[task.state] ~= nil
end

--- Non-mutating snapshot of a task (no owner gate; use M.poll for gated reads).
---@param task table task record
---@return table snapshot
function M.snapshot(task)
  return {
    id = task.id,
    owner = copy(task.owner),
    generation = task.generation,
    state = task.state,
    is_terminal = M.is_terminal(task),
    result = task.result and copy(task.result) or nil,
    diagnostics = vim.deepcopy(task.diagnostics),
    diagnostics_truncated = task._diagnostics_truncated == true,
    created_at = task.created_at,
    completed_at = task.completed_at,
  }
end

-------------------------------------------------------------------------------
-- TTL(result) lifecycle
-------------------------------------------------------------------------------

--- Compare a caller owner against the recorded retention owner.
---@param meta_owner table retention.owner
---@param caller_owner table caller-provided owner
---@return table|nil err
local function owner_mismatch(meta_owner, caller_owner)
  for _, field in ipairs({ "session_id", "request_id", "batch_id" }) do
    if caller_owner[field] ~= nil and caller_owner[field] ~= meta_owner[field] then
      return {
        code = "owner_mismatch",
        message = ("retention owner mismatch at %s"):format(field),
        cause = { field = field, expected = meta_owner[field], got = caller_owner[field] },
      }
    end
  end
  return nil
end

--- Build a fresh retention metadata record.
---@param action string TTL action
---@param opts table|nil { owner?, set_at_ms?, clock?, rounds?, source? }
---@return table meta
function M.retention_meta(action, opts)
  opts = opts or {}
  local ts = opts.set_at_ms or now_ms(opts)
  local meta = {
    action = M.TTL_ACTIONS[action] and action or M.TTL_ACTIONS.keep,
    owner = opts.owner and copy(opts.owner) or nil,
    set_at_ms = ts,
    source = opts.source or "explicit",
    deadline_ms = nil,
    rounds = nil,
    deadline_round = nil,
    persistent = false,
    removed = false,
    expired = false,
    expired_at_ms = nil,
  }
  if meta.action == M.TTL_ACTIONS.discard then
    meta.removed = true
    meta.deadline_ms = ts
  elseif meta.action == M.TTL_ACTIONS.defer then
    meta.rounds = opts.rounds or 1
    meta.deadline_ms = ts + meta.rounds * M.TTL_ROUND_MS
  elseif meta.action == M.TTL_ACTIONS.persist then
    meta.persistent = true
  end
  return meta
end

--- Apply a TTL action to a result's auxiliary payload policy. Only retention
--- metadata / auxiliary content ownership change: the provider-facing
--- `content` (and the durable trace it was persisted into) is never touched.
---@param result table result record (call.result / task.result)
---@param action string "discard"|"defer"|"keep"|"persist"
---@param opts table|nil {
---   owner?: table owner identity (first attach records it; later mismatches reject),
---   rounds?: integer defer rounds (positive integer required for defer),
---   round?: integer|nil current round counter (defer deadline_round),
---   deadline_ms?: integer|nil explicit defer deadline,
---   at_ms?: integer|nil policy timestamp,
---   clock?: table|nil { now_ms } deterministic clock seam,
--- }
---@return table|nil result (unchanged reference on success)
---@return table|nil err { code="invalid_target"|"invalid_action"|"invalid_rounds"|"owner_mismatch" }
function M.retain(result, action, opts)
  opts = opts or {}
  if type(result) ~= "table" then
    return nil, { code = "invalid_target", message = "retain requires a result table" }
  end
  if type(action) ~= "string" or not M.TTL_ACTIONS[action] then
    return nil,
      {
        code = "invalid_action",
        message = ("retain action must be one of discard|defer|keep|persist (got %s)"):format(tostring(action)),
      }
  end
  local meta = result.retention or {}
  if opts.owner ~= nil then
    if meta.owner ~= nil then
      local oerr = owner_mismatch(meta.owner, opts.owner)
      if oerr then
        return nil, oerr
      end
    else
      meta.owner = copy(opts.owner)
    end
  end
  -- Validate action-specific inputs before any mutation (failed retain leaves
  -- the existing policy untouched).
  local rounds = nil
  if action == M.TTL_ACTIONS.defer then
    rounds = opts.rounds
    if type(rounds) ~= "number" or rounds <= 0 or rounds % 1 ~= 0 then
      return nil,
        {
          code = "invalid_rounds",
          message = "defer requires a positive integer rounds value",
        }
    end
  end
  local ts = opts.at_ms or now_ms(opts)
  meta.action = action
  meta.set_at_ms = ts
  meta.source = "explicit"
  meta.persistent = false
  meta.removed = false
  meta.expired = false
  meta.expired_at_ms = nil
  if action == M.TTL_ACTIONS.discard then
    meta.removed = true
    meta.deadline_ms = ts -- availability ended immediately
    meta.rounds = nil
    meta.deadline_round = nil
    result.aux = nil -- auxiliary payload removed; provider-facing content untouched
  elseif action == M.TTL_ACTIONS.defer then
    meta.rounds = rounds
    meta.deadline_ms = opts.deadline_ms or (ts + rounds * M.TTL_ROUND_MS)
    meta.deadline_round = (opts.round ~= nil) and (opts.round + rounds) or nil
  elseif action == M.TTL_ACTIONS.keep then
    meta.rounds = nil
    meta.deadline_ms = nil
    meta.deadline_round = nil
  else -- persist
    meta.persistent = true
    meta.rounds = nil
    meta.deadline_ms = nil
    meta.deadline_round = nil
  end
  result.retention = meta
  return result
end

--- Mark a result's auxiliary payload availability as expired (metadata only:
--- expired=true + expired_at_ms; the auxiliary payload remains until a
--- discard removes it). Provider-facing content is never touched.
---@param result table result record
---@param opts table|nil { at_ms?, owner?, clock? }
---@return table|nil result
---@return table|nil err { code="invalid_target"|"owner_mismatch" }
function M.expire(result, opts)
  opts = opts or {}
  if type(result) ~= "table" then
    return nil, { code = "invalid_target", message = "expire requires a result table" }
  end
  local meta = result.retention
  if not meta then
    meta = M.retention_meta(M.TTL_ACTIONS.keep, {
      owner = opts.owner,
      set_at_ms = opts.at_ms or now_ms(opts),
      source = "explicit",
    })
    result.retention = meta
  end
  if opts.owner ~= nil and meta.owner ~= nil then
    local oerr = owner_mismatch(meta.owner, opts.owner)
    if oerr then
      return nil, oerr
    end
  elseif opts.owner ~= nil then
    meta.owner = copy(opts.owner)
  end
  meta.expired = true
  meta.expired_at_ms = opts.at_ms or now_ms(opts)
  return result
end

return M
