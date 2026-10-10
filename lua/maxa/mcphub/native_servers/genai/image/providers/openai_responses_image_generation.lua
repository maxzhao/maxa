-- filepath: lua/maxa/mcphub/native_servers/genai/image/providers/openai_responses_image_generation.lua
-- Responses API 图片 tool provider driver
--
-- 该 driver 通过 /v1/responses + image_generation server-side tool 接入图片生成/编辑。
-- 结果继续落本地文件，不把 base64 注入 chat。

local adapter_utils = require("maxa.mcphub.native_servers.genai.image.adapter")
local image = require("maxa.mcphub.native_servers.genai.image")
local output_metadata = require("maxa.mcphub.native_servers.genai.image.output_metadata")
local requested_size = require("maxa.mcphub.native_servers.genai.image.requested_size")
local utils = require("maxa.mcphub.native_servers.genai.image.utils")

local M = {}

local DEFAULT_REQUEST_TIMEOUT = 900
local DEFAULT_KEEPALIVE_INTERVAL = 30
local DEFAULT_TEXT_MODEL = "gpt-5.5"
local DEFAULT_IMAGE_MODEL = "gpt-image-2"
local DEFAULT_QUALITY = "auto"
local DEFAULT_MAX_RETRIES = 3
local DEFAULT_RETRY_DELAY_MS = 15000
local DEFAULT_INPUT_IMAGE_DETAIL = "original"

local allowed_input_image_details = {
  low = true,
  high = true,
  original = true,
  auto = true,
}

local allowed_output_formats = {
  png = true,
  jpeg = true,
  webp = true,
}

local allowed_tool_fields = {}

local function finish_with_schedule(callback, response, err)
  vim.schedule(function()
    callback(response, err)
  end)
end

local function resolve_provider_settings(provider)
  return adapter_utils.resolve_provider_settings(provider)
end

local function validate_provider(provider, _)
  if not provider then
    return nil, "image provider is required"
  end
  if provider.driver ~= "openai_responses_image_generation" then
    return nil,
      string.format(
        "Provider '%s' uses driver '%s', expected 'openai_responses_image_generation'",
        provider.name or "<unknown>",
        tostring(provider.driver)
      )
  end
  local settings, err = resolve_provider_settings(provider)
  if not settings then
    return nil, err
  end
  return true, nil
end

local rejected_passthrough_fields = {
  response_format = "Responses image_generation results are always saved locally; do not pass response_format",
  n = "Responses image_generation only supports one image per call; omit n and use separate calls for candidates",
  moderation = "codex image mode fixes image_generation moderation to low; do not pass moderation",
  tool_choice = "codex image mode fixes Responses tool_choice to image_generation; do not pass tool_choice",
  reasoning = "codex image mode fixes Responses reasoning effort to none; do not pass reasoning",
  store = "codex image mode fixes Responses store=false; do not pass store",
  instructions = "codex image mode builds provider prompt-rewrite protection; do not pass instructions",
}

local rejected_extra_fields = {
  model = "Provide the image_generation tool model through top-level model, not extra.model",
  response_format = "Responses image_generation does not support response_format in tool fields",
  n = "Responses image_generation rejects n; use separate calls for candidates",
  moderation = "codex image mode fixes image_generation moderation to low; do not pass moderation",
  tool_choice = "codex image mode fixes Responses tool_choice to image_generation; do not pass extra.tool_choice",
  reasoning = "codex image mode fixes Responses reasoning effort to none; do not pass extra.reasoning",
  store = "codex image mode fixes Responses store=false; do not pass extra.store",
  instructions = "codex image mode builds provider prompt-rewrite protection; do not pass extra.instructions",
  input_image = "Provide reference images through image_edit image_paths, not extra.input_image",
  mask = "Use mask_path for local masks; do not pass old Images API mask fields",
  input_fidelity = "Responses image_generation through codex image mode does not support input_fidelity",
  style = "Responses image_generation through codex image mode does not support style",
}

local function is_present(value)
  return not image.is_absent(value)
end

local function trim_string(value)
  return requested_size.trim_string(value)
end

local function normalize_input_image_detail(params)
  local detail = trim_string(params.detail)
  if detail == nil and type(params.extra) == "table" then
    detail = trim_string(params.extra.detail)
  end
  if detail == nil then
    detail = DEFAULT_INPUT_IMAGE_DETAIL
  end
  if not allowed_input_image_details[detail] then
    return nil, "codex image mode input_image detail must be one of low, high, original, auto"
  end
  params.detail = detail
  return true, nil
end

