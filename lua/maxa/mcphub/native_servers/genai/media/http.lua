local M = {}

local function temp_path(label)
  local dir = vim.fn.stdpath("cache") .. "/genai-media-tmp"
  vim.fn.mkdir(dir, "p")
  return string.format("%s/%s_%s", dir, label, tostring(vim.uv.hrtime()))
end

local function read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

local function remove(path)
  if path then pcall(vim.loop.fs_unlink, path) end
end

local function bounded(value, limit)
  value = tostring(value or ""):gsub("[%z\1-\8\11\12\14-\31\127-\255]", "?")
  if #value > (limit or 500) then return value:sub(1, limit or 500) .. "…" end
  return value
end

function M.json(value)
  local ok, decoded = pcall(vim.json.decode, value or "")
  if ok then return decoded end
  return nil
end

function M.error_from(body, status)
  local decoded = M.json(body)
  local message
  if type(decoded) == "table" then
    local err = decoded.error
    if type(err) == "table" then message = err.message or err.msg end
    message = message or decoded.message or decoded.msg
    if not message and type(decoded.data) == "table" then message = decoded.data.message or decoded.data.msg end
  end
  message = message or (body and body:match("<title>(.-)</title>")) or body
  return string.format("HTTP %s: %s", tostring(status or "?"), bounded(message))
end

-- Execute curl without blocking Neovim. The response body is written to a file so
-- binary media never enters MCP result text or Lua JSON handling.
function M.request_async(opts, callback)
  local body_path, header_path = temp_path("body"), temp_path("headers")
  local args = { "curl", "--silent", "--show-error", "--location", "--max-time", tostring(opts.timeout or 300), "-D", header_path, "-o", body_path, "-w", "%{http_code}", "-X", opts.method or "GET" }
  local proxy = opts.proxy
  if type(proxy) == "function" then proxy = proxy() end
  if proxy then
    table.insert(args, "--proxy"); table.insert(args, proxy)
  else
    table.insert(args, "--noproxy"); table.insert(args, "*")
  end
  for _, header in ipairs(opts.headers or {}) do table.insert(args, "-H"); table.insert(args, header) end
  if opts.data then table.insert(args, "--data-binary"); table.insert(args, opts.data) end
  for _, form in ipairs(opts.form_strings or {}) do table.insert(args, "--form-string"); table.insert(args, form) end
  for _, form in ipairs(opts.form_files or {}) do table.insert(args, "-F"); table.insert(args, form) end
  table.insert(args, opts.url)
  local completed, process = false, nil
  local finish = vim.schedule_wrap(function(result)
    if completed then return end
    completed = true
    local status = tonumber(result and result.stdout or "")
    local body = read(body_path) or ""
    local headers = read(header_path) or ""
    remove(body_path); remove(header_path)
    if not status or status < 200 or status >= 300 then
      return callback(nil, M.error_from(body, status or result.code))
    end
    callback({ body = body, headers = headers, status = status }, nil)
  end)
  local ok, err = pcall(function() process = vim.system(args, { text = true }, finish) end)
  if not ok then
    completed = true
    remove(body_path); remove(header_path); callback(nil, "Failed to start curl: " .. tostring(err))
  end
  return {
    cancel = function()
      if completed then return false end
      completed = true
      if process then pcall(process.kill, process, 15) end
      remove(body_path); remove(header_path)
      return true
    end,
  }
end

return M
