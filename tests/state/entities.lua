-- filepath: tests/state/entities.lua
--- Phase-2 W1 headless validation: session four-entity model + legal transition
--- reducer (session/init.lua).
---
--- Scenarios:
---   A. four-entity construction + full state-set values (+ idle==ready alias)
---   B. main chain: created->ready->busy (accept_submit), request
---      submitted->starting->streaming->tool_pending, batch
---      pending->running->draining->completed, request terminal -> session
---      waiting_for_user; snapshot + transition history
---   C. illegal transitions: typed INVALID_ARGUMENT + diagnostic event
---      (session.transition_rejected) + no partial mutation
---   D. terminal idempotency: first terminal CAS wins, later calls no-op
---   E. superseded request terminal: marked on the record, session untouched
---   F. stop/close: active request+batch cancelled, idempotent, no submit after
---   G. view transitions: hide/show/detach/close, illegal move rejected
---   H. continue (busy->busy) reducer row; tool-batch requires active request
---   I. import-guard: no legacy families loaded
---
--- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
---   local d='<root>/tests/state/entities.lua' local ok=pcall(dofile,d)
---   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
--- Exit 0 on success; 1 (cq) on any failed assertion.

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("STATE_FAIL: " .. msg)
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end

local session_mod = require("maxa.runtime.session")
local events = require("maxa.runtime.events")
local schema = require("maxa.runtime.schema")