local function normalize_responses_params(params)
  local normalized_size, err = requested_size.apply(params, {
    provider_label = "codex image mode",
  })
  if not normalized_size then
    return nil, err
  end

  params.text_model = trim_string(params.text_model)
    or (type(params.extra) == "table" and trim_string(params.extra.text_model) or nil)
    or DEFAULT_TEXT_MODEL
  if params.text_model:match("^gpt%-image%-") then
    return nil,
      "codex image mode uses text_model for the outer Responses host model; pass GPT Image models through top-level model instead"
  end
  params.model = trim_string(params.model) or DEFAULT_IMAGE_MODEL

  local quality = trim_string(params.quality)
    or (type(params.extra) == "table" and trim_string(params.extra.quality) or nil)
  if quality and quality ~= DEFAULT_QUALITY then
    return nil, "codex image mode fixes Responses image_generation quality to auto; omit quality or pass quality=auto"
  end
  params.quality = DEFAULT_QUALITY

  local detail_ok, detail_err = normalize_input_image_detail(params)
  if not detail_ok then
    return nil, detail_err
  end

  params.stream = true
  params.store = false
  params.reasoning_effort = "none"

  return true, nil
end

local function validate_responses_params(params)
  params = params or {}

  local valid_size, size_err = requested_size.validate_params(params, { provider_label = "codex image mode" })
  if not valid_size then
    return nil, size_err
  end

  for field, message in pairs(rejected_passthrough_fields) do
    if is_present(params[field]) then
      return nil, message
    end
  end

  if is_present(params.background) and tostring(params.background) == "transparent" then
    return nil,
      "codex image mode currently uses gpt-image-2, which rejects background=transparent; use auto/opaque or omit background"
  end

  if type(params.extra) == "table" then
    for field, message in pairs(rejected_extra_fields) do
      if is_present(params.extra[field]) then
        return nil, message
      end
    end
    if is_present(params.extra.background) and tostring(params.extra.background) == "transparent" then
      return nil,
        "codex image mode currently uses gpt-image-2, which rejects background=transparent; use auto/opaque or omit background"
    end
  end

  return true, nil
end

local function prepare_common(provider, params, endpoint_key)
  local ok, err = validate_provider(provider, endpoint_key)
  if not ok then
    return nil, err
  end

  ok, err = validate_responses_params(params)
  if not ok then
    return nil, err
  end

  local settings
  settings, err = resolve_provider_settings(provider)
  if not settings then
    return nil, err
  end

  local merged = image.build_request_params(provider, params)
  local normalized
  normalized, err = normalize_responses_params(merged)
  if not normalized then
    return nil, err
  end
  merged.provider = merged.provider or provider.name
  merged.output_dir = merged.output_dir or provider.output_dir

  local output_dir
  output_dir, err = utils.resolve_output_dir(merged.output_dir)
  if not output_dir then
    return nil, err
  end
  merged.output_dir = output_dir

  return {
    provider = provider,
    params = merged,
    endpoint = settings.url,
    adapter = settings.adapter,
    api_key = settings.api_key,
    proxy = settings.proxy,
    timeout = merged.timeout,
    keepalive_interval = merged.keepalive_interval or merged.keepalive_time,
  },
    nil
end

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

local function extract_http_response(raw)
  local status = nil
  local marker = raw:match("\n__HTTP_STATUS__(%d+)%s*$") or raw:match("__HTTP_STATUS__(%d+)%s*$")
  if marker then
    status = tonumber(marker)
    raw = raw:gsub("\n?__HTTP_STATUS__%d+%s*$", "")
  end

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

local function get_image_base64_value(source)
  if type(source) ~= "table" then
    return nil
  end

  for _, key in ipairs({ "b64_json", "base64", "image", "data" }) do
    local value = source[key]
    if type(value) == "string" and value ~= "" then
      return value
    end
  end

  return nil
end

local function get_image_url_value(source)
  if type(source) ~= "table" then
    return nil
  end

  local value = source.url
  if type(value) == "string" and value ~= "" then
    return value
  end

  return nil
end

local function insert_image_generation_item(out, item)
  local key
  if type(item.b64_json) == "string" and item.b64_json ~= "" then
    key = "b64:" .. item.b64_json
  elseif type(item.url) == "string" and item.url ~= "" then
    key = "url:" .. item.url
  else
    return
  end

  out._seen = out._seen or {}
  if out._seen[key] then
    return
  end

  out._seen[key] = true
  table.insert(out, item)
end

