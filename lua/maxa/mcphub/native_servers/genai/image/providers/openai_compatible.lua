-- OpenAI 兼容图片 provider driver
--
-- provider 抽象层负责根据配置准备 OpenAI-compatible 图片接口请求，并提供
-- image_generate/image_edit 工具可复用的 HTTP 调用与响应保存能力。模块加载与
-- 配置读取阶段不发起网络请求。

local image = require("maxa.mcphub.native_servers.genai.image")
local adapter_utils = require("maxa.mcphub.native_servers.genai.image.adapter")
local utils = require("maxa.mcphub.native_servers.genai.image.utils")
local requested_size = require("maxa.mcphub.native_servers.genai.image.requested_size")
local output_metadata = require("maxa.mcphub.native_servers.genai.image.output_metadata")

local M = {}

local function normalize_stream_default(params)
  if params.stream == nil or params.stream == vim.NIL then
    params.stream = true
  end
end

local DEFAULT_ENDPOINTS = {
  generations = "/images/generations",
  edits = "/images/edits",
}

local function normalize_openai_images_base_url(url)
  local base = tostring(url or ""):gsub("/+$", "")
  base = base:gsub("/responses$", "")
  base = base:gsub("/chat/completions$", "")
  return base
end

local function is_present(value)
  if value == nil or value == vim.NIL then
    return false
  end
  return not (type(value) == "string" and vim.trim(value) == "")
end

local function validate_openai_compatible_params(params)
  params = params or {}
  local valid_size, size_err = requested_size.validate_params(params, { provider_label = "openai_compatible" })
  if not valid_size then
    return nil, size_err
  end
  if is_present(params.text_model) then
    return nil, "openai_compatible uses the Images API and does not support text_model"
  end
  if type(params.extra) == "table" and is_present(params.extra.text_model) then
    return nil, "openai_compatible uses the Images API and does not support extra.text_model"
  end
  return true, nil
end

local function provider_endpoint(provider, endpoint_key)
  local endpoints = provider and provider.endpoints or {}
  return endpoints[endpoint_key] or DEFAULT_ENDPOINTS[endpoint_key]
end

local function validate_provider(provider, endpoint_key)
  if not provider then
    return nil, "image provider is required"
  end
  if provider.driver ~= "openai_compatible" then
    return nil, string.format(
      "Provider '%s' uses driver '%s', expected 'openai_compatible'",
      provider.name or "<unknown>",
      tostring(provider.driver)
    )
  end
  if not provider_endpoint(provider, endpoint_key) then
    return nil, string.format(
      "Endpoint '%s' is not configured for image provider '%s'",
      endpoint_key,
      provider.name or "<unknown>"
    )
  end
  return true, nil
end

local function prepare_common(provider, params, endpoint_key)
  local ok, err = validate_provider(provider, endpoint_key)
  if not ok then
    return nil, err
  end

  local settings
  settings, err = adapter_utils.resolve_provider_settings(provider)
  if not settings then
    return nil, err
  end
  if not settings.url or settings.url == "" then
    return nil, "base_url or adapter url is required for image provider '" .. tostring(provider.name) .. "'"
  end

  local ok_params
  ok_params, err = validate_openai_compatible_params(params)
  if not ok_params then
    return nil, err
  end

  local merged = image.build_request_params(provider, params)
  if merged.n ~= nil and merged.n ~= vim.NIL then
    local n = tonumber(merged.n)
    local max_n = tonumber(provider.max_n) or 15
    if not n or n % 1 ~= 0 or n < 1 or n > max_n then
      return nil, string.format("n must be an integer within 1..%d", max_n)
    end
    merged.n = n
  end
  local normalized_size
  normalized_size, err = requested_size.apply(merged, { provider_label = "openai_compatible" })
  if not normalized_size then
    return nil, err
  end
  if provider.force_stream ~= false then
    normalize_stream_default(merged)
  end
  settings.proxy = settings.proxy or provider.proxy
  merged.provider = merged.provider or provider.name
  merged.output_dir = merged.output_dir or provider.output_dir

  local output_dir
  output_dir, err = utils.resolve_output_dir(merged.output_dir)
  if not output_dir then
    return nil, err
  end
  merged.output_dir = output_dir

  local request_provider = vim.tbl_extend("force", provider, {
    api_key = settings.api_key,
  })

  local endpoint = provider_endpoint(provider, endpoint_key)
  return {
    provider = request_provider,
    params = merged,
    endpoint = utils.join_url(normalize_openai_images_base_url(settings.url), endpoint),
    adapter = settings.adapter,
    api_key = settings.api_key,
    proxy = settings.proxy,
  }, nil
