-- Dependency-free inspection and request/actual metadata for saved GenAI images.

local requested_size = require("maxa.mcphub.native_servers.genai.image.requested_size")
local utils = require("maxa.mcphub.native_servers.genai.image.utils")

local M = {}

local function byte(data, index)
  return data:byte(index)
end

local function be16(data, index)
  local a, b = byte(data, index), byte(data, index + 1)
  if not a or not b then
    return nil
  end
  return a * 256 + b
end

local function be32(data, index)
  local a, b, c, d = byte(data, index), byte(data, index + 1), byte(data, index + 2), byte(data, index + 3)
  if not a or not b or not c or not d then
    return nil
  end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function le16(data, index)
  local a, b = byte(data, index), byte(data, index + 1)
  if not a or not b then
    return nil
  end
  return a + b * 256
end

local function le24(data, index)
  local a, b, c = byte(data, index), byte(data, index + 1), byte(data, index + 2)
  if not a or not b or not c then
    return nil
  end
  return a + b * 256 + c * 65536
end

local function le32(data, index)
  local a, b, c, d = byte(data, index), byte(data, index + 1), byte(data, index + 2), byte(data, index + 3)
  if not a or not b or not c or not d then
    return nil
  end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function valid_dimensions(width, height)
  return type(width) == "number" and type(height) == "number" and width > 0 and height > 0
end

local function inspect_png(data)
  if #data < 24 or data:sub(1, 8) ~= "\137PNG\r\n\26\n" or data:sub(13, 16) ~= "IHDR" then
    return nil, "malformed or truncated PNG header"
  end
  local width, height = be32(data, 17), be32(data, 21)
  if not valid_dimensions(width, height) then
    return nil, "PNG IHDR contains invalid dimensions"
  end
  return { actual_format = "png", actual_width = width, actual_height = height }
end

local jpeg_sof = {
  [0xC0] = true,
  [0xC1] = true,
  [0xC2] = true,
  [0xC3] = true,
  [0xC5] = true,
  [0xC6] = true,
  [0xC7] = true,
  [0xC9] = true,
  [0xCA] = true,
  [0xCB] = true,
  [0xCD] = true,
  [0xCE] = true,
  [0xCF] = true,
}

local function inspect_jpeg(data)
  if #data < 4 or byte(data, 1) ~= 0xFF or byte(data, 2) ~= 0xD8 then
    return nil, "malformed JPEG signature"
  end

  local pos = 3
  while pos <= #data do
    while pos <= #data and byte(data, pos) ~= 0xFF do
      pos = pos + 1
    end
    while pos <= #data and byte(data, pos) == 0xFF do
      pos = pos + 1
    end
    local marker = byte(data, pos)
    if not marker then
      break
    end
    pos = pos + 1

    if marker == 0xD9 or marker == 0xDA then
      break
    end
    if marker ~= 0x01 and not (marker >= 0xD0 and marker <= 0xD8) then
      local segment_length = be16(data, pos)
      if not segment_length or segment_length < 2 or pos + segment_length - 1 > #data then
        return nil, "malformed or truncated JPEG segment"
      end
      if jpeg_sof[marker] then
        if segment_length < 7 then
          return nil, "truncated JPEG SOF segment"
        end
        local height, width = be16(data, pos + 3), be16(data, pos + 5)
        if not valid_dimensions(width, height) then
          return nil, "JPEG SOF contains invalid dimensions"
        end
        return { actual_format = "jpeg", actual_width = width, actual_height = height }
      end
      pos = pos + segment_length
    end
  end

  return nil, "JPEG contains no supported SOF dimensions"
end

local function inspect_webp_chunk(data, chunk_type, payload, chunk_size)
  if chunk_type == "VP8X" then
    if chunk_size < 10 or payload + 9 > #data then
      return nil, "truncated WebP VP8X chunk"
    end
    return 1 + le24(data, payload + 4), 1 + le24(data, payload + 7)
  end

  if chunk_type == "VP8L" then
    if chunk_size < 5 or payload + 4 > #data or byte(data, payload) ~= 0x2F then
      return nil, "malformed WebP VP8L chunk"
    end
    local b1, b2, b3, b4 = byte(data, payload + 1), byte(data, payload + 2), byte(data, payload + 3), byte(data, payload + 4)
    local width = 1 + b1 + bit.band(b2, 0x3F) * 256
    local height = 1 + bit.rshift(b2, 6) + b3 * 4 + bit.band(b4, 0x0F) * 1024
    return width, height
  end

  if chunk_type == "VP8 " then
    if chunk_size < 10 or payload + 9 > #data or data:sub(payload + 3, payload + 5) ~= "\157\1\42" then
      return nil, "malformed WebP VP8 chunk"
    end
    local width, height = le16(data, payload + 6), le16(data, payload + 8)
    if width and height then
      return bit.band(width, 0x3FFF), bit.band(height, 0x3FFF)
    end
  end

  return nil, nil
