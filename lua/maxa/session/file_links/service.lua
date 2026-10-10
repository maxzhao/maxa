local M = {}
local starting = {}

local function configuration()
  local runtime = require("maxa.config").runtime()
  return runtime.chat_upload.hostname, runtime.file_links or { port = 43128, allowed_roots = { ".maxa" } }
end

local function request(method, endpoint, payload, callback)
  local host, cfg = configuration()
  local scheme = host == "127.0.0.1" and "http" or "https"
  local command = { "curl", "-sS", "--noproxy", "*", "--connect-timeout", "1", "--max-time", "2",
    "--fail-with-body", "-X", method, scheme .. "://" .. host .. ":" .. cfg.port .. endpoint }
  if scheme == "https" then
    vim.list_extend(command, { "--resolve", host .. ":" .. cfg.port .. ":127.0.0.1" })
  end
  local options = { text = true }
  if payload then
    vim.list_extend(command, { "-H", "Content-Type: application/json", "--data-binary", "@-" })
    options.stdin = vim.json.encode(payload)
  end
  local ok, err = pcall(vim.system, command, options, function(result)
    vim.schedule(function()
      local decoded, data = pcall(vim.json.decode, result.stdout or "")
      callback(result.code == 0 and decoded, decoded and data or nil,
        result.code == 0 and nil or vim.trim(result.stderr or "file service unavailable"))
    end)
  end)
  if not ok then callback(false, nil, tostring(err)) end
end

local function ready(callback)
  request("GET", "/health", nil, function(ok, data, err)
    callback(ok and type(data) == "table" and data.service == "maxa-file-links" and data.version == 1, err)
  end)
end

function M.register(root, paths, callback)
  local host, cfg = configuration()
  local function register()
    request("POST", "/register", { pid = vim.fn.getpid(), project_root = root,
      allowed_roots = cfg.allowed_roots, paths = paths }, function(ok, data, err)
      callback(ok and type(data) == "table" and type(data.urls) == "table" and data.urls or nil, err)
    end)
  end
  ready(function(ok)
    if ok then return register() end
    local key = host .. ":" .. tostring(cfg.port)
    if starting[key] then starting[key][#starting[key] + 1] = { register, callback }; return end
    starting[key] = { { register, callback } }
    local cli = vim.fs.joinpath(vim.fn.stdpath("config"), "tools/chat-upload/src/file_links_cli.mjs")
    -- A detached, unreferenced daemon belongs to all registered processes, not this caller.
    local handle
    local spawned, value = pcall(function()
      handle = vim.uv.spawn("node", { args = { cli, "--hostname", host, "--port", tostring(cfg.port) },
        detached = true, stdio = { nil, nil, nil } }, function()
        if handle and not handle:is_closing() then handle:close() end
      end)
      if handle then handle:unref() end
      return handle
    end)
    local function finish(success, err)
      local pending = starting[key] or {}
      starting[key] = nil
      for _, item in ipairs(pending) do
        if success then item[1]() else item[2](nil, err) end
      end
    end
    if not spawned or not value then return finish(false, "could not launch local file service") end
    local deadline = vim.uv.hrtime() + 5e9
    local function poll()
      ready(function(available, err)
        if available then return finish(true) end
        if vim.uv.hrtime() >= deadline then return finish(false, err or "file service did not become ready (port or TLS configuration)") end
        vim.defer_fn(poll, 100)
      end)
    end
    poll()
  end)
end

M.configuration = configuration
return M