end

local consumed_extra_fields = {
  requested_size = true,
  aspect = true,
  ratio = true,
  size = true,
  text_model = true,
}

local function add_extra_fields(body, extra)
  if type(extra) ~= "table" then
    return
  end
  for k, v in pairs(extra) do
    if type(k) == "string" and v ~= nil and not consumed_extra_fields[k] then
      body[k] = v
    end
  end
end

local function build_json_body(params)
  local body = {
    model = params.model,
    prompt = params.prompt,
    size = params.requested_size,
    quality = params.quality,
    output_format = params.output_format,
    background = params.background,
    response_format = params.response_format,
    n = params.n,
    stream = params.stream,
  }
  add_extra_fields(body, params.extra)
  return body
end

local function extract_http_response(raw)
  local status = nil
  local marker = raw:match("\n__HTTP_STATUS__(%d+)%s*$") or raw:match("__HTTP_STATUS__(%d+)%s*$")
  if marker then
    status = tonumber(marker)
    raw = raw:gsub("\n?__HTTP_STATUS__%d+%s*$", "")
  end

  -- curl -D - -o - 会先输出 header，再输出 body。不同平台/HTTP 版本下
  -- header block 可能以 CRLFCRLF 或 LFLF 分隔；重定向或 100-continue 时还
  -- 可能出现多个连续的 HTTP header block。只从响应开头剥离 header，避免
  -- JSON body 内部空行被误当作分隔符。
  local body = raw
  while body:match("^HTTP/%S+%s+%d+") do
    local crlf_start, crlf_end = body:find("\r\n\r\n", 1, true)
    local lf_start, lf_end = body:find("\n\n", 1, true)
    local end_pos

    if crlf_start and (not lf_start or crlf_start <= lf_start) then
      end_pos = crlf_end
    elseif lf_start then
      end_pos = lf_end
    else
      break
    end

    body = body:sub(end_pos + 1)
  end

  return status, body
end

M._extract_http_response = extract_http_response

local function insert_image_item(out, item)
  local key
  if type(item.b64_json) == "string" and item.b64_json ~= "" then
    key = "b64:" .. item.b64_json
  elseif type(item.url) == "string" and item.url ~= "" then
    key = "url:" .. item.url
  else
    return
  end

  -- Streaming Images API implementations may repeat the same final image in an
  -- item event and again in the completed response. Keep one local output per
  -- unique upstream payload while preserving the first-seen order.
  out._seen = out._seen or {}
  if out._seen[key] then
    return
  end

  out._seen[key] = true
  table.insert(out, item)
end

local function collect_image_items(value, out)
  if type(value) ~= "table" then
    return
  end

  if type(value.b64_json) == "string" and value.b64_json ~= "" then
    insert_image_item(out, { b64_json = value.b64_json })
  end
  if type(value.url) == "string" and value.url ~= "" then
    insert_image_item(out, { url = value.url })
  end

  for _, field in ipairs({ "data", "images", "results" }) do
    local list = value[field]
    if type(list) == "table" then
      if vim.islist(list) then
        for _, item in ipairs(list) do collect_image_items(item, out) end
      else
        collect_image_items(list, out)
      end
    end
  end

  local response = value.response
  if type(response) == "table" then
    collect_image_items(response, out)
  end

  local body = value.body
  if type(body) == "table" then
    collect_image_items(body, out)
  end

  local output = value.output
  if type(output) == "table" then
    for _, item in ipairs(output) do
      collect_image_items(item, out)
    end
  end
end

local function decode_sse_response(response_body)
  local items = {}
  local last_error = nil
  local event_lines = {}

  local function flush_event()
    if #event_lines == 0 then
      return
    end

    local payload = table.concat(event_lines, "\n")
    event_lines = {}
    if payload == "" or payload == "[DONE]" then
      return
    end

    local ok, decoded = pcall(vim.json.decode, payload)
    if ok and type(decoded) == "table" then
      collect_image_items(decoded, items)
      if type(decoded.error) == "table" then
        last_error = decoded.error.message or vim.inspect(decoded.error)
      elseif type(decoded.error) == "string" then
        last_error = decoded.error
      end
    else
      last_error = "Failed to parse SSE data JSON: " .. payload:sub(1, 500)
    end
  end

  for line in tostring(response_body or ""):gmatch("([^\n]*)\n?") do
    line = line:gsub("\r$", "")
    if line == "" then
      flush_event()
    elseif line:sub(1, 5) == "data:" then
      table.insert(event_lines, vim.trim(line:sub(6)))
    end
  end
  flush_event()

  if #items == 0 then
    return nil, last_error or "Image stream response contains no image data"
  end

  return { data = items }, nil
