-- Shared concise result formatting for GenAI image tools.

local M = {}

function M.build(title, result)
  local lines = {
    title,
    "",
    "- Adapter: " .. tostring(result.adapter or result.provider),
    "- Model: " .. tostring(result.model or "unknown"),
    "- Requested size: " .. tostring(result.requested_size or "auto"),
    "- Size check: " .. tostring(result.size_check or "unverified"),
    "- Requested format: " .. tostring(result.output_format or "unknown"),
    "- Response mode: " .. tostring(result.response_mode or "unknown"),
    "- Count: " .. tostring(result.count or 0),
  }

  if result.files and #result.files > 0 then
    table.insert(lines, "")
    table.insert(lines, "Files:")
    for i, file in ipairs(result.files) do
      local actual_size = file.actual_size or "unverified"
      local actual_format = file.actual_format or "unverified"
      table.insert(
        lines,
        string.format(
          "%d. `%s` (%s actual, %d bytes, %s; size check: %s)",
          i,
          file.path,
          actual_size,
          file.bytes or 0,
          actual_format,
          file.size_check or "unverified"
        )
      )
    end
  end

  if result.urls and #result.urls > 0 then
    table.insert(lines, "")
    table.insert(lines, "URLs:")
    for i, url in ipairs(result.urls) do
      table.insert(lines, string.format("%d. %s", i, url))
    end
  end

  if result.warnings and #result.warnings > 0 then
    table.insert(lines, "")
    table.insert(lines, "Warnings:")
    for _, warning in ipairs(result.warnings) do
      table.insert(lines, "- " .. tostring(warning))
    end
  end

  return table.concat(lines, "\n")
end

return M
