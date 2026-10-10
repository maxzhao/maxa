-- Search query normalization and Rust-regex filtering of LSP candidates.
local M = {}

function M.resolve(params, required)
  if params.patterns ~= nil or params.literal ~= nil then
    return nil, "search uses text or regex; patterns and literal are no longer supported."
  end
  if params.text ~= nil and params.regex ~= nil then
    return nil, "text and regex are mutually exclusive."
  end
  local mode = params.text ~= nil and "text" or params.regex ~= nil and "regex" or "none"
  if mode == "none" then
    if required then return nil, "search requires text or regex for this scope." end
    return { mode = mode, values = {} }
  end
  local values = params[mode]
  if type(values) == "string" then values = { values } end
  if type(values) ~= "table" or not vim.islist(values) or #values == 0 then
    return nil, mode .. " must be a nonempty string or array of nonempty strings."
  end
  for _, value in ipairs(values) do
    if type(value) ~= "string" or value == "" then
      return nil, mode .. " must contain only nonempty strings."
    end
  end
  return { mode = mode, values = values }
end

function M.prepare(context)
  local params = {}
  for key, value in pairs(context.params or {}) do
    if value ~= vim.NIL then params[key] = value end
  end
  local query, err = M.resolve(params)
  if not query then return nil, err end
  if query.mode ~= "none" then params[query.mode] = vim.deepcopy(query.values) end
  return params
end

function M.rg_args(query, case)
  local args = { "--no-config", "--engine=default", "--color=never" }
  if query.mode == "text" then args[#args + 1] = "--fixed-strings" end
  if case == "insensitive" then args[#args + 1] = "--ignore-case"
  elseif case == "smart" then args[#args + 1] = "--smart-case" end
  for _, value in ipairs(query.values) do args[#args + 1] = "--regexp=" .. value end
  return args
end

-- Returns a process for cancellation, or completes synchronously for text/none.
-- Each candidate is one rendered line; matched line numbers preserve record identity.
function M.filter(query, lines, done)
  if query.mode ~= "regex" then
    local matched = {}
    for index, line in ipairs(lines) do
      if query.mode == "none" then matched[index] = true else
        for _, value in ipairs(query.values) do
          if line:find(value, 1, true) then matched[index] = true; break end
        end
      end
    end
    done(matched)
    return
  end
  local args = { "rg" }
  vim.list_extend(args, M.rg_args(query))
  -- Numbered lines avoid JSON's per-match payload growth for patterns like '.'.
  vim.list_extend(args, { "--line-number", "--no-heading", "--no-filename", "--text", "--", "-" })
  local input = {}
  for index, line in ipairs(lines) do input[index] = line:gsub("[\r\n]", " ") end
  local ok, process = pcall(vim.system, args, { stdin = #input > 0 and table.concat(input, "\n") .. "\n" or "", text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 and result.code ~= 1 then
        return done(nil, "regex: rg failed (" .. result.code .. "): " .. (result.stderr or ""):sub(1, 2048))
      end
      local matched = {}
      for line in (result.stdout or ""):gmatch("[^\n]+") do
        local index = tonumber(line:match("^(%d+):"))
        if not index or not lines[index] then return done(nil, "Cannot decode rg candidate line number.") end
        matched[index] = true
      end
      done(matched)
    end)
  end)
  if not ok then done(nil, "regex: cannot start rg: " .. tostring(process)); return end
  return process
end

return M