local function is_partial_image_generation_event(value)
  if type(value) ~= "table" then
    return false
  end

  local event_type = type(value.type) == "string" and value.type or ""
  if event_type:match("partial") then
    return true
  end

  return value.partial_image_index ~= nil or value.partial_image_b64 ~= nil
end

local function is_direct_image_generation_payload(value)
  if type(value) ~= "table" then
    return false
  end

  local event_type = type(value.type) == "string" and value.type or ""
  return event_type == "" or event_type == "image_generation_call"
end

local function collect_image_generation_items(value, out)
  if type(value) ~= "table" then
    return
  end

  -- Streaming Responses can emit intermediate/partial image payloads before the
  -- final image_generation_call.result. Those previews are not final outputs and
  -- must not be saved as separate generated images.
  if is_partial_image_generation_event(value) then
    return
  end

  if is_direct_image_generation_payload(value) then
    if type(value.b64_json) == "string" and value.b64_json ~= "" then
      insert_image_generation_item(out, {
        b64_json = value.b64_json,
        revised_prompt = value.revised_prompt,
      })
    end
    if type(value.url) == "string" and value.url ~= "" then
      insert_image_generation_item(out, { url = value.url, revised_prompt = value.revised_prompt })
    end
  end

  if value.type == "image_generation_call" then
    if type(value.result) == "string" and value.result ~= "" then
      insert_image_generation_item(out, {
        b64_json = value.result,
        revised_prompt = value.revised_prompt,
      })
    elseif type(value.result) == "table" then
      local b64 = get_image_base64_value(value.result)
      if b64 then
        insert_image_generation_item(out, {
          b64_json = b64,
          revised_prompt = value.revised_prompt,
        })
      end

      local url = get_image_url_value(value.result)
      if url then
        insert_image_generation_item(out, {
          url = url,
          revised_prompt = value.revised_prompt,
        })
      end
    end
  end

  if type(value.data) == "table" then
    for _, item in ipairs(value.data) do
      collect_image_generation_items(item, out)
    end
  end

  if type(value.response) == "table" then
    collect_image_generation_items(value.response, out)
  end

  if type(value.body) == "table" then
    collect_image_generation_items(value.body, out)
  end

  if type(value.output) == "table" then
    for _, item in ipairs(value.output) do
      collect_image_generation_items(item, out)
    end
  end

  if type(value.item) == "table" then
    collect_image_generation_items(value.item, out)
  end
end

local function extract_tool_usage(value)
  if type(value) ~= "table" then
    return nil
  end

  if type(value.tool_usage) == "table" then
    if type(value.tool_usage.image_gen) == "table" then
      return value.tool_usage.image_gen
    end
    return value.tool_usage
  end

  if type(value.response) == "table" then
    local nested = extract_tool_usage(value.response)
    if nested then
      return nested
    end
  end

  if type(value.body) == "table" then
    local nested = extract_tool_usage(value.body)
    if nested then
      return nested
    end
  end

  if type(value.data) == "table" then
    for _, item in ipairs(value.data) do
      local nested = extract_tool_usage(item)
      if nested then
        return nested
      end
    end
  end

  if type(value.output) == "table" then
    for _, item in ipairs(value.output) do
      local nested = extract_tool_usage(item)
      if nested then
        return nested
      end
    end
  end

  return nil
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
      collect_image_generation_items(decoded, items)
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

local function parse_json_response_body(response_body)
  response_body = strip_to_json_payload(response_body)
  local decoded = parse_json_candidate(response_body)
  if not decoded then
    local snippet = (response_body or ""):gsub("%s+", " "):sub(1, 1000)
    return nil, "Failed to parse image API response JSON: " .. (snippet ~= "" and snippet or "<empty response>")
  end
  return decoded, nil
end

local function parse_response_body(response_body, stream)
  if stream then
    local decoded, err = decode_sse_response(response_body)
    if decoded then
      return decoded, nil
    end

    if
      tostring(response_body or ""):match("%f[%w]data%s*:") or tostring(response_body or ""):match("%f[%w]event%s*:")
    then
      return nil, err
    end

    decoded = parse_json_response_body(response_body)
    if decoded then
      return decoded, nil
    end
    return nil, err
  end

  return parse_json_response_body(response_body)
end

M._extract_http_response = extract_http_response
M._parse_response_body = parse_response_body
M._decode_sse_response = decode_sse_response
M._collect_image_generation_items = collect_image_generation_items
M._extract_tool_usage = extract_tool_usage

