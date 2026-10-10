-- LLM projection only; registry.public keeps diagnostic/UI task metadata.
local M = {}

function M.state(task, opts)
  opts = opts or {}
  local lines = {
    "async_id: " .. tostring(task and task.id or opts.async_id),
    "status: " .. tostring(task and task.status or "not_found"),
  }
  if opts.submitted then lines[#lines + 1] = "lifetime: current Neovim session" end
  if opts.wait_timed_out then lines[#lines + 1] = "wait_timed_out: true" end
  if opts.cancellation then lines[#lines + 1] = "cancellation: " .. opts.cancellation end
  local reason = opts.reason
  if not opts.cancellation then reason = reason or (task and task.error) end
  if task and task.cancel_error then reason = reason or "Canceller error: " .. task.cancel_error end
  if not task then reason = reason or "task unavailable in this Neovim session" end
  local text = table.concat(lines, "\n")
  if reason and reason ~= "" then text = text .. "\n---\n" .. reason end
  return text
end

return M