end

M._decode_sse_response = decode_sse_response

local function parse_json_candidate(body)
  local ok, decoded = pcall(vim.json.decode, body or "")
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function strip_to_json_payload(response_body)
  local body = tostring(response_body or "")

  if parse_json_candidate(body) then
    return body
  end

  local best_candidate = body
  local positions = {}
  for pos in body:gmatch("()[{%[]") do
    table.insert(positions, pos)
  end

  for _, pos in ipairs(positions) do
    local candidate = body:sub(pos)
    best_candidate = candidate
    if parse_json_candidate(candidate) then
      return candidate
    end
  end

  return best_candidate
end

local function parse_json_response_body(response_body)
  response_body = strip_to_json_payload(response_body)
  local decoded = parse_json_candidate(response_body)
  if not decoded then
    local snippet = (response_body or ""):gsub("%s+", " "):sub(1, 1000)
    return nil, "Failed to parse image API response JSON: " .. (snippet ~= "" and snippet or "<empty response>")
  end
  if decoded.code ~= nil and tonumber(decoded.code) ~= 0 and tonumber(decoded.code) ~= 200 then
    local err = type(decoded.error) == "table" and decoded.error.message or decoded.error
    return nil, tostring(decoded.msg or decoded.message or err or "Image API returned an error")
  end
  if type(decoded.error) == "table" and decoded.error.message then return nil, tostring(decoded.error.message) end
  if type(decoded.error) == "string" and decoded.error ~= "" then return nil, decoded.error end
  return decoded, nil
end

local function parse_response_body(response_body, stream)
  if stream then
    local decoded, err = decode_sse_response(response_body)
    if decoded then
      return decoded, nil
    end

    -- Some providers accept stream=true but still return the final JSON object.
    decoded = parse_json_response_body(response_body)
    if decoded then
      return decoded, nil
    end
    return nil, err
  end

  return parse_json_response_body(response_body)
end

M._parse_response_body = parse_response_body
M._strip_to_json_payload = strip_to_json_payload

local function finish_with_schedule(callback, response, err)
  vim.schedule(function()
    callback(response, err)
  end)
end

local function format_curl_error(code, stderr)
  stderr = (stderr or ""):gsub("%s+$", "")
  return string.format("HTTP request failed: curl exit %s%s", tostring(code), stderr ~= "" and (": " .. stderr) or "")
end

