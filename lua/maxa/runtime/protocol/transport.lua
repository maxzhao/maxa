-- filepath: lua/maxa/runtime/protocol/transport.lua
--- maxa runtime HTTP transport: plenary.curl POST wrapper (phase-1 W1).
---
--- Purpose: the single transport boundary for protocol adapters. Encodes the
--- request body to a temp file (avoiding shell command-line length), drives
--- plenary.curl with headers/proxy/connect-timeout/max-time, and normalizes
--- every failure mode into a typed schema error with a granular class
--- (authentication / rate_limited / quota / network / timeout / protocol /
--- invalid_request / provider_unavailable).
---
--- Alignment (read-only) to the pinned CodeCompanion v18.7.0 `http.lua`:
---   - temp-file JSON body via vim.fn.tempname() + plenary.path:write
---   - same plenary.curl option surface (headers/proxy/raw/compressed)
---   - three-callback contract (on_chunk / on_done / on_error) + job:shutdown()
---     cancel; streaming disables compression and adds --tcp-nodelay/--no-buffer
---   - streamed JSON error bodies (`{"error"...` / `{"type":"error"...`) are
---     captured and classified at the final callback; they are NOT forwarded to
---     on_chunk (mirrors http.lua stream_error_body handling).
--- The original is NEVER imported; only behavior is aligned.
---
--- Contract:
---   client = M.new(opts?) -> client        (opts may inject static methods)
---   handle = client:post(request_opts, callbacks) -> handle|nil, err
---     request_opts: { url=string,
---                     headers?=table<string,string>,
---                     body?=table|string,   -- encoded/written to a temp file
---                     body_file?=string,    -- caller-owned file path (no cleanup)
---                     stream?=bool,         -- SSE streaming mode
---                     method?=string,       -- "post" default
---                     timeout_ms?=int,      -- curl --max-time (whole request)
---                     connect_timeout_ms?=int, -- curl --connect-timeout (default 10s)
---                     proxy?=string,        -- explicit proxy URL
---                     proxy_env?=string,    -- env var name holding the proxy URL
---                     raw?=string[],        -- extra curl args
---                     retries?=int }        -- parsed only; auto-retry is phase 2
---     callbacks: { on_chunk?=fun(data:string),   -- line-normalized stream chunks (line + "\n")
---                  on_done?=fun(response:table|nil), -- stream: nil; else plenary
---                                                 -- response {status,headers,body,exit}
---                  on_error?=fun(err:typed_error) } -- schema.new_error shape with
---                                                 -- cause.class = M.CLASS.*
---     handle: { id=string, job=table|nil, active=bool,
---               status() -> "pending"|"streaming"|"success"|"error"|"cancelled",
---               cancel() -> bool, last_error?=table }
---
--- Invariants:
---   - Exactly one terminal callback (on_done xor on_error) fires per request;
---     after a terminal (or cancel) all late callbacks are suppressed.
---   - HTTP status >= 400 -> on_error with a typed error (body preserved in
---     cause.body for diagnostics).
---   - curl-level failures -> on_error (exit 28 -> TIMEOUT/timeout class).
---   - Auto-retry is NOT implemented here (phase-2 watchdog/backoff domain);
---     `retries` is validated and recorded on the handle only.
---
--- Dependencies: plenary.curl, plenary.path, maxa.runtime.schema. Never loads
--- codecompanion.* / mcphub.* / lua/util/hooks/*.

local Curl = require("plenary.curl")
local Path = require("plenary.path")
local schema = require("maxa.runtime.schema")

local M = {}

M.name = "protocol.transport"

--- Granular failure classes (phase-1 plan §4.2). The runtime-level error code
--- stays schema.ERROR.*; the finer class lives at err.cause.class so adapters
--- and the orchestrator can branch without loosening the typed-error contract.
M.CLASS = {
  AUTHENTICATION = "authentication",
  RATE_LIMITED = "rate_limited",
  QUOTA = "quota",
  NETWORK = "network",
  TIMEOUT = "timeout",
  PROTOCOL = "protocol",
  INVALID_REQUEST = "invalid_request",
  PROVIDER_UNAVAILABLE = "provider_unavailable",
}

--- Static method injection points (mirrors codecompanion http.lua
--- Client.static.methods): tests inject a fake `post` / `schedule` to drive the
--- transport without a network, and a fake `tempname`/`fs_rm` to observe temp
--- files. Defaults are the real plenary/vim implementations.
M.static = {
  post = { default = Curl.post },
  encode = { default = vim.json.encode },
  schedule = { default = vim.schedule },
  schedule_wrap = { default = vim.schedule_wrap },
  tempname = { default = vim.fn.tempname },
  fs_rm = { default = vim.loop.fs_unlink },
}

--- Map a provider-reported error type/status to a transport class. Returns nil
--- when the provider string is unknown (callers fall back to status mapping).
--- Provider vocabularies covered: OpenAI (error.type), Anthropic (error.type),
--- Gemini (error.status). Unknown values are deliberately not guessed.
---@param provider_type string
---@return string|nil class
function M.class_from_provider_type(provider_type)
  local map = {
    insufficient_quota = M.CLASS.QUOTA,
    quota_exceeded = M.CLASS.QUOTA,
    resource_exhausted = M.CLASS.QUOTA,
    rate_limit_error = M.CLASS.RATE_LIMITED,
    rate_limit_exceeded = M.CLASS.RATE_LIMITED,
    requests = M.CLASS.RATE_LIMITED,
    tokens = M.CLASS.RATE_LIMITED,
    authentication_error = M.CLASS.AUTHENTICATION,
    permission_error = M.CLASS.AUTHENTICATION,
    permission_denied = M.CLASS.AUTHENTICATION,
    unauthenticated = M.CLASS.AUTHENTICATION,
    invalid_request_error = M.CLASS.INVALID_REQUEST,
    invalid_argument = M.CLASS.INVALID_REQUEST,
    failed_precondition = M.CLASS.INVALID_REQUEST,
    not_found = M.CLASS.INVALID_REQUEST,
    api_error = M.CLASS.PROVIDER_UNAVAILABLE,
    overloaded_error = M.CLASS.PROVIDER_UNAVAILABLE,
    unavailable = M.CLASS.PROVIDER_UNAVAILABLE,
    internal = M.CLASS.PROVIDER_UNAVAILABLE,
    deadline_exceeded = M.CLASS.TIMEOUT,
    timeout = M.CLASS.TIMEOUT,
  }
  if type(provider_type) ~= "string" then
    return nil
  end
  return map[provider_type:lower()]
end

--- Fallback class from an HTTP status code.
---@param status integer
---@return string class
function M.class_from_status(status)
  if status >= 500 then
    return M.CLASS.PROVIDER_UNAVAILABLE
  end
  if status == 429 then
    return M.CLASS.RATE_LIMITED
  end
  if status == 408 then
    return M.CLASS.TIMEOUT
  end
  if status == 401 or status == 403 then
    return M.CLASS.AUTHENTICATION
  end
  if status == 400 or status == 404 then
    return M.CLASS.INVALID_REQUEST
  end
  return M.CLASS.PROVIDER_UNAVAILABLE
end

--- Classify an HTTP error response into { class, provider_type }.
--- Provider body classification wins over the status fallback when the body
--- carries a recognizable error.type / error.status field; the raw body is
--- always preserved by the caller for diagnostics.
---@param status integer HTTP status code
---@param body string|nil response body text
---@return table info { class=string, provider_type=string|nil }
function M.classify_error(status, body)
  local info = { class = M.class_from_status(status), provider_type = nil }
  if type(body) ~= "string" or body == "" then
    return info
  end
  local ok, parsed = pcall(vim.json.decode, body)
  if not ok or type(parsed) ~= "table" then
    return info
  end
  -- Anthropic roots the type at the payload level: {"type":"error","error":{...}}
  local err_obj = parsed.error
  if type(err_obj) ~= "table" then
    if type(parsed.type) == "string" then
      info.provider_type = parsed.type
      info.class = M.class_from_provider_type(parsed.type) or info.class
    end
    return info
  end
  -- OpenAI: error.type ("insufficient_quota", ...); Gemini: error.status.
  local t = err_obj.type or err_obj.status
  if type(t) == "string" then
    info.provider_type = t
    info.class = M.class_from_provider_type(t) or info.class
  end
  return info
end

--- Resolve the effective proxy for a request: explicit `proxy` wins; otherwise
--- `proxy_env` names an environment variable holding the proxy URL; otherwise
--- nil (curl uses its own environment).
---@param opts table request options
---@return string|nil proxy
function M.resolve_proxy(opts)
  opts = opts or {}
  if opts.proxy ~= nil then
    return opts.proxy
  end
  if type(opts.proxy_env) == "string" and opts.proxy_env ~= "" then
    local v = os.getenv(opts.proxy_env)
    if v and v ~= "" then
      return v
    end
  end
  return nil
end

--- Build a terminal typed transport error with the granular class attached.
---@param code string schema.ERROR.* code
---@param class string M.CLASS.* class
---@param message string
---@param cause table additional cause fields
---@return table error
local function typed_error(code, class, message, cause)
  cause = cause or {}
  cause.class = class
  return schema.new_error(code, message, cause, true)
end

--- Resolve per-client method overrides (test injection).
---@param opts? table client options { post?, encode?, schedule?, schedule_wrap?, tempname?, fs_rm? }
---@return table methods
local function resolve_methods(opts)
  local methods = {}
  for k, v in pairs(M.static) do
    methods[k] = (opts and opts[k] ~= nil) and opts[k] or v.default
  end
  return methods
end

--- Transport client class (one per request stream group; stateless apart from
--- injected methods). Instances are created via M.new and accessed through the
--- `Client:post` instance method.
local Client = {}

--- Encode a Lua table as JSON (injectable for tests).
---@param body table
---@return string json
function Client:encode(body)
  return self.methods.encode(body)
end

--- Issue a POST request (async). See the module contract for full option and
--- callback semantics.
---@param request_opts table request options (see module doc)
---@param callbacks? table { on_chunk?, on_done?, on_error? }
---@return table|nil handle
---@return string|nil err invalid-argument error (body must be table|string|body_file)
function Client:post(request_opts, callbacks)
  callbacks = callbacks or {}
  local methods = self.methods

  -- Request identity: adapters reject late events by this id (plan §4.2).
  local meta = { id = tostring(math.random(1000000)) }

  local state = "pending" -- pending|streaming|success|error|cancelled
  local terminated = false -- exactly-one-terminal guard
  local stream_error_body = nil -- captured streamed JSON error bodies
  local body_file = nil -- temp file created by this call (cleaned up)
  local cleanup = nil -- assigned below

  local handle = {
    id = meta.id,
    job = nil,
    active = true,
    last_error = nil,
  }

  --- Transition into a terminal state exactly once. Runs inside a scheduled
  --- callback (or cancel), so the guard double-checks `terminated`.
  ---@param kind "on_done"|"on_error"
  ---@param arg any callback argument
  local function emit(kind, arg)
    if terminated then
      return
    end
    terminated = true
    handle.active = false
    state = kind == "on_done" and "success" or "error"
    if cleanup then
      cleanup()
    end
    local fn = callbacks[kind]
    if fn then
      local ok, err = pcall(fn, arg)
      if not ok then
        handle.last_error = { kind = kind, err = tostring(err) }
      end
    end
  end

  -- Request body: encode tables, write to a temp file, hand the file to curl
  -- (-d @file) so the JSON never hits the command line.
  if not request_opts.body_file and request_opts.body ~= nil then
    local body_text
    if type(request_opts.body) == "table" then
      body_text = self:encode(request_opts.body)
    elseif type(request_opts.body) == "string" then
      body_text = request_opts.body
    else
      return nil, "transport.post: body must be a table, string, or body_file path"
    end
    local path = methods.tempname() .. ".json"
    Path.new(path):write(vim.split(body_text, "\n"), "w")
    body_file = path
  end

  cleanup = function()
    if body_file then
      pcall(methods.fs_rm, body_file)
      body_file = nil
    end
  end

  -- curl raw args: keepalive + explicit connect/max timeouts (plenary only
  -- applies `timeout` in sync mode, so async requests need raw flags).
  local raw = { "--keepalive-time", "60" }
  local connect_ms = request_opts.connect_timeout_ms or 10000
  raw[#raw + 1] = "--connect-timeout"
  raw[#raw + 1] = tostring(math.max(1, math.ceil(connect_ms / 1000)))
  if request_opts.timeout_ms then
    raw[#raw + 1] = "--max-time"
    raw[#raw + 1] = tostring(math.max(1, math.ceil(request_opts.timeout_ms / 1000)))
  end
  if request_opts.stream then
    -- Stream-optimized curl: immediate flush, no TCP delay. Compression is
    -- disabled so chunked gzip does not destroy SSE frame boundaries.
    raw[#raw + 1] = "--tcp-nodelay"
    raw[#raw + 1] = "--no-buffer"
  end
  if type(request_opts.raw) == "table" then
    vim.list_extend(raw, request_opts.raw)
  end

  local curl_opts = {
    url = request_opts.url,
    headers = request_opts.headers,
    proxy = M.resolve_proxy(request_opts),
    raw = raw,
    body = body_file or (request_opts.body_file or ""),
    compressed = not request_opts.stream, -- default on for non-stream
  }
  if request_opts.method then
    curl_opts.method = request_opts.method
  end

  -- Streaming chunks: plenary.job delivers stdout LINE-SPLIT — one callback per
  -- complete line WITHOUT its trailing newline (partial lines are concatenated
  -- across raw chunks), empty separator lines arrive as "", and \r is stripped.
  -- Transport reattaches "\n" per delivered line (including "" separators) so
  -- on_chunk consumers (the SSE parser) see the original line structure and
  -- dispatch frames on blank lines. JSON error bodies that arrive through the
  -- stream are captured for final classification and never forwarded to
  -- on_chunk (mirrors codecompanion http.lua).
  if request_opts.stream then
    curl_opts.stream = methods.schedule_wrap(function(_, data)
      if terminated then
        return
      end
      if type(data) == "string" then
        local line = data:gsub("\r", "")
        local trimmed = line:match("^%s*(.*)$") or line
        if trimmed:match('^{"error"') or trimmed:match('^{"type"%s*:%s*"error"') then
          stream_error_body = line
          return
        end
        state = "streaming"
        local fn = callbacks.on_chunk
        if fn then
          local ok, err = pcall(fn, line .. "\n")
          if not ok then
            handle.last_error = { kind = "on_chunk", err = tostring(err) }
          end
        end
      end
    end)
  end

  -- Final curl callback: non-stream responses carry the parsed response table;
  -- stream requests receive nil on success. HTTP >= 400 is normalized to a
  -- typed error (classified from the captured stream body or response body).
  curl_opts.callback = function(response)
    methods.schedule(function()
      if terminated then
        return
      end
      local status = response and response.status
      if status and status >= 400 then
        local body = stream_error_body or (response and response.body) or ""
        local info = M.classify_error(status, body)
        emit(
          "on_error",
          typed_error(
            schema.ERROR.PROVIDER,
            info.class,
            ("HTTP %d error from provider (class=%s)"):format(status, info.class),
            {
              status = status,
              body = body,
              provider_type = info.provider_type,
            }
          )
        )
        return
      end
      if request_opts.stream then
        emit("on_done", nil)
      else
        emit("on_done", response)
      end
    end)
  end

  -- curl-level failure (exit code != 0): exit 28 is a timeout (curl --max-time
  -- / connect deadline); DNS/connect failures are network class.
  curl_opts.on_error = function(err)
    methods.schedule(function()
      if terminated then
        return
      end
      local code = schema.ERROR.PROVIDER
      local class = M.CLASS.PROVIDER_UNAVAILABLE
      if err and err.exit == 28 then
        code = schema.ERROR.TIMEOUT
        class = M.CLASS.TIMEOUT
      elseif err and (err.exit == 6 or err.exit == 7) then
        class = M.CLASS.NETWORK
      end
      emit(
        "on_error",
        typed_error(code, class, "curl transport failure", {
          exit = err and err.exit,
          stderr = err and err.stderr,
          message = err and err.message,
        })
      )
    end)
  end

  handle.status = function()
    return state
  end

  -- Ordered cancel: abort the curl job and suppress every late callback.
  -- Exactly-once: a no-op once a terminal has fired.
  handle.cancel = function()
    if terminated then
      return false
    end
    terminated = true
    handle.active = false
    state = "cancelled"
    if cleanup then
      cleanup()
    end
    if handle.job and handle.job.shutdown then
      pcall(function()
        handle.job:shutdown()
      end)
    end
    return true
  end

  local job = methods.post(curl_opts)
  handle.job = job

  -- Parse-only validation of retries (auto-retry is phase-2): record it for
  -- diagnostics but never act on it here.
  if request_opts.retries ~= nil then
    handle.retries = request_opts.retries
  end

  return handle
end

--- Create a transport client.
---@param opts? table client options (method injection; see M.static)
---@return table client
function M.new(opts)
  return setmetatable({ methods = resolve_methods(opts), opts = opts or {} }, { __index = Client })
end

--- Convenience: issue a POST via a default client.
---@param request_opts table see Client:post
---@param callbacks? table { on_chunk?, on_done?, on_error? }
---@return table|nil handle
function M.post(request_opts, callbacks)
  return M.new():post(request_opts, callbacks)
end

return M
