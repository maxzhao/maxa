local M = {}

-- Anchor to the installed runtime, not the selected project's working directory.
local source = debug.getinfo(1, "S").source or ""
if source:sub(1, 1) == "@" then
  local root = vim.fs.normalize(vim.fn.fnamemodify(source:sub(2), ":p"))
  for _ = 1, 3 do
    root = vim.fs.dirname(root)
  end
  M.runtime_root = root
  M.path = root .. "/.version"
end

---Read the runtime/project-schema compatibility generation.
---@return string? version
---@return string? error
function M.read()
  if not M.path then
    return nil, "runtime-root-unavailable"
  end
  local fd = io.open(M.path, "r")
  if not fd then
    return nil, "missing"
  end
  local line = (fd:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  fd:close()
  local value = tonumber(line)
  if not value or value < 0 or value % 1 ~= 0 then
    return nil, "invalid"
  end
  return line
end

return M