local function format_curl_error(code, stderr, request)
  stderr = (stderr or ""):gsub("%s+$", "")
  local base =
    string.format("HTTP request failed: curl exit %s%s", tostring(code), stderr ~= "" and (": " .. stderr) or "")

  local lower = stderr:lower()
  local is_reset = tostring(code) == "56"
    or lower:match("connection reset")
    or lower:match("recv failure")
    or lower:match("stream .*not closed cleanly")
    or lower:match("internal_error")

  if is_reset and request and request.body and request.body.tools then
    return base
      .. "\nDiagnosis: Responses image_generation stream was interrupted by the upstream gateway. "
      .. "For image_edit this can be a safety/moderation abort that closes the stream before an explicit moderation error is delivered, or a provider gateway failure. "
      .. "If the prompt includes sensitive/sexualized wording, rewrite the prompt to a neutral non-sexual edit and retry once. "
      .. "If a neutral prompt on the same input image still resets or reports safety violations, treat the input image as the likely trigger and stop using this image for edit; use a safer source image or regenerate from text instead."
  end

  return base
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

local function run_curl_async(args, request, callback)
  local stdout_lines = {}
  local stderr_lines = {}
  local pending_stdout = ""
  local pending_stderr = ""
  local http_status = nil
  local finished = false

  local function finish(response, err)
    if finished then
      return
    end
    finished = true
    finish_with_schedule(callback, response, err)
  end

  local function handle_stdout_line(line)
    line = line:gsub("\r$", "")
    local marker = line:match("^__HTTP_STATUS__(%d+)%s*$")
    if marker then
      http_status = tonumber(marker)
      return
    end
    table.insert(stdout_lines, line)
  end

  local function handle_stderr_line(line)
    if line ~= "" then
      table.insert(stderr_lines, line)
    end
  end

  local job_id = vim.fn.jobstart(vim.list_extend({ "curl" }, args), {
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

      if finished then
        return
      end

      local response_body = table.concat(stdout_lines, "\n")
      local extracted_status, extracted_body = extract_http_response(response_body)
      http_status = http_status or extracted_status
      if extracted_status then
        response_body = extracted_body
      end

      if code ~= 0 then
        return finish(nil, format_curl_error(code, table.concat(stderr_lines, "\n"), request))
      end
      if not http_status then
        return finish(nil, "HTTP request failed: missing HTTP status code")
      end
      if http_status < 200 or http_status >= 300 then
        local snippet = (response_body or ""):sub(1, 1000)
        return finish(nil, string.format("HTTP request failed with status %d: %s", http_status, snippet))
      end

      local decoded, err = parse_response_body(response_body, true)
      if not decoded then
        return finish(nil, err)
      end

      return finish({
        status = http_status,
        body = decoded,
        response_mode = "sse_or_json",
      }, nil)
    end,
  })

  if type(job_id) ~= "number" or job_id <= 0 then
    return finish_with_schedule(callback, nil, "Failed to start curl job")
  end
end

local function resolve_optional_api_key(request)
  local api_key = request and request.api_key
  if api_key == vim.NIL or api_key == "" then
    api_key = nil
  end
  return api_key, nil
end

local function add_optional_auth_header(args, api_key)
  if type(api_key) == "string" and api_key ~= "" then
    table.insert(args, "-H")
    table.insert(args, "Authorization: Bearer " .. api_key)
  end
end

local function append_proxy(args, proxy)
  if type(proxy) == "function" then proxy = proxy() end
  if proxy then
    table.insert(args, "--proxy")
    table.insert(args, proxy)
  else
    table.insert(args, "--noproxy")
    table.insert(args, "*")
  end
end

local function append_endpoint(args, request)
  add_optional_auth_header(args, request.api_key)
  append_proxy(args, request.proxy)
  table.insert(args, request.endpoint)
end

local function resolve_request_timeout(request)
  local timeout = tonumber(request and request.timeout)
  if not timeout and request and type(request.params) == "table" then
    timeout = tonumber(request.params.timeout)
  end
  if timeout and timeout > 0 then
    return timeout
  end
  if request and request.stream then
    return DEFAULT_REQUEST_TIMEOUT
  end
  return 300
end

local function resolve_keepalive_interval(request)
  local interval = tonumber(request and request.keepalive_interval)
  if not interval and request and type(request.params) == "table" then
    interval = tonumber(request.params.keepalive_interval or request.params.keepalive_time)
  end
  if interval and interval > 0 then
    return interval
  end
  return DEFAULT_KEEPALIVE_INTERVAL
end

local function build_json_curl_args(body_file, request)
  local args = {
    "-sS",
    "-N",
    "--http1.1",
    "--connect-timeout",
    "30",
    "--keepalive-time",
    tostring(resolve_keepalive_interval(request)),
    "--max-time",
    tostring(resolve_request_timeout(request)),
    "-X",
    request.method or "POST",
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
  }
  append_endpoint(args, request)
  return args
