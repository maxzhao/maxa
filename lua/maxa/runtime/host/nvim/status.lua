-- filepath: lua/maxa/runtime/host/nvim/status.lua
--- maxa host Chat status projection (chat-ui-status subpackage 3.5 of
--- .supermax/drafts/chat-ui-modernization-plan.md; phase-5 W2 spine wiring).
---
--- Rendering separation contract (chat-ui spec): the Chat view owns rendering;
--- global status (lualine) and spinners consume the view spine separately
--- through a read-only projection. This module provides:
---   * `spinner_frame()`      deterministic spinner frame for busy states,
---   * `lualine_component()`  a lualine-compatible component function; with a
---                            registered spine service it reads ONLY the spine
---                            snapshot (provider/model/usage/state + spinner
---                            frame); without a spine it falls back to the
---                            active view projection (empty when absent),
---   * `set_active_view()`    register the view lualine should project (fallback
---                            path; preserved for phase-1.5 compatibility),
---   * `set_spine()`          register the status spine service (preferred path).
---
--- No timers/global side effects: frames derive from `vim.loop.now()` at call
--- time, so the component is safe to evaluate on every lualine refresh. The
--- component never mutates the spine (read-only snapshot access only).
local M = {}
M.name = "host.nvim.status"

-- Spinner frames (braille, 100ms cadence derived from clock time).
M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@private The view currently projected by the lualine component (fallback).
M._active_view = nil

---@private The registered spine service (preferred projection source).
M._spine = nil

--- Register the view whose projection the lualine component reads.
--- Used as the no-spine fallback; the main session wires the spine service via
--- set_spine() and drives display identity through it.
---@param view table|nil maxa host view (nil clears the projection)
function M.set_active_view(view)
  M._active_view = view
end

--- Register the status spine service the lualine component reads. When set,
--- the component projects the spine snapshot exclusively (no view lookup, no
--- CodeCompanion internals, no metadata writes).
---@param spine table|nil status service exposing snapshot() (nil clears)
function M.set_spine(spine)
  M._spine = spine
end

--- Deterministic spinner frame for a point in time (no timer state).
---@return string
function M.spinner_frame()
  local now = vim.loop.now()
  return M.SPINNER_FRAMES[(math.floor(now / 100) % #M.SPINNER_FRAMES) + 1]
end

---@private Format a normalized usage table as "in=N out=N" (nil when absent).
---@param usage table|nil
---@return string|nil
local function format_usage(usage)
  if type(usage) ~= "table" then
    return nil
  end
  local parts = {}
  if usage.input_tokens ~= nil then
    parts[#parts + 1] = ("in=%d"):format(usage.input_tokens)
  end
  if usage.output_tokens ~= nil then
    parts[#parts + 1] = ("out=%d"):format(usage.output_tokens)
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " ")
end

---@private Build the lualine text from a spine snapshot. Read-only: only
--- snapshot()/spinner_phase() are consulted, never a spine mutator.
---@param spine table status service
---@return string
local function spine_text(spine)
  local snapshot = spine.snapshot()
  local phase = "idle"
  if type(spine.spinner_phase) == "function" then
    phase = spine.spinner_phase()
  elseif snapshot.active_requests and snapshot.active_requests > 0 then
    phase = "busy"
  end
  local parts = {}
  if phase ~= "idle" and phase ~= "terminal" then
    parts[#parts + 1] = M.spinner_frame()
  end
  if type(snapshot.provider_id) == "string" then
    parts[#parts + 1] = snapshot.provider_id
  end
  if type(snapshot.model) == "string" then
    parts[#parts + 1] = snapshot.model
  end
  local usage = format_usage(snapshot.usage)
  if usage then
    parts[#parts + 1] = usage
  end
  if next(snapshot.terminal or {}) ~= nil then
    local t = snapshot.terminal
    parts[#parts + 1] = t.state .. (type(t.reason) == "string" and (": " .. t.reason) or "")
  end
  if next(snapshot.notification or {}) ~= nil then
    parts[#parts + 1] = type(snapshot.notification.message) == "string" and snapshot.notification.message or "!"
  end
  if #parts == 0 then
    return ""
  end
  return table.concat(parts, " ")
end

--- Build a lualine-compatible component: a zero-arg function returning the
--- projected status text. With a spine service the text comes from the spine
--- snapshot (spinner frame + provider/model + normalized usage + state);
--- without a spine it falls back to the active view projection ("" when none).
--- Rendering is decoupled: this module never mutates the view or the spine.
---@return function
function M.lualine_component()
  return function()
    if M._spine then
      return spine_text(M._spine)
    end
    local v = M._active_view
    if not v or type(v.projection) ~= "function" then
      return ""
    end
    local p = v:projection()
    return (p and p.text) or ""
  end
end

return M