local function handle_job_lines(data, pending, on_line)
  if type(data) ~= "table" or #data == 0 then
    return pending
  end

  if #data == 1 then
    return pending .. tostring(data[1] or "")
  end

  data[1] = pending .. tostring(data[1] or "")
  for i = 1, #data - 1 do
    on_line(tostring(data[i] or ""))
  end
  return tostring(data[#data] or "")
end

---异步执行 curl，并在 stream=true 时增量解析 SSE 图片数据。
---
---Native MCP tool 支持 handler 返回 nil 后稍后 res:send()。这里避免
---vim.system(...):wait() 阻塞 Neovim，并且在 SSE 已收到足够图片数据或
---[DONE] 时主动结束 curl，避免 provider keep-alive 导致工具长期 pending。
---@param args string[] curl 参数（不含 curl 命令本身）
---@param request table
---@param callback fun(response: table|nil, error: string|nil)
---@param cleanup fun()|nil
local function run_curl_async(args, request, callback, cleanup)
  local body_lines = {}
  local stderr_lines = {}
  local pending_stdout = ""
  local pending_stderr = ""
  local http_status = nil
  local finished = false
  local job_id = nil

  local stream_items = {}
  local stream_error = nil
  local stream_event_lines = {}
  local expected_count = tonumber(request.params and request.params.n) or 1
  if expected_count < 1 then
    expected_count = 1
  end

  local function cleanup_once()
    if cleanup then
      pcall(cleanup)
      cleanup = nil
    end
  end

  local function finish(response, err, stop_job)
    if finished then
      return
    end
    finished = true
    cleanup_once()
    if stop_job and job_id then
      pcall(vim.fn.jobstop, job_id)
    end
    finish_with_schedule(callback, response, err)
  end

  local function finish_stream_success(stop_job)
    finish({
      status = http_status or 200,
      body = { data = stream_items },
      response_mode = "sse",
    }, nil, stop_job)
  end

  local function flush_stream_event()
    if #stream_event_lines == 0 or finished then
      return
    end

    local payload = table.concat(stream_event_lines, "\n")
    stream_event_lines = {}
    if payload == "" then
      return
    end
    if payload == "[DONE]" then
      if #stream_items > 0 then
        finish_stream_success(true)
      else
        finish(nil, stream_error or "Image stream completed without image data", true)
      end
      return
    end

    local ok, decoded = pcall(vim.json.decode, payload)
    if not ok or type(decoded) ~= "table" then
      stream_error = "Failed to parse SSE data JSON: " .. payload:sub(1, 500)
      return
    end

    local new_items = {}
    collect_image_items(decoded, new_items)
    for _, item in ipairs(new_items) do
      table.insert(stream_items, item)
    end

    local decoded_error = nil
    if type(decoded.error) == "table" then
      decoded_error = decoded.error.message or vim.inspect(decoded.error)
    elseif type(decoded.error) == "string" then
      decoded_error = decoded.error
    end
    if decoded_error then
      stream_error = decoded_error
      if #new_items == 0 then
        finish(nil, decoded_error, true)
        return
      end
    end

    if #stream_items >= expected_count then
      finish_stream_success(true)
    end
  end

  local function feed_stream_line(line)
    if finished then
      return
    end
    line = line:gsub("\r$", "")
    if line == "" then
      flush_stream_event()
    elseif line:sub(1, 5) == "data:" then
      table.insert(stream_event_lines, vim.trim(line:sub(6)))
    end
  end

  local function handle_stdout_line(line)
    line = line:gsub("\r$", "")
    local marker = line:match("^__HTTP_STATUS__(%d+)%s*$")
    if marker then
      http_status = tonumber(marker)
      return
    end

    table.insert(body_lines, line)
    if request.stream then
      feed_stream_line(line)
    end
  end

  local function handle_stderr_line(line)
    if line ~= "" then
      table.insert(stderr_lines, line)
    end
  end

  job_id = vim.fn.jobstart(vim.list_extend({ "curl" }, args), {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      pending_stdout = handle_job_lines(data, pending_stdout, handle_stdout_line)
    end,
    on_stderr = function(_, data)
      pending_stderr = handle_job_lines(data, pending_stderr, handle_stderr_line)
    end,
    on_exit = function(_, code)
      if pending_stdout ~= "" then
        handle_stdout_line(pending_stdout)
        pending_stdout = ""
      end
      if pending_stderr ~= "" then
        handle_stderr_line(pending_stderr)
        pending_stderr = ""
      end
      if request.stream then
        flush_stream_event()
      end
      if finished then
        return
      end

      local response_body = table.concat(body_lines, "\n")
      local extracted_status, extracted_body = extract_http_response(response_body)
      http_status = http_status or extracted_status
      if extracted_status then
        response_body = extracted_body
      end

      if code ~= 0 then
        return finish(nil, format_curl_error(code, table.concat(stderr_lines, "\n")), false)
      end
      if not http_status then
        return finish(nil, "HTTP request failed: missing HTTP status code", false)
      end
      if http_status < 200 or http_status >= 300 then
        local snippet = (response_body or ""):sub(1, 1000)
        return finish(nil, string.format("HTTP request failed with status %d: %s", http_status, snippet), false)
      end

      local decoded, err = parse_response_body(response_body, request.stream)
      if not decoded then
        return finish(nil, err, false)
      end

      return finish({
        status = http_status,
        body = decoded,
        response_mode = request.stream and "json_fallback" or "json",
      }, nil, false)
    end,
  })

  if type(job_id) ~= "number" or job_id <= 0 then
    cleanup_once()
    return finish_with_schedule(callback, nil, "Failed to start curl job")
  end
end

local function append_proxy_args(args, proxy)
  if type(proxy) == "function" then proxy = proxy() end
  if proxy then
    table.insert(args, "--proxy")
    table.insert(args, proxy)
  else
    table.insert(args, "--noproxy")
    table.insert(args, "*")
  end
end

---执行 JSON HTTP POST。
---@param request table
---@return table|nil response
---@return string|nil error
function M.post_json(request)
  local api_key, err = utils.resolve_api_key(request.provider)
  if not api_key then
    return nil, err
  end

  local ok, body = pcall(vim.json.encode, request.body or {})
  if not ok then
    return nil, "Failed to encode JSON request body: " .. tostring(body)
  end

  local body_file = os.tmpname()
  local f
  f, err = io.open(body_file, "w")
  if not f then
    return nil, "Failed to create temporary request body: " .. tostring(err)
  end
  f:write(body)
  f:close()

  local args = {
    "-sS",
    "-N",
    "--connect-timeout",
    "30",
    "--max-time",
    tostring(request.timeout or 300),
    "-X",
    request.method or "POST",
    "-H",
    "Authorization: Bearer " .. api_key,
    "-H",
    "Content-Type: application/json",
    "-H",
    request.stream and "Accept: text/event-stream" or "Accept: application/json",
    "-D",
    "-",
    "-o",
    "-",
    "-w",
    "\n__HTTP_STATUS__%{http_code}",
    "--data-binary",
    "@" .. body_file,
    request.endpoint,
  }
  append_proxy_args(args, request.proxy)

  local result = vim.system({ "curl", unpack(args) }, { text = true }):wait()
  os.remove(body_file)

  if result.code ~= 0 then
    return nil, format_curl_error(result.code, result.stderr)
  end

  local status, response_body = extract_http_response(result.stdout or "")
  if not status then
    return nil, "HTTP request failed: missing HTTP status code"
  end
  if status < 200 or status >= 300 then
    local snippet = (response_body or ""):sub(1, 1000)
    return nil, string.format("HTTP request failed with status %d: %s", status, snippet)
  end

  local decoded
  decoded, err = parse_response_body(response_body, request.stream)
  if not decoded then
    return nil, err
  end

  return {
    status = status,
    body = decoded,
    response_mode = request.stream and "sse_or_json" or "json",
  }, nil
end

local function stringify_multipart_value(value)
  if value == nil then
    return nil
  end
  if type(value) == "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    if ok then
      return encoded
    end
    return tostring(value)
  end
  return tostring(value)
end

---执行 multipart/form-data HTTP POST。
---@param request table
---@return table|nil response
---@return string|nil error
function M.post_json_async(request, callback)
  local api_key, err = utils.resolve_api_key(request.provider)
  if not api_key then
    return finish_with_schedule(callback, nil, err)
  end

  local ok, body = pcall(vim.json.encode, request.body or {})
  if not ok then
    return finish_with_schedule(callback, nil, "Failed to encode JSON request body: " .. tostring(body))
  end

  local body_file = os.tmpname()
  local f
  f, err = io.open(body_file, "w")
  if not f then
    return finish_with_schedule(callback, nil, "Failed to create temporary request body: " .. tostring(err))
  end
  f:write(body)
  f:close()

  local args = {
    "-sS",
    "-N",
    "--connect-timeout",
    "30",
    "--max-time",
    tostring(request.timeout or 300),
    "-X",
    request.method or "POST",
    "-H",
    "Authorization: Bearer " .. api_key,
    "-H",
    "Content-Type: application/json",
    "-H",
    request.stream and "Accept: text/event-stream" or "Accept: application/json",
    "-D",
    "-",
    "-o",
    "-",
    "-w",
    "\n__HTTP_STATUS__%{http_code}",
    "--data-binary",
    "@" .. body_file,
    request.endpoint,
  }
  append_proxy_args(args, request.proxy)

  return run_curl_async(args, request, callback, function()
    os.remove(body_file)
  end)
end

function M.post_multipart(request)
  local api_key, err = utils.resolve_api_key(request.provider)
  if not api_key then
    return nil, err
  end

  local multipart = request.multipart or {}
  local args = {
    "-sS",
    "-N",
    "--connect-timeout",
    "30",
    "--max-time",
    tostring(request.timeout or 300),
    "-X",
    request.method or "POST",
    "-H",
    "Authorization: Bearer " .. api_key,
    "-H",
    request.stream and "Accept: text/event-stream" or "Accept: application/json",
    "-D",
    "-",
    "-o",
    "-",
    "-w",
    "\n__HTTP_STATUS__%{http_code}",
  }

  for key, value in pairs(multipart.fields or {}) do
    local field_value = stringify_multipart_value(value)
    if type(key) == "string" and key ~= "" and field_value ~= nil then
      table.insert(args, "--form-string")
      table.insert(args, key .. "=" .. field_value)
    end
  end

  local image_field = multipart.image_field or "image[]"
  for _, image_path in ipairs(multipart.images or {}) do
    table.insert(args, "-F")
    table.insert(args, image_field .. "=@" .. image_path)
  end

  if multipart.mask and multipart.mask ~= "" then
    table.insert(args, "-F")
    table.insert(args, (multipart.mask_field or "mask") .. "=@" .. multipart.mask)
  end

  append_proxy_args(args, request.proxy)
  table.insert(args, request.endpoint)

  local result = vim.system({ "curl", unpack(args) }, { text = true }):wait()

  if result.code ~= 0 then
    return nil, format_curl_error(result.code, result.stderr)
  end

  local status, response_body = extract_http_response(result.stdout or "")
  if not status then
    return nil, "HTTP request failed: missing HTTP status code"
  end
  if status < 200 or status >= 300 then
    local snippet = (response_body or ""):sub(1, 1000)
    return nil, string.format("HTTP request failed with status %d: %s", status, snippet)
  end

  local decoded
  decoded, err = parse_response_body(response_body, request.stream)
  if not decoded then
    return nil, err
  end

  return {
    status = status,
    body = decoded,
    response_mode = request.stream and "sse_or_json" or "json",
  }, nil
end

function M.post_multipart_async(request, callback)
  local api_key, err = utils.resolve_api_key(request.provider)
  if not api_key then
    return finish_with_schedule(callback, nil, err)
  end

  local multipart = request.multipart or {}
  local args = {
    "-sS",
    "-N",
    "--connect-timeout",
    "30",
    "--max-time",
    tostring(request.timeout or 300),
    "-X",
    request.method or "POST",
    "-H",
    "Authorization: Bearer " .. api_key,
    "-H",
    request.stream and "Accept: text/event-stream" or "Accept: application/json",
    "-D",
    "-",
    "-o",
    "-",
    "-w",
    "\n__HTTP_STATUS__%{http_code}",
  }

  for key, value in pairs(multipart.fields or {}) do
    local field_value = stringify_multipart_value(value)
    if type(key) == "string" and key ~= "" and field_value ~= nil then
      table.insert(args, "--form-string")
      table.insert(args, key .. "=" .. field_value)
    end
  end

  local image_field = multipart.image_field or "image[]"
  for _, image_path in ipairs(multipart.images or {}) do
    table.insert(args, "-F")
    table.insert(args, image_field .. "=@" .. image_path)
  end

  if multipart.mask and multipart.mask ~= "" then
    table.insert(args, "-F")
    table.insert(args, (multipart.mask_field or "mask") .. "=@" .. multipart.mask)
  end

  append_proxy_args(args, request.proxy)
  table.insert(args, request.endpoint)
  return run_curl_async(args, request, callback)
end

local function detect_response_mode(response)
  if response and response.response_mode then
    return response.response_mode
  end
  return "json"
end

local function download_url_file(url, output_path, proxy)
  if type(url) ~= "string" or url == "" then
    return nil, "image url is empty"
  end

  local args = {
    "curl",
    "-L",
    "-sS",
    "--connect-timeout",
    "30",
    "--max-time",
    "300",
    "-o",
    output_path,
  }
  append_proxy_args(args, proxy)
  table.insert(args, url)
  local result = vim.system(args, { text = true }):wait()

  if result.code ~= 0 then
    local stderr = (result.stderr or ""):gsub("%s+$", "")
    return nil, string.format("Failed to download image URL: curl exit %s%s", tostring(result.code), stderr ~= "" and (": " .. stderr) or "")
  end

  local stat = vim.uv.fs_stat(output_path)
  if not stat or not stat.size or stat.size <= 0 then
    return nil, "Downloaded image URL produced an empty file"
  end

  return stat.size, nil
end

local function download_url_file_async(url, output_path, proxy, callback)
  if type(url) ~= "string" or url == "" then
    return finish_with_schedule(callback, nil, "image url is empty")
  end

  local stderr_lines = {}
  local pending_stderr = ""
  local finished = false

  local function finish(bytes, err)
    if finished then
      return
    end
    finished = true
    finish_with_schedule(callback, bytes, err)
  end

  local function handle_stderr_line(line)
    if line ~= "" then
      table.insert(stderr_lines, line)
    end
  end

  local args = {
    "curl",
    "-L",
    "-sS",
    "--connect-timeout",
    "30",
    "--max-time",
    "300",
    "-o",
    output_path,
  }
  append_proxy_args(args, proxy)
  table.insert(args, url)
  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stderr = function(_, data)
      pending_stderr = handle_job_lines(data, pending_stderr, handle_stderr_line)
    end,
    on_exit = function(_, code)
      if pending_stderr ~= "" then
        handle_stderr_line(pending_stderr)
        pending_stderr = ""
      end
      if code ~= 0 then
        return finish(nil, "Failed to download image URL: " .. format_curl_error(code, table.concat(stderr_lines, "\n")))
      end

      local stat = vim.uv.fs_stat(output_path)
      if not stat or not stat.size or stat.size <= 0 then
        return finish(nil, "Downloaded image URL produced an empty file")
      end
      return finish(stat.size, nil)
    end,
  })

  if type(job_id) ~= "number" or job_id <= 0 then
    return finish_with_schedule(callback, nil, "Failed to start image URL download job")
  end