end

M._build_json_curl_args = build_json_curl_args

local function post_json_request(request)
  local api_key, auth_err = resolve_optional_api_key(request)
  if auth_err then
    return nil, auth_err
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

  local args = build_json_curl_args(body_file, request)

  local result = vim.system({ "curl", unpack(args) }, { text = true }):wait()
  os.remove(body_file)

  if result.code ~= 0 then
    return nil, format_curl_error(result.code, result.stderr, request)
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
  },
    nil
end

local function resolve_retry_settings(request)
  local params = request and request.params or {}
  local max_retries = tonumber(params.max_retries)
  local retry_delay_ms = tonumber(params.retry_delay_ms)
  if type(params.extra) == "table" then
    max_retries = max_retries or tonumber(params.extra.max_retries)
    retry_delay_ms = retry_delay_ms or tonumber(params.extra.retry_delay_ms)
  end
  if max_retries == nil then
    max_retries = DEFAULT_MAX_RETRIES
  end
  if retry_delay_ms == nil then
    retry_delay_ms = DEFAULT_RETRY_DELAY_MS
  end
  max_retries = math.max(0, math.floor(max_retries))
  retry_delay_ms = math.max(0, math.floor(retry_delay_ms))
  return max_retries, retry_delay_ms
end

local function is_retryable_error(err)
  local text = tostring(err or ""):lower()
  local patterns = {
    "http request failed with status 429",
    "http request failed with status 502",
    "http request failed with status 503",
    "http request failed with status 504",
    "http request failed with status 524",
    "timeout",
    "rate limit",
    "too many requests",
    "no available account",
    "account pool busy",
    "please retry later",
    "temporarily unavailable",
    "overloaded",
    "fetch failed",
    "socket hang up",
    "econnreset",
    "terminated",
    "no image_generation_call result",
    "no image result",
    "curl exit 56",
    "connection reset",
    "recv failure",
    "stream was interrupted",
    "internal_error",
  }
  for _, pattern in ipairs(patterns) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function is_fatal_error(err)
  local text = tostring(err or ""):lower()
  if is_retryable_error(text) then
    return false
  end
  local patterns = {
    "http request failed with status 400",
    "http request failed with status 401",
    "http request failed with status 403",
    "http request failed with status 404",
    "http request failed with status 422",
    "unauthorized",
    "forbidden",
    "invalid api key",
    "incorrect api key",
    "missing api key",
    "api key is missing",
    "invalid parameter",
    "invalid_request",
    "unsupported",
    "model not found",
    "content policy",
    "safety policy",
    "moderation",
    "moderation_blocked",
  }
  for _, pattern in ipairs(patterns) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function format_retry_error(err, retries)
  if retries and retries > 0 then
    return string.format("%s (after %d retries)", tostring(err), retries)
  end
  return err
end

local function sleep_ms(ms)
  if ms and ms > 0 then
    vim.wait(ms)
  end
end

local function retry_post_json_request(request)
  local max_retries, retry_delay_ms = resolve_retry_settings(request)
  local retries = 0
  while true do
    local response, err = post_json_request(request)
    if response then
      if retries > 0 then
        response.retries = retries
      end
      return response, nil
    end
    if is_fatal_error(err) or not is_retryable_error(err) or retries >= max_retries then
      return nil, format_retry_error(err, retries)
    end
    retries = retries + 1
    sleep_ms(retry_delay_ms)
  end
end

local function retry_post_json_request_async(request, callback)
  local max_retries, retry_delay_ms = resolve_retry_settings(request)
  local retries = 0

  local function attempt()
    M.post_json_async(request, function(response, err)
      if response then
        if retries > 0 then
          response.retries = retries
        end
        return callback(response, nil)
      end
      if is_fatal_error(err) or not is_retryable_error(err) or retries >= max_retries then
        return callback(nil, format_retry_error(err, retries))
      end
      retries = retries + 1
      vim.defer_fn(attempt, retry_delay_ms)
    end)
  end

  return attempt()
end

M._is_retryable_error = is_retryable_error
M._is_fatal_error = is_fatal_error
M._resolve_retry_settings = resolve_retry_settings

function M.post_json(request)
  return retry_post_json_request(request)
end

function M.post_json_async(request, callback)
  local api_key, auth_err = resolve_optional_api_key(request)
  if auth_err then
    return finish_with_schedule(callback, nil, auth_err)
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

  local args = build_json_curl_args(body_file, request)

  return run_curl_async(args, request, function(response, response_err)
    os.remove(body_file)
    callback(response, response_err)
  end)
