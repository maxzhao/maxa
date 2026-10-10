local markdown = require("maxa.session.file_links.markdown")
local M = {}

local function below(file, root)
  return file == root or file:sub(1, #root + 1) == root .. "/"
end

local function eligible(chat)
  return chat and not chat._maxa_hidden_image_analysis and not chat._is_rescue_session
end

function M.transform(chat, text, callback)
  if not eligible(chat) or type(text) ~= "string" then return callback(text) end
  local root = require("maxa.session.session_identity").project_root(chat)
  if not root then return callback(text) end
  local allowed = {}
  local _, cfg = require("maxa.session.file_links.service").configuration()
  for _, value in ipairs(cfg.allowed_roots) do
    local path = value:sub(1, 1) == "/" and value or vim.fs.joinpath(root, value)
        local real = vim.uv.fs_realpath(path)
    if real then allowed[#allowed + 1] = real:gsub("/+$", "") end
  end
  local items, paths, seen = markdown.destinations(text), {}, {}
  for _, item in ipairs(items) do
    local target = item.target:gsub("\\([%p])", "%1")
    local local_file = not target:match("^[%a][%w+.-]*:")
    if target:match("^file://") then
      local authority = target:match("^file://([^/]*)")
      if authority == "" or authority == "localhost" then
        target, local_file = target:gsub("^file://localhost", ""):gsub("^file://", ""), true
      end
    end
    if local_file and target ~= "" and target:sub(1, 1) ~= "#" then
      target = vim.uri_decode(target)
      local path = target:sub(1, 1) == "/" and target or vim.fs.joinpath(root, target)
      local real = vim.uv.fs_realpath(path)
      if not real then
        local base, fragment = path:match("^(.-)(#.*)$")
        if base then real, item.fragment = vim.uv.fs_realpath(base), fragment end
      end
      local stat = real and vim.uv.fs_stat(real)
      if stat and stat.type == "file" then
        for _, parent in ipairs(allowed) do
          if below(real, parent) then
            item.path = real
            if not seen[real] then paths[#paths + 1], seen[real] = real, true end
            break
          end
        end
      end
    end
  end
  if #paths == 0 then return callback(text) end
  require("maxa.session.file_links.service").register(root, paths, function(urls, err)
    if not urls then
      vim.notify("[file_links] " .. tostring(err or "file service unavailable"), vim.log.levels.WARN)
      return callback(text)
    end
    callback(markdown.replace(text, items, urls))
  end)
end

-- Preserve original messages/arguments; only the user-facing copy is projected.
function M.params(chat, params, callback)
  if params.parse_mode == "HTML" or type(params.message) ~= "string" then return callback(vim.deepcopy(params)) end
  M.transform(chat, params.message, function(text)
    local copy = vim.deepcopy(params)
    copy.message = text
    callback(copy)
  end)
end

-- Keep only streamed body ranges; reasoning may share the canonical message.
function M.track(chat, source, ranges)
  local api = vim.api
  local ns = api.nvim_create_namespace("MaxaFileLinksBody")
  chat._file_link_body = chat._file_link_body or setmetatable({}, { __mode = "k" })
  local first, last
  for _, range in ipairs(ranges or {}) do
    if range[5] == chat.MESSAGE_TYPES.LLM_MESSAGE then
      first = first or { range[1], range[2] }
      last = { range[3], range[4] }
    end
  end
  if first and last then
    chat._file_link_body[source] = api.nvim_buf_set_extmark(chat.bufnr, ns, first[1], first[2],
      { end_row = last[1], end_col = last[2], right_gravity = false, end_right_gravity = false })
  end
end

local function range_for(chat, provenance, source)
  local id = chat._file_link_body and chat._file_link_body[source]
  if id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(chat.bufnr, vim.api.nvim_create_namespace("MaxaFileLinksBody"), id, { details = true })
    if #mark == 3 and not mark[3].invalid then return { mark[1], mark[2], mark[3].end_row, mark[3].end_col } end
  end
  if source.call_id then
    local first, last = provenance:rows(source)
    if first then
      local line = vim.api.nvim_buf_get_lines(chat.bufnr, last, last + 1, false)[1] or ""
      return { first, 0, last, #line }
    end
    return nil
  end
  return provenance:message_range(source)
end

function M.present(chat, source)
  if not eligible(chat) or not source then return end
  local provenance = chat.ui and chat.ui.message_provenance
  if not provenance or not provenance.message_range then return end
  local range = range_for(chat, provenance, source)
  if not range then return end
  local api, bufnr = vim.api, chat.bufnr
  local original = table.concat(api.nvim_buf_get_text(bufnr, range[1], range[2], range[3], range[4], {}), "\n")
  M.transform(chat, original, function(text)
    if text == original or not api.nvim_buf_is_valid(bufnr) then return end
    local current = range_for(chat, provenance, source)
    if not current then return end
    local shown = table.concat(api.nvim_buf_get_text(bufnr, current[1], current[2], current[3], current[4], {}), "\n")
    if shown ~= original then return end
    local modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    local ok, err = pcall(provenance.text, provenance, current[1], current[2], current[3], current[4],
      vim.split(text, "\n", { plain = true }), source)
    vim.bo[bufnr].modifiable = modifiable
    if not ok then vim.notify("[file_links] " .. tostring(err), vim.log.levels.WARN) end
  end)
end

-- Reconstruct eligibility from canonical message order, not temporary display URLs.
function M.restore(chat)
  local messages = chat.messages or {}
  for index, message in ipairs(messages) do
    if (message.role == "llm" or message.role == "assistant") and type(message.content) == "string"
      and message.content ~= "" and not message.tools and not (message.opts and message.opts.visible == false) then
      local next_message = messages[index + 1]
      local calls = next_message and next_message.tools and next_message.tools.calls
      local is_final = not next_message or next_message.role == "user"
      local first = calls and calls[1]
      local fn = first and first["function"]
      local name = first and (first.name or (fn and fn.name))
      if name == "run" and fn then
        local args = require("maxa.interactions.chat.tools.display").parse_args(fn)
        if args.scope == "tool" and args.command == "ask" then name = "ask" end
      end
      if is_final or name == "ask" then M.present(chat, message) end
    end
    for _, call in ipairs(message.tools and message.tools.calls or {}) do
      local fn = call["function"]
      if fn and fn.name == "ask" then
        local args = require("maxa.interactions.chat.tools.display").parse_args(fn)
        if args.parse_mode ~= "HTML" then
          M.present(chat, { call_id = call.call_id or call.id, phase = "request", all_fragments = true })
        end
      end
    end
  end
end

return M
