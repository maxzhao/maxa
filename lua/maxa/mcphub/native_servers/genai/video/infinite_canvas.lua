local provider_api = require("maxa.mcphub.native_servers.genai.adapter")
local http = require("maxa.mcphub.native_servers.genai.media.http")
local output = require("maxa.mcphub.native_servers.genai.media.output")
local utils = require("maxa.mcphub.native_servers.genai.image.utils")

local M = {}
local TERMINAL_SUCCESS = { completed = true, succeeded = true, success = true }
local TERMINAL_FAILURE = { failed = true, cancelled = true, canceled = true }

local function unwrap(value)
  if type(value) ~= "table" then return value end
  if value.code ~= nil and tonumber(value.code) ~= 0 and tonumber(value.code) ~= 200 then
    return nil, value.msg or value.message or (type(value.error) == "table" and value.error.message) or "provider error"
  end
  return type(value.data) == "table" and value.data or value
end

function M.parse_task(body)
  local decoded = http.json(body)
  if not decoded then return nil, "Video endpoint returned invalid JSON" end
  local value, err = unwrap(decoded)
  if not value then return nil, err end
  local task = value.task or value.result or value
  local id = task.id or task.task_id or task.video_id
  local status = tostring(task.status or task.state or ""):lower()
  local url = task.url or task.video_url or task.result_url or task.output_url
  if type(task.output) == "table" then url = url or task.output.url or task.output.video_url end
  if type(task.content) == "table" then url = url or task.content.url or task.content.video_url end
  local task_error = type(task.error) == "table" and (task.error.message or task.error.msg) or task.error
  task_error = task_error or task.message or task.msg
  return { id = id, status = status, url = url, error = task_error, raw = task }
end

function M.build_create(capability, params)
  local merged = provider_api.merge(capability.defaults, params)
  if merged.generation_preset ~= nil then merged.preset = merged.generation_preset end
  if type(merged.prompt) ~= "string" or vim.trim(merged.prompt) == "" then return nil, "prompt is required" end
  local seconds = tonumber(merged.seconds)
  if not seconds or seconds % 1 ~= 0 or seconds < 1 or seconds > 20 then return nil, "seconds must be an integer within 1..20" end
  if merged.size and merged.size ~= "auto" and not tostring(merged.size):match("^[1-9]%d*x[1-9]%d*$") then
    return nil, "size must be auto or positive-integer WIDTHxHEIGHT"
  end
  if type(merged.extra) == "table" and next(merged.extra) ~= nil then return nil, "video extra fields are not supported by this driver" end
  local paths, max = {}, tonumber(capability.request.max_reference_images) or 7
  if #(merged.reference_image_paths or {}) > max then return nil, "reference_image_paths exceeds configured maximum of " .. max end
  for _, path in ipairs(merged.reference_image_paths or {}) do
    local normalized, err = utils.validate_file(path, "reference image")
    if not normalized then return nil, err end
    table.insert(paths, normalized)
  end
  local form = { strings = { "prompt=" .. merged.prompt, "seconds=" .. tostring(seconds) }, files = {} }
  for _, key in ipairs({ "model", "size", "resolution_name", "preset" }) do if merged[key] then table.insert(form.strings, key .. "=" .. tostring(merged[key])) end end
  local field = capability.request.reference_field or "input_reference[]"
  for _, path in ipairs(paths) do table.insert(form.files, field .. "=@" .. path) end
  return form, merged
end