end

local function build_tool_fields(params)
  local tool = {}
  local output_format = utils.normalize_output_format(params.output_format)
  if not allowed_output_formats[output_format] then
    return nil, "Unsupported output_format: " .. tostring(params.output_format)
  end

  tool.model = params.model or DEFAULT_IMAGE_MODEL
  tool.output_format = output_format
  tool.quality = DEFAULT_QUALITY

  local output_compression = params.output_compression
  if output_compression ~= nil and output_compression ~= vim.NIL then
    output_compression = tonumber(output_compression)
    if not output_compression then
      return nil, "output_compression must be a number"
    end
    if output_compression < 0 or output_compression > 100 then
      return nil, "output_compression must be between 0 and 100"
    end
    if output_format == "png" and output_compression ~= 100 then
      return nil, "PNG output does not support output_compression other than 100"
    end
    if output_format ~= "png" then
      tool.output_compression = output_compression
    end
  end

  tool.size = params.requested_size

  local background = params.background
  if background ~= nil and background ~= vim.NIL and background ~= "" then
    background = tostring(background)
    if background ~= "auto" and background ~= "opaque" and background ~= "transparent" then
      return nil, "Unsupported background: " .. tostring(params.background)
    end
    tool.background = background
  end

  -- The default Responses image provider intentionally uses the lower image
  -- moderation setting for all genai calls. Keep this fixed so callers cannot
  -- accidentally diverge from the provider contract via params or extra.
  tool.moderation = "low"

  local partial_images = params.partial_images
  if partial_images == nil or partial_images == vim.NIL then
    partial_images = type(params.extra) == "table" and params.extra.partial_images or nil
  end
  if partial_images ~= nil and partial_images ~= vim.NIL then
    partial_images = tonumber(partial_images)
    if not partial_images then
      return nil, "partial_images must be a number"
    end
    if partial_images < 0 or partial_images > 3 then
      return nil, "partial_images must be between 0 and 3"
    end
    tool.partial_images = partial_images
  end

  if tool.partial_images == nil then
    tool.partial_images = requested_size.parse(tool.size) and 0 or 1
  end

  if type(params.extra) == "table" then
    for k, v in pairs(params.extra) do
      if type(k) == "string" and allowed_tool_fields[k] and v ~= nil then
        tool[k] = v
      end
    end
  end

  if tool.background ~= nil then
    tool.background = tostring(tool.background)
    if tool.background ~= "auto" and tool.background ~= "opaque" and tool.background ~= "transparent" then
      return nil, "Unsupported background: " .. tostring(tool.background)
    end
  end

  return tool, nil
end

local NO_PROMPT_REVISION_INSTRUCTIONS = "Pass the user prompt to image_generation VERBATIM."

local function build_size_instruction(params)
  local size = params.requested_size or "auto"
  return string.format(
    "Use %s as the requested image size for the image_generation tool. Pass this value to the tool unchanged. "
      .. "Do not infer, replace, or override it based on the prompt. The saved image dimensions may differ from this requested size.",
    size
  )
end

local function is_prompt_rewrite_guard_enabled(params)
  if params.prompt_rewrite_guard ~= nil and params.prompt_rewrite_guard ~= vim.NIL then
    return params.prompt_rewrite_guard ~= false
  end
  if type(params.extra) == "table" and params.extra.prompt_rewrite_guard ~= nil then
    return params.extra.prompt_rewrite_guard ~= false
  end
  return true
end

local function build_instructions(params)
  local instructions = {}
  if is_prompt_rewrite_guard_enabled(params) then
    table.insert(instructions, NO_PROMPT_REVISION_INSTRUCTIONS)
  end
  table.insert(instructions, build_size_instruction(params))
  return table.concat(instructions, "\n\n")
end

local function build_input_text_message(params, image_parts)
  local content = {
    {
      type = "input_text",
      text = params.prompt,
    },
  }

  for _, item in ipairs(image_parts or {}) do
    table.insert(content, item)
  end

  return {
    role = "user",
    content = content,
  }
end

local function normalize_action(request_kind, params)
  local action = params.action
  if action == nil or action == vim.NIL or action == "" then
    if type(params.extra) == "table" then
      action = params.extra.action
    end
  end

  if action == nil or action == vim.NIL or action == "" then
    if request_kind == "edit" then
      return "edit", nil
    end
    return "generate", nil
  end

  action = tostring(action)
  if action ~= "auto" and action ~= "generate" and action ~= "edit" then
    return nil, "Unsupported action: " .. tostring(action)
  end

  return action, nil
