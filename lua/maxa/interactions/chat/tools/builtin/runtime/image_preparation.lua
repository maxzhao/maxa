-- filepath: lua/maxa/interactions/chat/tools/builtin/runtime/image_preparation.lua
-- Internal single-image validation, transformation, and encoding.
-- This module has no chat, tool-result, TTL, or payload-registry side effects.

local param_utils = require("maxa.mcphub.native_servers.shared.params")

local M = {}

local API_MAX_SIZE = 8000
local MAX_DIAGNOSTIC_BYTES = 800
local DEFAULT_DETAIL = "original"
local DEFAULT_RESIZE_MODE = "downscale_only"
local VALID_DETAIL = { low = true, high = true, original = true, auto = true }
local VALID_RESIZE_MODE = { upscale_only = true, downscale_only = true, always = true }
local DIRECT_FORMATS = {
  PNG = { ext = "png", mimetype = "image/png" },
  JPEG = { ext = "jpg", mimetype = "image/jpeg" },
  WEBP = { ext = "webp", mimetype = "image/webp" },
  GIF = { ext = "gif", mimetype = "image/gif" },
}
local EXCLUDED_FORMATS = { PDF = true, SVG = true }
local ALLOWED_FIELDS = {
  path = true,
  detail = true,
  region = true,
  target_long_edge = true,
  resize_mode = true,
}
local REGION_FIELDS = { x = true, y = true, w = true, h = true }