end

local function extract_response_items(body)
  if type(body) ~= "table" then return nil end
  if body.code ~= nil and tonumber(body.code) ~= 0 and tonumber(body.code) ~= 200 then
    local provider_error = type(body.error) == "table" and body.error.message or body.error
    return nil, tostring(body.msg or body.message or provider_error or "Image API returned an error")
  end
  local payload = body
  if type(body.data) == "table" and #body.data == 0 and not body.data.b64_json and not body.data.url then
    payload = body.data
  end
  local items = payload.data or payload.images or payload.results
  if type(items) == "table" and #items > 0 then return items end
  if type(items) == "table" and (items.b64_json or items.url) then return { items } end
  if type(payload) == "table" and #payload > 0 then return payload end
  if type(payload) == "table" and (payload.b64_json or payload.url) then return { payload } end
  return nil
end

M._extract_response_items = extract_response_items

---保存 OpenAI-compatible 图片响应。
---@param request table
---@param response table
---@return table|nil result
---@return string|nil error
function M.save_image_response(request, response)
  local params = request.params or {}
  local data, response_err = extract_response_items(response and response.body)
  if response_err then return nil, response_err end
  if type(data) ~= "table" or #data == 0 then
    return nil, "Image API response contains no image data"
  end

  local ok, err = utils.ensure_output_dir(params.output_dir)
  if not ok then
    return nil, err
  end

  local files = {}
  local urls = {}
  local output_format = utils.normalize_output_format(params.output_format)

  for i, item in ipairs(data) do
    if type(item) == "table" and type(item.b64_json) == "string" and item.b64_json ~= "" then
      local path = utils.make_output_path(params.output_dir, params.filename_prefix, output_format, i)
      local bytes
      bytes, err = utils.save_base64_file(item.b64_json, path)
      if not bytes then
        return nil, err
      end
      table.insert(files, {
        path = path,
        bytes = bytes,
        requested_format = output_format,
      })
    elseif type(item) == "table" and type(item.url) == "string" and item.url ~= "" then
      local path = utils.make_output_path(params.output_dir, params.filename_prefix, output_format, i)
      local bytes
      bytes, err = download_url_file(item.url, path, request.proxy)
      if not bytes then
        return nil, err
      end
      table.insert(files, {
        path = path,
        bytes = bytes,
        requested_format = output_format,
      })
      table.insert(urls, item.url)
    end
  end

  if #files == 0 and #urls == 0 then
    return nil, "Image API response contains no b64_json or url entries"
  end

  return output_metadata.finalize_result({
    provider = request.provider.name,
    model = params.model,
    requested_size = params.requested_size,
    quality = params.quality,
    output_format = output_format,
    response_format = params.response_format,
    response_mode = detect_response_mode(response),
    count = #data,
    files = files,
    urls = urls,
  }), nil
