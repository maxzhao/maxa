-- filepath: lua/maxa/interactions/chat/tools/builtin/tools/builtin_edit.lua
-- Silent edit_file implementation with delimiter blocks and local fuzzy matching.

local ok_path, Path = pcall(require, "plenary.path")
if not ok_path then
  Path = {}
  function Path:new(file_path)
    local obj = { filename = file_path }
    function obj:exists()
      return vim.uv.fs_stat(self.filename) ~= nil
    end
    function obj:is_file()
      local stat = vim.uv.fs_stat(self.filename)
      return stat ~= nil and stat.type == "file"
    end
    function obj:read()
      local fd = assert(io.open(self.filename, "r"))
      local text = fd:read("*a") or ""
      fd:close()
      return text
    end
    function obj:write(data, mode)
      local fd = assert(io.open(self.filename, mode == "a" and "a" or "w"))
      fd:write(data or "")
      fd:close()
    end
    return obj
  end
end
local utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

local function edit_config() return require("maxa.config").runtime().tools.edit_file end

local function trim(s)
  return vim.trim(s or "")
end

local function split_lines(text)
  text = text or ""
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(text, "\n", { plain = true, trimempty = false })
end

local function join_lines(lines)
  return table.concat(lines, "\n")
end

local function normalize_for_match(str)
  str = str or ""
  str = str:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&amp;", "&")
  str = str:gsub("“", '"'):gsub("”", '"'):gsub("‘", "'"):gsub("’", "'")
  str = str:gsub("…", "..."):gsub("—", "-"):gsub("–", "-")
  str = trim(str):gsub("%s+", " ")
  return str:lower()
end

local function normalize_punctuation(str)
  str = str or ""
  str = str:gsub("%s*,%s*", ", ")
  str = str:gsub("%s*;%s*", "; ")
  str = str:gsub("%s*%(%s*", "(")
  str = str:gsub("%s*%)%s*", ")")
  str = str:gsub("%s*%[%s*", "[")
  str = str:gsub("%s*%]%s*", "]")
  str = str:gsub("%s*{%s*", "{")
  str = str:gsub("%s*}%s*", "}")
  str = str:gsub(",%s*$", "")
  str = str:gsub(";%s*$", "")
  return str
end