local function finite_number(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function bounded_diagnostic(value)
  local text = vim.trim(tostring(value or ""):gsub("%s+", " "))
  if #text > MAX_DIAGNOSTIC_BYTES then
    return text:sub(1, MAX_DIAGNOSTIC_BYTES) .. "..."
  end
  return text
end

local function fail(message)
  return nil, bounded_diagnostic(message)
end

local function make_temp_path(ext)
  return string.format("/tmp/nvim_load_image_%d_%d.%s", vim.fn.getpid(), vim.uv.hrtime(), ext)
end

local function cleanup_temp(path)
  if path then
    pcall(vim.uv.fs_unlink, path)
  end
end

---Reject document/vector inputs before ImageMagick can rasterize them.
---Shared with the previous image loader; raster metadata is not file format evidence.
---@param path string
---@return string|nil format
function M.detect_excluded_content(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local ok, prefix = pcall(vim.uv.fs_read, fd, 4096, 0)
  pcall(vim.uv.fs_close, fd)
  if not ok or type(prefix) ~= "string" then
    return nil
  end
  if prefix:sub(1, 5) == "%PDF-" then
    return "PDF"
  end
  local text = prefix:gsub("^\239\187\191", ""):lower()
  -- SVG is a markup document (possibly with an XML prolog), not an arbitrary
  -- occurrence inside a binary image's metadata or compressed pixel data.
  if text:match("^%s*<") and text:find("<svg[%s/>]") then
    return "SVG"
  end
  return nil
end

local function probe_image(path)
  local output = vim.fn.system({
    "magick",
    "identify",
    "-ping",
    "-format",
    "%m\t%[mime:type]\t%w\t%h\t%[colorspace]\t%z\\n",
    path,
  })
  if vim.v.shell_error ~= 0 then
    return fail("Failed to decode image content: " .. bounded_diagnostic(output))
  end

  local records = {}
  for line in tostring(output):gmatch("[^\r\n]+") do
    local format, mimetype, width, height, colorspace, depth =
      line:match("^([^\t]+)\t([^\t]*)\t(%d+)\t(%d+)\t([^\t]*)\t(%d+)$")
    if not format then
      return fail("ImageMagick returned invalid probe metadata")
    end
    records[#records + 1] = {
      format = format:upper(),
      mimetype = mimetype ~= "" and mimetype or nil,
      width = tonumber(width),
      height = tonumber(height),
      colorspace = colorspace,
      depth = tonumber(depth),
    }
  end
  if #records == 0 then
    return fail("ImageMagick returned no decoded images")
  end
  local info = records[1]
  info.image_count = #records
  return info, nil
end

local function validate(params)
  if type(params) ~= "table" then
    return fail("image params must be an object")
  end
  local normalized = param_utils.normalize(params)

  for key in pairs(normalized) do
    if not ALLOWED_FIELDS[key] then
      return fail(string.format("unknown image parameter: %s", tostring(key)))
    end
  end

  local path, path_err = param_utils.required_string(normalized.path, "path")
  if not path then
    return fail(path_err)
  end
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  end
  if vim.fn.filereadable(path) ~= 1 then
    return fail(string.format("File not found: %s", path))
  end

  local detail = param_utils.default(normalized.detail, DEFAULT_DETAIL)
  if type(detail) ~= "string" or not VALID_DETAIL[detail] then
    return fail("detail must be one of low, high, original, auto")
  end

  local resize_mode = param_utils.default(normalized.resize_mode, DEFAULT_RESIZE_MODE)
  if type(resize_mode) ~= "string" or not VALID_RESIZE_MODE[resize_mode] then
    return fail("resize_mode must be one of upscale_only, downscale_only, always")
  end

  local target = normalized.target_long_edge
  if target ~= nil and (not finite_number(target) or target % 1 ~= 0 or target < 1 or target > API_MAX_SIZE) then
    return fail("target_long_edge must be an integer from 1 to 8000")
  end

  local region = normalized.region
  if region ~= nil then
    if type(region) ~= "table" then
      return fail("region must be an object with {x, y, w, h}")
    end
    for key in pairs(region) do
      if not REGION_FIELDS[key] then
        return fail(string.format("unknown region parameter: %s", tostring(key)))
      end
    end
    for _, key in ipairs({ "x", "y", "w", "h" }) do
      local value = region[key]
      if not finite_number(value) then
        return fail(string.format("region.%s must be a finite number", key))
      end
      if value < 0 or value > 100 then
        return fail(string.format("region.%s must be 0-100, got %s", key, value))
      end
    end
    if region.w <= 0 or region.h <= 0 then
      return fail("region.w and region.h must be > 0")
    end
  end

  return {
    path = path,
    detail = detail,
    region = region,
    target_long_edge = target,
    resize_mode = resize_mode,
  },
    nil
end

local function transform(src, source, options)
  local direct = DIRECT_FORMATS[source.format]
  local final_format = direct and source.format or "PNG"
  local output = direct or DIRECT_FORMATS.PNG
  local normalized = direct == nil
  local width, height = source.width, source.height
  local cropped, resized = false, false
  local resize_direction, resize_skip_reason
  local args = { "magick", src }

  if options.region then
    local region = options.region
    local x = math.floor(source.width * region.x / 100)
    local y = math.floor(source.height * region.y / 100)
    local w = math.min(math.floor(source.width * region.w / 100), source.width - x)
    local h = math.min(math.floor(source.height * region.h / 100), source.height - y)
    if w <= 0 or h <= 0 then
      return nil,
        nil,
        string.format(
          "Invalid region: computed crop %dx%d+%d+%d from %dx%d image",
          w,
          h,
          x,
          y,
          source.width,
          source.height
        )
    end
    vim.list_extend(args, { "-crop", string.format("%dx%d+%d+%d", w, h, x, y), "+repage" })
    width, height, cropped = w, h, true
  end

  if options.target_long_edge then
    local current = math.max(width, height)
    local smaller, larger = current < options.target_long_edge, current > options.target_long_edge
    local upscale = smaller and (options.resize_mode == "upscale_only" or options.resize_mode == "always")
    local downscale = larger and (options.resize_mode == "downscale_only" or options.resize_mode == "always")
    if upscale or downscale then
      vim.list_extend(args, { "-resize", string.format("%dx%d", options.target_long_edge, options.target_long_edge) })
      resized = true
      resize_direction = upscale and "upscale" or "downscale"
    elseif current == options.target_long_edge then
      resize_skip_reason = "current longest edge already equals target"
    elseif options.resize_mode == "upscale_only" then
      resize_skip_reason = "upscale_only does not downscale a larger image"
    else
      resize_skip_reason = "downscale_only does not upscale a smaller image"
    end
  end

  local metadata = {
    path = options.path,
    source_format = source.format,
    final_format = final_format,
    mimetype = output.mimetype,
    original_width = source.width,
    original_height = source.height,
    width = width,
    height = height,
    detail = options.detail,
    normalized = normalized,
    cropped = cropped,
    resized = resized,
    region = options.region and vim.deepcopy(options.region) or nil,
    target_long_edge = options.target_long_edge,
    resize_mode = options.resize_mode,
    resize_direction = resize_direction,
    resize_skip_reason = resize_skip_reason,
    source_mimetype = source.mimetype,
  }

  if not (normalized or cropped or resized) then
    return nil, metadata, nil
  end
  if normalized then
    vim.list_extend(args, { "-colorspace", "sRGB", "-depth", "8" })
  end
  local temp_path = make_temp_path(output.ext)
  args[#args + 1] = temp_path
  local process_output = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    cleanup_temp(temp_path)
    return nil, metadata, "ImageMagick processing failed: " .. bounded_diagnostic(process_output)
  end

  local final, probe_err = probe_image(temp_path)
  if not final then
    cleanup_temp(temp_path)
    return nil, metadata, "Failed to verify processed image: " .. probe_err
  end
  if final.image_count ~= 1 or final.format ~= final_format then
    cleanup_temp(temp_path)
    return nil,
      metadata,
      string.format(
        "Processed image invariant failed: expected one %s image, got %d %s image(s)",
        final_format,
        final.image_count,
        final.format
      )
  end
  if normalized and (final.depth ~= 8 or final.colorspace:lower() ~= "srgb") then
    cleanup_temp(temp_path)
    return nil,
      metadata,
      string.format(
        "PNG normalization invariant failed: expected 8-bit sRGB, got %d-bit %s",
        final.depth,
        final.colorspace
      )
  end
  metadata.width, metadata.height = final.width, final.height
  return temp_path, metadata, nil
end

---Strictly validate image-only arguments without decoding or modifying the image.
---@param params table
---@return table|nil normalized
---@return string|nil error
function M.validate(params)
  return validate(params)
end

---Prepare and encode one local image.
---@param params table Image-only parameters: path, detail, region, target_long_edge, resize_mode.
---@return table|nil result { payload = encoded image, metadata = factual processing metadata }
---@return string|nil error Bounded diagnostic without an MCP/tool prefix.
function M.prepare(params)
  local validated, validation_err = validate(params)
  if not validated then
    return fail(validation_err)
  end
  if vim.fn.executable("magick") ~= 1 then
    return fail("ImageMagick (magick) is required to identify and validate image content")
  end

  local excluded = M.detect_excluded_content(validated.path)
  if excluded then
    return fail(string.format("%s input is not supported", excluded))
  end
  local source, source_err = probe_image(validated.path)
  if not source then
    return fail(source_err)
  end
  if EXCLUDED_FORMATS[source.format] then
    return fail(string.format("%s input is not supported", source.format))
  end
  if source.image_count ~= 1 then
    return fail(
      string.format(
        "Animated, multi-frame, or multi-page images are not supported (detected %d images)",
        source.image_count
      )
    )
  end

  local temp_path, metadata, transform_err = transform(validated.path, source, validated)
  if transform_err then
    return fail(transform_err)
  end
  if metadata.width > API_MAX_SIZE or metadata.height > API_MAX_SIZE then
    cleanup_temp(temp_path)
    return fail(
      string.format(
        "Image dimensions %dx%d exceed API maximum (%dpx per side)",
        metadata.width,
        metadata.height,
        API_MAX_SIZE
      )
    )
  end

  local encode_path = temp_path or validated.path
  local ok, payload = pcall(function()
    return require("maxa.utils.images").encode_image({ path = encode_path, id = validated.path })
  end)
  cleanup_temp(temp_path)
  if not ok then
    return fail("Failed to encode image: " .. bounded_diagnostic(payload))
  end
  if type(payload) == "string" then
    return fail(bounded_diagnostic(payload))
  end
  if type(payload) ~= "table" or type(payload.base64) ~= "string" then
    return fail("Image encoder returned an invalid payload")
  end
  payload.mimetype = metadata.mimetype

  return { payload = payload, metadata = metadata }, nil
end

M.API_MAX_SIZE = API_MAX_SIZE
M.DEFAULT_DETAIL = DEFAULT_DETAIL
M.DEFAULT_RESIZE_MODE = DEFAULT_RESIZE_MODE

return M