end

function M.save_image_response_async(request, response, callback)
  local params = request.params or {}
  local data, response_err = extract_response_items(response and response.body)
  if response_err then return finish_with_schedule(callback, nil, response_err) end
  if type(data) ~= "table" or #data == 0 then
    return finish_with_schedule(callback, nil, "Image API response contains no image data")
  end

  local ok, err = utils.ensure_output_dir(params.output_dir)
  if not ok then
    return finish_with_schedule(callback, nil, err)
  end

  local files = {}
  local urls = {}
  local output_format = utils.normalize_output_format(params.output_format)
  local index = 1

  local function finish(result, finish_err)
    return callback(result, finish_err)
  end

  local function process_next()
    while index <= #data do
      local item = data[index]
      local current_index = index
      index = index + 1

      if type(item) == "table" and type(item.b64_json) == "string" and item.b64_json ~= "" then
        local path = utils.make_output_path(params.output_dir, params.filename_prefix, output_format, current_index)
        local bytes
        bytes, err = utils.save_base64_file(item.b64_json, path)
        if not bytes then
          return finish(nil, err)
        end
        table.insert(files, {
          path = path,
          bytes = bytes,
          requested_format = output_format,
        })
      elseif type(item) == "table" and type(item.url) == "string" and item.url ~= "" then
        local path = utils.make_output_path(params.output_dir, params.filename_prefix, output_format, current_index)
        return download_url_file_async(item.url, path, request.proxy, function(bytes, download_err)
          if not bytes then
            return finish(nil, download_err)
          end
          table.insert(files, {
            path = path,
            bytes = bytes,
            requested_format = output_format,
          })
          table.insert(urls, item.url)
          return process_next()
        end)
      end
    end

    if #files == 0 and #urls == 0 then
      return finish(nil, "Image API response contains no b64_json or url entries")
    end

    return finish(output_metadata.finalize_result({
      provider = request.provider.name,
      model = params.model,
      requested_size = params.requested_size,
      quality = params.quality,
      output_format = output_format,
      response_format = params.response_format,
      response_mode = detect_response_mode(response),
      count = #data,
      files = files,
      urls = urls,
    }), nil)
  end

  return process_next()
