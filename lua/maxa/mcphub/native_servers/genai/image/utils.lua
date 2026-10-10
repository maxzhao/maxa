-- 通用图片工具辅助函数

local Path = require("plenary.path")

local M = {}

---规范化输出目录。
---@param output_dir string|nil
---@return string|nil
---@return string|nil
function M.resolve_output_dir(output_dir)
  if not output_dir or vim.trim(output_dir) == "" then
    return nil, "output_dir is required"
  end
  return vim.fn.fnamemodify(vim.fn.expand(output_dir), ":p"):gsub("/$", ""), nil
end

---确保输出目录存在。
---@param output_dir string
---@return boolean
---@return string|nil
function M.ensure_output_dir(output_dir)
  local p = Path:new(output_dir)
  if p:exists() then
    if p:is_dir() then
      return true, nil
    end
    return false, "Output path exists but is not a directory: " .. output_dir
  end
  local ok, err = pcall(function()
    p:mkdir({ parents = true })
  end)
  if not ok then
    return false, "Failed to create output directory: " .. tostring(err)
  end
  return true, nil
end

---合并 URL base/path，避免重复斜杠。
---@param base_url string
---@param endpoint string
---@return string
function M.join_url(base_url, endpoint)
  local base = (base_url or ""):gsub("/+$", "")
  local path = (endpoint or ""):gsub("^/+", "")
  if path == "" then
    return base
  end
  return base .. "/" .. path
end

---解析惰性 api_key。
---@param provider table
---@return string|nil
---@return string|nil
function M.resolve_api_key(provider)
  local api_key = provider and provider.api_key
  if type(api_key) == "function" then
    local ok, value = pcall(api_key)
    if not ok then
      return nil, "Failed to resolve API key for image provider '" .. tostring(provider.name) .. "': " .. tostring(value)
    end
    api_key = value
  end
  if not api_key or api_key == "" then
    return nil, "API key is missing for image provider '" .. tostring(provider and provider.name or "<unknown>") .. "'"
  end
  return api_key, nil
end

---校验文件存在且不是目录。
---@param path string
---@param label string|nil
---@return string|nil normalized_path
---@return string|nil error
function M.validate_file(path, label)
  if not path or vim.trim(path) == "" then
    return nil, (label or "file") .. " path is required"
  end
  local normalized = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  local p = Path:new(normalized)
  if not p:exists() then
    return nil, (label or "file") .. " not found: " .. path
  end
  if p:is_dir() then
    return nil, (label or "file") .. " path is a directory: " .. path
  end
  return normalized, nil
end

---规范化文件名片段，避免路径穿越和特殊字符。
---@param value string|nil
---@param fallback string
---@return string
function M.sanitize_filename_part(value, fallback)
  local part = tostring(value or "")
  part = part:gsub("^%s+", ""):gsub("%s+$", "")
  part = part:gsub("[^%w%._%-]+", "_")
  part = part:gsub("_+", "_")
  part = part:gsub("^[_%.%-]+", ""):gsub("[_%.%-]+$", "")
  if part == "" then
    return fallback
  end
  return part
end

---规范化输出图片格式/扩展名。
---@param format string|nil
---@return string
function M.normalize_output_format(format)
  local ext = tostring(format or "png"):lower()
  ext = ext:gsub("^%.", "")
  ext = ext:gsub("[^%w]+", "")
  if ext == "" then
    ext = "png"
  end
  if ext == "jpg" then
    ext = "jpeg"
  end
  return ext
end

---生成不会覆盖已有文件的输出路径。
---@param output_dir string
---@param filename_prefix string|nil
---@param output_format string|nil
---@param index number|nil
---@return string
function M.make_output_path(output_dir, filename_prefix, output_format, index)
  local prefix = M.sanitize_filename_part(filename_prefix, "image_generate")
  local ext = M.normalize_output_format(output_format)
  local stamp = os.date("%Y%m%d_%H%M%S")
  local hr = tostring(vim.uv.hrtime())
  local idx = index and string.format("_%02d", index) or ""
  local basename = string.format("%s_%s_%s%s.%s", prefix, stamp, hr, idx, ext)
  return output_dir .. "/" .. basename
end

---保存 base64 图片数据到文件。
---@param b64 string
---@param output_path string
---@return number|nil bytes
---@return string|nil error
function M.save_base64_file(b64, output_path)
  if type(b64) ~= "string" or b64 == "" then
    return nil, "b64_json is empty"
  end

  -- 兼容 data URL 形式，虽然 OpenAI 兼容接口通常只返回裸 base64。
  local data = b64:match("^data:[^,]+,(.+)$") or b64
  local ok, decoded = pcall(vim.base64.decode, data)
  if not ok or type(decoded) ~= "string" then
    return nil, "Failed to decode b64_json"
  end

  local file, err = io.open(output_path, "wb")
  if not file then
    return nil, "Failed to open output file: " .. tostring(err)
  end

  local write_ok, write_err = file:write(decoded)
  file:close()
  if not write_ok then
    return nil, "Failed to write output file: " .. tostring(write_err)
  end

  return #decoded, nil
end


---把本地文件编码为 data URL。
---@param path string
---@return string|nil data_url
---@return string|nil error
function M.file_to_data_url(path)
  if not path or vim.trim(path) == "" then
    return nil, "file path is required"
  end

  local normalized, err = M.validate_file(path, "image file")
  if not normalized then
    return nil, err
  end

  local ext = vim.fn.fnamemodify(normalized, ':e'):lower()
  local mime_map = {
    png = 'image/png',
    jpg = 'image/jpeg',
    jpeg = 'image/jpeg',
    webp = 'image/webp',
  }
  local mime = mime_map[ext]
  if not mime then
    return nil, 'Unsupported image file type for data URL: ' .. tostring(ext ~= '' and ext or '<none>')
  end

  local file, read_err = io.open(normalized, "rb")
  if not file then
    return nil, "Failed to open image file: " .. tostring(read_err)
  end
  local bytes = file:read("*a")
  file:close()
  if not bytes or bytes == "" then
    return nil, "Image file is empty: " .. normalized
  end

  local ok, encoded = pcall(vim.base64.encode, bytes)
  if not ok or type(encoded) ~= 'string' then
    return nil, 'Failed to encode image file to base64: ' .. normalized
  end

  return 'data:' .. mime .. ';base64,' .. encoded, nil
end

return M