end

local function build_responses_request(provider, params, image_parts, request_kind, mask_data_url)
  local tool, err = build_tool_fields(params)
  if not tool then
    return nil, err
  end
  if mask_data_url then
    tool.input_image_mask = {
      image_url = mask_data_url,
    }
  end

  local action
  action, err = normalize_action(request_kind, params)
  if not action and err then
    return nil, err
  end
  if action then
    tool.action = action
  end

  local body = {
    model = params.text_model or DEFAULT_TEXT_MODEL,
    stream = true,
    store = false,
    reasoning = { effort = "none" },
    input = { build_input_text_message(params, image_parts) },
    tools = {
      vim.tbl_extend("force", { type = "image_generation" }, tool),
    },
    tool_choice = { type = "image_generation" },
  }

  local instructions = build_instructions(params)
  if instructions then
    body.instructions = instructions
  end

  return body, nil
end

local function save_image_response_internal(request, response, callback)
  local params = request.params or {}
  local response_body = response and response.body or {}
  local items = {}
  local body = response_body
  if type(response_body) == "string" then
    local parsed, parsed_err = parse_response_body(response_body, true)
    if not parsed then
      return callback(nil, parsed_err)
    end
    body = parsed
  end
  collect_image_generation_items(body, items)

  if #items == 0 then
    local usage = extract_tool_usage(body)
    local usage_hint = ""
    if type(usage) == "table" then
      local total = tonumber(usage.total_tokens)
      local output = tonumber(usage.output_tokens)
      if total == 0 or output == 0 then
        usage_hint = " image_gen tool_usage is zero, so the hosted tool was not executed."
      end
    end

    local text_hint = ""
    local function collect_text(value, out)
      if type(value) ~= "table" or #out > 0 then
        return
      end
      if type(value.text) == "string" and value.text ~= "" then
        table.insert(out, value.text:gsub("%s+", " "):sub(1, 240))
        return
      end
      if type(value.content) == "table" then
        for _, child in ipairs(value.content) do
          collect_text(child, out)
        end
      end
      if type(value.output) == "table" then
        for _, child in ipairs(value.output) do
          collect_text(child, out)
        end
      end
    end
    local text_parts = {}
    collect_text(body, text_parts)
    if #text_parts > 0 then
      text_hint = " First text output: " .. text_parts[1]
    end

    return callback(nil, "Responses image_generation returned no image result." .. usage_hint .. text_hint)
  end

  local ok, err = utils.ensure_output_dir(params.output_dir)
  if not ok then
    return callback(nil, err)
  end

  local output_format = utils.normalize_output_format(params.output_format)
  local files = {}
  local urls = {}
  local revised_prompt

  for i, item in ipairs(items) do
    if type(item.revised_prompt) == "string" and item.revised_prompt ~= "" and not revised_prompt then
      revised_prompt = item.revised_prompt
    end

    if type(item.b64_json) == "string" and item.b64_json ~= "" then
      local path = utils.make_output_path(params.output_dir, params.filename_prefix, output_format, i)
      local bytes
      bytes, err = utils.save_base64_file(item.b64_json, path)
      if not bytes then
        return callback(nil, err)
      end
      table.insert(files, {
        path = path,
        bytes = bytes,
        requested_format = output_format,
      })
    elseif type(item.url) == "string" and item.url ~= "" then
      local path = utils.make_output_path(params.output_dir, params.filename_prefix, output_format, i)
      local args = {
        "curl",
        "-L",
        "-sS",
        "--connect-timeout",
        "30",
        "--max-time",
        "300",
        "-o",
        path,
      }
      append_proxy(args, request.proxy)
      table.insert(args, item.url)
      local result = vim.system(args, { text = true }):wait()

      if result.code ~= 0 then
        local stderr = (result.stderr or ""):gsub("%s+$", "")
        return callback(
          nil,
          string.format(
            "Failed to download image URL: curl exit %s%s",
            tostring(result.code),
            stderr ~= "" and (": " .. stderr) or ""
          )
        )
      end

      local stat = vim.uv.fs_stat(path)
      if not stat or not stat.size or stat.size <= 0 then
        return callback(nil, "Downloaded image URL produced an empty file")
      end
      table.insert(files, {
        path = path,
        bytes = stat.size,
        requested_format = output_format,
      })
      table.insert(urls, item.url)
    end
  end

  if #files == 0 and #urls == 0 then
    return callback(nil, "Responses image_generation returned no image result files")
  end

  local result = output_metadata.finalize_result({
    provider = request.provider.name,
    model = params.model,
    requested_size = params.requested_size,
    output_format = output_format,
    response_mode = response and response.response_mode or (params.stream and "sse_or_json" or "json"),
    count = #items,
    files = files,
    urls = urls,
    revised_prompt = revised_prompt,
    tool_usage = extract_tool_usage(body),
  })

  return callback(result, nil)
