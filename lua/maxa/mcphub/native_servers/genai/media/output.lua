local utils = require("maxa.mcphub.native_servers.genai.image.utils")
local M = {}

local FORMATS = {
  mp3 = { ext = "mp3", mime = "audio/mpeg" }, opus = { ext = "opus", mime = "audio/opus" },
  aac = { ext = "aac", mime = "audio/aac" }, flac = { ext = "flac", mime = "audio/flac" },
  wav = { ext = "wav", mime = "audio/wav" }, pcm = { ext = "pcm", mime = "audio/pcm" },
}

function M.audio_format(name) return FORMATS[tostring(name or ""):lower()] end

function M.content_type(headers)
  return headers and headers:lower():match("content%-type:%s*([^;\r\n]+)") or nil
end

function M.looks_like_error(bytes, mime)
  local prefix = (bytes or ""):sub(1, 256):lower():gsub("^%s+", "")
  mime = tostring(mime or ""):lower()
  return prefix:match("^[%{%[]") ~= nil or prefix:match("^<html") ~= nil or prefix:match("^<!doctype") ~= nil
    or mime:find("json", 1, true) ~= nil or mime:find("text/", 1, true) ~= nil or mime:find("html", 1, true) ~= nil
end

function M.save(provider, params, bytes, fallback_prefix, ext)
  local output_dir, err = utils.resolve_output_dir(params.output_dir or provider.output_dir)
  if not output_dir then return nil, err end
  local ok
  ok, err = utils.ensure_output_dir(output_dir)
  if not ok then return nil, err end
  local path = utils.make_output_path(output_dir, params.filename_prefix or fallback_prefix, ext)
  local file
  file, err = io.open(path, "wb")
  if not file then return nil, "Failed to open media output: " .. tostring(err) end
  local wrote, write_err = file:write(bytes)
  file:close()
  if not wrote then return nil, "Failed to write media output: " .. tostring(write_err) end
  return { path = path, bytes = #bytes }
end

return M