-------------------------------------------------------------------------------
-- A. Entity construction + state-set values
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local s = session_mod.new({ session_id = "s-test", project_id = "p-test", events = bus })
  assert_eq(s.id, "s-test", "A: session id")
  assert_eq(s.project_id, "p-test", "A: project_id")
  assert_eq(s.generation, 0, "A: initial generation")
  assert_eq(s.state, session_mod.states.ready, "A: session created->ready at construction")
  check(s.active_request_id == nil, "A: no active request")
  check(s.active_tool_batch_id == nil, "A: no active tool batch")
  check(type(s.loop) == "table", "A: loop container present")
  check(type(s.views) == "table" and #s.views == 0, "A: views list present")
  check(session_mod.create == session_mod.new, "A: create alias")

  local want_session = { "created", "ready", "busy", "waiting_for_user", "completed", "failed", "stopped", "closed" }
  for _, st in ipairs(want_session) do
    check(session_mod.states[st] == st, "A: session state value " .. st)
  end
  assert_eq(session_mod.states.idle, session_mod.states.ready, "A: idle compat alias == ready")

  local want_request = { "submitted", "starting", "streaming", "tool_pending", "completed", "failed", "cancelled" }
  for _, st in ipairs(want_request) do
    check(session_mod.request_states[st] == st, "A: request state value " .. st)
  end
  local want_batch = { "pending", "running", "draining", "completed", "failed", "cancelled" }
  for _, st in ipairs(want_batch) do
    check(session_mod.tool_batch_states[st] == st, "A: batch state value " .. st)
  end
  local want_view = { "attached", "hidden", "detached", "closed" }
  for _, st in ipairs(want_view) do
    check(session_mod.view_states[st] == st, "A: view state value " .. st)
  end
  assert_eq(session_mod.TERMINAL_STATES.completed, true, "A: request terminal set")
  assert_eq(session_mod.TERMINAL_STATES.cancelled, true, "A: request terminal set (cancelled)")
  assert_eq(session_mod.TERMINAL_BATCH_STATES.completed, true, "A: batch terminal set")

  check(type(session_mod.Session) == "table", "A: Session class exported")
  check(type(session_mod.Request) == "table", "A: Request class exported")
  check(type(session_mod.ToolBatch) == "table", "A: ToolBatch class exported")
  check(type(session_mod.View) == "table", "A: View class exported")
  check(type(session_mod.transition) == "function", "A: reducer exported")
  check(
    session_mod.TRANSITIONS.session.ready ~= nil and session_mod.TRANSITIONS.request.terminal ~= nil,
    "A: transition rules present"
  )
end

-------------------------------------------------------------------------------
-- B. Main chain through the reducer + snapshot + history
-------------------------------------------------------------------------------
do
  local s = session_mod.new({ session_id = "s-chain" })
  local req, err = s:start_request({ request_id = "req-1", intent = "manual" })
  check(req ~= nil and err == nil, "B: start_request ok")
  check(s:is_busy() and not s:is_idle(), "B: busy after submit")
  assert_eq(s.state, session_mod.states.busy, "B: session busy")
  assert_eq(req.state, session_mod.request_states.submitted, "B: request submitted")
  assert_eq(req.generation, 1, "B: request generation")
  assert_eq(req.turn_id, "req-1", "B: turn_id defaults to request id")
  assert_eq(req.session_id, "s-chain", "B: request session_id")
  assert_eq(req.intent, "manual", "B: request intent")

  -- request progression submitted -> starting -> streaming -> tool_pending
  local ok1, r1 = session_mod.transition(req, "start", { session = s })
  check(ok1 == true and r1.changed == true, "B: request start")
  assert_eq(req.state, "starting", "B: request starting")
  local ok2, r2 = session_mod.transition(req, "stream", { session = s })
  check(ok2 == true and r2.changed == true, "B: request stream")
  assert_eq(req.state, "streaming", "B: request streaming")
  local ok3, r3 = session_mod.transition(req, "tool_pending", { session = s })
  check(ok3 == true and r3.changed == true, "B: request tool_pending")
  assert_eq(req.state, "tool_pending", "B: request tool_pending state")

  -- tool batch pending -> running -> draining -> completed
  local batch, berr = s:new_tool_batch({ batch_id = "batch-1", calls = { { call_id = "c1" } } })
  check(batch ~= nil and berr == nil, "B: new_tool_batch ok")
  assert_eq(s.active_tool_batch_id, "batch-1", "B: active batch id")
  assert_eq(batch.request_id, "req-1", "B: batch request_id")
  assert_eq(batch.ordinal, 1, "B: batch ordinal")
  assert_eq(#batch.calls, 1, "B: batch calls carried")
  local b1, br1 = session_mod.transition(batch, "run", { session = s })
  local b2, br2 = session_mod.transition(batch, "drain", { session = s })
  local b3, br3 = session_mod.transition(batch, "terminal", { session = s, to = "completed" })
  check(b1 == true and br1.changed == true, "B: batch run")
  check(b2 == true and br2.changed == true, "B: batch drain")
  check(b3 == true and br3.changed == true, "B: batch terminal completed")
  assert_eq(batch.state, "completed", "B: batch completed")
  check(s.active_tool_batch_id == nil, "B: active batch cleared after terminal")

  -- request terminal -> session busy -> waiting_for_user
  local fok, ferr = s:finish_request(req, "completed")
  check(fok == true and ferr == nil, "B: finish_request completed")
  assert_eq(s.state, session_mod.states.waiting_for_user, "B: session waiting_for_user")
  check(s:is_idle() and not s:is_busy(), "B: idle accepts next submit")
  assert_eq(req.state, "completed", "B: request completed")
  check(req.terminal ~= nil and req.terminal.state == "completed" and not req.terminal.superseded, "B: terminal record")
  check(s.active_request_id == nil, "B: active request cleared")

  -- snapshot: phase-0 fields + W1 additive fields
  local snap = s:snapshot()
  assert_eq(snap.id, "s-chain", "B: snapshot id")
  assert_eq(snap.project_id, "local", "B: snapshot project_id")
  assert_eq(snap.state, session_mod.states.waiting_for_user, "B: snapshot state")
  assert_eq(snap.generation, 1, "B: snapshot generation")
  check(snap.active_request_id == nil and snap.active_tool_batch_id == nil, "B: snapshot active nil")
  check(type(snap.loop) == "table" and type(snap.views) == "table", "B: snapshot loop/views")

  -- history: one request terminal record + one session wait_for_user record
  local h = s:transition_history()
  local term_records = 0
  local wfu_records = 0
  for _, rec in ipairs(h) do
    if rec.entity == "request" and rec.action == "terminal" then
      term_records = term_records + 1
    end
    if rec.entity == "session" and rec.action == "wait_for_user" then
      wfu_records = wfu_records + 1
    end
  end
  assert_eq(term_records, 1, "B: exactly one request terminal record")
  assert_eq(wfu_records, 1, "B: exactly one session wait_for_user record")
  assert_eq(#h, 10, "B: full history (ready,accept,start,stream,tool_pending,run,drain,batch_term,req_term,wfu)")
  local first = h[1]
  assert_eq(first.entity, "session", "B: first record entity")
  assert_eq(first.action, "ready", "B: first record action")
  check(type(first.owner) == "string" and type(first.event) == "string", "B: record owner/event")
  check(type(first.reason) == "string" and type(first.at) == "number", "B: record reason/at")
end

-------------------------------------------------------------------------------
-- C. Illegal transitions: typed error + diagnostic event + no partial mutation
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local rejected = 0
  local payloads = {}
  bus.on(bus.events.session_transition_rejected or "session.transition_rejected", function(p)
    rejected = rejected + 1
    payloads[#payloads + 1] = p
  end)
  local s = session_mod.new({ session_id = "s-illegal", events = bus })
  local req = s:start_request()

  -- duplicate submit while busy
  local ok, _, err = session_mod.transition(s, "accept_submit", { session = s })
  check(ok == nil and err ~= nil, "C: duplicate accept_submit rejected")
  assert_eq(err.code, schema.ERROR.INVALID_ARGUMENT, "C: reject error code")
  assert_eq(rejected, 1, "C: diagnostic event emitted once")
  assert_eq(payloads[1].entity, "session", "C: payload entity")
  assert_eq(payloads[1].action, "accept_submit", "C: payload action")
  assert_eq(payloads[1].error.code, schema.ERROR.INVALID_ARGUMENT, "C: payload error code")
  check(s.state == session_mod.states.busy and s.active_request_id == req.id, "C: no partial mutation after reject")

  -- unknown action
  local ok2, _, err2 = session_mod.transition(req, "teleport", { session = s })
  check(ok2 == nil and err2 ~= nil, "C: unknown action rejected")
  assert_eq(rejected, 2, "C: second diagnostic")

  -- illegal terminal state through the compat wrapper
  local fok, ferr = s:finish_request(req, "streaming")
  check(fok == false and ferr ~= nil, "C: illegal terminal state")
  assert_eq(ferr.code, schema.ERROR.INVALID_ARGUMENT, "C: terminal err code")
  check(s.state == session_mod.states.busy, "C: no mutation after illegal terminal")

  -- batch terminal with a non-terminal target
  local b = s:new_tool_batch()
  local ok3, _, err3 = session_mod.transition(b, "terminal", { session = s, to = "draining" })
  check(ok3 == nil and err3 ~= nil, "C: illegal batch terminal to")
  assert_eq(b.state, "pending", "C: batch unchanged after reject")

  -- request terminal without ctx.session
  local ok4, _, err4 = session_mod.transition(req, "terminal", { to = "completed" })
  check(ok4 == nil and err4 ~= nil, "C: terminal requires ctx.session")
end

-------------------------------------------------------------------------------
-- D. Terminal idempotency: first CAS wins, later calls no-op
-------------------------------------------------------------------------------
do
  local s = session_mod.new({ session_id = "s-term" })
  local req = s:start_request()
  local ok1 = s:finish_request(req, "completed")
  check(ok1 == true, "D: first terminal wins")
  local ok2 = s:finish_request(req, "completed")
  check(ok2 == false, "D: repeat terminal no-op")
  local ok3 = s:finish_request(req, "failed")
  check(ok3 == false, "D: different terminal also no-op")
  assert_eq(req.state, "completed", "D: first terminal state kept")
  assert_eq(s.state, session_mod.states.waiting_for_user, "D: session unchanged")

  -- batch terminal CAS
  local req2 = s:start_request()
  local b = s:new_tool_batch()
  local t1ok, t1res = session_mod.transition(b, "terminal", { session = s, to = "completed" })
  check(t1ok == true and t1res.changed == true, "D: batch first terminal")
  local t2ok, t2res = session_mod.transition(b, "terminal", { session = s, to = "failed" })
  check(t2ok == true and t2res.changed == false, "D: batch second terminal no-op")
  assert_eq(b.state, "completed", "D: batch keeps first terminal")
  s:finish_request(req2, "completed")
end

-------------------------------------------------------------------------------
-- E. Superseded request terminal: marked, session untouched
-------------------------------------------------------------------------------
do
  local s = session_mod.new({ session_id = "s-super" })
  local reqA = s:start_request({ request_id = "req-A" })
  -- Simulate the W3 continuation supersession: a new automatic request becomes
  -- active while reqA is still non-terminal (the reducer's busy->busy authority
  -- advance; W1 has no public API to start a second request while busy).
  s.active_request_id = "req-B"
  s.generation = 2

  local ok, err = s:finish_request(reqA, "failed")
  check(ok == false and err == nil, "E: superseded terminal no-op")
  check(
    reqA.terminal ~= nil and reqA.terminal.state == "failed" and reqA.terminal.superseded == true,
    "E: superseded marked"
  )
  -- Phase-0 parity: the superseded call marks the terminal record only; the
  -- lifecycle `state` field and the session stay untouched.
  assert_eq(reqA.state, "submitted", "E: stale request lifecycle state untouched")
  check(s.state == session_mod.states.busy and s.active_request_id == "req-B", "E: session not mutated")
  -- A later terminal for the active successor still works (reqA is stale).
  local okB = s:finish_request(reqA, "completed")
  check(okB == false, "E: stale request never mutates again (idempotent)")
  s:close()
end

-------------------------------------------------------------------------------
-- F. stop / close semantics
-------------------------------------------------------------------------------
do
  local s = session_mod.new({ session_id = "s-stop" })
  local req = s:start_request()
  local b = s:new_tool_batch()
  local stopped = s:stop("user pressed stop")
  check(stopped == true, "F: stop performed")
  assert_eq(s.state, session_mod.states.stopped, "F: session stopped")
  check(
    req.terminal ~= nil and req.terminal.state == "cancelled" and req.terminal.reason == "user pressed stop",
    "F: active request cancelled"
  )
  check(b.terminal ~= nil and b.terminal.state == "cancelled", "F: active batch cancelled")
  check(s:is_closed() == false and s:is_idle() == false and s:is_busy() == false, "F: stopped is terminal-ish")
  local again = s:stop()
  check(again == false, "F: stop idempotent")

  local req2, err2 = s:start_request()
  check(req2 == nil and err2 ~= nil, "F: no submit after stop")
  assert_eq(err2.terminal, true, "F: stopped error is terminal")

  local closed = s:close()
  check(closed == true, "F: close from stopped")
  assert_eq(s.state, session_mod.states.closed, "F: closed")
  local again2 = s:close()
  check(again2 == false, "F: close idempotent")
end

do
  local s = session_mod.new({ session_id = "s-close-busy" })
  local req = s:start_request()
  local b = s:new_tool_batch()
  local closed = s:close()
  check(closed == true, "G: close busy performed")
  assert_eq(s.state, session_mod.states.closed, "G: closed")
  check(req.terminal ~= nil and req.terminal.state == "cancelled", "G: request cancelled on close")
  check(b.terminal ~= nil and b.terminal.state == "cancelled", "G: batch cancelled on close")
  local req2, err2 = s:start_request()
  check(req2 == nil and err2 ~= nil, "G: no submit after close")
  assert_eq(err2.terminal, true, "G: closed error is terminal")
end

-------------------------------------------------------------------------------
-- H. View transitions
-------------------------------------------------------------------------------
do
  local s = session_mod.new({ session_id = "s-view" })
  local v = s:new_view({ view_id = "view-1", bufnr = 42 })
  check(v ~= nil, "H: view constructed")
  assert_eq(v.state, "attached", "H: view attached at construction")
  assert_eq(v.session_id, "s-view", "H: view session_id")
  assert_eq(v.generation, 0, "H: view generation")
  assert_eq(v.bufnr, 42, "H: view bufnr")

  local h1, r1 = session_mod.transition(v, "hide", { session = s })
  check(h1 == true and r1.changed == true, "H: hide")
  assert_eq(v.state, "hidden", "H: hidden")
  local sh, sr = session_mod.transition(v, "show", { session = s })
  check(sh == true and sr.changed == true, "H: show")
  assert_eq(v.state, "attached", "H: re-attached")
  local det, dr = session_mod.transition(v, "detach", { session = s, reason = "buffer deleted" })
  check(det == true and dr.changed == true, "H: detach")
  assert_eq(v.state, "detached", "H: detached")
  assert_eq(s.state, session_mod.states.ready, "H: session remains after view detach")

  local vc, vcr = session_mod.transition(v, "close", { session = s })
  check(vc == true and vcr.changed == true, "H: view close from detached")
  assert_eq(v.state, "closed", "H: view closed")
  local vc2, vc2r = session_mod.transition(v, "close", { session = s })
  check(vc2 == true and vc2r.changed == false, "H: view close idempotent")

  local bad, _, errb = session_mod.transition(v, "hide", { session = s })
  check(bad == nil and errb ~= nil, "H: hide from closed rejected")
  assert_eq(v.state, "closed", "H: no mutation after rejected view transition")
end

-------------------------------------------------------------------------------
-- I. continue reducer row + batch construction guard
-------------------------------------------------------------------------------
do
  local s = session_mod.new({ session_id = "s-cont" })
  local req = s:start_request()
  local ok1, r1 = s:transition("continue", { reason = "auto-continuation" })
  check(ok1 == true and r1.changed == true, "I: continue busy->busy")
  assert_eq(s.state, "busy", "I: still busy after continue")
  local ok2, r2 = s:transition("continue")
  check(ok2 == true and r2.changed == true, "I: continue allowed again (not idempotent)")
  s:finish_request(req, "completed")
  local ok3, _, err3 = s:transition("continue")
  check(ok3 == nil and err3 ~= nil, "I: continue rejected when not busy")

  local s2 = session_mod.new({ session_id = "s-nobatch" })
  local b, berr = s2:new_tool_batch()
  check(b == nil and berr ~= nil, "I: batch requires active request")
  assert_eq(berr.code, schema.ERROR.INVALID_ARGUMENT, "I: batch err code")
end

-------------------------------------------------------------------------------
-- J. Import-guard: nothing legacy loaded
-------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "J: import-guard no legacy families")
end

if ok_all then
  print("STATE_ENTITIES_OK")
else
  -- Throw instead of :cq so the tests/state runner can record the failure and
  -- continue with the remaining fixtures. Standalone runs keep the same exit
  -- semantics (the headless wrapper maps a thrown error to :cq / exit 1).
  error("STATE_ENTITIES_FAILED count=" .. #failures)
end
