-- Shared request-only image size normalization for genai providers.
--
-- Public tools expose only `requested_size`. Providers translate that field to
-- their native upstream `size` field without ratio inference or remapping.

local M = {}

local LEGACY_FIELDS = { "size", "aspect", "ratio" }

local function is_present(value)
  return value ~= nil and value ~= vim.NIL
end

local function trim_string(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  if type(value) ~= "string" then
    return nil
  end
  local text = vim.trim(value)
  if text == "" then
    return nil
  end
  return text
end

function M.trim_string(value)
  return trim_string(value)
end

function M.parse(value)
  local text = trim_string(value)
  if not text or text == "auto" then
    return nil
  end
  local width, height = text:match("^(%d+)x(%d+)$")
  width = tonumber(width)
  height = tonumber(height)
  if not width or not height or width <= 0 or height <= 0 then
    return nil
  end
  return width, height
end

local function reject_legacy_fields(params, provider_label)
  for _, field in ipairs(LEGACY_FIELDS) do
    if is_present(params[field]) then
      return nil,
        string.format(
          "%s no longer accepts top-level `%s`; use top-level `requested_size=auto|WIDTHxHEIGHT`",
          provider_label,
          field
        )
    end
  end

  if type(params.extra) == "table" then
    for _, field in ipairs(LEGACY_FIELDS) do
      if is_present(params.extra[field]) then
        return nil,
          string.format(
            "%s no longer accepts `extra.%s`; use top-level `requested_size=auto|WIDTHxHEIGHT`",
            provider_label,
            field
          )
      end
    end
    if is_present(params.extra.requested_size) then
      return nil,
        string.format(
          "%s does not accept `extra.requested_size`; provide `requested_size` at the top level",
          provider_label
        )
    end
  end

  return true, nil
end

function M.validate_params(params, opts)
  params = params or {}
  opts = opts or {}
  local provider_label = opts.provider_label or "image provider"

  local ok, err = reject_legacy_fields(params, provider_label)
  if not ok then
    return nil, err
  end

  if is_present(params.requested_size) then
    if type(params.requested_size) ~= "string" then
      return nil,
        string.format("%s requested_size must be `auto` or positive-integer `WIDTHxHEIGHT`", provider_label)
    end
    local normalized = trim_string(params.requested_size)
    if not normalized then
      params.requested_size = nil
    elseif normalized ~= "auto" and not M.parse(normalized) then
      return nil,
        string.format(
          "Invalid requested_size '%s' for %s; expected `auto` or positive-integer `WIDTHxHEIGHT`",
          tostring(params.requested_size),
          provider_label
        )
    else
      params.requested_size = normalized
    end
  end

  return true, nil
end

function M.apply(params, opts)
  local ok, err = M.validate_params(params, opts)
  if not ok then
    return nil, err
  end
  params.requested_size = trim_string(params.requested_size) or "auto"
  return params.requested_size, nil
end

return M