local function download(provider, capability, merged, task, started, polls, callback)
  local direct_url = task.url
  local url = direct_url or provider_api.endpoint(provider, "video_content", task.id, capability)
  if url and url:sub(1, 1) == "/" then url = require("maxa.mcphub.native_servers.genai.image.utils").join_url(provider.api_root, url) end
  local headers = direct_url and {} or { "Authorization: Bearer " .. provider.api_key }
  return http.request_async({ method = "GET", url = url, headers = headers, timeout = tonumber(merged.timeout_seconds) or 600, proxy = provider.proxy }, function(response, err)
    if not response then return callback(nil, err) end
    local mime = output.content_type(response.headers)
    if response.body == "" then return callback(nil, "Video download returned an empty body") end
    if output.looks_like_error(response.body, mime) then return callback(nil, http.error_from(response.body, response.status)) end
    local ext = (mime and mime:match("video/([%w%-]+)")) or "mp4"
    local saved, save_err = output.save(provider, merged, response.body, "video_generate", ext)
    if not saved then return callback(nil, save_err) end
    saved.adapter, saved.model, saved.task_id = provider.name, merged.model, task.id
    saved.status, saved.mime, saved.seconds, saved.size = task.status ~= "" and task.status or "completed", mime or "video/mp4", merged.seconds, merged.size
    saved.polls, saved.elapsed_ms = polls, math.floor((vim.uv.hrtime() - started) / 1000000)
    callback(saved)
  end)
end

function M.generate_async(provider, capability, params, callback)
  local form, merged = M.build_create(capability, params)
  if not form then return callback(nil, merged) end
  local started, polls, done = vim.uv.hrtime(), 0, false
  local current_request, timer
  local function finish(result, err)
    if done then return end
    done = true
    if timer then timer:stop(); timer:close(); timer = nil end
    callback(result, err)
  end
  local function handle(task)
    if task.url and (not task.id or TERMINAL_SUCCESS[task.status] or task.status == "") then
      current_request = download(provider, capability, merged, task, started, polls, finish)
      return
    end
    if not task.id then return finish(nil, "Video create response did not include a task ID or result URL") end
    if TERMINAL_FAILURE[task.status] then
      local suffix = task.error and (": " .. tostring(task.error)) or ""
      return finish(nil, "Video task " .. task.id .. " ended with status " .. task.status .. suffix)
    end
    if TERMINAL_SUCCESS[task.status] then
      current_request = download(provider, capability, merged, task, started, polls, finish)
      return
    end
    local max_attempts = tonumber(capability.request.max_poll_attempts) or 120
    if polls >= max_attempts then return finish(nil, "Video task " .. task.id .. " timed out after " .. polls .. " polls") end
    local elapsed = (vim.uv.hrtime() - started) / 1000000000
    if merged.timeout_seconds and elapsed >= tonumber(merged.timeout_seconds) then return finish(nil, "Video task " .. task.id .. " exceeded timeout_seconds") end
    timer = vim.uv.new_timer()
    timer:start(tonumber(capability.request.poll_interval_ms) or 2500, 0, vim.schedule_wrap(function()
      timer:stop(); timer:close(); timer = nil; if done then return end
      polls = polls + 1
      current_request = http.request_async({ method = "GET", url = provider_api.endpoint(provider, "video_retrieve", task.id, capability), headers = { "Authorization: Bearer " .. provider.api_key }, timeout = tonumber(merged.timeout_seconds) or 600, proxy = provider.proxy }, function(response, err)
        if not response then return finish(nil, err) end
        local next_task, parse_err = M.parse_task(response.body)
        if not next_task then return finish(nil, parse_err) end
        next_task.id = next_task.id or task.id
        handle(next_task)
      end)
    end))
  end
  current_request = http.request_async({ method = "POST", url = provider_api.endpoint(provider, "video_create", nil, capability), headers = { "Authorization: Bearer " .. provider.api_key }, form_strings = form.strings, form_files = form.files, timeout = tonumber(merged.timeout_seconds) or 600, proxy = provider.proxy }, function(response, err)
    if not response then return finish(nil, err) end
    local task, parse_err = M.parse_task(response.body)
    if not task then return finish(nil, parse_err) end
    handle(task)
  end)
  return {
    cancel = function()
      if done then return false end
      done = true
      if timer then timer:stop(); timer:close(); timer = nil end
      if current_request and current_request.cancel then current_request.cancel() end
      callback(nil, "Video generation cancelled")
      return true
    end,
  }
end

return M
