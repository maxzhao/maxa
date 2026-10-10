-- Ask owns request/options/visual roles; the coordinator owns channel arbitration.
local M = {}
function M.request(args, status, shortcuts)
  local lines = {}
  local function choice(value)
    return vim.trim(tostring(value or ""):gsub("%s+", " ")):gsub("([\\`*_{}%[%]()#+.!|>~-])", "\\%1")
  end
  if args.message and args.message ~= "" then
    if args.parse_mode == "HTML" then vim.list_extend(lines, { "````html", args.message, "````" })
    else vim.list_extend(lines, vim.split(args.message, "\n", { plain = true })) end
  end
  if args.photo and args.photo ~= "" then
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = "图片：`" .. args.photo .. "`"
  end
  if args.mode == "choice" then
    lines[#lines + 1], lines[#lines + 2] = "", "可选项："
    local index = 0
    for _, row in ipairs(args.choices or {}) do
      for _, item in ipairs(row) do
        index = index + 1
        local value = ""
        if item.value ~= item.label then
          local raw = vim.trim(tostring(item.value):gsub("%s+", " "))
          value = "（值：" .. (raw:find("`", 1, true) and choice(raw) or ("`" .. raw .. "`")) .. "）"
        end
        local key = shortcuts and shortcuts[index] and (" · Alt+" .. index) or ""
        lines[#lines + 1] = string.format("- %d%s　**%s**%s", index, key, choice(item.label), value)
      end
    end
    if status then lines[#lines + 1] = "\n可在输入区输入任意文本；标出的 Alt+数字可直接选择。" end
  elseif args.mode == "input" then
    lines[#lines + 1] = "\n请直接输入文本；也可通过 Telegram 回复一张图片。"
  end
  if status and args.mode ~= "notify" then lines[#lines + 1] = "\n_" .. status .. "_" end
  return { summary = false, progress = false, blocks = {
    { kind = "message", role = "assistant", content = table.concat(lines, "\n") },
  } }
end
function M.display(args, result)
  if not result then return M.request(args) end
  return { summary = false, progress = false, blocks = {
    { kind = "message", role = result.ok and args.mode ~= "notify" and "user" or "assistant",
      content = result.ok and result.text or ("❌ " .. result.text) },
  } }
end
return M