end

function M.save_image_response(request, response)
  local result
  local err
  save_image_response_internal(request, response, function(value, callback_err)
    result = value
    err = callback_err
  end)
  if not result then
    return nil, err
  end
  return result, nil
end

function M.save_image_response_async(request, response, callback)
  return save_image_response_internal(request, response, callback)
end

function M.generate(provider, params)
  local request, err = prepare_common(provider, params, "responses")
  if not request then
    return nil, err
  end

  if not request.params.prompt or vim.trim(request.params.prompt) == "" then
    return nil, "Missing required parameter: prompt"
  end
  if request.params.n ~= nil and request.params.n ~= vim.NIL then
    local n = tonumber(request.params.n)
    if n and n > 1 then
      return nil, "Responses image_generation only supports one image per call"
    end
  end

  request.method = "POST"
  request.content_type = "application/json"
  request.stream = true
  request.body, err = build_responses_request(provider, request.params, {}, "generate")
  if not request.body then
    return nil, err
  end
  return request, nil
end

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

  local result
  save_image_response_internal(request, response, function(value, callback_err)
    result = value
    err = callback_err
  end)
  if not result then
    return nil, err
  end

  return result, nil
end

function M.generate_image_async(provider, params, callback)
  local request, err = M.generate(provider, params)
  if not request then
    return finish_with_schedule(callback, nil, err)
  end

  return retry_post_json_request_async(request, function(response, response_err)
    if not response then
      return callback(nil, response_err)
    end
    return save_image_response_internal(request, response, callback)
  end)
end

function M.edit(provider, params)
  local request, err = prepare_common(provider, params, "responses")
  if not request then
    return nil, err
  end

  if not request.params.prompt or vim.trim(request.params.prompt) == "" then
    return nil, "Missing required parameter: prompt"
  end
  if type(request.params.image_paths) ~= "table" or #request.params.image_paths == 0 then
    return nil, "Missing required parameter: image_paths must contain at least one image path"
  end
  if request.params.n ~= nil and request.params.n ~= vim.NIL then
    local n = tonumber(request.params.n)
    if n and n > 1 then
      return nil, "Responses image_generation only supports one image per call"
    end
  end

  local normalized_mask
  local mask_data_url
  if request.params.mask_path and request.params.mask_path ~= "" then
    normalized_mask, err = utils.validate_file(request.params.mask_path, "mask_path")
    if not normalized_mask then
      return nil, err
    end
    mask_data_url, err = utils.file_to_data_url(normalized_mask)
    if not mask_data_url then
      return nil, err
    end
    request.params.mask_path = normalized_mask
  end

  local normalized_images = {}
  local image_parts = {}
  for i, path in ipairs(request.params.image_paths) do
    local normalized
    normalized, err = utils.validate_file(path, "image_paths[" .. i .. "]")
    if not normalized then
      return nil, err
    end
    table.insert(normalized_images, normalized)

    local data_url
    data_url, err = utils.file_to_data_url(normalized)
    if not data_url then
      return nil, err
    end
    local detail = request.params.detail

    table.insert(image_parts, {
      type = "input_image",
      image_url = data_url,
      detail = detail,
    })
  end
  request.params.image_paths = normalized_images

  request.method = "POST"
  request.content_type = "application/json"
  request.stream = true
  request.body, err = build_responses_request(provider, request.params, image_parts, "edit", mask_data_url)
  if not request.body then
    return nil, err
  end
  return request, nil
end

function M.edit_image(provider, params)
  local request, err = M.edit(provider, params)
  if not request then
    return nil, err
  end

  local response
  response, err = M.post_json(request)
  if not response then
    return nil, err
  end

  local result
  save_image_response_internal(request, response, function(value, callback_err)
    result = value
    err = callback_err
  end)
  if not result then
    return nil, err
  end

  return result, nil
end

function M.edit_image_async(provider, params, callback)
  local request, err = M.edit(provider, params)
  if not request then
    return finish_with_schedule(callback, nil, err)
  end

  return retry_post_json_request_async(request, function(response, response_err)
    if not response then
      return callback(nil, response_err)
    end
    return save_image_response_internal(request, response, callback)
  end)
end

return M