end

---准备文本生图请求参数。
---@param provider table
---@param params table|nil
---@return table|nil request
---@return string|nil error
function M.generate(provider, params)
  local request, err = prepare_common(provider, params, "generations")
  if not request then
    return nil, err
  end

  if not request.params.prompt or vim.trim(request.params.prompt) == "" then
    return nil, "Missing required parameter: prompt"
  end

  request.method = "POST"
  request.content_type = "application/json"
  request.stream = request.params.stream
  request.body = build_json_body(request.params)
  return request, nil
end

---执行文本生图请求并保存结果。
---@param provider table
---@param params table|nil
---@return table|nil result
---@return string|nil error
function M.generate_image(provider, params)
  local request, err = M.generate(provider, params)
  if not request then
    return nil, err
  end

  local response
  response, err = M.post_json(request)
  if not response then
    return nil, err
  end

  return M.save_image_response(request, response)
end

---异步执行文本生图请求并保存结果。
---@param provider table
---@param params table|nil
---@param callback fun(result: table|nil, error: string|nil)
function M.generate_image_async(provider, params, callback)
  local request, err = M.generate(provider, params)
  if not request then
    return finish_with_schedule(callback, nil, err)
  end

  return M.post_json_async(request, function(response, response_err)
    if not response then
      return callback(nil, response_err)
    end

    local result
    result, err = M.save_image_response_async(request, response, callback)
    if result ~= nil or err ~= nil then
      return callback(result, err)
    end
  end)