local function levenshtein(a, b)
  a = a or ""
  b = b or ""
  if a == b then
    return 0
  end
  local len_a, len_b = #a, #b
  if len_a == 0 then
    return len_b
  end
  if len_b == 0 then
    return len_a
  end
  local prev = {}
  for j = 0, len_b do
    prev[j] = j
  end
  for i = 1, len_a do
    local cur = { [0] = i }
    local ca = a:sub(i, i)
    for j = 1, len_b do
      local cost = ca == b:sub(j, j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[len_b]
end

local function similarity(a, b)
  a = a or ""
  b = b or ""
  if a == b then
    return 1
  end
  local max_len = math.max(#a, #b)
  if max_len == 0 then
    return 1
  end
  return 1 - levenshtein(a, b) / max_len
end

local function compare_lines(line1, line2)
  if line1 == line2 then
    return "exact", 1.0
  end

  local ws1 = trim(line1):gsub("%s+", " ")
  local ws2 = trim(line2):gsub("%s+", " ")
  if ws1 == ws2 then
    return "exact_whitespace", 0.99
  end

  local code1 = normalize_for_match(line1)
  local code2 = normalize_for_match(line2)
  if code1 == code2 then
    return "normalized", 0.98
  end

  local punct1 = normalize_punctuation(code1)
  local punct2 = normalize_punctuation(code2)
  if punct1 == punct2 then
    return "punctuation", 0.95
  end

  if code1:lower() == code2:lower() then
    return "case_insensitive", 0.90
  end

  local score = similarity(code1, code2)
  if score >= 0.85 then
    return "fuzzy_high", score
  elseif score >= 0.70 then
    return "fuzzy_medium", score
  elseif score >= 0.50 then
    return "fuzzy_low", score
  end
  return "no_match", score
end

local function marker_kind(line)
  local left, delimiter = line:match("^%s*(<+)%s+([%w_.:-]+)%s*$")
  if left and #left >= 5 then
    return "open", delimiter
  end

  local eqs, delimiter2 = line:match("^%s*(=+)%s+([%w_.:-]+)%s*$")
  if eqs and #eqs >= 7 then
    return "separator", delimiter2
  end

  local rights, delimiter3 = line:match("^%s*(>+)%s+([%w_.:-]+)%s*$")
  if rights and #rights >= 5 then
    return "close", delimiter3
  end

  return nil, nil
end

local function new_parser(config)
  local self = {
    config = vim.tbl_deep_extend("force", vim.deepcopy(edit_config().parser), config or {}),
    issues = {},
  }

  local function track(issue)
    table.insert(self.issues, issue)
  end

  function self:parse(diff_content)
    if not diff_content or diff_content == "" then
      return nil, "Empty diff content"
    end

    self.issues = {}
    local lines = split_lines(diff_content)
    local blocks = {}
    local state = "waiting"
    local current = nil
    local block_counter = 1

    local function finish_block()
      local search_content = join_lines(current.search_lines)
      local replace_content = join_lines(current.replace_lines)
      if search_content ~= "" or replace_content ~= "" then
        table.insert(blocks, {
          search_content = search_content,
          replace_content = replace_content,
          block_id = "Block " .. block_counter,
          search_lines = vim.deepcopy(current.search_lines),
          replace_lines = vim.deepcopy(current.replace_lines),
          delimiter = current.delimiter,
        })
        block_counter = block_counter + 1
      end
    end

    local function expected_format(delimiter)
      delimiter = delimiter or self.config.default_delimiter
      return string.format(
        "Expected edit block format:\n<<<<<<< %s\n[original text to find]\n======= %s\n[new text]\n>>>>>>> %s",
        delimiter,
        delimiter,
        delimiter
      )
    end

    local function invalid_start(line_num)
      return string.format(
        "Invalid delimiter block at line %d. The diff must start with an opening marker `<<<<<<< %s`.\n\n%s",
        line_num,
        self.config.default_delimiter,
        expected_format(self.config.default_delimiter)
      )
    end

    local function delimiter_conflict(line_num, delimiter)
      return string.format(
        "Delimiter `%s` conflicts with content at line %d. Retry with a different delimiter.",
        delimiter,
        line_num
      )
    end

    for line_num, line in ipairs(lines) do
      local kind, delimiter = marker_kind(line)

      if state == "waiting" then
        if kind == "open" then
          state = "searching"
          current = {
            delimiter = delimiter,
            search_lines = {},
            replace_lines = {},
          }
        elseif trim(line) ~= "" then
          return nil, invalid_start(line_num)
        end
      elseif state == "searching" then
        if kind == "separator" and delimiter == current.delimiter then
          state = "replacing"
        elseif kind == "close" and delimiter == current.delimiter then
          return nil, string.format(
            "Missing middle separator before closing marker at line %d. The separator line must be exactly `======= %s` for this block. A bare `=======` is invalid.\n\n%s",
            line_num,
            delimiter,
            expected_format(delimiter)
          )
        elseif kind == "open" and delimiter == current.delimiter then
          return nil, delimiter_conflict(line_num, delimiter)
        else
          table.insert(current.search_lines, line)
        end
      elseif state == "replacing" then
        if kind == "close" and delimiter == current.delimiter then
          finish_block()
          state = "waiting"
          current = nil
        elseif kind == "separator" and delimiter == current.delimiter then
          return nil, string.format(
            "Unexpected separator after replacement started at line %d. Use one separator only.",
            line_num
          )
        elseif kind == "open" and delimiter == current.delimiter then
          return nil, delimiter_conflict(line_num, delimiter)
        else
          table.insert(current.replace_lines, line)
        end
      end
    end

    if state ~= "waiting" then
      return nil, string.format(
        "Incomplete delimiter block. Close the block with `>>>>>>> %s` after the replacement content.\n\n%s",
        current and current.delimiter or self.config.default_delimiter,
        expected_format(current and current.delimiter or self.config.default_delimiter)
      )
    end

    if #blocks == 0 then
      return nil, "No valid delimiter blocks found"
    end

    return blocks, nil
  end

  function self:has_issues()
    return #self.issues > 0
  end

  function self:get_feedback()
    if #self.issues == 0 then
      return nil
    end
    return "## ISSUES WHILE PARSING DIFF\n" .. table.concat(self.issues, "\n\n")
  end

  function self:track_issue(issue)
    track(issue)
  end

  return self
end

local function compare_priority(match_type)
  local priority = {
    exact = 5,
    exact_whitespace = 4,
    normalized = 3,
    punctuation = 2,
    case_insensitive = 1,
    fuzzy_high = 0,
    fuzzy_medium = 0,
    fuzzy_low = 0,
    no_match = -1,
  }
  return priority[match_type] or -1
end

local function new_locator(config)
  local self = {
    config = vim.tbl_deep_extend("force", vim.deepcopy(edit_config().locator), config or {}),
  }

  local function range_available(used_ranges, start_line, end_line)
    for _, range in ipairs(used_ranges) do
      if not (end_line < range.start_line or start_line > range.end_line) then
        return false
      end
    end
    return true
  end

  local function mark_used(used_ranges, start_line, end_line)
    table.insert(used_ranges, { start_line = start_line, end_line = end_line })
  end

  local function locate_one(search_lines, file_lines, used_ranges)
    if #search_lines == 0 then
      return {
        found = true,
        start_line = 1,
        end_line = 0,
        overall_score = 1,
        overall_match_type = "exact",
        confidence = 100,
        found_content = "",
        found_lines = {},
        line_details = {},
        search_metadata = {},
      }
    end

    local best = nil

    for start_pos = 1, #file_lines - #search_lines + 1 do
      local end_pos = start_pos + #search_lines - 1
      if range_available(used_ranges, start_pos, end_pos) then
        local total_score = 0
        local all_exact = true
        local all_whitespace_or_better = true
        local line_details = {}

        for i = 1, #search_lines do
          local expected = search_lines[i]
          local actual = file_lines[start_pos + i - 1]
          local match_type, score = compare_lines(expected, actual)
          total_score = total_score + score

          if match_type ~= "exact" then
            all_exact = false
          end
          if match_type ~= "exact" and match_type ~= "exact_whitespace" then
            all_whitespace_or_better = false
          end

          line_details[#line_details + 1] = {
            line_number = start_pos + i - 1,
            expected_line = expected,
            found_line = actual,
            line_score = score,
            line_match_type = match_type,
            differences = {},
          }
        end

        local avg_score = total_score / #search_lines
        local overall_match_type
        if all_exact then
          overall_match_type = "exact"
        elseif all_whitespace_or_better then
          overall_match_type = "exact_whitespace"
        elseif avg_score >= 0.85 then
          overall_match_type = "fuzzy_high"
        elseif avg_score >= 0.70 then
          overall_match_type = "fuzzy_medium"
        else
          overall_match_type = "fuzzy_low"
        end

        local candidate = {
          score = avg_score,
          start_line = start_pos,
          end_line = end_pos,
          line_details = line_details,
          match_type = overall_match_type,
        }

        if not best then
          best = candidate
        else
          local best_priority = compare_priority(best.match_type)
          local candidate_priority = compare_priority(candidate.match_type)
          if candidate_priority > best_priority or (candidate_priority == best_priority and candidate.score > best.score) then
            best = candidate
          end
        end

        if overall_match_type == "exact" then
          best = candidate
          break
        end
      end
    end

    if best and (
      best.match_type == "exact"
      or best.match_type == "exact_whitespace"
      or (self.config.enable_fuzzy_matching and best.score >= self.config.fuzzy_threshold)
    ) then
      mark_used(used_ranges, best.start_line, best.end_line)
      local found_lines = vim.list_slice(file_lines, best.start_line, best.end_line)
      return {
        found = true,
        start_line = best.start_line,
        end_line = best.end_line,
        overall_score = best.score,
        overall_match_type = best.match_type,
        confidence = math.floor(best.score * 100),
        found_content = join_lines(found_lines),
        found_lines = found_lines,
        line_details = best.line_details,
        search_metadata = {},
      }
    end

    return {
      found = false,
      error = "No suitable match found",
      overall_score = best and best.score or 0,
      confidence = math.floor((best and best.score or 0) * 100),
      start_line = best and best.start_line or 1,
      end_line = best and best.end_line or 1,
      found_content = "",
      found_lines = {},
      line_details = best and best.line_details or {},
      search_metadata = {},
    }
  end

  function self:locate_all_blocks(parsed_blocks, file_content)
    local file_lines = split_lines(file_content)
    local located_blocks = {}
    local used_ranges = {}

    for _, parsed_block in ipairs(parsed_blocks) do
      local location_result = locate_one(parsed_block.search_lines, file_lines, used_ranges)
      located_blocks[#located_blocks + 1] = {
        search_content = parsed_block.search_content,
        replace_content = parsed_block.replace_content,
        block_id = parsed_block.block_id,
        search_lines = parsed_block.search_lines,
        replace_lines = parsed_block.replace_lines,
        location_result = location_result,
      }
    end

    return located_blocks
  end

  function self:get_feedback(located_blocks)
    local logs = {}
    if located_blocks then
      for _, block in ipairs(located_blocks) do
        if not block.location_result.found then
          logs[#logs + 1] = string.format(
            "### `%s` (ERROR)\nFinding content for `%s` failed: `%s`",
            block.block_id,
            block.block_id,
            block.location_result.error or "unknown error"
          )
        elseif block.location_result.overall_match_type ~= "exact" and block.location_result.overall_match_type ~= "exact_whitespace" then
          logs[#logs + 1] = string.format(
            "### `%s` (WARNING)\nBlock was applied using fuzzy matching with %d%% confidence.",
            block.block_id,
            block.location_result.confidence or 0
          )
        end
      end
    end

    if #logs > 0 then
      return "## ISSUES WHILE SEARCHING\n" .. table.concat(logs, "\n\n")
    end
    return nil
  end

  return self
end

local function apply_changes(file_lines, located_blocks)
  local result_lines = vim.deepcopy(file_lines)
  local base_line_offset = 0

  table.sort(located_blocks, function(a, b)
    return a.location_result.start_line < b.location_result.start_line
  end)

  for _, block in ipairs(located_blocks) do
    local start_line = block.location_result.start_line + base_line_offset
    local end_line = block.location_result.end_line + base_line_offset

    for _ = start_line, end_line do
      table.remove(result_lines, start_line)
    end
    for i, line in ipairs(block.replace_lines) do
      table.insert(result_lines, start_line + i - 1, line)
    end

    base_line_offset = base_line_offset + (#block.replace_lines - (end_line - start_line + 1))
  end

  return result_lines
end

local function generate_report(parser, locator, located_blocks, file_path)
  local parts = {}
  parts[#parts + 1] = string.format("Edited %s (%d blocks)", file_path, #located_blocks)

  local parser_feedback = parser:get_feedback()
  if parser_feedback then
    parts[#parts + 1] = parser_feedback
  end

  local locator_feedback = locator:get_feedback(located_blocks)
  if locator_feedback then
    parts[#parts + 1] = locator_feedback
  end

  return table.concat(parts, "\n\n")
end

local function parse_and_locate(diff_content, file_content)
  local parser = new_parser(edit_config().parser)
  local locator = new_locator(edit_config().locator)
  local parsed_blocks, parse_error = parser:parse(diff_content)
  if not parsed_blocks then
    return nil, nil, nil, parse_error
  end
  local located_blocks = locator:locate_all_blocks(parsed_blocks, file_content)
  return parser, locator, parsed_blocks, located_blocks
end

return {
  name = "edit",
  display = function(args)
    return { summary = require("maxa.interactions.chat.tools.display_helpers").path_detail("edit", args) }
  end,
  description = [[Apply delimiter-block edits directly to a file without opening an editor.
Uses local fuzzy matching to locate target content. Default delimiter is `EDIT_FILE`; choose another delimiter only when block content contains that token.]],
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Path to the file to modify.",
      },
      diff = {
        type = "string",
        description = [[Not a unified diff. Provide one or more blocks exactly as:

<<<<<<< EDIT_FILE
[original text to find]
======= EDIT_FILE
[new text]
>>>>>>> EDIT_FILE

Rules: include opening, middle separator, and closing markers; the middle line must be `======= EDIT_FILE` for the default delimiter; bare `=======` is invalid; use the same delimiter on all 3 marker lines. Use another delimiter only if `EDIT_FILE` appears in block content, e.g. `<<<<<<< MY_DELIM`, `======= MY_DELIM`, `>>>>>>> MY_DELIM`.]],
      },
    },
    required = { "path", "diff" },
  },
  __test = {
    compare_lines = compare_lines,
    parse_diff = function(diff_content)
      local parser = new_parser(edit_config().parser)
      return parser:parse(diff_content)
    end,
    locate_blocks = function(parsed_blocks, file_content)
      local locator = new_locator(edit_config().locator)
      return locator:locate_all_blocks(parsed_blocks, file_content)
    end,
  },
  run = function(context, response)
    local params = param_utils.normalize(context.params)

    local missing_path = not params.path or trim(params.path) == ""
    local missing_diff = not params.diff or trim(params.diff) == ""

    if missing_path and missing_diff then
      return response:error(
        "Both 'path' and 'diff' parameters are missing. "
          .. "This usually happens when the diff content is too large and output gets truncated. "
          .. "Please split the diff into smaller delimiter blocks and try again."
      )
    end

    if missing_path then
      return response:error("Missing required parameter: path")
    end
    if missing_diff then
      return response:error("Missing required parameter: diff. If the diff is large, split it into smaller delimiter blocks.")
    end

    local file_path = params.path
    local diff_content = params.diff

    local p = Path:new(file_path)
    local file_content = ""
    local is_new_file = false

    if p:exists() and p:is_file() then
      local read_ok, read_result = pcall(function()
        return p:read()
      end)
      if not read_ok then
        return response:error(string.format("Failed to read `%s`: %s", file_path, tostring(read_result)))
      end
      file_content = read_result or ""
    else
      is_new_file = true
    end

    local function write_file_content(new_content)
      local parent = p.parent and p:parent() or nil
      if parent and not parent:exists() then
        local mkdir_ok, mkdir_err = pcall(function()
          parent:mkdir({ parents = true })
        end)
        if not mkdir_ok then
          return false, string.format("Failed to create parent directory for `%s`: %s", file_path, tostring(mkdir_err))
        end
      end
      local write_ok, write_err = pcall(function()
        p:write(new_content, "w")
      end)
      if not write_ok then
        return false, string.format("Failed to write `%s`: %s", file_path, tostring(write_err))
      end
      return true, nil
    end

    local parser, locator, parsed_blocks, located_blocks, parse_error = nil, nil, nil, nil, nil
    parser, locator, parsed_blocks, parse_error = parse_and_locate(diff_content, file_content)
    if not parser then
      return response:error("Failed to parse diff: " .. (parse_error or "unknown error"))
    end

    local has_empty_search = false
    for _, block in ipairs(parsed_blocks) do
      if trim(block.search_content) == "" then
        has_empty_search = true
        break
      end
    end

    if has_empty_search and #parsed_blocks > 1 then
      return response:error(
        "A block with empty search content was found, but multiple blocks are present. "
          .. "Use a single empty-search block only when you want to replace the entire file."
      )
    end

    if has_empty_search then
      local new_content = parsed_blocks[1].replace_content
      local write_ok, write_err = write_file_content(new_content)
      if not write_ok then
        return response:error(write_err)
      end
      utils.reload_buffer_if_needed(file_path)
      utils.fire_file_event(context, is_new_file and "create" or "modify", file_path, "edit")
      return response:text(string.format("%s %s (1 block)", is_new_file and "Created" or "Replaced", file_path)):send()
    end

    if is_new_file then
      return response:error(
        string.format(
          "Editing `%s` failed. The file does not exist. Use an empty-search block to create a new file.",
          file_path
        )
      )
    end

    located_blocks = locator:locate_all_blocks(parsed_blocks, file_content)

    local failed_blocks = vim.tbl_filter(function(block)
      return not block.location_result.found
    end, located_blocks)

    if #failed_blocks > 0 then
      local lines = {
        "Edit failed: " .. file_path,
        "No changes were made.",
        string.format("Unmatched blocks: %d/%d", #failed_blocks, #located_blocks),
      }
      for _, block in ipairs(failed_blocks) do
        lines[#lines + 1] = "- " .. block.block_id .. ": " .. (block.location_result.error or "unknown error")
      end
      return response:error(table.concat(lines, "\n"))
    end

    local file_lines = split_lines(file_content)
    local result_lines = apply_changes(file_lines, located_blocks)
    local new_content = table.concat(result_lines, "\n")

    local write_ok, write_err = write_file_content(new_content)
    if not write_ok then
      return response:error(write_err)
    end
    utils.reload_buffer_if_needed(file_path)
    utils.fire_file_event(context, "modify", file_path, "edit")

    local report = generate_report(parser, locator, located_blocks, file_path)
    return response:text(report):send()
  end,
}