end

local function inspect_webp(data)
  if #data < 20 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WEBP" then
    return nil, "malformed or truncated WebP header"
  end

  local pos = 13
  while pos + 7 <= #data do
    local chunk_type = data:sub(pos, pos + 3)
    local chunk_size = le32(data, pos + 4)
    if not chunk_size then
      return nil, "truncated WebP chunk header"
    end
    local payload = pos + 8
    if payload + chunk_size - 1 > #data then
      return nil, "truncated WebP image chunk"
    end
    local width, height_or_err = inspect_webp_chunk(data, chunk_type, payload, chunk_size)
    if width then
      local height = height_or_err
      if not valid_dimensions(width, height) then
        return nil, "WebP image chunk contains invalid dimensions"
      end
      return { actual_format = "webp", actual_width = width, actual_height = height }
    elseif height_or_err then
      return nil, height_or_err
    end
    pos = payload + chunk_size + (chunk_size % 2)
  end

  return nil, "WebP contains no supported VP8, VP8L, or VP8X dimensions"
end

function M.inspect_bytes(data)
  if type(data) ~= "string" or data == "" then
    return nil, "image file is empty"
  end
  if data:sub(1, 8) == "\137PNG\r\n\26\n" then
    return inspect_png(data)
  end
  if byte(data, 1) == 0xFF and byte(data, 2) == 0xD8 then
    return inspect_jpeg(data)
  end
  if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
    return inspect_webp(data)
  end
  return nil, "unsupported image signature; expected PNG, JPEG, or WebP"
end

function M.inspect_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, "failed to open saved image: " .. tostring(err)
  end
  local data = file:read("*a")
  file:close()
  return M.inspect_bytes(data)
end

function M.enrich_file(file, requested, requested_format)
  file.requested_format = utils.normalize_output_format(requested_format)
  local metadata, err = M.inspect_file(file.path)
  local warnings = {}

  if not metadata then
    file.actual_format = nil
    file.actual_width = nil
    file.actual_height = nil
    file.actual_size = nil
    file.size_check = "unverified"
    table.insert(warnings, string.format("Could not inspect saved image metadata for `%s`: %s", file.path, tostring(err)))
    return warnings
  end

  file.actual_format = metadata.actual_format
  file.actual_width = metadata.actual_width
  file.actual_height = metadata.actual_height
  file.actual_size = string.format("%dx%d", metadata.actual_width, metadata.actual_height)
  file.format = metadata.actual_format

  if requested == "auto" then
    file.size_check = "not_applicable"
  else
    local expected_width, expected_height = requested_size.parse(requested)
    if expected_width == metadata.actual_width and expected_height == metadata.actual_height then
      file.size_check = "matched"
    else
      file.size_check = "mismatched"
      table.insert(
        warnings,
        string.format(
          "Upstream returned dimensions different from requested_size for `%s` (requested %s, actual %s).",
          file.path,
          requested,
          file.actual_size
        )
      )
    end
  end

  if file.requested_format ~= file.actual_format then
    table.insert(
      warnings,
      string.format(
        "Saved image format differs from requested format for `%s` (requested %s, actual %s).",
        file.path,
        file.requested_format,
        file.actual_format
      )
    )
  end

  return warnings
end

function M.finalize_result(result)
  local files = result.files or {}
  local warnings = result.warnings or {}
  local aggregate = result.requested_size == "auto" and "not_applicable" or "matched"

  for _, file in ipairs(files) do
    local file_warnings = M.enrich_file(file, result.requested_size, file.requested_format or result.output_format)
    for _, warning in ipairs(file_warnings) do
      table.insert(warnings, warning)
    end
    if file.size_check == "mismatched" then
      aggregate = "mismatched"
    elseif file.size_check == "unverified" and aggregate ~= "mismatched" then
      aggregate = "unverified"
    end
  end

  if #files == 0 then
    aggregate = "unverified"
  end
  result.size_check = aggregate
  result.warnings = warnings
  return result
end

return M