end

---准备图片编辑请求参数。
---@param provider table
---@param params table|nil
---@return table|nil request
---@return string|nil error
function M.edit(provider, params)
  local request, err = prepare_common(provider, params, "edits")
  if not request then
    return nil, err
  end

  if not request.params.prompt or vim.trim(request.params.prompt) == "" then
    return nil, "Missing required parameter: prompt"
  end
  if type(request.params.image_paths) ~= "table" or #request.params.image_paths == 0 then
    return nil, "Missing required parameter: image_paths must contain at least one image path"
  end

  local normalized_images = {}
  for i, path in ipairs(request.params.image_paths) do
    local normalized
    normalized, err = utils.validate_file(path, "image_paths[" .. i .. "]")
    if not normalized then
      return nil, err
    end
    table.insert(normalized_images, normalized)
  end
  request.params.image_paths = normalized_images

  if request.params.mask_path and request.params.mask_path ~= "" then
    local normalized_mask
    normalized_mask, err = utils.validate_file(request.params.mask_path, "mask_path")
    if not normalized_mask then
      return nil, err
    end
    request.params.mask_path = normalized_mask
  end

  request.method = "POST"
  request.content_type = "multipart/form-data"
  request.stream = request.params.stream
  request.multipart = {
    image_field = (provider.multipart and provider.multipart.image_field) or "image[]",
    mask_field = (provider.multipart and provider.multipart.mask_field) or "mask",
    images = request.params.image_paths,
    mask = request.params.mask_path,
    fields = build_json_body(request.params),
  }
  return request, nil
end

---执行图片编辑请求并保存结果。
---@param provider table
---@param params table|nil
---@return table|nil result
---@return string|nil error
function M.edit_image(provider, params)
  local request, err = M.edit(provider, params)
  if not request then
    return nil, err
  end

  local response
  response, err = M.post_multipart(request)
  if not response then
    return nil, err
  end

  return M.save_image_response(request, response)
end

---异步执行图片编辑请求并保存结果。
---@param provider table
---@param params table|nil
---@param callback fun(result: table|nil, error: string|nil)
function M.edit_image_async(provider, params, callback)
  local request, err = M.edit(provider, params)
  if not request then
    return finish_with_schedule(callback, nil, err)
  end

  return M.post_multipart_async(request, function(response, response_err)
    if not response then
      return callback(nil, response_err)
    end

    local result
    result, err = M.save_image_response_async(request, response, callback)
    if result ~= nil or err ~= nil then
      return callback(result, err)
    end
  end)
end

return M
