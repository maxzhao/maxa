-- filepath: lua/maxa/runtime/host/nvim/status.lua
--- maxa host Chat status projection (chat-ui-status subpackage 3.5 of
--- .supermax/drafts/chat-ui-modernization-plan.md).
---
--- Rendering separation contract (chat-ui spec): the Chat view owns rendering;
--- global status (lualine) and spinners consume the view spine separately
--- through a read-only projection. This module provides:
---   * `spinner_frame()`      deterministic spinner frame for busy states,
---   * `lualine_component()`  a lualine-compatible component function reading
---                            the active view projection (empty when absent),
---   * `set_active_view()`    register the view lualine should project.
---
--- No timers/global side effects: frames derive from `vim.loop.now()` at call
--- time, so the component is safe to evaluate on every lualine refresh.
local M = {}
M.name = "host.nvim.status"

-- Spinner frames (braille, 100ms cadence derived from clock time).
M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@private The view currently projected by the lualine component.
M._active_view = nil

--- Register the view whose projection the lualine component reads.
---@param view table|nil maxa host view (nil clears the projection)
function M.set_active_view(view)
  M._active_view = view
end

--- Deterministic spinner frame for a point in time (no timer state).
---@return string
function M.spinner_frame()
  local now = vim.loop.now()
  return M.SPINNER_FRAMES[(math.floor(now / 100) % #M.SPINNER_FRAMES) + 1]
end

--- Build a lualine-compatible component: a zero-arg function returning the
--- projected status text of the active view ("" when none). Rendering is
--- decoupled: this module never mutates the view.
---@return function
function M.lualine_component()
  return function()
    local v = M._active_view
    if not v or type(v.projection) ~= "function" then
      return ""
    end
    local p = v:projection()
    return (p and p.text) or ""
  end
end

return M
