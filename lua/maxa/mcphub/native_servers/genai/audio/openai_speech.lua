local provider_api = require("maxa.mcphub.native_servers.genai.adapter")
local http = require("maxa.mcphub.native_servers.genai.media.http")
local output = require("maxa.mcphub.native_servers.genai.media.output")

local M = {}
local EXTRA_ALLOWLIST = {}

function M.build_request(capability, params)
  local merged = provider_api.merge(capability.defaults, params)
  if type(merged.input) ~= "string" or vim.trim(merged.input) == "" then return nil, "input is required" end
  if type(merged.model) ~= "string" or vim.trim(merged.model) == "" then return nil, "model is required" end
  if type(merged.voice) ~= "string" or vim.trim(merged.voice) == "" then return nil, "voice is required" end
  local fmt = output.audio_format(merged.response_format)
  if not fmt then return nil, "response_format must be one of: mp3, opus, aac, flac, wav, pcm" end
  local speed = tonumber(merged.speed)
  if not speed or speed < 0.25 or speed > 4 then return nil, "speed must be within 0.25..4" end
  local body = { input = merged.input, model = merged.model, voice = merged.voice, response_format = merged.response_format, speed = speed }
  if merged.instructions then body.instructions = merged.instructions end
  for key, value in pairs(merged.extra or {}) do
    if not EXTRA_ALLOWLIST[key] then return nil, "extra field is not allowed: " .. tostring(key) end
    body[key] = value
  end
  return body, merged, fmt
end

function M.speech_async(provider, capability, params, callback)
  local body, merged, fmt = M.build_request(capability, params)
  if not body then return callback(nil, merged) end
  return http.request_async({
    method = "POST", url = provider_api.endpoint(provider, "speech", nil, capability),
    headers = { "Authorization: Bearer " .. provider.api_key, "Content-Type: application/json", "Accept: audio/*" },
    data = vim.json.encode(body), timeout = tonumber(params.timeout_seconds) or 300, proxy = provider.proxy,
  }, function(response, err)
    if not response then return callback(nil, err) end
    local mime = output.content_type(response.headers)
    if response.body == "" then return callback(nil, "Speech endpoint returned an empty body") end
    if output.looks_like_error(response.body, mime) then return callback(nil, http.error_from(response.body, response.status)) end
    local saved, save_err = output.save(provider, merged, response.body, "audio_speech", fmt.ext)
    if not saved then return callback(nil, save_err) end
    saved.adapter, saved.model, saved.voice = provider.name, merged.model, merged.voice
    saved.format, saved.mime = merged.response_format, mime or fmt.mime
    return callback(saved)
  end)
end

return M
